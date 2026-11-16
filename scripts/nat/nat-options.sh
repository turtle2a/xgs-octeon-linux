#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STATE_DIR=/var/lib/xgs-linux-nat
STATE_FILE=$STATE_DIR/managed-state
SYSCTL_CONFIG=/etc/sysctl.d/99-xgs-nat-options.conf
SDP_BRINGUP_SCRIPT="$SCRIPT_DIR/../octep/sdp-bringup.sh"
PORT_SETUP_SCRIPT="$SCRIPT_DIR/../octep/rpc-port-setup.sh"
CHAIN=XGS_NAT
PBR_TABLE=100
PBR_PRIO=100

fail() {
	echo "xgs-nat: $*" >&2
	exit 1
}

require_root() {
	[ "$(id -u)" -eq 0 ] || fail "run with sudo"
}

require_ipt() {
	command -v iptables >/dev/null 2>&1 || fail "the 'iptables' command is required"
}

chain_present() {
	iptables -t nat -n -L "$CHAIN" >/dev/null 2>&1
}

# Remove every POSTROUTING jump to the chain, then the chain itself.
chain_remove() {
	while iptables -t nat -D POSTROUTING -j "$CHAIN" 2>/dev/null; do :; done
	iptables -t nat -F "$CHAIN" 2>/dev/null || true
	iptables -t nat -X "$CHAIN"
}

# Usage: chain_install "wan" cidr...
chain_install() {
	wan_if=$1
	shift
	iptables -t nat -N "$CHAIN" || return 1
	for cidr do
		iptables -t nat -A "$CHAIN" -s "$cidr" -o "$wan_if" -j MASQUERADE || return 1
	done
	iptables -t nat -I POSTROUTING 1 -j "$CHAIN"
}

# Send the LAN subnets out the WAN without touching the LAN's own default route
# (e.g. a holding gateway that carries this host's own traffic).
# Subnets on a device that holds a non-WAN default route match by input interface only,
# so this host's own traffic keeps using that default; other subnets match by source.
# Usage: policy_install wan "keep devices" cidr...
policy_install() {
	wan_if=$1
	keep=$2
	shift 2
	gw=
	n=0
	while [ "$n" -lt 20 ]; do
		gw=$(ip -4 route show default dev "$wan_if" | awk '{ for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }')
		[ -n "$gw" ] && break
		n=$((n + 1))
		sleep 1
	done
	[ -n "$gw" ] || { echo "xgs-nat: no default gateway on $wan_if (DHCP not up)" >&2; return 1; }
	ip route replace default via "$gw" dev "$wan_if" table "$PBR_TABLE" || return 1
	prio=$PBR_PRIO
	for cidr do
		dev=$(ip -4 -o route show "$cidr" scope link | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
		iif=
		for k in $keep; do
			[ "$k" = "$dev" ] && iif="iif $dev"
		done
		ip rule add from "$cidr" $iif lookup "$PBR_TABLE" priority "$prio" || return 1
		prio=$((prio + 1))
	done
}

policy_remove() {
	while ip rule del lookup "$PBR_TABLE" 2>/dev/null; do :; done
	ip route flush table "$PBR_TABLE" 2>/dev/null || true
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

state_is_managed() {
	grep -Fqx 'managed_by=xgs-nat-options-v1' "$STATE_FILE" ||
		grep -Fqx 'managed_by=xgs-nat-options-v2' "$STATE_FILE"
}

state_value() {
	key=$1
	sed -n "s/^$key=//p" "$STATE_FILE"
}

nm_set_never_default() {
	uuid=$1
	device=$2
	value=$3

	nmcli connection modify "$uuid" ipv4.never-default "$value" || return 1
	if [ -d "/sys/class/net/$device" ]; then
		active_uuid=$(nmcli -g GENERAL.CON-UUID device show "$device" 2>/dev/null) ||
			return 1
		if [ "$active_uuid" = "$uuid" ]; then
			nmcli device reapply "$device" >/dev/null || return 1
		fi
	fi
}

restore_forwarding() {
	previous=$1
	config=$2

	if [ "$config" = created ]; then
		if [ -e "$SYSCTL_CONFIG" ] || [ -L "$SYSCTL_CONFIG" ]; then
			[ -f "$SYSCTL_CONFIG" ] && [ ! -L "$SYSCTL_CONFIG" ] || return 1
			grep -Fqx 'net.ipv4.ip_forward=1' "$SYSCTL_CONFIG" || return 1
			rm -f -- "$SYSCTL_CONFIG" || return 1
		fi
	fi
	case $previous in
		0) sysctl -w net.ipv4.ip_forward=0 >/dev/null || return 1 ;;
		1|'') ;;
		*) return 1 ;;
	esac
}

show_status() {
	require_root
	printf '%s\n' 'Detected network/firewall components:'
	for tool in nmcli firewall-cmd iptables; do
		if command -v "$tool" >/dev/null 2>&1; then
			printf '  %-13s %s\n' "$tool" "$(command -v "$tool")"
		else
			printf '  %-13s not installed\n' "$tool"
		fi
	done
	printf '  %-13s %s\n' 'NetworkManager' "$(manager_state NetworkManager)"
	printf '  %-13s %s\n' 'firewalld' "$(manager_state firewalld)"

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

	if ! command -v iptables >/dev/null 2>&1; then
		printf '%s\n' 'XGS NAT table: unknown (iptables command is unavailable)'
	elif chain_present; then
		if [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] &&
		   state_is_managed; then
			printf '%s\n' 'XGS NAT table: present and recorded as managed by this script'
		else
			printf '%s\n' 'XGS NAT table: present but not recognized; it will be left untouched'
		fi
	elif [ -f "$STATE_FILE" ]; then
		printf '%s\n' 'XGS NAT table: absent; a stale state record exists (run undo to clear it)'
	else
		printf '%s\n' 'XGS NAT table: not present; no NAT rules have been added by this script'
	fi
	printf '%s\n' 'Status is read-only; apply and undo change only the NAT table and settings recorded by this script.'
}

list_copper_ports() {
	for physical_port in 2 4; do
		interface="octep$(($physical_port - 1))"
		if [ -e "/sys/class/net/$interface" ]; then
			printf '  WAN physical port %s: %s (link %s)\n' \
				"$physical_port" "$interface" "$(port_carrier "$interface")"
		else
			printf '  WAN physical port %s: %s (not initialized)\n' \
				"$physical_port" "$interface"
		fi
	done
}

ensure_wan_interface() {
	physical_port=$1
	interface="octep$(($physical_port - 1))"
	[ -e "/sys/class/net/$interface" ] && return 0
	[ -f "$SDP_BRINGUP_SCRIPT" ] ||
		fail "OCTEP SDP bring-up script is missing"
	[ -f "$PORT_SETUP_SCRIPT" ] ||
		fail "OCTEP WAN interface $interface is absent and the port-setup script is missing"
	printf '%s\n' 'Arming OCTEP SDP rings before initializing the selected WAN port...'
	sh "$SDP_BRINGUP_SCRIPT" ||
		fail "SDP bring-up failed; check the OCTEP bring-up log"
	printf 'Initializing only physical WAN port %s...\n' "$physical_port"
	sh "$PORT_SETUP_SCRIPT" --wan-port "$physical_port" ||
		fail "WAN port initialization failed; check the port-setup error and NPU state"
	[ -e "/sys/class/net/$interface" ] ||
		fail "WAN port setup completed but did not create $interface"
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

valid_connection_uuid() {
	case $1 in
		''|*[!A-Fa-f0-9-]*) return 1 ;;
		*) return 0 ;;
	esac
}

prepare_wan_profile() {
	command -v nmcli >/dev/null 2>&1 ||
		fail "NetworkManager is required to configure DHCP on $wan"
	wan_nm_uuid=$(nmcli -g GENERAL.CON-UUID device show "$wan" 2>/dev/null || true)
	if ! valid_connection_uuid "$wan_nm_uuid"; then
		wan_nm_uuid=
		matching_profiles=
		wan_profiles=$(nmcli -g connection.uuid connection show) ||
			fail "could not list NetworkManager profiles to configure DHCP on $wan"
		for candidate_uuid in $wan_profiles; do
			candidate_device=$(nmcli -g connection.interface-name connection show \
				"$candidate_uuid" 2>/dev/null || true)
			[ "$candidate_device" = "$wan" ] || continue
			matching_profiles="${matching_profiles}${matching_profiles:+
}$candidate_uuid"
		done
		set -- $matching_profiles
		if [ "$#" -gt 1 ]; then
			fail "multiple NetworkManager profiles are bound to $wan; select one before applying NAT"
		elif [ "$#" -eq 1 ]; then
			wan_nm_uuid=$1
		else
			wan_nm_created=yes
			wan_profile_name="xgs-nat-$wan"
			if nmcli connection show "$wan_profile_name" >/dev/null 2>&1; then
				fail "NetworkManager profile $wan_profile_name already exists; refusing to overwrite it"
			fi
			wan_old_method=
			wan_old_never_default=
			wan_old_ignore_auto_routes=
			wan_old_autoconnect=
			return
		fi
	fi

	valid_connection_uuid "$wan_nm_uuid" ||
		fail "could not identify a NetworkManager profile for $wan"
	wan_nm_created=no
	wan_old_method=$(nmcli -g ipv4.method connection show "$wan_nm_uuid") ||
		fail "could not read the IPv4 method for $wan"
	wan_old_never_default=$(nmcli -g ipv4.never-default connection show "$wan_nm_uuid") ||
		fail "could not read the default-route setting for $wan"
	wan_old_ignore_auto_routes=$(nmcli -g ipv4.ignore-auto-routes connection show "$wan_nm_uuid") ||
		fail "could not read the automatic-route setting for $wan"
	wan_old_autoconnect=$(nmcli -g connection.autoconnect connection show "$wan_nm_uuid") ||
		fail "could not read autoconnect for $wan"
}

wan_address_state() {
	wan_addresses=$(ip -4 -o address show dev "$wan" |
		awk '$3 == "inet" { print $4 }')
	wan_address=
	wan_link_local=
	for address in $wan_addresses; do
		case $address in
			169.254.*)
				[ -n "$wan_link_local" ] || wan_link_local=$address
				;;
			*)
				[ -n "$wan_address" ] || wan_address=$address
				;;
		esac
	done
}

configure_wan_dhcp() {
	ip link set dev "$wan" up ||
		fail "could not bring WAN interface $wan up"
	wan_link=$(port_carrier "$wan")
	case $wan_link in
		up) ;;
		down)
			fail "WAN physical port $wan_port ($wan) has no link; check the cable and upstream port"
			;;
		*)
			fail "could not read link status for WAN physical port $wan_port ($wan)"
			;;
	esac

	if [ "$wan_nm_created" = yes ]; then
		nmcli connection add type ethernet ifname "$wan" \
			con-name "$wan_profile_name" ipv4.method auto \
			ipv4.never-default no ipv4.ignore-auto-routes no \
			connection.autoconnect yes ||
			fail "could not create a DHCP NetworkManager profile for $wan"
		wan_nm_uuid=$(nmcli -g connection.uuid connection show "$wan_profile_name") ||
			fail "created a DHCP profile for $wan but could not read its UUID; remove $wan_profile_name manually"
	fi

	active_wan_uuid=$(nmcli -g GENERAL.CON-UUID device show "$wan" 2>/dev/null || true)
	if [ "$active_wan_uuid" = "$wan_nm_uuid" ]; then
		nmcli connection down "$wan_nm_uuid" ||
			fail "could not bring $wan down before requesting DHCP"
	fi
	nmcli connection modify "$wan_nm_uuid" \
		ipv4.method auto ipv4.never-default no \
		ipv4.ignore-auto-routes no connection.autoconnect yes ||
		fail "could not configure DHCP on $wan"
	nmcli --wait 30 connection up "$wan_nm_uuid" ifname "$wan" ||
		printf 'xgs-nat: NetworkManager did not confirm DHCP activation on %s; checking the lease\n' "$wan" >&2

	wan_address_state
	if [ -z "$wan_address" ]; then
		if [ -n "$wan_link_local" ]; then
			fail "$wan has only link-local address $wan_link_local; DHCP did not provide a lease. Check the DHCP server, VLAN, and cable"
		fi
		fail "$wan has no IPv4 address after DHCP activation; check the DHCP server, VLAN, and NetworkManager profile"
	fi
	wan_default_route=$(ip -4 route show default dev "$wan") ||
		fail "could not check the default route for $wan"
	[ -n "$wan_default_route" ] ||
		fail "$wan received IPv4 address $wan_address but no default gateway; check the DHCP router option or WAN configuration"
}

restore_wan_profile() {
	uuid=$1
	created=$2
	name=$3
	device=$4
	old_method=$5
	old_never_default=$6
	old_ignore_auto_routes=$7
	old_autoconnect=$8

	if [ "$created" = yes ]; then
		profile=${uuid:-$name}
		[ -n "$profile" ] || return 1
		nmcli connection delete "$profile" || return 1
		return 0
	fi
	[ -n "$uuid" ] || return 0
	[ -n "$old_method" ] && [ -n "$old_never_default" ] &&
		[ -n "$old_ignore_auto_routes" ] && [ -n "$old_autoconnect" ] ||
		return 1
	nmcli connection modify "$uuid" ipv4.method "$old_method" \
		ipv4.never-default "$old_never_default" \
		ipv4.ignore-auto-routes "$old_ignore_auto_routes" \
		connection.autoconnect "$old_autoconnect" || return 1
	if [ -d "/sys/class/net/$device" ] &&
	   [ "$(nmcli -g GENERAL.CON-UUID device show "$device" 2>/dev/null || true)" = "$uuid" ]; then
		nmcli --wait 30 connection up "$uuid" ifname "$device" || return 1
	fi
}

prepare_lan_route_change() {
	nm_route_change=0
	nm_uuid=
	nm_device=
	nm_original_never_default=
	keep_devs=$(ip -4 route show default | awk -v wan="$wan" '
		{
			for (i = 1; i < NF; i++)
				if ($i == "dev") {
					if ($(i + 1) != wan && !seen[$(i + 1)]++)
						printf "%s ", $(i + 1)
					break
				}
		}
	')
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

# Every connected IPv4 subnet except the WAN, lo and link-local, including the management port.
all_lan_cidrs() {
	ip -4 -o route show scope link proto kernel |
		awk -v wan="$wan" '
			$1 ~ /^[0-9.]+\/[0-9]+$/ && $1 !~ /^169\.254\./ {
				for (i = 1; i <= NF; i++)
					if ($i == "dev" && $(i + 1) != wan && $(i + 1) != "lo" && !seen[$1]++)
						printf "%s%s", (n++ ? "," : ""), $1
			}'
}

read_input() {
	prompt=$1
	printf '%s' "$prompt"
	IFS= read -r REPLY || fail "input ended before configuration was complete"
}

apply_options() {
	require_root
	require_ipt
	command -v ip >/dev/null 2>&1 || fail "the ip command is required to configure NAT routing"

	if systemctl is-active --quiet firewalld 2>/dev/null; then
		fail "firewalld is active; refusing to bypass its rule manager"
	fi
	if chain_present; then
		if [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] &&
		   state_is_managed; then
			fail "an XGS NAT table is already applied; use 'undo' first"
		fi
		fail "chain nat/$CHAIN already exists and is not recognized; refusing to touch it"
	fi
	if [ -e "$STATE_FILE" ] || [ -L "$STATE_FILE" ]; then
		fail "a previous state record exists; use 'undo' to clear it before applying"
	fi

	ip_forward=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || true)
	case $ip_forward in
		1) forward_config=none ;;
		0)
			command -v sysctl >/dev/null 2>&1 ||
				fail "sysctl is required to enable IPv4 forwarding for NAT"
			[ ! -e "$SYSCTL_CONFIG" ] && [ ! -L "$SYSCTL_CONFIG" ] ||
				fail "$SYSCTL_CONFIG already exists; refusing to overwrite it"
			forward_config=created
			;;
		*) fail "could not read the IPv4 forwarding setting" ;;
	esac

	printf '%s\n' 'WAN choices only (other OCTEP ports remain LAN):'
	list_copper_ports
	if [ -n "${1:-}" ]; then
		wan_port=$1
	else
		read_input 'WAN physical port (2 or 4) [2]: '
		wan_port=${REPLY:-2}
	fi
	case $wan_port in
		2|4) ;;
		*) fail "select WAN physical port 2 or 4" ;;
	esac
	ensure_wan_interface "$wan_port"
	wan=$(interface_for_port "$wan_port") ||
		fail "WAN physical port $wan_port is not available"
	prepare_wan_profile
	prepare_lan_route_change

	if [ "${2:-}" = --all-lans ]; then
		lan_cidrs=$(all_lan_cidrs)
		[ -n "$lan_cidrs" ] || fail "no connected LAN subnets found besides the WAN"
		printf 'All connected LAN subnets (including management): %s\n' "$lan_cidrs"
	else
		read_input 'LAN source IPv4 subnet(s), comma-separated CIDR: '
		lan_cidrs=$REPLY
	fi
	validate_lan_cidrs "$lan_cidrs" ||
		fail "enter one or more valid IPv4 CIDRs separated by commas"

	printf '\n%s\n' 'Planned operation (no rules have been changed yet):'
	printf '  LAN source subnet(s): %s\n  WAN: %s (physical port %s, link %s)\n' \
		"$lan_cidrs" "$wan" "$wan_port" "$(port_carrier "$wan")"
	printf '  WAN IPv4: configure DHCP on %s\n' "$wan"
	printf '  LAN routing: policy table %s sends the LAN subnets out %s; existing default routes are not changed%s\n' \
		"$PBR_TABLE" "$wan" "${keep_devs:+ (host traffic keeps using the default on: $keep_devs)}"
	if [ "$forward_config" = created ]; then
		printf '%s\n' '  IPv4 forwarding: enable now and persist in sysctl configuration'
	else
		printf '%s\n' '  IPv4 forwarding: already enabled'
	fi
	printf '%s\n' '  Scope: IPv4 source NAT only; no filter or port-forward rules.'

	state_tmp=
	sysctl_tmp=
	cleanup() {
		if [ -n "$state_tmp" ]; then
			rm -f "$state_tmp"
		fi
		if [ -n "$sysctl_tmp" ]; then
			rm -f "$sysctl_tmp"
		fi
	}
	trap cleanup EXIT
	trap 'exit 1' HUP INT TERM

	read_input 'Type APPLY to install the dedicated XGS_NAT iptables chain: '
	[ "$REPLY" = APPLY ] || fail "cancelled; no rules were applied"

	state_tmp=$(mktemp "${TMPDIR:-/tmp}/xgs-nat-state.XXXXXX") ||
		fail "could not create a temporary state record"
	umask 077
	{
		printf 'managed_by=xgs-nat-options-v2\n'
		printf 'wan=%s\nwan_port=%s\nlan_cidrs=%s\n' \
			"$wan" "$wan_port" "$lan_cidrs"
		printf 'wan_nm_uuid=%s\nwan_nm_created=%s\nwan_profile_name=%s\n' \
			"$wan_nm_uuid" "$wan_nm_created" "$wan_profile_name"
		printf 'wan_old_method=%s\nwan_old_never_default=%s\n' \
			"$wan_old_method" "$wan_old_never_default"
		printf 'wan_old_ignore_auto_routes=%s\nwan_old_autoconnect=%s\n' \
			"$wan_old_ignore_auto_routes" "$wan_old_autoconnect"
		printf 'lan_nm_uuid=%s\nlan_device=%s\nlan_never_default=%s\n' \
			"$nm_uuid" "$nm_device" "$nm_original_never_default"
		printf 'ip_forward_previous=%s\nip_forward_config=%s\n' \
			"$ip_forward" "$forward_config"
	} > "$state_tmp"
	[ ! -L "$STATE_DIR" ] || fail "NAT state directory must not be a symlink"
	install -d -m 0700 "$STATE_DIR" ||
		fail "could not create private NAT state directory $STATE_DIR"
	chmod 0700 "$STATE_DIR" ||
		fail "could not secure private NAT state directory $STATE_DIR"
	mv "$state_tmp" "$STATE_FILE"
	state_tmp=

	configure_wan_dhcp

	if [ "$forward_config" = created ]; then
		sysctl_tmp=$(mktemp /etc/sysctl.d/.xgs-nat.XXXXXX) ||
			fail "could not create a temporary sysctl configuration"
		printf 'net.ipv4.ip_forward=1\n' > "$sysctl_tmp" ||
			fail "could not write the IPv4 forwarding configuration"
		chmod 0644 "$sysctl_tmp" ||
			fail "could not set permissions on the IPv4 forwarding configuration"
		mv "$sysctl_tmp" "$SYSCTL_CONFIG" ||
			fail "could not install the IPv4 forwarding configuration"
		sysctl_tmp=
		sysctl -w net.ipv4.ip_forward=1 >/dev/null ||
			fail "could not enable IPv4 forwarding; run 'undo' to restore managed settings"
	fi

	old_ifs=$IFS
	IFS=,
	set -- $lan_cidrs
	IFS=$old_ifs
	if ! { chain_install "$wan" "$@" && policy_install "$wan" "$keep_devs" "$@"; }; then
		policy_remove
		chain_present && chain_remove 2>/dev/null || true
		rollback_ok=1
		restore_wan_profile "$wan_nm_uuid" "$wan_nm_created" "$wan_profile_name" \
			"$wan" "$wan_old_method" "$wan_old_never_default" \
			"$wan_old_ignore_auto_routes" "$wan_old_autoconnect" ||
			rollback_ok=0
		restore_forwarding "$ip_forward" "$forward_config" || rollback_ok=0
		if [ "$rollback_ok" -eq 1 ]; then
			rm -f "$STATE_FILE"
		else
			fail "iptables rejected the rules and rollback was incomplete; run 'undo' to restore managed settings"
		fi
		fail "iptables did not apply the proposed rules; changes were rolled back"
	fi
	printf '%s\n' 'NAT applied with DHCP configured on the selected WAN.'
	printf '%s\n' 'The LAN route and WAN DHCP profile changes are persistent and can be reverted with undo.'
	printf '%s\n' 'IPv4 forwarding is enabled persistently when it was previously disabled.'
	printf '%s\n' 'Rules are runtime-only and are not restored automatically after reboot.'
	printf '%s\n' 'To use a different WAN, run undo and apply again. This script does not fail over automatically.'
}

undo_options() {
	require_root
	require_ipt

	if [ ! -e "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ]; then
		if chain_present; then
			fail "chain nat/$CHAIN has no XGS ownership record; it was left untouched"
		fi
		printf '%s\n' 'No NAT rules managed by this script are recorded; nothing changed.'
		return
	fi
	[ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] ||
		fail "state record is not a regular file; refusing to change firewall rules"
	state_is_managed ||
		fail "state record is not recognized; refusing to change firewall rules"

	printf '%s\n' 'This undo removes only this script’s XGS_NAT chain and removes its policy routes and restores its saved WAN and forwarding settings.'
	read_input 'Type UNDO to continue: '
	[ "$REPLY" = UNDO ] || fail "cancelled; no rules were changed"

	if chain_present; then
		chain_remove ||
			fail "could not remove the managed XGS NAT table"
	else
		printf '%s\n' 'The managed NAT table is already absent.'
	fi
	policy_remove
	wan_nm_uuid=$(state_value wan_nm_uuid)
	wan_nm_created=$(state_value wan_nm_created)
	wan_profile_name=$(state_value wan_profile_name)
	wan_device=$(state_value wan)
	wan_old_method=$(state_value wan_old_method)
	wan_old_never_default=$(state_value wan_old_never_default)
	wan_old_ignore_auto_routes=$(state_value wan_old_ignore_auto_routes)
	wan_old_autoconnect=$(state_value wan_old_autoconnect)
	if [ "$wan_nm_created" = yes ] || [ -n "$wan_nm_uuid" ]; then
		restore_wan_profile "$wan_nm_uuid" "$wan_nm_created" "$wan_profile_name" \
			"$wan_device" "$wan_old_method" "$wan_old_never_default" \
			"$wan_old_ignore_auto_routes" "$wan_old_autoconnect" ||
			fail "removed NAT table, but could not restore the WAN DHCP profile"
	fi
	lan_nm_uuid=$(state_value lan_nm_uuid)
	lan_device=$(state_value lan_device)
	lan_never_default=$(state_value lan_never_default)
	if [ -n "$lan_nm_uuid" ] && [ -n "$lan_device" ] &&
	   [ -n "$lan_never_default" ]; then
		nm_set_never_default "$lan_nm_uuid" "$lan_device" "$lan_never_default" ||
			fail "removed the NAT table, but could not restore the saved LAN route setting"
	fi
	ip_forward_previous=$(state_value ip_forward_previous)
	ip_forward_config=$(state_value ip_forward_config)
	restore_forwarding "$ip_forward_previous" "$ip_forward_config" ||
		fail "removed the NAT table, but could not restore IPv4 forwarding; state was retained"
	rm -f -- "$STATE_FILE" || fail "could not remove the state record"
	rmdir "$STATE_DIR" 2>/dev/null || true
	printf '%s\n' 'Managed NAT options undone; saved WAN DHCP, LAN routing, and forwarding settings were restored.'
}

usage() {
	printf 'Usage: %s [status|apply [2|4] [--all-lans]|undo|--help]\n' "$0"
	printf '%s\n' \
		'  status  Detect components and report this script’s managed table (read-only).' \
			'  apply   Select one WAN and configure IPv4 NAT after confirmation;' \
			'          --all-lans NATs every connected LAN subnet, management included.' \
			'  undo    Remove this script’s NAT and restore its saved network settings.'
}

case ${1:-status} in
	status)
		[ "$#" -le 1 ] || { usage >&2; exit 64; }
		show_status
		;;
	apply)
		[ "$#" -le 3 ] || { usage >&2; exit 64; }
		[ "$#" -eq 1 ] || case $2 in 2|4) ;; *) usage >&2; exit 64 ;; esac
		[ "$#" -le 2 ] || [ "$3" = --all-lans ] || { usage >&2; exit 64; }
		apply_options "${2:-}" "${3:-}"
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
