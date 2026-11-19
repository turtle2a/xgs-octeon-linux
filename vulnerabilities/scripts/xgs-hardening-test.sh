#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Tests for the NAT security rules (xgs-nat.sh) and the optional hardening (xgs-hardening.sh).
#   xgs-hardening-test.sh          stub test; fake iptables/ip/sysctl, changes nothing, no root needed
#   sudo xgs-hardening-test.sh --live   also checks the running router (read-only)
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
NAT=$ROOT/scripts/nat/xgs-nat.sh
HARD=$ROOT/scripts/nat/xgs-hardening.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }
chk() { # description, command...
	d=$1; shift
	if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

mkdir "$T/bin"
for c in iptables ip sysctl sleep; do
	printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexit 0\n' "$c" "$T" >"$T/bin/$c"
	chmod +x "$T/bin/$c"
done
for c in awk cat sh; do ln -sf "$(command -v $c)" "$T/bin/$c"; done
run() { : >"$T/calls"; env -i PATH="$T/bin" "$@"; }

chk "xgs-nat.sh syntax" sh -n "$NAT"
chk "xgs-hardening.sh syntax" sh -n "$HARD"

run "$NAT" start >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && ok "nat start rc 0" || bad "nat start rc $rc"
grep -q 'nat -A POSTROUTING -s 10.4.4.0/28 -o octep1 -j MASQUERADE' "$T/calls" && ok "per-subnet MASQUERADE" || bad "per-subnet MASQUERADE"
grep -q -e '-A POSTROUTING -o octep1 -j MASQUERADE' "$T/calls" && bad "bare MASQUERADE added" || ok "no bare MASQUERADE added"
grep -q 'XGS-FWD -m conntrack --ctstate INVALID -j DROP' "$T/calls" && ok "FORWARD INVALID drop" || bad "FORWARD INVALID drop"
grep -q -e '-d 10.4.4.0/28 -i octep1 -j DROP' "$T/calls" && ok "new WAN->LAN dropped" || bad "new WAN->LAN dropped"
grep -q -e '-s 10.4.4.0/28 -d 10.1.1.0/28 -j DROP' "$T/calls" && bad "LAN->mgmt blocked by default" || ok "LAN->mgmt open by default"

rc=$(env -i PATH="$T/bin" WAN='octep1;id' "$NAT" start >/dev/null 2>&1; echo $?)
[ "$rc" -eq 64 ] && ok "bad WAN rejected (64)" || bad "bad WAN rc $rc"

run "$NAT" stop >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && ok "nat stop rc 0" || bad "nat stop rc $rc"
grep -q -e '-X XGS-FWD' "$T/calls" && ok "stop removes XGS-FWD" || bad "stop removes XGS-FWD"

run "$HARD" start >/dev/null 2>&1; rc=$?
[ $rc -eq 0 ] && ok "hardening start rc 0" || bad "hardening start rc $rc"
grep -q 'nf_conntrack_max=16384' "$T/calls" && ok "conntrack sysctls set" || bad "conntrack sysctls set"
grep -q 'XGS-HARD-PRE -m conntrack --ctstate INVALID -j DROP' "$T/calls" && ok "mangle INVALID drop" || bad "mangle INVALID drop"
grep -q 'tcpmss ! --mss 536:65535' "$T/calls" && ok "bad-MSS SYN drop" || bad "bad-MSS SYN drop"
grep -q 'tcp-flags ALL NONE -j DROP' "$T/calls" && ok "null-scan drop" || bad "null-scan drop"
grep -q 'DSCP' "$T/calls" && bad "DSCP off by default" || ok "DSCP off by default"
run "$HARD" stop >/dev/null 2>&1
grep -q -e '-X XGS-HARD-PRE' "$T/calls" && ok "hardening stop removes chains" || bad "hardening stop removes chains"
rc=$(env -i PATH="$T/bin" "$HARD" bogus >/dev/null 2>&1; echo $?)
[ "$rc" -eq 64 ] && ok "hardening usage rc 64" || bad "hardening usage rc $rc"

if [ "${1:-}" = --live ]; then
	[ "$(id -u)" -eq 0 ] || { echo "SKIP live: needs root"; exit $((fails > 0)); }
	echo "-- live (read-only); verify flow offload is ON before any throughput test"
	for u in xgs-nat xgs-hardening; do echo "$u: $(systemctl is-enabled $u 2>&1) / $(systemctl is-active $u 2>&1)"; done
	iptables -S FORWARD | sed -n 1,3p | grep -q 'XGS-FWD' && ok "FORWARD jumps to XGS-FWD first" || bad "FORWARD jumps to XGS-FWD first"
	iptables -t nat -S POSTROUTING | grep -q -e '^-A POSTROUTING -o octep1 -j MASQUERADE' && bad "bare MASQUERADE present" || ok "no bare MASQUERADE"
	iptables -t nat -S POSTROUTING | grep -q -e '^-A POSTROUTING -s .* -j MASQUERADE' && ok "per-subnet MASQUERADE present" || bad "per-subnet MASQUERADE present"
	if systemctl is-active xgs-hardening >/dev/null 2>&1; then
		iptables -t mangle -S XGS-HARD-PRE >/dev/null 2>&1 && ok "XGS-HARD-PRE present" || bad "XGS-HARD-PRE present"
		echo "conntrack: $(cat /proc/sys/net/netfilter/nf_conntrack_count)/$(cat /proc/sys/net/netfilter/nf_conntrack_max)"
	fi
	ss -lunp 2>/dev/null | grep -E ':67\b' | grep -q -E 'octep1|enp2s0' && bad "DHCP server bound to WAN/mgmt" || ok "DHCP server not on WAN/mgmt"
	ip rule | grep -q 'lookup 100' && ok "policy routing rules present" || bad "policy routing rules present"
fi

[ $fails -eq 0 ] && echo "ALL PASS" || echo "$fails FAILED"
exit $((fails > 0))
