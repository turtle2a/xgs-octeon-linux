#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Offload check for the octep0 (LAN) / octep1 (WAN) pair with the test parameters preset:
# 30 s window, LAN=octep0, WAN=octep1. Optional first argument overrides the seconds.
# Needs root. See octep-offload-check.sh for the full description and exit codes.
exec "$(dirname "$0")/octep-offload-check.sh" "${1:-30}" octep0 octep1
