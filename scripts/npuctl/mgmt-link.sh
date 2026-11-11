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
LINK=${NPU_MGMT_IF:-}
HOST_ADDR=${NPU_HOST_ADDR:-169.254.254.1}
NPU_ADDR=${NPU_ADDR:-169.254.254.2}
PREFIX_LEN=${NPU_PREFIX_LEN:-30}
KEY=${NPU_SSH_KEY:-"${HOME}/.ssh/id_ed25519_npu"}

require_link() {
	[ -n "$LINK" ] || { echo "set NPU_MGMT_IF to the host management-link interface" >&2; return 1; }
	ip link show dev "$LINK" >/dev/null 2>&1 ||
		{ echo "no management-link interface: $LINK" >&2; return 1; }
}

allow_npu_input() {
	command -v nft >/dev/null 2>&1 || { echo "nft is required for the management-link rule" >&2; return 1; }
	nft list chain inet filter input >/dev/null 2>&1 || {
		echo "nft chain 'inet filter input' is unavailable; configure the host firewall for $NPU_ADDR on $LINK" >&2
		return 1
	}
	if ! nft -a list chain inet filter input |
		grep -F "iifname \"$LINK\" ip saddr $NPU_ADDR accept" >/dev/null; then
		nft insert rule inet filter input iifname "$LINK" ip saddr "$NPU_ADDR" accept
	fi
}

host_up() {
	require_link
	ip addr replace "$HOST_ADDR/$PREFIX_LEN" dev "$LINK"
	ip link set dev "$LINK" up
	allow_npu_input
}

case ${1:-status} in
assign|start)
	host_up
	echo "$LINK configured at $HOST_ADDR/$PREFIX_LEN (runtime only)"
	;;
coprocessor)
	host_up
	"$NPU_RUN" 15 "ip addr replace $NPU_ADDR/$PREFIX_LEN dev mvmgmt0; ip link set dev mvmgmt0 up"
	;;
status)
	if [ -z "$LINK" ] || ! ip link show dev "$LINK" >/dev/null 2>&1; then
		echo "management-link interface unavailable; set NPU_MGMT_IF after the driver creates it"
		exit 0
	fi
	ip -brief address show dev "$LINK"
	ip link show dev "$LINK" | head -1
	if ping -I "$LINK" -c 2 -W 2 "$NPU_ADDR" >/dev/null 2>&1; then
		echo "coprocessor $NPU_ADDR: reachable"
	else
		echo "coprocessor $NPU_ADDR: not reachable"
	fi
	;;
ssh)
	require_link
	shift
	exec ssh -i "$KEY" -b "$HOST_ADDR" -o BatchMode=yes -o ConnectTimeout=8 \
		"root@$NPU_ADDR" "$@"
	;;
trust)
	require_link
	command -v ssh-keygen >/dev/null 2>&1 || { echo "ssh-keygen is required" >&2; exit 1; }
	[ -f "$KEY" ] || {
		mkdir -p -m 0700 "$(dirname "$KEY")"
		ssh-keygen -q -t ed25519 -N '' -f "$KEY" -C xgs-host-to-npu
	}
	PUB=$(cat "$KEY.pub")
	BODY=$(printf '%s\n' "$PUB" | awk '{print $2}')
	"$NPU_RUN" 10 "xgs-remount.sh rw && (grep -qF '$BODY' /root/.ssh/authorized_keys || { sed -i '/xgs-host-to-npu/d' /root/.ssh/authorized_keys; echo '$PUB' >> /root/.ssh/authorized_keys; }) && xgs-remount.sh ro"
	;;
*)
	echo "usage: $0 assign|start|coprocessor|trust|status|ssh [command]" >&2
	exit 2
	;;
esac
