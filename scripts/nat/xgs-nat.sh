#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Blind, simple NAT. Default: everything leaving faceplate port 2 (octep1) is masqueraded.
# Faceplate port N = interface octep(N-1).
#   sudo xgs-nat.sh start    default NAT out octep1
#   sudo xgs-nat.sh mgmt     optional: also send 10.1.1.0/28 (from enp2s0) out octep1
#   sudo xgs-nat.sh stop     undo both
WAN=octep1
GW=192.168.1.1   # WAN gateway; edit if yours differs

case $1 in
start)
	sysctl -qw net.ipv4.ip_forward=1
	iptables -t nat -C POSTROUTING -o $WAN -j MASQUERADE 2>/dev/null ||
		iptables -t nat -A POSTROUTING -o $WAN -j MASQUERADE
	echo "All LAN ports now routed via Port 2 (octep1) WAN"
	;;
mgmt)
	ip route replace default via $GW dev $WAN table 100
	ip rule del from 10.1.1.0/28 iif enp2s0 lookup 100 2>/dev/null
	ip rule add from 10.1.1.0/28 iif enp2s0 lookup 100 priority 101
	echo "10.1.1.0/28 now routed via Port 2 (octep1) WAN"
	;;
stop)
	iptables -t nat -D POSTROUTING -o $WAN -j MASQUERADE 2>/dev/null
	ip rule del from 10.1.1.0/28 iif enp2s0 lookup 100 2>/dev/null
	ip route flush table 100 2>/dev/null
	echo "NAT removed"
	;;
*) echo "usage: $0 start|mgmt|stop" >&2; exit 64 ;;
esac
exit 0
