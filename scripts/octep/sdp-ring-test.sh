#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

SYSFS_ROOT=${OCTEP_SYSFS_ROOT:-/sys/bus/pci/devices}
DEVICE=${OCTEP_DEVICE_SYSFS:-}
KVER=${KVER:-$(uname -r)}
MODULE=${OCTEP_MODULE_KO:-}
DMESG_LINES=${OCTEP_TEST_DMESG_LINES:-25}
KMSG_AVAILABLE=0
[ -w /dev/kmsg ] && KMSG_AVAILABLE=1

fail() {
	message="ERROR: $*"
	echo "xgs-octep-ring-test: $message" >&2
	log "$message"
	exit 1
}

log() {
	message=$*
	echo "xgs-octep-ring-test: $message"
	if [ "$KMSG_AVAILABLE" -eq 1 ] &&
	   ! printf '<6>xgs-octep-ring-test: %s\n' "$message" > /dev/kmsg 2>/dev/null; then
		KMSG_AVAILABLE=0
	fi
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

[ "$(id -u)" -eq 0 ] || fail "run as root (for example: sudo $0)"
for command in basename cat dmesg grep id insmod modinfo readlink rmmod sed sleep uname; do
	require_command "$command"
done
case $DMESG_LINES in
	''|*[!0-9]*) fail "OCTEP_TEST_DMESG_LINES must be a positive integer" ;;
esac
[ "$DMESG_LINES" -gt 0 ] || fail "OCTEP_TEST_DMESG_LINES must be a positive integer"
if [ -z "$MODULE" ]; then
	MODULE=$(modinfo -k "$KVER" -n octep) ||
		fail "cannot locate the installed octep module for kernel $KVER"
fi
[ -r "$MODULE" ] || fail "OCTEP module not found: $MODULE"

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
[ -r "$DEVICE/sdp_state" ] && [ -w "$DEVICE/sdp_start" ] &&
	[ -w "$DEVICE/sdp_stop" ] ||
	fail "the octep driver lacks SDP ring controls"

state_value() {
	key=$1
	state=$2
	printf '%s\n' "$state" |
		sed -n "s/.*${key}=\\([^ ]*\\).*/\\1/p"
}

read_state() {
	STATE=$(cat "$DEVICE/sdp_state") || fail "cannot read SDP state"
	RINGS=$(state_value rings "$STATE")
	RING_COUNT=$(state_value ring_count "$STATE")
	HANDSHAKE=$(state_value handshake "$STATE")
	SCRATCH=$(state_value scratch "$STATE")
	[ -n "$RINGS" ] && [ -n "$RING_COUNT" ] &&
		[ -n "$HANDSHAKE" ] && [ -n "$SCRATCH" ] ||
		fail "unrecognized SDP state: $STATE"
}

read_state
[ "$HANDSHAKE" = idle ] ||
	fail "handshake is $HANDSHAKE; refusing to reload the driver"
[ "$SCRATCH" = 0x0000000000000000 ] ||
	fail "handshake scratch is $SCRATCH; refusing to reload the driver"

case $RINGS:$RING_COUNT in
armed:8)
	printf '1\n' >"$DEVICE/sdp_stop" ||
		fail "could not stop SDP rings"
	read_state
	[ "$RINGS:$RING_COUNT" = stopped:0 ] ||
		fail "rings did not stop cleanly: $STATE"
	;;
stopped:0)
	;;
*)
	fail "unexpected ring state; refusing to reload: $STATE"
	;;
esac

module_vermagic=$(modinfo -F vermagic "$MODULE") ||
	fail "cannot read module vermagic from $MODULE"
[ "${module_vermagic%% *}" = "$KVER" ] ||
	fail "module vermagic does not match kernel $KVER"

log "unloading old octep module"
log "NetworkManager settings are unchanged; it may reactivate DHCP on the OCTEP management interface"
rmmod octep || fail "could not unload octep; no forced removal attempted"
log "loading $MODULE"
insmod "$MODULE" || fail "could not load $MODULE; device remains unbound"

attempt=0
while [ ! -r "$DEVICE/sdp_state" ] && [ "$attempt" -lt 20 ]; do
	attempt=$((attempt + 1))
	sleep 0.1
done
[ -r "$DEVICE/sdp_state" ] ||
	fail "octep did not bind after module load"
[ -w "$DEVICE/sdp_port_add" ] ||
	fail "loaded module lacks sdp_port_add; it is not the updated datapath build"

read_state
[ "$RINGS:$RING_COUNT" = stopped:0 ] ||
	fail "new module did not start with stopped rings: $STATE"
case $STATE in
	*"packet_service=disabled"*) ;;
	*) fail "updated packet service marker is missing: $STATE" ;;
esac

printf '1\n' >"$DEVICE/sdp_start" ||
	fail "SDP ring start failed"
read_state
[ "$RINGS:$RING_COUNT" = armed:8 ] ||
	fail "new module did not arm all eight rings: $STATE"
case $STATE in
	*"packet_service=rx-poll,tx-ring0"*) ;;
	*) fail "new ring packet-service marker is missing: $STATE" ;;
esac

log "PASS - rings armed, RX polling enabled, TX ring available"
log "handshake was not started; no packet traffic was sent"
dmesg | grep -iE 'octep|dp:' | tail -n "$DMESG_LINES"
