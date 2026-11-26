#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 turtle2a <354865938+turtle2a@users.noreply.github.com>
# Gives the OCTEP LAN ports their router addresses (octep0 = 10.4.4.10/28,
# octepN = 10.4.(10+N).10/28) so Kea can serve DHCP on them. Uses
# NetworkManager profiles when nmcli exists, otherwise plain "ip addr".
# octep1 (WAN) and enp2s0 (management) are never touched.
# Run by xgs-nat.service before the NAT rules; safe to re-run.
set -u
DHCP_ATTEMPT_DIR=/run/xgs-octep-dhcp-attempted

log() {
	printf 'xgs-lan: %s\n' "$*"
}

configure_octep_dhcp() {
	iface=$1
	# Optional: "manual <addr/prefix>" makes a LAN port static (it serves DHCP via Kea)
	method=${2:-auto}
	lan_addr=${3:-}
	profile_name=xgs-$iface-dhcp
	if ! command -v nmcli >/dev/null 2>&1 || ! systemctl is-active --quiet NetworkManager; then
		if [ -n "$lan_addr" ]; then
			ip addr replace "$lan_addr" dev "$iface" && ip link set "$iface" up &&
				log "$iface: $lan_addr set with ip (no NetworkManager)"
		fi
		return 0
	fi

	active_uuid=$(nmcli -g GENERAL.CON-UUID device show "$iface" 2>/dev/null || true)
	case $active_uuid in
		''|--) active_uuid= ;;
	esac
	profile_uuid=$active_uuid

	if [ -z "$profile_uuid" ]; then
		profiles=$(nmcli -g UUID connection show) || {
			log "WARNING: could not list NetworkManager profiles for $iface"
			return 0
		}
		while IFS= read -r candidate_uuid; do
			[ -n "$candidate_uuid" ] || continue
			candidate_iface=$(nmcli -g connection.interface-name \
				connection show "$candidate_uuid") || {
				log "WARNING: could not inspect NetworkManager profile $candidate_uuid"
				return 0
			}
			if [ "$candidate_iface" = "$iface" ]; then
				if [ -n "$profile_uuid" ]; then
					log "WARNING: multiple NetworkManager profiles target $iface"
					return 0
				fi
				profile_uuid=$candidate_uuid
			fi
		done <<EOF
$profiles
EOF
	fi

	if [ -z "$profile_uuid" ]; then
		profile_uuid=$(nmcli -g connection.uuid connection show \
			"$profile_name" 2>/dev/null || true)
		case $profile_uuid in
			''|--)
				profile_uuid=
				;;
			*)
				candidate_iface=$(nmcli -g connection.interface-name \
					connection show "$profile_uuid") || {
					log "WARNING: could not inspect NetworkManager profile $profile_name"
					return 0
				}
				case $candidate_iface in
					''|--|"$iface") ;;
					*)
						log "WARNING: $profile_name is bound to $candidate_iface, not $iface"
						return 0
						;;
				esac
				nmcli connection modify "$profile_uuid" \
					connection.interface-name "$iface" || {
					log "WARNING: could not bind $profile_name to $iface"
					return 0
				}
				;;
		esac
	fi

	if [ -z "$profile_uuid" ]; then
		nmcli connection add type ethernet ifname "$iface" \
			con-name "$profile_name" ipv4.method "$method" \
			${lan_addr:+ipv4.addresses "$lan_addr"} \
			ipv6.method link-local 802-3-ethernet.cloned-mac-address permanent \
			ipv4.never-default yes ipv4.ignore-auto-routes no \
			connection.autoconnect yes connection.autoconnect-retries 0 || {
			log "WARNING: could not create a DHCP profile for $iface"
			return 0
		}
		profile_uuid=$(nmcli -g connection.uuid connection show "$profile_name") || {
			log "WARNING: created a DHCP profile for $iface but could not read its UUID"
			return 0
		}
	fi

	nmcli connection modify "$profile_uuid" ipv4.method "$method" \
		${lan_addr:+ipv4.addresses "$lan_addr" ipv4.never-default yes} \
		ipv6.method link-local 802-3-ethernet.cloned-mac-address permanent \
		connection.autoconnect yes connection.autoconnect-retries 0 || {
		log "WARNING: could not configure DHCP on $iface"
		return 0
	}

	address=$(nmcli -g IP4.ADDRESS device show "$iface" 2>/dev/null || true)
	case $address in
		''|--) address= ;;
	esac
	if [ -n "$address" ] &&
		[ "$active_uuid" = "$profile_uuid" ]; then
		rm -f "$DHCP_ATTEMPT_DIR/$iface"
		log "DHCP is active on $iface ($address); existing default-route policy was preserved"
		return 0
	fi

	now=$(date +%s) || {
		log "WARNING: could not read current time for DHCP retry on $iface"
		return 0
	}
	cycle_link=1
	if [ -e "$DHCP_ATTEMPT_DIR/$iface" ]; then
		last_attempt=$(cat "$DHCP_ATTEMPT_DIR/$iface" 2>/dev/null || true)
		case $last_attempt in
			''|*[!0-9]*) ;;
			*)
				elapsed=$((now - last_attempt))
				if [ "$elapsed" -lt 60 ]; then
					log "DHCP is pending on $iface; next activation in $((60 - elapsed))s"
					return 0
				fi
				cycle_link=0
				;;
		esac
	fi

	if [ "$cycle_link" -eq 1 ]; then
		mkdir -p "$DHCP_ATTEMPT_DIR" || {
			log "WARNING: could not create DHCP attempt marker directory"
			return 0
		}
		log "cycling $iface link once to restart DHCP activation"
		if ! ip link set dev "$iface" down; then
			log "WARNING: could not bring $iface link down for DHCP activation"
			return 0
		fi
		sleep 1
		if ! ip link set dev "$iface" up; then
			log "WARNING: could not bring $iface link up after DHCP activation cycle"
			return 0
		fi
	fi

	printf '%s\n' "$now" > "$DHCP_ATTEMPT_DIR/$iface" || {
		log "WARNING: could not record DHCP activation time for $iface"
		return 0
	}
	nmcli --wait 0 connection up "$profile_uuid" ifname "$iface" || {
		log "WARNING: could not activate or refresh DHCP on $iface"
		return 0
	}

	address=$(nmcli -g IP4.ADDRESS device show "$iface" 2>/dev/null || true)
	case $address in
		''|--) address= ;;
	esac
	if [ -z "$address" ]; then
		log "DHCP activation requested on $iface; no IPv4 lease yet"
		return 0
	fi
	log "DHCP is active on $iface ($address); existing default-route policy was preserved"
}

configure_all_octep_dhcp() {
	# LAN ports only: octep0 is 10.4.4.0/28 and octepN (N >= 2) is
	# 10.4.(10+N).0/28, router at .10; Kea (kea/kea-dhcp4.conf) hands
	# out .2-.9 on each. octep1 (WAN) and enp2s0 (management) are left to the
	# operator and are never modified here.
	configure_octep_dhcp octep0 manual 10.4.4.10/28
	port=2
	while [ "$port" -lt 10 ]; do
		configure_octep_dhcp "octep$port" manual "10.4.$((10 + port)).10/28"
		port=$((port + 1))
	done
	# Kea only binds interfaces that already have an address, so restart it once
	# per boot after the LAN addresses are in place.
	if [ ! -e /run/xgs-kea-rebound ] && ip -4 -o addr show dev octep0 2>/dev/null | grep -q inet; then
		for u in kea-dhcp4.service kea-dhcp4-server.service; do
			systemctl try-restart "$u" >/dev/null 2>&1
		done
		: >/run/xgs-kea-rebound
		log "restarted Kea DHCP after the LAN addresses were applied"
	fi
}

# The interfaces appear when SDP bring-up finishes; wait for them.
i=0
while [ "$i" -lt 120 ] && ! ip link show octep0 >/dev/null 2>&1; do
	[ "$i" -eq 0 ] && log "waiting for octep0 (SDP bring-up)"
	sleep 1
	i=$((i + 1))
done
ip link show octep0 >/dev/null 2>&1 || { log "octep0 not present; nothing to do"; exit 0; }
configure_all_octep_dhcp
exit 0
