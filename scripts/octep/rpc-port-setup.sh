#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

SYSFS_ROOT=${OCTEP_SYSFS_ROOT:-/sys/bus/pci/devices}
DEVICE=${OCTEP_DEVICE_SYSFS:-}
NWA_WAIT=${NWA_WAIT:-40}
NWA_DISCOVERY_WAIT=${NWA_DISCOVERY_WAIT:-140}
RPC_WAIT=${RPC_WAIT:-140}
LOGFILE=${LOGFILE:-/var/log/xgs-octep-port-setup.log}
SYSCTL_BIN=${SYSCTL_BIN:-sysctl}
NET_CLASS_ROOT=${OCTEP_NET_CLASS_ROOT:-/sys/class/net}

# Defaults match the XGS 3300 panel; override these maps for another board.
CAGE_MAP=${OCTEP_CAGE_MAP:-"10:1 11:2"}
SWITCH_MAP=${OCTEP_SWITCH_MAP:-"0:33024 1:33280 2:33536 3:33792 4:34048 5:34304 6:34560 7:34816 8:35072 9:35328"}
WAN_PORT=
if [ "$#" -gt 0 ]; then
	[ "$#" -eq 2 ] && [ "$1" = --wan-port ] ||
		{ echo "Usage: $0 [--wan-port 2|4]" >&2; exit 64; }
	WAN_PORT=$2
	case $WAN_PORT in
		2|4) ;;
		*) echo "Usage: $0 [--wan-port 2|4]" >&2; exit 64 ;;
	esac
fi

fail() {
	echo "xgs-octep-port-setup: $*" >&2
	exit 1
}

set_sysctl() {
	key=$1
	value=$2
	if ! "$SYSCTL_BIN" -w "$key=$value" >/dev/null 2>&1; then
		fail "could not enable required host-readiness sysctl $key=$value"
	fi
	actual=$("$SYSCTL_BIN" -n "$key" 2>/dev/null) ||
		fail "could not verify host-readiness sysctl $key"
	[ "$actual" = "$value" ] ||
		fail "host-readiness sysctl $key is $actual, expected $value"
	log "host-readiness sysctl $key=$actual"
}

configure_forwarding_sysctls() {
	set_sysctl net.ipv4.ip_forward 1
	set_sysctl net.ipv4.conf.all.forwarding 1
	set_sysctl net.ipv4.conf.default.forwarding 1
	set_sysctl net.ipv4.conf.all.bc_forwarding 1

	interface_count=0
	for interface_path in "$NET_CLASS_ROOT"/octep[0-9]*; do
		[ -e "$interface_path" ] || continue
		interface=${interface_path##*/}
		interface_count=$((interface_count + 1))
		set_sysctl "net.ipv4.conf.$interface.forwarding" 1
		set_sysctl "net.ipv4.conf.$interface.bc_forwarding" 1
		set_sysctl "net.ipv6.conf.$interface.force_forwarding" 1
		set_sysctl "net.ipv6.conf.$interface.forwarding" 1
	done
	log "host forwarding configured on $interface_count current OCTEP netdevs"
}

# The kernel only sets mc_forwarding while a multicast routing daemon holds the
# MRT socket; restart it after the OCTEP netdevs exist so it adds a VIF for each.
refresh_multicast_router() {
	command -v systemctl >/dev/null 2>&1 || return 0
	systemctl cat smcroute.service >/dev/null 2>&1 || return 0
	systemctl enable --now smcroute.service >/dev/null 2>&1 || true
	# A restart briefly toggles allmulticast on every port, so skip it when every port already has mc_forwarding=1.
	mc_need=0
	for mc_path in "$NET_CLASS_ROOT"/octep[0-9]*; do
		[ -e "$mc_path" ] || continue
		[ "$("$SYSCTL_BIN" -n "net.ipv4.conf.${mc_path##*/}.mc_forwarding" 2>/dev/null)" = 1 ] || mc_need=1
	done
	if [ "$mc_need" = 1 ]; then
		systemctl restart smcroute.service >/dev/null 2>&1 ||
			log "WARNING: could not restart smcroute.service"
	fi
	mc_wait=0
	while [ "$mc_wait" -lt 10 ]; do
		[ "$("$SYSCTL_BIN" -n net.ipv4.conf.all.mc_forwarding 2>/dev/null)" = 1 ] && break
		mc_wait=$((mc_wait + 1))
		sleep 1
	done
}

report_multicast_forwarding() {
	for mc_family in ipv4 ipv6; do
		mc_global=$("$SYSCTL_BIN" -n "net.$mc_family.conf.all.mc_forwarding" 2>/dev/null) ||
			mc_global=unavailable
		mc_disabled=0
		mc_unknown=0
		for mc_path in "$NET_CLASS_ROOT"/octep[0-9]*; do
			[ -e "$mc_path" ] || continue
			mc_interface=${mc_path##*/}
			mc_value=$("$SYSCTL_BIN" -n "net.$mc_family.conf.$mc_interface.mc_forwarding" 2>/dev/null) ||
				mc_value=unavailable
			case $mc_value in
				1) ;;
				0) mc_disabled=$((mc_disabled + 1)) ;;
				*) mc_unknown=$((mc_unknown + 1)) ;;
			esac
		done
		if [ "$mc_global" = 1 ] && [ "$mc_disabled" -eq 0 ] && [ "$mc_unknown" -eq 0 ]; then
			log "host $mc_family multicast forwarding sysctls are enabled"
		else
			log "WARNING: host $mc_family multicast forwarding is not fully enabled (all=$mc_global, disabled ports=$mc_disabled, unknown ports=$mc_unknown); multicast routing needs a routing daemon (install smcroute and enable smcroute.service)" >&2
		fi
	done
}

log() {
	message=$*
	printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$message" \
		>>"$LOGFILE" 2>/dev/null || true
	echo "$message"
}

case $NWA_WAIT in
	''|*[!0-9]*) fail "NWA_WAIT must be a non-negative integer" ;;
esac
[ "$NWA_WAIT" -gt 0 ] || fail "NWA_WAIT must be greater than zero"
case $NWA_DISCOVERY_WAIT in
	''|*[!0-9]*) fail "NWA_DISCOVERY_WAIT must be a non-negative integer" ;;
esac
[ "$NWA_DISCOVERY_WAIT" -gt 0 ] ||
	fail "NWA_DISCOVERY_WAIT must be greater than zero"
case $RPC_WAIT in
	''|*[!0-9]*) fail "RPC_WAIT must be a non-negative integer" ;;
esac
[ "$RPC_WAIT" -gt 0 ] || fail "RPC_WAIT must be greater than zero"

validate_map() {
	map_name=$1
	map_value=$2

	case $map_value in
		*[!0-9:\ ]*) fail "$map_name must contain only iface:tag pairs separated by spaces" ;;
	esac
	for entry in $map_value; do
		case $entry in
			*:*:*) fail "invalid $map_name entry: $entry" ;;
			*:*) ;;
			*) fail "invalid $map_name entry: $entry" ;;
		esac
		iface=${entry%%:*}
		tag=${entry#*:}
		[ -n "$iface" ] && [ -n "$tag" ] ||
			fail "invalid $map_name entry: $entry"
		[ "$iface" -le 127 ] && [ "$tag" -le 65535 ] ||
			fail "$map_name entry is out of range: $entry"
	done
}

validate_map OCTEP_CAGE_MAP "$CAGE_MAP"
validate_map OCTEP_SWITCH_MAP "$SWITCH_MAP"

SELECTED_IFACE=
SELECTED_TAG=
if [ -n "$WAN_PORT" ]; then
	SELECTED_IFACE=$((WAN_PORT - 1))
	for entry in $SWITCH_MAP; do
		if [ "${entry%%:*}" = "$SELECTED_IFACE" ]; then
			SELECTED_TAG=${entry#*:}
			break
		fi
	done
	[ -n "$SELECTED_TAG" ] ||
		fail "no switch-port mapping exists for WAN physical port $WAN_PORT"
fi

if [ -z "$DEVICE" ]; then
	for candidate in "$SYSFS_ROOT"/*; do
		[ -r "$candidate/vendor" ] && [ -r "$candidate/device" ] || continue
		[ "$(cat "$candidate/vendor")" = 0x177d ] || continue
		[ "$(cat "$candidate/device")" = 0xa300 ] || continue
		if [ -n "$DEVICE" ]; then
			fail "multiple OCTEP PFs found; set OCTEP_DEVICE_SYSFS to one PCI function"
		fi
		DEVICE=$candidate
	done
fi

[ -n "$DEVICE" ] && [ -d "$DEVICE" ] ||
	fail "PCI function 177d:a300 was not found"
[ -L "$DEVICE/driver" ] &&
	[ "$(basename "$(readlink "$DEVICE/driver")")" = octep ] ||
	fail "$(basename "$DEVICE") is not bound to the octep driver"

for attr in sdp_state rpc_state rpc_configure rpc_allow_write rpc_lif_add \
	rpc_pport_update nwa_discover nwa_ports nwa_request nwa_last; do
	[ -r "$DEVICE/$attr" ] || fail "the octep driver lacks $attr"
done
for attr in sdp_port_add rpc_configure rpc_allow_write rpc_lif_add rpc_pport_update \
	nwa_discover nwa_request; do
	[ -w "$DEVICE/$attr" ] || fail "$attr is not writable"
done

state_value() {
	key=$1
	state=$2
	printf '%s\n' "$state" |
		sed -n "s/.*${key}=\\([^ ]*\\).*/\\1/p"
}

STATE=$(cat "$DEVICE/sdp_state") || fail "cannot read SDP state"
[ "$(state_value rings "$STATE")" = armed ] ||
	fail "SDP rings are not armed; run sdp-bringup.sh first"
[ "$(state_value handshake "$STATE")" = completed ] ||
	fail "EP-mode handshake is not complete; run sdp-bringup.sh first"

RPC_STATE=$(cat "$DEVICE/rpc_state") || fail "cannot read RPC state"
if [ "$(state_value configured "$RPC_STATE")" != 1 ]; then
	[ "$(state_value ready "$RPC_STATE")" = 1 ] ||
		fail "RPC facility is not ready: $RPC_STATE"
	rpc_start=$(date +%s)
	rpc_attempt=0
	while [ "$(state_value configured "$RPC_STATE")" != 1 ]; do
		printf '1\n' >"$DEVICE/barmap_rescan" ||
			fail "RPC barmap rescan failed; inspect the kernel journal"
		rpc_attempt=$((rpc_attempt + 1))
		if printf '1\n' >"$DEVICE/rpc_configure" 2>/dev/null; then
			RPC_STATE=$(cat "$DEVICE/rpc_state") ||
				fail "cannot read RPC state"
			[ "$(state_value configured "$RPC_STATE")" = 1 ] ||
				fail "RPC configuration returned without configuring the ring: $RPC_STATE"
			log "RPC ring configured on attempt $rpc_attempt"
			break
		fi
		RPC_STATE=$(cat "$DEVICE/rpc_state") ||
			fail "cannot read RPC state after configuration timeout"
		[ "$(state_value configured "$RPC_STATE")" = 1 ] && break
		rpc_now=$(date +%s)
		rpc_elapsed=$((rpc_now - rpc_start))
		[ "$rpc_elapsed" -lt "$RPC_WAIT" ] ||
			fail "RPC ring was not acknowledged within ${RPC_WAIT}s: $RPC_STATE"
		log "RPC ring configuration attempt $rpc_attempt was not acknowledged; retrying ($rpc_elapsed/${RPC_WAIT}s)"
		sleep 1
	done
fi
[ "$(state_value configured "$RPC_STATE")" = 1 ] ||
	fail "RPC ring is not configured: $RPC_STATE"
[ "$(cat "$DEVICE/rpc_allow_write")" = 0 ] ||
	fail "RPC write gate is already open; close it before port setup"

nwa_attempt=0
while [ "$nwa_attempt" -lt "$NWA_DISCOVERY_WAIT" ]; do
	nwa_attempt=$((nwa_attempt + 1))
	if printf '1\n' >"$DEVICE/nwa_discover" 2>/dev/null; then
		PORTS=$(cat "$DEVICE/nwa_ports") || fail "cannot read NetAgent port list"
		if printf '%s\n' "$PORTS" | grep -q '^ports='; then
			log "NetAgent discovery succeeded on attempt $nwa_attempt"
			break
		fi
	fi
	[ "$nwa_attempt" -lt "$NWA_DISCOVERY_WAIT" ] ||
		fail "NetAgent mailbox did not become ready for discovery within ${NWA_DISCOVERY_WAIT}s"
	log "NetAgent mailbox is not ready for discovery; retrying ($nwa_attempt/${NWA_DISCOVERY_WAIT}s)"
	sleep 1
done

has_tag() {
	tag_text=$(printf '0x%04x' "$1")
	printf '%s\n' "$PORTS" |
		awk -v wanted="$tag_text" '$2 == wanted { found = 1 } END { exit !found }'
}

for entry in $SWITCH_MAP; do
	if [ -n "$WAN_PORT" ] && [ "${entry%%:*}" != "$SELECTED_IFACE" ]; then
		continue
	fi
	tag=${entry#*:}
	has_tag "$tag" ||
		fail "NetAgent discovery did not report required switch tag $tag"
done

request() {
	if printf '%s\n' "$1 $2 $3 $4 $5" >"$DEVICE/nwa_request"; then
		return 0
	fi
	return 1
}

last_nwa_succeeded() {
	last=$(cat "$DEVICE/nwa_last") || fail "cannot read NWA reply"
	error=$(printf '%s\n' "$last" | sed -n 's/.*error=\([-0-9]*\).*/\1/p')
	status=$(printf '%s\n' "$last" | sed -n 's/.*status=\([^ ]*\).*/\1/p')
	[ "$error" = 0 ] && [ -n "$status" ] && [ "$((status))" -eq 0 ]
}

nwa_get_mac() {
	port=$1
	attempt=0
	while [ "$attempt" -lt 3 ]; do
		attempt=$((attempt + 1))
		if request 4 3 "$port" 0 0; then
			last_nwa_succeeded || {
				sleep 2
				continue
			}
			words=$(printf '%s\n' "$last" | sed -n 's/.*words=\([0-9]*\).*/\1/p')
			word0=$(printf '%s\n' "$last" | sed -n 's/^word0=//p')
			word1=$(printf '%s\n' "$last" | sed -n 's/^word1=//p')
			if [ "$words" -ge 2 ] && [ -n "$word0" ] && [ -n "$word1" ]; then
				MAC_WORD0=$word0
				MAC_WORD1=$word1
				return 0
			fi
		fi
		sleep 2
	done
	return 1
}

mac_from_words() {
	word0=$(( $1 ))
	word1=$(( $2 ))
	printf '%02x:%02x:%02x:%02x:%02x:%02x' \
		$((word0 & 255)) $(((word0 >> 8) & 255)) \
		$(((word0 >> 16) & 255)) $(((word0 >> 24) & 255)) \
		$((word1 & 255)) $(((word1 >> 8) & 255))
}

mac_is_valid_unicast() {
	[ "$1" != 00:00:00:00:00:00 ] || return 1
	first_octet=${1%%:*}
	[ $((0x$first_octet & 1)) -eq 0 ]
}

GATE_OPEN=0
close_gate() {
	if [ "$GATE_OPEN" -eq 1 ]; then
		if printf '0\n' >"$DEVICE/rpc_allow_write"; then
			GATE_OPEN=0
		else
			echo "xgs-octep-port-setup: failed to close RPC write gate" >&2
		fi
	fi
}
trap close_gate EXIT
trap 'exit 1' HUP INT TERM

configure_forwarding_sysctls

attempt=0
while [ "$attempt" -lt "$NWA_WAIT" ]; do
	attempt=$((attempt + 1))
	if request 4 3 2 0 0; then
		if last_nwa_succeeded; then
			break
		fi
	fi
	sleep 1
done
[ "$attempt" -lt "$NWA_WAIT" ] ||
	fail "NetAgent did not answer after ${NWA_WAIT}s"

if [ -z "$WAN_PORT" ]; then
	# Bring up the two cages and switch uplink before mapping all front-panel ports.
	for port in 0 1 2; do
		request 3 0 "$port" 1 0 ||
			fail "could not raise NetAgent port $port"
	done
fi

printf '1\n' >"$DEVICE/rpc_allow_write" ||
	fail "could not open RPC write gate"
GATE_OPEN=1

configure_port() {
	iface=$1
	tag=$2
	set_mac=$3
	optional=${4:-0}

	if [ "$set_mac" -eq 1 ]; then
		request 3 0 "$tag" 1 0 ||
			fail "could not raise switch port tag $tag"
	fi
	if ! nwa_get_mac "$tag"; then
		if [ "$optional" -eq 1 ]; then
			log "optional cage tag $tag did not provide a MAC; skipping it"
			return 0
		fi
		fail "could not read MAC for port tag $tag"
	fi
	mac=$(mac_from_words "$MAC_WORD0" "$MAC_WORD1")
	if ! mac_is_valid_unicast "$mac"; then
		if [ "$optional" -eq 1 ]; then
			log "optional cage tag $tag returned invalid MAC $mac; skipping it"
			return 0
		fi
		fail "NetAgent returned invalid MAC $mac for port tag $tag"
	fi
	if [ "$set_mac" -eq 1 ]; then
		request 3 3 "$tag" "$((MAC_WORD0))" "$((MAC_WORD1))" ||
			fail "could not set MAC for port tag $tag"
	fi
	request 3 70 "$tag" 1 0 ||
		fail "could not enable all-multicast on NPU port tag $tag"
	last_nwa_succeeded ||
		fail "all-multicast enable was not acknowledged for NPU port tag $tag"
	log "NPU all-multicast enabled on port tag $tag"
	if ! printf '%s %s %s\n' "$iface" 0 "$mac" >"$DEVICE/rpc_lif_add"; then
		rpc_result=$(cat "$DEVICE/rpc_last" 2>/dev/null || echo "unavailable")
		fail "LIF_ADD_UPDATE failed for interface $iface ($rpc_result)"
	fi
	printf '%s %s\n' "$iface" "$tag" >"$DEVICE/rpc_pport_update" ||
		fail "PPORT_UPDATE failed for port tag $tag"
	printf '%s %s %s\n' "$tag" "$iface" "$mac" >"$DEVICE/sdp_port_add" ||
		fail "front-port netdev creation failed for port tag $tag"
	configure_forwarding_sysctls
	log "mapped port tag $tag to interface $iface ($mac)"
}

if [ -n "$WAN_PORT" ]; then
	configure_port "$SELECTED_IFACE" "$SELECTED_TAG" 1
else
	# The direct 10G cages use tags 1 and 2, but may be omitted from discovery.
	for entry in $CAGE_MAP; do
		configure_port "${entry%%:*}" "${entry#*:}" 0 1
	done
	for entry in $SWITCH_MAP; do
		configure_port "${entry%%:*}" "${entry#*:}" 1
	done
fi

configure_forwarding_sysctls
refresh_multicast_router
report_multicast_forwarding

printf '0\n' >"$DEVICE/rpc_allow_write" ||
	fail "port setup finished, but RPC write gate could not be closed"
GATE_OPEN=0
log "RPC mappings and SDP front-port netdevs are installed"
