#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Blind, simple NAT. Default: everything leaving faceplate port 2 (octep1) is masqueraded.
# Faceplate port N = interface octep(N-1).
#   sudo xgs-nat.sh start    default NAT out octep1
#   sudo xgs-nat.sh mgmt     optional: also send 10.1.1.0/28 (from enp2s0) out octep1
#   sudo xgs-nat.sh stop     undo both
WAN=${WAN:-octep1}
GW=192.168.1.1   # fallback WAN gateway; the DHCP default route on $WAN is preferred
LAN_NET=10.4.4.0/28   # OCTEP LAN client subnet (octep0) forced out the WAN
# Optional overrides: WAN=, GW=, LAN_NET= in /etc/xgs-nat.conf
[ -r /etc/xgs-nat.conf ] && . /etc/xgs-nat.conf

nat_rules() { # $1 = -A|-D
	iptables -t nat $1 POSTROUTING -o $WAN -j MASQUERADE
}

fwd_rules() { # $1 = -I|-D; accept LAN->WAN and replies even under a default-drop FORWARD policy
	iptables $1 FORWARD -s $LAN_NET -o $WAN -j ACCEPT
	iptables $1 FORWARD -d $LAN_NET -i $WAN -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
}

case $1 in
start)
	sysctl -qw net.ipv4.ip_forward=1
	nat_rules -C 2>/dev/null || nat_rules -A
	fwd_rules -D 2>/dev/null
	fwd_rules -I 2>/dev/null
	# The main table's default route can prefer enp2s0 (lower metric), so
	# pin the OCTEP LAN subnet to the WAN with a policy route. The unit can
	# start before DHCP completes, so wait for the WAN default route.
	i=0
	while [ $i -lt 90 ] && [ -z "$(ip -4 route show default dev $WAN 2>/dev/null)" ]; do
		sleep 1; i=$((i + 1))
	done
	DHCP_GW=$(ip -4 route show default dev $WAN 2>/dev/null | awk '{print $3; exit}')
	ip route replace default via "${DHCP_GW:-$GW}" dev $WAN table 100
	ip rule del from $LAN_NET lookup 100 2>/dev/null
	ip rule add from $LAN_NET lookup 100 priority 100
	echo "All LAN ports now routed via $WAN WAN"
	;;
mgmt)
	DHCP_GW=$(ip -4 route show default dev $WAN 2>/dev/null | awk '{print $3; exit}')
	ip route replace default via "${DHCP_GW:-$GW}" dev $WAN table 100
	ip rule del from 10.1.1.0/28 iif enp2s0 lookup 100 2>/dev/null
	ip rule add from 10.1.1.0/28 iif enp2s0 lookup 100 priority 101
	echo "10.1.1.0/28 now routed via Port 2 (octep1) WAN"
	;;
stop)
	nat_rules -D 2>/dev/null
	fwd_rules -D 2>/dev/null
	ip rule del from $LAN_NET lookup 100 2>/dev/null
	ip rule del from 10.1.1.0/28 iif enp2s0 lookup 100 2>/dev/null
	ip route flush table 100 2>/dev/null
	echo "NAT removed"
	;;
*) echo "usage: $0 start|mgmt|stop" >&2; exit 64 ;;
esac
exit 0
