#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
import pathlib
import subprocess
import tempfile

script = (pathlib.Path(__file__).resolve().parents[1] /
          "tests/octep-accel-telemetry-test.sh").read_text()
start = script.index("flow_chain_snapshot() {")
mid = script.index("\nflow_chain_delta() {", start)
end = script.index('\n\nlog "NWA port statistics', mid)
functions = script[start:end]

test = r"""
set -eu
PF=$1
flow_chain_before=$(flow_chain_snapshot)
printf '%s\n' "$flow_chain_before" | grep -Fx 'RX_WIRE=100'
printf '%s\n' "$flow_chain_before" | grep -Fx 'TX_DROP_QUEUE_FULL=3'
printf '%s\n' "$flow_chain_before" | grep -Fx 'MFLOW_NOT_ACTIVE=0'
cp "$PF/second" "$PF/rpc_sys_counters"
flow_chain_after=$(flow_chain_snapshot)
delta=$(flow_chain_delta "$flow_chain_before" "$flow_chain_after")
printf '%s\n' "$delta" | grep -Fx 'RX_WIRE=60'
printf '%s\n' "$delta" | grep -Fx 'TX_DROP_QUEUE_FULL=2'
printf '%s\n' "$delta" | grep -Fx 'FORCED=20'
printf '%s\n' "$delta" | grep -Fx 'NHOP_UNRESOLVED=25'
printf '%s\n' "$delta" | grep -Fx 'MFLOW_NOT_ACTIVE=35'
printf 'count=64 command_shift=0\n' > "$PF/rpc_sys_counters"
if flow_chain_snapshot; then
    echo "short system counter table was accepted" >&2
    exit 1
fi
"""

with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    counters = {0: 100, 1: 90, 2: 0, 3: 90, 8: 3, 9: 3, 12: 100,
                37: 0, 38: 0, 39: 100, 40: 0, 41: 0, 42: 0, 43: 0,
                44: 0, 45: 0, 46: 0, 47: 0, 48: 0, 49: 0, 50: 0,
                51: 0, 52: 0, 53: 0, 54: 0, 55: 0, 56: 0, 57: 0,
                58: 0, 59: 0, 60: 0}
    lines = ["count=128 command_shift=0"]
    lines.extend(f"{index}={value}" for index, value in counters.items())
    (root / "rpc_sys_counters").write_text("\n".join(lines) + "\n")
    counters.update({0: 160, 1: 150, 2: 50, 3: 150, 8: 7, 9: 5,
                     12: 160, 39: 120, 45: 25, 59: 35})
    lines = ["count=128 command_shift=0"]
    lines.extend(f"{index}={value}" for index, value in counters.items())
    (root / "second").write_text("\n".join(lines) + "\n")
    program = "set -e\n" + functions + "\n" + test
    result = subprocess.run(["bash", "-c", program, "test", str(root)],
                            check=True, text=True, capture_output=True)
    print(result.stdout, end="")
    print("telemetry NPU flow-chain counter deltas: PASS")
