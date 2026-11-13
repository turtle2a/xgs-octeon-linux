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
		echo "xgs-octep-status: recovery refused an unsafe state; heartbeat timer remains active"
		exit 0
		;;
	*)
		echo "xgs-octep-status: automatic NPU recovery failed; heartbeat timer remains active for the next check" >&2
		exit "$recovery_rc"
		;;
	esac
}

show_status
if ! read_state; then
	echo "xgs-octep-status: cannot read state for $UNIT" >&2
	exit 1
fi

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
				echo "xgs-octep-status: bring-up is auto-restarting; no safe blocked-state recovery"
				exit 0
				;;
			5)
				echo "xgs-octep-status: OCTEP PF is temporarily unavailable; keeping retry timer active"
				exit 0
				;;
			*) exit "$recovery_rc" ;;
		esac
		;;
	activating:*|deactivating:*|reloading:*)
		echo "xgs-octep-status: bring-up is already ${ACTIVE_STATE}/${SUB_STATE}; no overlapping start"
		exit 0
		;;
	failed:*|inactive:*)
		echo "xgs-octep-status: bring-up is ${ACTIVE_STATE}/${SUB_STATE}; resetting failure and starting it"
		attempt_recovery
		recovery_rc=$?
		case "$recovery_rc" in
			3) ;;
			5)
				echo "xgs-octep-status: OCTEP PF is temporarily unavailable; keeping retry timer active"
				exit 0
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
