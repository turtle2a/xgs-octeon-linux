#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -u

PCI_ROOT=${XGS_NPU_PCI_SYSFS:-/sys/bus/pci/devices}
VENDOR_ID=0x177d
DEVICE_ID=0xa300
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -n "${NPU_RUN_SCRIPT:-}" ]; then
	NPU_RUN=$NPU_RUN_SCRIPT
elif [ -x "$SCRIPT_DIR/npu-run.sh" ]; then
	NPU_RUN=$SCRIPT_DIR/npu-run.sh
else
	NPU_RUN=/usr/local/xgs/linux/scripts/xgs/npu-run.sh
fi
STATE_DIR=${XGS_NPU_STATE_DIR:-/var/lib/os-xgs-npu}
STATE_FILE=$STATE_DIR/health.txt
DMESG_LINES=${XGS_NPU_DMESG_LINES:-20}
EXPECT_SDP_ARMED=${XGS_NPU_EXPECT_SDP_ARMED:-1}
NPU_COMMAND='cat /proc/uptime /proc/loadavg; grep -E "^(MemTotal|MemAvailable):" /proc/meminfo; grep -c ^processor /proc/cpuinfo'
found=0
failed=0
KMSG_AVAILABLE=0
if [ -w /dev/kmsg ]; then
	KMSG_AVAILABLE=1
else
	printf 'xgs-npu-health: cannot write health results to /dev/kmsg\n' >&2
fi

case $DMESG_LINES in
''|*[!0-9]*) echo "XGS_NPU_DMESG_LINES must be a positive integer" >&2; exit 64 ;;
esac
[ "$DMESG_LINES" -gt 0 ] || {
	echo "XGS_NPU_DMESG_LINES must be a positive integer" >&2
	exit 64
}
case $EXPECT_SDP_ARMED in
0|1) ;;
*) echo "XGS_NPU_EXPECT_SDP_ARMED must be 0 or 1" >&2; exit 64 ;;
esac

log() {
	printf 'xgs-npu-health: %s\n' "$*"
	if [ "$KMSG_AVAILABLE" -eq 1 ]; then
		printf '<6>xgs-npu-health: %s\n' "$*" > /dev/kmsg 2>/dev/null || {
			KMSG_AVAILABLE=0
			printf 'xgs-npu-health: cannot write to /dev/kmsg\n' >&2
		}
	fi
}

state_value() {
	key=$1
	state=$2
	printf '%s\n' "$state" |
		sed -n "s/.*${key}=\\([^ ]*\\).*/\\1/p"
}

show_kernel_log() {
	if ! command -v dmesg >/dev/null 2>&1; then
		log "kernel log unavailable: dmesg is not installed"
		return
	fi

	raw=$(dmesg 2>&1)
	status=$?
	if [ "$status" -ne 0 ]; then
		log "kernel log unavailable: $(printf '%s' "$raw" | tr '\n' ' ' | cut -c 1-160)"
		return
	fi

	lines=$(printf '%s\n' "$raw" |
		grep -iE 'octep|sdp|177d:a300' |
		grep -v 'xgs-npu-health' |
		tail -n "$DMESG_LINES")
	if [ -z "$lines" ]; then
		log "kernel log: no OCTEP/SDP messages in the current dmesg buffer"
		return
	fi

	log "last $DMESG_LINES OCTEP/SDP kernel messages:"
	while IFS= read -r line || [ -n "$line" ]; do
		printf 'xgs-npu-health: dmesg: %s\n' "$line"
	done <<EOF
$lines
EOF
}

show_snapshot() {
	if [ ! -r "$STATE_FILE" ]; then
		log "no cached NPU health snapshot at $STATE_FILE"
		return 1
	fi
	cat "$STATE_FILE"
}

collect_npu_health() {
	if ! mkdir -p "$STATE_DIR"; then
		log "ERROR: cannot create health state directory $STATE_DIR"
		return 1
	fi

	raw=$("$NPU_RUN" 8 "$NPU_COMMAND" 2>&1)
	run_status=$?
	metrics=$(printf '%s\n' "$raw" | awk '
		function number(value) {
			return value ~ /^[0-9]+([.][0-9]+)?$/
		}
		NF == 2 && number($1) && number($2) && uptime == "" {
			uptime = int($1)
		}
		NF == 5 && number($1) && number($2) && number($3) &&
			$4 ~ /^[0-9]+\/[0-9]+$/ && $5 ~ /^[0-9]+$/ {
			load = $1 " " $2 " " $3
		}
		$1 == "MemTotal:" && $2 ~ /^[0-9]+$/ {
			mem_total = $2
		}
		$1 == "MemAvailable:" && $2 ~ /^[0-9]+$/ {
			mem_available = $2
		}
		NF == 1 && $1 ~ /^[0-9]+$/ {
			cpus = $1
		}
		END {
			if (uptime == "")
				exit 1
			print "uptime_seconds=" uptime
			if (load != "")
				print "load=" load
			if (mem_total != "")
				print "mem_total_kb=" mem_total
			if (mem_available != "")
				print "mem_available_kb=" mem_available
			if (cpus != "")
				print "cpus=" cpus
		}
	')
	metrics_status=$?
	collected_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
	tmp=$(mktemp "$STATE_DIR/health.XXXXXX") || {
		log "ERROR: cannot create temporary health snapshot"
		return 1
	}

	if [ "$run_status" -eq 0 ] && [ "$metrics_status" -eq 0 ]; then
		{
			printf 'collected_at=%s\n' "$collected_at"
			printf '%s\n' "$metrics"
		} > "$tmp"
		if ! mv "$tmp" "$STATE_FILE"; then
			rm -f "$tmp"
			log "ERROR: cannot save health snapshot to $STATE_FILE"
			return 1
		fi
		while IFS= read -r line; do
			log "NPU: $line"
		done <<EOF
$metrics
EOF
		return 0
	fi

	error="console query failed (runner exit $run_status)"
	if [ "$run_status" -eq 0 ]; then
		error="console response did not contain NPU uptime"
	fi
	{
		printf 'collected_at=%s\n' "$collected_at"
		printf 'error=%s\n' "$error"
	} > "$tmp"
	if ! mv "$tmp" "$STATE_FILE"; then
		rm -f "$tmp"
		log "ERROR: cannot save health snapshot to $STATE_FILE"
	fi
	log "ERROR: $error"
	if [ -n "$raw" ]; then
		log "NPU runner: $(printf '%s' "$raw" | tr '\n' ' ' | cut -c 1-200)"
	fi
	return 1
}

case ${1:-collect} in
collect) ;;
show)
	show_snapshot
	exit $?
	;;
*)
	echo "usage: npu-health.sh [collect|show]" >&2
	exit 64
	;;
esac

for device in "$PCI_ROOT"/*; do
	[ -d "$device" ] || continue
	[ -r "$device/vendor" ] && [ -r "$device/device" ] || continue
	[ "$(cat "$device/vendor")" = "$VENDOR_ID" ] || continue
	[ "$(cat "$device/device")" = "$DEVICE_ID" ] || continue

	found=1
	bdf=${device##*/}
	if [ -L "$device/driver" ]; then
		driver=$(basename "$(readlink "$device/driver")")
	else
		driver=unbound
	fi
	log "$bdf: driver=$driver"

	if [ "$driver" != octep ]; then
		log "$bdf: diagnostic driver is not bound; BAR and mailbox checks skipped"
		continue
	fi

	if [ -r "$device/state" ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			log "$bdf: state: $line"
		done < "$device/state"
	else
		log "$bdf: ERROR: octep state attribute is unavailable"
		failed=1
	fi

	if [ -r "$device/sdp_state" ]; then
		sdp_state=$(cat "$device/sdp_state") || {
			log "$bdf: ERROR: cannot read SDP ring state"
			failed=1
			sdp_state=
		}
		if [ -n "$sdp_state" ]; then
			log "$bdf: SDP: $sdp_state"
			rings=$(state_value rings "$sdp_state")
			ring_count=$(state_value ring_count "$sdp_state")
			packet_service=$(state_value packet_service "$sdp_state")
			case $rings:$ring_count in
			armed:8)
				if [ "$packet_service" != rx-poll,tx-ring0 ]; then
					log "$bdf: ERROR: SDP rings are armed but packet service is unavailable ($packet_service)"
					failed=1
				else
					log "$bdf: SDP rings are armed (8/8); packet service=$packet_service"
				fi
				;;
			armed:*)
				log "$bdf: ERROR: SDP rings are armed with ring_count=${ring_count:-unknown}, expected 8"
				failed=1
				;;
			stopped:0)
				if [ "$EXPECT_SDP_ARMED" -eq 1 ]; then
					log "$bdf: ERROR: SDP rings are stopped; armed rings were required"
					failed=1
				else
					log "$bdf: SDP rings are stopped"
				fi
				;;
			*)
				log "$bdf: ERROR: unrecognized SDP ring state"
				failed=1
				;;
			esac
		fi
	else
		log "$bdf: ERROR: octep SDP ring state attribute is unavailable"
		failed=1
	fi

	if [ -r "$device/facilities" ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			log "$bdf: facility: $line"
		done < "$device/facilities"
	else
		log "$bdf: ERROR: octep facilities attribute is unavailable"
		failed=1
	fi

	if [ -r "$device/sdp_rinfo" ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			log "$bdf: SDP RINFO: $line"
		done < "$device/sdp_rinfo"
	else
		log "$bdf: ERROR: octep SDP RINFO attribute is unavailable"
		failed=1
	fi

	if [ ! -r "$device/nwa_ports" ]; then
		log "$bdf: ERROR: octep NWA status attribute is unavailable"
		failed=1
	elif grep -q '^no successful NWA discovery' "$device/nwa_ports"; then
		log "$bdf: NWA discovery has no cached result; mailbox was not queried"
	else
		while IFS= read -r line || [ -n "$line" ]; do
			log "$bdf: NWA: $line"
		done < "$device/nwa_ports"
	fi
done

show_kernel_log

if [ "$found" -eq 0 ]; then
	log "no PCI function $VENDOR_ID:$DEVICE_ID found"
	failed=1
fi

collect_npu_health || failed=1
exit "$failed"
