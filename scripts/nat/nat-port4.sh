#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 turtle2a <354865938+turtle2a@users.noreply.github.com>
# OPTIONAL: NAT out Port 4 (octep3) instead of the default Port 2 (octep1).
#   sudo nat-port4.sh      (undo: sudo xgs-nat.sh start, or nat-off.sh)
D=$(dirname "$0")
WAN=octep1 "$D/xgs-nat.sh" stop >/dev/null
WAN=octep3 "$D/xgs-nat.sh" start
