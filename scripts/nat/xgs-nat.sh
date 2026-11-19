#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Blind, simple NAT. Default: everything leaving faceplate port 2 (octep1) is masqueraded.
# Faceplate port N = interface octep(N-1).
#   sudo xgs-nat.sh start    default NAT out octep1
#   sudo xgs-nat.sh start    default NAT out octep1 for all LAN ports and the management subnet
#   sudo xgs-nat.sh mgmt     re-apply only the management route (already part of start)
#   sudo xgs-nat.sh stop     undo both
WAN=${WAN:-octep1}
GW=192.168.1.1   # fallback WAN gateway; the DHCP default route on $WAN is preferred
LAN_NETS="10.4.4.0/28 10.4.12.0/28 10.4.13.0/28 10.4.14.0/28 10.4.15.0/28 10.4.16.0/28 10.4.17.0/28 10.4.18.0/28 10.4.19.0/28"   # OCTEP LAN subnets (octep0, octep2-9) forced out the WAN
MGMT_NET=10.1.1.0/28   # management subnet (enp2s0), also NATed out the WAN; enp2s0 itself is never reconfigured
MGMT_IF=enp2s0
# Optional overrides: WAN=, GW=, LAN_NETS=, MGMT_NET=, MGMT_IF= in /etc/xgs-nat.conf
[ -r /etc/xgs-nat.conf ] && . /etc/xgs-nat.conf

nat_rules() { # $1 = -A|-D
	iptables -t nat $1 POSTROUTING -o $WAN -j MASQUERADE
}

fwd_rules() { # $1 = -I|-D; accept LAN->WAN and replies even under a default-drop FORWARD policy
	for net in $LAN_NETS $MGMT_NET; do
		iptables $1 FORWARD -s $net -o $WAN -j ACCEPT
		iptables $1 FORWARD -d $net -i $WAN -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
	done
}

# Table 100 holds only a default route, so give it the WAN's own on-link subnet(s):
# the WAN gateway and servers on that subnet are then reached directly.
wan_links() {
	ip -4 route show dev $WAN scope link 2>/dev/null | while read -r r; do
		ip route replace $r dev $WAN table 100 2>/dev/null
	done
}

# The "from <LAN subnet> lookup 100" rules also match packets the router itself
# sends from a LAN address (ping/ssh replies from 10.4.4.10), which would leave via
# the WAN. Traffic to a LAN or management subnet stays on its connected route.
lan_local_rules() { # $1 = -A|-D
	for net in $LAN_NETS $MGMT_NET; do
		ip rule del to $net lookup main suppress_prefixlength 0 priority 90 2>/dev/null
		[ "$1" = -A ] && ip rule add to $net lookup main suppress_prefixlength 0 priority 90
	done
	return 0
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
	wan_links
	for net in $LAN_NETS; do
		ip rule del from $net lookup 100 2>/dev/null
		ip rule add from $net lookup 100 priority 100
	done
	lan_local_rules -A
	ip rule del from $MGMT_NET iif $MGMT_IF lookup 100 2>/dev/null
	ip rule add from $MGMT_NET iif $MGMT_IF lookup 100 priority 101
	echo "All LAN and management ports now routed via $WAN WAN"
	;;
mgmt)
	DHCP_GW=$(ip -4 route show default dev $WAN 2>/dev/null | awk '{print $3; exit}')
	ip route replace default via "${DHCP_GW:-$GW}" dev $WAN table 100
	wan_links
	ip rule del from $MGMT_NET iif $MGMT_IF lookup 100 2>/dev/null
	ip rule add from $MGMT_NET iif $MGMT_IF lookup 100 priority 101
	echo "$MGMT_NET now routed via $WAN WAN"
	;;
stop)
	nat_rules -D 2>/dev/null
	fwd_rules -D 2>/dev/null
	for net in $LAN_NETS; do
		ip rule del from $net lookup 100 2>/dev/null
	done
	ip rule del from $MGMT_NET iif $MGMT_IF lookup 100 2>/dev/null
	lan_local_rules -D
	ip route flush table 100 2>/dev/null
	echo "NAT removed"
	;;
*) echo "usage: $0 start|mgmt|stop" >&2; exit 64 ;;
esac
exit 0
