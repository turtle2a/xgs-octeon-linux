#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

usage() {
	echo "usage: iperf-transit-test.sh <iperf3-server> <gate-state:off|on> [seconds]" >&2
	echo "Run from a test host; traffic must transit the OCTEON appliance." >&2
}

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
	usage
	exit 64
fi

SERVER=$1
GATE_STATE=$2
DURATION=${3:-10}

case $GATE_STATE in
off|on) ;;
*)
	usage
	exit 64
	;;
esac

case $DURATION in
''|*[!0-9]*)
	echo "iperf-transit-test: seconds must be an integer from 1 to 60" >&2
	exit 64
	;;
esac
if [ "$DURATION" -lt 1 ] || [ "$DURATION" -gt 60 ]; then
	echo "iperf-transit-test: seconds must be an integer from 1 to 60" >&2
	exit 64
fi

command -v iperf3 >/dev/null 2>&1 || {
	echo "iperf-transit-test: iperf3 is required on this test host" >&2
	exit 127
}

echo "iperf-transit-test: gate label=$GATE_STATE; duration=${DURATION}s; one TCP stream"
echo "iperf-transit-test: run only between test hosts on opposite sides of the appliance"
echo "iperf-transit-test: forward direction"
iperf3 --client "$SERVER" --time "$DURATION" --parallel 1 --get-server-output

echo "iperf-transit-test: reverse direction"
iperf3 --client "$SERVER" --reverse --time "$DURATION" --parallel 1 --get-server-output

echo "iperf-transit-test: complete; compare off/on runs alongside appliance status and flow evidence"
