#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

STATE_DIR=/var/lib/xgs-linux-nat
STATE_FILE=$STATE_DIR/managed-state
TABLE_FAMILY=ip
TABLE_NAME=xgs_nat

fail() {
	echo "xgs-nat: $*" >&2
	exit 1
}

require_root() {
	[ "$(id -u)" -eq 0 ] || fail "run with sudo"
}

require_nft() {
	command -v nft >/dev/null 2>&1 || fail "nftables command 'nft' is required"
}

manager_state() {
	unit=$1
	if ! command -v systemctl >/dev/null 2>&1; then
		printf 'unavailable'
		return
	fi
	state=$(systemctl is-active "$unit" 2>/dev/null || true)
	printf '%s' "${state:-inactive}"
}

port_carrier() {
	interface=$1
	carrier_file="/sys/class/net/$interface/carrier"
	if [ -r "$carrier_file" ]; then
		case $(cat "$carrier_file" 2>/dev/null || true) in
			1) printf 'up' ;;
			0) printf 'down' ;;
			*) printf 'unknown' ;;
		esac
	else
		printf 'unknown'
	fi
}

show_status() {
	require_root
	printf '%s\n' 'Detected network/firewall components:'
	for tool in nmcli firewall-cmd nft iptables; do
		if command -v "$tool" >/dev/null 2>&1; then
			printf '  %-13s %s\n' "$tool" "$(command -v "$tool")"
		else
			printf '  %-13s not installed\n' "$tool"
		fi
	done
	printf '  %-13s %s\n' 'NetworkManager' "$(manager_state NetworkManager)"
	printf '  %-13s %s\n' 'firewalld' "$(manager_state firewalld)"
	printf '  %-13s %s\n' 'nftables' "$(manager_state nftables)"

	for path in /sys/class/net/octep[0-9]*; do
		[ -e "$path" ] || continue
		interface=${path##*/}
		case $interface in
			octep[0-9]*)
				physical_port=$((${interface#octep} + 1))
				printf '  physical port %-2s (%s): link %s\n' \
					"$physical_port" "$interface" "$(port_carrier "$interface")"
				;;
		esac
	done

	if ! command -v nft >/dev/null 2>&1; then
		printf '%s\n' 'XGS NAT table: unknown (nft command is unavailable)'
	elif nft list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1; then
		if [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] &&
		   grep -Fqx 'managed_by=xgs-nat-options-v1' "$STATE_FILE"; then
			printf '%s\n' 'XGS NAT table: present and recorded as managed by this script'
		else
			printf '%s\n' 'XGS NAT table: present but not recognized; it will be left untouched'
		fi
	elif [ -f "$STATE_FILE" ]; then
		printf '%s\n' 'XGS NAT table: absent; a stale state record exists (run undo to clear it)'
	else
		printf '%s\n' 'XGS NAT table: not present; no NAT rules have been added by this script'
	fi
	printf '%s\n' 'Status is read-only. This script does not change existing firewall rules or NetworkManager settings.'
}

list_copper_ports() {
	found=0
	for physical_port in 2 4; do
		interface="octep$(($physical_port - 1))"
		[ -e "/sys/class/net/$interface" ] || continue
		printf '  WAN physical port %s: %s (link %s)\n' \
			"$physical_port" "$interface" "$(port_carrier "$interface")"
		found=1
	done
	[ "$found" -eq 1 ] || fail "neither WAN interface (physical port 2 or 4) is currently detected"
}

interface_for_port() {
	case $1 in
		2) interface=octep1 ;;
		4) interface=octep3 ;;
		*) return 1 ;;
	esac
	[ -e "/sys/class/net/$interface" ] || return 1
	printf '%s' "$interface"
}

valid_ipv4_cidr() {
	printf '%s\n' "$1" | awk -F'[./]' '
		NF != 5 { exit 1 }
		{
			for (i = 1; i <= 4; i++) {
				if ($i !~ /^[0-9]+$/ || $i > 255)
					exit 1
			}
			if ($5 !~ /^[0-9]+$/ || $5 > 32)
				exit 1
		}
	'
}

validate_lan_cidrs() {
	case $1 in
		''|*[!0-9.,/]*|*//*|*,,*|,*|*,)
			return 1
			;;
	esac

	old_ifs=$IFS
	IFS=,
	set -- $1
	IFS=$old_ifs
	[ "$#" -gt 0 ] || return 1
	for cidr do
		valid_ipv4_cidr "$cidr" || return 1
	done
}

read_input() {
	prompt=$1
	printf '%s' "$prompt"
	IFS= read -r REPLY || fail "input ended before configuration was complete"
}

apply_options() {
	require_root
	require_nft

	if systemctl is-active --quiet firewalld 2>/dev/null; then
		fail "firewalld is active; refusing to bypass its rule manager"
	fi
	if nft list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1; then
		if [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] &&
		   grep -Fqx 'managed_by=xgs-nat-options-v1' "$STATE_FILE"; then
			fail "an XGS NAT table is already applied; use 'undo' first"
		fi
		fail "table $TABLE_FAMILY $TABLE_NAME already exists and is not recognized; refusing to touch it"
	fi
	if [ -e "$STATE_FILE" ] || [ -L "$STATE_FILE" ]; then
		fail "a previous state record exists; use 'undo' to clear it before applying"
	fi

	ip_forward=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || true)
	[ "$ip_forward" = 1 ] ||
		fail "IPv4 forwarding is disabled; enable and verify forwarding separately before applying NAT"

	printf '%s\n' 'WAN choices only (other OCTEP ports remain LAN):'
	list_copper_ports
	read_input 'WAN physical port (2 or 4) [2]: '
	wan_port=${REPLY:-2}
	wan=$(interface_for_port "$wan_port") ||
		fail "select detected WAN physical port 2 or 4"

	read_input 'LAN source IPv4 subnet(s), comma-separated CIDR: '
	lan_cidrs=$REPLY
	validate_lan_cidrs "$lan_cidrs" ||
		fail "enter one or more valid IPv4 CIDRs separated by commas"

	printf '\n%s\n' 'Planned operation (no rules have been changed yet):'
	printf '  LAN source subnet(s): %s\n  WAN: %s (physical port %s, link %s)\n' \
		"$lan_cidrs" "$wan" "$wan_port" "$(port_carrier "$wan")"
	printf '%s\n' '  Scope: IPv4 source NAT only; no filter, route, forwarding, or port-forward rules.'

	tmp=$(mktemp "${TMPDIR:-/tmp}/xgs-nat.XXXXXX") ||
		fail "could not create a temporary nftables ruleset"
	state_tmp=
	cleanup() {
		rm -f "$tmp"
		if [ -n "$state_tmp" ]; then
			rm -f "$state_tmp"
		fi
	}
	trap cleanup EXIT
	trap 'exit 1' HUP INT TERM

	{
		printf 'table ip %s {\n' "$TABLE_NAME"
		printf ' chain postrouting {\n'
		printf '  type nat hook postrouting priority srcnat; policy accept;\n'
		old_ifs=$IFS
		IFS=,
		set -- $lan_cidrs
		IFS=$old_ifs
		for cidr do
			printf '  ip saddr %s oifname "%s" masquerade\n' "$cidr" "$wan"
		done
		printf ' }\n}\n'
	} > "$tmp"

	nft -c -f "$tmp" || fail "nftables rejected the proposed rules; no rules were applied"
	read_input 'Type APPLY to install this dedicated NAT table: '
	[ "$REPLY" = APPLY ] || fail "cancelled; no rules were applied"

	state_tmp=$(mktemp "${TMPDIR:-/tmp}/xgs-nat-state.XXXXXX") ||
		fail "could not create a temporary state record"
	umask 077
	{
		printf 'managed_by=xgs-nat-options-v1\n'
		printf 'wan=%s\nwan_port=%s\nlan_cidrs=%s\n' \
			"$wan" "$wan_port" "$lan_cidrs"
	} > "$state_tmp"
	[ ! -L "$STATE_DIR" ] || fail "NAT state directory must not be a symlink"
	install -d -m 0700 "$STATE_DIR" ||
		fail "could not create private NAT state directory $STATE_DIR"
	chmod 0700 "$STATE_DIR" ||
		fail "could not secure private NAT state directory $STATE_DIR"
	mv "$state_tmp" "$STATE_FILE"
	state_tmp=

	if ! nft -f "$tmp"; then
		rm -f "$STATE_FILE"
		fail "nftables did not apply the proposed rules; state record removed"
	fi
	printf '%s\n' 'NAT table applied. Other nftables tables and NetworkManager settings were not changed.'
	printf '%s\n' 'Rules are runtime-only and are not restored automatically after reboot.'
	printf '%s\n' 'To use a different WAN, run undo and apply again. This script does not fail over automatically.'
}

undo_options() {
	require_root
	require_nft

	if [ ! -e "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ]; then
		if nft list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1; then
			fail "table $TABLE_FAMILY $TABLE_NAME has no XGS ownership record; it was left untouched"
		fi
		printf '%s\n' 'No NAT rules managed by this script are recorded; nothing changed.'
		return
	fi
	[ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] ||
		fail "state record is not a regular file; refusing to change firewall rules"
	grep -Fqx 'managed_by=xgs-nat-options-v1' "$STATE_FILE" ||
		fail "state record is not recognized; refusing to change firewall rules"

	printf '%s\n' 'This undo removes only the dedicated table ip xgs_nat created by this script.'
	read_input 'Type UNDO to continue: '
	[ "$REPLY" = UNDO ] || fail "cancelled; no rules were changed"

	if nft list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1; then
		nft delete table "$TABLE_FAMILY" "$TABLE_NAME" ||
			fail "could not remove the managed XGS NAT table"
	else
		printf '%s\n' 'The managed NAT table is already absent.'
	fi
	rm -f -- "$STATE_FILE" || fail "could not remove the state record"
	rmdir "$STATE_DIR" 2>/dev/null || true
	printf '%s\n' 'Managed NAT options undone; other firewall rules and NetworkManager settings were untouched.'
}

usage() {
	printf 'Usage: %s [status|apply|undo|--help]\n' "$0"
	printf '%s\n' \
		'  status  Detect components and report this script’s managed table (read-only).' \
		'  apply   Interactively select one WAN and configure IPv4 source NAT after confirmation.' \
		'  undo    Interactively remove only this script’s dedicated NAT table.'
}

case ${1:-status} in
	status)
		[ "$#" -le 1 ] || { usage >&2; exit 64; }
		show_status
		;;
	apply)
		[ "$#" -eq 1 ] || { usage >&2; exit 64; }
		apply_options
		;;
	undo)
		[ "$#" -eq 1 ] || { usage >&2; exit 64; }
		undo_options
		;;
	--help|-h)
		usage
		;;
	*)
		usage >&2
		exit 64
		;;
esac
