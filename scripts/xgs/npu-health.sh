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
NPU_COMMAND='cat /proc/uptime /proc/loadavg; head -n 1 /proc/stat; grep -E "^(MemTotal|MemAvailable):" /proc/meminfo; grep -c ^processor /proc/cpuinfo'
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

collect_local_telemetry() {
	if [ -r /proc/loadavg ]; then
		host_load=$(awk '{ print $1 " " $2 " " $3 }' /proc/loadavg)
		printf 'host_loadavg=%s\n' "$host_load"
	else
		printf 'host_loadavg=unavailable\n'
	fi

	host_temp_found=0
	npu_temp_found=0
	for hwmon_dir in /sys/class/hwmon/hwmon*; do
		[ -r "$hwmon_dir/name" ] || continue
		sensor_name=$(cat "$hwmon_dir/name")
		for sensor_input in "$hwmon_dir"/temp*_input; do
			[ -r "$sensor_input" ] || continue
			sensor_label_file=${sensor_input%_input}_label
			if [ -r "$sensor_label_file" ]; then
				sensor_label=$(cat "$sensor_label_file")
			else
				sensor_label=${sensor_input##*/}
			fi
			sensor_raw=$(cat "$sensor_input")
			sensor_id=$(printf '%s_%s' "$sensor_name" "$sensor_label" |
				tr '[:upper:]' '[:lower:]' |
				tr -c '[:alnum:]_' '_')
			case $sensor_id in
			*npu*|*octeon*|*cavium*|*cn83*)
				npu_temp_found=1
				printf 'npu_temp_%s_c=%s\n' "$sensor_id" \
					"$(awk -v value="$sensor_raw" 'BEGIN { printf "%.1f", value / 1000 }')"
				;;
			*)
				host_temp_found=1
				printf 'host_temp_%s_c=%s\n' "$sensor_id" \
					"$(awk -v value="$sensor_raw" 'BEGIN { printf "%.1f", value / 1000 }')"
				;;
			esac
		done
	done

	for thermal_zone in /sys/class/thermal/thermal_zone*; do
		[ -r "$thermal_zone/temp" ] || continue
		zone_type=$(cat "$thermal_zone/type" 2>/dev/null || echo unknown)
		zone_raw=$(cat "$thermal_zone/temp")
		zone_id=$(printf '%s' "$zone_type" |
			tr '[:upper:]' '[:lower:]' |
			tr -c '[:alnum:]_' '_')
		case $zone_id in
		*npu*|*octeon*|*cavium*|*cn83*)
			npu_temp_found=1
			printf 'npu_thermal_%s_c=%s\n' "$zone_id" \
				"$(awk -v value="$zone_raw" 'BEGIN { printf "%.1f", value / 1000 }')"
			;;
		*)
			host_temp_found=1
			printf 'host_thermal_%s_c=%s\n' "$zone_id" \
				"$(awk -v value="$zone_raw" 'BEGIN { printf "%.1f", value / 1000 }')"
			;;
		esac
	done
	[ "$host_temp_found" -eq 1 ] || printf 'host_temp_sensor=unavailable\n'
	[ "$npu_temp_found" -eq 1 ] || printf 'npu_temp_sensor=unavailable\n'

	flow_found=0
	for device in "$PCI_ROOT"/*; do
		[ -r "$device/vendor" ] && [ -r "$device/device" ] || continue
		[ "$(cat "$device/vendor")" = "$VENDOR_ID" ] &&
			[ "$(cat "$device/device")" = "$DEVICE_ID" ] || continue
		[ -r "$device/flow_stats" ] || continue
		flow_stats=$(cat "$device/flow_stats") || continue
		for flow_field in tag254_frames cmsg_rx conn_stats_messages \
			conn_stats_entries tracked stale untracked malformed dropped; do
			flow_value=$(printf '%s\n' "$flow_stats" |
				sed -n "s/\\(^\\|.* \\)${flow_field}=\\([^ ]*\\).*/\\2/p")
			[ -n "$flow_value" ] || flow_value=unavailable
			printf 'npu_flow_%s=%s\n' "$flow_field" "$flow_value"
		done
		if [ -r "$device/rx_flow" ]; then
			rx_flow=$(cat "$device/rx_flow") || rx_flow=
			if [ -n "$rx_flow" ]; then
				printf '%s\n' "$rx_flow" | sed 's/^/npu_rx_flow=/'
			else
				printf 'npu_rx_flow=unavailable\n'
			fi
		else
			printf 'npu_rx_flow=unavailable\n'
		fi
		flow_found=1
		break
	done
	[ "$flow_found" -eq 1 ] || printf 'npu_flow_stats=unavailable\n'
	collect_npu_sensor_temperature
}

collect_npu_sensor_temperature() {
	sensor_bin=${XGS_NPU_SENSOR_BIN:-xgs-1us-sensors}
	sensor_loader=${XGS_NPU_SENSOR_LOADER:-}
	sensor_libdir=${XGS_NPU_SENSOR_LIBDIR:-}
	sensor_output=
	sensor_status=0

	if ! command -v timeout >/dev/null 2>&1; then
		printf 'NPU_TEMP_STATUS=unavailable reason=timeout_missing\n'
		return
	fi

	if [ -n "$sensor_loader" ]; then
		if [ -z "$sensor_libdir" ]; then
			printf 'NPU_TEMP_STATUS=unavailable reason=loader_requires_libdir\n'
			return
		fi
		if [ ! -x "$sensor_loader" ] || [ ! -d "$sensor_libdir" ] ||
			[ ! -r "$sensor_bin" ]; then
			printf 'NPU_TEMP_STATUS=unavailable reason=invalid_sensor_paths\n'
			return
		fi
		if sensor_output=$(LC_ALL=C timeout 5s "$sensor_loader" --library-path \
			"$sensor_libdir" "$sensor_bin" -n 2>&1); then
			:
		else
			sensor_status=$?
		fi
	else
		if ! command -v "$sensor_bin" >/dev/null 2>&1; then
			printf 'NPU_TEMP_STATUS=unavailable reason=sensor_not_found\n'
			return
		fi
		if sensor_output=$(LC_ALL=C timeout 5s "$sensor_bin" -n 2>&1); then
			:
		else
			sensor_status=$?
		fi
	fi

	if [ "$sensor_status" -ne 0 ]; then
		sensor_detail=$(printf '%s' "$sensor_output" |
			tr '\n' ' ' | cut -c 1-160)
		printf 'NPU_TEMP_STATUS=error exit=%s detail=%s\n' \
			"$sensor_status" "${sensor_detail:-none}"
		return
	fi

	if sensor_value=$(printf '%s\n' "$sensor_output" | LC_ALL=C awk '
		$1 == "NPU" && $2 == "Temperature" {
			if ($3 !~ /^-?[0-9]+([.][0-9]+)?$/ || found) {
				invalid = 1
				next
			}
			value = $3
			found = 1
		}
		END {
			if (invalid || !found)
				exit 1
			printf "%.3f\n", value
		}
	'); then
		printf 'NPU_TEMP_C=%s\n' "$sensor_value"
	else
		sensor_detail=$(printf '%s' "$sensor_output" |
			tr '\n' ' ' | cut -c 1-160)
		printf 'NPU_TEMP_STATUS=invalid_output detail=%s\n' \
			"${sensor_detail:-none}"
	fi
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
		$1 == "cpu" && NF >= 9 {
			cpu_stat = $2 " " $3 " " $4 " " $5 " " $6 " " $7 " " $8 " " $9
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
			if (cpu_stat != "")
				print "npu_cpu_stat=" cpu_stat
			if (mem_total != "")
				print "mem_total_kb=" mem_total
			if (mem_available != "")
				print "mem_available_kb=" mem_available
			if (cpus != "")
				print "cpus=" cpus
		}
	')
	metrics_status=$?
	if [ "$run_status" -eq 0 ] && [ "$metrics_status" -eq 0 ] &&
		[ -r "$STATE_FILE" ]; then
		previous_cpu_stat=$(sed -n 's/^npu_cpu_stat=//p' "$STATE_FILE")
		current_cpu_stat=$(printf '%s\n' "$metrics" |
			sed -n 's/^npu_cpu_stat=//p')
		if [ -n "$previous_cpu_stat" ] && [ -n "$current_cpu_stat" ]; then
			cpu_busy_pct=$(awk -v previous="$previous_cpu_stat" \
				-v current="$current_cpu_stat" '
				BEGIN {
					split(previous, p, " ")
					split(current, c, " ")
					for (i = 1; i <= 8; i++) {
						previous_total += p[i]
						current_total += c[i]
					}
					previous_idle = p[4] + p[5]
					current_idle = c[4] + c[5]
					total_delta = current_total - previous_total
					idle_delta = current_idle - previous_idle
					if (total_delta > 0 && idle_delta >= 0 &&
						idle_delta <= total_delta)
						printf "%.1f\n", (total_delta - idle_delta) * 100 / total_delta
				}
			')
			if [ -n "$cpu_busy_pct" ]; then
				metrics="$metrics
npu_cpu_busy_pct=$cpu_busy_pct"
			fi
		fi
	fi
	local_metrics=$(collect_local_telemetry)
	collected_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
	tmp=$(mktemp "$STATE_DIR/health.XXXXXX") || {
		log "ERROR: cannot create temporary health snapshot"
		return 1
	}

	if [ "$run_status" -eq 0 ] && [ "$metrics_status" -eq 0 ]; then
		{
			printf 'collected_at=%s\n' "$collected_at"
			printf '%s\n' "$metrics"
			printf '%s\n' "$local_metrics"
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
		while IFS= read -r line; do
			log "Telemetry: $line"
		done <<EOF
$local_metrics
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
		printf '%s\n' "$local_metrics"
	} > "$tmp"
	if ! mv "$tmp" "$STATE_FILE"; then
		rm -f "$tmp"
		log "ERROR: cannot save health snapshot to $STATE_FILE"
	fi
	log "ERROR: $error"
	while IFS= read -r line; do
		log "Telemetry: $line"
	done <<EOF
$local_metrics
EOF
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

log "NPU health collection: entry"

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
if [ "$failed" -eq 0 ]; then
	log "NPU health collection: exit result=ok"
else
	log "NPU health collection: exit result=error"
fi
exit "$failed"
