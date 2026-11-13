#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STATUS_CHECK="$SCRIPT_DIR/../octep/sdp-status-check.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/bin"
: > "$TMP/kmsg"

cat > "$TMP/bin/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_SYSTEMCTL_LOG"
case "$1" in
status) exit 0 ;;
show)
	state=$(cat "$MOCK_UNIT_STATE")
	case "$2" in
	--property=ActiveState) printf '%s\n' "${state%%:*}" ;;
	--property=SubState) printf '%s\n' "${state#*:}" ;;
	*) exit 2 ;;
	esac
	;;
start)
	printf 'active:exited\n' > "$MOCK_UNIT_STATE"
	;;
stop|reset-failed) ;;
*) exit 2 ;;
esac
EOF
cat > "$TMP/recovery" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_RECOVERY_LOG"
if [ "$MOCK_RECOVERY_RC" -eq 0 ]; then
	printf 'active:exited\n' > "$MOCK_UNIT_STATE"
fi
exit "$MOCK_RECOVERY_RC"
EOF
chmod +x "$TMP/bin/systemctl" "$TMP/recovery"

run_check() {
	PATH="$TMP/bin:$PATH" \
	MOCK_SYSTEMCTL_LOG="$TMP/systemctl.log" \
	MOCK_RECOVERY_LOG="$TMP/recovery.log" \
	MOCK_UNIT_STATE="$TMP/unit-state" \
	MOCK_RECOVERY_RC=$1 \
	OCTEP_STATUS_KMSG="$TMP/kmsg" \
	OCTEP_SDP_RECOVERY_SCRIPT="$TMP/recovery" \
	sh "$STATUS_CHECK"
}

reset_logs() {
	: > "$TMP/systemctl.log"
	: > "$TMP/recovery.log"
	: > "$TMP/kmsg"
}

assert_no_start() {
	if grep -Eq '^(start|reset-failed) ' "$TMP/systemctl.log"; then
		echo "FAIL: status checker started bring-up instead of honoring recovery result" >&2
		cat "$TMP/systemctl.log" >&2
		exit 1
	fi
}

printf 'active:exited\n' > "$TMP/unit-state"
reset_logs
run_check 3 > "$TMP/output"
grep -q '^--auto$' "$TMP/recovery.log"
grep -q '^<6>xgs-octep-status: check started$' "$TMP/kmsg"
grep -q '^<6>xgs-octep-status: check finished (exit=0)$' "$TMP/kmsg"
if grep -q '^stop xgs-octep-sdp-status.timer$' "$TMP/systemctl.log"; then
echo "FAIL: a healthy heartbeat stopped the retry timer" >&2
exit 1
fi
assert_no_start

printf 'active:exited\n' > "$TMP/unit-state"
reset_logs
run_check 5 > "$TMP/output"
grep -q '^--auto$' "$TMP/recovery.log"
if grep -q '^stop xgs-octep-sdp-status.timer$' "$TMP/systemctl.log"; then
	echo "FAIL: transient PF unbind stopped the retry timer" >&2
	exit 1
fi
assert_no_start
grep -q 'temporarily unavailable' "$TMP/output"

printf 'active:exited\n' > "$TMP/unit-state"
reset_logs
run_check 0 > "$TMP/output"
grep -q '^--auto$' "$TMP/recovery.log"
if grep -q '^stop xgs-octep-sdp-status.timer$' "$TMP/systemctl.log"; then
	echo "FAIL: successful recovery stopped the heartbeat timer" >&2
	exit 1
fi
assert_no_start

printf 'active:exited\n' > "$TMP/unit-state"
reset_logs
run_check 4 > "$TMP/output" 2>&1
grep -q 'recovery refused an unsafe state; heartbeat timer remains active' "$TMP/output"
if grep -q '^stop xgs-octep-sdp-status.timer$' "$TMP/systemctl.log"; then
	echo "FAIL: unsafe state refusal stopped the heartbeat timer" >&2
	exit 1
fi
assert_no_start

printf 'active:exited\n' > "$TMP/unit-state"
reset_logs
if run_check 1 > "$TMP/output" 2>&1; then
	echo "FAIL: status checker hid a recovery execution failure" >&2
	exit 1
else
	rc=$?
fi
[ "$rc" -eq 1 ] || {
	echo "FAIL: expected recovery execution failure status 1, got $rc" >&2
	exit 1
}
grep -q 'heartbeat timer remains active for the next check' "$TMP/output"
if grep -q '^stop xgs-octep-sdp-status.timer$' "$TMP/systemctl.log"; then
	echo "FAIL: recovery execution failure stopped the heartbeat timer" >&2
	exit 1
fi
assert_no_start

printf 'activating:auto-restart\n' > "$TMP/unit-state"
reset_logs
run_check 3 > "$TMP/output"
grep -q '^--auto$' "$TMP/recovery.log"
assert_no_start
grep -q 'auto-restarting' "$TMP/output"

printf 'activating:auto-restart\n' > "$TMP/unit-state"
reset_logs
run_check 5 > "$TMP/output"
grep -q '^--auto$' "$TMP/recovery.log"
if grep -q '^stop xgs-octep-sdp-status.timer$' "$TMP/systemctl.log"; then
	echo "FAIL: transient PF unbind stopped the auto-restart retry timer" >&2
	exit 1
fi
assert_no_start

printf 'activating:auto-restart\n' > "$TMP/unit-state"
reset_logs
run_check 0 > "$TMP/output"
grep -q '^--auto$' "$TMP/recovery.log"
if grep -q '^stop xgs-octep-sdp-status.timer$' "$TMP/systemctl.log"; then
	echo "FAIL: auto-restart recovery stopped the heartbeat timer" >&2
	exit 1
fi
assert_no_start

printf 'activating:auto-restart\n' > "$TMP/unit-state"
reset_logs
run_check 4 > "$TMP/output" 2>&1
grep -q 'recovery refused an unsafe state; heartbeat timer remains active' "$TMP/output"
if grep -q '^stop xgs-octep-sdp-status.timer$' "$TMP/systemctl.log"; then
	echo "FAIL: unsafe auto-restart refusal stopped the heartbeat timer" >&2
	exit 1
fi
assert_no_start

printf 'failed:failed\n' > "$TMP/unit-state"
reset_logs
run_check 3 > "$TMP/output"
grep -q '^reset-failed xgs-octep-sdp-bringup.service$' "$TMP/systemctl.log"
grep -q '^start xgs-octep-sdp-bringup.service$' "$TMP/systemctl.log"
if grep -q '^stop xgs-octep-sdp-status.timer$' "$TMP/systemctl.log"; then
	echo "FAIL: successful normal bring-up stopped the heartbeat timer" >&2
	exit 1
fi

printf 'failed:failed\n' > "$TMP/unit-state"
reset_logs
run_check 5 > "$TMP/output"
grep -q '^--auto$' "$TMP/recovery.log"
if grep -Eq '^(start|reset-failed|stop) ' "$TMP/systemctl.log"; then
	echo "FAIL: transient PF unbind triggered a start or stopped monitoring" >&2
	cat "$TMP/systemctl.log" >&2
	exit 1
fi

echo "PASS: recovery defers transient PF unbinds, preserves monitoring on unsafe states and errors, and handles successful and normal bring-up paths"
