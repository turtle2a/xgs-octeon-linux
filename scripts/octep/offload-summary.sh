#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 turtle2a <354865938+turtle2a@users.noreply.github.com>
# One-page summary of an octep-hook-live.sh run for review: gate, allocation (driver claim vs NPU
# readback vs NPU flow_stats), takeover state and proof, NPU load, per-second pcap counts around the
# offload, and a CROSS-CHECK verdict. Read-only; no sudo needed.
# Usage: octep-offload-summary.sh [run-tag]   (tag = takeover-YYYYMMDD-HHMMSS; default: latest run)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LOGDIR=$ROOT/testlogs/hook-runs
CAP=$ROOT/testlogs/captures
DEV=/sys/bus/pci/devices/0000:01:00.0

if [ -n "${1:-}" ]; then
	stamp=${1#takeover-}
	HL=$LOGDIR/hook-$stamp.log
else
	HL=$(ls -t "$LOGDIR"/hook-*.log 2>/dev/null | head -1)
	stamp=$(basename "$HL" .log); stamp=${stamp#hook-}
fi
[ -f "$HL" ] || { echo "no hook log found in $LOGDIR" >&2; exit 1; }
since="${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2}"
hdr() { printf '\n== %s\n' "$1"; }

echo "RUN SUMMARY  tag=takeover-$stamp  started=$since"
echo "hook log: $HL"

hdr "1. GATE / OFFLOAD-ON (when)"
grep -E "^GATE-EVENT [0-9:.]+ OFFLOAD|baseline params|^verdict=|^ft_cutin=|HOOK-STOPPED" "$HL" | cut -c1-210

# Kernel lines only (the hook echoes its own verdicts into dmesg, which must not count as events).
KLOG=$(journalctl -k --since "$since" --no-pager 2>/dev/null | grep -E " kernel: ")
hdr "2. ALLOCATION: driver claim (kernel log)"
printf '%s\n' "$KLOG" | grep -E "ft: (offloaded|cut-in|released|conn [0-9]+ (firmware-active|reply microflow frozen))" | cut -c1-215
n_off=$(printf '%s\n' "$KLOG" | grep -c "ft: offloaded conn")
n_rel=$(printf '%s\n' "$KLOG" | grep -c "ft: released conn")
echo "driver: offloaded=$n_off released=$n_rel"

hdr "3. ALLOCATION: NPU firmware readback (rpc_mflow_read)"
first_o=$(grep "mflow-live-readback orig" "$HL" | head -1); last_o=$(grep "mflow-live-readback orig" "$HL" | tail -1)
first_r=$(grep "mflow-live-readback reply" "$HL" | head -1); last_r=$(grep "mflow-live-readback reply" "$HL" | tail -1)
kv() { printf '%s' "$1" | grep -oE "(^| )$2=[^ ]+" | head -1 | cut -d= -f2; }
for w in orig reply; do
	f=$([ $w = orig ] && echo "$first_o" || echo "$first_r"); l=$([ $w = orig ] && echo "$last_o" || echo "$last_r")
	if [ -z "$f" ]; then echo "$w: NO NPU readback captured"; continue; fi
	echo "$w: id=$(kv "$f" requested_index) fw_valid=$(kv "$f" fw_valid) action=$(kv "$f" action) state=$(kv "$f" state) conn=$(kv "$f" connection) next_hop=$(kv "$f" next_hop) timestamp $(kv "$f" timestamp) -> $(kv "$l" timestamp)"
done
ts_o0=$(kv "$first_o" timestamp); ts_o1=$(kv "$last_o" timestamp); ts_r0=$(kv "$first_r" timestamp); ts_r1=$(kv "$last_r" timestamp)
[ -n "$ts_o0" ] && echo "NPU hit counters: orig $([ "$ts_o0" != "$ts_o1" ] && echo MOVING || echo FROZEN), reply $([ "$ts_r0" != "$ts_r1" ] && echo MOVING || echo FROZEN)"

hdr "4. ALLOCATION: NPU flow-stat messages to host (flow_stats, now)"
cat "$DEV/flow_stats" 2>/dev/null | cut -c1-230

hdr "5. TAKEOVER STATE + PROOF (first of each; duplicates from older hook builds removed)"
grep -E "TAKEOVER-(STATE|REPORT|LOAD)|OFFLOAD-PROOF" "$HL" | awk '!s[$0]++' | head -6 | cut -c1-330
grep -h "OFFLOAD-PROOF SUMMARY" "$HL" | tail -1

hdr "6. NPU LOAD (low-rate samples)"
grep -E "npu-load: cpu_busy" "$HL" | awk '{print}' | sed -E 's/.*cpu_busy=([0-9.]+)%.*/\1/' | awk 'NF{n++; s+=$1; if(min==""||$1<min)min=$1; if($1>max)max=$1} END{ if(n) printf "samples=%d busy%% min=%.1f avg=%.1f max=%.1f\n", n,min,s/n,max; else print "no NPU load samples captured" }'

hdr "7. PCAP (packets/s; data = packets carrying payload) around the offload"
off_line=$(printf '%s\n' "$KLOG" | grep "ft: offloaded conn" | head -1)
if [ -n "$off_line" ]; then
	off_ep=$(date -d "$(printf '%s' "$off_line" | awk '{print $1,$2,$3}')" +%s)
	for p in octep0 octep1; do
		f=$CAP/takeover-$stamp-$p.pcap
		if [ ! -s "$f" ]; then echo "$p: no pcap ($f)"; continue; fi
		echo "$p  (offload at +0s; reply = from :5201)"
		tcpdump -nn -tt -r "$f" 2>/dev/null | awk -v off="$off_ep" '
			{ s=int($1)-off; if (s<-3||s>10) next
			  n[s]++; rep=($3 ~ /\.5201$/); if (rep) r[s]++
			  if ($NF+0>0) { d[s]++; if (rep) rd[s]++ } }
			END { for (s=-3;s<=10;s++) printf "  %+3ds pkts=%-6d data=%-6d reply_pkts=%-6d reply_data=%d\n", s, n[s]+0, d[s]+0, r[s]+0, rd[s]+0 }'
	done
else
	echo "no offload in the kernel log for this run"
fi

hdr "8. CROSS-CHECK (driver claim vs NPU readback vs traffic)"
why=()
[ "$n_off" -ge 1 ] || why+=("driver never offloaded a conn")
[ "$(kv "$first_o" fw_valid)" = 1 ] && [ "$(kv "$first_r" fw_valid)" = 1 ] || why+=("NPU readback: microflows not fw_valid")
[ "$(kv "$first_o" action)" = 1 ] && [ "$(kv "$first_r" action)" = 1 ] || why+=("NPU readback: action is not forward on both")
[ -n "$ts_r0" ] && [ "$ts_r0" != "$ts_r1" ] || why+=("NPU reply microflow hit counter frozen/absent (reply direction not forwarded)")
grep -q "OFFLOAD-PROOF YES" "$HL" || why+=("no OFFLOAD-PROOF YES (host rx never fell while the NPU forwarded)")
tracked=$(grep -oE "tracked=[0-9]+" "$DEV/flow_stats" 2>/dev/null | head -1 | cut -d= -f2)
[ "${tracked:-0}" -ge 1 ] || why+=("NPU flow_stats tracked=${tracked:-?} (no per-flow stats reported by the NPU)")
if [ ${#why[@]} -eq 0 ]; then
	echo "CROSS-CHECK AGREE: allocation, forwarding and NPU reporting all confirm the NPU is offloading"
else
	echo "CROSS-CHECK DISAGREE:"; printf '  - %s\n' "${why[@]}"
fi
hdr "files"
ls -la "$CAP"/takeover-$stamp-* "$LOGDIR"/*"$stamp"* 2>/dev/null | awk '{print $5, $9}'
