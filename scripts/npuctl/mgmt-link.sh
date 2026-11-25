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
NPU_PCI=${NPU_PCI:-0000:01:00.0}
LINK=${NPU_MGMT_IF:-}
if [ -z "$LINK" ]; then
	# The NPU link is the netdev on the NPU's own PCI function (not the octep front ports).
	for d in /sys/bus/pci/devices/"$NPU_PCI"/net/*; do
		[ -e "$d" ] || continue
		case ${d##*/} in octep*) continue ;; esac
		LINK=${d##*/}
		break
	done
fi
HOST_ADDR=${NPU_HOST_ADDR:-169.254.254.1}
NPU_ADDR=${NPU_ADDR:-169.254.254.2}
PREFIX_LEN=${NPU_PREFIX_LEN:-30}
if [ -n "${NPU_SSH_KEY:-}" ]; then
	KEY=$NPU_SSH_KEY
elif [ -f /etc/keys/mvmgt.x86 ]; then
	KEY=/etc/keys/mvmgt.x86
else
	KEY="${HOME}/.ssh/id_ed25519_npu"
fi

require_link() {
	[ -n "$LINK" ] || { echo "no NPU link netdev found; set NPU_MGMT_IF" >&2; return 1; }
	ip link show dev "$LINK" >/dev/null 2>&1 ||
		{ echo "no management-link interface: $LINK" >&2; return 1; }
}

allow_npu_input() {
	command -v nft >/dev/null 2>&1 || { echo "nft is required for the management-link rule" >&2; return 1; }
	nft list chain inet filter input >/dev/null 2>&1 || {
		echo "nft chain 'inet filter input' is unavailable; configure the host firewall for $NPU_ADDR on $LINK" >&2
		return 1
	}
	# Default: the NPU may only answer host-initiated connections (ssh). NPU_INPUT=all restores the old
	# unrestricted accept from the NPU address.
	if [ "${NPU_INPUT:-replies}" = all ]; then
		rule="accept"
	else
		rule="ct state established,related accept"
	fi
	if ! nft -a list chain inet filter input |
		grep -F "iifname \"$LINK\" ip saddr $NPU_ADDR $rule" >/dev/null; then
		[ "$rule" = accept ] || nft insert rule inet filter input iifname "$LINK" ip saddr "$NPU_ADDR" drop
		nft insert rule inet filter input iifname "$LINK" ip saddr "$NPU_ADDR" $rule
	fi
}

host_up() {
	require_link
	ip addr replace "$HOST_ADDR/$PREFIX_LEN" dev "$LINK"
	ip link set dev "$LINK" up
	# With ufw the host firewall rules come from install.sh; the nft rule is only for plain nftables hosts.
	allow_npu_input || echo "note: nft rule not added; make sure the host firewall allows $NPU_ADDR on $LINK" >&2
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
		echo "management-link interface unavailable; NPU link netdev not found; set NPU_MGMT_IF"
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
		-o StrictHostKeyChecking=accept-new "root@$NPU_ADDR" "$@"
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
