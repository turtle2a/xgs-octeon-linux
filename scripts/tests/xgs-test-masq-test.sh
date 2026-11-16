#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Masquerade start/stop in a private network namespace (no root needed).
# Covers the boot case: the WAN adapters do not exist yet when the unit starts.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec unshare -rnm sh -eu -c '
S="$1/xgs-test-masq.sh"
sh "$S" start >/dev/null || { echo "FAIL: start with no adapters" >&2; exit 1; }
iptables -t nat -S XGS_MASQ | grep -q -- "-o octep1 -j MASQUERADE" &&
iptables -t nat -S XGS_MASQ | grep -q -- "-o octep3 -j MASQUERADE" ||
	{ echo "FAIL: rule missing" >&2; exit 1; }
[ "$(iptables -t nat -S POSTROUTING | grep -c -- "-j XGS_MASQ")" = 1 ] || { echo "FAIL: jump not single" >&2; exit 1; }
[ "$(cat /proc/sys/net/ipv4/ip_forward)" = 1 ] || { echo "FAIL: ip_forward off" >&2; exit 1; }
sh "$S" start >/dev/null || { echo "FAIL: second start" >&2; exit 1; }
sh "$S" stop
if iptables -t nat -n -L XGS_MASQ >/dev/null 2>&1; then echo "FAIL: stop left the chain" >&2; exit 1; fi
sh "$S" stop || { echo "FAIL: second stop" >&2; exit 1; }
echo "PASS: masquerade starts without adapters, is idempotent, enables forwarding and stops cleanly"
' sh "$SCRIPT_DIR"
