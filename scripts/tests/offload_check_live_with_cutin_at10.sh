#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 turtle2a <354865938+turtle2a@users.noreply.github.com>
# Same live check as octep-offload-check.sh, but with the staged cut-in: flows are created
# staged while the host keeps forwarding, then flipped to forward 10 s later (ft_cutin=1,
# ft_cutin_ms=10000). ft_cutin_ms is restored on exit; the hook resets ft_cutin to 0 on its
# next run. Needs root.
#   offload_check_live_with_cutin_at10.sh [seconds] [LAN_IF] [WAN_IF]   (defaults: 60 octep0 octep1)
set -uo pipefail

P=/sys/module/octep/parameters
HERE=$(cd "$(dirname "$0")" && pwd)

[ "$(id -u)" -eq 0 ] || { echo "SUDO REQUIRED: sudo $0 $*" >&2; exit 2; }
[ -w "$P/ft_cutin_ms" ] || { echo "octep ft_cutin_ms not available" >&2; exit 2; }

old_ms=$(cat "$P/ft_cutin_ms")
trap 'echo "$old_ms" > "$P/ft_cutin_ms"; echo "restored ft_cutin_ms=$old_ms"' EXIT
echo 10000 > "$P/ft_cutin_ms"
echo "ft_cutin_ms=$(cat "$P/ft_cutin_ms") (was $old_ms), ft_cutin=1 for this run"

export OCTEP_FT_CUTIN=1
"$HERE/octep-offload-check.sh" "${1:-60}" "${2:-octep0}" "${3:-octep1}"
