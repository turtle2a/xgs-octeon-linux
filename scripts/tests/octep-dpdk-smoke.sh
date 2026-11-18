#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/../.." && pwd)
LOG_DIR=${OCTEP_TEST_LOG_DIR:-"$REPO_DIR/tests"}
mkdir -p -- "$LOG_DIR" || exit 1
LOG_FILE=${OCTEP_TEST_LOG:-"$LOG_DIR/octep-dpdk-$(date -u '+%Y%m%dT%H%M%SZ').log"}
exec > >(tee -a "$LOG_FILE") 2>&1

capture() {
	printf '\n$'
	printf ' %q' "$@"
	printf '\n'
	if "$@" 2>&1; then
		status=0
	else
		status=$?
	fi
	if [ "$status" -eq 0 ]; then
		printf 'RESULT: PASS (exit %d)\n' "$status"
	else
		printf 'RESULT: FAIL (exit %d)\n' "$status"
	fi
	return 0
}

capture_kernel_logs() {
	printf '\n### %s\n' "$1"
	if kernel_log=$(dmesg -T 2>&1); then
		echo 'dmesg RESULT: PASS (exit 0)'
		filtered=$(printf '%s\n' "$kernel_log" |
			grep -iE 'octep|sdp|vfio|sriov|177d' |
			tail -n 120 || true)
		if [ -n "$filtered" ]; then
			printf '%s\n' "$filtered"
		else
			echo 'No matching OCTEP/SDP/VFIO/SR-IOV messages.'
		fi
	else
		status=$?
		printf 'dmesg RESULT: FAIL (exit %d): %s\n' "$status" "$kernel_log"
	fi
}

finish() {
	status=$?
	trap - EXIT
	printf '\n[%s] OCTEP DPDK smoke test ended with status %d\n' \
		"$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$status"
	printf 'OCTEP test log: %s\n' "$LOG_FILE"
	exit "$status"
}
trap finish EXIT

printf '[%s] OCTEP DPDK smoke test started\n' \
	"$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
printf 'Log: %s\n' "$LOG_FILE"
capture id
capture uname -a
capture lsmod
capture modinfo octep
capture modinfo -p octep
capture modinfo vfio-pci
capture lspci -nnk -d 177d:
capture dpdk-devbind.py --status
capture systemctl show xgs-octep-sdp-bringup.service \
	-p ActiveState -p SubState -p ExecMainStatus -p NRestarts
capture journalctl -u xgs-octep-sdp-bringup.service -b \
	-o short-iso --no-pager
capture ls -la /dev/vfio
echo 'Module load/unload evidence is collected from kernel and systemd logs; this script does not reload the active PF.'
printf '\n### IOMMU groups containing OCTEP devices\n'
for group in /sys/kernel/iommu_groups/*; do
	[ -d "$group/devices" ] || continue
	for device in "$group"/devices/*; do
		[ -e "$device" ] || continue
		vendor=$(cat "$device/vendor" 2>/dev/null || true)
		[ "$vendor" = 0x177d ] || continue
		driver=unbound
		[ -L "$device/driver" ] &&
			driver=$(basename "$(readlink "$device/driver")")
		printf 'group=%s device=%s vendor=%s device_id=%s driver=%s\n' \
			"$(basename "$group")" "$(basename "$device")" "$vendor" \
			"$(cat "$device/device" 2>/dev/null || echo unavailable)" "$driver"
	done
done
printf '\n### OCTEP/SDP/VFIO kernel messages (current boot)\n'
if kernel_log=$(journalctl -k -b -o short-iso --no-pager 2>&1); then
	echo 'kernel journal RESULT: PASS (exit 0)'
	filtered=$(printf '%s\n' "$kernel_log" |
		grep -iE 'octep|sdp|vfio|sriov|177d' | tail -n 120 || true)
	if [ -n "$filtered" ]; then
		printf '%s\n' "$filtered"
	else
		echo 'No matching kernel journal messages.'
	fi
else
	status=$?
	printf 'kernel journal RESULT: FAIL (exit %d): %s\n' "$status" "$kernel_log"
fi
capture_kernel_logs 'Recent dmesg entries'

PF=
for candidate in /sys/bus/pci/devices/*; do
	[ -r "$candidate/vendor" ] && [ -r "$candidate/device" ] || continue
	[ "$(cat "$candidate/vendor")" = 0x177d ] || continue
	[ "$(cat "$candidate/device")" = 0xa300 ] || continue
	if [ -n "$PF" ]; then
		echo "ERROR: multiple OCTEP PFs found; refusing to choose one"
		exit 2
	fi
	PF=$candidate
done
[ -n "$PF" ] || {
	echo "ERROR: OCTEP PF 177d:a300 not found"
	exit 2
}

printf '\n### OCTEP PF %s\n' "$(basename "$PF")"
for attribute in driver sriov_totalvfs sriov_numvfs sdp_state sdp_rinfo; do
	if [ -L "$PF/$attribute" ]; then
		printf '%s=%s\n' "$attribute" "$(basename "$(readlink "$PF/$attribute")")"
	elif [ -r "$PF/$attribute" ]; then
		printf '%s=%s\n' "$attribute" "$(cat "$PF/$attribute")"
	else
		printf '%s=unavailable\n' "$attribute"
	fi
done

printf '\n### OCTEP VF inventory\n'
for vf in "$PF"/virtfn*; do
	[ -L "$vf" ] || continue
	vf_device=$(readlink -f "$vf" 2>/dev/null || true)
	[ -n "$vf_device" ] || continue
	driver=unbound
	[ -L "$vf_device/driver" ] &&
		driver=$(basename "$(readlink "$vf_device/driver")")
	iommu_group=unavailable
	[ -L "$vf_device/iommu_group" ] &&
		iommu_group=$(basename "$(readlink "$vf_device/iommu_group")")
	printf 'VF=%s vendor=%s device=%s driver=%s iommu_group=%s\n' \
		"$(basename "$vf_device")" \
		"$(cat "$vf_device/vendor" 2>/dev/null || echo unavailable)" \
		"$(cat "$vf_device/device" 2>/dev/null || echo unavailable)" \
		"$driver" "$iommu_group"
done
if [ -r /sys/module/octep/parameters/sriov_vfs ]; then
	printf 'module.sriov_vfs=%s\n' \
		"$(cat /sys/module/octep/parameters/sriov_vfs)"
else
	echo 'module.sriov_vfs=unavailable'
fi

VF_COUNT=$(cat "$PF/sriov_numvfs") || {
	echo "ERROR: cannot read the enabled VF count"
	exit 2
}
if [ "$VF_COUNT" -ne 4 ]; then
	echo "ERROR: expected 4 OCTEP VFs; found $VF_COUNT. No DPDK test run."
	exit 3
fi
if [ "$EUID" -ne 0 ]; then
	echo "ERROR: run as root to access VFIO devices and DPDK"
	exit 77
fi

VF_ARGS=()
VF_SEEN=0
for vf in "$PF"/virtfn*; do
	[ -L "$vf" ] || continue
	vf_device=$(readlink -f "$vf") || {
		echo "ERROR: cannot resolve $vf"
		exit 2
	}
	[ "$(cat "$vf_device/vendor")" = 0x177d ] &&
		[ "$(cat "$vf_device/device")" = 0xa303 ] || {
			echo "ERROR: $(basename "$vf_device") is not an OCTEON TX VF"
			exit 2
		}
	driver=
	[ -L "$vf_device/driver" ] &&
		driver=$(basename "$(readlink "$vf_device/driver")")
	if [ "$driver" != vfio-pci ]; then
		echo "ERROR: $(basename "$vf_device") is bound to ${driver:-no driver}, not vfio-pci"
		exit 4
	fi
	VF_ARGS+=(--allow "$(basename "$vf_device")")
	VF_SEEN=$((VF_SEEN + 1))
done
[ "$VF_SEEN" -eq 4 ] || {
	echo "ERROR: expected 4 OCTEON TX VFs; found $VF_SEEN"
	exit 3
}

command -v dpdk-testpmd >/dev/null 2>&1 || {
	echo "ERROR: dpdk-testpmd is not installed"
	exit 127
}

printf '\n### DPDK testpmd probe: four VF ports, no packet forwarding\n'
printf 'Commands: show port info all; show port stats all; quit\n'
set +e
printf 'show port info all\nshow port stats all\nquit\n' |
	dpdk-testpmd -l 0-1 --no-huge --iova-mode=va --no-shconf \
		--file-prefix="octep-smoke-$$" "${VF_ARGS[@]}" -- \
		--total-num-mbufs=8192 -i
TESTPMD_STATUS=${PIPESTATUS[1]}
set -e
if [ "$TESTPMD_STATUS" -eq 0 ]; then
	printf 'DPDK RESULT: PASS (exit %d)\n' "$TESTPMD_STATUS"
else
	printf 'DPDK RESULT: FAIL (exit %d)\n' "$TESTPMD_STATUS"
fi

printf '\n### Post-test OCTEP/SDP/VFIO kernel messages\n'
capture_kernel_logs 'Post-test dmesg entries'
exit "$TESTPMD_STATUS"
