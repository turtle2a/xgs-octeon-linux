#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 turtle2a <354865938+turtle2a@users.noreply.github.com>
# Fast live deploy of a locally built octep.ko with validation and rollback.
# Usage (root): octep-fastdeploy.sh [path/to/octep.ko]
# Swaps the installed module, reloads it, waits for the front-port links and
# restores the previous module if the load or bring-up fails. The kernel's
# xz decoder only accepts CRC32 checks (default CRC64 fails modprobe with
# "decompression failed with status 6"). Run
# ./install.sh --replace-managed at the end so the DKMS copy matches.
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
KO=${1:-$ROOT/octep/octep.ko}
DEST=/lib/modules/$(uname -r)/extra/octep.ko.xz
PREV_DIR=/var/lib/xgs
PREV=${OCTEP_DEPLOY_PREV:-$PREV_DIR/octep.ko.xz.prev}
LINKS_WANT=${OCTEP_DEPLOY_LINKS:-10}
WAIT_S=${OCTEP_DEPLOY_WAIT_S:-240}
UNIT=xgs-octep-sdp-bringup.service

[ "$(id -u)" -eq 0 ] || { echo "octep-fastdeploy: run as root" >&2; exit 2; }
[ -r "$KO" ] || { echo "octep-fastdeploy: missing $KO" >&2; exit 2; }

# The octep ports go down for the reload and NPU reset; the mgmt port must not.
MGMT=${OCTEP_MGMT_IF:-enp2s0}
mgmt_state() { printf '%s %s\n' "$(cat /sys/class/net/$MGMT/carrier 2>/dev/null)" "$(ip -4 -o addr show dev "$MGMT" 2>/dev/null | awk '{print $4}' | sort | tr '\n' ',')"; }
case "$(mgmt_state)" in 1\ *) ;; *) echo "octep-fastdeploy: refusing, mgmt port $MGMT has no carrier (you would lose access)" >&2; exit 2 ;; esac
MGMT_BEFORE=$(mgmt_state)
live=$(grep -cE "ESTABLISHED" /proc/net/nf_conntrack 2>/dev/null || echo 0)
echo "octep-fastdeploy: NOTICE octep ports and hosts behind them drop for ~3 min; $live established flows will break; $MGMT is left alone"

links() { ls /sys/class/net 2>/dev/null | grep -c '^octep'; }

wait_links() {
	t=0
	while [ "$t" -lt "$WAIT_S" ]; do
		[ "$(links)" -ge "$LINKS_WANT" ] && return 0
		sleep 5
		t=$((t + 5))
	done
	return 1
}

restore() {
	echo "octep-fastdeploy: restoring the previous module"
	cp "$PREV" "$DEST" && depmod -a
	systemctl reset-failed "$UNIT" 2>/dev/null
	systemctl restart "$UNIT"
	if wait_links; then
		echo "octep-fastdeploy: ROLLED BACK, $(links) links up"
	else
		echo "octep-fastdeploy: rollback bring-up incomplete; the status timer keeps retrying" >&2
	fi
}

mkdir -p -m 0700 "$(dirname -- "$PREV")" || exit 2
rm -f -- "$PREV"
cp -P --no-preserve=mode "$DEST" "$PREV" || exit 2
xz --check=crc32 -c "$KO" >"$DEST.new" && mv "$DEST.new" "$DEST" || { echo "octep-fastdeploy: install failed" >&2; exit 2; }
depmod -a

systemctl stop "$UNIT" 2>/dev/null
rmmod octep 2>/dev/null
start=$(date +%s)
if ! modprobe octep ${OCTEP_MODPARAMS:-}; then
	echo "octep-fastdeploy: modprobe failed; kernel says:" >&2
	dmesg | tail -5 >&2
	restore
	exit 1
fi
systemctl reset-failed "$UNIT" 2>/dev/null
systemctl start "$UNIT" &
# An unloaded module leaves the NPU handshake owned, so the SR-IOV step is
# refused until the NPU is reset; do that once if the links are slow.
WAIT_S_ALL=$WAIT_S
WAIT_S=${OCTEP_DEPLOY_FIRST_WAIT_S:-90}
if ! wait_links; then
	echo "octep-fastdeploy: links slow after reload; running the wedged-NPU recovery"
	"$ROOT/scripts/octep/sdp-recover-npu.sh" --wedged
fi
WAIT_S=$WAIT_S_ALL
if wait_links; then
	[ "$(mgmt_state)" = "$MGMT_BEFORE" ] || echo "octep-fastdeploy: WARNING $MGMT changed during deploy: before [$MGMT_BEFORE] after [$(mgmt_state)]" >&2
	# The reload re-creates octep1, so the kernel drops the WAN policy route; re-apply it.
	systemctl restart xgs-nat.service 2>/dev/null || true
	echo "octep-fastdeploy: DEPLOYED, $(links) links up in $(($(date +%s) - start))s"
	exit 0
fi
echo "octep-fastdeploy: links did not return in ${WAIT_S}s" >&2
restore
exit 1
