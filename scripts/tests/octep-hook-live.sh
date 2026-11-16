#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Live test of the in-kernel flowtable hook (flow_offload=1). Never reloads octep;
# opens the write gate, binds a throwaway nft flowtable on the LAN and WAN octep ports, waits for
# traffic from a host behind the LAN port, then shows the hook's dmesg lines and tears everything down.
#   octep-hook-live.sh [LAN_IF] [WAN_IF] [SECONDS]      (no reload; refuses unless the NPU is healthy)
# Run iperf3 from the LAN host (iperf3 -c 192.168.1.1 -t 60) within a few seconds of "READY".
# Never touches enp2s0.
set -u
LAN=${1:-octep0}
WAN=${2:-octep1}
SECS=${3:-70}
DEV=/sys/bus/pci/devices/0000:01:00.0
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TABLE=octep_hook_live
MARK=$(date +%s)

[ "$(id -u)" -eq 0 ] || { echo "SUDO REQUIRED: sudo $0 $*" >&2; exit 1; }
case "$LAN$WAN" in *enp2s0*) echo "refusing enp2s0" >&2; exit 1 ;; esac

GATE_OPENED=0
cleanup() {
	# A second, colliding invocation that fails before opening the gate (e.g. "RPC write
	# gate is already open") must not reset these global sysfs params on its own exit --
	# that silently stomps the already-running instance's NAT/flag settings (ft_offload_nat
	# back to N mid-test, invalidating a live NAT retest without any visible error).
	[ "$GATE_OPENED" = 1 ] || return 0
	# xgs-npu-health.timer's sensor read shares the firmware RPC port with flow control
	# (libsbsp.so.1: xgs_mdio_load_ies_rpc_port) and was stopped for the test; restart it.
	systemctl start xgs-npu-health.timer 2>/dev/null
	nft delete table inet "$TABLE" 2>/dev/null
	nft delete table ip xgsdnat 2>/dev/null
	{ echo N > /sys/module/octep/parameters/flow_offload; } 2>/dev/null
	{ echo N > /sys/module/octep/parameters/ft_offload_nat; echo N > /sys/module/octep/parameters/ft_nat_both; echo 0 > /sys/module/octep/parameters/ft_flags_extra; echo N > /sys/module/octep/parameters/ft_nat_ports0; echo 0 > /sys/module/octep/parameters/ft_mflow_extra; echo 0 > /sys/module/octep/parameters/ft_l3_rev; } 2>/dev/null
	echo 0 > "$DEV/rpc_allow_write" 2>/dev/null
	echo off > "$DEV/offload" 2>/dev/null
}
trap cleanup EXIT

PARAM=/sys/module/octep/parameters/flow_offload
healthy() {
	case $(cat "$DEV/sdp_state" 2>/dev/null) in *rings=armed*handshake=completed*front_netdevs=10*) return 0 ;; esac
	return 1
}
busy() { pgrep -f 'sdp-bringup.sh|sdp-recover-npu.sh|rpc-port-setup.sh' >/dev/null; }

healthy && ! busy || { echo "FAIL: NPU not healthy or a bring-up is running; nothing changed. $(cat "$DEV/sdp_state")" >&2; exit 1; }
# a read-only parameter is fine when the loaded build already has it on
if [ "$(cat "$PARAM")" != Y ]; then
	{ echo Y > "$PARAM"; } 2>/dev/null && [ "$(cat "$PARAM")" = Y ] ||
		{ echo "FAIL: loaded octep has a read-only flow_offload=N; load a build with flow_offload=Y first (a module reload drops the rings; do it deliberately, not from this script)" >&2; exit 1; }
fi
# OCTEP_FT_NAT=1 (default here) lets NAT-rewritten flows offload for the experiment; the module default is off.
{ echo "${OCTEP_FT_NAT:-1}" | sed 's/^1$/Y/;s/^0$/N/' > /sys/module/octep/parameters/ft_offload_nat; } 2>/dev/null
# OCTEP_FT_NATBOTH (default 0; run 17 showed no effect) sets both NAT flag bits; the module default is off.
{ echo "${OCTEP_FT_NATBOTH:-0}" | sed 's/^1$/Y/;s/^0$/N/' > /sys/module/octep/parameters/ft_nat_both; } 2>/dev/null
"$ROOT/scripts/octep/rpc-port-setup.sh" || { echo "FAIL: rpc-port-setup" >&2; exit 1; }
echo 1 > "$DEV/rpc_allow_write" && echo on > "$DEV/offload" || { echo "FAIL: gate" >&2; exit 1; }
GATE_OPENED=1
# xgs-npu-health.timer's periodic sensor read shares the firmware RPC port with flow
# control; it is the likely source of periodic stalls seen mid-test (item 7). Stop it
# for the test window; cleanup() restarts it on exit.
systemctl stop xgs-npu-health.timer 2>/dev/null
echo "gate: $(cat "$DEV/offload")"

nft add table inet "$TABLE"
nft add flowtable inet "$TABLE" ft "{ hook ingress priority 0; devices = { $LAN, $WAN }; flags offload; }" ||
	{ echo "FAIL: flowtable bind" >&2; exit 1; }
nft add chain inet "$TABLE" hookfw "{ type filter hook forward priority 0; policy accept; }"
nft add rule inet "$TABLE" hookfw ct state established flow add @ft
# Flag-bit probe: a number in /var/tmp/octep-ft-flags-extra (e.g. 0x40000) is ORed into the flow-create flags.
{ cat /var/tmp/octep-ft-flags-extra 2>/dev/null || echo 0; } | { read -r v; echo "$((v))" > /sys/module/octep/parameters/ft_flags_extra; } 2>/dev/null
# /var/tmp/octep-ft-ports0 containing 1 writes zero NAT-block ports for the run.
if [ "$(cat /var/tmp/octep-ft-ports0 2>/dev/null)" = 1 ]; then echo Y > /sys/module/octep/parameters/ft_nat_ports0; fi
{ cat /var/tmp/octep-ft-mflow-extra 2>/dev/null || echo 0; } | { read -r v; echo "$((v))" > /sys/module/octep/parameters/ft_mflow_extra; } 2>/dev/null
{ cat /var/tmp/octep-ft-l3-rev 2>/dev/null || echo 0; } | { read -r v; echo "$((v))" > /sys/module/octep/parameters/ft_l3_rev; } 2>/dev/null
if [ "$(cat /var/tmp/octep-ft-tcp-state 2>/dev/null)" = 1 ]; then echo Y > /sys/module/octep/parameters/ft_tcp_state; else echo N > /sys/module/octep/parameters/ft_tcp_state; fi 2>/dev/null
echo "l3_rev=$(cat /sys/module/octep/parameters/ft_l3_rev 2>/dev/null)"
echo "tcp_state=$(cat /sys/module/octep/parameters/ft_tcp_state 2>/dev/null)"
echo "mflow_extra=$(cat /sys/module/octep/parameters/ft_mflow_extra 2>/dev/null)"
echo "nat_ports0=$(cat /sys/module/octep/parameters/ft_nat_ports0 2>/dev/null)"
echo "flags_extra=$(cat /sys/module/octep/parameters/ft_flags_extra 2>/dev/null)"
# 4th argument "dnat": LAN host connects to 10.4.4.10:5202 and is DNAT-ed to the server 192.168.1.1:5201 (masquerade adds SNAT).
if [ "${4:-}" = dnat ]; then
	nft add table ip xgsdnat
	nft "add chain ip xgsdnat pre { type nat hook prerouting priority -100; }"
	nft add rule ip xgsdnat pre iifname "$LAN" ip daddr 10.4.4.10 tcp dport 5202 dnat to 192.168.1.1:5201
	echo "DNAT test: run iperf3 -B 10.4.4.2 -c 10.4.4.10 -p 5202 -t 60"
fi
echo "READY: start iperf3 from the LAN host now (${SECS}s window)"
# Live ground-truth check: the moment an "offloaded conn" line appears, query the firmware's own
# LO_MFLOW_READ for both microflow ids (not our pre-send dump) to settle whether state=2 actually
# landed in the live table, instead of inferring it from what we wrote.
(
	seen=""
	end=$((SECONDS + SECS + 5))
	while [ "$SECONDS" -lt "$end" ]; do
		line=$(dmesg --time-format iso --since "@$MARK" 2>/dev/null | grep -F "offloaded conn" | tail -1)
		if [ -n "$line" ] && [ "$line" != "$seen" ]; then
			seen="$line"
			oid=$(echo "$line" | grep -oP 'orig id \K[0-9]+')
			rid=$(echo "$line" | grep -oP 'reply id \K[0-9]+')
			for tag_id in "orig:$oid" "reply:$rid"; do
				tag=${tag_id%%:*}; id=${tag_id#*:}
				[ -n "$id" ] || continue
				echo "$id" > "$DEV/rpc_mflow_read" 2>/dev/null
				echo "mflow-live-readback $tag id=$id: $(cat "$DEV/rpc_mflow_read" 2>/dev/null)"
			done
		fi
		sleep 0.2
	done
) &
# per-second NPU counter deltas, as the agent reports them (WIRE_TO_WIRE rising = NPU forwarding)
python3 - "$ROOT" "$SECS" <<'PY' &
import sys, time, importlib.util as u
root, secs = sys.argv[1], int(sys.argv[2])
spec = u.spec_from_file_location("c", f"{root}/scripts/tests/octep-offload-commission.py")
c = u.module_from_spec(spec); spec.loader.exec_module(c)
prev = c.counters()
for _ in range(secs):
    time.sleep(1)
    now = c.counters()
    d = {c.NAMES.get(i, f"#{i}"): now[i] - prev.get(i, 0) for i in now if now[i] != prev.get(i, 0)}
    if d:
        print(time.strftime("%H:%M:%S"), "npu:", d, flush=True)
    prev = now
PY
wait

echo "== hook dmesg"
dmesg --time-format iso --since "@$MARK" 2>/dev/null | grep -E "octep 0000:01:00.0: ft:|octep.*ft: |ft: dbg" | tail -80
echo "== conntrack"
grep dport=5201 /proc/net/nf_conntrack | cut -c1-250
echo "== counters"
cat "$DEV/offload"
grep -E "WIRE_TO_WIRE|CONN_RECLAIMED|MFLOW_NOT_ACTIVE" "$DEV"/rpc_sys_counters 2>/dev/null | head
