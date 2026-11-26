#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 turtle2a <354865938+turtle2a@users.noreply.github.com>
# Offline test of xgs-boot-gate.sh: fake module tree, stub grubby and modinfo. Changes nothing on the host.
#   scripts/tests/xgs-boot-gate-test.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
GATE=$HERE/../xgs/xgs-boot-gate.sh
T=$(mktemp -d "${TMPDIR:-/var/tmp}/xgs-gate.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
fail=0

# Stub grubby records the requested default; stub modinfo reports the kernel named in the file path.
printf '#!/bin/sh\necho "$@" >> %s/grubby.calls\n[ -z "${GRUBBY_FAIL:-}" ]\n' "$T" >"$T/grubby"
printf '#!/bin/sh\nbasename "$(dirname "$(dirname "$3")")"\n' >"$T/modinfo"
chmod +x "$T/grubby" "$T/modinfo"

run() { # name expect-exit expect-pin(0/1) env...
	name=$1 want=$2 pin=$3; shift 3
	: >"$T/grubby.calls"
	env XGS_RUN_KV=7.3.4 XGS_NEW_KV=7.3.5 XGS_MODROOT="$T/mods" XGS_GRUBBY="$T/grubby" \
		XGS_MODINFO="$T/modinfo" XGS_BOOTDIR=/boot "$@" "$GATE" >"$T/out" 2>&1
	rc=$?
	calls=$(wc -l <"$T/grubby.calls")
	ok=0
	if [ "$rc" = "$want" ]; then
		[ "$pin" = 1 ] && [ "$calls" = 1 ] && ok=1
		[ "$pin" = 0 ] && [ "$calls" = 0 ] && ok=1
	fi
	if [ "$ok" = 1 ]; then
		echo "PASS $name"
	else
		echo "FAIL $name (rc=$rc want=$want, grubby calls=$calls want=$pin)"; sed 's/^/    /' "$T/out"; fail=1
	fi
}

mkdir -p "$T/mods/7.3.5/extra" "$T/mods/7.3.6/extra" "$T/mods/7.3.7/extra"
: >"$T/mods/7.3.5/extra/octep.ko.xz"
: >"$T/mods/7.3.6/extra/octep.ko.xz"

run "module present for new kernel: default unchanged" 0 0
run "no module for new kernel: pin to running kernel" 0 1 XGS_NEW_KV=7.3.7
run "module dir exists but wrong vermagic: pin" 0 1 XGS_NEW_KV=7.3.6 XGS_MODINFO=/bin/echo
run "new kernel is the running kernel: nothing to do" 0 0 XGS_NEW_KV=7.3.4
run "pin attempted but grubby fails: exit 1" 1 1 XGS_NEW_KV=7.3.7 GRUBBY_FAIL=1
run "no grubby available: not applicable (2)" 2 0 XGS_GRUBBY=/nonexistent
exit $fail
