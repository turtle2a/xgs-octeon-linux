#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RECOVERY_SCRIPT="$SCRIPT_DIR/../octep/sdp-recover-npu.sh"
TMP=$(mktemp -d)
RESET_LISTENER=

cleanup() {
	if [ -n "$RESET_LISTENER" ]; then
		kill "$RESET_LISTENER" 2>/dev/null || true
		wait "$RESET_LISTENER" 2>/dev/null || true
	fi
	rm -rf "$TMP"
}
trap cleanup EXIT HUP INT TERM

DEVICE="$TMP/sysfs/0000:01:00.0"
BRIDGE="$TMP/devices/pci0000:00/0000:00:01.1"
REAL_DEVICE="$BRIDGE/0000:01:00.0"
DRIVER_ROOT="$TMP/drivers"
MARKER_PATH="$TMP/run/recovery-attempted"
mkdir -p "$TMP/bin" "$TMP/sysfs" "$REAL_DEVICE" "$DRIVER_ROOT/octep" "$TMP/run" "$TMP/nm-active"
ln -s "$REAL_DEVICE" "$DEVICE"
ln -s "$DRIVER_ROOT/octep" "$REAL_DEVICE/driver"
printf '0x060400\n' > "$BRIDGE/class"
printf '0x177d\n' > "$REAL_DEVICE/vendor"
printf '0xa300\n' > "$REAL_DEVICE/device"
printf 'flr bus\n' > "$REAL_DEVICE/reset_method"
printf '\n' > "$REAL_DEVICE/reset"
printf '\n' > "$DRIVER_ROOT/octep/bind"
printf '\n' > "$DRIVER_ROOT/octep/unbind"

cat > "$TMP/bin/id" <<'EOF'
#!/bin/sh
if [ "$1" = -u ]; then
	echo 0
else
	exec /usr/bin/id "$@"
fi
EOF
cat > "$TMP/bin/systemctl" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_SYSTEMCTL_LOG"
if [ "$1" = start ] && [ "$2" = xgs-octep-sdp-bringup.service ]; then
	printf '%s\n' \
		'rings=armed ring_count=8 handshake=completed scratch=0x0000000000000001 coproc_ticks_per_us=800 time_threshold=39 management_netdev=registered front_netdevs=10 packet_service=rx-poll,tx-ring0' \
		> "$MOCK_DEVICE/sdp_state"
fi
EOF
cat > "$TMP/bin/nmcli" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_NMCLI_LOG"
if [ "$1" = -g ] && [ "$2" = GENERAL.CON-UUID ] &&
	[ "$3" = device ] && [ "$4" = show ]; then
	if [ -e "$MOCK_NM_ACTIVE_DIR/$5" ]; then echo "test-$5"; fi
elif [ "$1" = -g ] && [ "$2" = UUID ] &&
	[ "$3" = connection ] && [ "$4" = show ]; then
	for port in 0 1 2 3 4 5 6 7 8 9; do echo "test-octep$port"; done
elif [ "$1" = -g ] && [ "$2" = connection.interface-name ] &&
	[ "$3" = connection ] && [ "$4" = show ]; then
	echo "${5#test-}"
elif [ "$1" = -g ] && [ "$2" = connection.uuid ] &&
	[ "$3" = connection ] && [ "$4" = show ]; then
	if [ "$5" = xgs-octep0-dhcp ]; then echo test-octep0; fi
elif [ "$1" = connection ] && [ "$2" = add ]; then
	:
elif [ "$1" = connection ] && [ "$2" = modify ]; then
	:
elif [ "$1" = --wait ] && [ "$2" = 0 ] &&
	[ "$3" = connection ] && [ "$4" = up ]; then
	: > "$MOCK_NM_ACTIVE_DIR/$7"
elif [ "$1" = device ] && [ "$2" = reapply ]; then
	:
elif [ "$1" = -g ] && [ "$2" = IP4.ADDRESS ] &&
	[ "$3" = device ] && [ "$4" = show ]; then
	if [ "${MOCK_NM_NO_LEASE:-0}" != 1 ]; then echo 192.0.2.10/28; fi
else
	echo "FAIL: unexpected nmcli invocation: $*" >&2
	exit 2
fi
EOF
cat > "$TMP/bin/sleep" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_SLEEP_LOG"
:
EOF
cat > "$TMP/bin/ip" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_IP_LOG"
EOF
cat > "$TMP/bin/date" <<'EOF'
#!/bin/sh
[ "$1" = +%s ] || exit 2
printf '%s\n' "$MOCK_DATE_VALUE"
EOF
chmod +x "$TMP/bin/id" "$TMP/bin/systemctl" "$TMP/bin/nmcli" "$TMP/bin/sleep" "$TMP/bin/ip" "$TMP/bin/date"
printf '%s\n' \
	'rings=armed ring_count=8 handshake=completed scratch=0x0000000000000001 coproc_ticks_per_us=800 time_threshold=39 management_netdev=registered front_netdevs=10 packet_service=rx-poll,tx-ring0' \
	> "$REAL_DEVICE/sdp_state"

run_recovery() {
	PATH="$TMP/bin:$PATH" \
	MOCK_SYSTEMCTL_LOG="$TMP/systemctl.log" \
	MOCK_NMCLI_LOG="$TMP/nmcli.log" \
	MOCK_IP_LOG="$TMP/ip.log" \
	MOCK_SLEEP_LOG="$TMP/sleep.log" \
	MOCK_DATE_VALUE=${MOCK_DATE_VALUE:-1000} \
	MOCK_NM_PROFILE="$TMP/nm-profile" \
	MOCK_NM_ACTIVE_DIR="$TMP/nm-active" \
	OCTEP_DHCP_ATTEMPT_DIR="$TMP/run/dhcp-attempted" \
	MOCK_NM_NO_LEASE=${MOCK_NM_NO_LEASE:-0} \
	MOCK_DEVICE="$REAL_DEVICE" \
	OCTEP_SYSFS_ROOT="$TMP/sysfs" \
	OCTEP_DRIVER_SYSFS_ROOT="$DRIVER_ROOT" \
	OCTEP_DEVICE_SYSFS="$DEVICE" \
	OCTEP_RECOVERY_MARKER="$MARKER_PATH" \
	"$RECOVERY_SCRIPT" --auto
}

prepare_reset_listener() {
	rm -f "$REAL_DEVICE/reset"
	mkfifo "$REAL_DEVICE/reset"
	(
		IFS= read -r reset_value < "$REAL_DEVICE/reset"
		[ "$reset_value" = 1 ] || exit 1
		printf '%s\n' \
			'rings=stopped ring_count=0 handshake=idle scratch=0x0000000000000000 coproc_ticks_per_us=0 time_threshold=0 management_netdev=registered front_netdevs=0 packet_service=disabled' \
			> "$REAL_DEVICE/sdp_state"
	) &
	RESET_LISTENER=$!
}

if MOCK_NM_NO_LEASE=1 run_recovery > "$TMP/output" 2>&1; then
	echo "FAIL: healthy NPU state was accepted for reset" >&2
	exit 1
else
	rc=$?
fi
[ "$rc" -eq 3 ] || {
	cat "$TMP/output"
	echo "FAIL: expected live-state skip (3), got $rc" >&2
	exit 1
}
[ ! -s "$TMP/systemctl.log" ] || {
	echo "FAIL: healthy-state guard reached systemctl" >&2
	exit 1
}
[ ! -e "$TMP/run/recovery-attempted" ] || {
	echo "FAIL: healthy-state guard consumed recovery attempt" >&2
	exit 1
}
grep -q 'NPU and OCTEPs are healthy; checking DHCP on all OCTEP interfaces' "$TMP/output"
grep -q 'DHCP activation requested on octep1; no IPv4 lease yet' "$TMP/output"
grep -q -- '--wait 0 connection up test-octep1 ifname octep1' "$TMP/nmcli.log"
if grep -q 'cloned-mac-address' "$TMP/nmcli.log"; then
	echo "FAIL: DHCP activation changed the interface MAC policy" >&2
	exit 1
fi
[ "$(wc -l < "$TMP/sleep.log")" -eq 10 ] || {
	echo "FAIL: expected one brief DHCP link cycle per OCTEP" >&2
	exit 1
}
for port in 0 1 2 3 4 5 6 7 8 9; do
	[ -f "$TMP/run/dhcp-attempted/octep$port" ] || {
		echo "FAIL: DHCP activation was not recorded for octep$port" >&2
		exit 1
	}
	grep -q "^link set dev octep$port down$" "$TMP/ip.log"
	grep -q "^link set dev octep$port up$" "$TMP/ip.log"
done

: > "$TMP/nmcli.log"
: > "$TMP/ip.log"
: > "$TMP/sleep.log"
MOCK_DATE_VALUE=1020
if MOCK_NM_NO_LEASE=1 run_recovery > "$TMP/output" 2>&1; then
	echo "FAIL: healthy-state DHCP check did not report pending lease" >&2
	exit 1
else
	rc=$?
fi
[ "$rc" -eq 3 ] || {
	cat "$TMP/output"
	echo "FAIL: expected healthy-state skip (3) during DHCP recheck, got $rc" >&2
	exit 1
}
grep -q 'DHCP is pending on octep1; next activation in 40s' "$TMP/output"
if grep -q -- ' connection up ' "$TMP/nmcli.log"; then
	echo "FAIL: DHCP was retried before its 60-second timeout" >&2
	exit 1
fi
[ ! -s "$TMP/ip.log" ] || {
	echo "FAIL: DHCP recheck cycled an interface a second time" >&2
	exit 1
}
[ ! -s "$TMP/sleep.log" ] || {
	echo "FAIL: DHCP recheck blocked while waiting for a lease" >&2
	exit 1
}
[ ! -s "$TMP/systemctl.log" ] || {
	echo "FAIL: healthy-state DHCP recheck reached systemd" >&2
	exit 1
}

MOCK_DATE_VALUE=1060
: > "$TMP/nmcli.log"
: > "$TMP/ip.log"
if MOCK_NM_NO_LEASE=1 run_recovery > "$TMP/output" 2>&1; then
	echo "FAIL: healthy-state DHCP retry did not report pending lease" >&2
	exit 1
else
	rc=$?
fi
[ "$rc" -eq 3 ] || {
	cat "$TMP/output"
	echo "FAIL: expected healthy-state skip (3) after DHCP retry, got $rc" >&2
	exit 1
}
grep -q -- '--wait 0 connection up test-octep1 ifname octep1' "$TMP/nmcli.log"
grep -q -- '--wait 0 connection up test-octep2 ifname octep2' "$TMP/nmcli.log"
[ ! -s "$TMP/ip.log" ] || {
	echo "FAIL: DHCP retry cycled an interface after the initial attempt" >&2
	exit 1
}

rm "$REAL_DEVICE/driver"
if run_recovery > "$TMP/output" 2>&1; then
	echo "FAIL: unbound PF was not deferred" >&2
	exit 1
else
	rc=$?
fi
[ "$rc" -eq 5 ] || {
	cat "$TMP/output"
	echo "FAIL: expected deferred unbound PF status 5, got $rc" >&2
	exit 1
}
[ ! -s "$TMP/systemctl.log" ] || {
	echo "FAIL: unbound PF reached systemd" >&2
	cat "$TMP/systemctl.log" >&2
	exit 1
}
ln -s "$DRIVER_ROOT/octep" "$REAL_DEVICE/driver"

printf '%s\n' \
	'rings=stopped ring_count=0 handshake=idle scratch=0x000000000000001f coproc_ticks_per_us=0 time_threshold=0 management_netdev=registered front_netdevs=0 packet_service=disabled' \
	> "$REAL_DEVICE/sdp_state"
printf 'flr\n' > "$REAL_DEVICE/reset_method"
if run_recovery > "$TMP/output" 2>&1; then
	echo "FAIL: unsupported bus reset was accepted" >&2
	exit 1
else
	rc=$?
fi
[ "$rc" -eq 4 ] || {
	cat "$TMP/output"
	echo "FAIL: expected unsafe-reset refusal (4), got $rc" >&2
	exit 1
}
[ ! -s "$TMP/systemctl.log" ] || {
	echo "FAIL: unsupported-reset guard reached systemctl" >&2
	exit 1
}
[ ! -e "$TMP/run/recovery-attempted" ] || {
	echo "FAIL: unsupported-reset guard consumed recovery attempt" >&2
	exit 1
}

printf 'flr bus\n' > "$REAL_DEVICE/reset_method"
prepare_reset_listener
if ! MOCK_NM_NO_LEASE=1 run_recovery > "$TMP/output" 2>&1; then
	cat "$TMP/output"
	echo "FAIL: guarded recovery did not complete in the simulated environment" >&2
	exit 1
fi
wait "$RESET_LISTENER"
RESET_LISTENER=
state=$(cat "$REAL_DEVICE/sdp_state")
case "$state" in
*"rings=armed"*"handshake=completed"*"packet_service=rx-poll,tx-ring0"*) ;;
*) echo "FAIL: mocked bring-up did not reach ready state: $state" >&2; exit 1 ;;
esac
[ -e "$TMP/run/recovery-attempted" ] || {
	echo "FAIL: recovery attempt marker was not created" >&2
	exit 1
}
if grep -q '^stop xgs-octep-sdp-status.timer$' "$TMP/systemctl.log"; then
	echo "FAIL: recovery stopped the startup heartbeat timer" >&2
	exit 1
fi
grep -q 'DHCP is pending on octep1; next activation in' "$TMP/output"
grep -q 'connection.autoconnect yes connection.autoconnect-retries 0' "$TMP/nmcli.log"
for port in 0 1 2 3 4 5 6 7 8 9; do
	grep -q "connection modify test-octep$port ipv4.method auto ipv6.method link-local" "$TMP/nmcli.log"
done
if grep -q 'connection down' "$TMP/nmcli.log"; then
	echo "FAIL: DHCP recovery disconnected octep1" >&2
	exit 1
fi

MARKER_PATH="$TMP/run/recovery-attempted-scratch1"
printf 'flr bus\n' > "$REAL_DEVICE/reset_method"
printf '%s\n' \
	'rings=stopped ring_count=0 handshake=idle scratch=0x0000000000000001 coproc_ticks_per_us=0 time_threshold=0 management_netdev=registered front_netdevs=0 packet_service=disabled' \
	> "$REAL_DEVICE/sdp_state"
prepare_reset_listener
if ! run_recovery > "$TMP/output" 2>&1; then
	cat "$TMP/output"
	echo "FAIL: scratch 0x1 did not recover in the simulated environment" >&2
	exit 1
fi
wait "$RESET_LISTENER"
RESET_LISTENER=
state=$(cat "$REAL_DEVICE/sdp_state")
case "$state" in
*"rings=armed"*"handshake=completed"*"packet_service=rx-poll,tx-ring0"*) ;;
*) echo "FAIL: scratch 0x1 bring-up did not reach ready state: $state" >&2; exit 1 ;;
esac
[ -e "$MARKER_PATH" ] || {
	echo "FAIL: scratch 0x1 recovery marker was not created" >&2
	exit 1
}
for port in 0 1 2 3 4 5 6 7 8 9; do
	grep -q "DHCP is active on octep$port" "$TMP/output"
done

if run_recovery > "$TMP/output" 2>&1; then
	echo "FAIL: healthy-state check did not return the normal skip status" >&2
	exit 1
else
	rc=$?
fi
[ "$rc" -eq 3 ] || {
	cat "$TMP/output"
	echo "FAIL: expected healthy-state skip (3) after recovery, got $rc" >&2
	exit 1
}
[ ! -e "$MARKER_PATH" ] || {
	echo "FAIL: healthy-state check did not re-arm recovery" >&2
	exit 1
}
grep -q 'recovery guard re-armed for a future failure' "$TMP/output"

printf '%s\n' \
	'rings=stopped ring_count=0 handshake=idle scratch=0x000000000000001f coproc_ticks_per_us=0 time_threshold=0 management_netdev=registered front_netdevs=0 packet_service=disabled' \
	> "$REAL_DEVICE/sdp_state"
printf 'flr bus\n' > "$REAL_DEVICE/reset_method"
prepare_reset_listener
if ! run_recovery > "$TMP/output" 2>&1; then
	cat "$TMP/output"
	echo "FAIL: a new failure after healthy recovery was not retried" >&2
	exit 1
fi
wait "$RESET_LISTENER"
RESET_LISTENER=
state=$(cat "$REAL_DEVICE/sdp_state")
case "$state" in
*"rings=armed"*"handshake=completed"*"packet_service=rx-poll,tx-ring0"*) ;;
*) echo "FAIL: second recovery did not reach ready state: $state" >&2; exit 1 ;;
esac

echo "PASS: live rings are protected, DHCP retries without blocking, recovery re-arms after healthy state, and reset safety guards hold"
