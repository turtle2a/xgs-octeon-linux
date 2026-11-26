#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 turtle2a <354865938+turtle2a@users.noreply.github.com>
set -eu

SYSFS_ROOT=${OCTEP_SYSFS_ROOT:-/sys/bus/pci/devices}
DRIVER_ROOT=${OCTEP_DRIVER_SYSFS_ROOT:-/sys/bus/pci/drivers}
DEVICE=${OCTEP_DEVICE_SYSFS:-}
BRINGUP_UNIT=xgs-octep-sdp-bringup.service
RECOVERY_MARKER=${OCTEP_RECOVERY_MARKER:-/run/xgs-octep-sdp-recovery-attempted}
DHCP_ATTEMPT_DIR=${OCTEP_DHCP_ATTEMPT_DIR:-/run/xgs-octep-dhcp-attempted}

log() {
	printf 'xgs-octep-recover: %s\n' "$*"
}

skip() {
	log "no recovery: $*"
	exit 3
}

defer() {
	log "recovery deferred: $*"
	exit 5
}

blocked() {
	log "recovery refused: $*"
	exit 4
}

fail() {
	log "ERROR: $*"
	exit 1
}

state_value() {
	key=$1
	state=$2
	printf '%s\n' "$state" |
		sed -n "s/.*${key}=\\([^ ]*\\).*/\\1/p"
}

configure_octep_dhcp() {
	iface=$1
	# Optional: "manual <addr/prefix>" makes a LAN port static (it serves DHCP via Kea)
	method=${2:-auto}
	lan_addr=${3:-}
	profile_name=xgs-$iface-dhcp
	if ! command -v nmcli >/dev/null 2>&1; then
		log "WARNING: nmcli is unavailable; cannot configure DHCP on $iface"
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
			ipv6.method link-local \
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
		ipv6.method link-local \
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

FORCE=0
case "${1:-}" in
--auto) ;;
--wedged) FORCE=1 ;;
*)
	echo "Usage: $0 --auto | --wedged" >&2
	echo "  --auto    invoked by the root SDP status service" >&2
	echo "  --wedged  operator-run: reset an armed-but-idle NPU that never answers the handshake" >&2
	exit 64
	;;
esac
[ "$(id -u)" -eq 0 ] || fail "must run as root"

# One recovery at a time: the status timer's --auto and an operator --wedged must not both reset the bus.
exec 9>"${OCTEP_RECOVER_LOCK:-/run/xgs-octep-recover.lock}"
flock -n 9 || skip "another recovery is already running"

if [ -z "$DEVICE" ]; then
	for candidate in "$SYSFS_ROOT"/*; do
		[ -r "$candidate/vendor" ] && [ -r "$candidate/device" ] || continue
		[ "$(cat "$candidate/vendor")" = 0x177d ] || continue
		[ "$(cat "$candidate/device")" = 0xa300 ] || continue
		[ -z "$DEVICE" ] || blocked "multiple OCTEP PFs found; select one explicitly"
		DEVICE=$candidate
	done
fi
[ -n "$DEVICE" ] && [ -d "$DEVICE" ] || defer "OCTEP PF is not present yet"
[ -L "$DEVICE/driver" ] || defer "OCTEP PF is not bound yet"
[ "$(basename "$(readlink -f "$DEVICE/driver")")" = octep ] ||
	defer "OCTEP PF is not bound to octep yet"
[ -r "$DEVICE/sdp_state" ] || defer "SDP state is not available yet"

STATE=$(cat "$DEVICE/sdp_state") || defer "cannot read SDP state yet"
RINGS=$(state_value rings "$STATE")
RING_COUNT=$(state_value ring_count "$STATE")
HANDSHAKE=$(state_value handshake "$STATE")
SCRATCH=$(state_value scratch "$STATE")
FRONT_NETDEVS=$(state_value front_netdevs "$STATE")
PACKET_SERVICE=$(state_value packet_service "$STATE")
[ -n "$RINGS" ] && [ -n "$RING_COUNT" ] && [ -n "$HANDSHAKE" ] &&
	[ -n "$SCRATCH" ] && [ -n "$FRONT_NETDEVS" ] &&
	[ -n "$PACKET_SERVICE" ] || blocked "unrecognized SDP state: $STATE"

WEDGED=0
case $RINGS:$RING_COUNT:$HANDSHAKE:$FRONT_NETDEVS:$PACKET_SERVICE in
stopped:0:idle:0:disabled|armed:8:completed:10:rx-poll,tx-ring0) ;;
armed:8:idle:0:rx-poll,tx-ring0)
	[ "$FORCE" -eq 1 ] && [ "$SCRATCH" = 0x0000000000000000 ] &&
		WEDGED=1
	[ "$WEDGED" -eq 1 ] ||
		skip "state is not safely resettable: $STATE (an operator can use --wedged)"
	;;
*) skip "state is not safely resettable: $STATE" ;;
esac
if [ "$WEDGED" -eq 1 ]; then
	systemctl stop "$BRINGUP_UNIT" ||
		fail "could not stop $BRINGUP_UNIT"
	sleep 1
	for busy in sdp-bringup.sh rpc-port-setup.sh octep-hook-live.sh; do
		pgrep -f "$busy" >/dev/null 2>&1 &&
			blocked "$busy is running; stop it first"
	done
fi
case $SCRATCH in
0x0000000000000001|0x000000000000001f) ;;
0x0000000000000000) [ "$WEDGED" -eq 1 ] ||
	blocked "unexpected handshake scratch $SCRATCH; only the observed 0x1 and 0x1f states are reset automatically" ;;
*) blocked "unexpected handshake scratch $SCRATCH; only the observed 0x1 and 0x1f states are reset automatically" ;;
esac
if [ "$RINGS:$RING_COUNT:$HANDSHAKE:$FRONT_NETDEVS:$PACKET_SERVICE" = \
	"armed:8:completed:10:rx-poll,tx-ring0" ]; then
	if [ -e "$RECOVERY_MARKER" ]; then
		rm -f "$RECOVERY_MARKER" ||
			fail "could not re-arm automatic recovery after healthy state"
		log "NPU and OCTEPs are healthy; recovery guard re-armed for a future failure"
	else
		log "NPU and OCTEPs are healthy; checking DHCP on all OCTEP interfaces"
	fi
	configure_all_octep_dhcp
	exit 3
fi
[ ! -e "$RECOVERY_MARKER" ] || [ "$FORCE" -eq 1 ] ||
	skip "one automatic reset was already attempted this boot"

BDF=${DEVICE##*/}
[ "$BDF" = 0000:01:00.0 ] ||
	blocked "unexpected OCTEP PCI address $BDF"
DEVICE_PATH=$(readlink -f "$DEVICE") || fail "cannot resolve PCI device path"
PARENT_PATH=${DEVICE_PATH%/*}
PARENT_BDF=${PARENT_PATH##*/}
[ "$PARENT_BDF" = 0000:00:01.1 ] ||
	blocked "unexpected upstream bridge $PARENT_BDF"
[ -r "$PARENT_PATH/class" ] &&
	[ "$(cat "$PARENT_PATH/class")" = 0x060400 ] ||
	blocked "upstream device is not a PCI-to-PCI bridge"

# A prior octep load can leave SR-IOV VFs (01:00.1-.4) enabled; rmmod does not
# tear them down, so they linger as sibling PCI functions on the NPU bus and
# would otherwise permanently block the isolation check below on every
# subsequent recovery attempt. Disable them here; this is a no-op if already 0.
if [ -w "$DEVICE/sriov_numvfs" ]; then
	CURRENT_VFS=$(cat "$DEVICE/sriov_numvfs" 2>/dev/null || echo 0)
	if [ "$CURRENT_VFS" != "0" ]; then
		log "disabling $CURRENT_VFS leftover SR-IOV VF(s) on $BDF before bus isolation check"
		if ! echo 0 >"$DEVICE/sriov_numvfs" 2>/dev/null; then
			# octep_sriov_configure() refuses changes while SDP is active or the
			# handshake scratch is owned, which is the wedged state recovery runs in.
			# The VFs are unbound, so remove them as PCI functions instead; the bus
			# reset later in recovery resets the PF's SR-IOV state.
			log "WARNING: sriov_numvfs refused (driver busy); removing unbound VF functions directly"
			for vf in "$DEVICE"/virtfn*; do
				[ -e "$vf" ] || continue
				vf_path=$(readlink -f "$vf")
				[ -e "$vf_path/driver" ] && fail "VF $(basename "$vf_path") is bound to a driver; refusing to remove"
				# A plain shell redirect to remove was refused here and a bare write can hang, so
				# go through tee under a timeout; a stuck VF is logged, not fatal.
				echo 1 | timeout 10 tee "$vf_path/remove" >/dev/null 2>&1 ||
					log "WARNING: could not remove VF function $(basename "$vf_path")"
			done
			echo 1 | timeout 10 tee /sys/bus/pci/rescan >/dev/null 2>&1 || true
		fi
		sleep 1
	fi
fi

BUS_PREFIX=${BDF%:*}
BUS_DEVICE_COUNT=0
for candidate in "$SYSFS_ROOT/$BUS_PREFIX":*; do
	[ -d "$candidate" ] || continue
	BUS_DEVICE_COUNT=$((BUS_DEVICE_COUNT + 1))
	[ "${candidate##*/}" = "$BDF" ] ||
		blocked "another PCI function shares NPU bus $BUS_PREFIX"
done
[ "$BUS_DEVICE_COUNT" -eq 1 ] ||
	blocked "could not verify an isolated NPU bus"
[ -r "$DEVICE/reset_method" ] && [ -w "$DEVICE/reset_method" ] &&
	[ -w "$DEVICE/reset" ] || blocked "PCI reset controls are unavailable"
case " $(cat "$DEVICE/reset_method") " in
*" bus "*) ;;
*) blocked "PCI bus reset is not listed as supported" ;;
esac

log "blocked SDP state detected on $BDF; stopping bring-up before PCI bus reset"
systemctl stop "$BRINGUP_UNIT" ||
	fail "could not stop $BRINGUP_UNIT"
printf 'attempted\n' > "$RECOVERY_MARKER" ||
	fail "could not create per-boot recovery marker $RECOVERY_MARKER"

restore_device() {
	rc=$?
	if [ -d "$DEVICE" ]; then
		printf 'default\n' > "$DEVICE/reset_method" ||
			log "WARNING: could not restore reset_method"
		if [ ! -L "$DEVICE/driver" ] && [ -w "$DRIVER_ROOT/octep/bind" ]; then
			printf '%s\n' "$BDF" > "$DRIVER_ROOT/octep/bind" ||
				log "WARNING: could not restore OCTEP binding"
		fi
	fi
	exit "$rc"
}
trap restore_device EXIT

printf 'bus\n' > "$DEVICE/reset_method" ||
	fail "could not select PCI bus reset"
[ "$(cat "$DEVICE/reset_method")" = bus ] ||
	fail "PCI bus reset method did not read back"
printf '%s\n' "$BDF" > "$DRIVER_ROOT/octep/unbind" ||
	fail "could not unbind OCTEP"
log "asserting PCI bus reset on isolated NPU bus $BUS_PREFIX"
printf '1\n' > "$DEVICE/reset" || fail "PCI bus reset failed"
printf 'default\n' > "$DEVICE/reset_method" ||
	fail "could not restore default PCI reset methods"
printf '%s\n' "$BDF" > "$DRIVER_ROOT/octep/bind" ||
	fail "could not rebind OCTEP"
trap - EXIT

ATTEMPT=0
while [ "$ATTEMPT" -lt 60 ]; do
	STATE=$(cat "$DEVICE/sdp_state") || fail "cannot read SDP state after reset"
	SCRATCH=$(state_value scratch "$STATE")
	[ "$SCRATCH" = 0x0000000000000000 ] && break
	ATTEMPT=$((ATTEMPT + 1))
	[ "$ATTEMPT" -lt 60 ] && sleep 2
done
printf '%s\n' "$STATE"
[ "$SCRATCH" = 0x0000000000000000 ] ||
	fail "NPU scratch did not clear after reset; leaving bring-up stopped"

systemctl reset-failed "$BRINGUP_UNIT" ||
	fail "could not clear the bring-up unit failure state"
if ! systemctl start "$BRINGUP_UNIT"; then
	systemctl stop "$BRINGUP_UNIT" ||
		log "WARNING: could not stop failed bring-up retries"
	fail "SDP bring-up failed after NPU reset"
fi

STATE=$(cat "$DEVICE/sdp_state") || fail "cannot read final SDP state"
printf '%s\n' "$STATE"
case "$STATE" in
*"rings=armed"*"handshake=completed"*"packet_service=rx-poll,tx-ring0"*)
	;;
*)
	systemctl stop "$BRINGUP_UNIT" ||
		log "WARNING: could not stop incomplete bring-up retries"
	fail "SDP state did not reach the expected ready state"
	;;
esac

# Offload is opt-in: only require it when the module was loaded with flow_offload=Y.
if [ "$(cat /sys/module/octep/parameters/flow_offload 2>/dev/null)" = Y ]; then
	[ "$(cat "$DEVICE/rpc_allow_write" 2>/dev/null)" = 1 ] &&
		case $(cat "$DEVICE/offload" 2>/dev/null) in *requested=on*acknowledged=yes*) true ;; *) false ;; esac ||
		fail "SDP rings are up but NPU flow offload is not enabled (gate: $(cat "$DEVICE/offload" 2>/dev/null))"
fi

configure_all_octep_dhcp
log "NPU recovery and SDP bring-up succeeded"
