#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Re-read the last completed offload run (no test is run, nothing is changed): prints the same
# one-page summary that octep-offload-check.sh ends with.
#   octep-offload-last.sh [run-tag]      (tag = takeover-YYYYMMDD-HHMMSS; default: last completed run)
# Runs that never opened the gate (e.g. refused because another run was active) are skipped.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LOGDIR=$ROOT/testlogs/hook-runs

tag=${1:-}
if [ -z "$tag" ]; then
	for f in $(ls -t "$LOGDIR"/hook-*.log 2>/dev/null); do
		if grep -q "^GATE ON" "$f"; then
			stamp=$(basename "$f" .log)
			tag=takeover-${stamp#hook-}
			break
		fi
	done
fi
[ -n "$tag" ] || { echo "no completed run found in $LOGDIR" >&2; exit 1; }

"$ROOT/scripts/octep/offload-summary.sh" "$tag"
rc=$?
"$ROOT/scripts/octep/offload-end-summary.sh" log "$LOGDIR/hook-${tag#takeover-}.log"
exit $rc
