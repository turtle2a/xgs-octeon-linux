#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Read-only check of NPU flow-offload capability and state. Changes nothing.
# Prints OFFLOAD: ENABLED (exit 0) only when every item is on; otherwise OFFLOAD: NOT ENABLED
# (exit 1). Run before every test; do not start traffic unless it says ENABLED.
# Some items need root (nft, firmware gate); run with sudo for the full check.
DEV=/sys/bus/pci/devices/0000:01:00.0
P=/sys/module/octep/parameters
TABLE=xgs_offload
bad=0

item() { # name, ok(0/1), detail
	if [ "$2" = 0 ]; then printf 'ok    %-28s %s\n' "$1" "$3"; else printf 'FAIL  %-28s %s\n' "$1" "$3"; bad=1; fi
}
skip() { printf 'skip  %-28s %s\n' "$1" "$2"; skipped=1; }

lsmod | grep -q '^octep ' && item "module loaded" 0 "octep" || item "module loaded" 1 "octep not loaded"

# Capability: the loaded build must expose a writable flow_offload and the TCP state options.
[ -f "$P/flow_offload" ] && item "capability: flow_offload" 0 "param present" || item "capability: flow_offload" 1 "build has no flow_offload"
m=$(stat -c %a "$P/flow_offload" 2>/dev/null)
[ -n "$m" ] && [ $(( 0$m & 0200 )) -ne 0 ] && item "capability: runtime-settable" 0 "mode $m" || item "capability: runtime-settable" 1 "read-only (mode ${m:-?})"
[ -f "$P/ft_tcp_state" ] && item "capability: TCP state sync" 0 "ft_tcp_state=$(cat "$P/ft_tcp_state")" || item "capability: TCP state sync" 1 "missing"

v=$(cat "$P/flow_offload" 2>/dev/null)
[ "$v" = Y ] && item "flow_offload" 0 "Y" || item "flow_offload" 1 "'${v:-unreadable}' (must be Y)"

s=$(cat "$DEV/sdp_state" 2>/dev/null)
case "$s" in
*rings=armed*handshake=completed*front_netdevs=[1-9]*) item "rings armed" 0 "$s" ;;
*) item "rings armed" 1 "${s:-unreadable}" ;;
esac

if [ -r "$DEV/offload" ] && [ -r "$DEV/rpc_allow_write" ]; then
	g=$(cat "$DEV/offload")
	case "$g" in
	*requested=on*acknowledged=yes*) item "firmware gate" 0 "$g" ;;
	*) item "firmware gate" 1 "$g" ;;
	esac
	[ "$(cat "$DEV/rpc_allow_write")" = 1 ] && item "RPC write gate" 0 "open" || item "RPC write gate" 1 "closed (driver cannot program flows)"
else
	skip "firmware / write gate" "needs root"
fi

if [ "$(id -u)" -eq 0 ]; then
	nft list flowtables 2>/dev/null | grep -q 'flags offload' &&
		item "nft flowtable (offload)" 0 "$(nft list flowtables 2>/dev/null | grep -oE 'flowtable [a-z_]+' | tr '\n' ' ')" ||
		item "nft flowtable (offload)" 1 "none with flags offload"
	nft list ruleset 2>/dev/null | grep -q 'flow add' && item "forward 'flow add' rule" 0 "present" || item "forward 'flow add' rule" 1 "missing"
else
	skip "nft flowtable / rule" "needs root"
fi

printf 'params: ft_verdict=%s ft_brctl=%s ft_tcp_state=%s ft_offload_nat=%s ft_reply_frozen=%s\n' \
	"$(cat "$P/ft_verdict" 2>/dev/null)" "$(cat "$P/ft_brctl" 2>/dev/null)" "$(cat "$P/ft_tcp_state" 2>/dev/null)" \
	"$(cat "$P/ft_offload_nat" 2>/dev/null)" "$(cat "$P/ft_reply_frozen" 2>/dev/null)"
printf 'recent: %s offloaded, %s released (kernel log, this boot)\n' \
	"$(journalctl -k -b --no-pager 2>/dev/null | grep -c 'ft: offloaded conn')" \
	"$(journalctl -k -b --no-pager 2>/dev/null | grep -c 'ft: released conn')"

if [ "$bad" = 0 ] && [ "${skipped:-0}" = 1 ]; then
	echo "OFFLOAD: NOT FULLY VERIFIED - some checks need root; run: sudo $0"
	exit 2
fi
if [ "$bad" = 0 ]; then echo "OFFLOAD: ENABLED"; exit 0; fi
echo "OFFLOAD: NOT ENABLED - do not start a test"
exit 1
