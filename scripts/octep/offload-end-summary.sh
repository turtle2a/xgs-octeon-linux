#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 turtle2a <354865938+turtle2a@users.noreply.github.com>
# Read-only end-of-run summary shared by the offload test scripts: NPU counter deltas
# (RX_WIRE, WIRE_TO_WIRE, ...), offload/cut-in settings, frozen-reply events and a PASS/FAIL line.
#   offload-end-summary.sh snap FILE      record counters and time at the start of a run
#   offload-end-summary.sh report FILE    print the deltas since "snap" (call last)
#   offload-end-summary.sh log HOOKLOG    totals from a finished hook run's per-second samples
# PASS = the NPU forwarded wire-to-wire (>= 1% of RX_WIRE) and no reply microflow was frozen.
# Exit status is always 0; callers keep their own exit codes.
set -u
DEV=${OCTEP_PF:-/sys/bus/pci/devices/0000:01:00.0}
PAR=/sys/module/octep/parameters

cnt() { sed -n "s/^$1=//p" "$DEV/rpc_sys_counters" 2>/dev/null | head -1; }
param() { cat "$PAR/$1" 2>/dev/null || echo "?"; }
kcount() { journalctl -k --since "$1" --no-pager 2>/dev/null | grep -c "$2"; }

block() { # label rx tx w2w kn mfna frozen offloaded
	local label=$1 rx=$2 tx=$3 w2w=$4 kn=$5 mf=$6 frozen=$7 offl=$8 pct verdict
	pct=$(awk -v a="$w2w" -v b="$rx" 'BEGIN { printf "%.3f", (b > 0) ? a * 100 / b : 0 }')
	if [ "$rx" -lt 1000 ]; then
		verdict="NO TRAFFIC SEEN - run invalid"
	elif [ "$frozen" != n/a ] && [ "$frozen" -gt 0 ]; then
		verdict="FAIL - reply microflow frozen ($frozen events)"
	elif awk -v a="$w2w" -v b="$rx" 'BEGIN { exit !(a * 100 >= b) }'; then
		verdict="PASS - NPU forwarded wire-to-wire"
	else
		verdict="FAIL - wire-to-wire ${pct}% of RX_WIRE (< 1%)"
	fi
	echo
	echo "################ END SUMMARY ($label) ################"
	echo "settings:  $(cat "$DEV/offload" 2>/dev/null | cut -c1-90)"
	echo "           flow_offload=$(param flow_offload) ft_cutin=$(param ft_cutin) ft_cutin_ms=$(param ft_cutin_ms) ft_verdict=$(param ft_verdict) ft_session_rev=$(param ft_session_rev)"
	echo "counters:  RX_WIRE=$rx TX_WIRE=$tx WIRE_TO_WIRE=$w2w RX_KN=$kn MFLOW_NOT_ACTIVE=$mf"
	echo "           WIRE_TO_WIRE = ${pct}% of RX_WIRE"
	echo "events:    ft offloaded=$offl  reply-microflow-frozen=$frozen"
	echo "VERDICT:   $verdict"
}

case ${1:-} in
snap)
	f=${2:?usage: $0 snap FILE}
	{
		echo "epoch=$(date +%s)"
		for i in 0 1 2 3 12; do echo "c$i=$(cnt $i)"; done
	} >"$f" 2>/dev/null
	;;
report)
	f=${2:?usage: $0 report FILE}
	[ -s "$f" ] || { echo "end-summary: no start snapshot ($f)"; exit 0; }
	g() { sed -n "s/^$1=//p" "$f" | head -1; }
	since=$(date -d "@$(g epoch)" '+%F %T')
	d() { echo $(($(cnt "$1") - $(g "c$1"))); }
	block "since $since" "$(d 0)" "$(d 1)" "$(d 2)" "$(d 3)" "$(d 12)" \
		"$(kcount "$since" 'reply microflow frozen')" "$(kcount "$since" 'ft: offloaded conn')"
	;;
log)
	hl=${2:?usage: $0 log HOOKLOG}
	[ -s "$hl" ] || { echo "end-summary: no hook log ($hl)"; exit 0; }
	stamp=$(basename "$hl" .log); stamp=${stamp#hook-}
	since=$(date -d "${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2}" '+%F %T' 2>/dev/null)
	read -r rx tx w2w kn mf < <(python3 - "$hl" <<'PY'
import ast, re, sys
t = dict.fromkeys(("RX_WIRE", "TX_WIRE", "WIRE_TO_WIRE", "RX_KN", "MFLOW_NOT_ACTIVE"), 0)
for line in open(sys.argv[1], errors="replace"):
    m = re.search(r"npu: (\{.*\})", line)
    if not m:
        continue
    try:
        d = ast.literal_eval(m.group(1))
    except Exception:
        continue
    for k in t:
        t[k] += int(d.get(k, 0))
print(*t.values())
PY
	)
	block "hook run $stamp (sampled seconds)" "${rx:-0}" "${tx:-0}" "${w2w:-0}" "${kn:-0}" "${mf:-0}" \
		"$([ -n "$since" ] && kcount "$since" 'reply microflow frozen' || echo n/a)" \
		"$([ -n "$since" ] && kcount "$since" 'ft: offloaded conn' || echo n/a)"
	;;
*)
	echo "usage: $0 snap FILE | report FILE | log HOOKLOG" >&2
	;;
esac
exit 0
