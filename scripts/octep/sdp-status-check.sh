#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -u

UNIT=xgs-octep-sdp-bringup.service
TIMER=xgs-octep-sdp-status.timer
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RECOVERY_SCRIPT=${OCTEP_SDP_RECOVERY_SCRIPT:-"$SCRIPT_DIR/sdp-recover-npu.sh"}
KMSG_PATH=${OCTEP_STATUS_KMSG:-/dev/kmsg}
KMSG_AVAILABLE=0

if [ -w "$KMSG_PATH" ]; then
	KMSG_AVAILABLE=1
else
	echo "xgs-octep-status: cannot write check markers to $KMSG_PATH" >&2
fi

kernel_log() {
	[ "$KMSG_AVAILABLE" -eq 1 ] || return 0
	printf '<6>xgs-octep-status: %s\n' "$*" >> "$KMSG_PATH" 2>/dev/null || {
		KMSG_AVAILABLE=0
		echo "xgs-octep-status: cannot write check markers to $KMSG_PATH" >&2
	}
}

log_check_exit() {
	check_rc=$?
	kernel_log "check finished (exit=$check_rc)"
}

trap log_check_exit EXIT
kernel_log "check started"

show_status() {
	status_rc=0
	systemctl status "$UNIT" --no-pager -l || status_rc=$?
	if [ "$status_rc" -ne 0 ]; then
		echo "xgs-octep-status: systemctl status returned $status_rc"
	fi
}

read_state() {
	ACTIVE_STATE=$(systemctl show --property=ActiveState --value "$UNIT") ||
		return 1
	SUB_STATE=$(systemctl show --property=SubState --value "$UNIT") ||
		return 1
}

attempt_recovery() {
	[ -x "$RECOVERY_SCRIPT" ] || return 3
	"$RECOVERY_SCRIPT" --auto
	recovery_rc=$?
	case "$recovery_rc" in
	0)
		show_status
		if ! read_state; then
			echo "xgs-octep-status: cannot read state after NPU recovery" >&2
			exit 1
		fi
		if [ "$ACTIVE_STATE:$SUB_STATE" = active:exited ]; then
			echo "xgs-octep-status: recovery succeeded; heartbeat timer remains active"
			exit 0
		fi
		echo "xgs-octep-status: recovery returned but bring-up is ${ACTIVE_STATE}/${SUB_STATE}" >&2
		exit 1
		;;
	3) return 3 ;;
	5) return 5 ;;
	4)
		# A stopped unit still needs its normal start; a refused reset only
		# means the NPU is not in a known blocked state.
		[ "${1:-}" != start ] || return 3
		echo "xgs-octep-status: recovery refused an unsafe state; heartbeat timer remains active"
		exit 0
		;;
	*)
		echo "xgs-octep-status: automatic NPU recovery failed; heartbeat timer remains active for the next check" >&2
		exit "$recovery_rc"
		;;
	esac
}

WEDGED_AFTER_S=${OCTEP_WEDGED_AFTER_S:-300}
# Operator override for hardware proofs of the backstop: --wedged-after SECONDS.
if [ "${1:-}" = --wedged-after ] && [ "${2:-}" -ge 0 ] 2>/dev/null; then
	WEDGED_AFTER_S=$2
fi
RECOVERY_MARKER=${OCTEP_RECOVERY_MARKER:-/run/xgs-octep-sdp-recovery-attempted}

# A bring-up that has been waiting for a target that never answers
# (armed, idle, scratch 0) is reset once per boot after WEDGED_AFTER_S.
attempt_wedged_recovery() {
	[ -x "$RECOVERY_SCRIPT" ] || return 0
	[ ! -e "$RECOVERY_MARKER" ] || return 0
	since=$(systemctl show --property=StateChangeTimestampMonotonic --value "$UNIT" 2>/dev/null) || return 0
	[ -n "$since" ] && [ "$since" -gt 0 ] 2>/dev/null || return 0
	up=$(cut -d. -f1 "${OCTEP_PROC_UPTIME:-/proc/uptime}") || return 0
	[ $((up - since / 1000000)) -ge "$WEDGED_AFTER_S" ] || return 0
	echo "xgs-octep-status: bring-up has waited over ${WEDGED_AFTER_S}s; trying one wedged-NPU recovery"
	"$RECOVERY_SCRIPT" --wedged
	wedged_rc=$?
	echo "xgs-octep-status: wedged-NPU recovery exited $wedged_rc"
	exit 0
}

# auto-restart resets the unit state timestamp on every retry, so the wait is
# measured from the first status check that saw it; cleared once it recovers.
RESTART_SEEN=${OCTEP_RESTART_SEEN:-/run/xgs-octep-sdp-restart-seen}
attempt_wedged_recovery_restarting() {
	[ -x "$RECOVERY_SCRIPT" ] || return 0
	[ ! -e "$RECOVERY_MARKER" ] || return 0
	up=$(cut -d. -f1 "${OCTEP_PROC_UPTIME:-/proc/uptime}") || return 0
	if [ ! -s "$RESTART_SEEN" ]; then
		echo "$up" >"$RESTART_SEEN" 2>/dev/null || true
		return 0
	fi
	seen=$(cat "$RESTART_SEEN" 2>/dev/null) || return 0
	[ "$seen" -ge 0 ] 2>/dev/null || return 0
	[ $((up - seen)) -ge "$WEDGED_AFTER_S" ] || return 0
	echo "xgs-octep-status: bring-up has been auto-restarting over ${WEDGED_AFTER_S}s; trying one wedged-NPU recovery"
	"$RECOVERY_SCRIPT" --wedged
	wedged_rc=$?
	echo "xgs-octep-status: wedged-NPU recovery exited $wedged_rc"
	exit 0
}

show_status
if ! read_state; then
	echo "xgs-octep-status: cannot read state for $UNIT" >&2
	exit 1
fi

[ "$ACTIVE_STATE:$SUB_STATE" = "activating:auto-restart" ] || rm -f "$RESTART_SEEN" 2>/dev/null

case "$ACTIVE_STATE:$SUB_STATE" in
	active:exited)
		attempt_recovery
		recovery_rc=$?
		case "$recovery_rc" in
			3)
				echo "xgs-octep-status: no blocked SDP state; heartbeat timer remains active"
				exit 0
				;;
			5)
				# The unit is a finished one-shot, so an unloaded module is
				# never reloaded unless the unit is started again.
				if ! grep -q '^octep ' "${OCTEP_PROC_MODULES:-/proc/modules}" 2>/dev/null; then
					echo "xgs-octep-status: octep module is not loaded; restarting $UNIT"
					systemctl restart "$UNIT" || echo "xgs-octep-status: restart of $UNIT failed" >&2
					exit 0
				fi
				echo "xgs-octep-status: OCTEP PF is temporarily unavailable; keeping retry timer active"
				exit 0
				;;
			*) exit "$recovery_rc" ;;
		esac
		;;
	activating:auto-restart)
		attempt_recovery
		recovery_rc=$?
		case "$recovery_rc" in
			3)
				attempt_wedged_recovery_restarting
				echo "xgs-octep-status: bring-up is auto-restarting; no safe blocked-state recovery"
				exit 0
				;;
			5)
				attempt_wedged_recovery_restarting
				echo "xgs-octep-status: OCTEP PF is temporarily unavailable; keeping retry timer active"
				exit 0
				;;
			*) exit "$recovery_rc" ;;
		esac
		;;
	activating:start|activating:start-pre)
		attempt_wedged_recovery
		echo "xgs-octep-status: bring-up is already ${ACTIVE_STATE}/${SUB_STATE}; no overlapping start"
		exit 0
		;;
	activating:*|deactivating:*|reloading:*)
		echo "xgs-octep-status: bring-up is already ${ACTIVE_STATE}/${SUB_STATE}; no overlapping start"
		exit 0
		;;
	failed:*|inactive:*)
		echo "xgs-octep-status: bring-up is ${ACTIVE_STATE}/${SUB_STATE}; resetting failure and starting it"
		attempt_recovery start
		recovery_rc=$?
		case "$recovery_rc" in
			3) ;;
			5)
				# No module means no PF to wait for: the bring-up unit loads it.
				if grep -q '^octep ' "${OCTEP_PROC_MODULES:-/proc/modules}" 2>/dev/null; then
					echo "xgs-octep-status: OCTEP PF is temporarily unavailable; keeping retry timer active"
					exit 0
				fi
				echo "xgs-octep-status: octep module is not loaded; using normal bring-up"
				;;
			*) exit "$recovery_rc" ;;
		esac
		echo "xgs-octep-status: blocked-state recovery not applicable; using normal bring-up"
		systemctl reset-failed "$UNIT" || {
			echo "xgs-octep-status: could not reset $UNIT" >&2
			exit 1
		}
		if systemctl start "$UNIT"; then
			echo "xgs-octep-status: start command completed"
		else
			start_rc=$?
			echo "xgs-octep-status: start command returned $start_rc"
		fi
		show_status
		if ! read_state; then
			echo "xgs-octep-status: cannot read state for $UNIT after start" >&2
			exit 1
		fi
		if [ "$ACTIVE_STATE:$SUB_STATE" = active:exited ]; then
			echo "xgs-octep-status: bring-up is healthy; heartbeat timer remains active"
		else
			echo "xgs-octep-status: will check again; state is ${ACTIVE_STATE}/${SUB_STATE}"
		fi
		exit 0
		;;
	*)
		echo "xgs-octep-status: unexpected state ${ACTIVE_STATE}/${SUB_STATE}; will check again"
		exit 0
		;;
esac
