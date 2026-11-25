#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

HOST_ADDR=${NPU_HOST_ADDR:-169.254.254.1}
NPU_ADDR=${NPU_ADDR:-169.254.254.2}
# The FreeBSD cuau2 commonly maps to Linux ttyS2; override if this board enumerates it differently.
CONSOLE=${NPU_CONSOLE:-/dev/ttyS2}

case ${1:-} in
''|*[!0-9]*) echo "usage: npu-run.sh <seconds> <command>" >&2; exit 64 ;;
esac
SECS=$1
CMD=${2:-}
[ -n "$CMD" ] || { echo "usage: npu-run.sh <seconds> <command>" >&2; exit 64; }

if [ -n "${NPU_MGMT_IF:-}" ] && command -v ssh >/dev/null 2>&1 &&
   ip link show dev "$NPU_MGMT_IF" >/dev/null 2>&1 &&
   timeout 5 ssh -b "$HOST_ADDR" -o BatchMode=yes -o ConnectTimeout=3 \
       -o StrictHostKeyChecking=accept-new "root@$NPU_ADDR" true >/dev/null 2>&1; then
	exec timeout "$((SECS + 10))" ssh -b "$HOST_ADDR" -o BatchMode=yes \
		-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
		"root@$NPU_ADDR" "$CMD"
fi

[ -n "$CONSOLE" ] || {
	echo "set NPU_CONSOLE to the Linux serial device (for example /dev/ttyS2)" >&2
	exit 1
}
[ -c "$CONSOLE" ] || {
	echo "no serial device: $CONSOLE; check the UART mapping and let devtmpfs/udev create it" >&2
	exit 1
}
command -v flock >/dev/null 2>&1 || { echo "flock is required" >&2; exit 1; }

LOCK=${NPU_CONSOLE_LOCK:-/run/lock/xgs-npu-console.lock}
TMP=$(mktemp "${TMPDIR:-/tmp}/xgs-npu-run.XXXXXX")
exec 9>"$LOCK"
flock -w 5 9 || { rm -f "$TMP"; echo "coprocessor console is busy" >&2; exit 75; }
clean() { tr -d '\r' < "$TMP" | sed -E 's/\x1b\[[0-9;?]*[a-zA-Z]//g'; }
reader=
cleanup() {
	if [ -n "$reader" ]; then
		kill "$reader" 2>/dev/null || true
		wait "$reader" 2>/dev/null || true
	fi
	rm -f "$TMP"
}
trap cleanup EXIT HUP INT TERM

stty -F "$CONSOLE" 115200 raw -echo
timeout "$((SECS + 10))" cat "$CONSOLE" >"$TMP" 2>/dev/null &
reader=$!
sleep 1
printf '\r' >"$CONSOLE"
sleep 1
if ! clean | grep -v '^[[:space:]]*$' | tail -1 |
	grep -q -E 'login:[[:space:]]*$|#[[:space:]]*$'; then
	echo "coprocessor console is not at a Linux login or shell prompt; nothing sent" >&2
	exit 1
fi
if clean | grep -q 'login:'; then
	printf 'root\r' >"$CONSOLE"
	sleep 2
	if clean | grep -q 'assword'; then
		printf '\r' >"$CONSOLE"
		sleep 2
	fi
fi
printf 'echo "---NPU""BEGIN---"; %s; echo "---NPU""END---"\r' "$CMD" >"$CONSOLE"
sleep "$SECS"
clean | awk '/^---NPUBEGIN---/ {on=1; next} /^---NPUEND---/ {on=0; done=1} on; END {exit !done}' ||
	{ echo "coprocessor console did not return a complete response" >&2; exit 1; }
clean | awk '/^---NPUBEGIN---/ {on=1; next} /^---NPUEND---/ {on=0} on'
