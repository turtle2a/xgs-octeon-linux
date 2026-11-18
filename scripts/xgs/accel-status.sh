#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -u

SYSFS_ROOT=${XGS_NPU_PCI_SYSFS:-/sys/bus/pci/devices}
VENDOR_ID=0x177d
DEVICE_ID=0xa300
found=0
failed=0
KMSG_AVAILABLE=0
ACTION=${1:-status}

case $ACTION in
status|on|off) ;;
*)
	echo "usage: accel-status.sh [status|on|off]" >&2
	exit 64
	;;
esac
[ "$#" -le 1 ] || {
	echo "usage: accel-status.sh [status|on|off]" >&2
	exit 64
}

if [ -w /dev/kmsg ]; then
	KMSG_AVAILABLE=1
else
	printf 'xgs-accel-status: cannot write to /dev/kmsg; run with sudo to log results to dmesg\n' >&2
fi

log() {
	message="xgs-accel-status: $*"
	printf '%s\n' "$message"
	if [ "$KMSG_AVAILABLE" -eq 1 ]; then
		printf '<6>%s\n' "$message" > /dev/kmsg 2>/dev/null || {
			KMSG_AVAILABLE=0
			printf 'xgs-accel-status: failed to write results to /dev/kmsg\n' >&2
		}
	fi
}

problem() {
	log "ERROR: $*"
	failed=1
}

check_forwarding() {
	forwarding_ready=1
	check_sysctl() {
		setting=$1
		path=$2
		expected=$3
		apply=${4:-yes}
		if [ "$ACTION" = on ] && [ "$(id -u)" -eq 0 ] &&
			[ "$apply" = yes ]; then
			value=$(cat "$path" 2>/dev/null || true)
			if [ "$value" != "$expected" ]; then
				if ! command -v sysctl >/dev/null 2>&1; then
					problem "sysctl is required to set $setting=$expected"
					forwarding_ready=0
				elif sysctl -w "$setting=$expected" >/dev/null 2>&1; then
					log "applied host-readiness sysctl $setting=$expected"
				else
					problem "could not set host-readiness sysctl $setting=$expected"
					forwarding_ready=0
				fi
			fi
		fi
		value=$(cat "$path" 2>/dev/null || true)
		if [ "$value" = "$expected" ]; then
			log "host-readiness sysctl $setting=$expected"
		else
			log "host-readiness sysctl $setting=${value:-unavailable}"
			if [ "$ACTION" != off ]; then
				problem "$setting must be $expected before opening the offload gate"
				forwarding_ready=0
			fi
		fi
	}

	check_sysctl net.ipv4.ip_forward /proc/sys/net/ipv4/ip_forward 1
	check_sysctl net.ipv4.conf.all.forwarding /proc/sys/net/ipv4/conf/all/forwarding 1
	check_sysctl net.ipv4.conf.default.forwarding /proc/sys/net/ipv4/conf/default/forwarding 1
	check_sysctl net.ipv4.conf.all.bc_forwarding /proc/sys/net/ipv4/conf/all/bc_forwarding 1

	interface_count=0
	for interface_path in /sys/class/net/octep[0-9]*; do
		[ -e "$interface_path" ] || continue
		interface=${interface_path##*/}
		interface_count=$((interface_count + 1))
		for setting in forwarding; do
			check_sysctl "net.ipv4.conf.$interface.$setting" \
				"/proc/sys/net/ipv4/conf/$interface/$setting" 1
		done
		check_sysctl "net.ipv4.conf.$interface.bc_forwarding" \
			"/proc/sys/net/ipv4/conf/$interface/bc_forwarding" 1
		for setting in force_forwarding forwarding; do
			check_sysctl "net.ipv6.conf.$interface.$setting" \
				"/proc/sys/net/ipv6/conf/$interface/$setting" 1
		done
	done
	if [ "$interface_count" -eq 0 ]; then
		log "host-readiness sysctls: no OCTEP front-port interfaces found"
		if [ "$ACTION" != off ]; then
			problem "OCTEP front-port interfaces are required before opening the offload gate"
			forwarding_ready=0
		fi
	fi

	report_multicast_routing_state
}

report_multicast_routing_state() {
	for family in ipv4 ipv6; do
		path="/proc/sys/net/$family/conf/all/mc_forwarding"
		value=$(cat "$path" 2>/dev/null || true)
		if [ -n "$value" ]; then
			log "host multicast-routing state net.$family.conf.all.mc_forwarding=$value (kernel-managed; not a writable forwarding toggle)"
		else
			log "host multicast-routing state net.$family.conf.all.mc_forwarding=unavailable"
		fi
	done
}

report_network_paths() {
	if ! command -v ip >/dev/null 2>&1; then
		log "route diagnostics unavailable: ip command not found"
	else
		for family in 4 6; do
			output=$(ip "-$family" route show table all 2>&1)
			rc=$?
			if [ "$rc" -ne 0 ]; then
				log "IPv$family route table unavailable: $output"
			elif [ -z "$output" ]; then
				log "IPv$family route table: empty"
			else
				log "IPv$family routes (informational; destination path needs a transit test):"
				while IFS= read -r line || [ -n "$line" ]; do
					log "IPv$family route: $line"
				done <<EOF
$output
EOF
			fi
			output=$(ip "-$family" rule show 2>&1)
			rc=$?
			if [ "$rc" -ne 0 ]; then
				log "IPv$family policy rules unavailable: $output"
			else
				while IFS= read -r line || [ -n "$line" ]; do
					log "IPv$family rule: $line"
				done <<EOF
$output
EOF
			fi
		done
	fi

	if ! command -v nft >/dev/null 2>&1; then
		log "nftables diagnostics unavailable: nft command not found"
		return
	fi

	output=$(nft list tables 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		log "nftables table list unavailable: $output"
	else
		log "nftables tables:"
		if [ -n "$output" ]; then
			while IFS= read -r line || [ -n "$line" ]; do
				log "nft table: $line"
			done <<EOF
$output
EOF
		else
			log "nftables tables: none"
		fi
	fi

	output=$(nft -a list ruleset 2>&1)
	rc=$?
	if [ "$rc" -ne 0 ]; then
		log "nftables ruleset unavailable: $output"
		return
	fi
	log "nftables ruleset snapshot (first 80 lines):"
	line_count=0
	while IFS= read -r line || [ -n "$line" ]; do
		line_count=$((line_count + 1))
		[ "$line_count" -le 80 ] && log "nft: $line"
	done <<EOF
$output
EOF
	if [ "$line_count" -gt 80 ]; then
		log "nftables ruleset truncated: $line_count total lines"
	fi
}

state_value() {
	key=$1
	state=$2
	printf '%s\n' "$state" |
		awk -v key="$key" '
			{
				for (i = 1; i <= NF; i++) {
					split($i, pair, "=")
					if (pair[1] == key) {
						print pair[2]
						exit
					}
				}
			}
		'
}

check_device() {
	device=$1
	bdf=${device##*/}

	log "PCI device $bdf"
	if [ -L "$device/driver" ]; then
		driver=$(basename "$(readlink "$device/driver")")
	else
		driver=unbound
	fi
	log "driver=$driver"
	if [ "$driver" != octep ]; then
		problem "$bdf is not bound to the octep driver"
		return
	fi

	driver_ready=0
	if [ ! -r "$device/state" ]; then
		problem "$bdf driver state is unavailable"
	else
		driver_state=$(cat "$device/state") || {
			problem "$bdf driver state could not be read"
			driver_state=
		}
		ready=$(state_value ready "$driver_state")
		if [ "$ready" = 1 ]; then
			log "driver_ready=yes"
			driver_ready=1
		else
			problem "$bdf driver is not ready (ready=${ready:-unknown})"
		fi
	fi

	sdp_ready=0
	front_netdevs=
	if [ ! -r "$device/sdp_state" ]; then
		problem "$bdf SDP state is unavailable"
	else
		sdp_state=$(cat "$device/sdp_state") || {
			problem "$bdf SDP state could not be read"
			sdp_state=
		}
		rings=$(state_value rings "$sdp_state")
		ring_count=$(state_value ring_count "$sdp_state")
		handshake=$(state_value handshake "$sdp_state")
		packet_service=$(state_value packet_service "$sdp_state")
		front_netdevs=$(state_value front_netdevs "$sdp_state")
		if [ "$rings" = armed ] &&
			[ "$ring_count" = 8 ] &&
			[ "$handshake" = completed ] &&
			[ "$packet_service" = rx-poll,tx-ring0 ]; then
			log "SDP packet path=READY (rings=$ring_count, handshake=$handshake, service=$packet_service)"
			sdp_ready=1
		else
			problem "$bdf SDP packet path is not ready (rings=${rings:-unknown}, ring_count=${ring_count:-unknown}, handshake=${handshake:-unknown}, service=${packet_service:-unknown})"
		fi
	fi

	rpc_configured=0
	rpc_write_gate=
	if [ -r "$device/rpc_state" ]; then
		rpc_state=$(cat "$device/rpc_state") || rpc_state=
		[ "$(state_value configured "$rpc_state")" = 1 ] &&
			rpc_configured=1
		rpc_write_gate=$(state_value write_gate "$rpc_state")
	else
		log "RPC state=status unavailable"
	fi

	check_forwarding

	if [ "$ACTION" != status ]; then
		if [ "$(id -u)" -ne 0 ]; then
			problem "run with sudo to change the offload gate"
		elif [ ! -w "$device/offload" ]; then
			problem "offload control is unavailable; install a driver version with the offload sysfs control"
		elif [ "$ACTION" = on ] &&
			{ [ "$driver_ready" -ne 1 ] || [ "$sdp_ready" -ne 1 ] ||
			  [ "$rpc_configured" -ne 1 ] || [ "$rpc_write_gate" != 0 ] ||
			  [ "$forwarding_ready" -ne 1 ]; }; then
			problem "refusing to open the gate until driver, SDP, RPC, port setup, and IPv4 forwarding are ready"
		elif [ "$ACTION" = on ]; then
			case $front_netdevs in
			''|*[!0-9]*)
				problem "cannot verify front-port LIF setup; refusing to open the gate"
				;;
			*)
				if [ "$front_netdevs" -lt 10 ]; then
					problem "only $front_netdevs front-port netdevs are configured; refusing to open the gate"
				elif printf '%s\n' "$ACTION" > "$device/offload"; then
					log "offload gate write accepted by the driver: $ACTION"
				else
					problem "driver rejected the offload gate request: $ACTION"
				fi
				;;
			esac
		elif printf '%s\n' "$ACTION" > "$device/offload"; then
			log "offload gate write accepted by the driver: $ACTION"
		else
			problem "driver rejected the offload gate request: $ACTION"
		fi
	fi

	if [ -r "$device/offload" ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			log "offload gate: $line"
		done < "$device/offload"
	else
		log "offload gate status=unknown (driver does not expose the control)"
	fi

	if [ -r "$device/nwa_ports" ]; then
		nwa_ports=$(cat "$device/nwa_ports") || nwa_ports=
		if printf '%s\n' "$nwa_ports" | grep -q '^ports='; then
			log "NWA discovery=reported"
		else
			log "NWA discovery=not yet successful"
		fi
	else
		log "NWA discovery=status unavailable"
	fi
}

for device in "$SYSFS_ROOT"/*; do
	[ -d "$device" ] || continue
	[ -r "$device/vendor" ] && [ -r "$device/device" ] || continue
	[ "$(cat "$device/vendor")" = "$VENDOR_ID" ] || continue
	[ "$(cat "$device/device")" = "$DEVICE_ID" ] || continue

	found=1
	check_device "$device"
done

if [ "$found" -eq 0 ]; then
	problem "PCI device $VENDOR_ID:$DEVICE_ID was not found"
fi

report_network_paths

log "multicast_offload=NOT READY (Linux multicast routes/groups and return paths are not synchronized into NPU state)"
log "automatic_flow_lifecycle=NOT IMPLEMENTED (the global gate does not install or latch per-flow NPU entries)"
log "active_hardware_offload=NOT VERIFIED (gate status does not show whether any traffic is being offloaded)"
if [ "$failed" -eq 0 ]; then
	log "host/NPU transport readiness=READY; this does not prove unicast or multicast packet offload is active"
else
	log "host/NPU transport readiness=NOT READY"
fi

exit "$failed"
