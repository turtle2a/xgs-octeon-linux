#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/../.." && pwd)
NPU_RUN=${NPU_RUN_SCRIPT:-"$REPO_DIR/scripts/xgs/npu-run.sh"}
NPU_MGMT_IF=${NPU_MGMT_IF:-mvmgmt0}
export NPU_MGMT_IF
NPU_READ_COMMAND='
printf "npu_uptime="; cat /proc/uptime
printf "npu_loadavg="; cat /proc/loadavg
head -n 1 /proc/stat
npu_sensor_found=0
for h in /sys/class/hwmon/hwmon*; do
	[ -r "$h/name" ] || continue
	name=$(cat "$h/name")
	for f in "$h"/temp*_input; do
		[ -r "$f" ] || continue
		npu_sensor_found=1
		label_file=${f%_input}_label
		if [ -r "$label_file" ]; then
			label=$(cat "$label_file")
		else
			label=${f##*/}
		fi
		raw=$(cat "$f")
		printf "npu_hwmon_temp_mC=%s sensor=%s label=%s\n" "$raw" "$name" "$label"
	done
done
for z in /sys/class/thermal/thermal_zone*; do
	[ -r "$z/temp" ] || continue
	npu_sensor_found=1
	type=$(cat "$z/type" 2>/dev/null || echo unknown)
	raw=$(cat "$z/temp")
	printf "npu_thermal_temp_mC=%s type=%s\n" "$raw" "$type"
done
[ "$npu_sensor_found" -eq 1 ] || echo npu_temperature=unavailable
'
SERVER=${1:-}
PORT_TAG=${2:-33280}
NETDEV=${3:-octep1}
DURATION=${4:-60}
PF_BDF=${OCTEP_PF_BDF:-}
LOG_DIR=${OCTEP_TEST_LOG_DIR:-"$REPO_DIR/testlogs/accel"}
LOG_FILE=${OCTEP_TEST_LOG:-"$LOG_DIR/octep-accel-telemetry-$(date -u '+%Y%m%dT%H%M%SZ').log"}
NPU_TEMP_POLL_INTERVAL=3
NPU_LOAD_POLL_INTERVAL=1
NPU_CPU_PREV_STAT=
CPU_PREV_TOTAL=0
CPU_PREV_IDLE=0

usage() {
	echo "Usage: sudo $0 <iperf3-server> [port-tag [netdev [seconds]]]" >&2
	echo "Defaults: port-tag=33280 netdev=octep1 seconds=60" >&2
	echo "Duration range: 9-80 seconds; default 60 gives repeated thermal samples" >&2
	echo "External sensor binaries use XGS_NPU_SENSOR_BIN, XGS_NPU_SENSOR_LOADER, and XGS_NPU_SENSOR_LIBDIR" >&2
}

if [ "$#" -gt 4 ]; then
	usage
	exit 64
fi
if [ -z "$SERVER" ]; then
	usage
	exit 64
fi

case $PORT_TAG in
	''|*[!0-9]*) usage; exit 64 ;;
esac
if [ "$PORT_TAG" -lt 1 ] || [ "$PORT_TAG" -gt 65535 ]; then
	usage
	exit 64
fi
case $DURATION in
	''|*[!0-9]*) usage; exit 64 ;;
esac
if [ "$DURATION" -lt 9 ] || [ "$DURATION" -gt 80 ]; then
	usage
	exit 64
fi

if [ "$EUID" -ne 0 ]; then
	echo "octep-accel-telemetry-test: run as root to query NWA port statistics" >&2
	exit 77
fi
for command in awk basename cat date grep head ip iperf3 mkdir readlink sed tee timeout tr; do
	command -v "$command" >/dev/null 2>&1 || {
		echo "octep-accel-telemetry-test: $command is required" >&2
		exit 127
	}
done

if [ -z "$PF_BDF" ]; then
	for candidate in /sys/bus/pci/devices/*; do
		[ -r "$candidate/vendor" ] && [ -r "$candidate/device" ] || continue
		[ "$(cat "$candidate/vendor")" = 0x177d ] &&
			[ "$(cat "$candidate/device")" = 0xa300 ] || continue
		[ -z "$PF_BDF" ] || {
			echo "octep-accel-telemetry-test: multiple OCTEP PFs found; set OCTEP_PF_BDF" >&2
			exit 2
		}
		PF_BDF=${candidate##*/}
	done
fi

PF="/sys/bus/pci/devices/$PF_BDF"
[ -d "$PF" ] || {
	echo "octep-accel-telemetry-test: OCTEP PF $PF_BDF not found" >&2
	exit 2
}
[ -L "$PF/driver" ] &&
	[ "$(basename "$(readlink -f "$PF/driver")")" = octep ] || {
	echo "octep-accel-telemetry-test: $PF_BDF is not bound to octep" >&2
	exit 2
}
for attr in flow_stats rx_flow rpc_sys_counters nwa_discover nwa_ports nwa_request nwa_last rpc_state; do
	[ -r "$PF/$attr" ] || {
		echo "octep-accel-telemetry-test: $attr is unavailable" >&2
		exit 2
	}
done
[ -w "$PF/nwa_request" ] || {
	echo "octep-accel-telemetry-test: nwa_request is not writable" >&2
	exit 77
}

ROUTE=$(ip route get "$SERVER")
case "$ROUTE" in
	*" dev $NETDEV "*) ;;
	*)
		echo "octep-accel-telemetry-test: route to $SERVER is not via $NETDEV: $ROUTE" >&2
		exit 2
		;;
esac
SOURCE_IP=$(printf '%s\n' "$ROUTE" |
	awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }')
[ -n "$SOURCE_IP" ] || {
	echo "octep-accel-telemetry-test: could not determine the source address" >&2
	exit 2
}

mkdir -p -- "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
	printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

log "log_file=$LOG_FILE; server=$SERVER; source=$SOURCE_IP; interface=$NETDEV; port_tag=$PORT_TAG; duration=${DURATION}s"
log "NPU load samples are read-only snapshots; load averages are not utilization percentages"
log "NPU load/CPU and I2C temperature are sampled before/after traffic; load/CPU every ${NPU_LOAD_POLL_INTERVAL}s"

PORTS=$(cat "$PF/nwa_ports")
case $PORTS in
	"no successful NWA discovery"*)
		printf '1\n' >"$PF/nwa_discover"
		PORTS=$(cat "$PF/nwa_ports")
		;;
esac
TAG_TEXT=$(printf '0x%04x' "$PORT_TAG")
printf '%s\n' "$PORTS" |
	awk -v wanted="$TAG_TEXT" '$2 == wanted { found = 1 } END { exit !found }' || {
	log "ERROR: NWA discovery does not list port tag $TAG_TEXT"
	exit 2
}

snapshot_stats() {
	printf '4 14 %s 0 0\n' "$PORT_TAG" >"$PF/nwa_request"
	cat "$PF/nwa_last"
}

validate_snapshot() {
	local snapshot=$1
	local header count

	header=$(printf '%s\n' "$snapshot" | head -n 1)
	printf '%s\n' "$header" |
		grep -Eq "op=4 sub=14 port=$PORT_TAG .*reply_len=264 words=64 error=0$" || return 1
	count=$(printf '%s\n' "$snapshot" |
		awk 'NR > 1 { n++ } END { print n + 0 }')
	[ "$count" -eq 32 ]
}

netdev_stats_snapshot() {
	local field value

	for field in rx_packets rx_bytes rx_dropped tx_packets tx_bytes tx_dropped; do
		value=$(cat "/sys/class/net/$NETDEV/statistics/$field") || return 1
		printf '%s=%s ' "$field" "$value"
	done
}

flow_byte_delta() {
	local before=$1 after=$2

	awk '
		function field(name, i, pair) {
			for (i = 1; i <= NF; i++) {
				split($i, pair, "=")
				if (pair[1] == name)
					return pair[2] + 0
			}
			return 0
		}
		FNR == NR {
			if (NR > 1) {
				key = field("index") ":" field("revision")
				before[key] = field("orig_bytes") + field("reply_bytes")
			}
			next
		}
		NR > 1 {
			key = field("index") ":" field("revision")
			delta = field("orig_bytes") + field("reply_bytes") - (before[key] + 0)
			if (delta > 0)
				total += delta
		}
		END { printf "%.0f\n", total + 0 }
	' <(printf '%s\n' "$before") <(printf '%s\n' "$after")
}

flow_chain_snapshot() {
	local raw count

	raw=$(cat "$PF/rpc_sys_counters") || return 1
	count=$(printf '%s\n' "$raw" | sed -n '1s/^count=\([0-9][0-9]*\) .*/\1/p')
	case $count in
	''|*[!0-9]*) return 1 ;;
	esac
	[ "$count" -gt 69 ] || return 1
	printf '%s\n' "$raw" | awk -F= '
		BEGIN {
			name[0] = "RX_WIRE"
			name[1] = "TX_WIRE"
			name[2] = "WIRE_TO_WIRE"
			name[3] = "RX_KN"
			name[8] = "TX_DROP"
			name[9] = "TX_DROP_QUEUE_FULL"
			name[12] = "TX_KN"
			name[37] = "LIF_OFFLOAD_DISABLED"
			name[38] = "LIF_UNKNOWN_VLAN_L3_MODE"
			name[39] = "FORCED"
			name[40] = "NON_ACCEL"
			name[41] = "MFLOW_LU_ERR"
			name[42] = "FW_REV_MISMATCH"
			name[43] = "L3_FW_REV_MISMATCH"
			name[44] = "NHOP_LU_NULL"
			name[45] = "NHOP_UNRESOLVED"
			name[46] = "NHOP_REV_MISMATCH"
			name[47] = "NHOP_IDX_ERR"
			name[48] = "CONN_LOCK_ERR"
			name[49] = "CONN_REV_MISMATCH"
			name[50] = "CONN_ID_ERR"
			name[51] = "CONN_INVALID"
			name[52] = "CONN_RECLAIM_PENDING"
			name[53] = "CONN_RECLAIMED"
			name[54] = "CONN_TERMINATING"
			name[55] = "LIVE_UID_INVALID"
			name[56] = "TCP_SEQ_CHK_INVALID"
			name[57] = "TCP_MAX_RETRANS"
			name[58] = "TCP_FIN_SYN_RST"
			name[59] = "MFLOW_NOT_ACTIVE"
			name[60] = "EG_ERR"
		}
		NR > 1 && ($1 in name) { print name[$1] "=" $2 }
	'
}

flow_chain_delta() {
	local before=$1 after=$2

	awk -F= '
		FNR == NR { before[$1] = $2; next }
		$1 in before { printf "%s=%.0f\n", $1, $2 - before[$1] }
	' <(printf '%s\n' "$before") <(printf '%s\n' "$after")
}

log "NWA port statistics before iperf:"
BEFORE=$(snapshot_stats)
printf '%s\n' "$BEFORE"
validate_snapshot "$BEFORE" || {
	log "ERROR: invalid baseline NWA statistics reply"
	exit 1
}

NPU_LOAD_ERRORS=0
sample_npu_load() {
	local phase=$1 raw rc load_line uptime_line temp_lines cpu_stat cpu_busy

	if [ ! -x "$NPU_RUN" ]; then
		log "ERROR: NPU telemetry sample unavailable (phase=$phase; runner is not executable)"
		NPU_LOAD_ERRORS=$((NPU_LOAD_ERRORS + 1))
		return 1
	fi
	if raw=$(NPU_CONSOLE_LOCK_WAIT=${NPU_CONSOLE_LOCK_WAIT:-20} "$NPU_RUN" 2 "$NPU_READ_COMMAND" 2>&1); then
		:
	else
		rc=$?
		log "ERROR: NPU telemetry sample failed (phase=$phase; runner_exit=$rc; ${raw//$'\n'/ })"
		NPU_LOAD_ERRORS=$((NPU_LOAD_ERRORS + 1))
		return 1
	fi

	uptime_line=$(printf '%s\n' "$raw" | awk '
		$1 ~ /^npu_uptime=/ {
			sub(/^npu_uptime=/, "", $1)
			print $1
			exit
		}
	')
	load_line=$(printf '%s\n' "$raw" | awk '
		$1 ~ /^npu_loadavg=/ &&
		$2 ~ /^[0-9]+([.][0-9]+)?$/ &&
		$3 ~ /^[0-9]+([.][0-9]+)?$/ &&
		$4 ~ /^[0-9]+\/[0-9]+$/ && $5 ~ /^[0-9]+$/ {
			sub(/^npu_loadavg=/, "", $1)
			print $1, $2, $3
			exit
		}
	')
	if [ -z "$load_line" ]; then
		log "ERROR: NPU response was missing /proc/loadavg data (phase=$phase)"
		NPU_LOAD_ERRORS=$((NPU_LOAD_ERRORS + 1))
		return 1
	fi
	log "npu_load_phase=$phase uptime_seconds=${uptime_line:-unknown} loadavg_1m_5m_15m=$load_line"
	cpu_stat=$(printf '%s\n' "$raw" | awk '
		$1 == "cpu" && NF >= 9 {
			for (i = 2; i <= 9; i++)
				printf "%s%s", $i, i == 9 ? "\n" : " "
			exit
		}
	')
	if [ -n "$cpu_stat" ]; then
		if [ -n "$NPU_CPU_PREV_STAT" ]; then
			cpu_busy=$(awk -v previous="$NPU_CPU_PREV_STAT" \
				-v current="$cpu_stat" '
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
			if [ -n "$cpu_busy" ]; then
				log "npu_cpu_busy_pct=$cpu_busy phase=$phase"
			else
				log "npu_cpu_busy_pct=unavailable phase=$phase reason=counters_reset"
			fi
		else
			log "npu_cpu_busy_pct=initial phase=$phase"
		fi
		NPU_CPU_PREV_STAT=$cpu_stat
	else
		log "npu_cpu_busy_pct=unavailable phase=$phase reason=proc_stat_missing"
	fi
	temp_lines=$(printf '%s\n' "$raw" | awk '
		/^npu_hwmon_temp_mC=/ {
			value = $1
			sub(/^npu_hwmon_temp_mC=/, "", value)
			sensor = $2
			sub(/^sensor=/, "", sensor)
			label = $3
			sub(/^label=/, "", label)
			printf "npu_temperature_sensor=%s label=%s temp_c=%.1f\n", sensor, label, value / 1000
			found = 1
		}
		/^npu_thermal_temp_mC=/ {
			value = $1
			sub(/^npu_thermal_temp_mC=/, "", value)
			type = $2
			sub(/^type=/, "", type)
			printf "npu_thermal_zone=%s temp_c=%.1f\n", type, value / 1000
			found = 1
		}
		/^npu_temperature=unavailable$/ { unavailable = 1 }
		END {
			if (!found) {
				if (unavailable)
					print "npu_temperature=unavailable"
				else
					print "npu_temperature=not_reported"
			}
		}
	')
	while IFS= read -r line; do
		log "$line phase=$phase"
	done <<<"$temp_lines"
}

sample_npu_load before || true

sample_npu_temperature() {
	local phase=$1 bin loader libdir output status failure value

	if [ -z "${XGS_NPU_SENSOR_BIN:-}" ] && [ -r /etc/default/xgs-npu-health ]; then
		# sudo drops the sensor variables; reuse the health service's settings
		# shellcheck disable=SC1091
		. /etc/default/xgs-npu-health
	fi
	bin=${XGS_NPU_SENSOR_BIN:-xgs-1us-sensors}
	loader=${XGS_NPU_SENSOR_LOADER:-}
	libdir=${XGS_NPU_SENSOR_LIBDIR:-}
	if [ -n "$loader" ]; then
		if [ -z "$libdir" ]; then
			log "ERROR: XGS_NPU_SENSOR_LIBDIR is required with XGS_NPU_SENSOR_LOADER"
			return 1
		fi
		if output=$(LC_ALL=C timeout 5s "$loader" --library-path \
			"$libdir" "$bin" -n 2>&1); then
			:
		else
			status=$?
			failure=${output//$'\n'/ }
			log "ERROR: NPU I2C temperature sample failed (phase=$phase; exit=$status; ${failure:0:160})"
			return 1
		fi
	else
		if output=$(LC_ALL=C timeout 5s "$bin" -n 2>&1); then
			:
		else
			status=$?
			failure=${output//$'\n'/ }
			log "ERROR: NPU I2C temperature sample failed (phase=$phase; exit=$status; ${failure:0:160})"
			return 1
		fi
	fi

	if value=$(printf '%s\n' "$output" | LC_ALL=C awk '
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
		log "npu_temp_i2c_phase=$phase temp_c=$value"
	else
		log "ERROR: NPU I2C temperature sample failed (phase=$phase; invalid sensor output)"
		return 1
	fi
}

sample_npu_temperature before || true

sample_host_cpu() {
	local user nice system idle iowait irq softirq steal total idle_total busy

	read -r _ user nice system idle iowait irq softirq steal _ </proc/stat
	total=$((user + nice + system + idle + iowait + irq + softirq + steal))
	idle_total=$((idle + iowait))
	if [ "$CPU_PREV_TOTAL" -gt 0 ] && [ "$total" -gt "$CPU_PREV_TOTAL" ]; then
		busy=$(((total - CPU_PREV_TOTAL -
			(idle_total - CPU_PREV_IDLE)) * 100 /
			(total - CPU_PREV_TOTAL)))
		printf 'host_cpu_busy_pct=%s\n' "$busy"
	else
		echo "host_cpu_busy_pct=initial"
	fi
	CPU_PREV_TOTAL=$total
	CPU_PREV_IDLE=$idle_total
	printf 'host_loadavg=%s\n' "$(cat /proc/loadavg)"
}

sample_temperatures() {
	local hwmon name input label label_path raw zone type host_found
	host_found=0
	for hwmon in /sys/class/hwmon/hwmon*; do
		[ -r "$hwmon/name" ] || continue
		name=$(cat "$hwmon/name")
		for input in "$hwmon"/temp*_input; do
			[ -r "$input" ] || continue
			label_path=${input%_input}_label
			if [ -r "$label_path" ]; then
				label=$(cat "$label_path")
			else
				label=${input##*/}
			fi
			raw=$(cat "$input")
			host_found=1
			printf 'host_temperature_sensor=%s label=%s temp_c=%s\n' \
				"$name" "$label" "$(awk -v v="$raw" 'BEGIN { printf "%.1f", v / 1000 }')"
		done
	done
	for zone in /sys/class/thermal/thermal_zone*; do
		[ -r "$zone/temp" ] || continue
		type=$(cat "$zone/type" 2>/dev/null || echo unknown)
		raw=$(cat "$zone/temp")
		host_found=1
		printf 'host_thermal_zone=%s temp_c=%s\n' "$type" \
			"$(awk -v v="$raw" 'BEGIN { printf "%.1f", v / 1000 }')"
	done
	[ "$host_found" -eq 1 ] || echo "host_temperature=unavailable"
}

sample_telemetry() {
	local phase=$1 line

	log "telemetry phase=$phase"
	sample_host_cpu
	sample_temperatures
	while IFS= read -r line; do
		printf 'npu_flow_stats=%s\n' "$line"
	done <"$PF/flow_stats"
	while IFS= read -r line; do
		printf 'npu_rx_flow=%s\n' "$line"
	done <"$PF/rx_flow"
	while IFS= read -r line; do
		printf 'npu_rpc_state=%s\n' "$line"
	done <"$PF/rpc_state"
	netdev_stats=$(netdev_stats_snapshot) || {
		log "ERROR: could not read OCTEP netdev statistics for $NETDEV"
		return 1
	}
	log "octep_netdev=$NETDEV $netdev_stats"
}

monitor_iperf() {
	local phase=$1 pid=$2 npu_sampled=0 npu_rc=0
	local last_npu_load_sample=$SECONDS last_npu_temp_sample
	sample_npu_temperature "$phase-start" || true
	sample_npu_load "$phase-start" || npu_rc=1
	last_npu_load_sample=$SECONDS
	last_npu_temp_sample=$SECONDS

	while kill -0 "$pid" 2>/dev/null; do
		if [ "$((SECONDS - last_npu_temp_sample))" -ge "$NPU_TEMP_POLL_INTERVAL" ]; then
			sample_npu_temperature "$phase-during" || true
			last_npu_temp_sample=$SECONDS
		fi
		if [ "$((SECONDS - last_npu_load_sample))" -ge "$NPU_LOAD_POLL_INTERVAL" ]; then
			sample_npu_load "$phase-during" || npu_rc=1
			last_npu_load_sample=$SECONDS
			npu_sampled=1
		fi
		sample_telemetry "$phase"
		sleep 1
	done
	sample_telemetry "$phase-end"
	sample_npu_temperature "$phase-end" || true
	sample_npu_load "$phase-end" || npu_rc=1
	if [ "$npu_sampled" -eq 0 ]; then
		log "ERROR: traffic ended before a during-iperf NPU load sample (phase=$phase)"
		npu_rc=1
	fi
	return "$npu_rc"
}

run_iperf() {
	local phase=$1 rc=0 flow_chain_before flow_chain_after
	shift

	flow_chain_before=$(flow_chain_snapshot) || {
		log "ERROR: could not read NPU flow-chain counters before phase=$phase"
		return 1
	}
	log "NPU flow-chain counters are global; unrelated traffic may contribute (phase=$phase)"
	while IFS= read -r line; do
		log "npu_counter_before[$phase]=$line"
	done <<<"$flow_chain_before"
	log "iperf phase=$phase"
	timeout "$((DURATION + 15))s" iperf3 \
		--client "$SERVER" --bind "$SOURCE_IP" --bind-dev "$NETDEV" \
		--time "$DURATION" \
		--parallel 1 --get-server-output "$@" 2>&1 |
		sed "s/^/iperf[$phase]: /" &
	local iperf_pid=$!
	monitor_iperf "$phase" "$iperf_pid" &
	local monitor_pid=$!
	if wait "$iperf_pid"; then
		rc=0
	else
		rc=$?
	fi
	if wait "$monitor_pid"; then
		:
	else
		NPU_LOAD_ERRORS=$((NPU_LOAD_ERRORS + 1))
	fi
	flow_chain_after=$(flow_chain_snapshot) || {
		log "ERROR: could not read NPU flow-chain counters after phase=$phase"
		return 1
	}
	while IFS= read -r line; do
		log "npu_counter_delta[$phase]=$line"
	done < <(flow_chain_delta "$flow_chain_before" "$flow_chain_after")
	return "$rc"
}

test_rc=0
FLOW_STATS_BEFORE=$(cat "$PF/flow_stats")
log "NPU flow stats before iperf: $FLOW_STATS_BEFORE"
RX_FLOW_BEFORE=$(cat "$PF/rx_flow")
while IFS= read -r line; do
	log "NPU RX flow metadata before iperf: $line"
done <<<"$RX_FLOW_BEFORE"
NETDEV_STATS_BEFORE=$(netdev_stats_snapshot) || {
	log "ERROR: could not read OCTEP netdev statistics for $NETDEV"
	exit 1
}
log "OCTEP netdev stats before iperf: $NETDEV_STATS_BEFORE"
run_iperf forward || test_rc=1
run_iperf reverse --reverse || test_rc=1

log "NWA port statistics after iperf:"
AFTER=$(snapshot_stats)
printf '%s\n' "$AFTER"
validate_snapshot "$AFTER" || {
	log "ERROR: invalid final NWA statistics reply"
	exit 1
}
FLOW_STATS_AFTER=$(cat "$PF/flow_stats")
log "NPU flow stats after iperf:"
printf '%s\n' "$FLOW_STATS_AFTER"
RX_FLOW_AFTER=$(cat "$PF/rx_flow")
while IFS= read -r line; do
	log "NPU RX flow metadata after iperf: $line"
done <<<"$RX_FLOW_AFTER"
NETDEV_STATS_AFTER=$(netdev_stats_snapshot) || {
	log "ERROR: could not read OCTEP netdev statistics for $NETDEV"
	exit 1
}
log "OCTEP netdev stats after iperf: $NETDEV_STATS_AFTER"
FLOW_BYTE_DELTA=$(flow_byte_delta "$FLOW_STATS_BEFORE" "$FLOW_STATS_AFTER")
log "NPU per-flow byte counter delta=$FLOW_BYTE_DELTA"
sample_npu_load after || true
sample_npu_temperature after || true

log "NWA counter deltas:"
DELTAS=$(awk -F= '
	FNR == NR { if (FNR > 1) before[$1] = $2; next }
	FNR > 1 && ($1 in before) { printf "%s=%.0f\n", $1, $2 - before[$1] }
' <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER"))
printf '%s\n' "$DELTAS"
OCTET_DELTA=$(printf '%s\n' "$DELTAS" | awk -F= \
	'$1 == "good_octets_received" || $1 == "good_octets_sent" { n += $2 } END { printf "%.0f", n + 0 }')

if [ "$test_rc" -ne 0 ]; then
	log "RESULT: FAIL (iperf client failed; see local log)"
	exit 1
fi
if [ "$OCTET_DELTA" -eq 0 ]; then
	log "RESULT: FAIL (no NWA good-octet delta; flow_stats is an offload activity indicator, not utilization)"
	exit 1
fi
if [ "$FLOW_BYTE_DELTA" -eq 0 ]; then
	log "RESULT: FAIL (NWA traffic advanced, but no NPU per-flow byte-counter delta; hardware offload was not demonstrated)"
	exit 1
fi
log "RESULT: INCONCLUSIVE (NWA octets and aggregate NPU per-flow bytes advanced, but counters are not correlated to the test flow; hardware offload was not demonstrated)"
exit 1
