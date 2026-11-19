#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -u

UNIT=xgs-octep-sdp-bringup.service
TIMER=xgs-octep-sdp-status.timer

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

stop_timer() {
	echo "xgs-octep-status: bring-up succeeded; stopping retry timer"
	systemctl stop "$TIMER"
}

show_status
if ! read_state; then
	echo "xgs-octep-status: cannot read state for $UNIT" >&2
	exit 1
fi

case "$ACTIVE_STATE:$SUB_STATE" in
	active:exited)
		stop_timer
		exit 0
		;;
	activating:*|deactivating:*|reloading:*)
		echo "xgs-octep-status: bring-up is already ${ACTIVE_STATE}/${SUB_STATE}; no overlapping start"
		exit 0
		;;
	failed:*|inactive:*)
		echo "xgs-octep-status: bring-up is ${ACTIVE_STATE}/${SUB_STATE}; resetting failure and starting it"
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
			stop_timer
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
