#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

SYSFS_ROOT=${OCTEP_SYSFS_ROOT:-/sys/bus/pci/devices}
DEVICE=${OCTEP_DEVICE_SYSFS:-}
WARMUP=${COPROC_WARMUP:-20}
ATTEMPTS=${HS_ATTEMPTS:-60}
RETRY_DELAY=${HS_RETRY_DELAY:-6}
READY_ATTEMPTS=${READY_ATTEMPTS:-60}
READY_RETRY_DELAY=${READY_RETRY_DELAY:-6}
LOGFILE=${LOGFILE:-/var/log/xgs-octep-bringup.log}
LOGTAG=${LOGTAG:-xgs-octep-bringup}
KMSG_AVAILABLE=0
[ -w /dev/kmsg ] && KMSG_AVAILABLE=1

report_kernel_log() {
	if ! command -v dmesg >/dev/null 2>&1; then
		echo "xgs-octep-bringup: dmesg unavailable" >&2
		return
	fi

	raw=$(dmesg 2>&1) || {
		echo "xgs-octep-bringup: cannot read dmesg: $raw" >&2
		return
	}
	lines=$(printf '%s\n' "$raw" |
		grep -iE 'octep|sdp|177d:a300' |
		tail -n 40)
	[ -n "$lines" ] || {
		echo "xgs-octep-bringup: no OCTEP/SDP messages in dmesg" >&2
		return
	}

	echo "xgs-octep-bringup: recent OCTEP/SDP dmesg:"
	while IFS= read -r line || [ -n "$line" ]; do
		echo "xgs-octep-bringup: dmesg: $line"
		printf '%s dmesg: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$line" \
			>>"$LOGFILE" 2>/dev/null || true
	done <<EOF
$lines
EOF
}

fail() {
	message="ERROR: $*"
	echo "xgs-octep-bringup: $message" >&2
	log "$message"
	report_kernel_log
	exit 1
}

log() {
	message=$*
	printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$message" \
		>>"$LOGFILE" 2>/dev/null || true
	if [ "$KMSG_AVAILABLE" -eq 1 ] &&
	   ! printf '<6>xgs-octep-bringup: %s\n' "$message" > /dev/kmsg 2>/dev/null; then
		KMSG_AVAILABLE=0
	fi
	if [ -t 1 ]; then
		echo "$message"
	elif command -v logger >/dev/null 2>&1; then
		logger -t "$LOGTAG" -p daemon.notice -- "$message" || true
	fi
}

case $WARMUP:$ATTEMPTS:$RETRY_DELAY:$READY_ATTEMPTS:$READY_RETRY_DELAY in
	*[!0-9:]*|::*|*:) fail "warm-up and retry settings must be non-negative integers" ;;
esac
[ "$ATTEMPTS" -gt 0 ] || fail "HS_ATTEMPTS must be greater than zero"
[ "$READY_ATTEMPTS" -gt 0 ] || fail "READY_ATTEMPTS must be greater than zero"

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
[ -r "$DEVICE/sdp_state" ] ||
	fail "the Linux octep driver has no sdp_state attribute"
[ -r "$DEVICE/state" ] && [ -w "$DEVICE/barmap_rescan" ] ||
	fail "the Linux octep driver lacks readiness and barmap-rescan controls"
[ -w "$DEVICE/sdp_start" ] && [ -w "$DEVICE/sdp_handshake" ] ||
	fail "the Linux octep driver lacks SDP start/handshake controls"
[ -w "$DEVICE/sdp_port_add" ] ||
	fail "the loaded octep module lacks the updated packet datapath; install it before ring bring-up"

state_value() {
	key=$1
	state=$2
	printf '%s\n' "$state" |
		sed -n "s/.*${key}=\\([^ ]*\\).*/\\1/p"
}

ready_attempt=0
while [ "$ready_attempt" -lt "$READY_ATTEMPTS" ]; do
	ready_attempt=$((ready_attempt + 1))
	printf '1\n' >"$DEVICE/barmap_rescan" 2>/dev/null || true
	DEVICE_STATE=$(cat "$DEVICE/state") ||
		fail "cannot read driver readiness from $DEVICE"
	READY=$(state_value ready "$DEVICE_STATE")
	[ -n "$READY" ] || fail "unrecognized driver state: $DEVICE_STATE"
	[ "$READY" = 1 ] && break
	if [ "$ready_attempt" -lt "$READY_ATTEMPTS" ]; then
		log "NPU barmap is not ready yet; retrying in ${READY_RETRY_DELAY}s ($ready_attempt/$READY_ATTEMPTS)"
		sleep "$READY_RETRY_DELAY"
	fi
done
[ "$READY" = 1 ] ||
	fail "NPU barmap did not become ready after $READY_ATTEMPTS attempts"

read_state() {
	STATE=$(cat "$DEVICE/sdp_state") ||
		fail "cannot read SDP state from $DEVICE"
	RINGS=$(state_value rings "$STATE")
	HANDSHAKE=$(state_value handshake "$STATE")
	SCRATCH=$(state_value scratch "$STATE")
	PACKET_SERVICE=$(state_value packet_service "$STATE")
	[ -n "$RINGS" ] && [ -n "$HANDSHAKE" ] && [ -n "$SCRATCH" ] &&
		[ -n "$PACKET_SERVICE" ] ||
		fail "unrecognized SDP state: $STATE"
}

read_state
case $RINGS:$PACKET_SERVICE in
	armed:rx-poll,tx-ring0|stopped:disabled) ;;
	*) fail "unexpected packet service for rings=$RINGS: $PACKET_SERVICE" ;;
esac
if [ "$HANDSHAKE" = completed ]; then
	log "handshake is already complete; leaving the latched rings untouched"
	report_kernel_log
	exit 0
fi

if [ "$RINGS" != armed ]; then
	[ "$SCRATCH" = 0x0000000000000000 ] ||
		fail "target-owned handshake scratch is $SCRATCH; refusing to reprogram rings"
	if ! printf '1\n' >"$DEVICE/sdp_start"; then
		fail "SDP ring arming failed; inspect the kernel journal"
	fi
	log "SDP ring 0 and its seven receive-only sibling rings armed"
	read_state
fi

[ "$RINGS" = armed ] ||
	fail "SDP rings are not armed after start: $STATE"
[ "$PACKET_SERVICE" = rx-poll,tx-ring0 ] ||
	fail "SDP packet service is not active after ring start: $STATE"

if [ "$SCRATCH" != 0x0000000000000000 ]; then
	fail "target-owned handshake scratch is $SCRATCH; refusing to overwrite it"
fi
log "waiting ${WARMUP}s for the coprocessor to reach its EP-mode handshake"
sleep "$WARMUP"

i=0
while [ "$i" -lt "$ATTEMPTS" ]; do
	read_state
	if [ "$HANDSHAKE" = completed ]; then
		log "EP-mode handshake completed"
		log "SDP ring polling and handshake are ready; run xgs-octep-port-setup to configure front-port netdevs"
		report_kernel_log
		exit 0
	fi
	[ "$HANDSHAKE" = idle ] ||
		fail "handshake state is $HANDSHAKE; refusing to interfere"
	[ "$SCRATCH" = 0x0000000000000000 ] ||
		fail "target-owned handshake scratch is $SCRATCH; refusing to overwrite it"

	i=$((i + 1))
	if printf '1\n' >"$DEVICE/sdp_handshake"; then
		log "handshake completed on offer $i"
		log "SDP ring polling and handshake are ready; run xgs-octep-port-setup to configure front-port netdevs"
		exit 0
	fi

	read_state
	if [ "$HANDSHAKE" = completed ]; then
		log "handshake completed on offer $i"
		log "SDP ring polling and handshake are ready; run xgs-octep-port-setup to configure front-port netdevs"
		report_kernel_log
		exit 0
	fi
	if [ "$SCRATCH" != 0x0000000000000000 ]; then
		fail "handshake did not settle cleanly (state=$HANDSHAKE scratch=$SCRATCH); refusing another offer"
	fi
	log "no target response on offer $i; retrying after ${RETRY_DELAY}s"
	sleep "$RETRY_DELAY"
done

fail "the EP-mode handshake did not complete after $i offers; rings remain armed"
