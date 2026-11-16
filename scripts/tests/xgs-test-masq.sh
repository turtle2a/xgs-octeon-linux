#!/bin/sh
# Masquerade out the configured WAN adapters. Run as root.
# Ports come from WAN_PORTS in /etc/xgs-nat.conf (default: octep1 octep3 = ports 2 and 4);
# the rule matches by name, so adapters that do not exist yet are fine.
# Usage: xgs-test-masq.sh start|stop
set -eu

WAN_PORTS="octep1 octep3"
[ -r /etc/xgs-nat.conf ] && . /etc/xgs-nat.conf

case "${1:-}" in
start)
	# oifname matches by name, so the rule is valid before the adapters exist; at boot this runs
	# before the SDP bring-up has created them, and after a driver reload they briefly vanish.
	[ -n "$WAN_PORTS" ] || { echo "xgs-masq: WAN_PORTS is empty" >&2; exit 1; }
	# -o matches by name, so the rules are valid before the adapters exist (boot, driver reload).
	"$0" stop
	iptables -t nat -N XGS_MASQ
	for p in $WAN_PORTS; do
		iptables -t nat -A XGS_MASQ -o "$p" -j MASQUERADE
	done
	iptables -t nat -I POSTROUTING 1 -j XGS_MASQ
	[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = 1 ] ||
		sysctl -qw net.ipv4.ip_forward=1 2>/dev/null ||
		echo "xgs-masq: warning: could not enable net.ipv4.ip_forward" >&2
	echo "xgs-masq: masquerade out $WAN_PORTS"
	;;
stop)
	while iptables -t nat -D POSTROUTING -j XGS_MASQ 2>/dev/null; do :; done
	iptables -t nat -F XGS_MASQ 2>/dev/null || true
	iptables -t nat -X XGS_MASQ 2>/dev/null || true
	;;
*)
	echo "usage: $0 start|stop" >&2
	exit 2
	;;
esac
