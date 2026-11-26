#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 turtle2a <354865938+turtle2a@users.noreply.github.com>
# Offload check for every octep port pair not covered by octep-offload-check_octep0_1.sh:
# (octep2,octep3) (octep4,octep5) (octep6,octep7) (octep8,octep9) (octep10,octep11),
# LAN first, WAN second. Pairs whose interfaces do not both exist are skipped.
# Each pair is one interactive run of octep-offload-check.sh with its own iperf3.
# Set IPERF_CMD to match the client and server behind each pair, e.g.
#   IPERF_CMD="iperf3 -B 10.5.5.2 -c 192.168.2.1 -t 30" octep-offload-check_octep2_to_11.sh
#   octep-offload-check_octep2_to_11.sh [seconds] [only_LAN_index]   (defaults: 30, all pairs)
# Needs root. Exit 0 = every run AGREE, 1 = any run failed, 2 = no pair could run.
set -uo pipefail

SECS=${1:-30}
ONLY=${2:-}
DIR=$(cd "$(dirname "$0")" && pwd)

ran=0 fail=0
for lan in 2 4 6 8 10; do
	wan=$((lan + 1))
	[ -z "$ONLY" ] || [ "$ONLY" = "$lan" ] || continue
	if [ ! -d "/sys/class/net/octep$lan" ] || [ ! -d "/sys/class/net/octep$wan" ]; then
		echo "SKIP octep$lan/octep$wan: interface not present"
		continue
	fi
	echo "=== octep$lan (LAN) -> octep$wan (WAN) ==="
	"$DIR/octep-offload-check.sh" "$SECS" "octep$lan" "octep$wan" || fail=1
	ran=$((ran + 1))
done

[ "$ran" -gt 0 ] || { echo "No octep pair in 2..11 is present" >&2; exit 2; }
exit "$fail"
