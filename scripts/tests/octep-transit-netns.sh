#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Transit-flow test bed: two OCTEP front ports joined by a patch cable, each in
# its own namespace, so both directions of a flow arrive from the wire and the
# firmware offers a candidate for each. Only octep interfaces are touched; the
# gateway port (octep1) and enp* are never used.
#   up       move the ports into namespaces and address them
#   probe    open the offload gate briefly, ping across, show candidates
#   links    read-only per-port NWA unicast counters
#   down     close the gate and move the ports back
set -euo pipefail

PF=${OCTEP_PF:-/sys/bus/pci/devices/0000:01:00.0}
PORT_A=${PORT_A:-octep3}
PORT_B=${PORT_B:-octep4}
NS_A=octep-tx-a
NS_B=octep-tx-b
IP_A=${IP_A:-10.77.0.1}
IP_B=${IP_B:-10.77.0.2}

[ "$(id -u)" -eq 0 ] || {
	echo "SUDO REQUIRED: run as root (sudo $0 $*)" >&2
	exit 1
}

gate_off() { echo off >"$PF/offload" 2>/dev/null || true; }

up() {
	local ns port addr
	for entry in "$NS_A:$PORT_A:$IP_A" "$NS_B:$PORT_B:$IP_B"; do
		IFS=: read -r ns port addr <<<"$entry"
		ip netns add "$ns"
		ip link set "$port" netns "$ns"
		ip -n "$ns" link set lo up
		ip -n "$ns" addr add "$addr/24" dev "$port"
		ip -n "$ns" link set "$port" up
	done
	sleep 2
	echo "up: $PORT_A=$IP_A ($NS_A) <-> $PORT_B=$IP_B ($NS_B)"
}

probe() {
	trap gate_off EXIT
	ip netns exec "$NS_A" ping -c 2 -W 2 "$IP_B" || echo "WARN: no reply (gate closed)"
	echo on >"$PF/offload"
	cat "$PF/offload"
	ip netns exec "$NS_A" ping -c 20 -i 0.2 -W 2 "$IP_B" || true
	sleep 1
	cat "$PF/rx_flow"
	cat "$PF/flow_stats"
}

links() {
	local tag port rx tx n
	for n in 0 1 2 3 4 5 6 7 8 9; do
		tag=$((0x8100 + n * 0x100))
		printf '4 14 %d 0 0\n' "$tag" >"$PF/nwa_request"
		port=$(cat "$PF/nwa_last")
		rx=$(printf '%s\n' "$port" | awk -F= '$1 == "unicast_frames_received" { print $2 }')
		tx=$(printf '%s\n' "$port" | awk -F= '$1 == "unicast_frames_sent" { print $2 }')
		printf 'octep%d tag=0x%x rx_ucast=%s tx_ucast=%s\n' "$n" "$tag" "${rx:-?}" "${tx:-?}"
	done
}

down() {
	local ns port
	gate_off
	for pair in "$NS_A:$PORT_A" "$NS_B:$PORT_B"; do
		ns=${pair%%:*}
		port=${pair##*:}
		ip netns list | grep -q "^$ns" || continue
		ip -n "$ns" link set "$port" netns 1 2>/dev/null || true
		ip netns del "$ns"
		ip link set "$port" up
	done
	cat "$PF/offload"
	ip -br link show dev "$PORT_A"
	ip -br link show dev "$PORT_B"
}

case ${1:-} in
up) up ;;
probe) probe ;;
links) links ;;
down) down ;;
*) echo "usage: $0 up|probe|links|down" >&2; exit 64 ;;
esac
