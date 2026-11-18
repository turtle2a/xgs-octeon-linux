#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/../.." && pwd)
LOG_DIR=${OCTEP_TEST_LOG_DIR:-"$REPO_DIR/tests"}
mkdir -p -- "$LOG_DIR"
LOG_FILE=${OCTEP_TEST_LOG:-"$LOG_DIR/octep-tx2-mailbox-compat-$(date -u '+%Y%m%dT%H%M%SZ').log"}
exec > >(tee -a "$LOG_FILE") 2>&1

macro_value() {
	awk -v name="$1" '$1 == "#define" && $2 == name { print $3; exit }' "$2"
}

driver_name() {
	if [ -L "$1/driver" ]; then
		basename "$(readlink "$1/driver")"
	else
		printf 'unbound'
	fi
}

printf '[%s] OCTEP/TX2 mailbox compatibility probe started\n' \
	"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'Log: %s\n' "$LOG_FILE"
printf 'Kernel: %s\n' "$(uname -r)"
echo 'Mode: read-only; no PCI config, BAR, mailbox, or driver-binding writes'

PF=
for device in /sys/bus/pci/devices/*; do
	[ -r "$device/vendor" ] && [ -r "$device/device" ] || continue
	if [ "$(cat "$device/vendor")" = 0x177d ] &&
	    [ "$(cat "$device/device")" = 0xa300 ]; then
		[ -z "$PF" ] || {
			echo 'RESULT: FAIL (multiple OCTEP PFs found)'
			exit 2
		}
		PF=$device
	fi
done
[ -n "$PF" ] || {
	echo 'RESULT: FAIL (OCTEP PF 177d:a300 not found)'
	exit 2
}

PF_ID=$(cat "$PF/device")
VF_COUNT=$(cat "$PF/sriov_numvfs")
printf 'OCTEP PF: %s vendor=%s device=%s driver=%s enabled_vfs=%s\n' \
	"$(basename "$PF")" "$(cat "$PF/vendor")" "$PF_ID" \
	"$(driver_name "$PF")" "$VF_COUNT"
printf 'OCTEP BAR resources:\n%s\n' "$(cat "$PF/resource")"
if [ -r "$PF/sdp_state" ]; then
	printf 'OCTEP SDP state: %s\n' "$(cat "$PF/sdp_state")"
fi

VF_ID=
VF_SEEN=0
for link in "$PF"/virtfn*; do
	[ -L "$link" ] || continue
	vf=$(readlink -f "$link")
	vf_id=$(cat "$vf/device")
	printf 'VF: %s vendor=%s device=%s driver=%s\n' \
		"$(basename "$vf")" "$(cat "$vf/vendor")" "$vf_id" \
		"$(driver_name "$vf")"
	VF_ID=$vf_id
	VF_SEEN=$((VF_SEEN + 1))
done
printf 'Enumerated VFs: %s\n' "$VF_SEEN"

if [ -n "${KERNEL_BUILD:-}" ]; then
	KERNEL_BUILDS=("$KERNEL_BUILD")
else
	KERNEL_BUILDS=("/lib/modules/$(uname -r)/build" /lib/modules/*/build)
fi

THUNDER_DIR=
for kernel_build in "${KERNEL_BUILDS[@]}"; do
	candidate="$kernel_build/drivers/net/ethernet/cavium/thunder"
	[ -r "$candidate/nic.h" ] || continue
	THUNDER_DIR=$candidate
	printf 'Kernel source: %s\n' "$kernel_build"
	break
done
if [ -z "$THUNDER_DIR" ]; then
	echo 'RESULT: SKIP (no installed kernel build source contains the TX2 NIC driver)'
	exit 0
fi

THUNDER_PF=$(macro_value PCI_DEVICE_ID_THUNDER_NIC_PF "$THUNDER_DIR/nic.h")
THUNDER_VF=$(macro_value PCI_DEVICE_ID_THUNDER_NIC_VF "$THUNDER_DIR/nic.h")
THUNDER_MBOX=$(macro_value NIC_PF_VF_0_127_MAILBOX_0_1 "$THUNDER_DIR/nic_reg.h")
OCTEP_PF_MBOX=$(macro_value OCTEP_SDP_R_MBOX_VF_PF_DATA "$REPO_DIR/octep/octep.c")
OCTEP_RING_STRIDE=$(macro_value OCTEP_SDP_RING_STRIDE "$REPO_DIR/octep/octep.c")

for value in "$THUNDER_PF" "$THUNDER_VF" "$THUNDER_MBOX" \
	"$OCTEP_PF_MBOX" "$OCTEP_RING_STRIDE"; do
	[ -n "$value" ] || {
		echo 'RESULT: FAIL (could not read mailbox identifiers from source)'
		exit 2
	}
done

printf 'TX2 source: PF=%s VF=%s mailbox_reg=%s\n' \
	"$THUNDER_PF" "$THUNDER_VF" "$THUNDER_MBOX"
printf 'OCTEP source: VF mailbox is BAR0 + %s + ring * %s\n' \
	"$OCTEP_PF_MBOX" "$OCTEP_RING_STRIDE"

if [ "${PF_ID,,}" = "${THUNDER_PF,,}" ] ||
	[ -n "$VF_ID" ] && [ "${VF_ID,,}" = "${THUNDER_VF,,}" ]; then
	echo 'RESULT: FAIL (unexpected PCI ID match; review protocol compatibility)'
	exit 1
fi

printf 'RESULT: PASS (TX2 NIC PF/VF IDs differ from this OCTEP endpoint; direct TX2 mailbox binding is not compatible)\n'
printf '[%s] Probe complete\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
