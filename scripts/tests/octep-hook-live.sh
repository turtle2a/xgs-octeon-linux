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
# Keep a copy of everything printed, so a run is never lost to terminal scrollback.
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LOGDIR=$ROOT/testlogs/hook-runs   # persistent: nothing is written to /tmp
mkdir -p "$LOGDIR"
HOOK_LOG=${OCTEP_HOOK_LOG:-$LOGDIR/hook-$(date +%Y%m%d-%H%M%S).log}
# Everything is printed live by default; OCTEP_HOOK_VERBOSE=0 hides the per-second npu:/ft: dbg lines (still in the log).
exec > >(if [ "${OCTEP_HOOK_VERBOSE:-1}" = 1 ]; then tee "$HOOK_LOG"; else tee "$HOOK_LOG" | grep -vE '^[0-9:]{8} npu:|ft: dbg|^[0-9T:,.+-]+ (ft: dbg|octep.*dbg)'; fi) 2>&1
echo "log: $HOOK_LOG"
# One hook at a time: two instances each report every takeover, which duplicated the events.
exec 9>/run/octep-hook-live.lock
flock -n 9 || { echo "FAIL: another octep-hook-live.sh is already running (pid $(pgrep -f '^bash .*octep-hook-live.sh' | grep -v "^$$\$" | head -1))" >&2; exit 1; }
DEV=/sys/bus/pci/devices/0000:01:00.0
TABLE=octep_hook_live
MARK=$(date +%s)

[ "$(id -u)" -eq 0 ] || { echo "SUDO REQUIRED: sudo $0 $*" >&2; exit 1; }
case "$LAN$WAN" in *enp2s0*) echo "refusing enp2s0" >&2; exit 1 ;; esac

GATE_OPENED=0
PCAP_DIR=$ROOT/testlogs/captures
PCAP_TAG=takeover-$(date +%Y%m%d-%H%M%S)
cleanup() {
	# The two review logs, kept in testlogs/: kernel log (dmesg) and flow log (counters, takeover verdicts, captures).
	sleep 1
	if [ "${GATE_OPENED:-0}" = 1 ]; then
	journalctl -k --since "@$MARK" --no-pager > "$LOGDIR/dmesg-$PCAP_TAG.log" 2>/dev/null
	grep -E '^[0-9:]{8} (npu|npu-load)|TAKEOVER|OFFLOAD-PROOF|GATE-EVENT|PCAP|mflow-live|HOOK-STOPPED' "$HOOK_LOG" > "$LOGDIR/flow-$PCAP_TAG.log" 2>/dev/null
	chmod a+r "$LOGDIR"/*"$PCAP_TAG"* 2>/dev/null
	[ -n "$SUDO_UID" ] && chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$LOGDIR"/*"$PCAP_TAG"* "$HOOK_LOG" 2>/dev/null
	echo "LOGS: $LOGDIR/dmesg-$PCAP_TAG.log  $LOGDIR/flow-$PCAP_TAG.log  $HOOK_LOG"
	# Run ledger: one row per run, so successes and failures are tracked and regressions are decided from data.
	L=$ROOT/testlogs/offload-runs.tsv
	[ -f "$L" ] || printf 'run\tmodule_built\tcutin\tverdict\tnat\tdelay_ms\toffloaded\trelease\tOFFLOADING\tSTALLING\tHOST-PATH\tproven\tcrosscheck_disagree\n' > "$L"
	P=/sys/module/octep/parameters
	c() { grep -c -- "$1" "$LOGDIR/flow-$PCAP_TAG.log" 2>/dev/null; }
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$PCAP_TAG" "$(date -r "$ROOT/octep/octep.ko" +%m%d-%H%M 2>/dev/null)" \
		"$(cat $P/ft_cutin 2>/dev/null)" "$(cat $P/ft_verdict 2>/dev/null)" "$(cat $P/ft_offload_nat 2>/dev/null)" "$(cat $P/ft_delay_ms 2>/dev/null)" \
		"$(grep -c 'ft: offloaded conn' "$LOGDIR/dmesg-$PCAP_TAG.log" 2>/dev/null)" "$(grep -c 'ft: released conn' "$LOGDIR/dmesg-$PCAP_TAG.log" 2>/dev/null)" \
		"$(c 'STATE.*OFFLOADING')" "$(c 'STATE.*STALLING')" "$(c 'STATE.*HOST-PATH')" "$(c 'PROOF YES')" "$(c 'CROSS-CHECK DISAGREE')" >> "$L"
	echo "LEDGER: $L"; tail -n 3 "$L"
	fi
	# Stop the captures first and keep the review files readable; print what they hold.
	pkill -f "tcpdump -nn -i ($LAN|$WAN) .*$PCAP_TAG" 2>/dev/null
	sleep 1
	for f in "$PCAP_DIR"/$PCAP_TAG-*.pcap; do
		[ -f "$f" ] || continue
		chmod a+r "$f" 2>/dev/null
		[ -n "$SUDO_UID" ] && chown "$SUDO_UID:${SUDO_GID:-$SUDO_UID}" "$f" 2>/dev/null
		echo "PCAP: $f packets=$(tcpdump -nn -r "$f" 2>/dev/null | wc -l)"
	done
	# A second, colliding invocation that fails before opening the gate (e.g. "RPC write
	# gate is already open") must not reset these global sysfs params on its own exit --
	# that silently stomps the already-running instance's NAT/flag settings (ft_offload_nat
	# back to N mid-test, invalidating a live NAT retest without any visible error).
	echo "$(date +%T) cleanup() called pid=$$ bashpid=$BASHPID ppid=$PPID gate_opened=${GATE_OPENED:-0} lastcmd=$BASH_COMMAND" >> "$LOGDIR/hook-cleanup.log"
	[ "$GATE_OPENED" = 1 ] || return 0
	# xgs-npu-health.timer's sensor read shares the firmware RPC port with flow control
	# (libsbsp.so.1: xgs_mdio_load_ies_rpc_port) and was stopped for the test; restart it.
	systemctl start xgs-npu-health.timer 2>/dev/null
	# Offload that was already on (boot autostart) stays on: leave the gate, flowtable and params as they were.
	[ "${PRE_ENABLED:-0}" = 1 ] && { echo "cleanup: offload was enabled before the hook; left ON"; return 0; }
	nft delete table inet "$TABLE" 2>/dev/null
	nft delete table ip xgsdnat 2>/dev/null
	{ echo N > /sys/module/octep/parameters/flow_offload; } 2>/dev/null
	{ echo N > /sys/module/octep/parameters/ft_offload_nat; echo N > /sys/module/octep/parameters/ft_nat_both; echo 0 > /sys/module/octep/parameters/ft_flags_extra; echo N > /sys/module/octep/parameters/ft_nat_ports0; echo 0 > /sys/module/octep/parameters/ft_mflow_extra; echo 0 > /sys/module/octep/parameters/ft_l3_rev; echo 1 > /sys/module/octep/parameters/ft_verdict; } 2>/dev/null
	echo 0 > "$DEV/rpc_allow_write" 2>/dev/null
	echo off > "$DEV/offload" 2>/dev/null
}
trap cleanup EXIT
ES=$(dirname "$0")/../octep/offload-end-summary.sh
ES_SNAP=$(mktemp 2>/dev/null) && [ -x "$ES" ] && "$ES" snap "$ES_SNAP"
# Name the signal if something stops the hook (it has exited with 143 twice, unexplained), in the log and dmesg.
for sig in TERM INT HUP; do
	trap "m=\"octep-test: HOOK-STOPPED by SIG$sig at \$(date +%T) (parent \$(ps -o args= -p \$PPID | cut -c1-80))\"; echo \"\$m\"; echo \"\$m\" > /dev/kmsg 2>/dev/null; exit 1" $sig
done

PARAM=/sys/module/octep/parameters/flow_offload
healthy() {
	case $(cat "$DEV/sdp_state" 2>/dev/null) in *rings=armed*handshake=completed*front_netdevs=[1-9]*) return 0 ;; esac
	return 1
}
busy() { pgrep -f 'sdp-bringup.sh|sdp-recover-npu.sh|rpc-port-setup.sh' >/dev/null; }

for _ in $(seq 1 20); do healthy && ! busy && break; sleep 2; done
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
PRE_ENABLED=0
if nft list flowtable inet xgs_offload ft >/dev/null 2>&1 && [ "$(cat "$DEV/rpc_allow_write" 2>/dev/null)" = 1 ] &&
	case $(cat "$DEV/offload" 2>/dev/null) in *requested=on*acknowledged=yes*) true ;; *) false ;; esac; then
	PRE_ENABLED=1
	echo "PRE-ENABLED: boot offload (xgs_offload flowtable, write gate open, firmware gate on) is already on; the hook reuses it and leaves it on"
	# /var/tmp/octep-hook-refresh containing 1 (item 7 A/B): re-run rpc-port-setup.sh with the gate closed, then reopen it, as the 17:33 run did.
	if [ "${OCTEP_HOOK_REFRESH:-0}" = 1 ] || [ "$(cat /var/tmp/octep-hook-refresh 2>/dev/null)" = 1 ]; then
		echo "REFRESH: closing gate, re-running rpc-port-setup.sh, reopening gate"
		echo 0 > "$DEV/rpc_allow_write"
		"$ROOT/scripts/octep/rpc-port-setup.sh" || { echo "FAIL: rpc-port-setup (refresh)" >&2; exit 1; }
		echo 1 > "$DEV/rpc_allow_write" && echo on > "$DEV/offload" || { echo "FAIL: gate (refresh)" >&2; exit 1; }
	fi
else
	"$ROOT/scripts/octep/rpc-port-setup.sh" || { echo "FAIL: rpc-port-setup" >&2; exit 1; }
	echo 1 > "$DEV/rpc_allow_write" && echo on > "$DEV/offload" || { echo "FAIL: gate" >&2; exit 1; }
fi
GATE_OPENED=1
# xgs-npu-health.timer's periodic sensor read shares the firmware RPC port with flow
# control; it is the likely source of periodic stalls seen mid-test (item 7). Stop it
# for the test window; cleanup() restarts it on exit.
systemctl stop xgs-npu-health.timer 2>/dev/null
echo "gate: $(cat "$DEV/offload")"
DBGSTATS=/sys/kernel/debug/octep/stats
echo "== P5 stats before"; cat $DBGSTATS 2>/dev/null || echo "P5 stats: debugfs file missing (module without P5?)"
echo "stack-protector: $(dmesg 2>/dev/null | grep -F 'stack protector' | tail -1 | cut -c1-120)"
echo "ft_two_step=$(cat /sys/module/octep/parameters/ft_two_step 2>/dev/null) ft_two_step_ms=$(cat /sys/module/octep/parameters/ft_two_step_ms 2>/dev/null) ft_seq_chk=$(cat /sys/module/octep/parameters/ft_seq_chk 2>/dev/null)"

if [ "$PRE_ENABLED" = 0 ]; then
nft add table inet "$TABLE"
nft add flowtable inet "$TABLE" ft "{ hook ingress priority 0; devices = { $LAN, $WAN }; flags offload; }" ||
	{ echo "FAIL: flowtable bind" >&2; exit 1; }
nft add chain inet "$TABLE" hookfw "{ type filter hook forward priority 0; policy accept; }"
nft add rule inet "$TABLE" hookfw ct state established flow add @ft
fi
# Read a plain number (decimal or 0x hex) from a file; anything else yields 0, so a planted file cannot inject shell arithmetic.
num() { v=$(head -c 32 "$1" 2>/dev/null); case $v in ''|*[!0-9a-fA-FxX]*) echo 0 ;; *) echo "$((v))" ;; esac; }
# Flag-bit probe: a number in /var/tmp/octep-ft-flags-extra (e.g. 0x40000) is ORed into the flow-create flags.
num /var/tmp/octep-ft-flags-extra > /sys/module/octep/parameters/ft_flags_extra 2>/dev/null
# /var/tmp/octep-ft-ports0 containing 1 writes zero NAT-block ports for the run.
if [ "$(cat /var/tmp/octep-ft-ports0 2>/dev/null)" = 1 ]; then echo Y > /sys/module/octep/parameters/ft_nat_ports0; fi
num /var/tmp/octep-ft-mflow-extra > /sys/module/octep/parameters/ft_mflow_extra 2>/dev/null
num /var/tmp/octep-ft-l3-rev > /sys/module/octep/parameters/ft_l3_rev 2>/dev/null
if [ "$(cat /var/tmp/octep-ft-tcp-state 2>/dev/null)" = 1 ]; then echo Y > /sys/module/octep/parameters/ft_tcp_state; else echo N > /sys/module/octep/parameters/ft_tcp_state; fi 2>/dev/null
{ echo "${OCTEP_FT_VERDICT:-1}" > /sys/module/octep/parameters/ft_verdict; } 2>/dev/null
echo "verdict=${OCTEP_FT_VERDICT:-1}"
# Regressed to the committed c591b5f behaviour (it set only the single verdict bit, no brctl nibble, no offload delay, no staged cut-in);
# every experiment since kept the same stall. Override with OCTEP_FT_BRCTL / OCTEP_FT_DELAY_MS / OCTEP_FT_CUTIN.
{ echo "${OCTEP_FT_BRCTL:-0}" > /sys/module/octep/parameters/ft_brctl; } 2>/dev/null
{ echo "${OCTEP_FT_DELAY_MS:-0}" > /sys/module/octep/parameters/ft_delay_ms; } 2>/dev/null
echo "baseline params: ft_brctl=$(cat /sys/module/octep/parameters/ft_brctl) ft_delay_ms=$(cat /sys/module/octep/parameters/ft_delay_ms)"
# Regressed: the staged cut-in (1) stalled live flows after its flip; straight-to-forward (0) is the default until it is proven better.
{ echo "${OCTEP_FT_CUTIN:-0}" > /sys/module/octep/parameters/ft_cutin; } 2>/dev/null
echo "ft_cutin=$(cat /sys/module/octep/parameters/ft_cutin)"
echo "l3_rev=$(cat /sys/module/octep/parameters/ft_l3_rev 2>/dev/null)"
# Change G: once the NPU forwards the original direction, host conntrack never sees that data, so the later server ACKs look out of window (INVALID) and are dropped. Liberal mode keeps them; the invalid counter delta below shows whether it happened.
ct_invalid() { awk 'NR>1{ s += strtonum("0x"$5) } END{print s+0}' /proc/net/stat/nf_conntrack 2>/dev/null; }
{ echo "${OCTEP_CT_LIBERAL:-1}" > /proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal; } 2>/dev/null
echo "nf_conntrack_tcp_be_liberal=$(cat /proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal 2>/dev/null)"
CT_INVALID0=$(ct_invalid)
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
# Review captures: TCP port 5201 headers (96 bytes) on both ports; each stops by itself after the window.
mkdir -p "$PCAP_DIR"
TD_PIDS=""
for ifc in "$LAN" "$WAN"; do
	tcpdump -nn -i "$ifc" -Z root -B 262144 -s 96 -c 250000 -w "$PCAP_DIR/$PCAP_TAG-$ifc.pcap" tcp port 5201 >/dev/null 2>"$LOGDIR/$PCAP_TAG-tcpdump-$ifc.err" &
	TD_PIDS="$TD_PIDS $!"
done
# Full-length frames (about 30 MB) of the first 20000 packets on the WAN port, so the TCP checksum of NPU-forwarded frames can be verified (the 96-byte captures cannot).
tcpdump -nn -i "$WAN" -Z root -s 0 -c 60000 -w "$PCAP_DIR/$PCAP_TAG-full-$WAN.pcap" tcp port 5201 >/dev/null 2>>"$LOGDIR/$PCAP_TAG-tcpdump-$WAN.err" &
TD_PIDS="$TD_PIDS $!"
sleep 2
for ifc in "$LAN" "$WAN"; do
	if [ -f "$PCAP_DIR/$PCAP_TAG-$ifc.pcap" ]; then m="PCAP-START ok $PCAP_DIR/$PCAP_TAG-$ifc.pcap"; else m="PCAP-START FAILED for $ifc: $(head -c 200 "$LOGDIR/$PCAP_TAG-tcpdump-$ifc.err" | tr '\n' ' ')"; fi
	echo "$m"; echo "octep-test: $m" > /dev/kmsg 2>/dev/null
done
# Gate watcher: one line, with a time, on every change of the offload gate or its params. It also
# lists the scripts that could have written them, so an unexpected change names its source.
(
	prev=""
	end=$((SECONDS + SECS + 5))
	while [ "$SECONDS" -lt "$end" ]; do
		cur="flow_offload=$(cat /sys/module/octep/parameters/flow_offload 2>/dev/null) verdict=$(cat /sys/module/octep/parameters/ft_verdict 2>/dev/null) nat=$(cat /sys/module/octep/parameters/ft_offload_nat 2>/dev/null) cutin=$(cat /sys/module/octep/parameters/ft_cutin 2>/dev/null) write_gate=$(cat "$DEV/rpc_allow_write" 2>/dev/null) fw_gate=[$(cat "$DEV/offload" 2>/dev/null)]"
		if [ "$cur" != "$prev" ]; then
			state=OFFLOAD-OFF
			case "$cur" in *flow_offload=Y*write_gate=1*requested=on*acknowledged=yes*) state=OFFLOAD-ON ;; esac
			msg="GATE-EVENT $(date +%T.%3N) $state $cur"
			echo "$msg"
			echo "octep-test: $msg" > /dev/kmsg 2>/dev/null
			[ -z "$prev" ] || echo "GATE-EVENT   writers running: $(pgrep -fa 'offload-enable|offload-check|octep-fastdeploy|rpc-port-setup|sdp-recover|sdp-status|octep-hook-live' | grep -v pgrep | cut -c1-90 | tr '\n' ';')"
			prev="$cur"
		fi
		sleep 1
	done
) &
# A false test is worse than none: refuse READY unless the gate is on, and flag flows that already exist.
gate=$(cat "$DEV/offload")
case "$gate" in *requested=on*acknowledged=yes*) ;; *) echo "FAIL: gate is not on+acknowledged ($gate); do not start iperf" >&2; exit 1;; esac
[ "$(cat "$PARAM")" = Y ] || { echo "FAIL: flow_offload is not Y; do not start iperf" >&2; exit 1; }
pre=$(grep -c dport=5201 /proc/net/nf_conntrack)
[ "$pre" -eq 0 ] || echo "WARNING: $pre port-5201 flow(s) already in conntrack; a flow that predates this hook is never offloaded by the NPU. Start iperf with a new source port."
echo "GATE ON: flow_offload=Y ft_offload_nat=$(cat /sys/module/octep/parameters/ft_offload_nat) $gate"
echo "READY: start a NEW iperf3 from the LAN host now (${SECS}s window)"
# Live ground-truth check: the moment an "offloaded conn" line appears, query the firmware's own
# LO_MFLOW_READ for both microflow ids (not our pre-send dump) to settle whether state=2 actually
# landed in the live table, instead of inferring it from what we wrote.
(
	# Kernel lines only (never the hook's own octep-test echoes), read once a second; one NPU readback at
	# offload, then one per second for 40 s (allocation/timestamp monitor), and one at release, each written to the log and to dmesg.
	n_seen=0; follow=0; next=0; oid=; rid=; conn=
	npu_alloc() {
		label=$1; out="NPU-ALLOC $label conn=$conn"
		for tag_id in "orig:$oid" "reply:$rid"; do
			tag=${tag_id%%:*}; id=${tag_id#*:}
			[ -n "$id" ] || continue
			echo "$id" > "$DEV/rpc_mflow_read" 2>/dev/null
			raw=$(cat "$DEV/rpc_mflow_read" 2>/dev/null)
			echo "mflow-live-readback $tag id=$id: $raw"
			out="$out | $tag id=$id $(echo "$raw" | grep -oE '(fw_valid|host_valid|action|state|connection|next_hop|timestamp)=[^ ]+' | tr '\n' ' ')"
		done
		out="$out | flow_stats $(grep -oE '(tracked|stale|untracked|conn_stats_entries|last_age_ms)=[0-9]+' "$DEV/flow_stats" 2>/dev/null | tr '\n' ' ')"
		echo "$out"
		echo "octep-test: $out" > /dev/kmsg 2>/dev/null
	}
	end=$((SECONDS + SECS + 5))
	while [ "$SECONDS" -lt "$end" ]; do
		lines=$(dmesg --time-format iso --since "@$MARK" 2>/dev/null | grep -E "octep 0000:01:00.0: ft: (offloaded|released) conn")
		total=$(printf '%s' "$lines" | grep -c .)
		if [ "$total" -gt "$n_seen" ]; then
			printf '%s\n' "$lines" | tail -n +$((n_seen + 1)) | while read -r line; do echo "$line"; done > "$LOGDIR/.ft-new.$$"
			while read -r line; do
				conn=$(echo "$line" | grep -oP 'conn \K[0-9]+')
				case "$line" in
				*offloaded*)
					oid=$(echo "$line" | grep -oP 'orig id \K[0-9]+'); rid=$(echo "$line" | grep -oP 'reply id \K[0-9]+')
					npu_alloc offload; follow=40; t0=$SECONDS; next=$((SECONDS + 1)) ;;
				*released*) npu_alloc release; follow=0 ;;
				esac
			done < "$LOGDIR/.ft-new.$$"
			rm -f "$LOGDIR/.ft-new.$$"
			n_seen=$total
		fi
		if [ "$follow" -gt 0 ] && [ "$SECONDS" -ge "$next" ]; then
			npu_alloc "+$((SECONDS - t0))s"; follow=$((follow - 1)); next=$((SECONDS + 1))
		fi
		# Always on: allocated-flow counters every second, offloaded or not.
		fa="FLOW-ALLOC $(date +%T) $(grep -oE '(tracked|stale|untracked|conn_stats_entries|last_age_ms)=[0-9]+' "$DEV/flow_stats" 2>/dev/null | tr '\n' ' ')conns_ft=$(dmesg --time-format iso --since "@$MARK" 2>/dev/null | grep -cE 'ft: offloaded conn') released=$(dmesg --time-format iso --since "@$MARK" 2>/dev/null | grep -cE 'ft: released conn')"
		echo "$fa"; echo "octep-test: $fa" > /dev/kmsg 2>/dev/null
		sleep 1
	done
) &
# per-second NPU counter deltas, as the agent reports them (WIRE_TO_WIRE rising = NPU forwarding)
python3 - "$ROOT" "$SECS" "$MARK" "$LAN" "$WAN" <<'PY' &
import sys, time, subprocess, re, importlib.util as u
root, secs, mark, lan, wan = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
took = 0
def say(msg):
    # Verification lines go to the log and to dmesg, so one dmesg capture holds the whole verdict.
    print(msg, flush=True)
    try:
        open("/dev/kmsg", "w").write("octep-test: " + msg[:900] + "\n")
    except OSError:
        pass
loadpend = []   # [tag, event time]: NPU load is reported once a sample after the event exists
def hostrx():
    t = 0
    for ifc in (lan, wan):
        try:
            t += int(open(f"/sys/class/net/{ifc}/statistics/rx_packets").read())
        except OSError:
            pass
    return t
hprev = hostrx()
import threading
loads = []   # (time, npu cpu busy %, 1-min load)
def npu_sampler():
    cmd = 'head -n 1 /proc/stat; cat /proc/loadavg'
    last = None
    while True:
        try:
            out = subprocess.run([f"{root}/scripts/xgs/npu-run.sh", "8", cmd], capture_output=True, text=True, timeout=12).stdout.splitlines()
            st = next(l for l in out if l.startswith("cpu ")).split()[1:9]
            st = [int(x) for x in st]
            la = next(l for l in out if re.match(r"^[0-9.]+ [0-9.]+ [0-9.]+ ", l)).split()[0]
            if last:
                tot = sum(st) - sum(last); idle = (st[3] + st[4]) - (last[3] + last[4])
                if tot > 0:
                    loads.append((time.time(), 100.0 * (tot - idle) / tot, la))
                    print(f"{time.strftime('%H:%M:%S')} npu-load: cpu_busy={loads[-1][1]:.1f}% load1={la}", flush=True)
            last = st
        except Exception as e:
            print(f"{time.strftime('%H:%M:%S')} npu-load: sample failed: {type(e).__name__} {str(e)[:60]}", flush=True)
        time.sleep(5)
threading.Thread(target=npu_sampler, daemon=True).start()
def load_near(t0, t1):
    v = [b for (t, b, _) in loads if t0 <= t <= t1]
    return (sum(v) / len(v)) if v else None
def flush_load(final):
    # Low-rate NPU load: nearest sample before the event vs the first one after it; no guessing if a side is missing.
    for p in list(loadpend):
        tag, t_ev = p
        before = [b for (t, b, _) in loads if t <= t_ev]
        after = [b for (t, b, _) in loads if t > t_ev]
        if after or final or time.time() > t_ev + 40:
            f = lambda v: "n/a" if not v else f"{v[-1] if v is before else v[0]:.0f}%"
            say(f"TAKEOVER-LOAD {tag}: NPU cpu busy {f(before)} (last sample before) -> {f(after)} (first sample after)")
            loadpend.remove(p)
spec = u.spec_from_file_location("c", f"{root}/scripts/tests/octep-offload-commission.py")
c = u.module_from_spec(spec); spec.loader.exec_module(c)
KEY = ["HOST_RX", "RX_WIRE", "TX_WIRE", "RX_KN", "TX_KN", "WIRE_TO_WIRE", "NON_ACCEL", "FORCED", "MFLOW_NOT_ACTIVE", "TX_DROP"]
prev = c.counters()
hist = []          # per-second deltas, newest last
pending = []       # [tag, second index at event, text]
seen = set()
def events():
    out = subprocess.run(["dmesg", "--time-format", "iso", "--since", "@" + mark], capture_output=True, text=True).stdout
    for ln in out.splitlines():
        if re.search(r"octep 0000:01:00\.0: ft: (offloaded conn|cut-in conn \d+ done|released conn|cut-in conn \d+ waiting)", ln) and ln not in seen:
            seen.add(ln)
            yield ln
def avg(rows, k):
    return sum(r.get(k, 0) for r in rows) / max(len(rows), 1)
def report(tag, idx, line, t_ev):
    before, after = hist[max(0, idx - 3):idx], hist[idx:idx + 3]
    cols = " ".join(f"{k}={avg(before,k):.0f}->{avg(after,k):.0f}" for k in KEY)
    say(f"TAKEOVER-REPORT {tag} (pkts/s, 3s before -> 3s after): {cols}")
    loadpend.append([tag, t_ev])
    # Proof = the host kernel stops seeing the flow's frames while the NPU keeps moving them wire to wire.
    hb, ha = avg(before, "HOST_RX"), avg(after, "HOST_RX")
    wb, wa = avg(before, "RX_WIRE"), avg(after, "RX_WIRE")
    w2w = avg(after, "WIRE_TO_WIRE")
    byp = avg(after, "RX_WIRE") - avg(after, "RX_KN")
    traffic = wa > 1000
    host_fell = hb > 1000 and ha < 0.2 * hb
    npu_fwd = w2w > 1000 or byp > 1000
    why = []
    if not traffic: why.append("no traffic after")
    if not host_fell: why.append(f"host rx did not fall ({hb:.0f}->{ha:.0f}/s)")
    if not npu_fwd: why.append(f"NPU not forwarding (wire-to-wire {w2w:.0f}/s, wire-minus-kernel {byp:.0f}/s)")
    global took
    # One plain state per takeover: forwarding in the NPU, stalled, or still on the host path.
    if not why:
        state = "OFFLOADING (NPU forwarding, host no longer carries the flow)"
    elif wb > 1000 and wa < 0.1 * wb:
        state = f"STALLING (traffic collapsed {wb:.0f}->{wa:.0f}/s after takeover)"
    elif not npu_fwd and traffic:
        state = "HOST-PATH (traffic flows but the NPU is not forwarding it)"
    else:
        state = "NO-TRAFFIC"
    say(f"TAKEOVER-STATE {tag}: {state}")
    if not why:
        took += 1
        say(f"OFFLOAD-PROOF YES {tag}: host rx {hb:.0f}->{ha:.0f}/s while NPU wire-to-wire {w2w:.0f}/s (wire-minus-kernel {byp:.0f}/s)")
    else:
        say(f"OFFLOAD-PROOF NO {tag}: " + "; ".join(why))
for _ in range(secs):
    time.sleep(1)
    now = c.counters()
    names = {k: i for i, k in c.NAMES.items()}
    d = {c.NAMES.get(i, f"#{i}"): now[i] - prev.get(i, 0) for i in now if now[i] != prev.get(i, 0)}
    h = hostrx(); d["HOST_RX"] = h - hprev; hprev = h
    hist.append(d)
    if d:
        print(time.strftime("%H:%M:%S"), "npu:", d, flush=True)
    prev = now
    for ln in events():
        m = re.search(r"ft: (offloaded conn \d+|cut-in conn \d+ done[^\n]*|released conn \d+|cut-in conn \d+ waiting[^\n]*)", ln)
        tag = m.group(1) if m else ln[-60:]
        say(f"TAKEOVER-EVENT {time.strftime('%H:%M:%S')} {tag}")
        if not tag.startswith("cut-in conn") or "done" in tag or tag.startswith("offloaded"):
            pending.append([tag, len(hist), ln, time.time()])
    for p in list(pending):
        if len(hist) >= p[1] + 3:
            report(p[0], p[1], p[2], p[3]); pending.remove(p)
    flush_load(False)
for p in pending:
    report(p[0], p[1], p[2], p[3])
flush_load(True)
say("OFFLOAD-PROOF SUMMARY: " + (f"{took} takeover(s) proven" if took else "NONE proven - do not treat this run as an offload result"))
PY
# Wait for the analysis only; the size-capped captures never end by themselves, so stop them here.
wait $!
[ -n "$TD_PIDS" ] && kill $TD_PIDS 2>/dev/null
wait

echo "== hook dmesg"
dmesg --time-format iso --since "@$MARK" 2>/dev/null | grep -E "octep 0000:01:00.0: ft:|octep.*ft: |ft: dbg" | tail -80
echo "CT-INVALID delta during run: $(( $(ct_invalid) - CT_INVALID0 ))"
echo "== conntrack"
grep dport=5201 /proc/net/nf_conntrack | cut -c1-250
if dmesg --time-format iso --since "@$MARK" 2>/dev/null | grep -qF "offloaded conn"; then
	echo "RESULT: VALID - the driver offloaded at least one flow in this window"
else
	echo "RESULT: INVALID - no 'ft: offloaded conn' this window; the flow predates the hook or never qualified. Discard this run and its captures."
fi
echo "== P5 stats after"; cat $DBGSTATS 2>/dev/null
echo "== counters"
cat "$DEV/offload"
grep -E "WIRE_TO_WIRE|CONN_RECLAIMED|MFLOW_NOT_ACTIVE" "$DEV"/rpc_sys_counters 2>/dev/null | head
# octep-offload-check.sh prints its own end summary after the run summary.
[ -z "${OCTEP_END_SUMMARY:-}" ] && [ -x "$ES" ] && "$ES" report "$ES_SNAP"
rm -f "$ES_SNAP"
