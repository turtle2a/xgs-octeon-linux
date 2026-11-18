#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/../.." && pwd)
MODULE=${SOPHOS_OCTEON_MODULE:?set SOPHOS_OCTEON_MODULE to the path of octeon_drv.ko}
PF_BDF=${SOPHOS_PF_BDF:-}
STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
LOG_FILE=${SOPHOS_TEST_LOG:-"$REPO_DIR/tests/sophos-cn83-live-$STAMP.log"}
BACKUP_ROOT=${SOPHOS_TEST_BACKUP_ROOT:-/var/tmp}
BACKUP_DIR="$BACKUP_ROOT/sophos-cn83-mailbox-$STAMP"
PF=
START_TIME=
ORIG_VF_COUNT=
CHANGES_STARTED=0
declare -a ORIG_VF_BDFS=()
declare -a ORIG_VF_OVERRIDES=()

usage() {
	echo "Usage: sudo $0 --confirm-disruptive" >&2
	echo "Set SOPHOS_OCTEON_MODULE and SOPHOS_PF_BDF to override defaults." >&2
}

log() {
	printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

fail() {
	log "ERROR: $*"
	exit 1
}

driver_name() {
	if [[ -L "$1/driver" ]]; then
		basename "$(readlink -f "$1/driver")"
	else
		echo unbound
	fi
}

capture_kernel_logs() {
	log "Relevant dmesg entries:"
	dmesg -T 2>&1 |
		grep -iE 'octep|octeon|mailbox|sriov|vfio|177d' |
		tail -n 150 || true
	if command -v journalctl >/dev/null 2>&1 && [[ -n "$START_TIME" ]]; then
		log "Relevant kernel journal entries since $START_TIME:"
		journalctl -k --since "$START_TIME" -o short-iso --no-pager 2>&1 |
			grep -iE 'octep|octeon|mailbox|sriov|vfio|177d' |
			tail -n 150 || true
	fi
}

restore_original_state() {
	local vf vf_bdf vf_path vf_driver pf_driver current_vfs i restore_failed=0

	log "Restoring the original octep PF and VFIO bindings"
	for vf in "$PF"/virtfn*; do
		[[ -L "$vf" ]] || continue
		vf_path=$(readlink -f "$vf") || {
			restore_failed=1
			continue
		}
		vf_bdf=${vf_path##*/}
		vf_driver=$(driver_name "$vf_path")
		if [[ "$vf_driver" != unbound ]]; then
			printf '%s\n' "$vf_bdf" >"/sys/bus/pci/drivers/$vf_driver/unbind" ||
				restore_failed=1
		fi
	done

	pf_driver=$(driver_name "$PF")
	if [[ "$pf_driver" == octeon_drv ]]; then
		if [[ -w "$PF/sriov_numvfs" ]] &&
		   [[ $(cat "$PF/sriov_numvfs") -gt 0 ]]; then
			printf '0\n' >"$PF/sriov_numvfs" || restore_failed=1
		fi
		printf '%s\n' "${PF##*/}" \
			>"/sys/bus/pci/drivers/octeon_drv/unbind" || restore_failed=1
	fi

	if [[ -d /sys/module/octeon_drv ]]; then
		rmmod octeon_drv || restore_failed=1
	fi

	pf_driver=$(driver_name "$PF")
	if [[ "$pf_driver" != octep ]]; then
		if [[ ! -d /sys/bus/pci/drivers/octep ]]; then
			modprobe octep || restore_failed=1
		fi
		if [[ -d /sys/bus/pci/drivers/octep ]]; then
			printf '%s\n' "${PF##*/}" \
				> /sys/bus/pci/drivers/octep/bind || restore_failed=1
		fi
	fi

	for ((i = 0; i < 50; i++)); do
		[[ $(driver_name "$PF") == octep ]] && break
		sleep 0.1
	done
	[[ $(driver_name "$PF") == octep ]] || restore_failed=1

	if [[ -w "$PF/sriov_numvfs" ]]; then
		current_vfs=$(cat "$PF/sriov_numvfs")
		if [[ "$current_vfs" -ne 0 && "$current_vfs" -ne "$ORIG_VF_COUNT" ]]; then
			for vf in "$PF"/virtfn*; do
				[[ -L "$vf" ]] || continue
				vf_path=$(readlink -f "$vf") || continue
				vf_bdf=${vf_path##*/}
				vf_driver=$(driver_name "$vf_path")
				if [[ "$vf_driver" != unbound ]]; then
					printf '%s\n' "$vf_bdf" \
						>"/sys/bus/pci/drivers/$vf_driver/unbind" ||
						restore_failed=1
				fi
			done
			printf '0\n' >"$PF/sriov_numvfs" || restore_failed=1
			current_vfs=$(cat "$PF/sriov_numvfs")
		fi
		if [[ "$current_vfs" -ne "$ORIG_VF_COUNT" ]]; then
			printf '%s\n' "$ORIG_VF_COUNT" >"$PF/sriov_numvfs" ||
				restore_failed=1
		fi
	else
		restore_failed=1
	fi

	modprobe vfio-pci || restore_failed=1
	for ((i = 0; i < ${#ORIG_VF_BDFS[@]}; i++)); do
		vf_bdf=${ORIG_VF_BDFS[i]}
		vf_path="/sys/bus/pci/devices/$vf_bdf"
		[[ -d "$vf_path" ]] || {
			restore_failed=1
			continue
		}
		vf_driver=$(driver_name "$vf_path")
		if [[ "$vf_driver" != vfio-pci ]]; then
			if [[ "$vf_driver" != unbound ]]; then
				printf '%s\n' "$vf_bdf" \
					>"/sys/bus/pci/drivers/$vf_driver/unbind" ||
					restore_failed=1
			fi
			printf 'vfio-pci\n' >"$vf_path/driver_override" ||
				restore_failed=1
			printf '%s\n' "$vf_bdf" > /sys/bus/pci/drivers_probe ||
				restore_failed=1
		fi
		printf '%s\n' "${ORIG_VF_OVERRIDES[i]}" \
			>"$vf_path/driver_override" || restore_failed=1
		[[ $(driver_name "$vf_path") == vfio-pci ]] || restore_failed=1
	done

	if [[ "$restore_failed" -eq 0 ]]; then
		log "Original PF/VF configuration restored"
	else
		log "RESTORE FAILED; backup is at $BACKUP_DIR; manual recovery or reboot may be required"
	fi
	return "$restore_failed"
}

cleanup() {
	local status=$?
	trap - EXIT INT TERM
	set +e
	if [[ "$CHANGES_STARTED" -eq 1 ]]; then
		restore_original_state || status=1
	fi
	capture_kernel_logs
	log "Test ended with status $status; log: $LOG_FILE; backup: $BACKUP_DIR"
	exit "$status"
}

[[ $# -eq 1 && "$1" == --confirm-disruptive ]] || {
	usage
	exit 2
}
[[ "$EUID" -eq 0 ]] || {
	echo "ERROR: run as root; no hardware was changed" >&2
	exit 77
}

mkdir -p -- "$(dirname -- "$LOG_FILE")" "$BACKUP_ROOT" ||
	exit 1
exec > >(tee -a "$LOG_FILE") 2>&1

for command in basename cat date dmesg dpdk-testpmd grep insmod modinfo \
	modprobe objdump readlink rmmod sleep strings tee; do
	command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done
[[ -r "$MODULE" ]] || fail "Sophos module not found: $MODULE"
[[ $(modinfo -F name "$MODULE") == octeon_drv ]] ||
	fail "module is not the Sophos octeon_drv: $MODULE"
[[ ! -d /sys/module/octeon_drv ]] ||
	fail "octeon_drv is already loaded; refusing to replace it"

if [[ -z "$PF_BDF" ]]; then
	for candidate in /sys/bus/pci/devices/*; do
		[[ -r "$candidate/vendor" && -r "$candidate/device" ]] || continue
		[[ $(cat "$candidate/vendor") == 0x177d &&
		   $(cat "$candidate/device") == 0xa300 ]] || continue
		[[ -z "$PF_BDF" ]] ||
			fail "multiple CN83xx PFs found; set SOPHOS_PF_BDF"
		PF_BDF=${candidate##*/}
	done
fi
PF="/sys/bus/pci/devices/$PF_BDF"
[[ -d "$PF" && $(cat "$PF/vendor") == 0x177d &&
   $(cat "$PF/device") == 0xa300 ]] ||
	fail "$PF_BDF is not an OCTEON TX CN83xx PF (177d:a300)"
[[ $(driver_name "$PF") == octep ]] ||
	fail "PF must be bound to the custom octep driver before the test"
[[ -w "$PF/sriov_numvfs" && $(cat "$PF/sriov_numvfs") -eq 4 ]] ||
	fail "expected exactly four enabled VFs"
[[ -r "$PF/sdp_state" && -r "$PF/sdp_rinfo" ]] ||
	fail "octep SDP state controls are unavailable"

SDP_STATE=$(cat "$PF/sdp_state")
RINFO=$(cat "$PF/sdp_rinfo")
[[ "$SDP_STATE" =~ (^|[[:space:]])rings=stopped([[:space:]]|$) ]] ||
	fail "SDP rings must be stopped before testing: $SDP_STATE"
[[ "$SDP_STATE" =~ (^|[[:space:]])handshake=idle([[:space:]]|$) ]] ||
	fail "SDP handshake must be idle before testing: $SDP_STATE"
[[ "$SDP_STATE" =~ (^|[[:space:]])scratch=0x0+([[:space:]]|$) ]] ||
	fail "SDP scratch must be clear before testing: $SDP_STATE"
if [[ "$SDP_STATE" =~ front_netdevs=([0-9]+) ]] &&
   [[ "${BASH_REMATCH[1]}" -ne 0 ]]; then
	fail "front-port netdevs must be absent before testing: $SDP_STATE"
fi
if [[ "$RINFO" == *"nvfs=0"* && "$RINFO" == *"rpvf=0"* ]]; then
	:
elif [[ "$RINFO" == *"nvfs=4"* && "$RINFO" == *"rpvf=1"* ]]; then
	:
else
	fail "RINFO must be unconfigured or declare four VFs with one ring each: $RINFO"
fi

if command -v systemctl >/dev/null 2>&1 &&
   systemctl is-active --quiet xgs-octep-sdp-bringup.service; then
	fail "stop xgs-octep-sdp-bringup.service before testing"
fi
for fd in /proc/[0-9]*/fd/*; do
	target=$(readlink "$fd" 2>/dev/null || true)
	case "$target" in
		/dev/vfio/*)
			pid=${fd#/proc/}
			fail "VFIO device is open by PID ${pid%%/*}; refusing to disrupt it"
			;;
	esac
done

ORIG_VF_COUNT=$(cat "$PF/sriov_numvfs")
for vf in "$PF"/virtfn*; do
	[[ -L "$vf" ]] || continue
	vf_path=$(readlink -f "$vf") || fail "cannot resolve $vf"
	vf_bdf=${vf_path##*/}
	[[ $(driver_name "$vf_path") == vfio-pci ]] ||
		fail "$vf_bdf must be bound to vfio-pci before testing"
	ORIG_VF_BDFS+=("$vf_bdf")
	ORIG_VF_OVERRIDES+=("$(cat "$vf_path/driver_override")")
done
[[ ${#ORIG_VF_BDFS[@]} -eq 4 ]] ||
	fail "expected four VF devices; found ${#ORIG_VF_BDFS[@]}"

mkdir "$BACKUP_DIR" || fail "could not create backup directory $BACKUP_DIR"
OCTEP_MODULE=$(modinfo -n octep) || fail "cannot locate the current octep module"
cp -p -- "$OCTEP_MODULE" "$BACKUP_DIR/" ||
	fail "could not back up the installed octep module"
{
	printf 'timestamp=%s\npf=%s\nmodule=%s\n' "$STAMP" "$PF_BDF" "$MODULE"
	printf 'sriov_numvfs=%s\n' "$ORIG_VF_COUNT"
	printf 'sdp_state=%s\nsdp_rinfo=%s\n' "$SDP_STATE" "$RINFO"
	for ((i = 0; i < ${#ORIG_VF_BDFS[@]}; i++)); do
		printf 'vf=%s driver=vfio-pci override=%s\n' \
			"${ORIG_VF_BDFS[i]}" "${ORIG_VF_OVERRIDES[i]}"
	done
} >"$BACKUP_DIR/live-state.txt"
log "Backup created at $BACKUP_DIR"
log "Test log: $LOG_FILE"
START_TIME=$(date --iso-8601=seconds)

log "Sophos module strings containing NACK-related terms:"
if ! strings "$MODULE" | grep -iE 'nack|negative response'; then
	echo "No NACK-related strings found"
fi
log "CN83xx PF mailbox handler disassembly:"
objdump -dr --disassemble=cn83xx_handle_pf_mbox_intr "$MODULE"

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
CHANGES_STARTED=1

log "Unbinding the four VFIO VFs and disabling SR-IOV"
for vf_bdf in "${ORIG_VF_BDFS[@]}"; do
	printf '%s\n' "$vf_bdf" >/sys/bus/pci/drivers/vfio-pci/unbind
done
printf '0\n' >"$PF/sriov_numvfs"
printf '%s\n' "$PF_BDF" >/sys/bus/pci/drivers/octep/unbind

log "Loading Sophos octeon_drv with four one-ring VFs"
insmod "$MODULE" num_vfs=4 num_rings_per_vf=1
for ((i = 0; i < 50; i++)); do
	[[ $(driver_name "$PF") == octeon_drv ]] && break
	sleep 0.1
done
[[ $(driver_name "$PF") == octeon_drv ]] ||
	fail "Sophos octeon_drv did not bind to $PF_BDF"
[[ $(cat "$PF/sriov_numvfs") -eq 4 ]] ||
	fail "Sophos driver did not create four VFs"

modprobe vfio-pci
VF_ARGS=()
for vf in "$PF"/virtfn*; do
	[[ -L "$vf" ]] || continue
	vf_path=$(readlink -f "$vf") || fail "cannot resolve $vf"
	vf_bdf=${vf_path##*/}
	[[ $(cat "$vf_path/vendor") == 0x177d &&
	   $(cat "$vf_path/device") == 0xa303 ]] ||
		fail "$vf_bdf is not an OCTEON TX VF"
	vf_driver=$(driver_name "$vf_path")
	if [[ "$vf_driver" != vfio-pci ]]; then
		if [[ "$vf_driver" != unbound ]]; then
			printf '%s\n' "$vf_bdf" \
				>"/sys/bus/pci/drivers/$vf_driver/unbind"
		fi
		printf 'vfio-pci\n' >"$vf_path/driver_override"
		printf '%s\n' "$vf_bdf" >/sys/bus/pci/drivers_probe
	fi
	[[ $(driver_name "$vf_path") == vfio-pci ]] ||
		fail "$vf_bdf could not be bound to vfio-pci"
	VF_ARGS+=(--allow "$vf_bdf")
done
[[ ${#VF_ARGS[@]} -eq 8 ]] || fail "Sophos driver did not expose four usable VFs"

log "Running DPDK testpmd probe without packet forwarding"
set +e
printf 'show port info all\nshow port stats all\nquit\n' |
	dpdk-testpmd -l 0-1 --no-huge --iova-mode=va --no-shconf \
	--file-prefix="sophos-mbox-$$" "${VF_ARGS[@]}" -- \
	--total-num-mbufs=8192 -i
TESTPMD_STATUS=${PIPESTATUS[1]}
set -e
log "testpmd exit status: $TESTPMD_STATUS"
if grep -qiE 'mbox received.*NACK' "$LOG_FILE"; then
	log "Observed a DPDK mailbox NACK"
elif grep -qiE 'mbox send Timeout|mailbox.*timed out' "$LOG_FILE"; then
	log "Observed a DPDK mailbox timeout (no response)"
else
	log "No explicit DPDK NACK/timeout marker found; inspect this log"
fi
exit "$TESTPMD_STATUS"
