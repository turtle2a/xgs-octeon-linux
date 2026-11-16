#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# OPTIONAL: no NAT. Removes the Port 2 / Port 4 masquerade rules.
# To keep it off across reboots: sudo touch /etc/xgs-nat-off
#   sudo nat-off.sh
iptables -t nat -D POSTROUTING -o octep1 -j MASQUERADE 2>/dev/null
iptables -t nat -D POSTROUTING -o octep3 -j MASQUERADE 2>/dev/null
echo "NAT off: no LAN port is NATed"
