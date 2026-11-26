#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 turtle2a <354865938+turtle2a@users.noreply.github.com>
# OPTIONAL: no NAT. Removes the Port 2 / Port 4 masquerade rules.
# To keep it off across reboots: sudo touch /etc/xgs-nat-off
#   sudo nat-off.sh
D=$(dirname "$0")
WAN=octep1 "$D/xgs-nat.sh" stop >/dev/null
WAN=octep3 "$D/xgs-nat.sh" stop >/dev/null
echo "NAT off: no LAN port is NATed"
