#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Opt-in: turn on NPU flow offload after the rings are armed and rpc-port-setup.sh has finished.
# Run by hand or add it as an ExecStartPost of the bring-up unit. Offload is off by default.
# Once invoked it exits non-zero unless every gate reads on, so a unit using it fails loudly.
# Never touches enp2s0.
set -u
DEV=/sys/bus/pci/devices/0000:01:00.0
PARAM=/sys/module/octep/parameters/flow_offload
TABLE=xgs_offload
LAN=${XGS_OFFLOAD_LAN:-octep0}
WAN=${XGS_OFFLOAD_WAN:-octep1}

fail() {
	echo "xgs-offload-enable: FAIL: $*" >&2
	echo 0 >"$DEV/rpc_allow_write" 2>/dev/null
	exit 1
}

case "$LAN$WAN" in *enp2s0*) fail "refusing enp2s0" ;; esac
WAIT_S=${XGS_OFFLOAD_WAIT_S:-180}

# Wait (bounded) for the rings to be armed; the NPU can take minutes to answer after boot.
i=0
until case $(cat "$DEV/sdp_state" 2>/dev/null) in *rings=armed*handshake=completed*front_netdevs=[1-9]*) true ;; *) false ;; esac; do
	[ "$i" -ge "$WAIT_S" ] && fail "rings not armed after ${WAIT_S}s: $(cat "$DEV/sdp_state" 2>/dev/null)"
	sleep 2; i=$((i + 2))
done
[ -w "$PARAM" ] || fail "loaded octep has no writable flow_offload"

# Baseline params = the tested configuration (same as octep-hook-live.sh); override via env.
P=/sys/module/octep/parameters
for kv in ft_tcp_state=Y ft_offload_nat=Y ft_verdict=${OCTEP_FT_VERDICT:-1} ft_brctl=${OCTEP_FT_BRCTL:-0} \
	ft_delay_ms=${OCTEP_FT_DELAY_MS:-0} ft_cutin=${OCTEP_FT_CUTIN:-0}; do
	[ -w "$P/${kv%%=*}" ] && echo "${kv#*=}" >"$P/${kv%%=*}" 2>/dev/null
done

# Offloaded data bypasses host conntrack, so later server ACKs look out of window; liberal mode keeps them from being INVALID.
[ -w /proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal ] && echo "${OCTEP_CT_LIBERAL:-1}" >/proc/sys/net/netfilter/nf_conntrack_tcp_be_liberal
echo Y >"$PARAM" || fail "could not set flow_offload=Y"
echo 1 >"$DEV/rpc_allow_write" || fail "could not open the RPC write gate"
echo on >"$DEV/offload" || fail "could not request firmware offload"
# Wait (bounded) for the firmware to acknowledge the gate.
i=0
until case $(cat "$DEV/offload" 2>/dev/null) in *requested=on*acknowledged=yes*) true ;; *) false ;; esac; do
	[ "$i" -ge "$WAIT_S" ] && fail "firmware gate not acknowledged after ${WAIT_S}s: $(cat "$DEV/offload" 2>/dev/null)"
	sleep 2; i=$((i + 2))
done

nft delete table inet "$TABLE" 2>/dev/null
nft add table inet "$TABLE" &&
	nft add flowtable inet "$TABLE" ft "{ hook ingress priority 0; devices = { $LAN, $WAN }; flags offload; }" &&
	nft add chain inet "$TABLE" offload_fwd "{ type filter hook forward priority 0; policy accept; }" &&
	nft add rule inet "$TABLE" offload_fwd ct state established flow add @ft ||
	fail "flowtable bind failed"

# Verify from fresh reads; never report offload on from what was written.
[ "$(cat "$PARAM")" = Y ] || fail "flow_offload is not Y"
[ "$(cat "$DEV/rpc_allow_write")" = 1 ] || fail "write gate is not open"
case $(cat "$DEV/offload") in
*requested=on*acknowledged=yes*) ;;
*) fail "firmware gate not on+acknowledged: $(cat "$DEV/offload")" ;;
esac
nft list flowtable inet "$TABLE" ft >/dev/null 2>&1 || fail "flowtable $TABLE missing"
echo "xgs-offload-enable: OFFLOAD ENABLED (verdict=$(cat $P/ft_verdict) brctl=$(cat $P/ft_brctl) tcp_state=$(cat $P/ft_tcp_state) flow_offload=Y, gate on+acknowledged, flowtable $TABLE on $LAN,$WAN)"
