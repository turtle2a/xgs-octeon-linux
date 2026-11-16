#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# OPTIONAL: NAT out Port 4 (octep3) instead of the default Port 2 (octep1).
#   sudo nat-port4.sh      (undo: sudo xgs-nat.sh start, or nat-off.sh)
iptables -t nat -D POSTROUTING -o octep1 -j MASQUERADE 2>/dev/null
sysctl -qw net.ipv4.ip_forward=1
iptables -t nat -C POSTROUTING -o octep3 -j MASQUERADE 2>/dev/null ||
	iptables -t nat -A POSTROUTING -o octep3 -j MASQUERADE
echo "All LAN ports now routed via Port 4 (octep3) WAN"
