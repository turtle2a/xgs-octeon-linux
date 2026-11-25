#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# One-command offload check: runs the live hook for a window, then prints the one-page run
# summary (gate, allocation, NPU readback, takeover proof, NPU load, per-second pcap counts,
# CROSS-CHECK verdict). Prompts first; start a NEW iperf3 from a client behind the LAN port when
# it says READY. To re-read the last run without testing, use octep-offload-last.sh.
# The hook leaves offload ON if it was on before. Needs root.
#   octep-offload-check.sh [seconds] [LAN_IF] [WAN_IF]     (defaults: 30 octep0 octep1)
# Exit 0 = CROSS-CHECK AGREE, 1 = DISAGREE or no valid run, 2 = could not run.
set -uo pipefail

SECS=${1:-30}
LAN=${2:-octep0}
WAN=${3:-octep1}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LOGDIR=$ROOT/testlogs/hook-runs

[ "$(id -u)" -eq 0 ] || { echo "SUDO REQUIRED: sudo $0 $*" >&2; exit 2; }
case $SECS in '' | *[!0-9]*) echo "usage: $0 [seconds] [LAN_IF] [WAN_IF]" >&2; exit 2 ;; esac

IPERF_CMD=${IPERF_CMD:-iperf3 -B <LAN_CLIENT_IP> -c <WAN_SERVER_IP> -t $SECS}
echo "On the LAN client, have this ready (do NOT start it yet):"
echo "    $IPERF_CMD"
read -r -p "Press Enter to open the ${SECS}s window, then start it when you see READY... " _ || true

before=$(ls -t "$LOGDIR"/hook-*.log 2>/dev/null | head -1)
ES=$ROOT/scripts/octep/offload-end-summary.sh
ES_SNAP=$(mktemp 2>/dev/null) && [ -x "$ES" ] && "$ES" snap "$ES_SNAP"
OCTEP_END_SUMMARY=1 "$ROOT/scripts/tests/octep-hook-live.sh" "$LAN" "$WAN" "$SECS"
hook_rc=$?
after=$(ls -t "$LOGDIR"/hook-*.log 2>/dev/null | head -1)
if [ "$hook_rc" -ne 0 ] || [ -z "$after" ] || [ "$after" = "$before" ]; then
	echo "the hook did not complete (rc=$hook_rc); no summary. If another run was still finishing, wait a minute and retry." >&2
	[ -n "$after" ] && [ "$after" != "$before" ] && rm -f "$after"
	exit 2
fi

stamp=$(basename "$after" .log)
echo
echo "################ RUN SUMMARY ################"
out=$("$ROOT/scripts/octep/offload-summary.sh" "takeover-${stamp#hook-}" 2>&1)
printf '%s\n' "$out"
[ -x "$ES" ] && "$ES" report "$ES_SNAP"
rm -f "$ES_SNAP"
printf '%s\n' "$out" | grep -q "CROSS-CHECK AGREE" && exit 0
exit 1
