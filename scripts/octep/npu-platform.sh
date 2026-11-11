#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -n "${NPU_RUN_SCRIPT:-}" ]; then
	NPU_RUN=$NPU_RUN_SCRIPT
elif [ -x "$SCRIPT_DIR/../xgs/npu-run.sh" ]; then
	NPU_RUN=$SCRIPT_DIR/../xgs/npu-run.sh
else
	NPU_RUN=/usr/local/xgs/linux/scripts/xgs/npu-run.sh
fi
OUT=${1:-/var/lib/os-xgs-npu/npu-platform.txt}
TMP="${OUT}.new"

mkdir -p "$(dirname "$OUT")"
if ! "$NPU_RUN" 20 xgs-platform | grep '^npu0\.' >"$TMP"; then
	rm -f "$TMP"
	echo "npu-platform: could not read platform data from the coprocessor" >&2
	exit 1
fi
if [ ! -s "$TMP" ]; then
	rm -f "$TMP"
	echo "npu-platform: coprocessor returned no npu0 platform keys" >&2
	exit 1
fi
mv "$TMP" "$OUT"
echo "npu-platform: $(grep -c . "$OUT") keys in $OUT"
