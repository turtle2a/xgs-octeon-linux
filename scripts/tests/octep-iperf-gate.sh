#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# iperf3 throughput with the offload gate off, on (no flow written) and off again,
# bound to one octep port. Needs root for the gate. The gate is always closed on exit.
#   octep-iperf-gate.sh [server] [seconds]
set -euo pipefail

PF=${OCTEP_PF:-/sys/bus/pci/devices/0000:01:00.0}
IFACE=${SRC_IF:-octep3}
SERVER=${1:-192.168.1.1}
SECS=${2:-10}

[ "$(id -u)" -eq 0 ] || {
	echo "SUDO REQUIRED: sudo $0 $*" >&2
	exit 1
}

trap 'echo off >"$PF/offload" 2>/dev/null || true' EXIT
ADDR=$(ip -4 -o addr show dev "$IFACE" | awk '{ sub("/.*", "", $4); print $4; exit }')
[ -n "$ADDR" ] || { echo "no IPv4 address on $IFACE" >&2; exit 1; }

snap() { grep -E '^(0|1|2|3)=' "$PF/rpc_sys_counters" | tr '\n' ' '; }

for state in off on off; do
	echo "$state" >"$PF/offload"
	sleep 2
	echo "== gate $state: $(cat "$PF/offload")"
	before=$(snap)
	for dir in "" "-R"; do
		echo "-- iperf3 $IFACE ${dir:-forward} to $SERVER, ${SECS}s"
		iperf3 -c "$SERVER" -B "$ADDR" -t "$SECS" $dir 2>&1 | grep -E "sender|receiver|Retr|error" || true
	done
	echo "counters before: $before"
	echo "counters after:  $(snap)   (0=RX_WIRE 1=TX_WIRE 2=WIRE_TO_WIRE 3=RX_KN)"
done
echo "gate: $(cat "$PF/offload")"
