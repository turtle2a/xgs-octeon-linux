#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 turtle2a <354865938+turtle2a@users.noreply.github.com>
# One offload commissioning cycle (read-only): open the gate, drive traffic via
# the octep3 binding (the only one that has produced candidates), wait for new firmware candidates, and read each
# microflow while it is still live. The gate is always closed on exit.
# Usage: sudo scripts/tests/octep-offload-loop.sh [target-ip] [seconds]
set -u
PF=${PF:-/sys/bus/pci/devices/0000:01:00.0}
TARGET=${1:-192.168.1.1}
SECS=${2:-25}
SRC_IF=${SRC_IF:-octep3}

if [ "$(id -u)" -ne 0 ]; then
	echo "SUDO REQUIRED: sudo $0 $*" >&2
	exit 1
fi

stat() { sed -n 's/.*[ ^]\(rx_frames=[0-9]*\).*metadata_valid=\([0-9]*\).*/\1 md=\2/p' "$PF/rx_flow" | head -1; }
mdcount() { grep -o 'metadata_valid=[0-9]*' "$PF/rx_flow" | head -1 | cut -d= -f2; }

trap 'echo off >"$PF/offload"; echo "gate: $(cat "$PF/offload")"' EXIT
ES=$(dirname "$0")/../octep/offload-end-summary.sh
ES_SNAP=$(mktemp 2>/dev/null) && [ -x "$ES" ] && "$ES" snap "$ES_SNAP"

before=$(mdcount)
echo on >"$PF/offload"
echo "gate: $(cat "$PF/offload")  md_before=$before"
sleep 2

ping -I "$SRC_IF" -c $((SECS * 3)) -i 0.33 "$TARGET" >/dev/null 2>&1 &
for p in 5301 5302 5303; do
	(echo x | timeout 1 nc -u -s "$(ip -4 -o addr show dev "$SRC_IF" | awk '{print $4}' | cut -d/ -f1 | head -1)" -p "$p" -w1 "$TARGET" 53) >/dev/null 2>&1 &
done

seen=""
for _ in $(seq 1 "$SECS"); do
	sleep 1
	for id in $(grep -o 'candidate_id=[0-9]*' "$PF/rx_flow" | cut -d= -f2); do
		case " $seen " in *" $id "*) continue ;; esac
		seen="$seen $id"
		echo "== candidate $id (live read)"
		grep "candidate_id=$id " "$PF/rx_flow" | cut -c1-220
		echo "$id" >"$PF/rpc_mflow_read"
		cut -c1-260 "$PF/rpc_mflow_read"
	done
done
wait

after=$(mdcount)
echo "metadata_valid: $before -> $after"
head -1 "$PF/rx_flow" | cut -c1-330
cut -c1-300 "$PF/flow_stats"
[ -x "$ES" ] && "$ES" report "$ES_SNAP"
rm -f "$ES_SNAP"
