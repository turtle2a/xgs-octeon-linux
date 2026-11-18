#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Idle opcode scan: sends each unassigned low RPC opcode once with a payload of 0xff bytes (out-of-range
# indices, so a recognised command should refuse it) through rpc_raw_write, and records the NPU return
# code. A return code that differs from the unknown-opcode baseline marks a command the firmware implements.
#   octep-opcode-scan.sh [OPCODES]      OPCODES: space-separated list, default "1 4 7 9 11 12 13 14 15 17-35"
# Needs the loaded octep with rpc_raw_cmd/rpc_raw_write. Stops at once if the RPC channel stops answering
# (the status timer then recovers it). Never touches enp2s0, never sends the known write opcodes.
set -u
DEV=/sys/bus/pci/devices/0000:01:00.0
PARM=/sys/module/octep/parameters/rpc_raw_cmd
[ "$(id -u)" -eq 0 ] || { echo "SUDO REQUIRED: sudo $0 $*" >&2; exit 1; }
[ -w "$PARM" ] && [ -e "$DEV/rpc_raw_write" ] || { echo "FAIL: loaded octep has no rpc_raw_cmd/rpc_raw_write" >&2; exit 1; }

# "fwcfg HEX4": send FW_CFG_PARAMS_SET (opcode 2) with a 4-byte payload, e.g. 01000000 = offload on, TCP seq check off
# (Sophos "be liberal"); the default build sends 03000000. Needs the write gate already open (octep-hook-live.sh
# opens it), so it neither opens nor closes the gate. Revert with fwcfg 03000000 (the hook run's exit does "offload off").
if [ "${1:-}" = fwcfg ]; then
	[ "$(cat "$DEV/rpc_allow_write" 2>/dev/null)" = 1 ] || { echo "FAIL: write gate closed; start octep-hook-live.sh first" >&2; exit 1; }
	echo 2 > "$PARM"
	echo "2 ${2:?4-byte hex payload}" > "$DEV/rpc_raw_write" 2>/dev/null
	echo "fwcfg $2 write rc=$?: $(dmesg 2>/dev/null | grep -aE 'rpc: (command 2 |raw cmd 2 )' | tail -2 | sed 's/.*octep 0000:01:00.0: //' | tr '\n' '|')"
	echo -1 > "$PARM"
	exit 0
fi

cleanup() {
	echo -1 > "$PARM" 2>/dev/null
	echo 0 > "$DEV/rpc_allow_write" 2>/dev/null
}
trap cleanup EXIT

healthy() {
	case $(cat "$DEV/sdp_state" 2>/dev/null) in *rings=armed*handshake=completed*front_netdevs=10*) return 0 ;; esac
	return 1
}
healthy || { echo "FAIL: NPU not healthy; nothing sent. $(cat "$DEV/sdp_state")" >&2; exit 1; }
# After a wedge the status timer (--auto) recovers the NPU; report whether it did within 300 s.
wait_recovery() {
	t=0
	while [ "$t" -lt 300 ]; do
		healthy && { echo "RECOVERED by automation after ${t}s"; return 0; }
		sleep 10
		t=$((t + 10))
	done
	echo "NOT RECOVERED within 300s: $(cat "$DEV/sdp_state")"
	return 1
}
"$(dirname "$0")/../octep/rpc-port-setup.sh" >/dev/null 2>&1 || { echo "FAIL: rpc-port-setup" >&2; exit 1; }
echo 1 > "$DEV/rpc_allow_write" || { echo "FAIL: gate" >&2; exit 1; }

LIST=${1:-"1 4 7 9 11 12 13 14 15 17-35"}
# "lif-dump": read-only dump of the NPU LIF table (interfaces 0-15, vlan 0), no write gate, nothing sent but reads.
if [ "$LIST" = lif-dump ]; then
	for i in $(seq 0 15); do
		if echo "$i 0" > "$DEV/rpc_lif_read" 2>/dev/null; then
			echo "lif $i: $(cat "$DEV/rpc_lif_read")"
		else
			echo "lif $i: read refused"
		fi
	done
	exit 0
fi
# "lif-set BYTE VALUE": rewrite LIFs 0-9 with the driver's normal LIF payload but payload byte BYTE (4-17) set
# to VALUE, via opcode 3, then dump the readback. Probe for a per-LIF offload bit; revert with "lif-set 13 0".
if [ "$LIST" = lif-set ]; then
	byte=${2:?byte offset 4-17}
	val=$((${3:?value}))
	echo 3 > "$PARM"
	for i in $(seq 0 9); do
		echo "$i 0" > "$DEV/rpc_lif_read" 2>/dev/null || { echo "lif $i: read refused"; continue; }
		mac=$(sed -n 's/.*mac=\([0-9a-f:]*\) .*/\1/p' "$DEV/rpc_lif_read")
		hex=$(python3 - "$i" "$mac" "$byte" "$val" <<'PY'
import sys
i, mac, byte, val = int(sys.argv[1]), sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
p = bytearray(18)
p[0:4] = (i << 12).to_bytes(4, "little")
p[4:10] = bytes.fromhex(mac.replace(":", ""))
p[10:12] = (1500).to_bytes(2, "little")
p[12] = 2; p[14] = 1; p[16:18] = (0xff).to_bytes(2, "little")
p[byte] = val
print(p.hex())
PY
)
		echo "3 $hex" > "$DEV/rpc_raw_write" 2>/dev/null
		echo "lif $i set byte $byte=$val write rc=$? ; $(echo "$i 0" > "$DEV/rpc_lif_read"; cat "$DEV/rpc_lif_read" | sed 's/.*reply_len/reply_len/')"
	done
	exit 0
fi
OPS=
for t in $LIST; do
	case $t in
	*-*) OPS="$OPS $(seq "${t%-*}" "${t#*-}")" ;;
	*) OPS="$OPS $t" ;;
	esac
done

PAYLOAD=ffffffffffffffff
for op in $OPS; do
	case $op in 0|2|3|5|6|8|10|16) echo "skip known opcode $op"; continue ;; esac
	mark=$(date +%s.%N)
	echo "$op" > "$PARM"
	echo "$op $PAYLOAD" > "$DEV/rpc_raw_write" 2>/dev/null
	rc=$?
	last=$(dmesg --time-format iso 2>/dev/null | grep -aE "rpc: (command $op |raw cmd $op )" | tail -2 | sed 's/.*octep 0000:01:00.0: //' | tr '\n' '|')
	echo "op $op: write rc=$rc  $last"
	healthy || { echo "STOP: NPU/RPC no longer healthy after opcode $op; waiting for automation"; wait_recovery; exit 2; }
	sleep 0.3
done
echo "scan done"
healthy && echo "post-scan: NPU healthy" || { echo "post-scan: NPU NOT healthy"; wait_recovery; }
