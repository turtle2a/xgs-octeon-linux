#!/bin/sh
# NAT offload test on one port: the agent must derive the NAT block from conntrack.
# Phase 1 SNAT: host ICMP to TARGET is source-NATed to SNAT_IP (a local address).
# Phase 2 DNAT (only if FAKE_IP is given): host traffic to FAKE_IP is destination-NATed to TARGET.
# Default ICMP: bounce is only valid for host-terminated ICMP. PROTO=tcp runs iperf3 with the local-flow guard on (agent must skip, TCP stays intact).
# The nft table is always removed on exit.
#   sudo scripts/tests/octep-nat-offload.sh [IFACE] [TARGET] [SNAT_IP] [FAKE_IP] [SECONDS]
set -u
IFACE=${1:-octep1}
TARGET=${2:-192.168.1.1}
SNAT_IP=${3:-}
FAKE_IP=${4:-}
SECS=${5:-45}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LOG="$ROOT/testlogs/task9-natoffload-$(date -u +%Y%m%dT%H%MZ).log"
TABLE=xgs_natt
PROTO=${PROTO:-icmp}
[ "$PROTO" = icmp ] && ALLOW_LOCAL=1
ES=$(dirname "$0")/../octep/offload-end-summary.sh
ES_SNAP=$(mktemp 2>/dev/null) && [ -x "$ES" ] && "$ES" snap "$ES_SNAP"

[ "$(id -u)" -eq 0 ] || { echo "SUDO REQUIRED: sudo $0 $IFACE $TARGET $SNAT_IP $FAKE_IP $SECS" >&2; exit 1; }
cleanup() { nft delete table ip $TABLE 2>/dev/null; [ -n "$FAKE_IP" ] && ip route del "$FAKE_IP/32" 2>/dev/null; }
trap cleanup EXIT INT TERM

dev=$(ip route get "$TARGET" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
[ "$dev" = "$IFACE" ] || { echo "route to $TARGET uses $dev, not $IFACE" >&2; exit 1; }
[ -z "$SNAT_IP" ] || ip -4 addr show | grep -q "inet $SNAT_IP/" || { echo "$SNAT_IP is not a local address" >&2; exit 1; }

MGMT=${MGMT_IF:-enp2s0}
case "$IFACE" in octep[0-9]*) ;; *) echo "refusing $IFACE: octep ports only" >&2; exit 1 ;; esac
[ "$(cat /sys/class/net/$MGMT/carrier 2>/dev/null)" = 1 ] || { echo "refusing: mgmt port $MGMT is not up" >&2; exit 1; }
mgmt_net=$(ip -4 route show dev "$MGMT" scope link | awk '{print $1; exit}')
for ip in "$TARGET" "$FAKE_IP" "$SNAT_IP"; do
	[ -n "$ip" ] || continue
	[ "$(ip route get "$ip" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p')" != "$MGMT" ] || { echo "refusing: $ip routes via mgmt port $MGMT ($mgmt_net)" >&2; exit 1; }
done
# Revert timer: removes the nft table and route even if this script hangs or is SIGKILLed
( sleep $((SECS * 3 + 120)); nft delete table ip $TABLE 2>/dev/null; [ -n "$FAKE_IP" ] && ip route del "$FAKE_IP/32" 2>/dev/null ) >/dev/null 2>&1 &
REVERT_PID=$!
cleanup() { kill "$REVERT_PID" 2>/dev/null; nft delete table ip $TABLE 2>/dev/null; [ -n "$FAKE_IP" ] && ip route del "$FAKE_IP/32" 2>/dev/null; }

nft add table ip $TABLE
nft "add chain ip $TABLE post { type nat hook postrouting priority 100; }"
nft "add chain ip $TABLE out { type nat hook output priority -100; }"
[ -n "$SNAT_IP" ] && nft add rule ip $TABLE post oifname "$IFACE" ip daddr "$TARGET" snat to "$SNAT_IP"
[ -n "$FAKE_IP" ] && nft add rule ip $TABLE out ip daddr "$FAKE_IP" dnat to "$TARGET"
[ -n "$FAKE_IP" ] && ip route replace "$FAKE_IP/32" dev "$IFACE"

phase() {
	name=$1; dst=$2
	# octep3 holds SNAT_IP on the same LAN, so the peer may resolve it to octep3's MAC; point it at IFACE
	[ -n "$SNAT_IP" ] && arping -q -c 2 -U -I "$IFACE" -s "$SNAT_IP" "$SNAT_IP" 2>/dev/null
	if [ "$PROTO" != icmp ] && ! iperf3 -c "$dst" -t 2 ${REV:+-R} >/dev/null 2>&1; then
		echo "== $name: preflight failed (peer unreachable or iperf3 busy), skipped"; return 1
	fi
	echo "== $name: $PROTO to $dst, agent ${SECS}s"
	if [ "$PROTO" = tcp ]; then
		iperf3 ${REV:+-R} -c "$dst" -t "$SECS" -i 5 >/tmp/natoffload-load.txt 2>&1 &
	elif [ "$PROTO" = udp ]; then
		iperf3 -u ${REV:+-R} -b 200M -c "$dst" -t "$SECS" -i 5 >/tmp/natoffload-load.txt 2>&1 &
	else
		ping -q -I "$IFACE" -c $((SECS * 5 + 20)) -i 0.2 "$dst" >/tmp/natoffload-load.txt 2>&1 &
	fi
	env SRC_IF="$IFACE" "$ROOT/scripts/octep/offload-agent.py" ${ALLOW_LOCAL:+--allow-local} \
		--seconds "$SECS" --lease "${LEASE:-8}" 2>&1 | tee -a "$LOG" |
		grep -E "nat from conntrack|^conn |reclaim conn|Traceback|Error|rate:|per-second"
	kill %1 2>/dev/null; wait 2>/dev/null
	echo "-- conntrack during phase:"
	grep -E "$PROTO" /proc/net/nf_conntrack | grep -E "$dst|$TARGET" | head -2
	[ "$PROTO" != icmp ] && grep -E "sender|receiver|error" /tmp/natoffload-load.txt
	sleep 5
}
for PROTO in ${PROTOS:-$PROTO}; do phase "SNAT-$PROTO" "$TARGET"; done
[ -n "$FAKE_IP" ] && phase DNAT "$FAKE_IP"
echo "== summary"
echo "NAT blocks derived: $(grep -c 'nat from conntrack' "$LOG")"
echo "EFFECTIVE:   $(grep -c ': EFFECTIVE' "$LOG")"
echo "INEFFECTIVE: $(grep -c ': INEFFECTIVE' "$LOG")"
echo "log: $LOG"
[ -x "$ES" ] && "$ES" report "$ES_SNAP"
rm -f "$ES_SNAP"
