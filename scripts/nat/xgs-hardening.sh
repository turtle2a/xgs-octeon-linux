#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Optional conntrack tuning and packet sanity filtering for the XGS router.
# Independent of xgs-nat.sh. Usage: xgs-hardening.sh start|stop|status
# Every value below can be overridden in /etc/xgs-hardening.conf.
CT_TUNE=1
CT_MAX=16384
CT_TCP_ESTABLISHED=19440
CT_UDP_TIMEOUT=60
CT_UDP_STREAM=180
CT_ACCT=1
SANITY=1
MSS_MIN=536
SYN_RATE=      # e.g. 200/second to rate-limit new TCP connections; empty = off
DSCP=0
DSCP_RT_PORTS=54:65535
DSCP_BE_UDP="53 123"
DSCP_BE_TCP=80:65535
MARK_UDP_PORTS=
[ -r /etc/xgs-hardening.conf ] && . /etc/xgs-hardening.conf

case $CT_MAX$CT_TCP_ESTABLISHED$CT_UDP_TIMEOUT$CT_UDP_STREAM$CT_ACCT$MSS_MIN in
*[!0-9]*|'') echo "xgs-hardening: invalid numeric value" >&2; exit 64 ;; esac
case $DSCP_RT_PORTS$DSCP_BE_UDP$DSCP_BE_TCP$MARK_UDP_PORTS in
*[!0-9:\ ]*) echo "xgs-hardening: invalid port list" >&2; exit 64 ;; esac
case $SYN_RATE in ''|[0-9]*/second|[0-9]*/minute) ;; *) echo "xgs-hardening: invalid SYN_RATE" >&2; exit 64 ;; esac

remove() {
	iptables -t mangle -D PREROUTING -j XGS-HARD-PRE 2>/dev/null
	iptables -t mangle -D POSTROUTING -j XGS-HARD-POST 2>/dev/null
	for c in XGS-HARD-PRE XGS-HARD-POST; do
		iptables -t mangle -F $c 2>/dev/null
		iptables -t mangle -X $c 2>/dev/null
	done
}

add() {
	iptables -t mangle -N XGS-HARD-PRE
	iptables -t mangle -N XGS-HARD-POST
	if [ "$SANITY" = 1 ]; then
		iptables -t mangle -A XGS-HARD-PRE -m conntrack --ctstate INVALID -j DROP
		iptables -t mangle -A XGS-HARD-PRE -p tcp ! --syn -m conntrack --ctstate NEW -j DROP
		iptables -t mangle -A XGS-HARD-PRE -p tcp -m conntrack --ctstate NEW -m tcpmss ! --mss $MSS_MIN:65535 -j DROP
		for f in FIN,SYN:FIN,SYN SYN,RST:SYN,RST FIN,RST:FIN,RST FIN,ACK:FIN ACK,URG:URG ACK,PSH:PSH ALL:NONE; do
			iptables -t mangle -A XGS-HARD-PRE -p tcp --tcp-flags ${f%%:*} ${f##*:} -j DROP
		done
	fi
	if [ -n "$SYN_RATE" ]; then
		iptables -t mangle -A XGS-HARD-PRE -p tcp --syn -m limit --limit $SYN_RATE --limit-burst 100 -j RETURN
		iptables -t mangle -A XGS-HARD-PRE -p tcp --syn -j DROP
	fi
	[ -z "$MARK_UDP_PORTS" ] || iptables -t mangle -A XGS-HARD-PRE -p udp --dport $MARK_UDP_PORTS -j MARK --set-mark 1
	if [ "$DSCP" = 1 ]; then
		iptables -t mangle -A XGS-HARD-POST -p udp --dport $DSCP_RT_PORTS -j DSCP --set-dscp-class EF
		for p in $DSCP_BE_UDP; do
			iptables -t mangle -A XGS-HARD-POST -p udp --dport $p -j DSCP --set-dscp-class BE
		done
		iptables -t mangle -A XGS-HARD-POST -p tcp --dport $DSCP_BE_TCP -j DSCP --set-dscp-class BE
	fi
	iptables -t mangle -I PREROUTING 1 -j XGS-HARD-PRE
	iptables -t mangle -I POSTROUTING 1 -j XGS-HARD-POST
}

case $1 in
start)
	if [ "$CT_TUNE" = 1 ]; then
		sysctl -qw net.netfilter.nf_conntrack_acct=$CT_ACCT \
			net.netfilter.nf_conntrack_max=$CT_MAX \
			net.netfilter.nf_conntrack_tcp_timeout_established=$CT_TCP_ESTABLISHED \
			net.netfilter.nf_conntrack_udp_timeout=$CT_UDP_TIMEOUT \
			net.netfilter.nf_conntrack_udp_timeout_stream=$CT_UDP_STREAM || true
	fi
	remove
	add
	echo "xgs-hardening applied"
	;;
stop)
	remove
	echo "xgs-hardening removed (conntrack sysctls left as set)"
	;;
status)
	iptables -t mangle -S XGS-HARD-PRE 2>/dev/null
	iptables -t mangle -S XGS-HARD-POST 2>/dev/null
	;;
*) echo "usage: $0 start|stop|status" >&2; exit 64 ;;
esac
exit 0
