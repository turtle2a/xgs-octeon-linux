#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 turtle2a <354865938+turtle2a@users.noreply.github.com>
# Runtime test: move the NPU's IOMMU group from identity (iommu=pt) to a translated DMA domain.
#   octep-iommu-strict-test.sh status   read-only baseline
#   octep-iommu-strict-test.sh enable   unbind octep, set group type DMA, rebind, re-run bring-up
#   octep-iommu-strict-test.sh revert   same with identity (a reboot also restores identity)
# Root only. Verify flow offload is ON first. Never run iperf from the router. Links drop while it runs.
set -u
DEV=${OCTEP_PCI:-0000:01:00.0}
DRV=/sys/bus/pci/drivers/octep
G=/sys/bus/pci/devices/$DEV/iommu_group
NPU_ADDR=${NPU_ADDR:-169.254.254.2}

[ -e "$G" ] || { echo "no IOMMU group for $DEV" >&2; exit 1; }
GN=$(basename "$(readlink -f "$G")")
GT=/sys/kernel/iommu_groups/$GN/type

fault_count() { dmesg 2>/dev/null | grep -c -E 'IO_PAGE_FAULT|AMD-Vi.*(Event|fault)'; }

report() {
	echo "group $GN devices: $(ls "$G/devices" | tr '\n' ' ')"
	echo "group type: $(cat "$GT")"
	echo "driver: $(basename "$(readlink -f /sys/bus/pci/devices/$DEV/driver 2>/dev/null)" 2>/dev/null)"
	echo "iommu faults in dmesg: $(fault_count)"
	echo "links up: $(ip -br link show 2>/dev/null | awk '$1 ~ /^octep[0-9]+/ && $2 == "UP"' | wc -l)"
	if ping -I mvmgmt0 -c 1 -W 2 "$NPU_ADDR" >/dev/null 2>&1; then echo "NPU $NPU_ADDR: reachable"; else echo "NPU $NPU_ADDR: not reachable"; fi
	[ ! -r /proc/sys/net/netfilter/nf_conntrack_count ] ||
		echo "conntrack: $(cat /proc/sys/net/netfilter/nf_conntrack_count)/$(cat /proc/sys/net/netfilter/nf_conntrack_max)"
}

switch() { # $1 = DMA|identity
	[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
	before=$(fault_count)
	echo "before:"; report
	systemctl stop xgs-nat.service 2>/dev/null
	if [ -e "$DRV/$DEV" ]; then
		echo "$DEV" >"$DRV/unbind" || { echo "unbind failed" >&2; exit 1; }
	fi
	if ! echo "$1" >"$GT"; then
		echo "FAIL: could not set group type $1 (is another device in the group bound?)" >&2
	fi
	echo "$DEV" >/sys/bus/pci/drivers_probe
	sleep 3
	systemctl restart xgs-octep-sdp-bringup.service 2>/dev/null
	systemctl start xgs-nat.service 2>/dev/null
	echo "after:"; report
	after=$(fault_count)
	if [ "$(cat "$GT")" = "$1" ] && [ "$after" -eq "$before" ]; then
		echo "RESULT: group type $1, no new IOMMU faults"
	else
		echo "RESULT: CHECK - type=$(cat "$GT"), new faults=$((after - before)); run revert or reboot" >&2
		exit 2
	fi
}

case ${1:-status} in
status) report ;;
enable) switch DMA ;;
revert) switch identity ;;
*) echo "usage: $0 status|enable|revert" >&2; exit 64 ;;
esac
