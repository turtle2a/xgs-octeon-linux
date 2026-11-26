// SPDX-License-Identifier: GPL-2.0-or-later AND BSD-2-Clause
// Copyright (c) 2026 turtle2a <354865938+turtle2a@users.noreply.github.com>
// Portions derived from os-xgs-npu (https://github.com/AbdelmonemAwad/os-xgs-npu), Copyright (c) 2026 Abdelmonem Awad, BSD-2-Clause
/*
 * Linux PCI core for the OCTEON TX CN83XX endpoint (177d:a300).
 *
 * Probe only maps BAR0/BAR2 and reads the published facility map. SDP DMA
 * queues and the EP-mode handshake are started separately by explicit sysfs
 * writes; neither is activated as a side effect of PCI probe.
 */

#include <linux/version.h>
#include <linux/bitops.h>
#include <linux/build_bug.h>
#include <linux/dma-mapping.h>
#include <linux/etherdevice.h>
#include <linux/hex.h>
#include <linux/if_ether.h>
#include <linux/if_vlan.h>
#include <linux/in.h>
#include <linux/io.h>
#include <linux/delay.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/jiffies.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/netdevice.h>
#include <linux/pci.h>
#include <linux/slab.h>
#include <linux/skbuff.h>
#include <linux/spinlock.h>
#include <linux/sysfs.h>
#include <linux/unaligned.h>
#include <linux/workqueue.h>
#include <net/flow_offload.h>
#include <net/pkt_cls.h>
#include <net/netfilter/nf_conntrack.h>
#include <net/netfilter/nf_conntrack_core.h>
#include <net/netfilter/nf_conntrack_zones.h>
#include <linux/netfilter_ipv4.h>

#define OCTEP_VENDOR_ID			0x177d
#define OCTEP_CN83XX_PF_ID		0xa300

#define OCTEP_SDP_SCRATCH		0x20180
#define OCTEP_SDP_EPF_RINFO		0x20190
#define OCTEP_SLI_EPF_SCRATCH		0x28100
#define OCTEP_SDP_RING_STRIDE		0x20000
#define OCTEP_SDP_RING_SPAN		0x10198
#define OCTEP_SDP_EPF_R_VF_NUM		0x10500
#define OCTEP_SDP_EPF_MBOX_RINT		0x20000
#define OCTEP_SDP_R_MBOX_VF_PF_DATA	0x10230
#define OCTEP_SDP_RINFO_RPVF_MASK	(0x1fULL << 32)
#define OCTEP_SDP_RINFO_NVFS_MASK	(0x7fULL << 48)
#define OCTEP_SDP_VF_NUM_MASK		0x7fULL
#define OCTEP_READY_MAGIC		0xabcdabcdU

#define OCTEP_SDP_R_IN_CONTROL		0x10000
#define OCTEP_SDP_R_IN_ENABLE		0x10010
#define OCTEP_SDP_R_IN_INSTR_BADDR	0x10020
#define OCTEP_SDP_R_IN_INSTR_RSIZE	0x10030
#define OCTEP_SDP_R_IN_INSTR_DBELL	0x10040
#define OCTEP_SDP_R_IN_INT_LEVELS	0x10060
#define OCTEP_SDP_R_OUT_INT_LEVELS	0x10110
#define OCTEP_SDP_R_OUT_CNTS		0x10100
#define OCTEP_SDP_R_OUT_SLIST_BADDR	0x10120
#define OCTEP_SDP_R_OUT_SLIST_RSIZE	0x10130
#define OCTEP_SDP_R_OUT_SLIST_DBELL	0x10140
#define OCTEP_SDP_R_OUT_CONTROL		0x10150
#define OCTEP_SDP_R_OUT_ENABLE		0x10160

#define OCTEP_R_IN_CTL_IDLE		BIT_ULL(28)
#define OCTEP_R_IN_CTL_RDSIZE		(3ULL << 25)
#define OCTEP_R_IN_CTL_IS_64B		BIT_ULL(24)
#define OCTEP_R_IN_CTL_ESR		BIT_ULL(1)
#define OCTEP_R_OUT_CTL_IDLE		BIT_ULL(36)
#define OCTEP_R_OUT_CTL_IMODE		BIT_ULL(23)
#define OCTEP_R_OUT_CTL_ES_I		BIT_ULL(34)
#define OCTEP_R_OUT_CTL_NSR_I		BIT_ULL(33)
#define OCTEP_R_OUT_CTL_ROR_I		BIT_ULL(32)
#define OCTEP_R_OUT_CTL_ES_D		BIT_ULL(30)
#define OCTEP_R_OUT_CTL_NSR_D		BIT_ULL(29)
#define OCTEP_R_OUT_CTL_ROR_D		BIT_ULL(28)
#define OCTEP_R_OUT_CTL_ES_P		BIT_ULL(26)
#define OCTEP_R_OUT_CTL_NSR_P		BIT_ULL(25)
#define OCTEP_R_OUT_CTL_ROR_P		BIT_ULL(24)
#define OCTEP_R_OUT_CTL_SIZE_MASK	0x7fffffULL
#define OCTEP_R_OUT_CTL_ATTR_MASK	(OCTEP_R_OUT_CTL_IMODE | \
					 OCTEP_R_OUT_CTL_ES_I | \
					 OCTEP_R_OUT_CTL_NSR_I | \
					 OCTEP_R_OUT_CTL_ROR_I | \
					 OCTEP_R_OUT_CTL_ES_D | \
					 OCTEP_R_OUT_CTL_NSR_D | \
					 OCTEP_R_OUT_CTL_ROR_D | \
					 OCTEP_R_OUT_CTL_ES_P | \
					 OCTEP_R_OUT_CTL_NSR_P | \
					 OCTEP_R_OUT_CTL_ROR_P)

#define OCTEP_DP_RING_COUNT		8
#define OCTEP_SRIOV_VF_COUNT		4
#define OCTEP_SRIOV_RINGS_PER_VF	1
#define OCTEP_DP_IQ_DESCS		256
#define OCTEP_DP_OQ_DESCS		1024
#define OCTEP_DP_INSTR_SIZE		64
#define OCTEP_DP_SLIST_ENTRY		16
#define OCTEP_DP_BUF_SIZE		1602
#define OCTEP_DP_BUF_ALIGN		64
#define OCTEP_DP_BUF_STRIDE		ALIGN(OCTEP_DP_BUF_SIZE, \
					      OCTEP_DP_BUF_ALIGN)
#define OCTEP_DP_OQ_INFO_SIZE		16
#define OCTEP_DP_OQ_INTR_PKT		32
#define OCTEP_DP_OQ_INTR_TIME		50
#define OCTEP_DP_OQ_FETCH		16
#define OCTEP_DP_OQ_WMARK		1024
#define OCTEP_DP_IDLE_TRIES		1000
#define OCTEP_DP_POLL_MS		2
#define OCTEP_DP_RX_BUDGET		128
#define OCTEP_DP_TAG_LEN		66
#define OCTEP_DP_META_LEN		64
#define OCTEP_DP_INSTR_FSZ		28
#define OCTEP_DP_INSTR_SL		(OCTEP_DP_INSTR_FSZ + OCTEP_DP_TAG_LEN)
#define OCTEP_DP_PPORT_HLEN		2
#define OCTEP_DP_RX_PREFIX_LEN		82
#define OCTEP_DP_RX_TAG_OFF		16
/* The kernel metadata block starts at 18; its firmware-allocated flow identity is at +8. */
#define OCTEP_DP_RX_META_OFF		18
#define OCTEP_DP_RX_META_SIG		0xb44399a2U
#define OCTEP_DP_RX_META_VALID_SHIFT	8
#define OCTEP_DP_RX_FLOW_OFF		(OCTEP_DP_RX_META_OFF + 8)
#define OCTEP_DP_RX_FLOW_ID_MASK	GENMASK(24, 0)
#define OCTEP_DP_RX_FLOW_REV_MASK	GENMASK(30, 25)
#define OCTEP_DP_RX_FLOW_VALID		BIT(31)
#define OCTEP_DP_IPV4_FRAGMENT_MASK	0x3fffU
#define OCTEP_DP_MIN_FRAME		60
#define OCTEP_DP_PKT_MAX		65535
#define OCTEP_DP_CMSG_TAG		254
#define OCTEP_CMSG_ETHERTYPE		0xefef
#define OCTEP_CMSG_VERSION		1
#define OCTEP_CMSG_TYPE_CONN_STATS	1
#define OCTEP_CMSG_HDR_LEN		8
#define OCTEP_CMSG_CONN_ENTRY_LEN	18
#define OCTEP_CMSG_CONN_INDEX_MASK	0x03ffffffU
#define OCTEP_CMSG_CONN_COUNT_SHIFT	26
#define OCTEP_CMSG_PKT_SHIFT		3
#define OCTEP_CMSG_PKT_MASK		0x1fffffffU
#define OCTEP_FLOW_STATS_MAX		256
#define OCTEP_FLOW_STATS_SHOW_MAX	24
#define OCTEP_FLOW_STATS_LIVE_JIFFIES	(10 * HZ)
#define OCTEP_RX_FLOW_TRACK_MAX		24
#define OCTEP_DP_OQ_GRANT		(OCTEP_DP_OQ_DESCS + \
					 OCTEP_DP_OQ_WMARK - \
					 OCTEP_DP_OQ_FETCH)
/* Test-only: raise the front-port MTU ceiling above 1500 (TX slots are sized from it). */
static unsigned int octep_dp_max_mtu = 1500;
module_param_named(dp_max_mtu, octep_dp_max_mtu, uint, 0444);
MODULE_PARM_DESC(dp_max_mtu,
		 "Maximum MTU for octepN front ports, 1500..9000 (load-time, default 1500)");

/* Debug: log every host-side front-port drop with its reason (rate-limited). Runtime-writable. */
static bool octep_dp_debug;
module_param_named(dp_debug, octep_dp_debug, bool, 0644);

/*
 * Load-time debug bitmask (default 0, no behaviour change):
 * 1 log SDP ring state on port open (enable check)
 * 2 on port stop, wait for the rings to drain and log the result
 * 4 log SDP ring state when the stall guard releases a flow (traffic stop)
 * 8 log TX skbs that are scatter-gather (frags, frag list or GSO)
 */
static bool octep_dp_sg;
module_param_named(dp_sg, octep_dp_sg, bool, 0444);
MODULE_PARM_DESC(dp_sg, "advertise scatter-gather and TX checksum offload on octepN (default N)");

static unsigned int octep_dp_dbg;
module_param_named(dp_dbg, octep_dp_dbg, uint, 0444);
MODULE_PARM_DESC(dp_dbg, "debug bitmask: 1=ring state on open, 2=drain on stop, 4=ring state at flow release, 8=log scatter-gather TX skbs");
MODULE_PARM_DESC(dp_debug,
		 "Log each host-side front-port drop with its reason and log every NPU counter that moved (default N)");

#define OCTEP_DP_TXBUF_SIZE		(octep_dp_max_mtu + ETH_HLEN + VLAN_HLEN + \
					 OCTEP_DP_TAG_LEN)
#define OCTEP_DP_TXBUF_STRIDE		ALIGN(OCTEP_DP_TXBUF_SIZE, \
					      OCTEP_DP_BUF_ALIGN)

static bool octep_flow_offload;
module_param_named(flow_offload, octep_flow_offload, bool, 0644);
MODULE_PARM_DESC(flow_offload,
		 "Program nftables flowtable flows into the NPU (needs rpc_allow_write; default off)");

static bool octep_rpc_hi_ring;
module_param_named(rpc_hi_ring, octep_rpc_hi_ring, bool, 0644);
MODULE_PARM_DESC(rpc_hi_ring,
		 "Post flow-programming RPCs on high-priority ring 1 instead of the low ring (read when the RPC channel is configured; default off)");

/* Temporary: on by default while the post-offload stall is investigated. */
static bool octep_ft_debug = true;
module_param_named(ft_debug, octep_ft_debug, bool, 0644);
MODULE_PARM_DESC(ft_debug,
		 "Log per-second NPU state of a freshly offloaded connection (temporary, default on)");

/* Temporary: the next-hop MTU written for offloaded flows (default 1500, as the agent uses). */
static unsigned int octep_ft_nhop_mtu = 1500;
module_param_named(ft_nhop_mtu, octep_ft_nhop_mtu, uint, 0644);
MODULE_PARM_DESC(ft_nhop_mtu,
		 "Next-hop MTU programmed for offloaded flows (temporary, default 1500)");

/* Item 7: a flow offloaded in its first second freezes after ~0.5 MB. Hold new flows on the host path this long first. */
static unsigned int octep_ft_delay_ms = 3500;
module_param_named(ft_delay_ms, octep_ft_delay_ms, uint, 0644);
MODULE_PARM_DESC(ft_delay_ms,
		 "Keep a new flow on the host path this many ms before offloading it (default 3500, 0 = offload as soon as the firmware tracks it)");

/* Spare-slot pairing blackholes in practice (run 14: 3s of zero throughput), so it is opt-in. */
static bool octep_ft_allow_spare;
module_param_named(ft_allow_spare, octep_ft_allow_spare, bool, 0644);
MODULE_PARM_DESC(ft_allow_spare,
		 "Offload with an idle spare slot when the reply direction has no live track (experimental, default off)");

/* Runs 8, 14, 15 showed a burst then nothing returns; that matched the item 7 mflow
 * self-invalidation bug (state freezes, fw_valid drops), not a NAT-specific fault.
 * ft_mflow_timeout + ft_mflow_rearm fixed that root cause (2026-11-16), so default
 * NAT offload on and let the hook test confirm wire content end to end.
 */
static bool octep_ft_offload_nat = true;
module_param_named(ft_offload_nat, octep_ft_offload_nat, bool, 0644);
MODULE_PARM_DESC(ft_offload_nat,
		 "Offload flows whose addresses or ports are NAT-rewritten (default on since the ft_mflow_rearm fix)");

/*
 * The microflow opr_fl.action nibble's FWD value was never confirmed against vendor source;
 * only action=0 (DROP) is known for certain. Runtime-tunable so alternate guesses (2, 3) can be
 * tried live against a reproducible stall without a rebuild each time (run 22+ all used action=1).
 */
static int octep_ft_mflow_action = 1;
module_param_named(ft_mflow_action, octep_ft_mflow_action, int, 0644);
MODULE_PARM_DESC(ft_mflow_action,
		 "Microflow opr_fl.action value used for offloaded flows (unverified guess, default 1)");

/*
 * mflow_timeout is documented (vendor comment) as SECONDS of idle time before the fast path
 * expires a microflow, not ticks/ms/jiffies. OCTEP_FT_TIMEOUT (244141) was ~2.8 days' worth of
 * seconds, wildly out of the platform's honoured range -- live readback (LO_MFLOW_READ) showed
 * firmware silently invalidating (state 2->0, fw_valid 1->0) within ~1-2s of creation, consistent
 * with the out-of-range value being clamped/rejected. 60s matches the reference project's own
 * confirmed-working measurement (flows expired 53-63s after 60 was sent). Runtime-tunable so this
 * can be re-measured without a rebuild.
 */
static int octep_ft_mflow_timeout = 60;
module_param_named(ft_mflow_timeout, octep_ft_mflow_timeout, int, 0644);
MODULE_PARM_DESC(ft_mflow_timeout,
		 "Microflow idle timeout in seconds sent to firmware (default 60, was hardcoded 244141)");

/*
 * Workaround: even with a sane ft_mflow_timeout, live-readback (LO_MFLOW_READ) showed a
 * microflow's fw_valid/state silently collapse (2->0) after ~60-90s *despite* continuous
 * active iperf traffic through it -- the reference driver's own keepalive (octep_flow_keepalive)
 * only reads a microflow's timestamp to learn whether packets flowed; it never re-arms the
 * firmware's timer, on the assumption a genuinely busy flow never needs it. That assumption does
 * not hold here, so re-issue MFLOW_PROGRAM for every live connection's both directions well
 * inside the timeout window, coding around the firmware-side bug rather than relying on an
 * automatic in-firmware refresh that isn't happening for us.
 */
static int octep_ft_mflow_rearm = 45;
module_param_named(ft_mflow_rearm, octep_ft_mflow_rearm, int, 0644);
MODULE_PARM_DESC(ft_mflow_rearm,
		 "Seconds between proactive MFLOW_PROGRAM re-arms per connection (0 disables, default 45, must stay below ft_mflow_timeout)");

/*
 * Connection verdict (flags bits 22:21): 0 send to IPS, 1 drop, 2 cut-through forward, per the
 * conn printer as documented by the os-xgs-npu BSD driver. This driver used to send 1,
 * which that source names DROP; the BSD driver makes plain connections with 2. Runtime-tunable.
 */
static unsigned int octep_ft_verdict = 2;
module_param_named(ft_verdict, octep_ft_verdict, uint, 0644);
MODULE_PARM_DESC(ft_verdict,
		 "Connection verdict sent on flow create: 0 IPS, 1 drop, 2 cut-through forward (default 2, as the BSD driver)");

/*
 * Make-before-break cut-in: flow-create programs the microflows with ft_cutin_action while the
 * host keeps forwarding, and ft_cutin_ms later (next 1 s work tick) MFLOW_PROGRAM flips them to
 * ft_mflow_action. 0 disables the staging (create forwards at once). The staging action's
 * meaning is unconfirmed, so it is tunable; 0 is DROP and would blackhole the flow.
 */
static unsigned int octep_ft_cutin;
module_param_named(ft_cutin, octep_ft_cutin, uint, 0644);
MODULE_PARM_DESC(ft_cutin,
		 "Cut-in mode: 0 = create straight to forward (default; the staged mode stalled live flows, see testlogs/offload-runs.tsv), 1 = staged create, checked flip to forward (also off when ft_cutin_ms is 0)");
static unsigned int octep_ft_cutin_ms = 500;
module_param_named(ft_cutin_ms, octep_ft_cutin_ms, uint, 0644);
MODULE_PARM_DESC(ft_cutin_ms,
		 "Milliseconds between staged flow-create and the flip to forward (0 = no staging, default 500)");
static unsigned int octep_ft_cutin_inflight = 65536;
module_param_named(ft_cutin_inflight, octep_ft_cutin_inflight, uint, 0644);
MODULE_PARM_DESC(ft_cutin_inflight,
		 "Largest unacked byte count at which the cut-in flip may happen (default 65536)");
static unsigned int octep_ft_cutin_wait_ms = 3000;
module_param_named(ft_cutin_wait_ms, octep_ft_cutin_wait_ms, uint, 0644);
MODULE_PARM_DESC(ft_cutin_wait_ms,
		 "How long the flip waits for the flow checks to pass before flipping anyway (default 3000)");
static int octep_ft_cutin_action = 2;
module_param_named(ft_cutin_action, octep_ft_cutin_action, int, 0644);
MODULE_PARM_DESC(ft_cutin_action,
		 "Microflow action used at flow-create while staging (default 2, unconfirmed; 0 is DROP)");

static inline u32 octep_ft_first_action(void)
{
	return octep_ft_cutin && octep_ft_cutin_ms ? (u32)octep_ft_cutin_action : (u32)octep_ft_mflow_action;
}

/* Runtime-tunable (0644): a firmware-active TCP flow whose reply microflow timestamp is frozen this long is released. */
static unsigned int octep_ft_reply_frozen_s = 2;
module_param_named(ft_reply_frozen, octep_ft_reply_frozen_s, uint, 0644);
MODULE_PARM_DESC(ft_reply_frozen,
		 "Seconds a firmware-active TCP flow's reply microflow may stay unhit before the flow is released to the slow path (default 2)");

/* Experiment: the reply direction of an SNAT flow needs a destination rewrite, so try setting both NAT flag bits. */
static bool octep_ft_nat_both;
module_param_named(ft_nat_both, octep_ft_nat_both, bool, 0644);
MODULE_PARM_DESC(ft_nat_both,
		 "Set both SNAT and DNAT flag bits when a flow is NAT-rewritten (experimental, default off)");

/* Experiment: zero the four NAT-block ports, as the userspace agent's SNAT mode does. */
static bool octep_ft_nat_ports0;
module_param_named(ft_nat_ports0, octep_ft_nat_ports0, bool, 0644);
MODULE_PARM_DESC(ft_nat_ports0,
		 "Write zero (wildcard) ports in the flow-create NAT block (experimental, default off)");

/* Experiment: L3/route revision written into each microflow (refreshed from the global route number). */
static unsigned int octep_ft_l3_rev;
module_param_named(ft_l3_rev, octep_ft_l3_rev, uint, 0644);
MODULE_PARM_DESC(ft_l3_rev,
		 "L3 revision written into the flow-create microflows (experimental, default 0)");

/* The flow-create record carries 60 bytes at offset 24 that match struct ip_ct_tcp (TCP window and state); they were always zero. */
static bool octep_ft_tcp_state;
module_param_named(ft_tcp_state, octep_ft_tcp_state, bool, 0644);
MODULE_PARM_DESC(ft_tcp_state,
		 "Copy the conntrack TCP state (struct ip_ct_tcp) into TCP flow-create records (experimental, default off)");

/* A young offloaded TCP conn whose reply microflow timestamp is frozen this long (ms) is returned to the host path; 0 = off. */
static unsigned int octep_ft_guard_ms = 50;
module_param_named(ft_guard_ms, octep_ft_guard_ms, uint, 0644);
MODULE_PARM_DESC(ft_guard_ms,
		 "Fast release of an offloaded TCP conn whose reply microflow is frozen this many ms (0 disables, default 50)");

/* Window headroom added to the TCP-state block: 0 = raw conntrack snapshot, >0 = fixed MiB, -1 = legacy max(16 MiB, 2 x window). */
static int octep_ft_tcp_room;
module_param_named(ft_tcp_room, octep_ft_tcp_room, int, 0644);
MODULE_PARM_DESC(ft_tcp_room,
		 "TCP-state window headroom in MiB (0 = raw conntrack snapshot, default; -1 = legacy 16 MiB+ headroom)");

/* Probe: one extra RPC opcode admitted past the allow-list for rpc_raw_write (needs rpc_allow_write; -1 = off). */
static int octep_rpc_raw_cmd = -1;
module_param_named(rpc_raw_cmd, octep_rpc_raw_cmd, int, 0644);
MODULE_PARM_DESC(rpc_raw_cmd,
		 "Opcode (0-35) that rpc_raw_write may send; -1 disables (experimental, default -1)");

/* BSD os-xgs-npu sends next hops with the L3 flag set (byte 26) and pport_tag 0; the Linux builder never did. */
static bool octep_ft_nhop_l3 = true;
module_param_named(ft_nhop_l3, octep_ft_nhop_l3, bool, 0644);
MODULE_PARM_DESC(ft_nhop_l3,
		 "Program next hops with the L3 flag and a zero pport tag, as the FreeBSD driver does (default Y)");

/*
 * Bridge-control nibble (operation bits 24-27): what the fast path rewrites. The FreeBSD driver
 * (os-xgs-npu, npuflow.c) sets 0xe on every routed microflow; 0 means "rewrite nothing, a bridge
 * carries it" and left NAT'd TCP stalling after the first burst.
 */
static unsigned int octep_ft_brctl = 0xe;
module_param_named(ft_brctl, octep_ft_brctl, uint, 0644);
MODULE_PARM_DESC(ft_brctl,
		 "Microflow bridge-control nibble, 0xe = routed (default), 0 = nothing rewritten");

/* Experiment: extra bits ORed into each microflow operation word. */
static unsigned int octep_ft_mflow_extra;
module_param_named(ft_mflow_extra, octep_ft_mflow_extra, uint, 0644);
MODULE_PARM_DESC(ft_mflow_extra,
		 "Extra bits ORed into the microflow operation word (experimental, default 0)");

/* Experiment: extra connection-flag bits (e.g. a TCP/UDP checksum-update bit) ORed into flow-create. */
static unsigned int octep_ft_flags_extra;
module_param_named(ft_flags_extra, octep_ft_flags_extra, uint, 0644);
MODULE_PARM_DESC(ft_flags_extra,
		 "Extra bits ORed into the flow-create connection flags (experimental, default 0)");

static unsigned int octep_ft_session_rev;
module_param_named(ft_session_rev, octep_ft_session_rev, uint, 0644);
MODULE_PARM_DESC(ft_session_rev,
		 "16-bit session revision written into flow-create records (default 0)");

static unsigned int octep_ft_live_uid;
module_param_named(ft_live_uid, octep_ft_live_uid, uint, 0644);
MODULE_PARM_DESC(ft_live_uid,
		 "16-bit live user id written into flow-create records (default 0)");

/*
 * Offload parity features. Every one is off by default; ft_parity switches on the whole group
 * except ft_fw_cfg_extra, which is a value and stays explicit.
 */
static u16 octep_ft_fw_cfg_extra;
module_param_named(ft_fw_cfg_extra, octep_ft_fw_cfg_extra, ushort, 0644);
MODULE_PARM_DESC(ft_fw_cfg_extra,
		 "Extra firmware-config bits ORed in when offload is turned on (default 0; 0x2C adds the bits of the reference configuration, total 0x2F). Re-write 'on' to the offload attribute after changing it");

static int octep_ft_trig_param_set(const char *val, const struct kernel_param *kp);
static const struct kernel_param_ops octep_ft_trig_ops = {
	.set = octep_ft_trig_param_set,
	.get = param_get_bool,
};

static bool octep_ft_parity;
module_param_cb(ft_parity, &octep_ft_trig_ops, &octep_ft_parity, 0644);
MODULE_PARM_DESC(ft_parity,
		 "Master switch: enables ft_pair_gate, ft_ct_trigger, ft_flow_state, ft_mflow_parity, ft_ct_refresh (120 s), ft_bulk_reclaim and ft_bridge (default N)");

static bool octep_ft_ct_trigger;
module_param_cb(ft_ct_trigger, &octep_ft_trig_ops, &octep_ft_ct_trigger, 0644);
MODULE_PARM_DESC(ft_ct_trigger,
		 "Queue a forwarded IPv4 TCP/UDP conntrack for offload as soon as it is established (TCP) or seen both ways (UDP), without the ft_delay_ms wait; needs flow_offload and the RPC write gate (default N)");

static bool octep_ft_pair_gate;
module_param_named(ft_pair_gate, octep_ft_pair_gate, bool, 0644);
MODULE_PARM_DESC(ft_pair_gate,
		 "Create a flow only when both directions have a live valid firmware slot id; never borrow a spare slot, count and log waits (default N)");

static unsigned int octep_ft_diag_frames;
module_param_named(ft_diag_frames, octep_ft_diag_frames, uint, 0644);
MODULE_PARM_DESC(ft_diag_frames,
		 "Record flow_valid/md_valid/id/rev/tag for the first N frames per direction of each new IPv4 flow in the ft_diag attribute (0 = off, or 8 when ft_pair_gate is set)");

static bool octep_ft_flow_state;
module_param_named(ft_flow_state, octep_ft_flow_state, bool, 0644);
MODULE_PARM_DESC(ft_flow_state,
		 "Gate creation on a non-zero firmware state revision and log per-flow direction state (default N)");

static bool octep_ft_mflow_parity;
module_param_named(ft_mflow_parity, octep_ft_mflow_parity, bool, 0644);
MODULE_PARM_DESC(ft_mflow_parity,
		 "Use a 30 s microflow timeout and a 25 s rearm instead of ft_mflow_timeout/ft_mflow_rearm (default N)");

static unsigned int octep_ft_ct_refresh;
module_param_named(ft_ct_refresh, octep_ft_ct_refresh, uint, 0644);
MODULE_PARM_DESC(ft_ct_refresh,
		 "Seconds: while the NPU counters of an offloaded flow advance, keep its conntrack entry from expiring sooner than this (0 = off, 120 with ft_parity)");

static bool octep_ft_bulk_reclaim;
module_param_named(ft_bulk_reclaim, octep_ft_bulk_reclaim, bool, 0644);
MODULE_PARM_DESC(ft_bulk_reclaim,
		 "Reclaim every offloaded connection when offload is turned off (default N)");

static bool octep_ft_bridge;
module_param_named(ft_bridge, octep_ft_bridge, bool, 0644);
MODULE_PARM_DESC(ft_bridge,
		 "Mark conntrack-triggered flows whose two ports share a bridge as bridged: no TTL or MAC rewrite (default N)");

static unsigned int octep_dp_poll_us = 200;
module_param_named(dp_poll_us, octep_dp_poll_us, uint, 0644);
MODULE_PARM_DESC(dp_poll_us,
		 "Data-path RX/TX completion by a timer-driven NAPI poll every N microseconds (50..100000) instead of the 2 ms delayed work; latched at sdp_start (default 200, 0 = delayed work)");

#define OCTEP_DP_NAPI_WEIGHT	96
#define OCTEP_FT_FEAT(p)	(READ_ONCE(octep_ft_parity) || READ_ONCE(p))

static unsigned int octep_sriov_vfs;
module_param_named(sriov_vfs, octep_sriov_vfs, uint, 0444);
MODULE_PARM_DESC(sriov_vfs,
		 "Number of OCTEON TX VFs to create before SDP bring-up (0 or 4)");
#define OCTEP_DP_PORT_MAX		32
#define OCTEP_DP_P_KIND		40
#define OCTEP_DP_OP_PACKET		0x1220
#define OCTEP_VF_MBOX_POLL_MS		1
#define OCTEP_VF_MBOX_VERSION_V1	1

enum octep_vf_mbox_opcode {
	OCTEP_VF_MBOX_CMD_VERSION,
	OCTEP_VF_MBOX_CMD_SET_MTU,
	OCTEP_VF_MBOX_CMD_SET_MAC_ADDR,
	OCTEP_VF_MBOX_CMD_GET_MAC_ADDR,
	OCTEP_VF_MBOX_CMD_GET_LINK_INFO,
	OCTEP_VF_MBOX_CMD_GET_STATS,
	OCTEP_VF_MBOX_CMD_SET_RX_STATE,
	OCTEP_VF_MBOX_CMD_SET_LINK_STATUS,
	OCTEP_VF_MBOX_CMD_GET_LINK_STATUS,
	OCTEP_VF_MBOX_CMD_GET_MTU,
	OCTEP_VF_MBOX_CMD_DEV_REMOVE,
};

enum octep_vf_mbox_type {
	OCTEP_VF_MBOX_TYPE_CMD,
	OCTEP_VF_MBOX_TYPE_RSP_ACK,
	OCTEP_VF_MBOX_TYPE_RSP_NACK,
};

union octep_vf_mbox_word {
	u64 u64;
	struct {
		u64 opcode:8;
		u64 type:2;
		u64 rsvd:6;
		u64 data:48;
	} s;
	struct {
		u64 opcode:8;
		u64 type:2;
		u64 rsvd:6;
		u64 version:48;
	} s_version;
	struct {
		u64 opcode:8;
		u64 type:2;
		u64 rsvd:6;
		u8 mac_addr[ETH_ALEN];
	} s_mac;
	struct {
		u64 opcode:8;
		u64 type:2;
		u64 rsvd:6;
		u64 mtu:48;
	} s_mtu;
} __packed;
#define OCTEP_DP_CKSUM_OFFSET		(OCTEP_DP_TAG_LEN + ETH_HLEN + 1)

#define OCTEP_MGMT_DEV_TYPE_OFF		8
#define OCTEP_MGMT_HOST_STATUS_OFF	128
#define OCTEP_MGMT_HOST_INTR_OFF	136
#define OCTEP_MGMT_HOST_MBOX_OFF	152
#define OCTEP_MGMT_TARGET_STATUS_OFF	256
#define OCTEP_MGMT_TX_DESCQ_OFF		1024
#define OCTEP_MGMT_RX_DESCQ_OFF		65536
#define OCTEP_MGMT_HOST_DOWN		0
#define OCTEP_MGMT_HOST_READY		1
#define OCTEP_MGMT_HOST_RUNNING		2
#define OCTEP_MGMT_HOST_GOING_DOWN	3
#define OCTEP_MGMT_TARGET_READY		1
#define OCTEP_MGMT_TARGET_RUNNING	2
#define OCTEP_MGMT_TARGET_FATAL		4
#define OCTEP_MGMT_STATUS_CHANGE		1
#define OCTEP_MGMT_DEV_TYPE		1
#define OCTEP_MGMT_RING_ENTRIES		256
#define OCTEP_MGMT_RING_MASK		(OCTEP_MGMT_RING_ENTRIES - 1)
#define OCTEP_MGMT_BUF_SIZE		2048
#define OCTEP_MGMT_MTU			1500
#define OCTEP_MGMT_DESC_HEADER_SIZE	32
#define OCTEP_MGMT_DESC_SIZE		16
#define OCTEP_MGMT_SHADOW_SIZE		PAGE_SIZE
#define OCTEP_MGMT_POLL_MS		20
#define OCTEP_MGMT_STATUS_TICKS		50
#define OCTEP_MGMT_RX_BUDGET		64
#define OCTEP_MGMT_MIN_FRAME		60
#define OCTEP_MGMT_DESC_MK(len)		\
	((((u64)(len) & 0xffff) << 48) | (((u64)(len) & 0xffff) << 30))

#define OCTEP_SDP_HOST_LOADED		0xdeadbeefULL
#define OCTEP_SDP_GET_HOST_INFO		0xbeefdeedULL
#define OCTEP_SDP_HOST_INFO_RECEIVED	0x00deaddeULL
#define OCTEP_SDP_HANDSHAKE_COMPLETED	0xdeeddeedULL
#define OCTEP_SDP_APP_MODE_NIC		2

#define OCTEP_RPC_STATE_CFG_MAGIC	0xd7d3ab00U
#define OCTEP_RPC_STATE_SIZE		232
#define OCTEP_RPC_STATE_CFG		0
#define OCTEP_RPC_STATE_RING_LO		72
#define OCTEP_RPC_STATE_RINGS		104
#define OCTEP_RPC_RING_SIZE		32
#define OCTEP_RPC_RING_POSTED		0
#define OCTEP_RPC_RING_DONE		8
#define OCTEP_RPC_RING_OFFSET		16
#define OCTEP_RPC_RING_DESC_OFF		20
#define OCTEP_RPC_RING_DESC_CNT		24
#define OCTEP_RPC_RING_CFG		28
#define OCTEP_RPC_RCFG(num, fidx, dbell, shared)	\
	(((num) & 0xff) | (((fidx) & 0xff) << 8) |	\
	 (((dbell) & 0xff) << 16) | (((shared) & 0xff) << 24))
#define OCTEP_RPC_BAR_DESC_SIZE		16
#define OCTEP_RPC_DESC_NO_AGG_DMA	2
#define OCTEP_RPC_BUF_DESC_SIZE		8
#define OCTEP_RPC_DATA_MAX_SIZE		4096
#define OCTEP_RPC_DESC_COUNT		256
#define OCTEP_RPC_DESC_OFFSET		4328
#define OCTEP_RPC_CFG_WAIT_MS		3000
#define OCTEP_RPC_CMD_WAIT_MS		2000
#define OCTEP_RPC_CMD_FW_STATE_REV_SET	0
#define OCTEP_RPC_CMD_FW_CFG_PARAMS_SET	2
#define OCTEP_RPC_CMD_LIF_ADD_UPDATE	3
#define OCTEP_RPC_CMD_PPORT_UPDATE	5
#define OCTEP_RPC_CMD_NHOP_PROGRAM	6
#define OCTEP_RPC_CMD_MFLOW_PROGRAM	8
#define OCTEP_RPC_CMD_FLOW_CREATE_FP	10
#define OCTEP_RPC_CMD_CONN_RECLAIM_FP	16
#define OCTEP_RPC_CMD_PLATFORM_READ	36
#define OCTEP_RPC_CMD_LO_LIF_READ	37
#define OCTEP_RPC_CMD_LO_CONN_READ	38
#define OCTEP_RPC_CMD_LO_MFLOW_READ	40
#define OCTEP_RPC_CMD_LO_WORKER_SYS_CNT_READ	44
#define OCTEP_RPC_CMD_SHIFT_MAX		4
#define OCTEP_RPC_PLATFORM_CONN_OFF	204
#define OCTEP_RPC_PLATFORM_NHOP_OFF	208
#define OCTEP_RPC_NHOP_REQ_LEN		32
#define OCTEP_RPC_MFLOW_REQ_LEN		32
#define OCTEP_RPC_FLOW_REQ_LEN		180
#define OCTEP_RPC_CONN_RECLAIM_REQ_LEN	8
#define OCTEP_RPC_CONN_RECLAIM_REPLY_LEN	64
#define OCTEP_RPC_TBL_REQ_LEN		12
#define OCTEP_RPC_SYS_COUNTER_COUNT	128
#define OCTEP_RPC_MFLOW_READ_REPLY_LEN	116
#define OCTEP_RPC_CONN_READ_REPLY_MAX	256
#define OCTEP_RPC_TABLE_FLAG_READ_ALL	0x0002
#define OCTEP_RPC_LIF_READ_REPLY_MIN	12
#define OCTEP_RPC_LIF_READ_REPLY_MAX	14
#define OCTEP_RPC_CONN_STATE_VALID	1
#define OCTEP_RPC_CONN_STATE_RECLAIM_PENDING	2
#define OCTEP_RPC_CONN_STATE_RECLAIMED	3
#define OCTEP_RPC_FLOW_VALID_ORIG	0x1
#define OCTEP_RPC_FLOW_VALID_REPLY	0x2
#define OCTEP_RPC_FLOW_OFF_VALID	112
#define OCTEP_RPC_FLOW_OFF_MFLOW_O	116
#define OCTEP_RPC_FLOW_OFF_MFLOW_R	148
#define OCTEP_RPC_MFLOW_STATE_ACTIVE	2
#define OCTEP_RPC_MFLOW_ACTION_FWD	1
#define OCTEP_RPC_MFLOW_ACTION_IPS	2
#define OCTEP_FW_CFG_OFFLOAD		0x0001
#define OCTEP_FW_CFG_TCP_SEQ_CHK	0x0002
#define OCTEP_RPC_LIF_M_ALL		0x00ff
#define OCTEP_RPC_LIF_M_MANAGED		0x001f
#define OCTEP_RPC_LIF_FP_PRIV_MASK_DF	0x01
#define OCTEP_RPC_LIF_MTU		1500
#define OCTEP_RPC_LIF_FWD_L3		2

#define OCTEP_NWA_COOKIE		0x00
#define OCTEP_NWA_COOKIE_VALUE		0xcafebabeU
#define OCTEP_NWA_BODY_OFF		0x04
#define OCTEP_NWA_BODY_EXPECTED		0x34
#define OCTEP_NWA_MAX_REQ		0x08
#define OCTEP_NWA_TURN			0x18
#define OCTEP_NWA_TURN_REQUEST		1
#define OCTEP_NWA_TURN_ACK		2
#define OCTEP_NWA_REQ_LEN		0x1c
#define OCTEP_NWA_STATUS		0x20
#define OCTEP_NWA_STATUS_IDLE		0
#define OCTEP_NWA_STATUS_REPLY		1
#define OCTEP_NWA_REPLY_LEN		0x24
#define OCTEP_NWA_REQ_SIZE		0x20
#define OCTEP_NWA_MAX_WORDS		512
#define OCTEP_NWA_OP_DISCOVER		1
#define OCTEP_NWA_REPLY_MARKER		0x14
#define OCTEP_NWA_REPLY_HEADER_SIZE	8
#define OCTEP_NWA_IDLE_TRIES		100
#define OCTEP_NWA_REPLY_TRIES		300
#define OCTEP_NWA_OP_SET		3
#define OCTEP_NWA_OP_GET		4
#define OCTEP_NWA_SUB_STATE		0
#define OCTEP_NWA_SUB_MAC		3
#define OCTEP_NWA_SUB_ALLMULTI		0x46
#define OCTEP_NWA_ALLMULTI_OFF		0
#define OCTEP_NWA_ALLMULTI_ON		1
#define OCTEP_NWA_SUB_STATS		14
#define OCTEP_NWA_STATS_COUNT		32
#define OCTEP_NWA_STATS_WORDS		(OCTEP_NWA_STATS_COUNT * 2)

static const char * const octep_nwa_stat_names[OCTEP_NWA_STATS_COUNT] = {
	"good_octets_received",
	"bad_octets_received",
	"mac_trans_error",
	"broadcast_frames_received",
	"multicast_frames_received",
	"frames_64_octets",
	"frames_65_to_127_octets",
	"frames_128_to_255_octets",
	"frames_256_to_511_octets",
	"frames_512_to_1023_octets",
	"frames_1024_to_max_octets",
	"excessive_collision",
	"multicast_frames_sent",
	"broadcast_frames_sent",
	"fc_sent",
	"fc_received",
	"rx_drop",
	"undersize",
	"fragments",
	"oversize",
	"jabber",
	"rx_error_frame_received",
	"bad_crc",
	"collisions",
	"late_collision",
	"unicast_frames_received",
	"unicast_frames_sent",
	"sent_multiple",
	"sent_deferred",
	"frames_1024_to_1518_octets",
	"frames_1519_to_max_octets",
	"good_octets_sent",
};

#define OCTEP_FACILITY_COUNT		5
#define OCTEP_BARMAP_VERSION		0x00000002U
#define OCTEP_BARMAP_VERSION_OFF	0
#define OCTEP_BARMAP_FACILITY_OFF	4
#define OCTEP_FACILITY_ENTRY_SIZE	16
#define OCTEP_BARMAP_GICD_OFF		(OCTEP_BARMAP_FACILITY_OFF + \
					 OCTEP_FACILITY_COUNT * \
					 OCTEP_FACILITY_ENTRY_SIZE)
#define OCTEP_BARMAP_PEM_OFF		(OCTEP_BARMAP_GICD_OFF + 4)
#define OCTEP_BARMAP_SIZE		(OCTEP_BARMAP_PEM_OFF + 4)

enum octep_facility_id {
	OCTEP_FCLT_CONTROL,
	OCTEP_FCLT_MGMT,
	OCTEP_FCLT_NW_AGENT,
	OCTEP_FCLT_RPC,
	OCTEP_FCLT_GIU,
};

static const char * const octep_facility_names[OCTEP_FACILITY_COUNT] = {
	[OCTEP_FCLT_CONTROL] = "control",
	[OCTEP_FCLT_MGMT] = "mgmt_netdev",
	[OCTEP_FCLT_NW_AGENT] = "nw_agent",
	[OCTEP_FCLT_RPC] = "rpc",
	[OCTEP_FCLT_GIU] = "giu",
};

struct octep_facility {
	u32 offset;
	u32 size;
	u32 dbell_start;
	u32 dbell_count;
};

struct octep_sdp_rinfo {
	u64 value;
	u32 start_ring;
	u32 pf_rings;
	u32 rings_per_vf;
	u32 num_vfs;
	u32 bar0_rings;
};

struct octep_dma_mem {
	void *vaddr;
	dma_addr_t dma_addr;
	size_t size;
};

struct octep_dp_ring {
	struct octep_dma_mem instr;
	struct octep_dma_mem txbuf;
	struct octep_dma_mem slist;
	struct octep_dma_mem bufs;
	struct octep_dma_mem info;
	u32 ring;
	u32 oq_rd;
	u32 oq_credit_carry;
	bool in_configured;
	bool out_configured;
};

struct octep;
struct octep_dp_port {
	struct net_device *netdev;
	struct rtnl_link_stats64 stats;
	u16 tag;
	u8 iface;
};

struct octep_netdev_priv {
	struct octep *octep;
	struct octep_dp_port *port;
};

/* BEGIN flowbuild */
/*
 * Offline wire layouts derived from flow-rpc-test.py. Opaque ranges and
 * lifecycle semantics remain unverified; these payloads are not submitted.
 */
struct octep_rpc_nhop_payload {
	__le32 index;
	u8 resolved;
	u8 revision;
	u8 opaque_6_7[2];
	u8 destination_mac[ETH_ALEN];
	u8 source_mac[ETH_ALEN];
	__be16 ethertype;
	__le16 vlan;
	__le16 tag;
	u8 flags;
	u8 interface;
	__le16 mtu;
	u8 opaque_30_31[2];
} __packed;

struct octep_rpc_mflow_payload {
	__le32 identity_revision_valid;
	__le32 operation;
	__le32 behavior;
	__le32 connection;
	__le32 firmware_connection_revision;
	__le32 next_hop_revision;
	__le16 security_association_revision;
	u8 opaque_26_27[2];
	__le32 timeout;
} __packed;

struct octep_rpc_flow_create_payload {
	__le32 connection;
	__le32 connection_flags;
	__le16 live_user;
	__le16 session_revision;
	__le32 session;
	u8 opaque_16_23[8];
	u8 tcp_state[60];
	u8 nat[24];
	u8 opaque_108_111[4];
	__le32 direction_valid_mask;
	struct octep_rpc_mflow_payload original;
	struct octep_rpc_mflow_payload reply;
} __packed;

static_assert(sizeof(struct octep_rpc_nhop_payload) == OCTEP_RPC_NHOP_REQ_LEN);
static_assert(sizeof(struct octep_rpc_mflow_payload) == OCTEP_RPC_MFLOW_REQ_LEN);
static_assert(sizeof(struct octep_rpc_flow_create_payload) ==
	      OCTEP_RPC_FLOW_REQ_LEN);

#define OCTEP_RPC_NHOP_FLAG_L3		0x01
#define OCTEP_RPC_FLOW_ACTION_FWD	1
#define OCTEP_RPC_FLOW_STATE_ACTIVE	2
#define OCTEP_RPC_FLOW_CONN_VALID	1
#define OCTEP_RPC_FLOW_VALID_BOTH	3
#define OCTEP_RPC_FLOW_VERDICT_BIT	21
#define OCTEP_RPC_FLOW_DNAT_BIT		19
#define OCTEP_RPC_FLOW_SNAT_BIT		20
#define OCTEP_RPC_FLOW_NAT_OFFSET	84

/* NAT block as the firmware wants it: addresses, then destination before source ports. */
struct octep_ft_nat {
	__be32 orig_src, orig_dst, nat_src, nat_dst;
	__be16 orig_dst_port, orig_src_port, nat_dst_port, nat_src_port;
	bool snat, dnat;
};

/* Same bytes as scripts/octep/flow-build.py nhop(). */
static inline void octep_ft_fill_nhop(struct octep_rpc_nhop_payload *p,
				      u32 index, u8 revision, const u8 *dst,
				      const u8 *src, u8 iface, u16 tag, u16 mtu)
{
	memset(p, 0, sizeof(*p));
	p->index = cpu_to_le32(index);
	p->resolved = 1;
	p->revision = revision;
	memcpy(p->destination_mac, dst, ETH_ALEN);
	memcpy(p->source_mac, src, ETH_ALEN);
	p->ethertype = htons(ETH_P_IP);
	p->tag = cpu_to_le16(octep_ft_nhop_l3 ? 0 : tag);
	p->flags = octep_ft_nhop_l3 ? OCTEP_RPC_NHOP_FLAG_L3 : 0;
	p->interface = iface;
	p->mtu = cpu_to_le16(mtu);
}

/* Same bytes as flow-build.py mflow(); id and revision come from a live firmware candidate. */
static inline u32 octep_ft_eff_timeout(void)
{
	return READ_ONCE(octep_ft_parity) || READ_ONCE(octep_ft_mflow_parity) ?
	       30 : (u32)octep_ft_mflow_timeout;
}

static inline u32 octep_ft_eff_brctl(bool bridged)
{
	return bridged && OCTEP_FT_FEAT(octep_ft_bridge) ? 0 : octep_ft_brctl;
}

static inline void octep_ft_fill_mflow(struct octep_rpc_mflow_payload *p,
				       u32 id, u32 id_rev, u32 direction, u32 action,
				       u32 conn, u32 conn_rev, u32 fw_rev,
				       u32 l3_rev, u32 nhop, u32 nhop_rev,
				       u32 timeout, u32 brctl)
{
	memset(p, 0, sizeof(*p));
	p->identity_revision_valid = cpu_to_le32(id | id_rev << 25 | BIT(31));
	p->operation = cpu_to_le32(action << 16 |
				   direction << 23 |
				   (brctl & 0xf) << 24 |
				   OCTEP_RPC_FLOW_STATE_ACTIVE << 28 |
				   octep_ft_mflow_extra);
	p->behavior = cpu_to_le32(l3_rev);
	p->connection = cpu_to_le32(conn);
	p->firmware_connection_revision = cpu_to_le32(conn_rev << 16 | fw_rev);
	p->next_hop_revision = cpu_to_le32(nhop | nhop_rev << 24);
	p->timeout = cpu_to_le32(timeout);
}

/* Same bytes as flow-build.py flow_create() for a two-direction flow. */
static inline void octep_ft_fill_flow(struct octep_rpc_flow_create_payload *p,
				      u32 conn, u32 conn_rev,
				      const struct octep_rpc_mflow_payload *orig,
				      const struct octep_rpc_mflow_payload *reply,
				      const struct octep_ft_nat *nat)
{
	u32 flags = conn_rev | (octep_ft_verdict & 3) << OCTEP_RPC_FLOW_VERDICT_BIT |
		    OCTEP_RPC_FLOW_CONN_VALID << 30;

	memset(p, 0, sizeof(*p));
	p->connection = cpu_to_le32(conn);
	if (octep_ft_nhop_l3)
		p->session = cpu_to_le32(conn);
	p->session_revision = cpu_to_le16((u16)READ_ONCE(octep_ft_session_rev));
	p->live_user = cpu_to_le16((u16)READ_ONCE(octep_ft_live_uid));
	if (nat) {
		u8 *block = p->nat;
		bool both = octep_ft_nat_both && (nat->snat || nat->dnat);

		memcpy(block, &nat->orig_src, 4);
		memcpy(block + 4, &nat->orig_dst, 4);
		memcpy(block + 8, &nat->nat_src, 4);
		memcpy(block + 12, &nat->nat_dst, 4);
		if (!octep_ft_nat_ports0) {
			memcpy(block + 16, &nat->orig_dst_port, 2);
			memcpy(block + 18, &nat->orig_src_port, 2);
			memcpy(block + 20, &nat->nat_dst_port, 2);
			memcpy(block + 22, &nat->nat_src_port, 2);
		}
		flags |= (u32)(nat->snat || both) << OCTEP_RPC_FLOW_SNAT_BIT |
			 (u32)(nat->dnat || both) << OCTEP_RPC_FLOW_DNAT_BIT;
	}
	p->connection_flags = cpu_to_le32(flags | octep_ft_flags_extra);
	p->direction_valid_mask = cpu_to_le32(OCTEP_RPC_FLOW_VALID_BOTH);
	p->original = *orig;
	p->reply = *reply;
}

/* Same bytes as flow-build.py mflow_clear(): state 0 invalidates a slot after reclaim. */
static inline void octep_ft_fill_mflow_clear(struct octep_rpc_mflow_payload *p,
					     u32 id, u32 id_rev, u32 conn,
					     u32 conn_rev, u32 fw_rev,
					     u32 l3_rev, u32 nhop)
{
	memset(p, 0, sizeof(*p));
	p->identity_revision_valid = cpu_to_le32(id | id_rev << 25 | BIT(31));
	p->behavior = cpu_to_le32(l3_rev);
	p->connection = cpu_to_le32(conn);
	p->firmware_connection_revision = cpu_to_le32(conn_rev << 16 | fw_rev);
	p->next_hop_revision = cpu_to_le32(nhop);
}
/* END flowbuild */

/* Flowtable hardware-offload state; every field is protected by octep->lock. */
#define OCTEP_FT_MAX		32
#define OCTEP_FT_CONNS		8
#define OCTEP_FT_CONN_BASE	10000
#define OCTEP_FT_NHOP_BASE	100
/* NHOP iface is the NWA port index, LIF + 2 (as offload-agent.py); a wrong value stalls that port's wire RX */
#define OCTEP_FT_NWA_IFACE_BASE	2
#define OCTEP_FT_MAX_AGE_MS	4000
/* Frames a firmware track needs before a flow is latched; the first packets already carry the ids, so default to 1 (flows are created on the first packet). */
static unsigned int octep_ft_min_frames = 1;
module_param_named(ft_min_frames, octep_ft_min_frames, uint, 0644);
MODULE_PARM_DESC(ft_min_frames,
		 "Frames a firmware flow track must have seen before the flow is offloaded (default 1, previously 100)");
#define OCTEP_FT_MIN_FRAMES	READ_ONCE(octep_ft_min_frames)
/* A new flow is matched against the firmware tracks every few ms for this long instead of waiting for the 1s scan. */
#define OCTEP_FT_FAST_POLL_MS	5
#define OCTEP_FT_FAST_WINDOW	(2 * HZ)
#define OCTEP_FT_TIMEOUT	244141
#define OCTEP_FT_BLACKHOLE_JIFFIES	(3 * HZ)

struct octep_ft_ent {
	bool used;
	int conn;
	unsigned long cookie;
	u8 proto;
	__be32 src, dst, nsrc, ndst;
	u16 sport, dport, nsport, ndport;
	u8 dmac[ETH_ALEN], smac[ETH_ALEN];
	u8 iface;
	u16 tag;
	u8 fails;
	bool blackhole;
	u32 bad_spare;
	unsigned long retry_at;
	unsigned long born;
	bool trig;
	bool bridged;
};

struct octep_ft_conn {
	bool used;
	bool blackhole_checked;
	bool hw_active;
	u32 reply_ts;
	unsigned long reply_ts_moved;
	unsigned long reply_ts_poll;
	unsigned long since;
	unsigned long rearm;
	u32 id[2], rev[2];
	u32 alloc_ts[2];
	unsigned long alloc_next;
	u8 revives;
	u64 pkts_seen;
	bool cutin_pending;
	unsigned long cutin_at;
	struct octep_ft_ent tup;
	struct octep_rpc_flow_create_payload fc;
};

struct octep_flow_counter {
	bool used;
	u32 index;
	u16 revision;
	u32 raw[2][2];
	u64 packets[2];
	u64 bytes[2];
	u64 sequence;
	unsigned long last_update;
};

struct octep_rx_flow_track {
	bool used;
	bool tuple_valid;
	u32 id;
	u16 tag;
	u8 revision;
	u64 frames;
	u64 sequence;
	unsigned long last_seen;
	u8 family;
	u8 protocol;
	u8 src_addr[16];
	u8 dst_addr[16];
	u16 src_port;
	u16 dst_port;
	u8 src_mac[ETH_ALEN];
	u8 dst_mac[ETH_ALEN];
	u16 vlan;
};

#define OCTEP_FT_DIAG_FLOWS	32
#define OCTEP_FT_DIAG_RING	64
#define OCTEP_FT_TRIG_MAX	16

struct octep_ft_diag_flow {
	bool used;
	__be32 lo_addr, hi_addr;
	u16 lo_port, hi_port;
	u8 cnt[2];
};

struct octep_ft_diag_rec {
	unsigned long when;
	__be32 src, dst;
	u16 sport, dport;
	u8 dir, flow_valid, md_valid, rev;
	u32 id;
	u16 tag;
};

struct octep {
	struct pci_dev *pdev;
	void __iomem *bar0;
	void __iomem *bar2;
	resource_size_t bar0_len;
	resource_size_t bar2_len;
	struct mutex lock;
	spinlock_t mgmt_lock;
	spinlock_t dp_tx_lock;
	spinlock_t dp_stats_lock;
	spinlock_t flow_stats_lock;
	struct delayed_work mgmt_poll_work;
	struct delayed_work dp_poll_work;
	struct net_device *dp_napi_dev;
	struct napi_struct dp_napi;
	struct hrtimer dp_hrt;
	ktime_t dp_hrt_period;
	bool dp_napi_on;
	bool dp_napi_enabled;
	struct delayed_work vf_mbox_work;
	u64 scratch;
	u32 barmap_offset;
	u32 barmap_version;
	u32 gicd_offset;
	u32 pem_num;
	bool ready;
	struct octep_facility facility[OCTEP_FACILITY_COUNT];
	struct net_device *mgmt_netdev;
	struct octep_dma_mem mgmt_shadow;
	struct octep_dma_mem mgmt_rxbuf;
	struct octep_dma_mem mgmt_txbuf;
	__le32 *mgmt_tx_cons_shadow;
	__le32 *mgmt_rx_cons_shadow;
	struct rtnl_link_stats64 mgmt_stats;
	u32 mgmt_tx_descq;
	u32 mgmt_rx_descq;
	u32 mgmt_tx_prod;
	u32 mgmt_rx_prod;
	u32 mgmt_rx_cons;
	u32 mgmt_dbell;
	u32 mgmt_mbox_id;
	u32 mgmt_host_status;
	u32 mgmt_poll_ticks;
	bool mgmt_active;
	bool mgmt_target_fatal_logged;
	bool nwa_cookie_not_ready_logged;
	bool nwa_discovered;
	u32 nwa_nports;
	u32 nwa_reply_words;
	u32 nwa_marker;
	u32 nwa_status;
	u32 nwa_reply_len;
	u32 nwa_reply[OCTEP_NWA_MAX_WORDS];
	u32 nwa_last_op;
	u32 nwa_last_sub;
	u32 nwa_last_port;
	u32 nwa_last_param;
	u32 nwa_last_param2;
	u32 nwa_last_words;
	u32 nwa_last_marker;
	u32 nwa_last_status;
	u32 nwa_last_reply_len;
	int nwa_last_error;
	u32 nwa_last_reply[OCTEP_NWA_MAX_WORDS];
	bool dp_up;
	bool dp_poll_enabled;
	bool dp_io_enabled;
	bool hs_done;
	bool hs_reply_received;
	u32 sdp_coproc_ticks_per_us;
	u32 dp_time_threshold;
	u32 dp_ring_count;
	u32 vf_mbox_ring_start;
	bool vf_mbox_enabled;
	bool vf_mbox_logged[OCTEP_SRIOV_VF_COUNT];
	u8 vf_mac[OCTEP_SRIOV_VF_COUNT][ETH_ALEN];
	u32 dp_tx_prod;
	u32 dp_port_count;
	struct octep_dp_port dp_port[OCTEP_DP_PORT_MAX];
	struct octep_flow_counter flow_stats[OCTEP_FLOW_STATS_MAX];
	u64 flow_stats_sequence;
	struct octep_rx_flow_track rx_flow_tracks[OCTEP_RX_FLOW_TRACK_MAX];
	struct octep_ft_diag_flow ft_diag_flow[OCTEP_FT_DIAG_FLOWS];
	struct octep_ft_diag_rec ft_diag_ring[OCTEP_FT_DIAG_RING];
	unsigned int ft_diag_next;
	unsigned int ft_diag_head;
	u64 ft_diag_total;
	u64 ft_pair_waits;
	u64 ft_pair_creates;
	u64 ft_ct_queued;
	u64 ft_ct_dropped;
	u64 ft_ct_released;
	u64 ft_ct_refreshed;
	struct octep_ft_ent ft_ent[OCTEP_FT_MAX];
	struct octep_ft_conn ft_conn[OCTEP_FT_CONNS];
	struct delayed_work ft_work;
	struct delayed_work ft_guard_work;
	unsigned long ft_full_at;
	bool ft_stop;
	u32 ft_spare_id;
	bool ft_spare_set;
	u64 rx_flow_track_sequence;
	u64 cmsg_tag_frames;
	u64 cmsg_rx;
	u64 cmsg_conn_stats_messages;
	u64 cmsg_conn_stats_entries;
	u64 cmsg_malformed;
	u64 cmsg_dropped;
	u64 cmsg_untracked;
	u8 cmsg_last_type;
	unsigned long cmsg_last_jiffies;
	u64 rx_meta_frames;
	u64 rx_meta_signature_matches;
	u64 rx_meta_valid_frames;
	u64 rx_meta_extra_frames;
	u64 rx_flow_valid_frames;
	u32 rx_flow_last_id;
	u8 rx_flow_last_revision;
	u32 rx_flow_last_valid_id;
	u8 rx_flow_last_valid_revision;
	u16 rx_flow_last_tag;
	u16 rx_flow_last_valid_tag;
	u8 rx_flow_last_md_valid;
	bool rx_flow_last_signature;
	bool rx_flow_last_valid;
	unsigned long rx_flow_last_jiffies;
	unsigned long rx_flow_last_valid_jiffies;
	struct octep_dp_ring dp_ring[OCTEP_DP_RING_COUNT];
	struct octep_dma_mem rpc_cmd;
	u32 rpc_desc_off;
	u32 rpc_desc_count;
	u64 rpc_posted;
	u64 rpc_hi_posted;
	bool rpc_hi_active;
	bool rpc_ready;
	bool rpc_allow_write;
	bool rpc_platform_probe;
	bool rpc_platform_known;
	u8 rpc_cmd_shift;
	u16 rpc_platform_len;
	u32 rpc_platform_conn;
	u32 rpc_platform_nhop;
	u16 rpc_fw_cfg;
	bool rpc_fw_cfg_known;
	u16 rpc_fw_rev;
	u64 rpc_fw_rev_bumps;
	u64 alloc_cnt[7];
	u64 alloc_cnt_all[OCTEP_RPC_SYS_COUNTER_COUNT];
	u32 rpc_last_cmd;
	u16 rpc_last_rc;
	u16 rpc_last_len;
	int rpc_last_error;
	u32 rpc_lif_read_index;
	u8 rpc_lif_read_reply[OCTEP_RPC_LIF_READ_REPLY_MAX];
	u16 rpc_lif_read_len;
	bool rpc_lif_read_valid;
	u32 rpc_mflow_read_index;
	u8 rpc_mflow_read_reply[OCTEP_RPC_MFLOW_READ_REPLY_LEN];
	bool rpc_mflow_read_valid;
	u32 rpc_conn_read_index;
	u16 rpc_conn_read_len;
	u8 rpc_conn_read_reply[OCTEP_RPC_CONN_READ_REPLY_MAX];
	bool rpc_conn_read_valid;
	u32 rpc_conn_reclaim_index;
	u16 rpc_conn_reclaim_revision;
	u8 rpc_conn_reclaim_reply[OCTEP_RPC_CONN_RECLAIM_REPLY_LEN];
	bool rpc_conn_reclaim_valid;
	bool rpc_conn_reclaim_verified;
	u64 rpc_commands;
	u64 rpc_timeouts;
};

static int octep_nwa_wait_locked(struct octep *octep, u32 want, unsigned int tries)
{
	unsigned int i;
	u32 status;

	lockdep_assert_held(&octep->lock);
	for (i = 0; i < tries; i++) {
		status = readl(octep->bar2 + octep->facility[OCTEP_FCLT_NW_AGENT].offset +
			       OCTEP_NWA_STATUS);
		if (status == want)
			return 0;
		if (status == U32_MAX)
			return -ENXIO;
		usleep_range(10000, 12000);
	}
	return -ETIMEDOUT;
}

static int octep_ring_dbell_locked(struct octep *octep, u32 spi)
{
	unsigned int i;

	lockdep_assert_held(&octep->lock);
	if (!octep->ready || !octep->gicd_offset ||
	    octep->gicd_offset > octep->bar2_len - sizeof(u32)) {
		dev_err(&octep->pdev->dev,
			"doorbell SPI %u refused: invalid GICD offset %#x\n",
			spi, octep->gicd_offset);
		return -ENXIO;
	}

	for (i = 0; i < OCTEP_FACILITY_COUNT; i++) {
		const struct octep_facility *facility = &octep->facility[i];
		u64 end = (u64)facility->dbell_start + facility->dbell_count;

		if (facility->dbell_count &&
		    spi >= facility->dbell_start && (u64)spi < end) {
			dev_dbg(&octep->pdev->dev,
				"doorbell write attempt: SPI %u to BAR2+%#x\n",
				 spi, octep->gicd_offset);
			writel(spi, octep->bar2 + octep->gicd_offset);
			wmb();
			dev_dbg(&octep->pdev->dev,
				"doorbell write issued: SPI %u; the write-only doorbell is not read back\n",
				 spi);
			return 0;
		}
	}
	dev_err(&octep->pdev->dev,
		"doorbell SPI %u refused: not in any advertised facility range\n",
		spi);
	return -EINVAL;
}

static bool octep_nwa_range_valid(struct octep *octep, u32 offset, u32 length)
{
	u64 start = (u64)octep->facility[OCTEP_FCLT_NW_AGENT].offset + offset;
	u64 end = start + length;

	return end >= start && end <= octep->bar2_len &&
	       end <= (octep->gicd_offset ? octep->gicd_offset : octep->bar2_len);
}

static int octep_nwa_discover_locked(struct octep *octep)
{
	const struct octep_facility *facility = &octep->facility[OCTEP_FCLT_NW_AGENT];
	u32 *reply = octep->nwa_reply;
	u32 body, max_req, reply_len, payload_len, words, reply_off;
	u32 marker, status;
	unsigned int i;
	int err, ack_err;

	lockdep_assert_held(&octep->lock);
	octep->nwa_discovered = false;
	octep->nwa_nports = 0;
	octep->nwa_reply_words = 0;

	if (!octep->ready || !facility->size || !facility->offset)
		return -ENXIO;
	if (!octep_nwa_range_valid(octep, 0, 0x10) ||
	    !octep_nwa_range_valid(octep, OCTEP_NWA_STATUS, sizeof(u32)) ||
	    !octep_nwa_range_valid(octep, OCTEP_NWA_REQ_SIZE, sizeof(u32)))
		return -EINVAL;

	body = readl(octep->bar2 + facility->offset + OCTEP_NWA_COOKIE);
	if (body != OCTEP_NWA_COOKIE_VALUE) {
		if (!octep->nwa_cookie_not_ready_logged) {
			dev_info(&octep->pdev->dev,
				 "NWA mailbox not ready: cookie %#x, expected %#x; no request sent\n",
				 body, OCTEP_NWA_COOKIE_VALUE);
			octep->nwa_cookie_not_ready_logged = true;
		}
		return -EAGAIN;
	}
	if (octep->nwa_cookie_not_ready_logged) {
		dev_info(&octep->pdev->dev,
			 "NWA mailbox ready: expected cookie %#x is published\n",
			 OCTEP_NWA_COOKIE_VALUE);
		octep->nwa_cookie_not_ready_logged = false;
	}
	body = readl(octep->bar2 + facility->offset + OCTEP_NWA_BODY_OFF);
	max_req = readl(octep->bar2 + facility->offset + OCTEP_NWA_MAX_REQ);
	if (body != OCTEP_NWA_BODY_EXPECTED || max_req < OCTEP_NWA_REQ_SIZE)
		return -EPROTO;
	if (!octep_nwa_range_valid(octep, body, OCTEP_NWA_REQ_SIZE) ||
	    !octep_nwa_range_valid(octep, OCTEP_NWA_REQ_LEN, sizeof(u32)) ||
	    !octep_nwa_range_valid(octep, OCTEP_NWA_TURN, sizeof(u32)) ||
	    !octep_nwa_range_valid(octep, OCTEP_NWA_REPLY_LEN, sizeof(u32)))
		return -EINVAL;

	err = octep_nwa_wait_locked(octep, OCTEP_NWA_STATUS_IDLE,
				    OCTEP_NWA_IDLE_TRIES);
	if (err) {
		dev_warn(&octep->pdev->dev,
			 "NWA discovery not sent: mailbox did not become idle: %d\n",
			 err);
		return err;
	}

	dev_info(&octep->pdev->dev,
		 "NWA discovery request: opcode %#x, %u bytes, facility BAR2+%#x\n",
		 OCTEP_NWA_OP_DISCOVER, OCTEP_NWA_REQ_SIZE, facility->offset);
	writel(OCTEP_NWA_OP_DISCOVER, octep->bar2 + facility->offset + body);
	for (i = 1; i < OCTEP_NWA_REQ_SIZE / sizeof(u32); i++)
		writel(0, octep->bar2 + facility->offset + body +
		       i * sizeof(u32));
	writel(OCTEP_NWA_REQ_SIZE,
	       octep->bar2 + facility->offset + OCTEP_NWA_REQ_LEN);
	wmb();
	writel(OCTEP_NWA_TURN_REQUEST,
	       octep->bar2 + facility->offset + OCTEP_NWA_TURN);
	wmb();
	err = octep_ring_dbell_locked(octep, facility->dbell_start);
	if (err)
		return err;

	dev_info(&octep->pdev->dev,
		 "NWA doorbell issued; polling mailbox status for the NPU reply\n");
	err = octep_nwa_wait_locked(octep, OCTEP_NWA_STATUS_REPLY,
				    OCTEP_NWA_REPLY_TRIES);
	if (err) {
		dev_warn(&octep->pdev->dev,
			 "NWA discovery got no reply before timeout/error: %d\n",
			 err);
		return err;
	}
	rmb();

	reply_len = readl(octep->bar2 + facility->offset + OCTEP_NWA_REPLY_LEN);
	reply_off = body + OCTEP_NWA_REQ_SIZE;
	if (reply_len < OCTEP_NWA_REPLY_HEADER_SIZE ||
	    reply_len > OCTEP_NWA_REPLY_HEADER_SIZE + OCTEP_NWA_MAX_WORDS * sizeof(u32) ||
	    !octep_nwa_range_valid(octep, reply_off, reply_len)) {
		err = -EPROTO;
		goto ack;
	}

	marker = readl(octep->bar2 + facility->offset + reply_off);
	status = readl(octep->bar2 + facility->offset + reply_off + sizeof(u32));
	payload_len = reply_len - OCTEP_NWA_REPLY_HEADER_SIZE;
	words = DIV_ROUND_UP(payload_len, sizeof(u32));
	for (i = 0; i < words; i++)
		reply[i] = readl(octep->bar2 + facility->offset + reply_off +
				 OCTEP_NWA_REPLY_HEADER_SIZE + i * sizeof(u32));
	if (words && (payload_len & 3))
		reply[words - 1] &= GENMASK((payload_len & 3) * 8 - 1, 0);

	octep->nwa_marker = marker;
	octep->nwa_status = status;
	octep->nwa_reply_len = reply_len;
	octep->nwa_reply_words = words;
	dev_info(&octep->pdev->dev,
		 "NWA reply received: marker=%#x status=%#x length=%u bytes\n",
		 marker, status, reply_len);
	if (marker != OCTEP_NWA_REPLY_MARKER || status) {
		dev_warn(&octep->pdev->dev,
			 "NWA reply rejected: marker=%#x status=%#x\n",
			 marker, status);
		err = -EREMOTEIO;
	} else {
		octep->nwa_discovered = true;
		dev_info(&octep->pdev->dev,
			 "NPU mailbox response accepted: marker=%#x status=0\n",
			 marker);
	}

	if (words)
		octep->nwa_nports = reply[0];
	if (octep->nwa_discovered)
		dev_info(&octep->pdev->dev, "NWA discovery found %u ports\n",
			 octep->nwa_nports);
	if (octep->nwa_nports > (words ? (words - 1) / 5 : 0)) {
		octep->nwa_discovered = false;
		err = -EPROTO;
	}

ack:
	writel(OCTEP_NWA_TURN_ACK,
	       octep->bar2 + facility->offset + OCTEP_NWA_TURN);
	wmb();
	ack_err = octep_ring_dbell_locked(octep, facility->dbell_start);
	if (!err && ack_err)
		err = ack_err;
	if (!ack_err)
		ack_err = octep_nwa_wait_locked(octep, OCTEP_NWA_STATUS_IDLE,
						OCTEP_NWA_IDLE_TRIES);
	if (ack_err)
		dev_warn(&octep->pdev->dev,
			 "NWA reply acknowledged, but mailbox did not return idle: %d\n",
			 ack_err);
	return err;
}

static int octep_nwa_request_locked(struct octep *octep, u32 op, u32 sub,
				    u32 port, u32 param, u32 param2)
{
	const struct octep_facility *facility =
		&octep->facility[OCTEP_FCLT_NW_AGENT];
	u32 body, max_req, reply_len, payload_len, words, reply_off;
	u32 marker, status, request[OCTEP_NWA_REQ_SIZE / sizeof(u32)] = {};
	unsigned int i;
	int err, ack_err;

	lockdep_assert_held(&octep->lock);
	if (!octep->ready || !facility->size || !facility->offset)
		return -ENXIO;
	if (op == OCTEP_NWA_OP_SET) {
		if (sub == OCTEP_NWA_SUB_STATE) {
			if (param > 1 || param2)
				return -EINVAL;
		} else if (sub == OCTEP_NWA_SUB_ALLMULTI) {
			if (param > OCTEP_NWA_ALLMULTI_ON || param2)
				return -EINVAL;
		} else if (sub == OCTEP_NWA_SUB_MAC) {
			u8 mac[ETH_ALEN] = {
				param, param >> 8, param >> 16, param >> 24,
				param2, param2 >> 8,
			};

			if ((param2 & 0xffff0000) ||
			    !is_valid_ether_addr(mac))
				return -EINVAL;
		} else {
			return -EPERM;
		}
	} else if (op == OCTEP_NWA_OP_GET) {
		if (param || param2)
			return -EINVAL;
		if (sub == OCTEP_NWA_SUB_STATS) {
			bool port_found = false;

			if (port > U16_MAX)
				return -EINVAL;
			if (!octep->nwa_discovered)
				return -ENXIO;
			for (i = 0; i < octep->nwa_nports; i++) {
				if ((octep->nwa_reply[1 + i * 5] & 0xffff) ==
				    port) {
					port_found = true;
					break;
				}
			}
			if (!port_found)
				return -ENODEV;
		} else if (sub != OCTEP_NWA_SUB_STATE &&
			   sub != OCTEP_NWA_SUB_MAC) {
			return -EPERM;
		}
	} else {
		return -EPERM;
	}

	if (!octep_nwa_range_valid(octep, 0, 0x10) ||
	    !octep_nwa_range_valid(octep, OCTEP_NWA_STATUS, sizeof(u32)) ||
	    !octep_nwa_range_valid(octep, OCTEP_NWA_REQ_SIZE, sizeof(u32)) ||
	    !octep_nwa_range_valid(octep, OCTEP_NWA_REQ_LEN, sizeof(u32)) ||
	    !octep_nwa_range_valid(octep, OCTEP_NWA_TURN, sizeof(u32)) ||
	    !octep_nwa_range_valid(octep, OCTEP_NWA_REPLY_LEN, sizeof(u32)))
		return -EINVAL;

	if (readl(octep->bar2 + facility->offset + OCTEP_NWA_COOKIE) !=
	    OCTEP_NWA_COOKIE_VALUE)
		return -EAGAIN;
	body = readl(octep->bar2 + facility->offset + OCTEP_NWA_BODY_OFF);
	max_req = readl(octep->bar2 + facility->offset + OCTEP_NWA_MAX_REQ);
	if (body != OCTEP_NWA_BODY_EXPECTED || max_req < OCTEP_NWA_REQ_SIZE)
		return -EPROTO;
	if (!octep_nwa_range_valid(octep, body, OCTEP_NWA_REQ_SIZE))
		return -EINVAL;

	err = octep_nwa_wait_locked(octep, OCTEP_NWA_STATUS_IDLE,
				    OCTEP_NWA_IDLE_TRIES);
	if (err)
		return err;

	request[0] = op;
	request[1] = sub;
	request[2] = port;
	request[4] = param;
	request[5] = param2;
	for (i = 0; i < ARRAY_SIZE(request); i++)
		writel(request[i], octep->bar2 + facility->offset + body +
		       i * sizeof(u32));
	writel(OCTEP_NWA_REQ_SIZE,
	       octep->bar2 + facility->offset + OCTEP_NWA_REQ_LEN);
	wmb();
	writel(OCTEP_NWA_TURN_REQUEST,
	       octep->bar2 + facility->offset + OCTEP_NWA_TURN);
	wmb();
	err = octep_ring_dbell_locked(octep, facility->dbell_start);
	if (err)
		return err;

	err = octep_nwa_wait_locked(octep, OCTEP_NWA_STATUS_REPLY,
				    OCTEP_NWA_REPLY_TRIES);
	if (err)
		return err;
	rmb();

	reply_len = readl(octep->bar2 + facility->offset + OCTEP_NWA_REPLY_LEN);
	reply_off = body + OCTEP_NWA_REQ_SIZE;
	if (reply_len < OCTEP_NWA_REPLY_HEADER_SIZE ||
	    reply_len > OCTEP_NWA_REPLY_HEADER_SIZE +
			OCTEP_NWA_MAX_WORDS * sizeof(u32) ||
	    !octep_nwa_range_valid(octep, reply_off, reply_len)) {
		err = -EPROTO;
		goto ack;
	}

	marker = readl(octep->bar2 + facility->offset + reply_off);
	status = readl(octep->bar2 + facility->offset + reply_off + sizeof(u32));
	payload_len = reply_len - OCTEP_NWA_REPLY_HEADER_SIZE;
	words = DIV_ROUND_UP(payload_len, sizeof(u32));
	memset(octep->nwa_last_reply, 0, sizeof(octep->nwa_last_reply));
	for (i = 0; i < words; i++)
		octep->nwa_last_reply[i] =
			readl(octep->bar2 + facility->offset + reply_off +
			      OCTEP_NWA_REPLY_HEADER_SIZE + i * sizeof(u32));
	if (words && (payload_len & 3))
		octep->nwa_last_reply[words - 1] &=
			GENMASK((payload_len & 3) * 8 - 1, 0);
	octep->nwa_last_words = words;
	octep->nwa_last_marker = marker;
	octep->nwa_last_status = status;
	octep->nwa_last_reply_len = reply_len;
	if (marker != OCTEP_NWA_REPLY_MARKER || status)
		err = -EREMOTEIO;
	else if (op == OCTEP_NWA_OP_GET &&
		 sub == OCTEP_NWA_SUB_STATS &&
		 payload_len != OCTEP_NWA_STATS_COUNT * sizeof(u64))
		err = -EPROTO;
	else
		err = 0;

ack:
	writel(OCTEP_NWA_TURN_ACK,
	       octep->bar2 + facility->offset + OCTEP_NWA_TURN);
	wmb();
	ack_err = octep_ring_dbell_locked(octep, facility->dbell_start);
	if (!err && ack_err)
		err = ack_err;
	if (!ack_err)
		(void)octep_nwa_wait_locked(octep, OCTEP_NWA_STATUS_IDLE,
					    OCTEP_NWA_IDLE_TRIES);
	return err;
}

static int octep_read_barmap_locked(struct octep *octep)
{
	resource_size_t offset, end;
	u32 magic;
	unsigned int i;

	octep->scratch = readq(octep->bar0 + OCTEP_SDP_SCRATCH);
	magic = lower_32_bits(octep->scratch);
	octep->barmap_offset = upper_32_bits(octep->scratch);
	octep->ready = false;
	memset(octep->facility, 0, sizeof(octep->facility));
	octep->nwa_discovered = false;
	octep->nwa_nports = 0;
	octep->nwa_reply_words = 0;

	if (octep->scratch == U64_MAX) {
		dev_err(&octep->pdev->dev,
			"BAR0 reads all ones; the endpoint is not decoding\n");
		return -ENXIO;
	}
	if (magic != OCTEP_READY_MAGIC) {
		dev_info(&octep->pdev->dev,
			 "NPU not ready yet (scratch %#018llx, magic %#010x)\n",
			 (unsigned long long)octep->scratch, magic);
		return -EAGAIN;
	}
	dev_info(&octep->pdev->dev,
		 "SDP scratch BAR0+%#x=%#018llx (magic=%#x, barmap offset=%#x)\n",
		 OCTEP_SDP_SCRATCH, (unsigned long long)octep->scratch,
		 magic, octep->barmap_offset);

	offset = octep->barmap_offset;
	if (offset > octep->bar2_len ||
	    octep->bar2_len - offset < OCTEP_BARMAP_SIZE) {
		dev_err(&octep->pdev->dev,
			"barmap offset %#x is outside BAR2 (size %#llx)\n",
			octep->barmap_offset,
			(unsigned long long)octep->bar2_len);
		return -EINVAL;
	}

	octep->barmap_version = readl(octep->bar2 + offset +
				       OCTEP_BARMAP_VERSION_OFF);
	if (octep->barmap_version == U32_MAX)
		return -EAGAIN;
	if (octep->barmap_version != OCTEP_BARMAP_VERSION) {
		dev_err(&octep->pdev->dev,
			"barmap version %#x, expected %#x\n",
			octep->barmap_version, OCTEP_BARMAP_VERSION);
		return -EINVAL;
	}

	for (i = 0; i < OCTEP_FACILITY_COUNT; i++) {
		resource_size_t entry = offset + OCTEP_BARMAP_FACILITY_OFF +
					i * OCTEP_FACILITY_ENTRY_SIZE;

		octep->facility[i].offset = readl(octep->bar2 + entry);
		octep->facility[i].size = readl(octep->bar2 + entry + 4);
		octep->facility[i].dbell_start = readl(octep->bar2 + entry + 8);
		octep->facility[i].dbell_count = readl(octep->bar2 + entry + 12);
	}

	octep->gicd_offset = readl(octep->bar2 + offset +
				    OCTEP_BARMAP_GICD_OFF);
	octep->pem_num = readl(octep->bar2 + offset + OCTEP_BARMAP_PEM_OFF) & 0xff;

	/*
	 * Do not read the GIC distributor window: on this device those reads can
	 * stall the host. Validate facility windows without touching their contents.
	 */
	for (i = 0; i < OCTEP_FACILITY_COUNT; i++) {
		struct octep_facility *facility = &octep->facility[i];

		if (!facility->size)
			continue;
		end = (resource_size_t)facility->offset + facility->size;
		if (end < facility->offset || end > octep->bar2_len ||
		    (octep->gicd_offset && end > octep->gicd_offset)) {
			dev_err(&octep->pdev->dev,
				"%s facility window [%#x, %#llx) is invalid\n",
				octep_facility_names[i], facility->offset,
				(unsigned long long)end);
			return -EINVAL;
		}
	}

	octep->ready = true;
	return 0;
}

static ssize_t state_show(struct device *dev, struct device_attribute *attr,
			  char *buf)
{
	struct octep *octep = dev_get_drvdata(dev);
	ssize_t len;

	mutex_lock(&octep->lock);
	len = sysfs_emit(buf,
			 "ready=%u scratch=%#018llx barmap_offset=%#x version=%u "
			 "pem=%u gicd_offset=%#x bar0=%#llx bar2=%#llx\n",
			 octep->ready, (unsigned long long)octep->scratch,
			 octep->barmap_offset, octep->barmap_version,
			 octep->pem_num, octep->gicd_offset,
			 (unsigned long long)octep->bar0_len,
			 (unsigned long long)octep->bar2_len);
	mutex_unlock(&octep->lock);
	return len;
}
static DEVICE_ATTR_RO(state);

static struct octep_sdp_rinfo octep_read_sdp_rinfo(struct octep *octep)
{
	struct octep_sdp_rinfo info = {};

	info.value = readq(octep->bar0 + OCTEP_SDP_EPF_RINFO);
	info.start_ring = info.value & 0x7f;
	info.pf_rings = (info.value >> 16) & 0xff;
	info.rings_per_vf = (info.value >> 32) & 0x1f;
	info.num_vfs = (info.value >> 48) & 0x7f;
	while ((u64)info.bar0_rings * OCTEP_SDP_RING_STRIDE +
	       OCTEP_SDP_RING_SPAN <= octep->bar0_len)
		info.bar0_rings++;
	return info;
}

static int octep_sdp_validate_vfs(struct octep *octep,
				  const struct octep_sdp_rinfo *rinfo,
				  u32 num_vfs, u32 *pf_start_ring)
{
	u32 reserved_rings, pf_limit;

	if (rinfo->value == U64_MAX)
		return -ENXIO;

	if (!num_vfs) {
		if (rinfo->num_vfs || rinfo->rings_per_vf) {
			dev_err(&octep->pdev->dev,
				"sdp: RINFO declares %u VFs x %u rings, but PCI exposes no VFs\n",
				rinfo->num_vfs, rinfo->rings_per_vf);
			return -EINVAL;
		}
		*pf_start_ring = rinfo->start_ring;
		return 0;
	}

	if (num_vfs != OCTEP_SRIOV_VF_COUNT) {
		dev_err(&octep->pdev->dev,
			"sdp: this XGS 2300 profile supports exactly %u VFs, not %u\n",
			OCTEP_SRIOV_VF_COUNT, num_vfs);
		return -EINVAL;
	}
	if ((rinfo->num_vfs == 0 && rinfo->rings_per_vf != 0) ||
	    (rinfo->num_vfs != 0 &&
	     (rinfo->num_vfs != num_vfs ||
	      rinfo->rings_per_vf != OCTEP_SRIOV_RINGS_PER_VF))) {
		dev_err(&octep->pdev->dev,
			"sdp: PCI exposes %u VFs but RINFO declares %u VFs x %u rings\n",
			num_vfs, rinfo->num_vfs, rinfo->rings_per_vf);
		return -EINVAL;
	}

	reserved_rings = num_vfs * OCTEP_SRIOV_RINGS_PER_VF;
	pf_limit = rinfo->start_ring + rinfo->pf_rings;
	*pf_start_ring = rinfo->start_ring + reserved_rings;
	if (rinfo->pf_rings < reserved_rings + OCTEP_DP_RING_COUNT ||
	    *pf_start_ring + OCTEP_DP_RING_COUNT > pf_limit ||
	    *pf_start_ring + OCTEP_DP_RING_COUNT > rinfo->bar0_rings ||
	    *pf_start_ring + OCTEP_DP_RING_COUNT > 64) {
		dev_err(&octep->pdev->dev,
			"sdp: cannot reserve %u VF rings and %u PF rings from RINFO %#018llx\n",
			reserved_rings, OCTEP_DP_RING_COUNT,
			(unsigned long long)rinfo->value);
		return -ENOSPC;
	}

	return 0;
}

static int octep_sdp_prepare_vfs_locked(struct octep *octep,
					struct octep_sdp_rinfo *rinfo,
					u32 *pf_start_ring)
{
	u32 num_vfs = pci_num_vf(octep->pdev);
	u32 reserved_rings, i;
	u64 value, readback, vf_num;
	int err;

	lockdep_assert_held(&octep->lock);
	err = octep_sdp_validate_vfs(octep, rinfo, num_vfs,
				     pf_start_ring);
	if (err || !num_vfs)
		return err;

	reserved_rings = num_vfs * OCTEP_SRIOV_RINGS_PER_VF;
	value = (rinfo->value & ~(OCTEP_SDP_RINFO_RPVF_MASK |
				  OCTEP_SDP_RINFO_NVFS_MASK)) |
		((u64)OCTEP_SRIOV_RINGS_PER_VF << 32) |
		((u64)num_vfs << 48);
	if (value != rinfo->value) {
		writeq(value, octep->bar0 + OCTEP_SDP_EPF_RINFO);
		readback = readq(octep->bar0 + OCTEP_SDP_EPF_RINFO);
		if ((readback & (OCTEP_SDP_RINFO_RPVF_MASK |
				 OCTEP_SDP_RINFO_NVFS_MASK)) !=
		    (value & (OCTEP_SDP_RINFO_RPVF_MASK |
			      OCTEP_SDP_RINFO_NVFS_MASK))) {
			dev_err(&octep->pdev->dev,
				"sdp: VF ring split did not read back (wanted %#018llx, got %#018llx)\n",
				(unsigned long long)value,
				(unsigned long long)readback);
			return -EIO;
		}
	}

	for (i = 0; i < reserved_rings; i++) {
		u32 ring = rinfo->start_ring + i;
		resource_size_t offset = OCTEP_SDP_EPF_R_VF_NUM +
					 (resource_size_t)ring *
					 OCTEP_SDP_RING_STRIDE;
		void __iomem *reg;

		if (ring >= rinfo->bar0_rings || ring >= 64 ||
		    offset + sizeof(u64) > octep->bar0_len)
			return -ENXIO;
		reg = octep->bar0 + offset;
		vf_num = readq(reg);
		vf_num = (vf_num & ~OCTEP_SDP_VF_NUM_MASK) |
			 (i / OCTEP_SRIOV_RINGS_PER_VF + 1);
		writeq(vf_num, reg);
		if ((readq(reg) & OCTEP_SDP_VF_NUM_MASK) !=
		    (i / OCTEP_SRIOV_RINGS_PER_VF + 1)) {
			dev_err(&octep->pdev->dev,
				"sdp: VF ownership did not read back for ring %u\n",
				ring);
			return -EIO;
		}
	}

	*rinfo = octep_read_sdp_rinfo(octep);
	err = octep_sdp_validate_vfs(octep, rinfo, num_vfs,
				     pf_start_ring);
	if (err)
		return err;

	dev_info(&octep->pdev->dev,
		 "sdp: published RINFO %#018llx; rings %u..%u assigned to %u VFs; PF rings start at %u\n",
		 (unsigned long long)rinfo->value, rinfo->start_ring,
		 rinfo->start_ring + reserved_rings - 1, num_vfs,
		 *pf_start_ring);
	return 0;
}

static int octep_sdp_clear_vf_split_locked(struct octep *octep)
{
	struct octep_sdp_rinfo rinfo = octep_read_sdp_rinfo(octep);
	u32 reserved_rings, i;
	u64 value, readback, vf_num;

	lockdep_assert_held(&octep->lock);
	if (rinfo.value == U64_MAX)
		return -ENXIO;
	if (!rinfo.num_vfs && !rinfo.rings_per_vf)
		return 0;
	if (rinfo.num_vfs != OCTEP_SRIOV_VF_COUNT ||
	    rinfo.rings_per_vf != OCTEP_SRIOV_RINGS_PER_VF)
		return -EINVAL;

	reserved_rings = rinfo.num_vfs * rinfo.rings_per_vf;
	for (i = 0; i < reserved_rings; i++) {
		u32 ring = rinfo.start_ring + i;
		resource_size_t offset = OCTEP_SDP_EPF_R_VF_NUM +
					 (resource_size_t)ring *
					 OCTEP_SDP_RING_STRIDE;
		void __iomem *reg;

		if (ring >= rinfo.bar0_rings || ring >= 64 ||
		    offset + sizeof(u64) > octep->bar0_len)
			return -ENXIO;
		reg = octep->bar0 + offset;
		vf_num = readq(reg) & ~OCTEP_SDP_VF_NUM_MASK;
		writeq(vf_num, reg);
		if (readq(reg) & OCTEP_SDP_VF_NUM_MASK)
			return -EIO;
	}

	value = rinfo.value & ~(OCTEP_SDP_RINFO_RPVF_MASK |
				OCTEP_SDP_RINFO_NVFS_MASK);
	writeq(value, octep->bar0 + OCTEP_SDP_EPF_RINFO);
	readback = readq(octep->bar0 + OCTEP_SDP_EPF_RINFO);
	if (readback & (OCTEP_SDP_RINFO_RPVF_MASK |
			OCTEP_SDP_RINFO_NVFS_MASK))
		return -EIO;

	return 0;
}

static void octep_log_sdp_rinfo(struct octep *octep)
{
	struct octep_sdp_rinfo info = octep_read_sdp_rinfo(octep);

	if (info.pf_rings) {
		dev_info(&octep->pdev->dev,
			 "SDP RINFO %#018llx ready=%u (barmap): advertised PF rings "
			 "%u..%u (%u), %u VF x %u rings; %u rings fit in BAR0\n",
			 (unsigned long long)info.value, octep->ready,
			 info.start_ring,
			 info.start_ring + info.pf_rings - 1, info.pf_rings,
			 info.num_vfs, info.rings_per_vf, info.bar0_rings);
	} else {
		dev_info(&octep->pdev->dev,
			 "SDP RINFO %#018llx ready=%u (barmap): advertised PF rings "
			 "none (0), %u VF x %u rings; %u rings fit in BAR0\n",
			 (unsigned long long)info.value, octep->ready, info.num_vfs,
			 info.rings_per_vf, info.bar0_rings);
	}
}

static ssize_t sdp_rinfo_show(struct device *dev,
			      struct device_attribute *attr, char *buf)
{
	struct octep *octep = dev_get_drvdata(dev);
	struct octep_sdp_rinfo info = octep_read_sdp_rinfo(octep);

	return sysfs_emit(buf,
			  "rinfo=%#018llx srn=%u pf_rings=%u rpvf=%u nvfs=%u "
			  "bar0_rings=%u\n",
			  (unsigned long long)info.value, info.start_ring,
			  info.pf_rings, info.rings_per_vf, info.num_vfs,
			  info.bar0_rings);
}
static DEVICE_ATTR_RO(sdp_rinfo);

static void __iomem *octep_ring_reg(struct octep *octep, u32 ring, u32 offset)
{
	return octep->bar0 + (resource_size_t)ring * OCTEP_SDP_RING_STRIDE +
	       offset;
}

static u64 octep_ring_readq(struct octep *octep, u32 ring, u32 offset)
{
	return readq(octep_ring_reg(octep, ring, offset));
}

static void octep_ring_writeq(struct octep *octep, u32 ring, u32 offset,
			      u64 value)
{
	writeq(value, octep_ring_reg(octep, ring, offset));
}

static int octep_dma_alloc(struct octep *octep, struct octep_dma_mem *mem,
			   size_t size)
{
	mem->vaddr = dma_alloc_coherent(&octep->pdev->dev, size,
					&mem->dma_addr, GFP_KERNEL);
	if (!mem->vaddr)
		return -ENOMEM;
	mem->size = size;
	return 0;
}

static void octep_dma_free(struct octep *octep, struct octep_dma_mem *mem)
{
	if (mem->vaddr)
		dma_free_coherent(&octep->pdev->dev, mem->size, mem->vaddr,
				  mem->dma_addr);
	memset(mem, 0, sizeof(*mem));
}

static void octep_dp_free_allocations(struct octep *octep)
{
	unsigned int i;

	for (i = 0; i < OCTEP_DP_RING_COUNT; i++) {
		struct octep_dp_ring *ring = &octep->dp_ring[i];

		octep_dma_free(octep, &ring->info);
		octep_dma_free(octep, &ring->bufs);
		octep_dma_free(octep, &ring->slist);
		octep_dma_free(octep, &ring->txbuf);
		octep_dma_free(octep, &ring->instr);
		memset(ring, 0, sizeof(*ring));
	}
	octep->dp_ring_count = 0;
}

static struct octep_dp_port *octep_dp_port_by_tag(struct octep *octep,
						   u16 tag)
{
	u32 i, count = smp_load_acquire(&octep->dp_port_count);

	for (i = 0; i < count; i++)
		if (octep->dp_port[i].tag == tag)
			return &octep->dp_port[i];
	return NULL;
}

static void octep_dp_build_instr(struct octep_dp_ring *ring, u32 slot,
				 dma_addr_t dptr, u32 len, u8 iface)
{
	u8 *entry = (u8 *)ring->instr.vaddr +
		    (size_t)slot * OCTEP_DP_INSTR_SIZE;
	u64 ih3, pki_ih3, irh, word;

	ih3 = (len + OCTEP_DP_INSTR_FSZ) |
	      ((u64)OCTEP_DP_P_KIND << 36) |
	      ((u64)OCTEP_DP_INSTR_FSZ << 42);
	pki_ih3 = (1ULL << 47) |
		  ((u64)OCTEP_DP_INSTR_SL << 48) |
		  (1ULL << 63);
	irh = ((u64)OCTEP_DP_CKSUM_OFFSET << 20) |
	      ((u64)iface << 40) |
	      ((u64)OCTEP_DP_OP_PACKET << 48);

	memset(entry, 0, OCTEP_DP_INSTR_SIZE);
	word = cpu_to_le64(dptr);
	memcpy(entry, &word, sizeof(word));
	word = cpu_to_le64(ih3);
	memcpy(entry + 8, &word, sizeof(word));
	word = cpu_to_le64(pki_ih3);
	memcpy(entry + 16, &word, sizeof(word));
	word = cpu_to_be64(0);
	memcpy(entry + 24, &word, sizeof(word));
	word = cpu_to_be64(irh);
	memcpy(entry + 32, &word, sizeof(word));
}

static u32 octep_dp_rx_span(u64 len)
{
	u64 extra;

	if (len <= OCTEP_DP_BUF_SIZE - 8)
		return 1;
	if (len > OCTEP_DP_PKT_MAX)
		return 0;

	extra = len + 8 - OCTEP_DP_BUF_SIZE;
	return 1 + DIV_ROUND_UP_ULL(extra, OCTEP_DP_BUF_SIZE);
}

static void octep_dp_count_rx(struct octep *octep,
			      struct octep_dp_port *port,
			      u32 len, bool dropped)
{
	unsigned long flags;

	spin_lock_irqsave(&octep->dp_stats_lock, flags);
	if (dropped) {
		port->stats.rx_dropped++;
	} else {
		port->stats.rx_packets++;
		port->stats.rx_bytes += len;
	}
	spin_unlock_irqrestore(&octep->dp_stats_lock, flags);
}

static bool octep_dp_rx_flow_tuple(const u8 *frame, u32 frame_len,
				   struct octep_rx_flow_track *track)
{
	u16 ether_type, fragment, ip_len;
	u32 ip_offset, l4_offset;
	u8 protocol;

	if (frame_len < ETH_HLEN)
		return false;

	ether_type = get_unaligned_be16(frame + 12);
	ip_offset = ETH_HLEN;
	memcpy(track->dst_mac, frame, ETH_ALEN);
	memcpy(track->src_mac, frame + ETH_ALEN, ETH_ALEN);

	while (ether_type == ETH_P_8021Q || ether_type == ETH_P_8021AD) {
		if (frame_len < ip_offset + VLAN_HLEN)
			return false;
		track->vlan = get_unaligned_be16(frame + ip_offset) & VLAN_VID_MASK;
		ether_type = get_unaligned_be16(frame + ip_offset + 2);
		ip_offset += VLAN_HLEN;
	}

	if (ether_type == ETH_P_IP) {
		u8 ihl;

		if (frame_len < ip_offset + sizeof(struct iphdr) ||
		    (frame[ip_offset] >> 4) != 4)
			return false;
		ihl = (frame[ip_offset] & 0x0f) * 4;
		if (ihl < sizeof(struct iphdr) || frame_len < ip_offset + ihl)
			return false;
		ip_len = get_unaligned_be16(frame + ip_offset + 2);
		if (ip_len < ihl || ip_len > frame_len - ip_offset)
			return false;

		track->family = 4;
		protocol = frame[ip_offset + offsetof(struct iphdr, protocol)];
		memcpy(track->src_addr, frame + ip_offset + 12, 4);
		memcpy(track->dst_addr, frame + ip_offset + 16, 4);
		fragment = get_unaligned_be16(frame + ip_offset + 6);
		if (fragment & OCTEP_DP_IPV4_FRAGMENT_MASK)
			return false;
		l4_offset = ip_offset + ihl;
	} else if (ether_type == ETH_P_IPV6) {
		if (frame_len < ip_offset + sizeof(struct ipv6hdr) ||
		    (frame[ip_offset] >> 4) != 6)
			return false;
		ip_len = get_unaligned_be16(frame + ip_offset + 4);
		if (ip_len > frame_len - ip_offset - sizeof(struct ipv6hdr))
			return false;

		track->family = 6;
		protocol = frame[ip_offset + offsetof(struct ipv6hdr, nexthdr)];
		memcpy(track->src_addr, frame + ip_offset + 8, 16);
		memcpy(track->dst_addr, frame + ip_offset + 24, 16);
		fragment = 0;
		l4_offset = ip_offset + sizeof(struct ipv6hdr);
	} else {
		return false;
	}

	track->protocol = protocol;
	if (protocol == IPPROTO_TCP || protocol == IPPROTO_UDP) {
		if (frame_len < l4_offset + 4 ||
		    (ether_type == ETH_P_IP && ip_len < l4_offset - ip_offset + 4) ||
		    (ether_type == ETH_P_IPV6 && ip_len < 4))
			return false;
		track->src_port = get_unaligned_be16(frame + l4_offset);
		track->dst_port = get_unaligned_be16(frame + l4_offset + 2);
	}
	return true;
}

static bool octep_dp_rx_flow_tuple_equal(const struct octep_rx_flow_track *a,
					 const struct octep_rx_flow_track *b)
{
	return a->tuple_valid == b->tuple_valid &&
	       a->family == b->family &&
	       a->protocol == b->protocol &&
	       a->src_port == b->src_port &&
	       a->dst_port == b->dst_port &&
	       a->vlan == b->vlan &&
	       ether_addr_equal(a->src_mac, b->src_mac) &&
	       ether_addr_equal(a->dst_mac, b->dst_mac) &&
	       !memcmp(a->src_addr, b->src_addr, sizeof(a->src_addr)) &&
	       !memcmp(a->dst_addr, b->dst_addr, sizeof(a->dst_addr));
}

static void octep_dp_rx_flow_tuple_copy(struct octep_rx_flow_track *dst,
					const struct octep_rx_flow_track *src)
{
	dst->tuple_valid = src->tuple_valid;
	dst->family = src->family;
	dst->protocol = src->protocol;
	memcpy(dst->src_addr, src->src_addr, sizeof(dst->src_addr));
	memcpy(dst->dst_addr, src->dst_addr, sizeof(dst->dst_addr));
	dst->src_port = src->src_port;
	dst->dst_port = src->dst_port;
	memcpy(dst->src_mac, src->src_mac, sizeof(dst->src_mac));
	memcpy(dst->dst_mac, src->dst_mac, sizeof(dst->dst_mac));
	dst->vlan = src->vlan;
}

/* Called with flow_stats_lock held: remember the first frames of each new IPv4 TCP flow, per direction. */
static void octep_ft_diag_record_locked(struct octep *octep,
					const struct octep_rx_flow_track *t,
					bool flow_valid, u8 md_valid, u32 identity,
					u16 tag)
{
	unsigned int limit = READ_ONCE(octep_ft_diag_frames);
	struct octep_ft_diag_flow *f = NULL;
	struct octep_ft_diag_rec *r;
	__be32 src, dst;
	u16 sport = t->src_port, dport = t->dst_port;
	bool fwd;
	unsigned int i;

	if (!limit && OCTEP_FT_FEAT(octep_ft_pair_gate))
		limit = 8;
	if (!limit || !t->tuple_valid || t->family != 4 || t->protocol != IPPROTO_TCP)
		return;
	memcpy(&src, t->src_addr, 4);
	memcpy(&dst, t->dst_addr, 4);
	fwd = ntohl(src) < ntohl(dst) || (src == dst && sport < dport);
	for (i = 0; i < OCTEP_FT_DIAG_FLOWS; i++) {
		struct octep_ft_diag_flow *c = &octep->ft_diag_flow[i];

		if (c->used && c->lo_addr == (fwd ? src : dst) &&
		    c->hi_addr == (fwd ? dst : src) &&
		    c->lo_port == (fwd ? sport : dport) &&
		    c->hi_port == (fwd ? dport : sport)) {
			f = c;
			break;
		}
	}
	if (!f) {
		f = &octep->ft_diag_flow[octep->ft_diag_next++ % OCTEP_FT_DIAG_FLOWS];
		memset(f, 0, sizeof(*f));
		f->used = true;
		f->lo_addr = fwd ? src : dst;
		f->hi_addr = fwd ? dst : src;
		f->lo_port = fwd ? sport : dport;
		f->hi_port = fwd ? dport : sport;
		dev_info_ratelimited(&octep->pdev->dev,
				     "ft: diag new flow %pI4:%u <-> %pI4:%u first frame flow_valid %d md_valid 0x%x id %u rev %u tag 0x%x\n",
				     &f->lo_addr, f->lo_port, &f->hi_addr, f->hi_port,
				     flow_valid, md_valid,
				     (u32)(identity & OCTEP_DP_RX_FLOW_ID_MASK),
				     (u32)((identity & OCTEP_DP_RX_FLOW_REV_MASK) >> 25), tag);
	}
	if (f->cnt[!fwd] >= limit)
		return;
	f->cnt[!fwd]++;
	r = &octep->ft_diag_ring[octep->ft_diag_head++ % OCTEP_FT_DIAG_RING];
	r->when = jiffies;
	r->src = src;
	r->dst = dst;
	r->sport = sport;
	r->dport = dport;
	r->dir = !fwd;
	r->flow_valid = flow_valid;
	r->md_valid = md_valid;
	r->id = identity & OCTEP_DP_RX_FLOW_ID_MASK;
	r->rev = (identity & OCTEP_DP_RX_FLOW_REV_MASK) >> 25;
	r->tag = tag;
	octep->ft_diag_total++;
}

static void octep_dp_rx_flow_metadata(struct octep *octep, const u8 *prefix,
				      u16 tag, const u8 *frame,
				      u32 frame_len)
{
	struct octep_rx_flow_track *track = NULL;
	struct octep_rx_flow_track tuple = {};
	u32 signature, metadata, identity;
	u8 md_valid;
	bool signature_valid, flow_valid;
	unsigned long flags, oldest = ULONG_MAX;
	u64 oldest_sequence = U64_MAX;
	unsigned int i;
	bool tuple_valid;

	signature = get_unaligned_le32(prefix + OCTEP_DP_RX_META_OFF);
	metadata = get_unaligned_le32(prefix + OCTEP_DP_RX_META_OFF + 4);
	identity = get_unaligned_le32(prefix + OCTEP_DP_RX_FLOW_OFF);
	md_valid = (metadata >> OCTEP_DP_RX_META_VALID_SHIFT) & 0xff;
	signature_valid = signature == OCTEP_DP_RX_META_SIG;
	/* md_valid is a bitmask (flow = bit 0, DoS = bit 1); the firmware stamps the flow id whenever bit 0 is set. */
	flow_valid = signature_valid && (md_valid & 1) &&
		     (identity & OCTEP_DP_RX_FLOW_VALID);
	tuple_valid = octep_dp_rx_flow_tuple(frame, frame_len, &tuple);
	if (!tuple_valid)
		memset(&tuple, 0, sizeof(tuple));
	tuple.tuple_valid = tuple_valid;

	spin_lock_irqsave(&octep->flow_stats_lock, flags);
	octep->rx_meta_frames++;
	octep->rx_flow_last_signature = signature_valid;
	octep->rx_flow_last_md_valid = md_valid;
	octep->rx_flow_last_valid = flow_valid;
	octep->rx_flow_last_id = flow_valid ?
		identity & OCTEP_DP_RX_FLOW_ID_MASK : 0;
	octep->rx_flow_last_revision = flow_valid ?
		(identity & OCTEP_DP_RX_FLOW_REV_MASK) >> 25 : 0;
	octep->rx_flow_last_tag = tag;
	octep->rx_flow_last_jiffies = jiffies;
	octep_ft_diag_record_locked(octep, &tuple, flow_valid, md_valid, identity, tag);

	if (signature_valid) {
		octep->rx_meta_signature_matches++;
		if (md_valid & ~1)
			octep->rx_meta_extra_frames++;
		if (md_valid & 1) {
			octep->rx_meta_valid_frames++;
			if (flow_valid) {
				octep->rx_flow_valid_frames++;
				octep->rx_flow_last_valid_id =
					identity & OCTEP_DP_RX_FLOW_ID_MASK;
				octep->rx_flow_last_valid_revision =
					(identity & OCTEP_DP_RX_FLOW_REV_MASK) >> 25;
				octep->rx_flow_last_valid_tag = tag;
				octep->rx_flow_last_valid_jiffies = jiffies;
				for (i = 0; i < ARRAY_SIZE(octep->rx_flow_tracks); i++) {
					struct octep_rx_flow_track *candidate =
						&octep->rx_flow_tracks[i];

					if (candidate->used &&
					    candidate->id == octep->rx_flow_last_valid_id &&
					    candidate->revision ==
						octep->rx_flow_last_valid_revision &&
					    candidate->tag == tag) {
						track = candidate;
						break;
					}
					if (!candidate->used) {
						track = candidate;
						oldest_sequence = 0;
						break;
					}
					if (candidate->sequence < oldest_sequence) {
						oldest_sequence = candidate->sequence;
						oldest = i;
					}
				}
				if (!track && oldest != ULONG_MAX)
					track = &octep->rx_flow_tracks[oldest];
				if (track) {
					if (!track->used ||
					    track->id != octep->rx_flow_last_valid_id ||
					    track->revision !=
						octep->rx_flow_last_valid_revision ||
					    track->tag != tag) {
						memset(track, 0, sizeof(*track));
						track->used = true;
						track->id = octep->rx_flow_last_valid_id;
						track->revision =
							octep->rx_flow_last_valid_revision;
						track->tag = tag;
					}
					if (!octep_dp_rx_flow_tuple_equal(track, &tuple)) {
						octep_dp_rx_flow_tuple_copy(track, &tuple);
						track->frames = 0;
					}
					track->frames++;
					track->sequence = ++octep->rx_flow_track_sequence;
					track->last_seen = jiffies;
				}
			}
		}
	}
	spin_unlock_irqrestore(&octep->flow_stats_lock, flags);
}

static bool octep_dp_copy_frame(struct octep_dp_ring *ring, u32 idx,
				u32 span, u32 frame_len, u8 *dst)
{
	u32 copied = 0, j;

	for (j = 0; j < span && copied < frame_len; j++) {
		u32 offset = j ? 0 : OCTEP_DP_RX_PREFIX_LEN;
		u8 *buf = (u8 *)ring->bufs.vaddr +
			  (size_t)((idx + j) % OCTEP_DP_OQ_DESCS) *
			  OCTEP_DP_BUF_STRIDE;
		u32 chunk = min_t(u32, frame_len - copied,
				  OCTEP_DP_BUF_SIZE - offset);

		memcpy(dst + copied, buf + offset, chunk);
		copied += chunk;
	}

	return copied == frame_len;
}

static void octep_dp_cmsg_drop(struct octep *octep)
{
	unsigned long flags;

	spin_lock_irqsave(&octep->flow_stats_lock, flags);
	octep->cmsg_tag_frames++;
	octep->cmsg_dropped++;
	spin_unlock_irqrestore(&octep->flow_stats_lock, flags);
}

/* Type-1 entries hold cumulative slot counters; accumulate their deltas per connection revision. */
static void octep_flow_counter_update_locked(struct octep *octep, u32 index,
					     u16 revision,
					     const u8 *entry)
{
	struct octep_flow_counter *counter = NULL;
	unsigned int i, dir;

	lockdep_assert_held(&octep->flow_stats_lock);
	for (i = 0; i < ARRAY_SIZE(octep->flow_stats); i++) {
		if (octep->flow_stats[i].used &&
		    octep->flow_stats[i].index == index) {
			counter = &octep->flow_stats[i];
			break;
		}
		if (!counter && !octep->flow_stats[i].used)
			counter = &octep->flow_stats[i];
	}
	if (!counter) {
		octep->cmsg_untracked++;
		return;
	}
	if (!counter->used) {
		counter->used = true;
		counter->index = index;
		counter->revision = revision;
	} else if (counter->revision != revision) {
		counter->revision = revision;
		memset(counter->packets, 0, sizeof(counter->packets));
		memset(counter->bytes, 0, sizeof(counter->bytes));
		memset(counter->raw, 0, sizeof(counter->raw));
	}

	for (dir = 0; dir < 2; dir++) {
		u32 low = get_unaligned_le32(entry + 8 * dir);
		u32 high = get_unaligned_le32(entry + 8 * dir + 4);
		u64 current_bytes = ((u64)(high & 0x7) << 32) | low;
		u64 previous_bytes =
			((u64)(counter->raw[dir][1] & 0x7) << 32) |
			counter->raw[dir][0];
		u32 current_packets = high >> OCTEP_CMSG_PKT_SHIFT;
		u32 previous_packets =
			counter->raw[dir][1] >> OCTEP_CMSG_PKT_SHIFT;

		counter->bytes[dir] +=
			(current_bytes - previous_bytes) & ((1ULL << 35) - 1);
		counter->packets[dir] +=
			(current_packets - previous_packets) & OCTEP_CMSG_PKT_MASK;
		counter->raw[dir][0] = low;
		counter->raw[dir][1] = high;
	}

	counter->sequence = ++octep->flow_stats_sequence;
	counter->last_update = jiffies;
}

static void octep_dp_cmsg_rx(struct octep *octep, const u8 *frame,
			     u32 frame_len)
{
	const u8 *p, *end, *check;
	unsigned long flags;
	u32 seen = 0, i;
	u16 entries;
	u8 type, bursts;

	spin_lock_irqsave(&octep->flow_stats_lock, flags);
	octep->cmsg_tag_frames++;
	if (frame_len < ETH_HLEN + OCTEP_CMSG_HDR_LEN ||
	    get_unaligned_be16(frame + 12) != OCTEP_CMSG_ETHERTYPE) {
		octep->cmsg_malformed++;
		spin_unlock_irqrestore(&octep->flow_stats_lock, flags);
		return;
	}
	p = frame + ETH_HLEN;
	type = p[2];
	octep->cmsg_rx++;
	octep->cmsg_last_type = type;
	octep->cmsg_last_jiffies = jiffies;
	spin_unlock_irqrestore(&octep->flow_stats_lock, flags);

	if (type != OCTEP_CMSG_TYPE_CONN_STATS)
		return;
	if (p[3] != OCTEP_CMSG_VERSION)
		goto malformed;

	entries = get_unaligned_le16(p + 4);
	bursts = p[6];
	p += OCTEP_CMSG_HDR_LEN;
	end = frame + frame_len;
	check = p;
	for (i = 0; i < bursts; i++) {
		u32 header, index, count;

		if (end - check < sizeof(u32))
			goto malformed;
		header = get_unaligned_le32(check);
		check += sizeof(u32);
		index = header & OCTEP_CMSG_CONN_INDEX_MASK;
		count = (header >> OCTEP_CMSG_CONN_COUNT_SHIFT) + 1;
		if (count - 1 > OCTEP_CMSG_CONN_INDEX_MASK - index ||
		    count > (end - check) / OCTEP_CMSG_CONN_ENTRY_LEN)
			goto malformed;
		seen += count;
		check += count * OCTEP_CMSG_CONN_ENTRY_LEN;
	}
	if (seen != entries)
		goto malformed;

	spin_lock_irqsave(&octep->flow_stats_lock, flags);
	octep->cmsg_conn_stats_messages++;
	octep->cmsg_conn_stats_entries += entries;
	for (i = 0; i < bursts; i++) {
		u32 header = get_unaligned_le32(p);
		u32 index = header & OCTEP_CMSG_CONN_INDEX_MASK;
		u32 count = (header >> OCTEP_CMSG_CONN_COUNT_SHIFT) + 1;
		u32 k;

		p += sizeof(u32);
		for (k = 0; k < count; k++, p += OCTEP_CMSG_CONN_ENTRY_LEN) {
			u16 revision = get_unaligned_le16(p + 16);

			octep_flow_counter_update_locked(octep, index + k,
							 revision, p);
		}
	}
	spin_unlock_irqrestore(&octep->flow_stats_lock, flags);
	return;

malformed:
	spin_lock_irqsave(&octep->flow_stats_lock, flags);
	octep->cmsg_malformed++;
	spin_unlock_irqrestore(&octep->flow_stats_lock, flags);
}

static void octep_dp_credit_ring(struct octep *octep,
				struct octep_dp_ring *ring, u32 buffers)
{
	s32 have = (s32)lower_32_bits(octep_ring_readq(
		octep, ring->ring, OCTEP_SDP_R_OUT_SLIST_DBELL));
	s64 room;
	u64 owed = (u64)ring->oq_credit_carry + buffers;
	u32 give;

	if (!owed)
		return;
	if (have < 0)
		have = 0;
	room = (s64)OCTEP_DP_OQ_GRANT - have;
	if (room < 0)
		room = 0;
	give = min_t(u64, owed, room);
	ring->oq_credit_carry = owed - give;
	if (give)
		octep_ring_writeq(octep, ring->ring,
				  OCTEP_SDP_R_OUT_SLIST_DBELL, give);
}

static void octep_dp_poll_ring(struct octep *octep,
			       struct octep_dp_ring *ring)
{
	u32 pending, packets = 0, buffers = 0;

	pending = lower_32_bits(octep_ring_readq(octep, ring->ring,
						 OCTEP_SDP_R_OUT_CNTS));
	if (!pending) {
		if (ring->oq_credit_carry) {
			dma_wmb();
			octep_dp_credit_ring(octep, ring, 0);
		}
		return;
	}
	pending = min_t(u32, pending, OCTEP_DP_RX_BUDGET);
	dma_rmb();

	while (packets < pending) {
		struct octep_dp_port *port;
		struct sk_buff *skb = NULL;
		u8 *buf, *dst;
		u64 wire_len;
		u32 idx, span, frame_len, j;
		u16 tag;

		idx = ring->oq_rd;
		buf = (u8 *)ring->bufs.vaddr +
		      (size_t)idx * OCTEP_DP_BUF_STRIDE;
		wire_len = be64_to_cpu(READ_ONCE(*(__be64 *)buf));
		if (!wire_len || wire_len == 0xa5a5a5a5a5a5a5a5ULL ||
		    wire_len <= OCTEP_DP_RX_PREFIX_LEN - sizeof(u64))
			break;

		span = octep_dp_rx_span(wire_len);
		if (!span || span >= OCTEP_DP_OQ_DESCS)
			span = 1;
		frame_len = wire_len - (OCTEP_DP_RX_PREFIX_LEN - sizeof(u64));
		tag = get_unaligned_be16(buf + OCTEP_DP_RX_TAG_OFF);
		port = octep_dp_port_by_tag(octep, tag);

		if (tag == OCTEP_DP_CMSG_TAG) {
			u8 *frame;

			if (wire_len > OCTEP_DP_PKT_MAX +
				       OCTEP_DP_RX_PREFIX_LEN - sizeof(u64) ||
			    frame_len < ETH_HLEN) {
				octep_dp_cmsg_drop(octep);
			} else {
				frame = kmalloc(frame_len, in_serving_softirq() ? GFP_ATOMIC : GFP_KERNEL);
				if (!frame) {
					octep_dp_cmsg_drop(octep);
				} else {
					if (octep_dp_copy_frame(ring, idx, span,
								frame_len, frame))
						octep_dp_cmsg_rx(octep, frame,
								 frame_len);
					else
						octep_dp_cmsg_drop(octep);
					kfree(frame);
				}
			}
		} else if (port && frame_len >= ETH_HLEN &&
		    frame_len <= port->netdev->mtu + ETH_HLEN + VLAN_HLEN) {
			skb = netdev_alloc_skb_ip_align(port->netdev, frame_len);
			if (skb) {
				dst = skb_put(skb, frame_len);
				if (octep_dp_copy_frame(ring, idx, span,
							frame_len, dst)) {
					octep_dp_rx_flow_metadata(octep, buf, tag,
								  dst, frame_len);
					skb->protocol = eth_type_trans(skb,
								       port->netdev);
					if (netif_rx(skb) == NET_RX_DROP)
						octep_dp_count_rx(octep, port,
								  frame_len, true);
					else
						octep_dp_count_rx(octep, port,
								  frame_len, false);
				} else {
					if (octep_dp_debug)
						dev_info_ratelimited(&octep->pdev->dev,
								     "dp-debug: rx drop: frame copy failed (len %u tag 0x%04x)\n",
								     frame_len, tag);
					dev_kfree_skb_any(skb);
					octep_dp_count_rx(octep, port, 0, true);
				}
			} else {
				if (octep_dp_debug)
					dev_info_ratelimited(&octep->pdev->dev,
							     "dp-debug: rx drop: skb alloc failed (len %u tag 0x%04x)\n",
							     frame_len, tag);
				octep_dp_count_rx(octep, port, 0, true);
			}
		} else if (octep_dp_debug) {
			dev_info_ratelimited(&octep->pdev->dev,
					     "dp-debug: rx ignored: %s (len %u tag 0x%04x)\n",
					     port ? "longer than port MTU" : "no port for tag",
					     frame_len, tag);
		}

		for (j = 0; j < span; j++) {
			u8 *consumed = (u8 *)ring->bufs.vaddr +
				       (size_t)((idx + j) % OCTEP_DP_OQ_DESCS) *
				       OCTEP_DP_BUF_STRIDE;

			memset(consumed, 0xa5, OCTEP_DP_BUF_SIZE);
		}
		ring->oq_rd = (idx + span) % OCTEP_DP_OQ_DESCS;
		packets++;
		buffers += span;
	}

	if (!packets) {
		if (ring->oq_credit_carry) {
			dma_wmb();
			octep_dp_credit_ring(octep, ring, 0);
		}
		return;
	}

	dma_wmb();
	octep_dp_credit_ring(octep, ring, buffers);
	octep_ring_writeq(octep, ring->ring, OCTEP_SDP_R_OUT_CNTS, packets);
}

static void octep_dp_poll_all(struct octep *octep)
{
	unsigned long flags;
	unsigned int i;
	u32 pending;

	for (i = 0; i < READ_ONCE(octep->dp_ring_count); i++)
		octep_dp_poll_ring(octep, &octep->dp_ring[i]);

	if (octep->dp_ring_count) {
		spin_lock_irqsave(&octep->dp_tx_lock, flags);
		pending = lower_32_bits(octep_ring_readq(
			octep, octep->dp_ring[0].ring,
			OCTEP_SDP_R_IN_INSTR_DBELL));
		if (pending < OCTEP_DP_IQ_DESCS - 1) {
			u32 count = smp_load_acquire(&octep->dp_port_count);

			for (i = 0; i < count; i++)
				if (netif_queue_stopped(octep->dp_port[i].netdev))
					netif_wake_queue(octep->dp_port[i].netdev);
		}
		spin_unlock_irqrestore(&octep->dp_tx_lock, flags);
	}
}

static void octep_dp_poll_work(struct work_struct *work)
{
	struct octep *octep = container_of(to_delayed_work(work),
					   struct octep, dp_poll_work);

	if (!READ_ONCE(octep->dp_poll_enabled))
		return;

	octep_dp_poll_all(octep);

	if (READ_ONCE(octep->dp_poll_enabled))
		schedule_delayed_work(&octep->dp_poll_work,
				      msecs_to_jiffies(OCTEP_DP_POLL_MS));
}

static enum hrtimer_restart octep_dp_hrt_fn(struct hrtimer *t)
{
	struct octep *octep = container_of(t, struct octep, dp_hrt);

	napi_schedule(&octep->dp_napi);
	return HRTIMER_NORESTART;
}

static int octep_dp_napi_poll(struct napi_struct *napi, int budget)
{
	struct octep *octep = container_of(napi, struct octep, dp_napi);

	if (READ_ONCE(octep->dp_poll_enabled))
		octep_dp_poll_all(octep);
	if (napi_complete_done(napi, 0) && READ_ONCE(octep->dp_poll_enabled))
		hrtimer_start(&octep->dp_hrt, octep->dp_hrt_period, HRTIMER_MODE_REL);
	return 0;
}

/* Called after the data path started: arm the timer-driven NAPI or the delayed work. */
static void octep_dp_poll_resume(struct octep *octep)
{
	unsigned int us = READ_ONCE(octep_dp_poll_us);

	octep->dp_napi_on = false;
	if (us) {
		if (!octep->dp_napi_dev) {
			octep->dp_napi_dev = alloc_netdev_dummy(0);
			if (octep->dp_napi_dev) {
				netif_napi_add_weight(octep->dp_napi_dev, &octep->dp_napi,
						      octep_dp_napi_poll,
						      OCTEP_DP_NAPI_WEIGHT);
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 13, 0)
				hrtimer_setup(&octep->dp_hrt, octep_dp_hrt_fn,
					      CLOCK_MONOTONIC, HRTIMER_MODE_REL);
#else
				hrtimer_init(&octep->dp_hrt, CLOCK_MONOTONIC,
					     HRTIMER_MODE_REL);
				octep->dp_hrt.function = octep_dp_hrt_fn;
#endif
			}
		}
		if (octep->dp_napi_dev) {
			octep->dp_hrt_period = ns_to_ktime((u64)clamp(us, 50u, 100000u) * NSEC_PER_USEC);
			if (!octep->dp_napi_enabled) {
				napi_enable(&octep->dp_napi);
				octep->dp_napi_enabled = true;
			}
			octep->dp_napi_on = true;
			hrtimer_start(&octep->dp_hrt, octep->dp_hrt_period, HRTIMER_MODE_REL);
			return;
		}
		dev_warn(&octep->pdev->dev, "dp: NAPI host allocation failed, using delayed work\n");
	}
	schedule_delayed_work(&octep->dp_poll_work, msecs_to_jiffies(OCTEP_DP_POLL_MS));
}

/* dp_poll_enabled must already be false. */
static void octep_dp_poll_quiesce(struct octep *octep)
{
	cancel_delayed_work_sync(&octep->dp_poll_work);
	if (!octep->dp_napi_enabled)
		return;
	hrtimer_cancel(&octep->dp_hrt);
	napi_disable(&octep->dp_napi);
	hrtimer_cancel(&octep->dp_hrt);
	octep->dp_napi_enabled = false;
}

static void octep_dp_napi_destroy(struct octep *octep)
{
	octep_dp_poll_quiesce(octep);
	if (!octep->dp_napi_dev)
		return;
	netif_napi_del(&octep->dp_napi);
	free_netdev(octep->dp_napi_dev);
	octep->dp_napi_dev = NULL;
}

static void octep_dp_dbg_rings(struct octep *octep, const char *why)
{
	u32 i, n = min_t(u32, octep->dp_ring_count, 4);

	for (i = 0; i < n; i++) {
		struct octep_dp_ring *r = &octep->dp_ring[i];

		if (!r->in_configured && !r->out_configured)
			continue;
		dev_info(&octep->pdev->dev,
			 "dp-dbg: %s ring %u in_ctl=%#llx out_ctl=%#llx in_en=%#llx out_cnt=%#llx oq_rd=%u\n",
			 why, r->ring,
			 (unsigned long long)octep_ring_readq(octep, r->ring, OCTEP_SDP_R_IN_CONTROL),
			 (unsigned long long)octep_ring_readq(octep, r->ring, OCTEP_SDP_R_OUT_CONTROL),
			 (unsigned long long)octep_ring_readq(octep, r->ring, OCTEP_SDP_R_IN_ENABLE),
			 (unsigned long long)octep_ring_readq(octep, r->ring, OCTEP_SDP_R_OUT_CNTS),
			 r->oq_rd);
	}
}

static int octep_dp_open(struct net_device *netdev)
{
	struct octep_netdev_priv *priv = netdev_priv(netdev);
	struct octep *octep = priv->octep;

	if (!READ_ONCE(octep->dp_io_enabled) || !READ_ONCE(octep->hs_done)) {
		if (octep_dp_dbg & 1)
			dev_info(&octep->pdev->dev,
				 "dp-dbg: %s open refused io_enabled=%d hs_done=%d\n",
				 netdev->name, READ_ONCE(octep->dp_io_enabled),
				 READ_ONCE(octep->hs_done));
		return -ENETDOWN;
	}
	if (octep_dp_dbg & 1)
		octep_dp_dbg_rings(octep, netdev->name);
	netif_carrier_on(netdev);
	netif_start_queue(netdev);
	return 0;
}

static int octep_dp_stop(struct net_device *netdev)
{
	struct octep_netdev_priv *priv = netdev_priv(netdev);
	struct octep *octep = priv->octep;

	netif_stop_queue(netdev);
	netif_carrier_off(netdev);
	if (octep_dp_dbg & 2) {
		unsigned int i;
		u32 r;
		bool busy = true;

		for (i = 0; i < 20 && busy; i++) {
			busy = false;
			for (r = 0; r < min_t(u32, octep->dp_ring_count, 4); r++) {
				struct octep_dp_ring *ring = &octep->dp_ring[r];

				if (ring->in_configured &&
				    !(octep_ring_readq(octep, ring->ring, OCTEP_SDP_R_IN_CONTROL) &
				      OCTEP_R_IN_CTL_IDLE))
					busy = true;
			}
			if (busy)
				usleep_range(1000, 1500);
		}
		dev_info(&octep->pdev->dev, "dp-dbg: %s stop drain %s after %u polls\n",
			 netdev->name, busy ? "TIMED OUT" : "ok", i);
		octep_dp_dbg_rings(octep, "stop");
	}
	return 0;
}

static netdev_tx_t octep_dp_xmit(struct sk_buff *skb,
				 struct net_device *netdev)
{
	struct octep_netdev_priv *priv = netdev_priv(netdev);
	struct octep_dp_port *port = priv->port;
	struct octep *octep = priv->octep;
	struct octep_dp_ring *ring;
	unsigned long flags, stats_flags;
	u8 *buf;
	u32 slot, len, wire_len, pending;
	int err;

	if (skb->ip_summed == CHECKSUM_PARTIAL && skb_checksum_help(skb)) {
		dev_kfree_skb_any(skb);
		spin_lock_irqsave(&octep->dp_stats_lock, stats_flags);
		port->stats.tx_dropped++;
		spin_unlock_irqrestore(&octep->dp_stats_lock, stats_flags);
		return NETDEV_TX_OK;
	}
	len = skb->len;
	if ((octep_dp_dbg & 8) && (skb_is_nonlinear(skb) || skb_shinfo(skb)->gso_size))
		net_ratelimited_function(dev_info, &octep->pdev->dev,
					 "dp-dbg: %s tx sg skb len=%u frags=%u frag_list=%d gso=%u\n",
					 netdev->name, len, skb_shinfo(skb)->nr_frags,
					 !!skb_has_frag_list(skb), skb_shinfo(skb)->gso_size);
	if (len < ETH_HLEN ||
	    len > netdev->mtu + ETH_HLEN + VLAN_HLEN ||
	    len + OCTEP_DP_TAG_LEN > OCTEP_DP_TXBUF_SIZE) {
		if (octep_dp_debug)
			dev_info_ratelimited(&octep->pdev->dev,
					     "dp-debug: %s tx drop: bad length %u (mtu %u, slot room %zu)\n",
					     netdev->name, len, netdev->mtu,
					     (size_t)OCTEP_DP_TXBUF_SIZE - OCTEP_DP_TAG_LEN);
		spin_lock_irqsave(&octep->dp_stats_lock, stats_flags);
		port->stats.tx_dropped++;
		spin_unlock_irqrestore(&octep->dp_stats_lock, stats_flags);
		dev_kfree_skb_any(skb);
		return NETDEV_TX_OK;
	}

	spin_lock_irqsave(&octep->dp_tx_lock, flags);
	if (!READ_ONCE(octep->dp_io_enabled) || !octep->dp_ring_count) {
		spin_unlock_irqrestore(&octep->dp_tx_lock, flags);
		return NETDEV_TX_BUSY;
	}
	ring = &octep->dp_ring[0];
	pending = lower_32_bits(octep_ring_readq(
		octep, ring->ring, OCTEP_SDP_R_IN_INSTR_DBELL));
	if (pending >= OCTEP_DP_IQ_DESCS - 1) {
		netif_stop_queue(netdev);
		spin_unlock_irqrestore(&octep->dp_tx_lock, flags);
		return NETDEV_TX_BUSY;
	}

	slot = octep->dp_tx_prod;
	buf = (u8 *)ring->txbuf.vaddr +
	      (size_t)slot * OCTEP_DP_TXBUF_STRIDE;
	memset(buf, 0, OCTEP_DP_TAG_LEN);
	put_unaligned_be16(port->tag, buf);
	buf[OCTEP_DP_PPORT_HLEN] = 1;
	wire_len = max_t(u32, len, OCTEP_DP_MIN_FRAME);
	memset(buf + OCTEP_DP_TAG_LEN + len, 0, wire_len - len);
	err = skb_copy_bits(skb, 0, buf + OCTEP_DP_TAG_LEN, len);
	if (err) {
		spin_unlock_irqrestore(&octep->dp_tx_lock, flags);
		spin_lock_irqsave(&octep->dp_stats_lock, stats_flags);
		port->stats.tx_dropped++;
		spin_unlock_irqrestore(&octep->dp_stats_lock, stats_flags);
		dev_kfree_skb_any(skb);
		return NETDEV_TX_OK;
	}

	octep_dp_build_instr(ring, slot,
			     ring->txbuf.dma_addr +
			     (dma_addr_t)slot * OCTEP_DP_TXBUF_STRIDE,
			     OCTEP_DP_TAG_LEN + wire_len, port->iface);
	dma_wmb();
	octep->dp_tx_prod = (slot + 1) % OCTEP_DP_IQ_DESCS;
	octep_ring_writeq(octep, ring->ring,
			  OCTEP_SDP_R_IN_INSTR_DBELL, 1);
	pending++;
	if (pending >= OCTEP_DP_IQ_DESCS - 1)
		netif_stop_queue(netdev);
	spin_unlock_irqrestore(&octep->dp_tx_lock, flags);

	spin_lock_irqsave(&octep->dp_stats_lock, stats_flags);
	port->stats.tx_packets++;
	port->stats.tx_bytes += len;
	spin_unlock_irqrestore(&octep->dp_stats_lock, stats_flags);
	netif_trans_update(netdev);
	dev_kfree_skb_any(skb);
	return NETDEV_TX_OK;
}

static void octep_dp_get_stats64(struct net_device *netdev,
				 struct rtnl_link_stats64 *stats)
{
	struct octep_netdev_priv *priv = netdev_priv(netdev);
	unsigned long flags;

	spin_lock_irqsave(&priv->octep->dp_stats_lock, flags);
	*stats = priv->port->stats;
	spin_unlock_irqrestore(&priv->octep->dp_stats_lock, flags);
}

static LIST_HEAD(octep_ft_block_cb_list);

/*
 * nftables flowtable hardware-offload requests. Each direction of a flow
 * arrives as its own FLOW_CLS_REPLACE. With flow_offload=1 the tuple, NAT
 * rewrite and next hop are recorded, and a worker programs the NPU once the
 * firmware offers a busy candidate for the reply direction. Anything the NPU
 * cannot deliver (egress not an octep port, non-TCP/UDP, IPv6) is declined and
 * stays in the software fast path.
 */
static int octep_ft_add(struct net_device *netdev,
			struct flow_cls_offload *f);
static int octep_ft_del(struct net_device *netdev,
			struct flow_cls_offload *f);

static const struct net_device_ops octep_dp_netdev_ops;

static int octep_ft_cb(enum tc_setup_type type, void *type_data, void *cb_priv)
{
	struct flow_cls_offload *f = type_data;
	struct net_device *netdev = cb_priv;

	if (type != TC_SETUP_CLSFLOWER)
		return -EOPNOTSUPP;
	switch (f->command) {
	case FLOW_CLS_REPLACE:
		return octep_ft_add(netdev, f);
	case FLOW_CLS_DESTROY:
		return octep_ft_del(netdev, f);
	case FLOW_CLS_STATS:
		return 0;
	default:
		return -EOPNOTSUPP;
	}
}

static int octep_dp_setup_tc(struct net_device *netdev,
			     enum tc_setup_type type, void *type_data)
{
	if (type != TC_SETUP_FT)
		return -EOPNOTSUPP;
	return flow_block_cb_setup_simple(type_data, &octep_ft_block_cb_list,
					  octep_ft_cb, netdev, netdev, true);
}

static const struct net_device_ops octep_dp_netdev_ops = {
	.ndo_open		= octep_dp_open,
	.ndo_stop		= octep_dp_stop,
	.ndo_start_xmit		= octep_dp_xmit,
	.ndo_get_stats64	= octep_dp_get_stats64,
	.ndo_setup_tc		= octep_dp_setup_tc,
	.ndo_set_mac_address	= eth_mac_addr,
	.ndo_validate_addr	= eth_validate_addr,
};

static int octep_dp_alloc_ring(struct octep *octep,
			       struct octep_dp_ring *ring, u32 ring_id,
			       bool with_instr)
{
	__le64 *entries;
	unsigned int i;
	int err;

	ring->ring = ring_id;
	if (with_instr) {
		err = octep_dma_alloc(octep, &ring->instr,
				      OCTEP_DP_IQ_DESCS * OCTEP_DP_INSTR_SIZE);
		if (err)
			return err;
		err = octep_dma_alloc(octep, &ring->txbuf,
				      OCTEP_DP_IQ_DESCS * OCTEP_DP_TXBUF_STRIDE);
		if (err)
			return err;
		memset(ring->txbuf.vaddr, 0, ring->txbuf.size);
	}

	err = octep_dma_alloc(octep, &ring->slist,
			      OCTEP_DP_OQ_DESCS * OCTEP_DP_SLIST_ENTRY);
	if (err)
		return err;
	err = octep_dma_alloc(octep, &ring->bufs,
			      OCTEP_DP_OQ_DESCS * OCTEP_DP_BUF_STRIDE);
	if (err)
		return err;
	err = octep_dma_alloc(octep, &ring->info,
			      OCTEP_DP_OQ_DESCS * OCTEP_DP_OQ_INFO_SIZE);
	if (err)
		return err;

	memset(ring->bufs.vaddr, 0xa5, ring->bufs.size);
	memset(ring->info.vaddr, 0, ring->info.size);
	entries = ring->slist.vaddr;
	for (i = 0; i < OCTEP_DP_OQ_DESCS; i++) {
		entries[i * 2] = cpu_to_le64(ring->bufs.dma_addr +
					     (dma_addr_t)i *
					     OCTEP_DP_BUF_STRIDE);
		entries[i * 2 + 1] = cpu_to_le64(ring->info.dma_addr +
						 (dma_addr_t)i *
						 OCTEP_DP_OQ_INFO_SIZE);
	}
	dma_wmb();
	return 0;
}

static int octep_wait_ring_idle(struct octep *octep, u32 ring, bool output)
{
	u32 control = output ? OCTEP_SDP_R_OUT_CONTROL :
			       OCTEP_SDP_R_IN_CONTROL;
	u64 idle = output ? OCTEP_R_OUT_CTL_IDLE : OCTEP_R_IN_CTL_IDLE;
	unsigned int i;

	for (i = 0; i < OCTEP_DP_IDLE_TRIES; i++) {
		if (octep_ring_readq(octep, ring, control) & idle)
			return 0;
		usleep_range(1000, 1500);
	}

	dev_err(&octep->pdev->dev,
		"dp: ring %u %s never went idle (control=%#018llx)\n",
		ring, output ? "output" : "input",
		(unsigned long long)octep_ring_readq(octep, ring, control));
	return -ETIMEDOUT;
}

static int octep_dp_ring_available(struct octep *octep, u32 ring,
				   bool check_input)
{
	u64 value;

	if (octep_ring_readq(octep, ring, OCTEP_SDP_R_OUT_CONTROL) ==
	    U64_MAX)
		return -ENXIO;
	if (!(octep_ring_readq(octep, ring, OCTEP_SDP_R_OUT_CONTROL) &
	      OCTEP_R_OUT_CTL_IDLE) ||
	    (octep_ring_readq(octep, ring, OCTEP_SDP_R_OUT_ENABLE) & 1) ||
	    octep_ring_readq(octep, ring, OCTEP_SDP_R_OUT_SLIST_BADDR)) {
		dev_err(&octep->pdev->dev,
			"dp: output ring %u is busy or already configured; refusing to overwrite it\n",
			ring);
		return -EBUSY;
	}

	if (!check_input)
		return 0;
	value = octep_ring_readq(octep, ring, OCTEP_SDP_R_IN_CONTROL);
	if (value == U64_MAX)
		return -ENXIO;
	if (!(value & OCTEP_R_IN_CTL_IDLE) ||
	    (octep_ring_readq(octep, ring, OCTEP_SDP_R_IN_ENABLE) & 1) ||
	    octep_ring_readq(octep, ring, OCTEP_SDP_R_IN_INSTR_BADDR)) {
		dev_err(&octep->pdev->dev,
			"dp: input ring %u is busy or already configured; refusing to overwrite it\n",
			ring);
		return -EBUSY;
	}
	return 0;
}

static int octep_dp_configure_output(struct octep *octep,
				     struct octep_dp_ring *ring)
{
	u64 value;
	int err;

	err = octep_wait_ring_idle(octep, ring->ring, true);
	if (err)
		return err;

	ring->out_configured = true;
	octep_ring_writeq(octep, ring->ring, OCTEP_SDP_R_OUT_SLIST_BADDR,
			  ring->slist.dma_addr);
	octep_ring_writeq(octep, ring->ring, OCTEP_SDP_R_OUT_SLIST_RSIZE,
			  OCTEP_DP_OQ_DESCS);
	value = octep_ring_readq(octep, ring->ring, OCTEP_SDP_R_OUT_CONTROL);
	value &= ~(OCTEP_R_OUT_CTL_SIZE_MASK | OCTEP_R_OUT_CTL_ATTR_MASK);
	value |= OCTEP_R_OUT_CTL_ES_P | OCTEP_DP_BUF_SIZE;
	octep_ring_writeq(octep, ring->ring, OCTEP_SDP_R_OUT_CONTROL, value);
	octep_ring_writeq(octep, ring->ring, OCTEP_SDP_R_OUT_INT_LEVELS,
			  ((u64)octep->dp_time_threshold << 32) |
			  OCTEP_DP_OQ_INTR_PKT);
	return 0;
}

static void octep_dp_enable_output(struct octep *octep,
				  struct octep_dp_ring *ring,
				  bool sibling)
{
	u64 enable;
	u32 grant = OCTEP_DP_OQ_DESCS + OCTEP_DP_OQ_WMARK -
		    OCTEP_DP_OQ_FETCH;

	dma_wmb();
	octep_ring_writeq(octep, ring->ring, OCTEP_SDP_R_OUT_SLIST_DBELL,
			  U32_MAX);
	enable = octep_ring_readq(octep, ring->ring, OCTEP_SDP_R_OUT_ENABLE);
	octep_ring_writeq(octep, ring->ring, OCTEP_SDP_R_OUT_ENABLE,
			  enable | 1);
	wmb();
	octep_ring_writeq(octep, ring->ring, OCTEP_SDP_R_OUT_SLIST_DBELL,
			  grant);

	if (sibling)
		dev_info(&octep->pdev->dev,
			 "dp: sibling ring %u armed - oq %u x %u B every %u B at %pad, "
			 "slist at %pad, out_control %#018llx\n",
			 ring->ring, OCTEP_DP_OQ_DESCS, OCTEP_DP_BUF_SIZE,
			 OCTEP_DP_BUF_STRIDE, &ring->bufs.dma_addr,
			 &ring->slist.dma_addr,
			 (unsigned long long)octep_ring_readq(octep, ring->ring,
							      OCTEP_SDP_R_OUT_CONTROL));
	else
		dev_info(&octep->pdev->dev,
			 "dp: output ring %u armed - oq %u x %u B every %u B at %pad, "
			 "slist at %pad, out_control %#018llx\n",
			 ring->ring, OCTEP_DP_OQ_DESCS, OCTEP_DP_BUF_SIZE,
			 OCTEP_DP_BUF_STRIDE, &ring->bufs.dma_addr,
			 &ring->slist.dma_addr,
			 (unsigned long long)octep_ring_readq(octep, ring->ring,
							      OCTEP_SDP_R_OUT_CONTROL));
}

static int octep_dp_stop_locked(struct octep *octep, bool force);

static int octep_dp_start_locked(struct octep *octep)
{
	struct octep_sdp_rinfo rinfo;
	struct octep_dp_ring *ring;
	u64 scratch, value;
	u32 i, base_ring;
	int err;

	lockdep_assert_held(&octep->lock);
	if (octep->dp_up)
		return -EALREADY;
	if (!octep->ready)
		return -EAGAIN;

	scratch = readq(octep->bar0 + OCTEP_SLI_EPF_SCRATCH);
	if (scratch) {
		dev_err(&octep->pdev->dev,
			"dp: SLI_EPF_SCRATCH is %#018llx; the target may own the rings, refusing to arm\n",
			(unsigned long long)scratch);
		return -EBUSY;
	}

	rinfo = octep_read_sdp_rinfo(octep);
	if (rinfo.value == U64_MAX)
		return -ENXIO;
	err = octep_sdp_prepare_vfs_locked(octep, &rinfo, &base_ring);
	if (err)
		return err;
	if (rinfo.pf_rings < OCTEP_DP_RING_COUNT) {
		dev_err(&octep->pdev->dev,
			"dp: this PF setup needs %u rings; RINFO is %#018llx\n",
			OCTEP_DP_RING_COUNT, (unsigned long long)rinfo.value);
		return -EINVAL;
	}
	if (base_ring + OCTEP_DP_RING_COUNT > rinfo.bar0_rings ||
	    base_ring + OCTEP_DP_RING_COUNT > 64)
		return -ENXIO;

	for (i = 0; i < OCTEP_DP_RING_COUNT; i++) {
		err = octep_dp_ring_available(octep, base_ring + i, i == 0);
		if (err)
			return err;
	}
	err = dma_set_mask_and_coherent(&octep->pdev->dev, DMA_BIT_MASK(64));
	if (err) {
		dev_err(&octep->pdev->dev,
			"dp: endpoint does not support 64-bit coherent DMA: %d\n",
			err);
		return err;
	}

	for (i = 0; i < OCTEP_DP_RING_COUNT; i++) {
		ring = &octep->dp_ring[i];
		octep->dp_ring_count = i + 1;
		err = octep_dp_alloc_ring(octep, ring, base_ring + i, i == 0);
		if (err)
			goto free_allocations;
		ring->oq_rd = 0;
		ring->oq_credit_carry = 0;
	}

	pci_set_master(octep->pdev);
	octep->dp_up = true;
	octep->dp_time_threshold =
		(u32)(((u64)octep->sdp_coproc_ticks_per_us *
		       OCTEP_DP_OQ_INTR_TIME) / 1024);
	dev_info(&octep->pdev->dev,
		 "dp: this instance has not seen the EP-mode handshake and the target reports no started port - normal before the fast path runs, and unknowable after a reload, so carrying on\n");

	ring = &octep->dp_ring[0];
	err = octep_wait_ring_idle(octep, ring->ring, false);
	if (err)
		goto stop_on_error;
	value = octep_ring_readq(octep, ring->ring, OCTEP_SDP_R_IN_CONTROL);
	value |= OCTEP_R_IN_CTL_RDSIZE | OCTEP_R_IN_CTL_IS_64B |
		 OCTEP_R_IN_CTL_ESR;
	octep_ring_writeq(octep, ring->ring, OCTEP_SDP_R_IN_CONTROL, value);
	octep_ring_writeq(octep, ring->ring, OCTEP_SDP_R_IN_INSTR_BADDR,
			  ring->instr.dma_addr);
	octep_ring_writeq(octep, ring->ring, OCTEP_SDP_R_IN_INSTR_RSIZE,
			  OCTEP_DP_IQ_DESCS);
	octep_ring_writeq(octep, ring->ring, OCTEP_SDP_R_IN_INT_LEVELS,
			  U32_MAX);
	ring->in_configured = true;

	for (i = 0; i < OCTEP_DP_RING_COUNT; i++) {
		err = octep_dp_configure_output(octep, &octep->dp_ring[i]);
		if (err)
			goto stop_on_error;
	}

	octep_ring_writeq(octep, ring->ring, OCTEP_SDP_R_IN_INSTR_DBELL,
			  U32_MAX);
	for (i = 0; i < OCTEP_DP_IDLE_TRIES; i++) {
		if (!(octep_ring_readq(octep, ring->ring,
				       OCTEP_SDP_R_IN_INSTR_DBELL) & U32_MAX))
			break;
		udelay(10);
	}
	if (i == OCTEP_DP_IDLE_TRIES) {
		dev_err(&octep->pdev->dev,
			"dp: input ring %u doorbell did not drain\n", ring->ring);
		err = -ETIMEDOUT;
		goto stop_on_error;
	}
	value = octep_ring_readq(octep, ring->ring, OCTEP_SDP_R_IN_ENABLE);
	octep_ring_writeq(octep, ring->ring, OCTEP_SDP_R_IN_ENABLE, value | 1);

	for (i = 0; i < OCTEP_DP_RING_COUNT; i++)
		octep_dp_enable_output(octep, &octep->dp_ring[i], i != 0);

	dev_info(&octep->pdev->dev,
		 "dp: ring %u up - iq %u x %u B at %pad, oq %u x %u B every %u B at %pad, "
		 "slist at %pad, oq time threshold %u\n",
		 ring->ring, OCTEP_DP_IQ_DESCS, OCTEP_DP_INSTR_SIZE,
		 &ring->instr.dma_addr, OCTEP_DP_OQ_DESCS, OCTEP_DP_BUF_SIZE,
		 OCTEP_DP_BUF_STRIDE, &ring->bufs.dma_addr,
		 &ring->slist.dma_addr, octep->dp_time_threshold);
	if (!octep->sdp_coproc_ticks_per_us)
		dev_info(&octep->pdev->dev,
			 "dp: the target's tick rate is unknown, so the output interrupt time threshold is 0 - harmless while nothing uses interrupts. It arrives with the handshake and a module reload loses it; set sdp_coproc_ticks_per_us to restore it\n");
	dev_info(&octep->pdev->dev,
		 "dp: %u receive-only sibling rings armed beside ring %u\n",
		 OCTEP_DP_RING_COUNT - 1, ring->ring);
	WRITE_ONCE(octep->dp_tx_prod, 0);
	WRITE_ONCE(octep->dp_io_enabled, true);
	dev_info(&octep->pdev->dev,
		 "dp: ring setup complete; bounded RX polling is enabled\n");
	return 0;

stop_on_error:
	if (octep_dp_stop_locked(octep, false))
		dev_err(&octep->pdev->dev,
			"dp: setup failed and DMA memory remains allocated because the hardware did not quiesce\n");
	return err;

free_allocations:
	octep_dp_free_allocations(octep);
	return err;
}

static int octep_dp_stop_locked(struct octep *octep, bool force)
{
	unsigned int i;
	bool pending_drained = true;
	int err = 0;

	lockdep_assert_held(&octep->lock);
	if (!octep->dp_up)
		return 0;
	if (!force && (octep->hs_done ||
		       readq(octep->bar0 + OCTEP_SLI_EPF_SCRATCH))) {
		dev_err(&octep->pdev->dev,
			"dp: refusing to free DMA rings after the handshake; reboot the coprocessor before stopping them\n");
		return -EBUSY;
	}

	WRITE_ONCE(octep->dp_io_enabled, false);
	for (i = 0; i < smp_load_acquire(&octep->dp_port_count); i++)
		netif_stop_queue(octep->dp_port[i].netdev);

	if (force) {
		pci_clear_master(octep->pdev);
		pending_drained =
			pci_wait_for_pending_transaction(octep->pdev);
		if (!pending_drained)
			dev_warn(&octep->pdev->dev,
				 "dp: pending DMA did not quiesce during forced detach; retaining coherent buffers\n");
	}

	for (i = 0; i < octep->dp_ring_count; i++) {
		struct octep_dp_ring *ring = &octep->dp_ring[i];

		if (ring->out_configured)
			octep_ring_writeq(octep, ring->ring,
					  OCTEP_SDP_R_OUT_ENABLE, 0);
		if (ring->in_configured)
			octep_ring_writeq(octep, ring->ring,
					  OCTEP_SDP_R_IN_ENABLE, 0);
	}
	wmb();

	for (i = 0; i < octep->dp_ring_count; i++) {
		struct octep_dp_ring *ring = &octep->dp_ring[i];

		if (ring->out_configured) {
			if (octep_wait_ring_idle(octep, ring->ring, true)) {
				err = -EBUSY;
			} else {
				octep_ring_writeq(octep, ring->ring,
						  OCTEP_SDP_R_OUT_SLIST_BADDR, 0);
				octep_ring_writeq(octep, ring->ring,
						  OCTEP_SDP_R_OUT_SLIST_RSIZE, 0);
				ring->out_configured = false;
			}
		}
		if (ring->in_configured) {
			if (octep_wait_ring_idle(octep, ring->ring, false)) {
				err = -EBUSY;
			} else {
				octep_ring_writeq(octep, ring->ring,
						  OCTEP_SDP_R_IN_INSTR_BADDR, 0);
				octep_ring_writeq(octep, ring->ring,
						  OCTEP_SDP_R_IN_INSTR_RSIZE, 0);
				ring->in_configured = false;
			}
		}
	}

	if (err && !force)
		return err;
	if (!force) {
		pci_clear_master(octep->pdev);
		if (!pci_wait_for_pending_transaction(octep->pdev)) {
			dev_err(&octep->pdev->dev,
				"dp: pending DMA did not quiesce; retaining coherent buffers\n");
			return -EBUSY;
		}
	}
	if (force && !pending_drained) {
		octep->dp_up = false;
		WRITE_ONCE(octep->dp_io_enabled, false);
		return 0;
	}
	if (force && err)
		dev_warn(&octep->pdev->dev,
			 "dp: forced detach left stale ring registers; PCI bus mastering is disabled\n");
	octep_dp_free_allocations(octep);
	octep_dma_free(octep, &octep->rpc_cmd);
	octep->rpc_ready = false;
	octep->rpc_allow_write = false;
	octep->rpc_platform_known = false;
	octep->rpc_lif_read_valid = false;
	octep->rpc_mflow_read_valid = false;
	octep->rpc_conn_read_valid = false;
	octep->rpc_conn_reclaim_valid = false;
	octep->rpc_conn_reclaim_verified = false;
	octep->dp_up = false;
	return 0;
}

static u32 octep_mgmt_descq(const struct octep *octep, bool rx)
{
	return octep->facility[OCTEP_FCLT_MGMT].offset +
	       (rx ? OCTEP_MGMT_RX_DESCQ_OFF : OCTEP_MGMT_TX_DESCQ_OFF);
}

static void octep_mgmt_write_desc(struct octep *octep, u32 descq, u32 index,
				  u64 header, dma_addr_t dma_addr)
{
	void __iomem *desc = octep->bar2 + descq + OCTEP_MGMT_DESC_HEADER_SIZE +
			     (resource_size_t)index * OCTEP_MGMT_DESC_SIZE;

	writeq(cpu_to_le64(header), desc);
	writeq(cpu_to_le64(dma_addr), desc + sizeof(u64));
}

static void octep_mgmt_publish_descq(struct octep *octep, u32 descq, u32 prod,
				     u32 buf_size, dma_addr_t shadow_cons)
{
	writel(0, octep->bar2 + descq + 4);
	writel(OCTEP_MGMT_RING_ENTRIES, octep->bar2 + descq + 8);
	writel(buf_size, octep->bar2 + descq + 12);
	writeq(shadow_cons, octep->bar2 + descq + 16);
	writeq(0, octep->bar2 + descq + 24);
	wmb();
	writel(prod, octep->bar2 + descq);
}

static void octep_mgmt_send_mbox(struct octep *octep, u8 opcode)
{
	u64 header;

	octep->mgmt_mbox_id++;
	header = opcode | ((u64)(octep->mgmt_mbox_id & 0xff) << 8);
	writeq(header, octep->bar2 +
	       octep->facility[OCTEP_FCLT_MGMT].offset +
	       OCTEP_MGMT_HOST_MBOX_OFF);
}

static void octep_mgmt_set_host_status(struct octep *octep, u32 status)
{
	writeq(status, octep->bar2 +
	       octep->facility[OCTEP_FCLT_MGMT].offset +
	       OCTEP_MGMT_HOST_STATUS_OFF);
	wmb();
	octep_mgmt_send_mbox(octep, OCTEP_MGMT_STATUS_CHANGE);
	octep->mgmt_host_status = status;
}

static void octep_mgmt_ring_doorbell(struct octep *octep)
{
	wmb();
	writel(octep->mgmt_dbell, octep->bar2 + octep->gicd_offset);
}

static int octep_mgmt_start(struct octep *octep)
{
	const struct octep_facility *facility =
		&octep->facility[OCTEP_FCLT_MGMT];
	u64 required, target;
	unsigned int i;
	unsigned long flags;
	int err;

	lockdep_assert_held(&octep->lock);
	if (!octep->ready || !facility->size || !facility->dbell_count)
		return -ENXIO;
	if (octep->mgmt_active)
		return -EALREADY;

	required = (u64)OCTEP_MGMT_RX_DESCQ_OFF + OCTEP_MGMT_DESC_HEADER_SIZE +
		  (u64)OCTEP_MGMT_RING_ENTRIES * OCTEP_MGMT_DESC_SIZE;
	if (facility->size < required ||
	    octep->gicd_offset > octep->bar2_len - sizeof(u32))
		return -EINVAL;

	target = readq(octep->bar2 + facility->offset +
		       OCTEP_MGMT_TARGET_STATUS_OFF);
	if (target != OCTEP_MGMT_TARGET_READY) {
		dev_warn(&octep->pdev->dev,
			 "mgmt: target status is %llu, not READY; refusing to publish rings\n",
			 (unsigned long long)target);
		return -EBUSY;
	}

	err = dma_set_mask_and_coherent(&octep->pdev->dev, DMA_BIT_MASK(64));
	if (err)
		return err;
	err = octep_dma_alloc(octep, &octep->mgmt_shadow,
			      OCTEP_MGMT_SHADOW_SIZE);
	if (err)
		return err;
	err = octep_dma_alloc(octep, &octep->mgmt_rxbuf,
			      OCTEP_MGMT_RING_ENTRIES * OCTEP_MGMT_BUF_SIZE);
	if (err)
		goto err_shadow;
	err = octep_dma_alloc(octep, &octep->mgmt_txbuf,
			      OCTEP_MGMT_RING_ENTRIES * OCTEP_MGMT_BUF_SIZE);
	if (err)
		goto err_rxbuf;

	memset(octep->mgmt_shadow.vaddr, 0, octep->mgmt_shadow.size);
	memset(octep->mgmt_rxbuf.vaddr, 0, octep->mgmt_rxbuf.size);
	memset(octep->mgmt_txbuf.vaddr, 0, octep->mgmt_txbuf.size);
	octep->mgmt_tx_cons_shadow = octep->mgmt_shadow.vaddr;
	octep->mgmt_rx_cons_shadow =
		(__le32 *)((u8 *)octep->mgmt_shadow.vaddr + 64);
	octep->mgmt_tx_descq = octep_mgmt_descq(octep, false);
	octep->mgmt_rx_descq = octep_mgmt_descq(octep, true);
	octep->mgmt_dbell = facility->dbell_start;
	octep->mgmt_tx_prod = 0;
	octep->mgmt_rx_prod = OCTEP_MGMT_RING_MASK;
	octep->mgmt_rx_cons = 0;
	octep->mgmt_poll_ticks = 0;
	octep->mgmt_target_fatal_logged = false;
	memset(&octep->mgmt_stats, 0, sizeof(octep->mgmt_stats));

	for (i = 0; i < OCTEP_MGMT_RING_MASK; i++)
		octep_mgmt_write_desc(octep, octep->mgmt_rx_descq, i, 0,
				      octep->mgmt_rxbuf.dma_addr +
				      (dma_addr_t)i * OCTEP_MGMT_BUF_SIZE);

	pci_set_master(octep->pdev);
	spin_lock_irqsave(&octep->mgmt_lock, flags);
	writel(1, octep->bar2 + facility->offset + OCTEP_MGMT_HOST_INTR_OFF);
	octep_mgmt_publish_descq(octep, octep->mgmt_tx_descq, 0, 0,
				 octep->mgmt_shadow.dma_addr);
	octep_mgmt_publish_descq(octep, octep->mgmt_rx_descq,
				 octep->mgmt_rx_prod, OCTEP_MGMT_BUF_SIZE,
				 octep->mgmt_shadow.dma_addr + 64);
	wmb();
	octep_mgmt_set_host_status(octep, OCTEP_MGMT_HOST_READY);
	octep->mgmt_active = true;
	spin_unlock_irqrestore(&octep->mgmt_lock, flags);

	dev_info(&octep->pdev->dev,
		 "mgmt: published %u-entry TX/RX rings with %u-byte buffers\n",
		 OCTEP_MGMT_RING_ENTRIES, OCTEP_MGMT_BUF_SIZE);
	return 0;

err_rxbuf:
	octep_dma_free(octep, &octep->mgmt_rxbuf);
err_shadow:
	octep_dma_free(octep, &octep->mgmt_shadow);
	octep->mgmt_tx_cons_shadow = NULL;
	octep->mgmt_rx_cons_shadow = NULL;
	return err;
}

static void octep_mgmt_drain_rx_locked(struct octep *octep,
				       struct sk_buff_head *received)
{
	struct net_device *netdev = octep->mgmt_netdev;
	u32 cons, done = 0;

	if (!octep->mgmt_rx_cons_shadow)
		return;

	cons = le32_to_cpu(READ_ONCE(*octep->mgmt_rx_cons_shadow)) &
	       OCTEP_MGMT_RING_MASK;
	dma_rmb();
	while (octep->mgmt_rx_cons != cons && done < OCTEP_MGMT_RX_BUDGET) {
		u32 index = octep->mgmt_rx_cons;
		void __iomem *desc = octep->bar2 + octep->mgmt_rx_descq +
				     OCTEP_MGMT_DESC_HEADER_SIZE +
				     (resource_size_t)index * OCTEP_MGMT_DESC_SIZE;
		u64 header = le64_to_cpu((__le64)readq(desc));
		u32 len = (header >> 48) & 0xffff;
		struct sk_buff *skb = NULL;
		void *buf = (u8 *)octep->mgmt_rxbuf.vaddr +
			    (size_t)index * OCTEP_MGMT_BUF_SIZE;

		if (!len)
			len = (header >> 30) & 0xffff;
		if (len >= ETH_HLEN && len <= OCTEP_MGMT_BUF_SIZE) {
			skb = netdev_alloc_skb_ip_align(netdev, len);
			if (skb) {
				skb_put_data(skb, buf, len);
				skb->dev = netdev;
				skb_queue_tail(received, skb);
				octep->mgmt_stats.rx_packets++;
				octep->mgmt_stats.rx_bytes += len;
			} else {
				octep->mgmt_stats.rx_dropped++;
			}
		} else {
			octep->mgmt_stats.rx_errors++;
		}

		octep_mgmt_write_desc(octep, octep->mgmt_rx_descq, index, 0,
				      octep->mgmt_rxbuf.dma_addr +
				      (dma_addr_t)index * OCTEP_MGMT_BUF_SIZE);
		octep->mgmt_rx_cons = (index + 1) & OCTEP_MGMT_RING_MASK;
		octep->mgmt_rx_prod = (octep->mgmt_rx_prod + 1) &
				      OCTEP_MGMT_RING_MASK;
		done++;
	}
	if (done) {
		dma_wmb();
		writel(octep->mgmt_rx_prod,
		       octep->bar2 + octep->mgmt_rx_descq);
	}
}

static void octep_mgmt_poll_work(struct work_struct *work)
{
	struct octep *octep = container_of(to_delayed_work(work),
					   struct octep, mgmt_poll_work);
	struct sk_buff_head received;
	struct sk_buff *skb;
	unsigned long flags;
	bool carrier_on = false;
	u64 target;

	skb_queue_head_init(&received);
	spin_lock_irqsave(&octep->mgmt_lock, flags);
	if (!octep->mgmt_active) {
		spin_unlock_irqrestore(&octep->mgmt_lock, flags);
		return;
	}

	if (++octep->mgmt_poll_ticks >= OCTEP_MGMT_STATUS_TICKS) {
		octep->mgmt_poll_ticks = 0;
		target = readq(octep->bar2 +
			       octep->facility[OCTEP_FCLT_MGMT].offset +
			       OCTEP_MGMT_TARGET_STATUS_OFF);
		if (target == OCTEP_MGMT_TARGET_RUNNING &&
		    octep->mgmt_host_status == OCTEP_MGMT_HOST_READY) {
			octep_mgmt_set_host_status(octep, OCTEP_MGMT_HOST_RUNNING);
			octep->mgmt_target_fatal_logged = false;
			netif_carrier_on(octep->mgmt_netdev);
			netif_start_queue(octep->mgmt_netdev);
			carrier_on = true;
		} else if (target != OCTEP_MGMT_TARGET_RUNNING &&
			   octep->mgmt_host_status == OCTEP_MGMT_HOST_RUNNING) {
			octep_mgmt_set_host_status(octep, OCTEP_MGMT_HOST_READY);
			netif_stop_queue(octep->mgmt_netdev);
			netif_carrier_off(octep->mgmt_netdev);
		} else if (target == OCTEP_MGMT_TARGET_FATAL &&
			   !octep->mgmt_target_fatal_logged) {
			dev_err(&octep->pdev->dev,
				"mgmt: target rejected the published queues and entered FATAL\n");
			octep->mgmt_target_fatal_logged = true;
			netif_stop_queue(octep->mgmt_netdev);
			netif_carrier_off(octep->mgmt_netdev);
		}
	}

	if (octep->mgmt_host_status == OCTEP_MGMT_HOST_RUNNING)
		octep_mgmt_drain_rx_locked(octep, &received);

	if (octep->mgmt_host_status == OCTEP_MGMT_HOST_RUNNING &&
	    netif_queue_stopped(octep->mgmt_netdev)) {
		u32 next = (octep->mgmt_tx_prod + 1) & OCTEP_MGMT_RING_MASK;
		u32 tx_cons = le32_to_cpu(READ_ONCE(*octep->mgmt_tx_cons_shadow)) &
			      OCTEP_MGMT_RING_MASK;

		if (next != tx_cons)
			netif_wake_queue(octep->mgmt_netdev);
	}
	spin_unlock_irqrestore(&octep->mgmt_lock, flags);

	if (carrier_on)
		dev_info(&octep->pdev->dev, "mgmt: target running; link is up\n");
	while ((skb = skb_dequeue(&received))) {
		skb->protocol = eth_type_trans(skb, octep->mgmt_netdev);
		if (netif_rx(skb) == NET_RX_DROP) {
			spin_lock_irqsave(&octep->mgmt_lock, flags);
			octep->mgmt_stats.rx_dropped++;
			spin_unlock_irqrestore(&octep->mgmt_lock, flags);
		}
	}

	if (READ_ONCE(octep->mgmt_active))
		schedule_delayed_work(&octep->mgmt_poll_work,
				      msecs_to_jiffies(OCTEP_MGMT_POLL_MS));
}

static netdev_tx_t octep_mgmt_xmit(struct sk_buff *skb,
				   struct net_device *netdev)
{
	struct octep *octep =
		((struct octep_netdev_priv *)netdev_priv(netdev))->octep;
	unsigned long flags;
	u32 len, wire, next, cons, slot;
	void *buf;
	int err;

	len = skb->len;
	if (!len || len > OCTEP_MGMT_BUF_SIZE) {
		dev_kfree_skb_any(skb);
		spin_lock_irqsave(&octep->mgmt_lock, flags);
		octep->mgmt_stats.tx_errors++;
		octep->mgmt_stats.tx_dropped++;
		spin_unlock_irqrestore(&octep->mgmt_lock, flags);
		return NETDEV_TX_OK;
	}

	wire = max_t(u32, len, OCTEP_MGMT_MIN_FRAME);
	spin_lock_irqsave(&octep->mgmt_lock, flags);
	if (!octep->mgmt_active ||
	    octep->mgmt_host_status != OCTEP_MGMT_HOST_RUNNING) {
		netif_stop_queue(netdev);
		spin_unlock_irqrestore(&octep->mgmt_lock, flags);
		return NETDEV_TX_BUSY;
	}

	next = (octep->mgmt_tx_prod + 1) & OCTEP_MGMT_RING_MASK;
	cons = le32_to_cpu(READ_ONCE(*octep->mgmt_tx_cons_shadow)) &
	       OCTEP_MGMT_RING_MASK;
	if (next == cons) {
		netif_stop_queue(netdev);
		spin_unlock_irqrestore(&octep->mgmt_lock, flags);
		return NETDEV_TX_BUSY;
	}

	slot = octep->mgmt_tx_prod;
	buf = (u8 *)octep->mgmt_txbuf.vaddr +
	      (size_t)slot * OCTEP_MGMT_BUF_SIZE;
	err = skb_copy_bits(skb, 0, buf, len);
	if (err) {
		octep->mgmt_stats.tx_errors++;
		octep->mgmt_stats.tx_dropped++;
		spin_unlock_irqrestore(&octep->mgmt_lock, flags);
		dev_kfree_skb_any(skb);
		return NETDEV_TX_OK;
	}
	if (wire > len)
		memset((u8 *)buf + len, 0, wire - len);

	octep_mgmt_write_desc(octep, octep->mgmt_tx_descq, slot,
			      OCTEP_MGMT_DESC_MK(wire),
			      octep->mgmt_txbuf.dma_addr +
			      (dma_addr_t)slot * OCTEP_MGMT_BUF_SIZE);
	octep->mgmt_tx_prod = next;
	dma_wmb();
	writel(next, octep->bar2 + octep->mgmt_tx_descq);
	octep_mgmt_ring_doorbell(octep);
	octep->mgmt_stats.tx_packets++;
	octep->mgmt_stats.tx_bytes += len;
	spin_unlock_irqrestore(&octep->mgmt_lock, flags);

	netif_trans_update(netdev);
	dev_kfree_skb_any(skb);
	return NETDEV_TX_OK;
}

static int octep_mgmt_open(struct net_device *netdev)
{
	struct octep *octep =
		((struct octep_netdev_priv *)netdev_priv(netdev))->octep;
	int err;

	netif_carrier_off(netdev);
	mutex_lock(&octep->lock);
	err = octep_mgmt_start(octep);
	mutex_unlock(&octep->lock);
	if (err)
		return err;

	schedule_delayed_work(&octep->mgmt_poll_work,
			      msecs_to_jiffies(OCTEP_MGMT_POLL_MS));
	return 0;
}

static int octep_mgmt_stop(struct net_device *netdev)
{
	struct octep *octep =
		((struct octep_netdev_priv *)netdev_priv(netdev))->octep;
	unsigned long flags;
	bool active;

	spin_lock_irqsave(&octep->mgmt_lock, flags);
	active = octep->mgmt_active;
	octep->mgmt_active = false;
	netif_stop_queue(netdev);
	netif_carrier_off(netdev);
	spin_unlock_irqrestore(&octep->mgmt_lock, flags);
	cancel_delayed_work_sync(&octep->mgmt_poll_work);
	if (!active)
		return 0;

	mutex_lock(&octep->lock);
	spin_lock_irqsave(&octep->mgmt_lock, flags);
	octep_mgmt_set_host_status(octep, OCTEP_MGMT_HOST_GOING_DOWN);
	spin_unlock_irqrestore(&octep->mgmt_lock, flags);
	msleep(2000);
	spin_lock_irqsave(&octep->mgmt_lock, flags);
	octep_mgmt_set_host_status(octep, OCTEP_MGMT_HOST_DOWN);
	writel(0, octep->bar2 +
	       octep->facility[OCTEP_FCLT_MGMT].offset +
	       OCTEP_MGMT_HOST_INTR_OFF);
	spin_unlock_irqrestore(&octep->mgmt_lock, flags);
	octep_dma_free(octep, &octep->mgmt_txbuf);
	octep_dma_free(octep, &octep->mgmt_rxbuf);
	octep_dma_free(octep, &octep->mgmt_shadow);
	octep->mgmt_tx_cons_shadow = NULL;
	octep->mgmt_rx_cons_shadow = NULL;
	octep->mgmt_host_status = OCTEP_MGMT_HOST_DOWN;
	mutex_unlock(&octep->lock);
	return 0;
}

static void octep_mgmt_get_stats64(struct net_device *netdev,
				   struct rtnl_link_stats64 *stats)
{
	struct octep *octep =
		((struct octep_netdev_priv *)netdev_priv(netdev))->octep;
	unsigned long flags;

	spin_lock_irqsave(&octep->mgmt_lock, flags);
	*stats = octep->mgmt_stats;
	spin_unlock_irqrestore(&octep->mgmt_lock, flags);
}

static const struct net_device_ops octep_mgmt_netdev_ops = {
	.ndo_open		= octep_mgmt_open,
	.ndo_stop		= octep_mgmt_stop,
	.ndo_start_xmit		= octep_mgmt_xmit,
	.ndo_get_stats64	= octep_mgmt_get_stats64,
	.ndo_set_mac_address	= eth_mac_addr,
	.ndo_validate_addr	= eth_validate_addr,
};

static int octep_mgmt_netdev_register(struct octep *octep)
{
	struct octep_netdev_priv *priv;
	struct net_device *netdev;
	int err;

	netdev = alloc_etherdev(sizeof(*priv));
	if (!netdev)
		return -ENOMEM;

	priv = netdev_priv(netdev);
	priv->octep = octep;
	netdev->netdev_ops = &octep_mgmt_netdev_ops;
	netdev->min_mtu = ETH_MIN_MTU;
	netdev->max_mtu = OCTEP_MGMT_MTU;
	strscpy(netdev->name, "mvmgmt%d", IFNAMSIZ);
	SET_NETDEV_DEV(netdev, &octep->pdev->dev);
	eth_hw_addr_random(netdev);
	netif_carrier_off(netdev);

	err = register_netdev(netdev);
	if (err) {
		free_netdev(netdev);
		return err;
	}
	octep->mgmt_netdev = netdev;
	dev_info(&octep->pdev->dev,
		 "mgmt: registered management interface %s\n", netdev->name);
	return 0;
}

static void octep_mgmt_netdev_unregister(struct octep *octep)
{
	if (!octep->mgmt_netdev)
		return;
	unregister_netdev(octep->mgmt_netdev);
	free_netdev(octep->mgmt_netdev);
	octep->mgmt_netdev = NULL;
}

static ssize_t sdp_start_store(struct device *dev,
			       struct device_attribute *attr,
			       const char *buf, size_t count)
{
	struct octep *octep = dev_get_drvdata(dev);
	u32 value;
	int err;

	err = kstrtou32(buf, 0, &value);
	if (err)
		return err;
	if (value != 1)
		return -EINVAL;

	mutex_lock(&octep->lock);
	err = octep_dp_start_locked(octep);
	if (!err)
		WRITE_ONCE(octep->dp_poll_enabled, true);
	mutex_unlock(&octep->lock);
	if (!err)
		octep_dp_poll_resume(octep);
	return err ? err : count;
}
static DEVICE_ATTR_WO(sdp_start);

static ssize_t sdp_stop_store(struct device *dev,
			      struct device_attribute *attr,
			      const char *buf, size_t count)
{
	struct octep *octep = dev_get_drvdata(dev);
	u32 value;
	int err;

	err = kstrtou32(buf, 0, &value);
	if (err)
		return err;
	if (value != 1)
		return -EINVAL;

	WRITE_ONCE(octep->dp_poll_enabled, false);
	octep_dp_poll_quiesce(octep);
	mutex_lock(&octep->lock);
	err = octep_dp_stop_locked(octep, false);
	if (err && octep->dp_up &&
	    (octep->hs_done ||
	     readq(octep->bar0 + OCTEP_SLI_EPF_SCRATCH)))
		WRITE_ONCE(octep->dp_poll_enabled, true);
	mutex_unlock(&octep->lock);
	if (err && READ_ONCE(octep->dp_poll_enabled))
		octep_dp_poll_resume(octep);
	return err ? err : count;
}
static DEVICE_ATTR_WO(sdp_stop);

static ssize_t sdp_handshake_store(struct device *dev,
				   struct device_attribute *attr,
				   const char *buf, size_t count)
{
	struct octep *octep = dev_get_drvdata(dev);
	struct octep_sdp_rinfo rinfo;
	u64 info_word, value;
	u32 i, ticks_per_us, num_vfs, pf_start_ring;
	int err;

	err = kstrtou32(buf, 0, &ticks_per_us);
	if (err)
		return err;
	if (ticks_per_us != 1)
		return -EINVAL;

	mutex_lock(&octep->lock);
	if (!octep->dp_up) {
		err = -ENXIO;
		goto out;
	}
	if (octep->hs_done) {
		err = -EALREADY;
		goto out;
	}
	value = readq(octep->bar0 + OCTEP_SLI_EPF_SCRATCH);
	if (value) {
		dev_err(&octep->pdev->dev,
			"sdp: handshake scratch is already owned (value %#018llx); refusing to overwrite it\n",
			(unsigned long long)value);
		err = -EBUSY;
		goto out;
	}
	rinfo = octep_read_sdp_rinfo(octep);
	num_vfs = pci_num_vf(octep->pdev);
	if (rinfo.value == U64_MAX) {
		err = -ENXIO;
		goto out;
	}
	err = octep_sdp_validate_vfs(octep, &rinfo, num_vfs,
				     &pf_start_ring);
	if (err)
		goto out;
	if (rinfo.pf_rings < OCTEP_DP_RING_COUNT) {
		err = -ENXIO;
		goto out;
	}
	info_word = ((u64)OCTEP_SDP_APP_MODE_NIC << 40) |
		    ((u64)pf_start_ring << 32) |
		    ((u64)OCTEP_DP_RING_COUNT << 24) |
		    ((u64)num_vfs << 16) |
		    ((u64)(num_vfs ? rinfo.start_ring : 0) << 8) |
		    (num_vfs ? OCTEP_SRIOV_RINGS_PER_VF : 0);

	dev_info(&octep->pdev->dev,
		 "sdp: SLI_EPF_SCRATCH was 0; writing HOST_LOADED\n");
	writeq(OCTEP_SDP_HOST_LOADED,
	       octep->bar0 + OCTEP_SLI_EPF_SCRATCH);
	if (readq(octep->bar0 + OCTEP_SLI_EPF_SCRATCH) !=
	    OCTEP_SDP_HOST_LOADED) {
		dev_err(&octep->pdev->dev,
			"sdp: HOST_LOADED did not read back; not continuing\n");
		err = -EIO;
		goto out;
	}

	for (i = 0; i < 5 * 50; i++) {
		value = readq(octep->bar0 + OCTEP_SLI_EPF_SCRATCH);
		if (value == OCTEP_SDP_GET_HOST_INFO)
			break;
		msleep(20);
	}
	if (i == 5 * 50) {
		writeq(0, octep->bar0 + OCTEP_SLI_EPF_SCRATCH);
		dev_err(&octep->pdev->dev,
			"sdp: target did not request host info; scratch reset to zero\n");
		err = -ETIMEDOUT;
		goto out;
	}

	writeq(info_word, octep->bar0 + OCTEP_SLI_EPF_SCRATCH);
	dev_info(&octep->pdev->dev,
		 "sdp: target asked; published %#018llx (app %u, pf_srn %u, rppf %u, vf_srn %u, %u VFs x %u rings)\n",
		 (unsigned long long)info_word, OCTEP_SDP_APP_MODE_NIC,
		 pf_start_ring, OCTEP_DP_RING_COUNT,
		 num_vfs ? rinfo.start_ring : 0, num_vfs,
		 num_vfs ? OCTEP_SRIOV_RINGS_PER_VF : 0);
	for (i = 0; i < 2 * 50; i++) {
		value = readq(octep->bar0 + OCTEP_SLI_EPF_SCRATCH);
		if ((value >> 16) == OCTEP_SDP_HOST_INFO_RECEIVED)
			break;
		msleep(20);
	}
	if (i == 2 * 50) {
		writeq(OCTEP_SDP_HANDSHAKE_COMPLETED,
		       octep->bar0 + OCTEP_SLI_EPF_SCRATCH);
		octep->hs_done = true;
		dev_err(&octep->pdev->dev,
			"sdp: no reply to the info word; wrote HANDSHAKE_COMPLETED to release the target's wait\n");
		err = -ETIMEDOUT;
		goto out;
	}

	octep->sdp_coproc_ticks_per_us = value & 0xffff;
	octep->hs_reply_received = true;
	octep->dp_time_threshold =
		(u32)(((u64)octep->sdp_coproc_ticks_per_us *
		       OCTEP_DP_OQ_INTR_TIME) / 1024);
	for (i = 0; i < octep->dp_ring_count; i++) {
		struct octep_dp_ring *ring = &octep->dp_ring[i];

		octep_ring_writeq(octep, ring->ring,
				  OCTEP_SDP_R_OUT_INT_LEVELS,
				  ((u64)octep->dp_time_threshold << 32) |
				  OCTEP_DP_OQ_INTR_PKT);
	}
	writeq(OCTEP_SDP_HANDSHAKE_COMPLETED,
	       octep->bar0 + OCTEP_SLI_EPF_SCRATCH);
	octep->hs_done = true;
	dev_info(&octep->pdev->dev,
		 "sdp: target took the info and reports %u ticks/us; announced HANDSHAKE_COMPLETED\n",
		 octep->sdp_coproc_ticks_per_us);
	err = 0;
out:
	mutex_unlock(&octep->lock);
	return err ? err : count;
}
static DEVICE_ATTR_WO(sdp_handshake);

static ssize_t sdp_state_show(struct device *dev,
			      struct device_attribute *attr, char *buf)
{
	struct octep *octep = dev_get_drvdata(dev);
	u64 scratch;
	u32 port_count;
	ssize_t len;

	mutex_lock(&octep->lock);
	scratch = readq(octep->bar0 + OCTEP_SLI_EPF_SCRATCH);
	port_count = smp_load_acquire(&octep->dp_port_count);
	len = sysfs_emit(buf,
			 "rings=%s ring_count=%u handshake=%s scratch=%#018llx "
			 "coproc_ticks_per_us=%u time_threshold=%u "
			 "management_netdev=%s front_netdevs=%u "
			 "packet_service=%s\n",
			 octep->dp_up ? "armed" : "stopped",
			 octep->dp_ring_count,
			 octep->hs_done ?
				(octep->hs_reply_received ? "completed" : "released") :
				"idle",
			 (unsigned long long)scratch,
			 octep->sdp_coproc_ticks_per_us,
			 octep->dp_time_threshold,
			 octep->mgmt_netdev ? "registered" : "unavailable",
			 port_count,
			 READ_ONCE(octep->dp_io_enabled) ?
				"rx-poll,tx-ring0" : "disabled");
	mutex_unlock(&octep->lock);
	return len;
}
static DEVICE_ATTR_RO(sdp_state);

static ssize_t sdp_port_add_store(struct device *dev,
				  struct device_attribute *attr,
				  const char *buf, size_t count)
{
	struct octep *octep = dev_get_drvdata(dev);
	struct octep_dp_port *port;
	struct octep_netdev_priv *priv;
	struct net_device *netdev;
	u32 values[8];
	u8 addr[ETH_ALEN];
	u32 i, port_count;
	int fields, err;

	fields = sscanf(buf, "%u %u %x:%x:%x:%x:%x:%x",
			&values[0], &values[1], &values[2], &values[3],
			&values[4], &values[5], &values[6], &values[7]);
	if (fields != ARRAY_SIZE(values) || values[0] > U16_MAX ||
	    values[1] > 127)
		return -EINVAL;
	for (i = 0; i < ETH_ALEN; i++) {
		if (values[i + 2] > U8_MAX)
			return -EINVAL;
		addr[i] = values[i + 2];
	}
	if (!is_valid_ether_addr(addr))
		return -EINVAL;

	mutex_lock(&octep->lock);
	if (!octep->dp_up || !octep->hs_done ||
	    !READ_ONCE(octep->dp_io_enabled)) {
		err = -ENXIO;
		goto out_unlock;
	}
	port = octep_dp_port_by_tag(octep, values[0]);
	if (port) {
		err = port->iface == values[1] &&
		      ether_addr_equal(port->netdev->dev_addr, addr) ?
			0 : -EEXIST;
		goto out_unlock;
	}

	port_count = smp_load_acquire(&octep->dp_port_count);
	if (port_count >= OCTEP_DP_PORT_MAX) {
		err = -ENOSPC;
		goto out_unlock;
	}
	port = &octep->dp_port[port_count];
	netdev = alloc_etherdev(sizeof(*priv));
	if (!netdev) {
		err = -ENOMEM;
		goto out_unlock;
	}
	port->netdev = netdev;
	port->tag = values[0];
	port->iface = values[1];
	priv = netdev_priv(netdev);
	priv->octep = octep;
	priv->port = port;
	netdev->netdev_ops = &octep_dp_netdev_ops;
	netdev->hw_features |= NETIF_F_HW_TC;
	netdev->features |= NETIF_F_HW_TC;
	if (octep_dp_sg) {
		/* TX copies via skb_copy_bits and finishes partial checksums in software. */
		netdev->hw_features |= NETIF_F_SG | NETIF_F_HW_CSUM;
		netdev->features |= NETIF_F_SG | NETIF_F_HW_CSUM;
	}
	netdev->min_mtu = ETH_MIN_MTU;
	netdev->max_mtu = octep_dp_max_mtu;
	strscpy(netdev->name, "octep%d", IFNAMSIZ);
	SET_NETDEV_DEV(netdev, &octep->pdev->dev);
	eth_hw_addr_set(netdev, addr);
	netif_carrier_off(netdev);

	err = register_netdev(netdev);
	if (err) {
		free_netdev(netdev);
		memset(port, 0, sizeof(*port));
		goto out_unlock;
	}
	smp_store_release(&octep->dp_port_count, port_count + 1);
	dev_info(&octep->pdev->dev,
		 "dp: registered front-port netdev %s tag %u LIF interface %u\n",
		 netdev->name, port->tag, port->iface);
out_unlock:
	mutex_unlock(&octep->lock);
	return err ? err : count;
}
static DEVICE_ATTR_WO(sdp_port_add);

static void octep_dp_netdev_unregister_all(struct octep *octep)
{
	u32 port_count = smp_load_acquire(&octep->dp_port_count);
	u32 i;

	for (i = 0; i < port_count; i++) {
		struct net_device *netdev = octep->dp_port[i].netdev;

		unregister_netdev(netdev);
		free_netdev(netdev);
		memset(&octep->dp_port[i], 0, sizeof(octep->dp_port[i]));
	}
	smp_store_release(&octep->dp_port_count, 0);
}

static ssize_t sdp_coproc_ticks_per_us_show(struct device *dev,
					    struct device_attribute *attr,
					    char *buf)
{
	struct octep *octep = dev_get_drvdata(dev);
	u32 value;

	mutex_lock(&octep->lock);
	value = octep->sdp_coproc_ticks_per_us;
	mutex_unlock(&octep->lock);
	return sysfs_emit(buf, "%u\n", value);
}

static ssize_t sdp_coproc_ticks_per_us_store(struct device *dev,
					     struct device_attribute *attr,
					     const char *buf, size_t count)
{
	struct octep *octep = dev_get_drvdata(dev);
	u32 value, i, threshold;
	int err;

	err = kstrtou32(buf, 0, &value);
	if (err)
		return err;
	mutex_lock(&octep->lock);
	octep->sdp_coproc_ticks_per_us = value;
	threshold = (u32)(((u64)value * OCTEP_DP_OQ_INTR_TIME) / 1024);
	octep->dp_time_threshold = threshold;
	if (octep->dp_up) {
		for (i = 0; i < octep->dp_ring_count; i++) {
			struct octep_dp_ring *ring = &octep->dp_ring[i];

			octep_ring_writeq(octep, ring->ring,
					  OCTEP_SDP_R_OUT_INT_LEVELS,
					  ((u64)threshold << 32) |
					  OCTEP_DP_OQ_INTR_PKT);
		}
	}
	mutex_unlock(&octep->lock);
	return count;
}
static DEVICE_ATTR_RW(sdp_coproc_ticks_per_us);

static resource_size_t octep_rpc_reg(struct octep *octep, u32 offset)
{
	return (resource_size_t)octep->facility[OCTEP_FCLT_RPC].offset + offset;
}

static u32 octep_rpc_readl(struct octep *octep, u32 offset)
{
	return readl(octep->bar2 + octep_rpc_reg(octep, offset));
}

static void octep_rpc_writel(struct octep *octep, u32 offset, u32 value)
{
	writel(value, octep->bar2 + octep_rpc_reg(octep, offset));
}

static u64 octep_rpc_readq(struct octep *octep, u32 offset)
{
	u64 low = octep_rpc_readl(octep, offset);
	u64 high = octep_rpc_readl(octep, offset + 4);

	return low | (high << 32);
}

static void octep_rpc_writeq(struct octep *octep, u32 offset, u64 value)
{
	octep_rpc_writel(octep, offset, lower_32_bits(value));
	octep_rpc_writel(octep, offset + 4, upper_32_bits(value));
}

static int octep_rpc_configure_locked(struct octep *octep)
{
	struct octep_facility *facility = &octep->facility[OCTEP_FCLT_RPC];
	u64 cfg, desc_end;
	u32 ring, revision, i;
	bool hi_ring = octep_rpc_hi_ring;
	int err;

	lockdep_assert_held(&octep->lock);
	if (!octep->dp_up || !octep->hs_reply_received)
		return -ENXIO;
	if (octep->rpc_ready)
		return -EALREADY;
	octep->rpc_hi_active = false;
	if (!octep->ready || !facility->size || !facility->dbell_count)
		return -ENXIO;

	desc_end = (u64)OCTEP_RPC_DESC_OFFSET +
		   (u64)OCTEP_RPC_DESC_COUNT * OCTEP_RPC_BAR_DESC_SIZE *
		   (hi_ring ? 2 : 1);
	if (OCTEP_RPC_DESC_OFFSET < OCTEP_RPC_STATE_SIZE ||
	    desc_end > facility->size ||
	    facility->dbell_start > U32_MAX - facility->dbell_count) {
		dev_err(&octep->pdev->dev,
			"rpc: descriptor or doorbell range is outside the published facility\n");
		return -EINVAL;
	}

	if (!octep->rpc_cmd.vaddr) {
		err = octep_dma_alloc(octep, &octep->rpc_cmd,
				      OCTEP_RPC_DATA_MAX_SIZE);
		if (err)
			return err;
	}
	cfg = octep_rpc_readq(octep, OCTEP_RPC_STATE_CFG);
	if (cfg == U64_MAX)
		return -ENXIO;
	revision = (((cfg >> 32) & 0xffff) + 1) & 0xffff;

	ring = OCTEP_RPC_STATE_RING_LO;
	octep_rpc_writeq(octep, ring + OCTEP_RPC_RING_POSTED, 0);
	octep_rpc_writeq(octep, ring + OCTEP_RPC_RING_DONE, 0);
	octep_rpc_writel(octep, ring + OCTEP_RPC_RING_OFFSET, 0);
	octep_rpc_writel(octep, ring + OCTEP_RPC_RING_DESC_OFF,
			  OCTEP_RPC_DESC_OFFSET);
	octep_rpc_writel(octep, ring + OCTEP_RPC_RING_DESC_CNT,
			  OCTEP_RPC_DESC_COUNT);
	octep_rpc_writel(octep, ring + OCTEP_RPC_RING_CFG,
			  OCTEP_RPC_RCFG(0, 0, 0, 0));

	for (i = 0; i < 4; i++) {
		u32 hi = OCTEP_RPC_STATE_RINGS + i * OCTEP_RPC_RING_SIZE;
		bool live_ring = hi_ring && !i;

		octep_rpc_writeq(octep, hi + OCTEP_RPC_RING_POSTED, 0);
		octep_rpc_writeq(octep, hi + OCTEP_RPC_RING_DONE, 0);
		octep_rpc_writel(octep, hi + OCTEP_RPC_RING_OFFSET,
				 live_ring ? hi : 0);
		octep_rpc_writel(octep, hi + OCTEP_RPC_RING_DESC_OFF,
				 live_ring ? OCTEP_RPC_DESC_OFFSET +
				 OCTEP_RPC_DESC_COUNT *
				 OCTEP_RPC_BAR_DESC_SIZE : 0);
		octep_rpc_writel(octep, hi + OCTEP_RPC_RING_DESC_CNT,
				 live_ring ? OCTEP_RPC_DESC_COUNT : 0);
		/* Ring 1 on the first doorbell after the config one; not shared. */
		octep_rpc_writel(octep, hi + OCTEP_RPC_RING_CFG,
				 live_ring ? OCTEP_RPC_RCFG(1, 0, 1, 0) : 0);
	}
	wmb();

	cfg = OCTEP_RPC_STATE_CFG_MAGIC | ((u64)revision << 32) |
	      ((u64)hi_ring << 48);
	octep_rpc_writeq(octep, OCTEP_RPC_STATE_CFG, cfg);
	wmb();
	dev_info(&octep->pdev->dev,
		 "rpc: published %s config revision %u, %u descriptors at BAR2+%#x, doorbell 0\n",
		 hi_ring ? "low+hi-ring-1" : "low-ring", revision, OCTEP_RPC_DESC_COUNT,
		 facility->offset + OCTEP_RPC_DESC_OFFSET);

	err = octep_ring_dbell_locked(octep, facility->dbell_start);
	if (err)
		return err;

	for (i = 0; i < OCTEP_RPC_CFG_WAIT_MS; i++) {
		u64 live = octep_rpc_readq(octep, OCTEP_RPC_STATE_CFG);

		if ((live >> 56) & 0xff) {
			u64 posted, done;

			posted = octep_rpc_readq(octep,
						 OCTEP_RPC_STATE_RING_LO +
						 OCTEP_RPC_RING_POSTED);
			done = octep_rpc_readq(octep,
					       OCTEP_RPC_STATE_RING_LO +
					       OCTEP_RPC_RING_DONE);
			if (posted != done) {
				dev_err(&octep->pdev->dev,
					"rpc: target acknowledged with outstanding commands (posted=%llu done=%llu)\n",
					(unsigned long long)posted,
					(unsigned long long)done);
				return -EBUSY;
			}
			octep->rpc_desc_off = OCTEP_RPC_DESC_OFFSET;
			octep->rpc_desc_count = OCTEP_RPC_DESC_COUNT;
			octep->rpc_posted = posted;
			if (hi_ring) {
				u64 hp = octep_rpc_readq(octep,
					OCTEP_RPC_STATE_RINGS +
					OCTEP_RPC_RING_POSTED);
				u64 hd = octep_rpc_readq(octep,
					OCTEP_RPC_STATE_RINGS +
					OCTEP_RPC_RING_DONE);

				if (hp != hd) {
					dev_err(&octep->pdev->dev,
						"rpc: hi ring 1 not idle after config (posted=%llu done=%llu)\n",
						(unsigned long long)hp,
						(unsigned long long)hd);
					return -EBUSY;
				}
				octep->rpc_hi_posted = hp;
				octep->rpc_hi_active = true;
			}
			octep->rpc_ready = true;
			octep->rpc_fw_cfg_known = false;
			dev_info(&octep->pdev->dev,
				 "rpc: target acknowledged after %u ms (cfg=%#018llx)\n",
				 i, (unsigned long long)live);
			return 0;
		}
		msleep(1);
	}

	dev_err(&octep->pdev->dev,
		"rpc: no acknowledgement after %u ms (cfg=%#018llx)\n",
		OCTEP_RPC_CFG_WAIT_MS,
		(unsigned long long)octep_rpc_readq(octep,
						    OCTEP_RPC_STATE_CFG));
	return -ETIMEDOUT;
}

static int octep_rpc_validate_flow_command(struct octep *octep, u8 command,
					   const u8 *payload, u16 payload_len);

static int octep_rpc_post_command_locked(struct octep *octep, u8 command,
					 const u8 *payload, u16 payload_len)
{
	struct octep_facility *facility = &octep->facility[OCTEP_FCLT_RPC];
	u8 *buffer = octep->rpc_cmd.vaddr;
	u8 wire_command = command;
	u64 posted, done, desc;
	unsigned long rpc_deadline;
	u32 index, offset, i;
	u16 rc, reply_len;
	u32 ring_base, desc_base, dbell;
	u64 *host_posted;
	bool use_hi;
	int err;

	lockdep_assert_held(&octep->lock);
	if (!octep->rpc_ready)
		return -ENXIO;
	if (!octep->rpc_allow_write &&
	    command != OCTEP_RPC_CMD_LO_LIF_READ &&
	    command != OCTEP_RPC_CMD_LO_CONN_READ &&
	    command != OCTEP_RPC_CMD_LO_MFLOW_READ &&
	    command != OCTEP_RPC_CMD_LO_WORKER_SYS_CNT_READ &&
	    !octep->rpc_platform_probe)
		return -EPERM;
	if (octep->rpc_platform_probe) {
		if (command < OCTEP_RPC_CMD_PLATFORM_READ ||
		    command > OCTEP_RPC_CMD_PLATFORM_READ + OCTEP_RPC_CMD_SHIFT_MAX)
			return -EPERM;
	} else {
		if (command != OCTEP_RPC_CMD_LIF_ADD_UPDATE &&
		    command != OCTEP_RPC_CMD_PPORT_UPDATE &&
		    command != OCTEP_RPC_CMD_FW_CFG_PARAMS_SET &&
		    command != OCTEP_RPC_CMD_FW_STATE_REV_SET &&
		    command != OCTEP_RPC_CMD_NHOP_PROGRAM &&
		    command != OCTEP_RPC_CMD_MFLOW_PROGRAM &&
		    command != OCTEP_RPC_CMD_FLOW_CREATE_FP &&
		    command != OCTEP_RPC_CMD_CONN_RECLAIM_FP &&
		    command != OCTEP_RPC_CMD_LO_LIF_READ &&
		    command != OCTEP_RPC_CMD_LO_CONN_READ &&
		    command != OCTEP_RPC_CMD_LO_MFLOW_READ &&
		    command != OCTEP_RPC_CMD_LO_WORKER_SYS_CNT_READ &&
		    (octep_rpc_raw_cmd < 0 || command != octep_rpc_raw_cmd))
			return -EPERM;
		if (command >= OCTEP_RPC_CMD_PLATFORM_READ) {
			if (!octep->rpc_platform_known)
				return -EOPNOTSUPP;
			wire_command += octep->rpc_cmd_shift;
		}
	}
	if (OCTEP_RPC_BUF_DESC_SIZE + payload_len > OCTEP_RPC_DATA_MAX_SIZE)
		return -EMSGSIZE;
	err = octep_rpc_validate_flow_command(octep, command, payload,
					     payload_len);
	if (err)
		return err;

	/* Flow-programming commands go on hi ring 1; reads and setup stay on the low ring. */
	use_hi = octep->rpc_hi_active &&
		 (command == OCTEP_RPC_CMD_NHOP_PROGRAM ||
		  command == OCTEP_RPC_CMD_MFLOW_PROGRAM ||
		  command == OCTEP_RPC_CMD_FLOW_CREATE_FP ||
		  command == OCTEP_RPC_CMD_CONN_RECLAIM_FP);
	ring_base = use_hi ? OCTEP_RPC_STATE_RINGS : OCTEP_RPC_STATE_RING_LO;
	desc_base = octep->rpc_desc_off +
		    (use_hi ? OCTEP_RPC_DESC_COUNT * OCTEP_RPC_BAR_DESC_SIZE : 0);
	host_posted = use_hi ? &octep->rpc_hi_posted : &octep->rpc_posted;
	dbell = facility->dbell_start + (use_hi ? 1 : 0);

	posted = octep_rpc_readq(octep, ring_base + OCTEP_RPC_RING_POSTED);
	done = octep_rpc_readq(octep, ring_base + OCTEP_RPC_RING_DONE);
	if (posted != *host_posted || done != posted) {
		dev_err(&octep->pdev->dev,
			"rpc: %s ring is not idle (host=%llu posted=%llu done=%llu)\n",
			use_hi ? "hi" : "low",
			(unsigned long long)*host_posted,
			(unsigned long long)posted, (unsigned long long)done);
		return -EBUSY;
	}

	memset(buffer, 0x5a, OCTEP_RPC_DATA_MAX_SIZE);
	buffer[0] = (OCTEP_RPC_DATA_MAX_SIZE - OCTEP_RPC_BUF_DESC_SIZE) & 0xff;
	buffer[1] = (OCTEP_RPC_DATA_MAX_SIZE - OCTEP_RPC_BUF_DESC_SIZE) >> 8;
	buffer[2] = 0;
	buffer[3] = wire_command;
	memset(buffer + 4, 0, 4);
	if (payload_len)
		memcpy(buffer + OCTEP_RPC_BUF_DESC_SIZE, payload, payload_len);
	dma_wmb();

	index = (u32)(posted & (octep->rpc_desc_count - 1));
	offset = desc_base + index * OCTEP_RPC_BAR_DESC_SIZE;
	desc = (u64)facility->offset + offset;
	if (desc + OCTEP_RPC_BAR_DESC_SIZE > octep->bar2_len ||
	    (octep->gicd_offset && desc + OCTEP_RPC_BAR_DESC_SIZE >
				       octep->gicd_offset))
		return -EINVAL;

	octep_rpc_writeq(octep, offset, octep->rpc_cmd.dma_addr);
	octep_rpc_writel(octep, offset + 8,
			  payload_len |
			  ((u32)OCTEP_RPC_DESC_NO_AGG_DMA << 16));
	octep_rpc_writel(octep, offset + 12, 0);
	wmb();
	octep_rpc_writeq(octep, ring_base + OCTEP_RPC_RING_POSTED, posted + 1);
	wmb();
	*host_posted = posted + 1;
	octep->rpc_last_cmd = wire_command;
	octep->rpc_last_rc = 0;
	octep->rpc_last_len = 0;
	octep->rpc_last_error = 0;
	err = octep_ring_dbell_locked(octep, dbell);
	if (err)
		return err;

	rpc_deadline = jiffies + msecs_to_jiffies(OCTEP_RPC_CMD_WAIT_MS);
	for (i = 0; ; i++) {
		done = octep_rpc_readq(octep, ring_base + OCTEP_RPC_RING_DONE);
		if (done > posted)
			break;
		if (time_after(jiffies, rpc_deadline)) {
			i = OCTEP_RPC_CMD_WAIT_MS;
			break;
		}
		/* A ring round trip is well under a millisecond; msleep(1) made every RPC cost 1-2 ms. */
		usleep_range(i < 2 ? 20 : 50, i < 2 ? 40 : 100);
	}
	if (i == OCTEP_RPC_CMD_WAIT_MS) {
		octep->rpc_last_error = -ETIMEDOUT;
		octep->rpc_timeouts++;
		octep->rpc_ready = false;
		octep->rpc_fw_cfg_known = false;
		dev_err(&octep->pdev->dev,
			"rpc: command %u timed out; posted=%llu done=%llu\n",
			wire_command, (unsigned long long)(posted + 1),
			(unsigned long long)done);
		return -ETIMEDOUT;
	}

	dma_rmb();
	rc = buffer[0] | ((u16)buffer[1] << 8);
	reply_len = buffer[6] | ((u16)buffer[7] << 8);
	octep->rpc_last_rc = rc;
	octep->rpc_last_len = reply_len;
	octep->rpc_commands++;
	if (reply_len > OCTEP_RPC_DATA_MAX_SIZE - OCTEP_RPC_BUF_DESC_SIZE) {
		octep->rpc_last_error = -EPROTO;
		octep->rpc_ready = false;
		octep->rpc_fw_cfg_known = false;
		return -EPROTO;
	}
	if (rc) {
		octep->rpc_last_error = -EREMOTEIO;
		if (!octep->rpc_platform_probe)
			dev_err(&octep->pdev->dev,
				"rpc: command %u refused with return code %#x\n",
				wire_command, rc);
		return -EREMOTEIO;
	}
	if (command == OCTEP_RPC_CMD_LO_LIF_READ) {
		octep->rpc_lif_read_valid = false;
		if (reply_len != OCTEP_RPC_LIF_READ_REPLY_MIN &&
		    reply_len != OCTEP_RPC_LIF_READ_REPLY_MAX) {
			octep->rpc_last_error = -EPROTO;
			return -EPROTO;
		}
		memcpy(octep->rpc_lif_read_reply,
		       buffer + OCTEP_RPC_BUF_DESC_SIZE,
		       reply_len);
		octep->rpc_lif_read_len = reply_len;
		octep->rpc_lif_read_valid = true;
	}
	dev_dbg(&octep->pdev->dev,
		"rpc: command %u completed successfully (reply %u bytes)\n",
		 wire_command, reply_len);
	return 0;
}

static int octep_rpc_platform_learn_locked(struct octep *octep)
{
	u8 empty_payload = 0;
	u8 *reply = octep->rpc_cmd.vaddr + OCTEP_RPC_BUF_DESC_SIZE;
	char name[65] = {};
	unsigned int shift;
	int err;

	lockdep_assert_held(&octep->lock);
	octep->rpc_platform_known = false;
	octep->rpc_platform_len = 0;
	octep->rpc_platform_conn = 0;
	octep->rpc_platform_nhop = 0;
	octep->rpc_cmd_shift = 0;
	octep->rpc_platform_probe = true;

	for (shift = 0; shift <= OCTEP_RPC_CMD_SHIFT_MAX; shift++) {
		err = octep_rpc_post_command_locked(
			octep, OCTEP_RPC_CMD_PLATFORM_READ + shift,
			&empty_payload, 0);
		if (err ||
		    (octep->rpc_last_len != 228 &&
		     octep->rpc_last_len != 232) ||
		    memcmp(reply, "XGS_", 4))
			continue;

		memcpy(name, reply, sizeof(name) - 1);
		octep->rpc_platform_len = octep->rpc_last_len;
		octep->rpc_platform_conn =
			get_unaligned_le32(reply + OCTEP_RPC_PLATFORM_CONN_OFF);
		octep->rpc_platform_nhop =
			get_unaligned_le32(reply + OCTEP_RPC_PLATFORM_NHOP_OFF);
		if (!octep->rpc_platform_conn || !octep->rpc_platform_nhop)
			continue;

		octep->rpc_cmd_shift = shift;
		octep->rpc_platform_known = true;
		break;
	}
	octep->rpc_platform_probe = false;
	if (!octep->rpc_platform_known) {
		dev_warn(&octep->pdev->dev,
			 "rpc: platform numbering/capacities unavailable; commands 36 and above are disabled\n");
		return -EOPNOTSUPP;
	}

	dev_info(&octep->pdev->dev,
		 "rpc: platform %s (%u bytes), command_shift=%u connections=%u next_hops=%u\n",
		 name, octep->rpc_platform_len, octep->rpc_cmd_shift,
		 octep->rpc_platform_conn, octep->rpc_platform_nhop);
	return 0;
}

static int octep_rpc_validate_mflow(struct octep *octep, const u8 *payload,
				    u32 expected_direction, u32 conn_idx,
				    u32 conn_rev)
{
	u32 identity = get_unaligned_le32(payload);
	u32 operation = get_unaligned_le32(payload + 4);
	u32 conn = get_unaligned_le32(payload + 12);
	u32 revision = get_unaligned_le32(payload + 16);
	u32 next_hop = get_unaligned_le32(payload + 20) & 0x00ffffff;
	u32 state = operation >> 28;
	u32 action = (operation >> 16) & 0xf;
	/* A standalone MFLOW_PROGRAM with state 0 and no action invalidates a slot. */
	bool clear = expected_direction == U32_MAX && !state && !action;

	if (!(identity & BIT(31)) || !(identity & 0x01ffffff))
		return -EINVAL;
	if (!clear &&
	    (state != OCTEP_RPC_MFLOW_STATE_ACTIVE ||
	     (action != OCTEP_RPC_MFLOW_ACTION_FWD &&
	      action != OCTEP_RPC_MFLOW_ACTION_IPS) ||
	     (expected_direction <= 1 &&
	      ((operation >> 23) & 1) != expected_direction)))
		return -EINVAL;
	if (conn != conn_idx || (revision >> 16) != (conn_rev & 0xffff))
		return -EINVAL;
	if (conn_idx < 2 || conn_idx >= octep->rpc_platform_conn ||
	    next_hop < 2 || next_hop >= octep->rpc_platform_nhop)
		return -ERANGE;
	return 0;
}

static int octep_rpc_validate_flow_command(struct octep *octep, u8 command,
					   const u8 *payload, u16 payload_len)
{
	u32 conn_idx, conn_flags, conn_rev, valid;
	int err;

	if (command != OCTEP_RPC_CMD_NHOP_PROGRAM &&
	    command != OCTEP_RPC_CMD_MFLOW_PROGRAM &&
	    command != OCTEP_RPC_CMD_FLOW_CREATE_FP)
		return 0;
	if (!octep->rpc_platform_known)
		return -EOPNOTSUPP;

	if (command == OCTEP_RPC_CMD_NHOP_PROGRAM) {
		if (payload_len != OCTEP_RPC_NHOP_REQ_LEN)
			return -EMSGSIZE;
		conn_idx = get_unaligned_le32(payload);
		return conn_idx >= 2 && conn_idx < octep->rpc_platform_nhop ?
			0 : -ERANGE;
	}

	if (command == OCTEP_RPC_CMD_MFLOW_PROGRAM) {
		if (payload_len != OCTEP_RPC_MFLOW_REQ_LEN)
			return -EMSGSIZE;
		conn_idx = get_unaligned_le32(payload + 12);
		conn_rev = get_unaligned_le32(payload + 16) >> 16;
		return octep_rpc_validate_mflow(octep, payload, U32_MAX,
						conn_idx, conn_rev);
	}

	if (payload_len != OCTEP_RPC_FLOW_REQ_LEN)
		return -EMSGSIZE;
	conn_idx = get_unaligned_le32(payload);
	conn_flags = get_unaligned_le32(payload + 4);
	conn_rev = conn_flags & 0xffff;
	valid = get_unaligned_le32(payload + OCTEP_RPC_FLOW_OFF_VALID);
	if (conn_idx < 2 || conn_idx >= octep->rpc_platform_conn ||
	    (conn_flags >> 30) != OCTEP_RPC_CONN_STATE_VALID ||
	    (valid != OCTEP_RPC_FLOW_VALID_ORIG &&
	     valid != (OCTEP_RPC_FLOW_VALID_ORIG | OCTEP_RPC_FLOW_VALID_REPLY)))
		return -EINVAL;

	err = octep_rpc_validate_mflow(
		octep, payload + OCTEP_RPC_FLOW_OFF_MFLOW_O, 0,
		conn_idx, conn_rev);
	if (err)
		return err;
	/* Originating side only, as in the first accelerated-frame test. */
	if (valid == OCTEP_RPC_FLOW_VALID_ORIG)
		return 0;
	err = octep_rpc_validate_mflow(
		octep, payload + OCTEP_RPC_FLOW_OFF_MFLOW_R, 1,
		conn_idx, conn_rev);
	if (err)
		return err;
	if ((get_unaligned_le32(payload + OCTEP_RPC_FLOW_OFF_MFLOW_O) &
	     0x01ffffff) ==
	    (get_unaligned_le32(payload + OCTEP_RPC_FLOW_OFF_MFLOW_R) &
	     0x01ffffff))
		return -EINVAL;
	return 0;
}

static ssize_t rpc_configure_store(struct device *dev,
				   struct device_attribute *attr,
				   const char *buf, size_t count)
{
	struct octep *octep = dev_get_drvdata(dev);
	u32 value;
	int err;

	err = kstrtou32(buf, 0, &value);
	if (err)
		return err;
	if (value != 1)
		return -EINVAL;
	mutex_lock(&octep->lock);
	err = octep_rpc_configure_locked(octep);
	if (!err) {
		octep_rpc_platform_learn_locked(octep);
		if (!octep->rpc_ready)
			err = octep->rpc_last_error ?: -EIO;
	}
	mutex_unlock(&octep->lock);
	return err ? err : count;
}
static DEVICE_ATTR_WO(rpc_configure);

static ssize_t rpc_allow_write_show(struct device *dev,
				    struct device_attribute *attr, char *buf)
{
	struct octep *octep = dev_get_drvdata(dev);
	bool allowed;

	mutex_lock(&octep->lock);
	allowed = octep->rpc_allow_write;
	mutex_unlock(&octep->lock);
	return sysfs_emit(buf, "%u\n", allowed);
}

static ssize_t rpc_allow_write_store(struct device *dev,
				     struct device_attribute *attr,
				     const char *buf, size_t count)
{
	struct octep *octep = dev_get_drvdata(dev);
	u32 value;
	int err;

	err = kstrtou32(buf, 0, &value);
	if (err)
		return err;
	if (value > 1)
		return -EINVAL;
	mutex_lock(&octep->lock);
	if (octep->rpc_allow_write != !!value)
		dev_info(dev, "gate: rpc write gate %s (by %s pid %d)\n",
			 value ? "OPEN" : "CLOSED", current->comm, current->pid);
	octep->rpc_allow_write = value;
	mutex_unlock(&octep->lock);
	return count;
}
static DEVICE_ATTR_RW(rpc_allow_write);

static ssize_t offload_show(struct device *dev,
			    struct device_attribute *attr, char *buf)
{
	struct octep *octep = dev_get_drvdata(dev);
	ssize_t len;

	mutex_lock(&octep->lock);
	if (!octep->rpc_fw_cfg_known) {
		len = sysfs_emit(buf,
				 "requested=unknown fw_cfg=unknown firmware_readback=no\n");
	} else {
		len = sysfs_emit(buf,
				 "requested=%s fw_cfg=0x%04x acknowledged=yes firmware_readback=no\n",
				 octep->rpc_fw_cfg & OCTEP_FW_CFG_OFFLOAD ?
					"on" : "off",
				 octep->rpc_fw_cfg);
	}
	mutex_unlock(&octep->lock);
	return len;
}

static void octep_ft_reclaim_all_locked(struct octep *octep);

static ssize_t offload_store(struct device *dev,
			     struct device_attribute *attr,
			     const char *buf, size_t count)
{
	struct octep *octep = dev_get_drvdata(dev);
	u8 payload[4] = {};
	bool enable, previous_allow_write;
	u16 fw_cfg;
	int err;

	if (sysfs_streq(buf, "on"))
		enable = true;
	else if (sysfs_streq(buf, "off"))
		enable = false;
	else
		return -EINVAL;

	mutex_lock(&octep->lock);
	if (!octep->rpc_ready) {
		err = -ENXIO;
		goto out_unlock;
	}

	fw_cfg = octep->rpc_fw_cfg_known ?
		 octep->rpc_fw_cfg : OCTEP_FW_CFG_TCP_SEQ_CHK;
	if (enable)
		fw_cfg |= OCTEP_FW_CFG_OFFLOAD | READ_ONCE(octep_ft_fw_cfg_extra);
	else
		fw_cfg &= ~OCTEP_FW_CFG_OFFLOAD;
	payload[0] = fw_cfg & 0xff;
	payload[1] = fw_cfg >> 8;

	previous_allow_write = octep->rpc_allow_write;
	octep->rpc_allow_write = true;
	if (!enable && OCTEP_FT_FEAT(octep_ft_bulk_reclaim))
		octep_ft_reclaim_all_locked(octep);
	err = octep_rpc_post_command_locked(octep,
					    OCTEP_RPC_CMD_FW_CFG_PARAMS_SET,
					    payload, sizeof(payload));
	octep->rpc_allow_write = previous_allow_write;
	if (!err) {
		octep->rpc_fw_cfg = fw_cfg;
		octep->rpc_fw_cfg_known = true;
	}
	dev_info(dev, "gate: firmware offload %s fw_cfg=0x%04x %s (by %s pid %d)\n",
		 enable ? "ON" : "OFF", fw_cfg,
		 err ? "FAILED" : "acknowledged", current->comm, current->pid);

out_unlock:
	mutex_unlock(&octep->lock);
	if (err)
		return err;
	return count;
}
static DEVICE_ATTR_RW(offload);

static int octep_rpc_lif_read_locked(struct octep *octep, u32 index)
{
	u8 payload[OCTEP_RPC_TBL_REQ_LEN] = {};

	lockdep_assert_held(&octep->lock);
	put_unaligned_le32(index, payload);
	put_unaligned_le16(1, payload + 4);
	octep->rpc_lif_read_valid = false;
	octep->rpc_lif_read_index = index;
	return octep_rpc_post_command_locked(octep,
					    OCTEP_RPC_CMD_LO_LIF_READ,
					    payload, sizeof(payload));
}

static bool octep_rpc_lif_matches(const u8 *reply, const u8 *mac)
{
	return !memcmp(reply, mac, ETH_ALEN) &&
	       get_unaligned_le16(reply + 6) == OCTEP_RPC_LIF_MTU &&
	       (get_unaligned_le16(reply + 8) & 0x000f) ==
		       OCTEP_RPC_LIF_FWD_L3;
}

static ssize_t rpc_lif_add_store(struct device *dev,
				 struct device_attribute *attr,
				 const char *buf, size_t count)
{
	struct octep *octep = dev_get_drvdata(dev);
	u8 payload[18] = {};
	u8 mac[ETH_ALEN];
	char mac_text[18];
	u32 iface, vlan, index;
	int err;

	if (sscanf(buf, "%u %u %17s", &iface, &vlan, mac_text) != 3 ||
	    !mac_pton(mac_text, mac) || !is_valid_ether_addr(mac))
		return -EINVAL;
	if (iface > 0x7f || vlan > 0xfff)
		return -ERANGE;

	index = (iface << 12) | vlan;
	put_unaligned_le32(index, payload);
	ether_addr_copy(payload + 4, mac);
	payload[10] = OCTEP_RPC_LIF_MTU & 0xff;
	payload[11] = OCTEP_RPC_LIF_MTU >> 8;
	payload[12] = OCTEP_RPC_LIF_FWD_L3;
	payload[14] = OCTEP_RPC_LIF_FP_PRIV_MASK_DF;
	payload[15] = 0;
	payload[16] = OCTEP_RPC_LIF_M_ALL & 0xff;
	payload[17] = OCTEP_RPC_LIF_M_ALL >> 8;

	mutex_lock(&octep->lock);
	if (!octep->rpc_allow_write) {
		err = -EPERM;
		goto out_unlock;
	}
	err = octep_rpc_lif_read_locked(octep, index);
	if (err)
		goto out_unlock;
	if (octep_rpc_lif_matches(octep->rpc_lif_read_reply, mac))
		goto out_unlock;
	if (get_unaligned_le16(octep->rpc_lif_read_reply + 8) & 0x0003)
		put_unaligned_le16(OCTEP_RPC_LIF_M_MANAGED, payload + 16);
	err = octep_rpc_post_command_locked(octep,
					    OCTEP_RPC_CMD_LIF_ADD_UPDATE,
					    payload, sizeof(payload));
	if (err) {
		int write_error = err;
		u16 write_rc = octep->rpc_last_rc;

		if (write_error != -EREMOTEIO || write_rc != 1)
			goto out_unlock;
		err = octep_rpc_lif_read_locked(octep, index);
		if (!err && octep_rpc_lif_matches(octep->rpc_lif_read_reply, mac)) {
			dev_info(&octep->pdev->dev,
				 "LIF %u appeared during update; verified readback after rc=1\n",
				 index);
			goto out_unlock;
		}
		octep->rpc_last_rc = write_rc;
		octep->rpc_last_error = write_error;
		err = write_error;
		goto out_unlock;
	}
	err = octep_rpc_lif_read_locked(octep, index);
	if (!err && !octep_rpc_lif_matches(octep->rpc_lif_read_reply, mac)) {
		err = -EIO;
		octep->rpc_last_error = err;
	}
out_unlock:
	mutex_unlock(&octep->lock);
	return err ? err : count;
}
static DEVICE_ATTR_WO(rpc_lif_add);

static ssize_t rpc_lif_read_show(struct device *dev,
				 struct device_attribute *attr, char *buf)
{
	struct octep *octep = dev_get_drvdata(dev);
	ssize_t len;
	unsigned int i;

	mutex_lock(&octep->lock);
	if (!octep->rpc_lif_read_valid) {
		len = sysfs_emit(buf, "no successful LIF read\n");
		goto out;
	}
	len = sysfs_emit(buf, "requested_index=%u mac=%pM mtu=%u flags=0x%04x reply_len=%u raw=",
			 octep->rpc_lif_read_index, octep->rpc_lif_read_reply,
			 get_unaligned_le16(octep->rpc_lif_read_reply + 6),
			 get_unaligned_le16(octep->rpc_lif_read_reply + 8),
			 octep->rpc_lif_read_len);
	for (i = 0; i < octep->rpc_lif_read_len; i++)
		len += sysfs_emit_at(buf, len, "%s%02x", i ? " " : "",
				     octep->rpc_lif_read_reply[i]);
	len += sysfs_emit_at(buf, len, "\n");
out:
	mutex_unlock(&octep->lock);
	return len;
}

static ssize_t rpc_lif_read_store(struct device *dev,
				  struct device_attribute *attr,
				  const char *buf, size_t count)
{
	struct octep *octep = dev_get_drvdata(dev);
	u32 iface, vlan, index;
	int err;

	if (sscanf(buf, "%u %u", &iface, &vlan) != 2)
		return -EINVAL;
	if (iface > 0x7f || vlan > 0xfff)
		return -ERANGE;

	index = (iface << 12) | vlan;
	mutex_lock(&octep->lock);
	err = octep_rpc_lif_read_locked(octep, index);
	mutex_unlock(&octep->lock);
	return err ? err : count;
}
static DEVICE_ATTR_RW(rpc_lif_read);

static ssize_t rpc_sys_counters_show(struct device *dev,
				     struct device_attribute *attr, char *buf)
{
	struct octep *octep = dev_get_drvdata(dev);
	u8 payload[OCTEP_RPC_TBL_REQ_LEN] = {};
	const u8 *reply;
	ssize_t len;
	unsigned int i;
	int err;

	put_unaligned_le16(OCTEP_RPC_SYS_COUNTER_COUNT, payload + 4);
	put_unaligned_le32(OCTEP_RPC_SYS_COUNTER_COUNT - 1, payload + 8);

	mutex_lock(&octep->lock);
	err = octep_rpc_post_command_locked(octep,
					    OCTEP_RPC_CMD_LO_WORKER_SYS_CNT_READ,
					    payload, sizeof(payload));
	if (err) {
		len = err;
		goto out;
	}
	if (octep->rpc_last_len != OCTEP_RPC_SYS_COUNTER_COUNT * sizeof(u64)) {
		octep->rpc_last_error = -EPROTO;
		len = -EPROTO;
		goto out;
	}
	reply = (u8 *)octep->rpc_cmd.vaddr + OCTEP_RPC_BUF_DESC_SIZE;
	len = sysfs_emit(buf, "count=%u command_shift=%u\n",
			 OCTEP_RPC_SYS_COUNTER_COUNT, octep->rpc_cmd_shift);
	for (i = 0; i < OCTEP_RPC_SYS_COUNTER_COUNT; i++)
		len += sysfs_emit_at(buf, len, "%u=%llu\n", i,
				     (unsigned long long)get_unaligned_le64(reply + i * sizeof(u64)));
out:
	mutex_unlock(&octep->lock);
	return len;
}
static DEVICE_ATTR_RO(rpc_sys_counters);

static ssize_t rpc_mflow_read_show(struct device *dev,
				   struct device_attribute *attr, char *buf)
{
	struct octep *octep = dev_get_drvdata(dev);
	const u8 *reply, *key, *entry, *operation;
	u32 state, action, nhop;
	ssize_t len;
	unsigned int i;

	mutex_lock(&octep->lock);
	if (!octep->rpc_mflow_read_valid) {
		len = sysfs_emit(buf, "no microflow read is available\n");
		goto out;
	}

	reply = octep->rpc_mflow_read_reply;
	key = reply + 8;
	entry = reply + 72;
	operation = reply + 92;
	state = get_unaligned_le32(entry + 12);
	action = get_unaligned_le32(operation);
	nhop = get_unaligned_le32(operation + 16);
	len = sysfs_emit(buf,
			 "requested_index=%u reply_index=%u timestamp=%u timeout=%u "
			 "revision=%u fw_valid=%u host_valid=%u action=%u "
			 "direction=%u bridge_control=%u state=%u connection=%u "
			 "next_hop=%u next_hop_revision=%u "
			 "key_lif=%u key_ethertype=0x%04x key_family=%u "
			 "key_protocol=%u key_src_port=%u key_dst_port=%u",
			 octep->rpc_mflow_read_index,
			 get_unaligned_le32(reply),
			 get_unaligned_le32(entry),
			 get_unaligned_le32(entry + 4),
			 (state >> 8) & 0xff, (state >> 16) & 0xff,
			 (state >> 24) & 0xff, (action >> 16) & 0xf,
			 (action >> 23) & 1, (action >> 24) & 0xf,
			 action >> 28, get_unaligned_le32(operation + 8),
			 nhop & 0x00ffffff, nhop >> 24,
			 get_unaligned_le32(key), get_unaligned_be16(key + 16),
			 key[18], key[19], get_unaligned_be16(key + 22),
			 get_unaligned_be16(key + 20));
	if (get_unaligned_be16(key + 16) == ETH_P_IP)
		len += sysfs_emit_at(buf, len,
				     " key_src_ipv4=%u.%u.%u.%u key_dst_ipv4=%u.%u.%u.%u",
				     key[24], key[25], key[26], key[27],
				     key[28], key[29], key[30], key[31]);
	len += sysfs_emit_at(buf, len, " raw=");
	for (i = 0; i < OCTEP_RPC_MFLOW_READ_REPLY_LEN; i++)
		len += sysfs_emit_at(buf, len, "%s%02x", i ? " " : "", reply[i]);
	len += sysfs_emit_at(buf, len, "\n");
out:
	mutex_unlock(&octep->lock);
	return len;
}

static ssize_t rpc_mflow_read_store(struct device *dev,
				    struct device_attribute *attr,
				    const char *buf, size_t count)
{
	struct octep *octep = dev_get_drvdata(dev);
	u8 payload[OCTEP_RPC_TBL_REQ_LEN] = {};
	const u8 *reply;
	u32 index;
	int err;

	mutex_lock(&octep->lock);
	octep->rpc_mflow_read_valid = false;
	err = kstrtou32(buf, 0, &index);
	if (err)
		goto out;
	if (index > 0x01ffffff) {
		err = -ERANGE;
		goto out;
	}

	put_unaligned_le32(index, payload);
	put_unaligned_le16(1, payload + 4);
	put_unaligned_le16(OCTEP_RPC_TABLE_FLAG_READ_ALL, payload + 6);
	put_unaligned_le32(index, payload + 8);

	err = octep_rpc_post_command_locked(octep,
					    OCTEP_RPC_CMD_LO_MFLOW_READ,
					    payload, sizeof(payload));
	if (err)
		goto out;
	if (octep->rpc_last_len != OCTEP_RPC_MFLOW_READ_REPLY_LEN) {
		octep->rpc_last_error = -EPROTO;
		err = -EPROTO;
		goto out;
	}
	reply = (u8 *)octep->rpc_cmd.vaddr + OCTEP_RPC_BUF_DESC_SIZE;
	if (get_unaligned_le32(reply) != index) {
		octep->rpc_last_error = -EPROTO;
		err = -EPROTO;
		goto out;
	}
	octep->rpc_mflow_read_index = index;
	memcpy(octep->rpc_mflow_read_reply, reply,
	       OCTEP_RPC_MFLOW_READ_REPLY_LEN);
	octep->rpc_mflow_read_valid = true;
out:
	mutex_unlock(&octep->lock);
	return err ? err : (ssize_t)count;
}
static DEVICE_ATTR_RW(rpc_mflow_read);

static ssize_t rpc_conn_read_show(struct device *dev,
				 struct device_attribute *attr, char *buf)
{
	struct octep *octep = dev_get_drvdata(dev);
	ssize_t len;
	unsigned int i;

	mutex_lock(&octep->lock);
	if (!octep->rpc_conn_read_valid) {
		len = sysfs_emit(buf, "no connection read is available\n");
		goto out;
	}
	len = sysfs_emit(buf, "requested_index=%u reply_index=%u reply_len=%u raw=",
			 octep->rpc_conn_read_index,
			 get_unaligned_le32(octep->rpc_conn_read_reply),
			 octep->rpc_conn_read_len);
	for (i = 0; i < octep->rpc_conn_read_len; i++)
		len += sysfs_emit_at(buf, len, "%s%02x", i ? " " : "",
				     octep->rpc_conn_read_reply[i]);
	len += sysfs_emit_at(buf, len, "\n");
out:
	mutex_unlock(&octep->lock);
	return len;
}

static ssize_t rpc_conn_read_store(struct device *dev,
				  struct device_attribute *attr,
				  const char *buf, size_t count)
{
	struct octep *octep = dev_get_drvdata(dev);
	u8 request[OCTEP_RPC_TBL_REQ_LEN] = {};
	const u8 *reply;
	u32 index;
	int err;

	mutex_lock(&octep->lock);
	octep->rpc_conn_read_valid = false;
	err = kstrtou32(buf, 0, &index);
	if (err)
		goto out;
	if (!octep->rpc_platform_known) {
		err = -EOPNOTSUPP;
		goto out;
	}
	if (index >= octep->rpc_platform_conn) {
		err = -ERANGE;
		goto out;
	}
	put_unaligned_le32(index, request);
	put_unaligned_le16(1, request + 4);
	put_unaligned_le16(OCTEP_RPC_TABLE_FLAG_READ_ALL, request + 6);
	put_unaligned_le32(index, request + 8);
	err = octep_rpc_post_command_locked(octep, OCTEP_RPC_CMD_LO_CONN_READ,
					    request, sizeof(request));
	if (err)
		goto out;
	reply = (u8 *)octep->rpc_cmd.vaddr + OCTEP_RPC_BUF_DESC_SIZE;
	if (octep->rpc_last_len < 12 ||
	    octep->rpc_last_len > sizeof(octep->rpc_conn_read_reply) ||
	    get_unaligned_le32(reply) != index) {
		octep->rpc_last_error = -EPROTO;
		err = -EPROTO;
		goto out;
	}
	octep->rpc_conn_read_index = index;
	octep->rpc_conn_read_len = octep->rpc_last_len;
	memcpy(octep->rpc_conn_read_reply, reply, octep->rpc_last_len);
	octep->rpc_conn_read_valid = true;
out:
	mutex_unlock(&octep->lock);
	return err ? err : (ssize_t)count;
}
static DEVICE_ATTR_RW(rpc_conn_read);

static ssize_t rpc_pport_update_store(struct device *dev,
				      struct device_attribute *attr,
				      const char *buf, size_t count)
{
	struct octep *octep = dev_get_drvdata(dev);
	u8 payload[4];
	u32 iface, tag;
	int err;

	if (sscanf(buf, "%u %u", &iface, &tag) != 2)
		return -EINVAL;
	if (iface > 0x7f || tag > U16_MAX)
		return -ERANGE;
	payload[0] = iface;
	payload[1] = 0;
	payload[2] = tag & 0xff;
	payload[3] = tag >> 8;

	mutex_lock(&octep->lock);
	err = octep_rpc_post_command_locked(octep,
					    OCTEP_RPC_CMD_PPORT_UPDATE,
					    payload, sizeof(payload));
	mutex_unlock(&octep->lock);
	return err ? err : count;
}
static DEVICE_ATTR_WO(rpc_pport_update);

static ssize_t rpc_fw_rev_bump_store(struct device *dev,
				     struct device_attribute *attr,
				     const char *buf, size_t count)
{
	struct octep *octep = dev_get_drvdata(dev);
	u8 payload[2];
	u32 value;
	u16 revision;
	int err;

	err = kstrtou32(buf, 0, &value);
	if (err)
		return err;
	if (value != 1)
		return -EINVAL;

	mutex_lock(&octep->lock);
	revision = octep->rpc_fw_rev + 1;
	payload[0] = revision & 0xff;
	payload[1] = revision >> 8;
	err = octep_rpc_post_command_locked(octep,
					    OCTEP_RPC_CMD_FW_STATE_REV_SET,
					    payload, sizeof(payload));
	if (!err) {
		octep->rpc_fw_rev = revision;
		octep->rpc_fw_rev_bumps++;
	}
	mutex_unlock(&octep->lock);
	return err ? err : count;
}
static DEVICE_ATTR_WO(rpc_fw_rev_bump);

static int octep_rpc_read_connection_locked(struct octep *octep, u32 index,
					     const u8 **entry)
{
	u8 request[OCTEP_RPC_TBL_REQ_LEN] = {};
	const u8 *reply;
	int err;

	put_unaligned_le32(index, request);
	put_unaligned_le16(1, request + 4);
	put_unaligned_le16(OCTEP_RPC_TABLE_FLAG_READ_ALL, request + 6);
	put_unaligned_le32(index, request + 8);
	err = octep_rpc_post_command_locked(octep, OCTEP_RPC_CMD_LO_CONN_READ,
					    request, sizeof(request));
	if (err)
		return err;
	/* Known formats contain a 108-byte entry after a 4- or 8-byte header. */
	if (octep->rpc_last_len != 112 && octep->rpc_last_len != 116) {
		octep->rpc_last_error = -EPROTO;
		return -EPROTO;
	}
	reply = (u8 *)octep->rpc_cmd.vaddr + OCTEP_RPC_BUF_DESC_SIZE;
	if (get_unaligned_le32(reply) != index) {
		octep->rpc_last_error = -EPROTO;
		return -EPROTO;
	}
	*entry = reply + octep->rpc_last_len - 108;
	return 0;
}

static int octep_rpc_mflow_read_locked(struct octep *octep, u32 index,
				       const u8 **reply)
{
	u8 request[OCTEP_RPC_TBL_REQ_LEN] = {};
	int err;

	put_unaligned_le32(index, request);
	put_unaligned_le16(1, request + 4);
	put_unaligned_le16(OCTEP_RPC_TABLE_FLAG_READ_ALL, request + 6);
	put_unaligned_le32(index, request + 8);
	err = octep_rpc_post_command_locked(octep,
					    OCTEP_RPC_CMD_LO_MFLOW_READ,
					    request, sizeof(request));
	if (err)
		return err;
	if (octep->rpc_last_len != OCTEP_RPC_MFLOW_READ_REPLY_LEN) {
		octep->rpc_last_error = -EPROTO;
		return -EPROTO;
	}
	*reply = (u8 *)octep->rpc_cmd.vaddr + OCTEP_RPC_BUF_DESC_SIZE;
	if (get_unaligned_le32(*reply) != index) {
		octep->rpc_last_error = -EPROTO;
		return -EPROTO;
	}
	return 0;
}

static int octep_rpc_check_mflow_candidate_locked(struct octep *octep,
						  const u8 *payload,
						  bool verify_operation)
{
	const u8 *reply, *operation;
	u32 identity = get_unaligned_le32(payload);
	u32 index = identity & 0x01ffffff;
	u32 revision = (identity >> 25) & 0x3f;
	u32 operation_mask = GENMASK(31, 23) | GENMASK(19, 0);
	u32 state;
	int err;

	err = octep_rpc_mflow_read_locked(octep, index, &reply);
	if (err)
		return err;
	state = get_unaligned_le32(reply + 84);
	/* A borrowed idle slot has never carried frames; it only has to be free. */
	if (octep->ft_spare_set && octep->ft_spare_id == index) {
		if (!verify_operation)
			return (state >> 16) ? -EBUSY : 0;
	} else {
		if (!((state >> 16) & 0xff) || ((state >> 8) & 0x3f) != revision)
			dev_info(&octep->pdev->dev,
				 "ft: mflow %u state 0x%08x want rev %u\n", index,
				 state, revision);
		if (!((state >> 16) & 0xff))
			return -EAGAIN;
		if (((state >> 8) & 0x3f) != revision)
			return -ESTALE;
	}
	if (!verify_operation)
		return 0;
	operation = reply + 92;
	if (!((state >> 24) & 0xff) ||
	    ((get_unaligned_le32(operation) ^
	      get_unaligned_le32(payload + 4)) & operation_mask) ||
	    ((get_unaligned_le32(operation + 4) ^
	      get_unaligned_le32(payload + 8)) & GENMASK(24, 0)) ||
	    get_unaligned_le32(operation + 8) != get_unaligned_le32(payload + 12) ||
	    get_unaligned_le32(operation + 12) != get_unaligned_le32(payload + 16) ||
	    get_unaligned_le32(operation + 16) != get_unaligned_le32(payload + 20) ||
	    get_unaligned_le16(operation + 20) != get_unaligned_le16(payload + 24)) {
		if (octep_ft_debug) {
			dev_info(&octep->pdev->dev,
				 "ft: dbg verify mismatch mflow %u state 0x%08x\n", index, state);
			print_hex_dump(KERN_INFO, "ft: dbg want: ", DUMP_PREFIX_OFFSET, 16, 1, payload + 4, 22, false);
			print_hex_dump(KERN_INFO, "ft: dbg have: ", DUMP_PREFIX_OFFSET, 16, 1, operation, 22, false);
		}
		return -EIO;
	}
	return 0;
}

static int octep_rpc_check_connection_locked(struct octep *octep,
					      const u8 *payload)
{
	const u8 *entry;
	u32 index = get_unaligned_le32(payload);
	u32 flags_mask = GENMASK(31, 30) | GENMASK(22, 19) | GENMASK(15, 0);
	int err;

	err = octep_rpc_read_connection_locked(octep, index, &entry);
	if (err)
		return err;
	if (((get_unaligned_le32(entry) ^ get_unaligned_le32(payload + 4)) &
	     flags_mask) ||
	    get_unaligned_le32(entry + 8) != get_unaligned_le32(payload + 12) ||
	    memcmp(entry + 80, payload + 84, 24)) {
		if (octep_ft_debug) {
			dev_info(&octep->pdev->dev,
				 "ft: dbg conn verify mismatch conn %u\n", index);
			print_hex_dump(KERN_INFO, "ft: dbg conn want: ", DUMP_PREFIX_OFFSET, 16, 1, payload + 4, 16, false);
			print_hex_dump(KERN_INFO, "ft: dbg conn have: ", DUMP_PREFIX_OFFSET, 16, 1, entry, 16, false);
		}
		return -EIO;
	}
	return 0;
}

/* Validate, post and verify one flow command; callers hold octep->lock. */
static int octep_rpc_flow_write_locked(struct octep *octep, u32 command,
				       const u8 *payload, size_t payload_len)
{
	bool submitted = false, clear;
	int err;

	if (!octep->rpc_allow_write)
		err = -EPERM;
	else
		err = octep_rpc_validate_flow_command(octep, command, payload, payload_len);
	clear = command == OCTEP_RPC_CMD_MFLOW_PROGRAM &&
		!(get_unaligned_le32(payload + 4) >> 28);
	if (!err && command == OCTEP_RPC_CMD_MFLOW_PROGRAM && !clear)
		err = octep_rpc_check_mflow_candidate_locked(octep, payload, false);
	if (!err && command == OCTEP_RPC_CMD_FLOW_CREATE_FP) {
		err = octep_rpc_check_mflow_candidate_locked(
			octep, payload + OCTEP_RPC_FLOW_OFF_MFLOW_O, false);
		if (!err && get_unaligned_le32(payload + OCTEP_RPC_FLOW_OFF_VALID) &
		    OCTEP_RPC_FLOW_VALID_REPLY)
			err = octep_rpc_check_mflow_candidate_locked(
				octep, payload + OCTEP_RPC_FLOW_OFF_MFLOW_R, false);
	}
	if (!err) {
		submitted = command == OCTEP_RPC_CMD_MFLOW_PROGRAM ||
			    command == OCTEP_RPC_CMD_FLOW_CREATE_FP;
		err = octep_rpc_post_command_locked(octep, command, payload,
						    payload_len);
	}
	if (!err && command == OCTEP_RPC_CMD_MFLOW_PROGRAM && !clear)
		err = octep_rpc_check_mflow_candidate_locked(octep, payload, true);
	else if (!err && command == OCTEP_RPC_CMD_FLOW_CREATE_FP) {
		unsigned int attempt;

		/* The firmware may need a moment to publish the programmed entries; retry the read-back. */
		for (attempt = 0; attempt < 3; attempt++) {
			if (attempt)
				msleep(5);
			err = octep_rpc_check_mflow_candidate_locked(
				octep, payload + OCTEP_RPC_FLOW_OFF_MFLOW_O, true);
			if (!err && get_unaligned_le32(payload + OCTEP_RPC_FLOW_OFF_VALID) &
			    OCTEP_RPC_FLOW_VALID_REPLY)
				err = octep_rpc_check_mflow_candidate_locked(
					octep, payload + OCTEP_RPC_FLOW_OFF_MFLOW_R, true);
			if (!err)
				err = octep_rpc_check_connection_locked(octep, payload);
			if (err != -EIO)
				break;
		}
		if (attempt && octep_ft_debug)
			dev_info(&octep->pdev->dev,
				 "ft: dbg flow-create verify took %u read-back(s), result %d\n",
				 min(attempt + 1, 3u), err);
	}
	if (err && submitted)
		dev_warn(&octep->pdev->dev,
			 "rpc: flow write or verification failed (%d); submitted flow may remain active\n",
			 err);

	return err;
}

/* Reclaim a firmware connection by index, reading its current revision first. */
static int octep_ft_reclaim_conn_locked(struct octep *octep, u32 conn)
{
	u8 request[OCTEP_RPC_CONN_RECLAIM_REQ_LEN] = {};
	const u8 *entry;
	u32 flags;
	int err;

	err = octep_rpc_read_connection_locked(octep, conn, &entry);
	if (err)
		return err;
	flags = get_unaligned_le32(entry);
	if ((flags >> 30) != OCTEP_RPC_CONN_STATE_VALID &&
	    (flags >> 30) != OCTEP_RPC_CONN_STATE_RECLAIM_PENDING)
		return 0;
	put_unaligned_le32(conn, request);
	put_unaligned_le16(flags & 0xffff, request + 4);
	return octep_rpc_post_command_locked(octep, OCTEP_RPC_CMD_CONN_RECLAIM_FP,
					     request, sizeof(request));
}

/* Reclaim the connection, clear both microflow slots and forget the pairing. */
/* Reclaim a connection entry and clear both of its microflows. */
static void octep_ft_teardown_locked(struct octep *octep, unsigned int slot,
				     const u32 id[2], const u32 rev[2])
{
	struct octep_rpc_mflow_payload m;
	unsigned int i;

	octep_ft_reclaim_conn_locked(octep, OCTEP_FT_CONN_BASE + slot);
	for (i = 0; i < 2; i++) {
		octep_ft_fill_mflow_clear(&m, id[i], rev[i],
					  OCTEP_FT_CONN_BASE + slot, 1,
					  octep->rpc_fw_rev, 0,
					  OCTEP_FT_NHOP_BASE + 2 * slot + i);
		octep_rpc_flow_write_locked(octep, OCTEP_RPC_CMD_MFLOW_PROGRAM,
					    (const u8 *)&m, sizeof(m));
	}
}

static void octep_ft_release_locked(struct octep *octep, unsigned int slot)
{
	struct octep_ft_conn *c = &octep->ft_conn[slot];
	unsigned int i;

	if (!c->used)
		return;
	octep_ft_teardown_locked(octep, slot, c->id, c->rev);
	c->used = false;
	for (i = 0; i < OCTEP_FT_MAX; i++)
		if (octep->ft_ent[i].used && octep->ft_ent[i].conn == (int)slot)
			octep->ft_ent[i].conn = -1;
	dev_info(&octep->pdev->dev, "ft: released conn %u\n",
		 OCTEP_FT_CONN_BASE + slot);
}

static void octep_ft_reclaim_all_locked(struct octep *octep)
{
	unsigned int i;

	for (i = 0; i < OCTEP_FT_CONNS; i++)
		octep_ft_release_locked(octep, i);
}

/*
 * Wire layout of the 60-byte TCP block at flow-create offset 24 (struct octep_rpc_flow_create_payload
 * tcp_state[60]), reverse engineered from a sibling FreeBSD driver for the same NPU family
 * (os-xgs-npu, octep.h ~1900-1935): NOT a raw dump of Linux's struct ip_ct_tcp (whose per-direction
 * td_scale/flags trailing bytes misalign direction 1 by 4 bytes and scramble the flags word below).
 * Instead, per direction d (0=orig,1=reply), 16 bytes packed tight at d*16: td_end, td_maxend,
 * td_maxwin (already window-scaled by conntrack), and at +12 the OTHER direction's td_end (the
 * reference driver fills this from "the other peer's seqlo" - cross direction, not this
 * direction's own td_maxack). Offset 56 is a flags word: bit0
 * SEQ_CHK_ON, bit1/bit2 LIBERAL_ORIG/LIBERAL_REPLY (both set so the hardware tolerates the gap
 * between conntrack's snapshot and the frames in flight when the flow goes hot), and the two
 * window scales in the top two bytes (reply at bits 16-23, orig at bits 24-31).
 */
#define OCTEP_TCP_SEEN(d)		((d) * 16)
#define OCTEP_TCP_OFF_FLAGS		56
#define OCTEP_TCP_SEQ_CHK_ON		0x00000001u
#define OCTEP_TCP_LIBERAL_ORIG		0x00000002u
#define OCTEP_TCP_LIBERAL_REPLY	0x00000004u
#define OCTEP_TCP_SCALE_REPLY_SHIFT	16
#define OCTEP_TCP_SCALE_ORIG_SHIFT	24

/* Fresh conntrack TCP window/state for the original-direction tuple; false when there is no TCP conntrack entry. */
static bool octep_ft_copy_tcp_state(const struct octep_ft_ent *e, u8 *out)
{
	struct nf_conntrack_tuple t = {};
	struct nf_conntrack_tuple_hash *h;
	struct nf_conn *ct;
	struct ip_ct_tcp_state *seen;
	u32 flags;
	int d;

	if (e->proto != IPPROTO_TCP)
		return false;
	t.src.l3num = AF_INET;
	t.src.u3.ip = e->src;
	t.src.u.tcp.port = htons(e->sport);
	t.dst.u3.ip = e->dst;
	t.dst.u.tcp.port = htons(e->dport);
	t.dst.protonum = IPPROTO_TCP;
	t.dst.dir = IP_CT_DIR_ORIGINAL;
	h = nf_conntrack_find_get(&init_net, &nf_ct_zone_dflt, &t);
	if (!h)
		return false;
	ct = nf_ct_tuplehash_to_ctrack(h);
	spin_lock_bh(&ct->lock);
	seen = ct->proto.tcp.seen;
	for (d = 0; d < 2; d++) {
		if (!octep_ft_tcp_room) {
			/* Raw conntrack snapshot, as in the 11-18 14:57 build (8 s of NPU forwarding) */
			put_unaligned_le32(seen[d].td_end, out + OCTEP_TCP_SEEN(d) + 0);
			put_unaligned_le32(seen[d].td_maxend, out + OCTEP_TCP_SEEN(d) + 4);
			put_unaligned_le32(seen[d].td_maxwin, out + OCTEP_TCP_SEEN(d) + 8);
			put_unaligned_le32(seen[d ^ 1].td_end, out + OCTEP_TCP_SEEN(d) + 12);
			continue;
		}
		/*
		 * conntrack's td_maxwin on a fresh flow is the unscaled SYN/SYN-ACK window
		 * (e.g. 65535 for a peer scaling by 14), far below what the peer advertises
		 * once data flows. Floor each window at the largest value its scale can
		 * express so the NPU never sees a window beyond its tracked maximum.
		 */
		u32 w = max_t(u32, seen[d].td_maxwin, 0xffffu << seen[d].td_scale) ?: 1;
		u32 wo = max_t(u32, seen[d ^ 1].td_maxwin, 0xffffu << seen[d ^ 1].td_scale) ?: 1;
		u32 room = octep_ft_tcp_room < 0 ? max_t(u32, 16u << 20, min_t(u32, 2 * w, 1u << 28)) :
			   (u32)octep_ft_tcp_room << 20;
		u32 room_o = octep_ft_tcp_room < 0 ? max_t(u32, 16u << 20, min_t(u32, 2 * wo, 1u << 28)) :
			     (u32)octep_ft_tcp_room << 20;
		u32 maxend = seen[d].td_maxend;
		u32 reach = seen[d ^ 1].td_end + wo;

		if ((s32)(reach - maxend) > 0)
			maxend = reach;
		/* Headroom as on BSD: the snapshot window is exhausted within one cwnd */
		put_unaligned_le32(seen[d].td_end, out + OCTEP_TCP_SEEN(d) + 0);
		put_unaligned_le32(maxend + room_o, out + OCTEP_TCP_SEEN(d) + 4);
		put_unaligned_le32(w + room, out + OCTEP_TCP_SEEN(d) + 8);
		put_unaligned_le32(seen[d ^ 1].td_end, out + OCTEP_TCP_SEEN(d) + 12);
	}
	flags = OCTEP_TCP_SEQ_CHK_ON | OCTEP_TCP_LIBERAL_ORIG | OCTEP_TCP_LIBERAL_REPLY |
		((u32)seen[1].td_scale << OCTEP_TCP_SCALE_REPLY_SHIFT) |
		((u32)seen[0].td_scale << OCTEP_TCP_SCALE_ORIG_SHIFT);
	spin_unlock_bh(&ct->lock);
	nf_ct_put(ct);
	put_unaligned_le32(flags, out + OCTEP_TCP_OFF_FLAGS);
	return true;
}

/*
 * Host TCP view for the cut-in gate. Only the last packet's ACK is known, so in-flight is
 * measurable when that packet was an ACK: the opposite direction's sent end minus that ACK.
 */
static int octep_ft_tcp_gate(const struct octep_ft_ent *e, u32 *inflight, u8 *retrans, u8 *state)
{
	struct nf_conntrack_tuple t = {};
	struct nf_conntrack_tuple_hash *h;
	struct nf_conn *ct;
	u8 dir;

	t.src.l3num = AF_INET;
	t.src.u3.ip = e->src;
	t.src.u.tcp.port = htons(e->sport);
	t.dst.u3.ip = e->dst;
	t.dst.u.tcp.port = htons(e->dport);
	t.dst.protonum = IPPROTO_TCP;
	t.dst.dir = IP_CT_DIR_ORIGINAL;
	h = nf_conntrack_find_get(&init_net, &nf_ct_zone_dflt, &t);
	if (!h)
		return -ENOENT;
	ct = nf_ct_tuplehash_to_ctrack(h);
	spin_lock_bh(&ct->lock);
	*state = ct->proto.tcp.state;
	*retrans = ct->proto.tcp.retrans;
	dir = ct->proto.tcp.last_dir;
	/* A pure ACK in the other direction acknowledges the data of direction !dir. */
	*inflight = ct->proto.tcp.seen[!dir].td_end - ct->proto.tcp.last_ack;
	if ((s32)*inflight < 0)
		*inflight = 0;
	if (ct->proto.tcp.last_end != ct->proto.tcp.last_seq)
		*inflight = U32_MAX;
	spin_unlock_bh(&ct->lock);
	nf_ct_put(ct);
	return 0;
}

/*
 * Program one connection: reply = the flow the wire is presenting (hot
 * candidate), orig = its paired entry on a borrowed idle slot.
 */
static void octep_ft_program_locked(struct octep *octep,
				    const struct octep_rx_flow_track *partner,
				    const struct octep_rx_flow_track *hot,
				    const struct octep_ft_ent *reply,
				    const struct octep_ft_ent *orig)
{
	struct octep_rpc_nhop_payload nh[2];
	struct octep_rpc_flow_create_payload fc;
	struct octep_rpc_mflow_payload mo, mr;
	struct octep_ft_nat nat = {};
	const struct octep_ft_ent *corig, *crep;
	const struct octep_rx_flow_track *sp;
	unsigned int slot;
	bool hot_is_orig;
	int err = -ENOSPC;
	const char *step = "none";
	u32 last_spare = 0;

	/*
	 * The two tuples of a flow sit in one array in struct flow_offload and
	 * the cookie is the tuple address, so the original direction is the
	 * lower one. NAT and the next hops follow conntrack direction; the hot
	 * wire flow takes whichever microflow matches its own direction.
	 */
	corig = reply->cookie < orig->cookie ? reply : orig;
	crep = corig == reply ? orig : reply;
	hot_is_orig = corig == reply;

	for (slot = 0; slot < OCTEP_FT_CONNS; slot++)
		if (!octep->ft_conn[slot].used)
			break;
	if (slot == OCTEP_FT_CONNS || !octep->rpc_platform_known ||
	    OCTEP_FT_CONN_BASE + slot >= octep->rpc_platform_conn ||
	    OCTEP_FT_NHOP_BASE + 2 * slot + 1 >= octep->rpc_platform_nhop)
		return;

	octep_ft_fill_nhop(&nh[0], OCTEP_FT_NHOP_BASE + 2 * slot, 0, corig->dmac,
			   corig->smac,
			   corig->iface + OCTEP_FT_NWA_IFACE_BASE, corig->tag,
			   min_t(unsigned int, octep_ft_nhop_mtu, U16_MAX));
	octep_ft_fill_nhop(&nh[1], OCTEP_FT_NHOP_BASE + 2 * slot + 1, 0,
			   crep->dmac, crep->smac,
			   crep->iface + OCTEP_FT_NWA_IFACE_BASE, crep->tag,
			   min_t(unsigned int, octep_ft_nhop_mtu, U16_MAX));
	nat.orig_src = corig->src;
	nat.orig_dst = corig->dst;
	nat.nat_src = corig->nsrc;
	nat.nat_dst = corig->ndst;
	nat.orig_dst_port = htons(corig->dport);
	nat.orig_src_port = htons(corig->sport);
	nat.nat_dst_port = htons(corig->ndport);
	nat.nat_src_port = htons(corig->nsport);
	nat.snat = corig->nsrc != corig->src || corig->nsport != corig->sport;
	nat.dnat = corig->ndst != corig->dst || corig->ndport != corig->dport;

	sp = partner;
	if (OCTEP_FT_FEAT(octep_ft_flow_state) && !octep->rpc_fw_rev) {
		dev_info_ratelimited(&octep->pdev->dev,
				     "ft: dbg state gate: firmware state revision is 0, not programming hot id %u\n",
				     hot->id);
		return;
	}
	last_spare = sp->id;
	octep->ft_spare_id = sp->id;
	/* A live partner is a normal slot; only an idle borrowed one gets the relaxed spare checks. */
	octep->ft_spare_set = jiffies_to_msecs(jiffies - sp->last_seen) > OCTEP_FT_MAX_AGE_MS;
	octep_ft_fill_mflow(&mo, hot_is_orig ? hot->id : sp->id,
			    hot_is_orig ? hot->revision : sp->revision, 0,
			    octep_ft_first_action(),
			    OCTEP_FT_CONN_BASE + slot, 1,
			    octep->rpc_fw_rev, octep_ft_l3_rev,
			    OCTEP_FT_NHOP_BASE + 2 * slot, 0,
			    octep_ft_eff_timeout(), octep_ft_eff_brctl(corig->bridged));
	octep_ft_fill_mflow(&mr, hot_is_orig ? sp->id : hot->id,
			    hot_is_orig ? sp->revision : hot->revision, 1,
			    octep_ft_first_action(),
			    OCTEP_FT_CONN_BASE + slot, 1,
			    octep->rpc_fw_rev, octep_ft_l3_rev,
			    OCTEP_FT_NHOP_BASE + 2 * slot + 1, 0,
			    octep_ft_eff_timeout(), octep_ft_eff_brctl(corig->bridged));
	octep_ft_fill_flow(&fc, OCTEP_FT_CONN_BASE + slot, 1, &mo, &mr,
			   nat.snat || nat.dnat ? &nat : NULL);
	if (octep_ft_tcp_state &&
	    octep_ft_copy_tcp_state(corig, fc.tcp_state) && octep_ft_debug)
		print_hex_dump(KERN_INFO, "ft: dbg tcp-state: ", DUMP_PREFIX_OFFSET,
			       16, 1, fc.tcp_state, sizeof(fc.tcp_state), false);
	step = "nhop0";
	err = octep_rpc_flow_write_locked(octep, OCTEP_RPC_CMD_NHOP_PROGRAM,
					  (const u8 *)&nh[0], sizeof(nh[0]));
	if (!err) {
		step = "nhop1";
		err = octep_rpc_flow_write_locked(octep, OCTEP_RPC_CMD_NHOP_PROGRAM,
						  (const u8 *)&nh[1], sizeof(nh[1]));
	}
	if (!err) {
		step = "flow-create";
		err = octep_rpc_flow_write_locked(octep, OCTEP_RPC_CMD_FLOW_CREATE_FP,
						  (const u8 *)&fc, sizeof(fc));
	}
	octep->ft_spare_set = false;
	if (!err) {
		if (octep_ft_debug) {
			print_hex_dump(KERN_INFO, "ft: dbg nhop-orig: ", DUMP_PREFIX_OFFSET, 16, 1, &nh[0], sizeof(nh[0]), false);
			print_hex_dump(KERN_INFO, "ft: dbg nhop-reply: ", DUMP_PREFIX_OFFSET, 16, 1, &nh[1], sizeof(nh[1]), false);
			print_hex_dump(KERN_INFO, "ft: dbg mflow-orig: ", DUMP_PREFIX_OFFSET, 16, 1, &mo, sizeof(mo), false);
			print_hex_dump(KERN_INFO, "ft: dbg mflow-reply: ", DUMP_PREFIX_OFFSET, 16, 1, &mr, sizeof(mr), false);
			print_hex_dump(KERN_INFO, "ft: dbg flow-create: ", DUMP_PREFIX_OFFSET, 16, 1, &fc, sizeof(fc), false);
		}
		octep->ft_conn[slot].used = true;
		octep->ft_conn[slot].fc = fc;
		octep->ft_conn[slot].revives = 0;
		octep->ft_conn[slot].since = jiffies;
		octep->ft_conn[slot].alloc_next = jiffies;
		octep->ft_conn[slot].alloc_ts[0] = 0;
		octep->ft_conn[slot].alloc_ts[1] = 0;
		octep->ft_conn[slot].tup = *corig;
		octep->ft_conn[slot].pkts_seen = 0;
		octep->ft_conn[slot].cutin_pending = octep_ft_cutin && octep_ft_cutin_ms;
		octep->ft_conn[slot].cutin_at = jiffies + msecs_to_jiffies(octep_ft_cutin_ms);
		octep->ft_conn[slot].blackhole_checked = false;
		octep->ft_conn[slot].hw_active = false;
		octep->ft_conn[slot].reply_ts = 0;
		octep->ft_conn[slot].reply_ts_moved = jiffies;
		octep->ft_conn[slot].reply_ts_poll = jiffies;
		mod_delayed_work(system_wq, &octep->ft_guard_work, msecs_to_jiffies(10));
		octep->ft_conn[slot].rearm = jiffies;
		octep->ft_conn[slot].id[0] = hot_is_orig ? hot->id : sp->id;
		octep->ft_conn[slot].rev[0] = hot_is_orig ? hot->revision : sp->revision;
		octep->ft_conn[slot].id[1] = hot_is_orig ? sp->id : hot->id;
		octep->ft_conn[slot].rev[1] = hot_is_orig ? sp->revision : hot->revision;
		((struct octep_ft_ent *)reply)->conn = slot;
		((struct octep_ft_ent *)orig)->conn = slot;
		dev_info(&octep->pdev->dev,
			 "ft: offloaded conn %u reply id %u orig id %u%s proto %u %pI4:%u -> %pI4:%u (nat %pI4:%u -> %pI4:%u)\n",
			 OCTEP_FT_CONN_BASE + slot,
			 hot_is_orig ? sp->id : hot->id,
			 hot_is_orig ? hot->id : sp->id,
			 nat.snat || nat.dnat ? " (NAT)" : "",
			 corig->proto, &corig->src, corig->sport,
			 &corig->dst, corig->dport,
			 &corig->nsrc, corig->nsport,
			 &corig->ndst, corig->ndport);
		dev_info(&octep->pdev->dev,
			 "ft: ids conn %u hot id %u rev %u tag 0x%x frames %llu age %ums valid %d | partner id %u rev %u tag 0x%x frames %llu age %ums valid %d spare %d\n",
			 OCTEP_FT_CONN_BASE + slot,
			 hot->id, hot->revision, hot->tag, hot->frames,
			 jiffies_to_msecs(jiffies - hot->last_seen), hot->tuple_valid,
			 sp->id, sp->revision, sp->tag, sp->frames,
			 jiffies_to_msecs(jiffies - sp->last_seen), sp->tuple_valid,
			 jiffies_to_msecs(jiffies - sp->last_seen) > OCTEP_FT_MAX_AGE_MS);
		return;
	}
	dev_info(&octep->pdev->dev,
		 "ft: program failed at %s (%d) hot id %u spare id %u\n",
		 step, err, hot->id, last_spare);
	/* A refused write changes nothing; a failed verify leaves half a flow that blackholes the hot slot (run 12). */
	if (err != -EAGAIN && err != -ESTALE && err != -EBUSY) {
		const u32 tid[2] = { hot_is_orig ? hot->id : sp->id,
				     hot_is_orig ? sp->id : hot->id };
		const u32 trev[2] = { hot_is_orig ? hot->revision : sp->revision,
				      hot_is_orig ? sp->revision : hot->revision };

		octep_ft_teardown_locked(octep, slot, tid, trev);
		dev_info(&octep->pdev->dev,
			 "ft: rolled back conn %u after failed %s\n",
			 OCTEP_FT_CONN_BASE + slot, step);
	}
	if (err == -EAGAIN) {
		octep_rpc_check_mflow_candidate_locked(octep, (const u8 *)&mo, false);
		octep_rpc_check_mflow_candidate_locked(octep, (const u8 *)&mr, false);
	}
	/* Back off 2, 4, 8 ... 32 s so a refused pair does not load the NPU every second. */
	{
		struct octep_ft_ent *fe = (struct octep_ft_ent *)reply;
		struct octep_ft_ent *fo = (struct octep_ft_ent *)orig;
		u8 n = min_t(u8, fe->fails + 1, 5);

		fe->fails = fo->fails = n;
		fe->bad_spare = fo->bad_spare = last_spare;
		fe->retry_at = fo->retry_at = jiffies + (HZ << n);
	}
}

/*
 * Proactively re-issue MFLOW_PROGRAM for both directions of every live connection, well inside
 * ft_mflow_timeout, so a genuinely busy flow cannot be aged out by firmware even though its own
 * traffic should (per vendor design) have kept it alive on its own. See ft_mflow_rearm comment.
 *
 * Bug fixed here (live readback showed fw_valid 1->0, state 2->0, firmware revision bumping to 1
 * right after a rearm, while host_valid stayed 1): we were resending the *same* id_rev every
 * cycle. Firmware reads a repeat of an already-committed id_rev as nothing new to confirm and
 * drops the slot back to invalid/inactive instead of refreshing its timeout. id_rev only has 6
 * bits of room in the payload (id | id_rev << 25 | BIT(31)), so bump it with wraparound on every
 * rearm the same way a fresh program would, and keep our own copy in sync for the next cycle and
 * for teardown/rollback, which also need the id's current revision.
 */
static void octep_ft_rearm_locked(struct octep *octep)
{
	struct octep_rpc_mflow_payload m;
	unsigned int slot, i;

	unsigned int rearm_secs;

	if (octep_ft_mflow_rearm <= 0 && !OCTEP_FT_FEAT(octep_ft_mflow_parity))
		return;
	/*
	 * ft_mflow_rearm is a live 0644 knob; clamp it against the current ft_mflow_timeout on
	 * every call instead of only at probe() so a bad runtime write (rearm >= timeout) can't
	 * put us right back into the same collapse this function exists to avoid.
	 */
	rearm_secs = OCTEP_FT_FEAT(octep_ft_mflow_parity) ? 25 :
		     (unsigned int)octep_ft_mflow_rearm;
	if (octep_ft_eff_timeout() > 5 && rearm_secs >= octep_ft_eff_timeout())
		rearm_secs = octep_ft_eff_timeout() - 5;
	for (slot = 0; slot < OCTEP_FT_CONNS; slot++) {
		struct octep_ft_conn *c = &octep->ft_conn[slot];

		if (!c->used)
			continue;
		if (time_before(jiffies, c->rearm + rearm_secs * HZ))
			continue;
		c->rearm = jiffies;
		for (i = 0; i < 2; i++) {
			c->rev[i] = (c->rev[i] + 1) & 0x3f;
			octep_ft_fill_mflow(&m, c->id[i], c->rev[i], i,
					    c->cutin_pending ? octep_ft_first_action() : (u32)octep_ft_mflow_action,
					    OCTEP_FT_CONN_BASE + slot, 1,
					    octep->rpc_fw_rev, octep_ft_l3_rev,
					    OCTEP_FT_NHOP_BASE + 2 * slot + i, 0,
					    octep_ft_eff_timeout(),
					    octep_ft_eff_brctl(c->tup.bridged));
			octep_rpc_flow_write_locked(octep, OCTEP_RPC_CMD_MFLOW_PROGRAM,
						    (const u8 *)&m, sizeof(m));
		}
		dev_info_ratelimited(&octep->pdev->dev,
				     "ft: rearmed conn %u ids %u/%u rev %u/%u\n",
				     OCTEP_FT_CONN_BASE + slot, c->id[0], c->id[1],
				     c->rev[0], c->rev[1]);
	}
}

/* Per-second NPU view of a fresh connection: both microflow states and the connection entry. */
static void octep_ft_debug_conn_locked(struct octep *octep, unsigned int slot)
{
	const struct octep_ft_conn *c = &octep->ft_conn[slot];
	const u8 *mf, *ce;
	u32 st[2] = {};
	int err[2], cerr;
	unsigned int i;

	for (i = 0; i < 2; i++) {
		err[i] = octep_rpc_mflow_read_locked(octep, c->id[i], &mf);
		if (!err[i])
			st[i] = get_unaligned_le32(mf + 84);
	}
	cerr = octep_rpc_read_connection_locked(octep, OCTEP_FT_CONN_BASE + slot, &ce);
	dev_info(&octep->pdev->dev,
		 "ft: dbg conn %u +%ums orig id %u state 0x%08x (%d) reply id %u state 0x%08x (%d) conn %d %*ph\n",
		 OCTEP_FT_CONN_BASE + slot,
		 jiffies_to_msecs(jiffies - c->since), c->id[0], st[0], err[0],
		 c->id[1], st[1], err[1], cerr, cerr ? 0 : 32, cerr ? NULL : ce);
	if (cerr)
		return;
	/* Whole NPU conn entry against the TCP block we sent, to see whether the NPU's window state still matches the host snapshot. */
	dev_info(&octep->pdev->dev, "ft: dbg npu conn[0..63] %64ph\n", ce);
	dev_info(&octep->pdev->dev, "ft: dbg npu conn[64..107] %44ph\n", ce + 64);
	dev_info(&octep->pdev->dev, "ft: dbg sent tcp[0..59] %60ph\n", c->fc.tcp_state);
}

/* Second half of make-before-break: flip a staged conn's microflows to the forward action and log it. */
static void octep_ft_cutin_locked(struct octep *octep)
{
	struct octep_rpc_mflow_payload m;
	unsigned int slot, i;

	for (slot = 0; slot < OCTEP_FT_CONNS; slot++) {
		struct octep_ft_conn *c = &octep->ft_conn[slot];
		int err[2] = {};

		const u8 *mf, *ce;
		const char *why = NULL;
		u32 inflight = 0;
		u8 retrans = 0, tstate = 0;
		bool timed_out;

		if (!c->used || !c->cutin_pending || time_before(jiffies, c->cutin_at))
			continue;
		timed_out = time_after(jiffies, c->cutin_at + msecs_to_jiffies(octep_ft_cutin_wait_ms));
		/* Flow status checks first: NPU reads and, for TCP, state, retransmits and unacked bytes. */
		if (octep_rpc_read_connection_locked(octep, OCTEP_FT_CONN_BASE + slot, &ce))
			why = "npu conn unreadable";
		else if (octep_rpc_mflow_read_locked(octep, c->id[0], &mf) ||
			 octep_rpc_mflow_read_locked(octep, c->id[1], &mf))
			why = "npu microflow unreadable";
		else if (c->tup.proto == IPPROTO_TCP) {
			if (octep_ft_tcp_gate(&c->tup, &inflight, &retrans, &tstate))
				why = "host conntrack gone";
			else if (tstate != TCP_CONNTRACK_ESTABLISHED)
				why = "tcp not established";
			else if (retrans)
				why = "host retransmits";
			else if (inflight > octep_ft_cutin_inflight)
				why = "unacked data above ft_cutin_inflight";
		}
		if (why && !timed_out) {
			dev_info(&octep->pdev->dev,
				 "ft: cut-in conn %u waiting: %s (tcp state %u retrans %u inflight %lld)\n",
				 OCTEP_FT_CONN_BASE + slot, why, tstate, retrans,
				 inflight == U32_MAX ? -1LL : (long long)inflight);
			continue;
		}
		c->rearm = jiffies;
		dev_info(&octep->pdev->dev,
			 "ft: cut-in conn %u: staged %ums, %s, flipping action %d -> %d (tcp state %u retrans %u inflight %lld)\n",
			 OCTEP_FT_CONN_BASE + slot, jiffies_to_msecs(jiffies - c->since),
			 why ? "checks timed out" : "checks passed",
			 octep_ft_cutin_action, octep_ft_mflow_action, tstate, retrans,
			 inflight == U32_MAX ? -1LL : (long long)inflight);
		octep_ft_debug_conn_locked(octep, slot);
		for (i = 0; i < 2; i++) {
			/* The firmware accepts a write only at the slot's current revision (bits 8..13 of the state), so read it, never bump. */
			if (!octep_rpc_mflow_read_locked(octep, c->id[i], &mf))
				c->rev[i] = (get_unaligned_le32(mf + 84) >> 8) & 0x3f;
			octep_ft_fill_mflow(&m, c->id[i], c->rev[i], i,
					    (u32)octep_ft_mflow_action,
					    OCTEP_FT_CONN_BASE + slot, 1,
					    octep->rpc_fw_rev, octep_ft_l3_rev,
					    OCTEP_FT_NHOP_BASE + 2 * slot + i, 0,
					    octep_ft_eff_timeout(),
					    octep_ft_eff_brctl(c->tup.bridged));
			err[i] = octep_rpc_flow_write_locked(octep, OCTEP_RPC_CMD_MFLOW_PROGRAM,
							     (const u8 *)&m, sizeof(m));
		}
		dev_info(&octep->pdev->dev,
			 "ft: cut-in conn %u done rev %u/%u rpc %d/%d\n",
			 OCTEP_FT_CONN_BASE + slot, c->rev[0], c->rev[1], err[0], err[1]);
		if (err[0] || err[1])
			continue;
		/* Forwarding starts now: restart the blackhole and frozen-reply clocks from the flip. */
		c->cutin_pending = false;
		c->since = jiffies;
		c->blackhole_checked = false;
		c->hw_active = false;
		c->reply_ts = 0;
		c->reply_ts_moved = jiffies;
		c->reply_ts_poll = jiffies;
		mod_delayed_work(system_wq, &octep->ft_guard_work, msecs_to_jiffies(10));
		octep_ft_debug_conn_locked(octep, slot);
	}
}

/*
 * A truly offloaded (wire-to-wire) connection is *supposed* to stop producing
 * host-visible frames -- that is the entire point of hardware offload, not a
 * failure symptom. octep_ft_check_blackhole_locked() below used to treat the
 * resulting silence on the rx_flow tracker as proof of a black hole and
 * release the connection within OCTEP_FT_BLACKHOLE_JIFFIES regardless, which
 * tore down every successful offload a few seconds after it started working
 * (confirmed live: WIRE_TO_WIRE counters rising, then "carried no
 * host-visible frames ... released" at the 3s mark). Ask the firmware
 * directly whether the microflow is still active/accepted (fw_valid and
 * state==2) before trusting the host-side silence as a sign of trouble.
 */
static bool octep_ft_mflow_active_locked(struct octep *octep, u32 id)
{
	const u8 *mf;
	u32 entry_state, action;

	if (octep_rpc_mflow_read_locked(octep, id, &mf))
		return false;
	entry_state = get_unaligned_le32(mf + 84);
	action = get_unaligned_le32(mf + 92);
	return ((entry_state >> 16) & 0xff) && (action >> 28) == 2;
}

/* Firmware hit timestamp of a microflow; frozen means no packet matched it. */
static bool octep_ft_mflow_ts_locked(struct octep *octep, u32 id, u32 *ts)
{
	const u8 *mf;

	if (octep_rpc_mflow_read_locked(octep, id, &mf))
		return false;
	*ts = get_unaligned_le32(mf + 72);
	return true;
}

/* Debug: read both microflows back and log what the firmware holds, to compare with what was sent. */
static void octep_ft_dump_mflows_locked(struct octep *octep, struct octep_ft_conn *c,
					const char *why)
{
	static const char * const dir[2] = { "orig", "reply" };
	unsigned int d;

	for (d = 0; d < 2; d++) {
		const u8 *mf;
		u32 es, act, nh;

		if (octep_rpc_mflow_read_locked(octep, c->id[d], &mf)) {
			dev_info(&octep->pdev->dev, "ft: dbg readback %s %s id %u: read failed\n",
				 why, dir[d], c->id[d]);
			continue;
		}
		es = get_unaligned_le32(mf + 84);
		act = get_unaligned_le32(mf + 92);
		nh = get_unaligned_le32(mf + 108);
		dev_info(&octep->pdev->dev,
			 "ft: dbg readback %s %s id %u ts %u timeout %u rev %u fw_valid %u host_valid %u state %u action %u dir %u conn %u nhop %u nhop_rev %u\n",
			 why, dir[d], c->id[d], get_unaligned_le32(mf + 72), get_unaligned_le32(mf + 76),
			 (es >> 8) & 0xff, (es >> 16) & 0xff, (es >> 24) & 0xff, act >> 28,
			 (act >> 16) & 0xf, (act >> 23) & 1, get_unaligned_le32(mf + 100),
			 nh & 0x00ffffff, nh >> 24);
		print_hex_dump(KERN_INFO, "ft: dbg readback-raw: ", DUMP_PREFIX_OFFSET, 16, 1,
			       mf, OCTEP_RPC_MFLOW_READ_REPLY_LEN, false);
	}
}

/*
 * A firmware-active TCP flow whose reply microflow never advances is not
 * forwarding ACKs, so the sender stalls. Polled every 1s (not per tick) to keep
 * RPC load off the shared lock; true once the reply timestamp has been frozen
 * for ft_reply_frozen seconds (default 2).
 */
static bool octep_ft_reply_frozen_locked(struct octep *octep,
					 struct octep_ft_conn *c)
{
	u32 ts;

	if (time_before(jiffies, c->reply_ts_poll + HZ))
		return false;
	c->reply_ts_poll = jiffies;
	if (!octep_ft_mflow_ts_locked(octep, c->id[1], &ts))
		return false;
	if (ts != c->reply_ts) {
		c->reply_ts = ts;
		c->reply_ts_moved = jiffies;
		return false;
	}
	return time_after(jiffies, c->reply_ts_moved + READ_ONCE(octep_ft_reply_frozen_s) * HZ);
}

/*
 * A TCP connection whose NPU-rewritten frames are dropped downstream never gets
 * an ACK back, so no frame of either direction reaches the host after the
 * offload. Reclaim such a connection and keep it on the host slow path.
 */
static void octep_ft_check_blackhole_locked(struct octep *octep,
					    const struct octep_rx_flow_track *tracks)
{
	unsigned int slot, i, k;

	for (slot = 0; slot < OCTEP_FT_CONNS; slot++) {
		struct octep_ft_conn *c = &octep->ft_conn[slot];
		bool seen = false;

		if (octep_ft_debug && c->used &&
		    time_before(jiffies, c->since + 8 * HZ))
			octep_ft_debug_conn_locked(octep, slot);
		/* A staged conn is not forwarding yet, so host silence says nothing until the flip. */
		if (!c->used || c->cutin_pending ||
		    time_before(jiffies, c->since + OCTEP_FT_BLACKHOLE_JIFFIES))
			continue;
		/*
		 * Only pay for the extra RPC round trips once per connection: a long-lived
		 * offloaded flow would otherwise get re-queried every second of its life
		 * (this scan runs on a 1s delayed_work), stacking up RPC latency under the
		 * same global lock that MFLOW_PROGRAM/FLOW_CREATE_FP also need and starving
		 * them -- the exact regression a continuous per-tick check introduced.
		 */
		if (!c->blackhole_checked) {
			c->blackhole_checked = true;
			c->hw_active = octep_ft_mflow_active_locked(octep, c->id[0]) ||
				       octep_ft_mflow_active_locked(octep, c->id[1]);
			if (c->hw_active)
				dev_info(&octep->pdev->dev,
					 "ft: conn %u firmware-active, host silence is offload not a black hole\n",
					 OCTEP_FT_CONN_BASE + slot);
		}
		/* Sticky: a one-tick continue let the next 1s scan release a live offload. */
		if (c->hw_active) {
			bool tcp = false;

			for (i = 0; i < OCTEP_FT_MAX && !tcp; i++)
				tcp = octep->ft_ent[i].used &&
				      octep->ft_ent[i].conn == (int)slot &&
				      octep->ft_ent[i].proto == IPPROTO_TCP;
			if (!tcp || !octep_ft_reply_frozen_locked(octep, c))
				continue;
			dev_info(&octep->pdev->dev,
				 "ft: conn %u reply microflow frozen for %us while firmware-active, releasing to the slow path\n",
				 OCTEP_FT_CONN_BASE + slot, READ_ONCE(octep_ft_reply_frozen_s));
			/* One NPU view of the conn and both microflows at the stall, before they are torn down. */
			octep_ft_debug_conn_locked(octep, slot);
			if (octep_dp_dbg & 4)
				octep_dp_dbg_rings(octep, "flow-release");
			goto release;
		}
		for (i = 0; i < OCTEP_FT_MAX && !seen; i++) {
			const struct octep_ft_ent *e = &octep->ft_ent[i];

			if (!e->used || e->conn != (int)slot || e->proto != IPPROTO_TCP)
				continue;
			for (k = 0; k < OCTEP_RX_FLOW_TRACK_MAX; k++) {
				const struct octep_rx_flow_track *t = &tracks[k];

				if (t->used && t->tuple_valid && t->family == 4 &&
				    t->protocol == e->proto &&
				    !memcmp(t->src_addr, &e->src, 4) &&
				    !memcmp(t->dst_addr, &e->dst, 4) &&
				    t->src_port == e->sport && t->dst_port == e->dport &&
				    time_after(t->last_seen, c->since + HZ)) {
					seen = true;
					break;
				}
			}
		}
		if (seen)
			continue;
release:
		for (i = 0; i < OCTEP_FT_MAX; i++) {
			struct octep_ft_ent *e = &octep->ft_ent[i];

			if (e->used && e->conn == (int)slot && e->proto == IPPROTO_TCP)
				e->blackhole = true;
		}
		if (!c->hw_active)
			dev_info(&octep->pdev->dev,
				 "ft: conn %u carried no host-visible frames for %us after offload, released and kept on the slow path\n",
				 OCTEP_FT_CONN_BASE + slot, OCTEP_FT_BLACKHOLE_JIFFIES / HZ);
		octep_ft_release_locked(octep, slot);
	}
}

/*
 * Fast guard for the stall seen on every offload: the NPU matches the orig microflow, then
 * stops matching the reply one and drops everything until its own lease reclaim (7-68 s dead).
 * The 1 s scan needs 6+ s to notice, so poll the reply timestamp of young TCP conns every
 * ft_guard_ms/2 and hand a frozen one back to the host path (the flow stays blackholed).
 */
static void octep_ft_guard_work(struct work_struct *work)
{
	struct octep *octep = container_of(to_delayed_work(work), struct octep,
					   ft_guard_work);
	unsigned int g = READ_ONCE(octep_ft_guard_ms), slot, i;
	bool any = false;

	if (!g)
		return;
	mutex_lock(&octep->lock);
	if (!octep->ft_stop && octep->rpc_ready && octep->rpc_allow_write) {
		for (slot = 0; slot < OCTEP_FT_CONNS; slot++) {
			struct octep_ft_conn *c = &octep->ft_conn[slot];
			bool tcp = false;
			u32 ts;

			if (!c->used || c->cutin_pending ||
			    time_after(jiffies, c->since + 10 * HZ))
				continue;
			for (i = 0; i < OCTEP_FT_MAX && !tcp; i++)
				tcp = octep->ft_ent[i].used &&
				      octep->ft_ent[i].conn == (int)slot &&
				      octep->ft_ent[i].proto == IPPROTO_TCP;
			if (!tcp)
				continue;
			any = true;
			if (!octep_ft_mflow_ts_locked(octep, c->id[1], &ts))
				continue;
			if (ts != c->reply_ts) {
				c->reply_ts = ts;
				c->reply_ts_moved = jiffies;
				continue;
			}
			if (time_before(jiffies, c->reply_ts_moved + msecs_to_jiffies(g)))
				continue;
			for (i = 0; i < OCTEP_FT_MAX; i++)
				if (octep->ft_ent[i].used && octep->ft_ent[i].conn == (int)slot &&
				    octep->ft_ent[i].proto == IPPROTO_TCP)
					octep->ft_ent[i].blackhole = true;
			dev_info(&octep->pdev->dev,
				 "ft: guard: conn %u reply microflow frozen %ums, back to the host path\n",
				 OCTEP_FT_CONN_BASE + slot, g);
			if (octep_ft_debug)
				octep_ft_dump_mflows_locked(octep, c, "at-release");
			octep_ft_release_locked(octep, slot);
		}
		if (any)
			schedule_delayed_work(&octep->ft_guard_work,
					      msecs_to_jiffies(max(g / 2, 10u)));
	}
	mutex_unlock(&octep->lock);
}

/* Debug: show which slots the NPU is tracking, to tell whether the reply direction is seen at all. */
static void octep_ft_dump_tracks(struct octep *octep,
				 const struct octep_rx_flow_track *tracks,
				 const struct octep_rx_flow_track *hot)
{
	unsigned int k;

	for (k = 0; k < OCTEP_RX_FLOW_TRACK_MAX; k++) {
		const struct octep_rx_flow_track *t = &tracks[k];

		if (!t->used)
			continue;
		dev_info_ratelimited(&octep->pdev->dev,
				     "ft: dbg track id %u%s tuple_valid %u fam %u proto %u %pI4:%u > %pI4:%u frames %llu age %ums\n",
				     t->id, t == hot ? " (hot)" : "", t->tuple_valid, t->family, t->protocol,
				     t->src_addr, t->src_port, t->dst_addr,
				     t->dst_port, t->frames,
				     jiffies_to_msecs(jiffies - t->last_seen));
	}
}

static void octep_ft_scan_locked(struct octep *octep, bool full)
{
	struct octep_rx_flow_track *tracks;
	unsigned long flags;
	unsigned int i, j, k, tries;
	u32 skip[8], last_state = 0;

	tracks = kmalloc_array(OCTEP_RX_FLOW_TRACK_MAX, sizeof(*tracks),
			       GFP_KERNEL);
	if (!tracks)
		return;
	spin_lock_irqsave(&octep->flow_stats_lock, flags);
	memcpy(tracks, octep->rx_flow_tracks,
	       OCTEP_RX_FLOW_TRACK_MAX * sizeof(*tracks));
	spin_unlock_irqrestore(&octep->flow_stats_lock, flags);

	if (full)
		octep_ft_check_blackhole_locked(octep, tracks);
	for (i = 0; i < OCTEP_FT_MAX; i++) {
		struct octep_ft_ent *e = &octep->ft_ent[i];
		const struct octep_rx_flow_track *hot = NULL, *partner = NULL;

		if (!e->used || e->conn >= 0 || e->blackhole ||
		    time_before(jiffies, e->retry_at) ||
		    (!e->trig && time_before(jiffies, e->born + msecs_to_jiffies(octep_ft_delay_ms))))
			continue;
		if (!octep_ft_offload_nat &&
		    (e->nsrc != e->src || e->ndst != e->dst ||
		     e->nsport != e->sport || e->ndport != e->dport))
			continue;
		for (k = 0; k < OCTEP_RX_FLOW_TRACK_MAX; k++) {
			const struct octep_rx_flow_track *t = &tracks[k];

			if (t->used && t->tuple_valid && t->family == 4 &&
			    t->protocol == e->proto && t->frames >= OCTEP_FT_MIN_FRAMES &&
			    !memcmp(t->src_addr, &e->src, 4) &&
			    !memcmp(t->dst_addr, &e->dst, 4) &&
			    t->src_port == e->sport && t->dst_port == e->dport &&
			    jiffies_to_msecs(jiffies - t->last_seen) <= OCTEP_FT_MAX_AGE_MS) {
				hot = t;
				break;
			}
		}
		if (!hot)
			continue;
		for (j = 0; j < OCTEP_FT_MAX; j++) {
			struct octep_ft_ent *o = &octep->ft_ent[j];

			if (o == e || !o->used || o->conn >= 0 || o->proto != e->proto ||
			    (!o->trig && time_before(jiffies, o->born + msecs_to_jiffies(octep_ft_delay_ms))) ||
			    e->src != o->ndst || e->dst != o->nsrc ||
			    e->sport != o->ndport || e->dport != o->nsport)
				continue;
			/* Prefer the reply direction's own live slot: the firmware only programs slots that carry traffic. */
			for (k = 0; k < OCTEP_RX_FLOW_TRACK_MAX; k++) {
				const struct octep_rx_flow_track *t = &tracks[k];

				if (t->used && t->tuple_valid && t->family == 4 &&
				    t->id != hot->id && t->id != e->bad_spare &&
				    t->protocol == o->proto &&
				    t->frames >= OCTEP_FT_MIN_FRAMES &&
				    !memcmp(t->src_addr, &o->src, 4) &&
				    !memcmp(t->dst_addr, &o->dst, 4) &&
				    t->src_port == o->sport && t->dst_port == o->dport &&
				    jiffies_to_msecs(jiffies - t->last_seen) <= OCTEP_FT_MAX_AGE_MS) {
					partner = t;
					break;
				}
			}
			if (partner) {
				if (OCTEP_FT_FEAT(octep_ft_pair_gate))
					dev_info_ratelimited(&octep->pdev->dev,
							     "ft: pair gate open, ids %u and %u\n",
							     hot->id, partner->id);
				octep->ft_pair_creates++;
				octep_ft_program_locked(octep, partner, hot, e, o);
				break;
			}
			if (OCTEP_FT_FEAT(octep_ft_pair_gate) || OCTEP_FT_FEAT(octep_ft_ct_trigger)) {
				octep->ft_pair_waits++;
				dev_info_ratelimited(&octep->pdev->dev,
						     "ft: pair gate waiting, hot id %u has no live partner for %pI4:%u > %pI4:%u\n",
						     hot->id, &o->src, o->sport, &o->dst, o->dport);
				break;
			}
			if (!octep_ft_allow_spare) {
				if (octep_ft_debug) {
					octep_ft_dump_tracks(octep, tracks, hot);
					dev_info_ratelimited(&octep->pdev->dev,
							     "ft: dbg no live reply track for hot id %u (%pI4:%u > %pI4:%u); staying on the slow path\n",
							     hot->id, &o->src, o->sport,
							     &o->dst, o->dport);
				}
				break;
			}
			/*
			 * No live reply slot. Borrow the quietest
			 * idle slot for the other one (offload-agent.py convention):
			 * not recently seen, not bound to a live connection, and not
			 * a spare this pair already failed with.
			 */
			for (tries = 0; tries < ARRAY_SIZE(skip); tries++) {
				const u8 *mf;

				partner = NULL;
				for (k = 0; k < OCTEP_RX_FLOW_TRACK_MAX; k++) {
					const struct octep_rx_flow_track *t = &tracks[k];
					unsigned int c, n;
					bool busy = false;

					if (!t->used || t == hot || t->id == hot->id ||
					    t->id == e->bad_spare || t->id == o->bad_spare ||
					    jiffies_to_msecs(jiffies - t->last_seen) <=
						OCTEP_FT_MAX_AGE_MS)
						continue;
					for (n = 0; n < tries; n++)
						if (skip[n] == t->id)
							busy = true;
					for (c = 0; c < OCTEP_FT_CONNS; c++)
						if (octep->ft_conn[c].used &&
						    (octep->ft_conn[c].id[0] == t->id ||
						     octep->ft_conn[c].id[1] == t->id))
							busy = true;
					if (busy)
						continue;
					if (!partner || t->frames < partner->frames ||
					    (t->frames == partner->frames &&
					     time_before(t->last_seen, partner->last_seen)))
						partner = t;
				}
				if (!partner)
					break;
				/* Idle slots read 0x18x (revision, no frames, no operation); only a slot without frames or an operation is safe to borrow. */
				if (!octep_rpc_mflow_read_locked(octep, partner->id, &mf)) {
					last_state = get_unaligned_le32(mf + 84);
					if (!(last_state >> 16))
						break;
				}
				skip[tries] = partner->id;
				partner = NULL;
			}
			if (!partner && octep_ft_debug)
				octep_ft_dump_tracks(octep, tracks, hot);
			if (!partner && octep_ft_debug)
				dev_info_ratelimited(&octep->pdev->dev,
						     "ft: dbg no free spare for hot id %u: %u idle tracks tried, last state 0x%08x\n",
						     hot->id, tries, last_state);
			if (partner)
				octep_ft_program_locked(octep, partner, hot, e, o);
			break;
		}
	}
	kfree(tracks);
}

/* NPU system counters logged with each npu-alloc line: wire-to-wire, firmware/L3 revision mismatches, conn reclaim and inactive-microflow punts. */
static const u8 octep_ft_alloc_cnt_idx[7] = { 0, 2, 42, 43, 52, 53, 59 };

/* NPU counter names (SFOS 22/23 order, matches our firmware) for the "moved" line; others print by id. */
static const struct { u8 id; const char *name; } octep_ft_cnt_names[] = {
	{ 0, "RX_WIRE" }, { 1, "TX_WIRE" }, { 2, "WIRE_TO_WIRE" }, { 3, "RX_KN" },
	{ 8, "TX_DROP" }, { 9, "TX_DROP_QUEUE_FULL" }, { 10, "TX_DROP_LEN_ERR" },
	{ 11, "TX_DROP_SHAPER_INV" }, { 21, "TX_DROP_POLL" }, { 22, "TX_DROP_ERR" },
	{ 24, "DROP_LIF_INDEX_INVALID" }, { 25, "DROP_LIF_LU_NULL" },
	{ 26, "DROP_LIF_INVALID" }, { 27, "DROP_LIF_ADMIN_DISABLED" },
	{ 28, "DROP_LIF_NOT_MY_MAC" }, { 29, "DROP_MTU_EXCEEDED" },
	{ 30, "DROP_TCP_SEQ_CHK_INVALID" }, { 31, "DROP_IPS_VERDICT" },
	{ 33, "DROP_MFLOW_ACTION" }, { 34, "DROP_MFLOW_UNSUPPORTED_ACTION" },
	{ 35, "DROP_FRAG_ERROR" }, { 36, "DROP_IG_ERR" },
	{ 40, "TO_KN_NON_ACCEL" }, { 42, "TO_KN_FW_REV_MISMATCH" },
	{ 43, "TO_KN_L3_FW_REV_MISMATCH" }, { 52, "TO_KN_CONN_RECLAIM_PENDING" },
	{ 53, "TO_KN_CONN_RECLAIMED" }, { 56, "TO_KN_TCP_SEQ_CHK_INVALID" },
	{ 57, "TO_KN_TCP_MAX_RETRANS" }, { 58, "TO_KN_TCP_FIN_SYN_RST" },
	{ 59, "TO_KN_MFLOW_NOT_ACTIVE" }, { 60, "TO_KN_EG_ERR" },
};

/* With dp_debug, one dmesg line listing every NPU counter that moved since the previous read. */
static void octep_ft_cnt_moved_report(struct octep *octep, const u8 *reply)
{
	char line[400];
	size_t n = 0;
	unsigned int i, k;

	for (i = 0; i < OCTEP_RPC_SYS_COUNTER_COUNT; i++) {
		u64 now = get_unaligned_le64(reply + i * sizeof(u64));
		u64 delta = now - octep->alloc_cnt_all[i];
		const char *name = NULL;

		octep->alloc_cnt_all[i] = now;
		if (!delta || delta == now)
			continue;
		for (k = 0; k < ARRAY_SIZE(octep_ft_cnt_names); k++)
			if (octep_ft_cnt_names[k].id == i)
				name = octep_ft_cnt_names[k].name;
		if (n < sizeof(line))
			n += scnprintf(line + n, sizeof(line) - n, " %s[%u]+%llu",
				       name ?: "ctr", i, (unsigned long long)delta);
	}
	if (n)
		dev_info(&octep->pdev->dev, "dp-debug: npu counters moved:%s\n", line);
}

/* One dmesg line per offloaded conn straight from the NPU (every 1s while young, then 5s): both microflows' hit timestamps and states, the pushed per-flow stats, and the NPU counter deltas that show where its frames go. */
static void octep_ft_alloc_report_locked(struct octep *octep)
{
	unsigned int slot, i;
	u64 cnt[7] = {}, d[7] = {};
	bool have_cnt = false, tried_cnt = false;

	for (slot = 0; slot < OCTEP_FT_CONNS; slot++) {
		struct octep_ft_conn *c = &octep->ft_conn[slot];
		u32 ts[2] = {}, st[2] = {};
		u8 raw[2][OCTEP_RPC_MFLOW_READ_REPLY_LEN] = {};
		int err[2];
		const u8 *mf;

		if (!c->used || time_before(jiffies, c->alloc_next))
			continue;
		c->alloc_next = jiffies + (jiffies_to_msecs(jiffies - c->since) < 10000 ? HZ : 5 * HZ);
		if (!tried_cnt) {
			u8 payload[OCTEP_RPC_TBL_REQ_LEN] = {};
			const u8 *reply;

			tried_cnt = true;
			put_unaligned_le16(OCTEP_RPC_SYS_COUNTER_COUNT, payload + 4);
			put_unaligned_le32(OCTEP_RPC_SYS_COUNTER_COUNT - 1, payload + 8);
			if (!octep_rpc_post_command_locked(octep,
							   OCTEP_RPC_CMD_LO_WORKER_SYS_CNT_READ,
							   payload, sizeof(payload)) &&
			    octep->rpc_last_len == OCTEP_RPC_SYS_COUNTER_COUNT * sizeof(u64)) {
				reply = (u8 *)octep->rpc_cmd.vaddr + OCTEP_RPC_BUF_DESC_SIZE;
				if (octep_dp_debug)
					octep_ft_cnt_moved_report(octep, reply);
				for (i = 0; i < ARRAY_SIZE(cnt); i++) {
					cnt[i] = get_unaligned_le64(reply + octep_ft_alloc_cnt_idx[i] * sizeof(u64));
					d[i] = cnt[i] - octep->alloc_cnt[i];
					octep->alloc_cnt[i] = cnt[i];
				}
				have_cnt = true;
			}
		}
		for (i = 0; i < 2; i++) {
			err[i] = octep_rpc_mflow_read_locked(octep, c->id[i], &mf);
			if (!err[i]) {
				ts[i] = get_unaligned_le32(mf + 72);
				st[i] = get_unaligned_le32(mf + 84);
				memcpy(raw[i], mf, sizeof(raw[i]));
			}
		}
		/* Raw slot bytes for the first 6s, to diff the orig and reply microflows. */
		if (jiffies_to_msecs(jiffies - c->since) < 6000)
			for (i = 0; i < 2; i++)
				if (!err[i])
					dev_info(&octep->pdev->dev,
						 "npu-dump: conn %u age %ums %s id %u: %*phN %*phN\n",
						 OCTEP_FT_CONN_BASE + slot,
						 jiffies_to_msecs(jiffies - c->since),
						 i ? "reply" : "orig", c->id[i],
						 58, raw[i], 58, raw[i] + 58);
		dev_info(&octep->pdev->dev,
			 "npu-alloc: conn %u age %ums orig id %u ts %u (+%u) state 0x%08x (%d) reply id %u ts %u (+%u) state 0x%08x (%d) conn_stats msgs=%llu entries=%llu\n",
			 OCTEP_FT_CONN_BASE + slot,
			 jiffies_to_msecs(jiffies - c->since),
			 c->id[0], ts[0], ts[0] - c->alloc_ts[0], st[0], err[0],
			 c->id[1], ts[1], ts[1] - c->alloc_ts[1], st[1], err[1],
			 (unsigned long long)READ_ONCE(octep->cmsg_conn_stats_messages),
			 (unsigned long long)READ_ONCE(octep->cmsg_conn_stats_entries));
		if (have_cnt)
			dev_info(&octep->pdev->dev,
				 "npu-alloc: conn %u npu counters since last report: RX_WIRE +%llu WIRE_TO_WIRE +%llu FW_REV_MISMATCH +%llu L3_FW_REV_MISMATCH +%llu CONN_RECLAIM_PENDING +%llu CONN_RECLAIMED +%llu MFLOW_NOT_ACTIVE +%llu (totals RX_WIRE=%llu WIRE_TO_WIRE=%llu)\n",
				 OCTEP_FT_CONN_BASE + slot,
				 d[0], d[1], d[2], d[3], d[4], d[5], d[6], cnt[0], cnt[1]);
		c->alloc_ts[0] = ts[0];
		c->alloc_ts[1] = ts[1];
	}
}

struct octep_ft_trig {
	bool used;
	bool queued;
	bool gaveup;
	struct octep *octep;
	u8 proto;
	__be32 src, dst;
	u16 sport, dport;
	unsigned long born;
	struct octep_ft_ent ent[2];
};

static struct octep_ft_trig octep_ft_trigs[OCTEP_FT_TRIG_MAX];
static DEFINE_SPINLOCK(octep_ft_trig_lock);
static DEFINE_MUTEX(octep_ft_hook_lock);
static bool octep_ft_hook_registered;
static bool octep_ft_hook_ready;

static struct nf_conn *octep_ft_ct_find(u8 proto, __be32 src, u16 sport,
					__be32 dst, u16 dport)
{
	struct nf_conntrack_tuple t = {};
	struct nf_conntrack_tuple_hash *h;

	t.src.l3num = AF_INET;
	t.src.u3.ip = src;
	t.src.u.all = htons(sport);
	t.dst.u3.ip = dst;
	t.dst.u.all = htons(dport);
	t.dst.protonum = proto;
	t.dst.dir = IP_CT_DIR_ORIGINAL;
	h = nf_conntrack_find_get(&init_net, &nf_ct_zone_dflt, &t);
	if (!h) {
		t.dst.dir = IP_CT_DIR_REPLY;
		h = nf_conntrack_find_get(&init_net, &nf_ct_zone_dflt, &t);
	}
	return h ? nf_ct_tuplehash_to_ctrack(h) : NULL;
}

static unsigned int octep_ft_ct_hook(void *priv, struct sk_buff *skb,
				     const struct nf_hook_state *state)
{
	struct octep_ft_ent ent[2] = {};
	struct octep_netdev_priv *ipriv, *opriv;
	const struct nf_conntrack_tuple *o, *r;
	struct octep_ft_trig *t = NULL;
	enum ip_conntrack_info ctinfo;
	struct net_device *in = state->in, *out = state->out, *bridge;
	struct neighbour *n;
	bool bridged;
	struct octep *octep;
	struct nf_conn *ct;
	unsigned int i;
	u8 proto;

	if (!OCTEP_FT_FEAT(octep_ft_ct_trigger) || !octep_flow_offload || !in || !out ||
	    in->netdev_ops != &octep_dp_netdev_ops ||
	    out->netdev_ops != &octep_dp_netdev_ops)
		return NF_ACCEPT;
	ct = nf_ct_get(skb, &ctinfo);
	if (!ct || CTINFO2DIR(ctinfo) != IP_CT_DIR_ORIGINAL || !nf_ct_is_confirmed(ct) ||
	    test_bit(IPS_OFFLOAD_BIT, &ct->status))
		return NF_ACCEPT;
	o = &ct->tuplehash[IP_CT_DIR_ORIGINAL].tuple;
	r = &ct->tuplehash[IP_CT_DIR_REPLY].tuple;
	proto = o->dst.protonum;
	if (proto == IPPROTO_TCP) {
		if (READ_ONCE(ct->proto.tcp.state) != TCP_CONNTRACK_ESTABLISHED)
			return NF_ACCEPT;
	} else if (proto == IPPROTO_UDP) {
		if (!test_bit(IPS_SEEN_REPLY_BIT, &ct->status))
			return NF_ACCEPT;
	} else {
		return NF_ACCEPT;
	}
	if (!octep_ft_offload_nat &&
	    (o->src.u3.ip != r->dst.u3.ip || o->dst.u3.ip != r->src.u3.ip ||
	     o->src.u.all != r->dst.u.all || o->dst.u.all != r->src.u.all))
		return NF_ACCEPT;
	ipriv = netdev_priv(in);
	opriv = netdev_priv(out);
	octep = opriv->octep;
	if (ipriv->octep != octep || READ_ONCE(octep->ft_stop) || !skb_dst(skb) ||
	    !skb_mac_header_was_set(skb))
		return NF_ACCEPT;
	n = dst_neigh_lookup_skb(skb_dst(skb), skb);
	if (!n)
		return NF_ACCEPT;
	if (!(READ_ONCE(n->nud_state) & NUD_VALID)) {
		neigh_release(n);
		return NF_ACCEPT;
	}
	neigh_ha_snapshot(ent[0].dmac, n, out);
	neigh_release(n);
	memcpy(ent[0].smac, out->dev_addr, ETH_ALEN);
	memcpy(ent[1].dmac, eth_hdr(skb)->h_source, ETH_ALEN);
	memcpy(ent[1].smac, in->dev_addr, ETH_ALEN);

	rcu_read_lock();
	bridge = netdev_master_upper_dev_get_rcu(in);
	bridged = bridge && bridge == netdev_master_upper_dev_get_rcu(out);
	rcu_read_unlock();

	ent[0].src = o->src.u3.ip;
	ent[0].dst = o->dst.u3.ip;
	ent[0].sport = ntohs(o->src.u.all);
	ent[0].dport = ntohs(o->dst.u.all);
	ent[0].nsrc = r->dst.u3.ip;
	ent[0].ndst = r->src.u3.ip;
	ent[0].nsport = ntohs(r->dst.u.all);
	ent[0].ndport = ntohs(r->src.u.all);
	ent[0].iface = opriv->port->iface;
	ent[0].tag = opriv->port->tag;
	ent[1].src = r->src.u3.ip;
	ent[1].dst = r->dst.u3.ip;
	ent[1].sport = ntohs(r->src.u.all);
	ent[1].dport = ntohs(r->dst.u.all);
	ent[1].nsrc = o->dst.u3.ip;
	ent[1].ndst = o->src.u3.ip;
	ent[1].nsport = ntohs(o->dst.u.all);
	ent[1].ndport = ntohs(o->src.u.all);
	ent[1].iface = ipriv->port->iface;
	ent[1].tag = ipriv->port->tag;
	for (i = 0; i < 2; i++) {
		ent[i].used = true;
		ent[i].conn = -1;
		ent[i].proto = proto;
		ent[i].trig = true;
		ent[i].bridged = bridged;
	}

	spin_lock(&octep_ft_trig_lock);
	for (i = 0; i < OCTEP_FT_TRIG_MAX; i++) {
		struct octep_ft_trig *c = &octep_ft_trigs[i];

		if (c->used && c->octep == octep && c->proto == proto &&
		    c->src == ent[0].src && c->dst == ent[0].dst &&
		    c->sport == ent[0].sport && c->dport == ent[0].dport) {
			spin_unlock(&octep_ft_trig_lock);
			return NF_ACCEPT;
		}
		if (!c->used && !t)
			t = c;
	}
	if (!t) {
		octep->ft_ct_dropped++;
		spin_unlock(&octep_ft_trig_lock);
		return NF_ACCEPT;
	}
	memset(t, 0, sizeof(*t));
	t->used = true;
	t->queued = true;
	t->octep = octep;
	t->proto = proto;
	t->src = ent[0].src;
	t->dst = ent[0].dst;
	t->sport = ent[0].sport;
	t->dport = ent[0].dport;
	t->born = jiffies;
	for (i = 0; i < 2; i++) {
		t->ent[i] = ent[i];
		t->ent[i].cookie = (unsigned long)t + i;
		t->ent[i].born = jiffies;
	}
	octep->ft_ct_queued++;
	spin_unlock(&octep_ft_trig_lock);
	mod_delayed_work(system_wq, &octep->ft_work, 0);
	return NF_ACCEPT;
}

static const struct nf_hook_ops octep_ft_ct_ops = {
	.hook = octep_ft_ct_hook,
	.pf = NFPROTO_IPV4,
	.hooknum = NF_INET_FORWARD,
	.priority = NF_IP_PRI_LAST,
};

static void octep_ft_trig_update(void)
{
	unsigned int i;
	bool want;

	mutex_lock(&octep_ft_hook_lock);
	want = octep_ft_hook_ready &&
	       (READ_ONCE(octep_ft_parity) || READ_ONCE(octep_ft_ct_trigger));
	if (want && !octep_ft_hook_registered) {
		if (nf_register_net_hook(&init_net, &octep_ft_ct_ops))
			pr_warn("octep: ft: conntrack hook registration failed\n");
		else
			octep_ft_hook_registered = true;
	} else if (!want && octep_ft_hook_registered) {
		nf_unregister_net_hook(&init_net, &octep_ft_ct_ops);
		octep_ft_hook_registered = false;
		synchronize_net();
		spin_lock_bh(&octep_ft_trig_lock);
		for (i = 0; i < OCTEP_FT_TRIG_MAX; i++)
			if (octep_ft_trigs[i].queued)
				memset(&octep_ft_trigs[i], 0, sizeof(octep_ft_trigs[i]));
		spin_unlock_bh(&octep_ft_trig_lock);
	}
	mutex_unlock(&octep_ft_hook_lock);
}

static int octep_ft_trig_param_set(const char *val, const struct kernel_param *kp)
{
	int err = param_set_bool(val, kp);

	if (!err)
		octep_ft_trig_update();
	return err;
}

static void octep_ft_trig_set_ready(bool ready)
{
	mutex_lock(&octep_ft_hook_lock);
	octep_ft_hook_ready = ready;
	mutex_unlock(&octep_ft_hook_lock);
	octep_ft_trig_update();
}

/* Drop every trigger of a device that is going away; the hook is already unregistered. */
static void octep_ft_trig_forget(struct octep *octep)
{
	unsigned int i;

	spin_lock_bh(&octep_ft_trig_lock);
	for (i = 0; i < OCTEP_FT_TRIG_MAX; i++)
		if (octep_ft_trigs[i].octep == octep)
			memset(&octep_ft_trigs[i], 0, sizeof(octep_ft_trigs[i]));
	spin_unlock_bh(&octep_ft_trig_lock);
}

/* Move queued conntrack triggers into free ft_ent slots; called with octep->lock held. */
static void octep_ft_trig_drain_locked(struct octep *octep)
{
	unsigned int i, k, free;

	spin_lock_bh(&octep_ft_trig_lock);
	for (i = 0; i < OCTEP_FT_TRIG_MAX; i++) {
		struct octep_ft_trig *t = &octep_ft_trigs[i];

		if (!t->used || !t->queued || t->octep != octep)
			continue;
		for (k = 0, free = 0; k < OCTEP_FT_MAX; k++)
			free += !octep->ft_ent[k].used;
		if (free < 2)
			break;
		for (k = 0, free = 0; k < OCTEP_FT_MAX && free < 2; k++) {
			if (octep->ft_ent[k].used)
				continue;
			octep->ft_ent[k] = t->ent[free++];
			octep->ft_ent[k].born = jiffies;
		}
		t->queued = false;
		t->born = jiffies;
	}
	spin_unlock_bh(&octep_ft_trig_lock);
}

static void octep_ft_trig_retire_locked(struct octep *octep, struct octep_ft_trig *t,
					bool forget)
{
	unsigned int i;

	for (i = 0; i < OCTEP_FT_MAX; i++) {
		struct octep_ft_ent *e = &octep->ft_ent[i];

		if (!e->used || (e->cookie != (unsigned long)t &&
				 e->cookie != (unsigned long)t + 1))
			continue;
		if (e->conn >= 0)
			octep_ft_release_locked(octep, e->conn);
		memset(e, 0, sizeof(*e));
	}
	spin_lock_bh(&octep_ft_trig_lock);
	if (forget)
		memset(t, 0, sizeof(*t));
	else
		t->gaveup = true;
	spin_unlock_bh(&octep_ft_trig_lock);
	octep->ft_ct_released++;
}

/* Once a second: retire triggers whose conntrack is gone or closing, or that never got created. */
static void octep_ft_trig_poll_locked(struct octep *octep)
{
	unsigned int i;

	for (i = 0; i < OCTEP_FT_TRIG_MAX; i++) {
		struct octep_ft_trig *t = &octep_ft_trigs[i];
		struct nf_conn *ct;
		bool created = false, closing = false;
		unsigned int k;

		if (!t->used || t->queued || t->octep != octep)
			continue;
		ct = octep_ft_ct_find(t->proto, t->src, t->sport, t->dst, t->dport);
		if (!ct) {
			octep_ft_trig_retire_locked(octep, t, true);
			continue;
		}
		if (t->proto == IPPROTO_TCP) {
			u8 s = READ_ONCE(ct->proto.tcp.state);

			closing = s >= TCP_CONNTRACK_FIN_WAIT && s <= TCP_CONNTRACK_CLOSE;
		}
		nf_ct_put(ct);
		if (t->gaveup)
			continue;
		for (k = 0; k < OCTEP_FT_MAX; k++)
			created |= octep->ft_ent[k].used && octep->ft_ent[k].conn >= 0 &&
				   (octep->ft_ent[k].cookie == (unsigned long)t ||
				    octep->ft_ent[k].cookie == (unsigned long)t + 1);
		if (closing || (!created && time_after(jiffies, t->born + 10 * HZ)))
			octep_ft_trig_retire_locked(octep, t, false);
	}
}

static bool octep_ft_trig_any(struct octep *octep)
{
	bool any = false;
	unsigned int i;

	spin_lock_bh(&octep_ft_trig_lock);
	for (i = 0; i < OCTEP_FT_TRIG_MAX; i++)
		any |= octep_ft_trigs[i].used && octep_ft_trigs[i].octep == octep;
	spin_unlock_bh(&octep_ft_trig_lock);
	return any;
}

/* Keep conntrack from expiring flows whose NPU counters still advance. */
static void octep_ft_ct_refresh_locked(struct octep *octep)
{
	unsigned int secs = READ_ONCE(octep_ft_ct_refresh);
	unsigned int slot, i;

	if (!secs && READ_ONCE(octep_ft_parity))
		secs = 120;
	if (!secs)
		return;
	for (slot = 0; slot < OCTEP_FT_CONNS; slot++) {
		struct octep_ft_conn *c = &octep->ft_conn[slot];
		const struct octep_ft_ent *e = NULL;
		struct nf_conn *ct;
		unsigned long flags;
		u64 pkts = 0;

		if (!c->used)
			continue;
		spin_lock_irqsave(&octep->flow_stats_lock, flags);
		for (i = 0; i < ARRAY_SIZE(octep->flow_stats); i++)
			if (octep->flow_stats[i].used &&
			    octep->flow_stats[i].index == OCTEP_FT_CONN_BASE + slot)
				pkts = octep->flow_stats[i].packets[0] +
				       octep->flow_stats[i].packets[1];
		spin_unlock_irqrestore(&octep->flow_stats_lock, flags);
		if (pkts == c->pkts_seen)
			continue;
		c->pkts_seen = pkts;
		for (i = 0; i < OCTEP_FT_MAX; i++)
			if (octep->ft_ent[i].used && octep->ft_ent[i].conn == (int)slot) {
				e = &octep->ft_ent[i];
				break;
			}
		if (!e)
			continue;
		ct = octep_ft_ct_find(e->proto, e->src, e->sport, e->dst, e->dport);
		if (!ct)
			continue;
		if (nf_ct_expires(ct) < (long)secs * HZ) {
			nf_ct_refresh(ct, (unsigned long)secs * HZ);
			octep->ft_ct_refreshed++;
		}
		nf_ct_put(ct);
	}
}

static void octep_ft_work(struct work_struct *work)
{
	struct octep *octep = container_of(to_delayed_work(work), struct octep,
					   ft_work);
	unsigned int i;
	bool any = false, fast = false;

	mutex_lock(&octep->lock);
	if (!octep->ft_stop) {
		if (octep->rpc_allow_write) {
			bool full = time_after_eq(jiffies, octep->ft_full_at);

			octep_ft_trig_drain_locked(octep);
			octep_ft_scan_locked(octep, full);
			if (full) {
				octep->ft_full_at = jiffies + HZ;
				octep_ft_trig_poll_locked(octep);
				octep_ft_ct_refresh_locked(octep);
				octep_ft_cutin_locked(octep);
				octep_ft_rearm_locked(octep);
				octep_ft_alloc_report_locked(octep);
			}
		}
		any = octep_ft_trig_any(octep);
		for (i = 0; i < OCTEP_FT_MAX; i++) {
			struct octep_ft_ent *e = &octep->ft_ent[i];

			any |= e->used;
			fast |= e->used && e->conn < 0 && !e->blackhole &&
				time_before(jiffies, e->born + OCTEP_FT_FAST_WINDOW);
		}
		if (fast)
			schedule_delayed_work(&octep->ft_work,
					      msecs_to_jiffies(OCTEP_FT_FAST_POLL_MS));
		else if (any)
			schedule_delayed_work(&octep->ft_work, HZ);
	}
	mutex_unlock(&octep->lock);
}

static void octep_ft_release_all(struct octep *octep)
{
	unsigned int i;

	mutex_lock(&octep->lock);
	octep->ft_stop = true;
	for (i = 0; i < OCTEP_FT_CONNS; i++)
		octep_ft_release_locked(octep, i);
	memset(octep->ft_ent, 0, sizeof(octep->ft_ent));
	mutex_unlock(&octep->lock);
	cancel_delayed_work_sync(&octep->ft_work);
	cancel_delayed_work_sync(&octep->ft_guard_work);
}

/* Copy the bytes a mangle changes (mask byte 0) into buf at its offset from base. */
static void octep_ft_mangle_bytes(u8 *buf, size_t len, u32 base,
				  const struct flow_action_entry *act, u32 *seen)
{
	u8 v[4], m[4];
	unsigned int i;

	memcpy(v, &act->mangle.val, 4);
	memcpy(m, &act->mangle.mask, 4);
	for (i = 0; i < 4; i++) {
		u32 pos = act->mangle.offset - base + i;

		if (!m[i] && pos < len) {
			buf[pos] = v[i];
			if (seen)
				*seen |= BIT(pos);
		}
	}
}

static int octep_ft_add(struct net_device *netdev, struct flow_cls_offload *f)
{
	struct flow_rule *rule = flow_cls_offload_flow_rule(f);
	struct octep_netdev_priv *priv = netdev_priv(netdev);
	struct octep *octep = priv->octep;
	struct octep_netdev_priv *opriv;
	struct flow_action_entry *act;
	struct net_device *out = NULL;
	struct flow_match_ipv4_addrs ip = {};
	struct flow_match_ports ports = {};
	struct flow_match_basic basic = {};
	struct octep_ft_ent e = { .conn = -1, .cookie = f->cookie };
	u8 mac[2 * ETH_ALEN] = {}, ipb[8];
	u8 portb[4];
	u32 mac_seen = 0;
	int i, err = -EOPNOTSUPP;

	if (!octep_flow_offload ||
	    !flow_rule_match_key(rule, FLOW_DISSECTOR_KEY_BASIC) ||
	    !flow_rule_match_key(rule, FLOW_DISSECTOR_KEY_IPV4_ADDRS) ||
	    !flow_rule_match_key(rule, FLOW_DISSECTOR_KEY_PORTS))
		return -EOPNOTSUPP;
	flow_rule_match_basic(rule, &basic);
	flow_rule_match_ipv4_addrs(rule, &ip);
	flow_rule_match_ports(rule, &ports);
	if (basic.key->ip_proto != IPPROTO_TCP && basic.key->ip_proto != IPPROTO_UDP)
		return -EOPNOTSUPP;
	e.proto = basic.key->ip_proto;
	e.src = ip.key->src;
	e.dst = ip.key->dst;
	e.sport = ntohs(ports.key->src);
	e.dport = ntohs(ports.key->dst);
	memcpy(ipb, &e.src, 4);
	memcpy(ipb + 4, &e.dst, 4);
	put_unaligned_be16(e.sport, portb);
	put_unaligned_be16(e.dport, portb + 2);

	flow_action_for_each(i, act, &rule->action) {
		if (act->id == FLOW_ACTION_REDIRECT) {
			out = act->dev;
		} else if (act->id == FLOW_ACTION_MANGLE) {
			switch (act->mangle.htype) {
			case FLOW_ACT_MANGLE_HDR_TYPE_ETH:
				octep_ft_mangle_bytes(mac, sizeof(mac), 0, act, &mac_seen);
				break;
			case FLOW_ACT_MANGLE_HDR_TYPE_IP4:
				octep_ft_mangle_bytes(ipb, 8, 12, act, NULL);
				break;
			case FLOW_ACT_MANGLE_HDR_TYPE_TCP:
			case FLOW_ACT_MANGLE_HDR_TYPE_UDP:
				octep_ft_mangle_bytes(portb, 4, 0, act, NULL);
				break;
			default:
				return -EOPNOTSUPP;
			}
		} else if (act->id != FLOW_ACTION_CSUM) {
			return -EOPNOTSUPP;
		}
	}
	if (!out || out->netdev_ops != &octep_dp_netdev_ops || mac_seen != 0xfff)
		return -EOPNOTSUPP;
	opriv = netdev_priv(out);
	if (opriv->octep != octep)
		return -EOPNOTSUPP;
	memcpy(&e.nsrc, ipb, 4);
	memcpy(&e.ndst, ipb + 4, 4);
	e.nsport = get_unaligned_be16(portb);
	e.ndport = get_unaligned_be16(portb + 2);
	memcpy(e.dmac, mac, ETH_ALEN);
	memcpy(e.smac, mac + ETH_ALEN, ETH_ALEN);
	e.iface = opriv->port->iface;
	e.tag = opriv->port->tag;
	e.used = true;
	e.born = jiffies;

	mutex_lock(&octep->lock);
	if (!octep->ft_stop) {
		for (i = 0; i < OCTEP_FT_MAX; i++)
			if (octep->ft_ent[i].used && octep->ft_ent[i].cookie == e.cookie) {
				err = 0;
				goto out;
			}
		for (i = 0; i < OCTEP_FT_MAX; i++) {
			if (octep->ft_ent[i].used)
				continue;
			octep->ft_ent[i] = e;
			err = 0;
			mod_delayed_work(system_wq, &octep->ft_work,
					 msecs_to_jiffies(OCTEP_FT_FAST_POLL_MS));
			netdev_info(netdev, "ft: accept %pI4:%u -> %pI4:%u nat %pI4:%u -> %pI4:%u out %s\n",
				    &e.src, e.sport, &e.dst, e.dport, &e.nsrc,
				    e.nsport, &e.ndst, e.ndport, out->name);
			break;
		}
		/* Latch as soon as both directions are accepted instead of waiting for the next poll. */
		if (!err && octep->rpc_allow_write)
			octep_ft_scan_locked(octep, false);
	}
out:
	mutex_unlock(&octep->lock);
	return err;
}

static int octep_ft_del(struct net_device *netdev, struct flow_cls_offload *f)
{
	struct octep_netdev_priv *priv = netdev_priv(netdev);
	struct octep *octep = priv->octep;
	unsigned int i;

	mutex_lock(&octep->lock);
	for (i = 0; i < OCTEP_FT_MAX; i++) {
		struct octep_ft_ent *e = &octep->ft_ent[i];

		if (!e->used || e->cookie != f->cookie)
			continue;
		if (e->conn >= 0)
			octep_ft_release_locked(octep, e->conn);
		memset(e, 0, sizeof(*e));
		break;
	}
	mutex_unlock(&octep->lock);
	return 0;
}

/*
 * Send one of the three flow-programming requests using its fixed wire length.
 * The payload is supplied as hex so this interface cannot issue arbitrary RPC
 * command IDs or overrun the command buffer.
 */
static ssize_t rpc_flow_write_store(struct device *dev,
				    struct device_attribute *attr,
				    const char *buf, size_t count)
{
	struct octep *octep = dev_get_drvdata(dev);
	char *copy, *cursor, *command_text, *hex;
	u8 payload[OCTEP_RPC_FLOW_REQ_LEN];
	u32 command;
	size_t payload_len;
	int err;

	copy = kstrndup(buf, count, GFP_KERNEL);
	if (!copy)
		return -ENOMEM;

	cursor = strim(copy);
	command_text = strsep(&cursor, " \t");
	if (!command_text || !cursor) {
		err = -EINVAL;
		goto out_free;
	}
	while (*cursor == ' ' || *cursor == '\t')
		cursor++;
	hex = strim(cursor);

	err = kstrtou32(command_text, 0, &command);
	if (err)
		goto out_free;
	switch (command) {
	case OCTEP_RPC_CMD_NHOP_PROGRAM:
		payload_len = OCTEP_RPC_NHOP_REQ_LEN;
		break;
	case OCTEP_RPC_CMD_MFLOW_PROGRAM:
		payload_len = OCTEP_RPC_MFLOW_REQ_LEN;
		break;
	case OCTEP_RPC_CMD_FLOW_CREATE_FP:
		payload_len = OCTEP_RPC_FLOW_REQ_LEN;
		break;
	default:
		err = -EINVAL;
		goto out_free;
	}
	if (strlen(hex) != payload_len * 2) {
		err = -EINVAL;
		goto out_free;
	}
	err = hex2bin(payload, hex, payload_len);
	if (err)
		goto out_free;

	mutex_lock(&octep->lock);
	err = octep_rpc_flow_write_locked(octep, command, payload, payload_len);
	mutex_unlock(&octep->lock);

out_free:
	kfree(copy);
	return err ? err : (ssize_t)count;
}
static DEVICE_ATTR_WO(rpc_flow_write);

/* Probe: "<opcode> <hex payload>"; only the opcode set in rpc_raw_cmd, and only with rpc_allow_write. */
static ssize_t rpc_raw_write_store(struct device *dev,
				   struct device_attribute *attr,
				   const char *buf, size_t count)
{
	struct octep *octep = dev_get_drvdata(dev);
	char *copy, *cursor, *command_text, *hex;
	u8 payload[OCTEP_RPC_FLOW_REQ_LEN];
	size_t payload_len;
	u32 command;
	int err;

	copy = kstrndup(buf, count, GFP_KERNEL);
	if (!copy)
		return -ENOMEM;
	cursor = strim(copy);
	command_text = strsep(&cursor, " \t");
	hex = cursor ? strim(cursor) : NULL;
	err = command_text ? kstrtou32(command_text, 0, &command) : -EINVAL;
	if (err || !hex || strlen(hex) % 2 ||
	    strlen(hex) / 2 > sizeof(payload)) {
		err = err ? err : -EINVAL;
		goto out_free;
	}
	payload_len = strlen(hex) / 2;
	err = hex2bin(payload, hex, payload_len);
	if (err)
		goto out_free;
	if (octep_rpc_raw_cmd < 0 || command != (u32)octep_rpc_raw_cmd ||
	    command >= OCTEP_RPC_CMD_PLATFORM_READ) {
		err = -EPERM;
		goto out_free;
	}

	mutex_lock(&octep->lock);
	if (!octep->rpc_allow_write)
		err = -EPERM;
	else
		err = octep_rpc_post_command_locked(octep, command, payload,
						    payload_len);
	dev_info(&octep->pdev->dev, "rpc: raw cmd %u len %zu -> %d\n",
		 command, payload_len, err);
	mutex_unlock(&octep->lock);

out_free:
	kfree(copy);
	return err ? err : (ssize_t)count;
}
static DEVICE_ATTR_WO(rpc_raw_write);

static ssize_t rpc_conn_reclaim_show(struct device *dev,
				     struct device_attribute *attr, char *buf)
{
	struct octep *octep = dev_get_drvdata(dev);
	ssize_t len;
	unsigned int i;

	mutex_lock(&octep->lock);
	if (!octep->rpc_conn_reclaim_valid) {
		len = sysfs_emit(buf, "no connection reclaim reply is available\n");
		goto out;
	}
	len = sysfs_emit(buf, "index=%u revision=%u verified=%u raw=",
			 octep->rpc_conn_reclaim_index,
			 octep->rpc_conn_reclaim_revision,
			 octep->rpc_conn_reclaim_verified);
	for (i = 0; i < sizeof(octep->rpc_conn_reclaim_reply); i++)
		len += sysfs_emit_at(buf, len, "%s%02x", i ? " " : "",
				     octep->rpc_conn_reclaim_reply[i]);
	len += sysfs_emit_at(buf, len, "\n");
out:
	mutex_unlock(&octep->lock);
	return len;
}

static ssize_t rpc_conn_reclaim_store(struct device *dev,
				      struct device_attribute *attr,
				      const char *buf, size_t count)
{
	struct octep *octep = dev_get_drvdata(dev);
	u8 request[OCTEP_RPC_CONN_RECLAIM_REQ_LEN] = {};
	const u8 *entry;
	u32 index, revision, flags, state;
	char extra;
	bool submitted = false;
	int err;

	mutex_lock(&octep->lock);
	octep->rpc_conn_reclaim_valid = false;
	octep->rpc_conn_reclaim_verified = false;
	if (sscanf(buf, "%u %u %c", &index, &revision, &extra) != 2) {
		err = -EINVAL;
		goto out;
	}
	if (revision > U16_MAX) {
		err = -ERANGE;
		goto out;
	}
	if (!octep->rpc_allow_write) {
		err = -EPERM;
		goto out;
	}
	if (!octep->rpc_platform_known) {
		err = -EOPNOTSUPP;
		goto out;
	}
	if (index < 2 || index >= octep->rpc_platform_conn) {
		err = -ERANGE;
		goto out;
	}
	err = octep_rpc_read_connection_locked(octep, index, &entry);
	if (err)
		goto out;
	flags = get_unaligned_le32(entry);
	state = flags >> 30;
	if ((flags & 0xffff) != revision) {
		err = -ESTALE;
		goto out;
	}
	if (state != OCTEP_RPC_CONN_STATE_VALID &&
	    state != OCTEP_RPC_CONN_STATE_RECLAIM_PENDING) {
		err = -EALREADY;
		goto out;
	}
	put_unaligned_le32(index, request);
	put_unaligned_le16(revision, request + 4);
	submitted = true;
	err = octep_rpc_post_command_locked(octep, OCTEP_RPC_CMD_CONN_RECLAIM_FP,
					    request, sizeof(request));
	if (err)
		goto out;
	if (octep->rpc_last_len != OCTEP_RPC_CONN_RECLAIM_REPLY_LEN) {
		err = -EPROTO;
		octep->rpc_last_error = err;
		goto out;
	}
	octep->rpc_conn_reclaim_index = index;
	octep->rpc_conn_reclaim_revision = revision;
	memcpy(octep->rpc_conn_reclaim_reply,
	       (u8 *)octep->rpc_cmd.vaddr + OCTEP_RPC_BUF_DESC_SIZE,
	       sizeof(octep->rpc_conn_reclaim_reply));
	octep->rpc_conn_reclaim_valid = true;
	err = octep_rpc_read_connection_locked(octep, index, &entry);
	if (err)
		goto out;
	flags = get_unaligned_le32(entry);
	if ((flags & 0xffff) != revision ||
	    (flags >> 30) != OCTEP_RPC_CONN_STATE_RECLAIMED)
		err = -EIO;
	else
		octep->rpc_conn_reclaim_verified = true;
out:
	if (err && submitted)
		dev_warn(&octep->pdev->dev,
			 "rpc: connection reclaim or verification failed (%d); flow state is uncertain\n",
			 err);
	mutex_unlock(&octep->lock);
	return err ? err : (ssize_t)count;
}
static DEVICE_ATTR(rpc_conn_reclaim, 0600, rpc_conn_reclaim_show,
		   rpc_conn_reclaim_store);

static ssize_t rpc_state_show(struct device *dev,
			      struct device_attribute *attr, char *buf)
{
	struct octep *octep = dev_get_drvdata(dev);
	struct octep_facility *facility = &octep->facility[OCTEP_FCLT_RPC];
	u64 cfg = 0, posted = 0, done = 0;
	ssize_t len;

	mutex_lock(&octep->lock);
	if (facility->size >= OCTEP_RPC_STATE_SIZE) {
		cfg = octep_rpc_readq(octep, OCTEP_RPC_STATE_CFG);
		posted = octep_rpc_readq(octep, OCTEP_RPC_STATE_RING_LO +
					 OCTEP_RPC_RING_POSTED);
		done = octep_rpc_readq(octep, OCTEP_RPC_STATE_RING_LO +
				       OCTEP_RPC_RING_DONE);
	}
	len = sysfs_emit(buf,
			 "ready=%u configured=%u cfg=%#018llx reconfig_done=%u "
			 "posted=%llu done=%llu desc_offset=%u desc_count=%u "
			 "write_gate=%u fw_rev=%u fw_rev_bumps=%llu "
			 "platform_known=%u command_shift=%u platform_len=%u "
			 "platform_conn=%u platform_nhop=%u\n",
			 octep->ready && facility->size != 0,
			 octep->rpc_ready, (unsigned long long)cfg,
			 (unsigned int)(cfg >> 56),
			 (unsigned long long)posted, (unsigned long long)done,
			 octep->rpc_desc_off, octep->rpc_desc_count,
			 octep->rpc_allow_write, octep->rpc_fw_rev,
			 (unsigned long long)octep->rpc_fw_rev_bumps,
			 octep->rpc_platform_known, octep->rpc_cmd_shift,
			 octep->rpc_platform_len, octep->rpc_platform_conn,
			 octep->rpc_platform_nhop);
	mutex_unlock(&octep->lock);
	return len;
}
static DEVICE_ATTR_RO(rpc_state);

static ssize_t rpc_last_show(struct device *dev,
			     struct device_attribute *attr, char *buf)
{
	struct octep *octep = dev_get_drvdata(dev);
	ssize_t len;

	mutex_lock(&octep->lock);
	len = sysfs_emit(buf,
			 "commands=%llu timeouts=%llu command=%u rc=%#x "
			 "reply_len=%u error=%d\n",
			 (unsigned long long)octep->rpc_commands,
			 (unsigned long long)octep->rpc_timeouts,
			 octep->rpc_last_cmd, octep->rpc_last_rc,
			 octep->rpc_last_len, octep->rpc_last_error);
	mutex_unlock(&octep->lock);
	return len;
}
static DEVICE_ATTR_RO(rpc_last);

static ssize_t rx_flow_show(struct device *dev,
			    struct device_attribute *attr, char *buf)
{
	struct octep *octep = dev_get_drvdata(dev);
	struct octep_rx_flow_track *tracks;
	unsigned long flags, last_jiffies, last_valid_jiffies;
	u64 frames, signature_matches, valid_frames, flow_valid_frames, extra_frames;
	u32 last_id, last_valid_id;
	u16 last_tag, last_valid_tag;
	u8 last_revision, last_valid_revision, last_md_valid;
	bool last_signature, last_valid;
	ssize_t len;
	unsigned int i;

	tracks = kmalloc_array(OCTEP_RX_FLOW_TRACK_MAX, sizeof(*tracks),
			       GFP_KERNEL);
	if (!tracks)
		return -ENOMEM;

	spin_lock_irqsave(&octep->flow_stats_lock, flags);
	frames = octep->rx_meta_frames;
	signature_matches = octep->rx_meta_signature_matches;
	valid_frames = octep->rx_meta_valid_frames;
	extra_frames = octep->rx_meta_extra_frames;
	flow_valid_frames = octep->rx_flow_valid_frames;
	last_id = octep->rx_flow_last_id;
	last_revision = octep->rx_flow_last_revision;
	last_valid_id = octep->rx_flow_last_valid_id;
	last_valid_revision = octep->rx_flow_last_valid_revision;
	last_tag = octep->rx_flow_last_tag;
	last_valid_tag = octep->rx_flow_last_valid_tag;
	memcpy(tracks, octep->rx_flow_tracks,
	       sizeof(*tracks) * OCTEP_RX_FLOW_TRACK_MAX);
	last_md_valid = octep->rx_flow_last_md_valid;
	last_signature = octep->rx_flow_last_signature;
	last_valid = octep->rx_flow_last_valid;
	last_jiffies = octep->rx_flow_last_jiffies;
	last_valid_jiffies = octep->rx_flow_last_valid_jiffies;
	spin_unlock_irqrestore(&octep->flow_stats_lock, flags);

	len = sysfs_emit(buf,
			 "rx_frames=%llu signature_matches=%llu "
			 "metadata_valid=%llu md_extra=%llu flow_valid=%llu "
			 "last_signature=%u last_md_valid=%u "
			 "last_flow_valid=%u last_id=%u last_revision=%u "
			 "last_tag=%u last_age_ms=%u last_valid_id=%u "
			 "last_valid_revision=%u last_valid_tag=%u "
			 "last_valid_age_ms=%u\n",
			 (unsigned long long)frames,
			 (unsigned long long)signature_matches,
			 (unsigned long long)valid_frames,
			 (unsigned long long)extra_frames,
			 (unsigned long long)flow_valid_frames,
			 last_signature, last_md_valid, last_valid, last_id,
			 last_revision, last_tag,
			 last_jiffies ?
			 jiffies_to_msecs(jiffies - last_jiffies) : 0,
			 last_valid_id, last_valid_revision,
			 last_valid_tag,
			 last_valid_jiffies ?
			 jiffies_to_msecs(jiffies - last_valid_jiffies) : 0);
	for (i = 0; i < OCTEP_RX_FLOW_TRACK_MAX && len < PAGE_SIZE; i++) {
		if (!tracks[i].used)
			continue;
		if (!tracks[i].tuple_valid) {
			len += sysfs_emit_at(buf, len,
					     "candidate_id=%u revision=%u tag=%u "
					     "tuple=unparsed frames=%llu age_ms=%u\n",
					     tracks[i].id, tracks[i].revision,
					     tracks[i].tag,
					     (unsigned long long)tracks[i].frames,
					     jiffies_to_msecs(jiffies -
						      tracks[i].last_seen));
		} else if (tracks[i].family == 4) {
			len += sysfs_emit_at(buf, len,
					     "candidate_id=%u revision=%u tag=%u "
					     "tuple=ipv4 proto=%u "
					     "%pI4:%u->%pI4:%u vlan=%u "
					     "src_mac=%pM dst_mac=%pM "
					     "frames=%llu age_ms=%u\n",
					     tracks[i].id, tracks[i].revision,
					     tracks[i].tag, tracks[i].protocol,
					     tracks[i].src_addr, tracks[i].src_port,
					     tracks[i].dst_addr, tracks[i].dst_port,
					     tracks[i].vlan, tracks[i].src_mac,
					     tracks[i].dst_mac,
					     (unsigned long long)tracks[i].frames,
					     jiffies_to_msecs(jiffies -
						      tracks[i].last_seen));
		} else {
			len += sysfs_emit_at(buf, len,
					     "candidate_id=%u revision=%u tag=%u "
					     "tuple=ipv6 proto=%u "
					     "%pI6c:%u->%pI6c:%u vlan=%u "
					     "src_mac=%pM dst_mac=%pM "
					     "frames=%llu age_ms=%u\n",
					     tracks[i].id, tracks[i].revision,
					     tracks[i].tag, tracks[i].protocol,
					     tracks[i].src_addr, tracks[i].src_port,
					     tracks[i].dst_addr, tracks[i].dst_port,
					     tracks[i].vlan, tracks[i].src_mac,
					     tracks[i].dst_mac,
					     (unsigned long long)tracks[i].frames,
					     jiffies_to_msecs(jiffies -
						      tracks[i].last_seen));
		}
	}
	kfree(tracks);
	return len;
}
static DEVICE_ATTR_RO(rx_flow);

static ssize_t ft_diag_show(struct device *dev, struct device_attribute *attr,
			    char *buf)
{
	struct octep *octep = dev_get_drvdata(dev);
	unsigned long flags;
	unsigned int n, i, head;
	ssize_t len = 0;

	spin_lock_irqsave(&octep->flow_stats_lock, flags);
	len += sysfs_emit_at(buf, len,
			     "recorded=%llu pair_waits=%llu pair_creates=%llu ct_queued=%llu ct_dropped=%llu ct_released=%llu ct_refreshed=%llu\n",
			     octep->ft_diag_total, octep->ft_pair_waits,
			     octep->ft_pair_creates, octep->ft_ct_queued,
			     octep->ft_ct_dropped, octep->ft_ct_released,
			     octep->ft_ct_refreshed);
	head = octep->ft_diag_head;
	n = min_t(unsigned int, head, OCTEP_FT_DIAG_RING);
	for (i = 0; i < n && len < PAGE_SIZE - 128; i++) {
		const struct octep_ft_diag_rec *r =
			&octep->ft_diag_ring[(head - n + i) % OCTEP_FT_DIAG_RING];

		len += sysfs_emit_at(buf, len,
				     "%u %pI4:%u > %pI4:%u dir %u flow_valid %u md_valid 0x%02x id %u rev %u tag 0x%x\n",
				     jiffies_to_msecs(jiffies - r->when),
				     &r->src, r->sport, &r->dst, r->dport,
				     r->dir, r->flow_valid, r->md_valid,
				     r->id, r->rev, r->tag);
	}
	spin_unlock_irqrestore(&octep->flow_stats_lock, flags);
	return len;
}
static DEVICE_ATTR_RO(ft_diag);

struct octep_flow_snapshot {
	u32 index;
	u16 revision;
	u64 packets[2];
	u64 bytes[2];
	u64 sequence;
	unsigned long last_update;
};

static ssize_t flow_stats_show(struct device *dev,
			       struct device_attribute *attr, char *buf)
{
	struct octep *octep = dev_get_drvdata(dev);
	struct octep_flow_snapshot recent[OCTEP_FLOW_STATS_SHOW_MAX];
	unsigned long flags, now = jiffies;
	u64 tag_frames, cmsg_rx, messages, entries, malformed, dropped;
	u64 untracked;
	u32 tracked = 0, stale = 0, shown = 0, i, j;
	u8 last_type;
	unsigned long last_jiffies;
	ssize_t len;

	spin_lock_irqsave(&octep->flow_stats_lock, flags);
	tag_frames = octep->cmsg_tag_frames;
	cmsg_rx = octep->cmsg_rx;
	messages = octep->cmsg_conn_stats_messages;
	entries = octep->cmsg_conn_stats_entries;
	malformed = octep->cmsg_malformed;
	dropped = octep->cmsg_dropped;
	untracked = octep->cmsg_untracked;
	last_type = octep->cmsg_last_type;
	last_jiffies = octep->cmsg_last_jiffies;
	for (i = 0; i < ARRAY_SIZE(octep->flow_stats); i++) {
		const struct octep_flow_counter *counter =
			&octep->flow_stats[i];
		u32 pos;

		if (!counter->used)
			continue;
		if (time_after(now, counter->last_update +
				    OCTEP_FLOW_STATS_LIVE_JIFFIES)) {
			stale++;
			continue;
		}
		tracked++;
		pos = 0;
		while (pos < shown &&
		       recent[pos].sequence > counter->sequence)
			pos++;
		if (pos == OCTEP_FLOW_STATS_SHOW_MAX)
			continue;
		if (shown < OCTEP_FLOW_STATS_SHOW_MAX)
			shown++;
		for (j = shown - 1; j > pos; j--)
			recent[j] = recent[j - 1];
		recent[pos].index = counter->index;
		recent[pos].revision = counter->revision;
		memcpy(recent[pos].packets, counter->packets,
		       sizeof(recent[pos].packets));
		memcpy(recent[pos].bytes, counter->bytes,
		       sizeof(recent[pos].bytes));
		recent[pos].sequence = counter->sequence;
		recent[pos].last_update = counter->last_update;
	}
	spin_unlock_irqrestore(&octep->flow_stats_lock, flags);

	len = sysfs_emit(buf,
			 "tag254_frames=%llu cmsg_rx=%llu conn_stats_messages=%llu "
			 "conn_stats_entries=%llu tracked=%u stale=%u untracked=%llu "
			 "malformed=%llu dropped=%llu last_type=%u "
			 "last_age_ms=%u shown=%u truncated=%u\n",
			 (unsigned long long)tag_frames,
			 (unsigned long long)cmsg_rx,
			 (unsigned long long)messages,
			 (unsigned long long)entries, tracked, stale,
			 (unsigned long long)untracked,
			 (unsigned long long)malformed,
			 (unsigned long long)dropped, last_type,
			 last_jiffies ?
			 jiffies_to_msecs(now - last_jiffies) : 0,
			 shown, tracked > shown);
	for (i = 0; i < shown && len < PAGE_SIZE; i++) {
		len += sysfs_emit_at(buf, len,
				     "index=%u revision=%u orig_packets=%llu "
				     "orig_bytes=%llu reply_packets=%llu "
				     "reply_bytes=%llu age_ms=%u\n",
				     recent[i].index, recent[i].revision,
				     (unsigned long long)recent[i].packets[0],
				     (unsigned long long)recent[i].bytes[0],
				     (unsigned long long)recent[i].packets[1],
				     (unsigned long long)recent[i].bytes[1],
				     jiffies_to_msecs(now -
						      recent[i].last_update));
	}
	return len;
}
static DEVICE_ATTR_RO(flow_stats);

static ssize_t facilities_show(struct device *dev,
			       struct device_attribute *attr, char *buf)
{
	struct octep *octep = dev_get_drvdata(dev);
	ssize_t len = 0;
	unsigned int i;

	mutex_lock(&octep->lock);
	if (!octep->ready) {
		len = sysfs_emit(buf, "barmap not ready\n");
		goto out;
	}

	for (i = 0; i < OCTEP_FACILITY_COUNT && len < PAGE_SIZE; i++) {
		const struct octep_facility *facility = &octep->facility[i];

		if (!facility->size)
			continue;
		len += sysfs_emit_at(buf, len,
				     "%s offset=%#x size=%#x h2t_dbells=%u..%u\n",
				     octep_facility_names[i], facility->offset,
				     facility->size, facility->dbell_start,
				     facility->dbell_count ?
				     facility->dbell_start +
				     facility->dbell_count - 1 :
				     facility->dbell_start);
	}
out:
	mutex_unlock(&octep->lock);
	return len;
}
static DEVICE_ATTR_RO(facilities);

static ssize_t nwa_discover_store(struct device *dev,
				  struct device_attribute *attr,
				  const char *buf, size_t count)
{
	struct octep *octep = dev_get_drvdata(dev);
	u32 value;
	int err;

	err = kstrtou32(buf, 0, &value);
	if (err)
		return err;
	if (value != 1)
		return -EINVAL;

	mutex_lock(&octep->lock);
	err = octep_nwa_discover_locked(octep);
	mutex_unlock(&octep->lock);
	if (err)
		return err;
	return count;
}
static DEVICE_ATTR_WO(nwa_discover);

static ssize_t nwa_request_store(struct device *dev,
				 struct device_attribute *attr,
				 const char *buf, size_t count)
{
	struct octep *octep = dev_get_drvdata(dev);
	u32 op, sub, port, param, param2;
	int err;

	if (sscanf(buf, "%u %u %u %u %u", &op, &sub, &port, &param,
		   &param2) != 5)
		return -EINVAL;

	mutex_lock(&octep->lock);
	octep->nwa_last_op = op;
	octep->nwa_last_sub = sub;
	octep->nwa_last_port = port;
	octep->nwa_last_param = param;
	octep->nwa_last_param2 = param2;
	octep->nwa_last_words = 0;
	octep->nwa_last_marker = 0;
	octep->nwa_last_status = 0;
	octep->nwa_last_reply_len = 0;
	memset(octep->nwa_last_reply, 0, sizeof(octep->nwa_last_reply));
	err = octep_nwa_request_locked(octep, op, sub, port, param, param2);
	octep->nwa_last_error = err;
	if (!err) {
		dev_info(dev,
			 "NWA request op=%u sub=%u port=%u completed: status=%#x, %u reply words\n",
			 op, sub, port, octep->nwa_last_status,
			 octep->nwa_last_words);
	} else {
		dev_err(dev,
			"NWA request op=%u sub=%u port=%u failed: %d\n",
			op, sub, port, err);
	}
	mutex_unlock(&octep->lock);

	return err ? err : count;
}
static DEVICE_ATTR_WO(nwa_request);

static ssize_t nwa_last_show(struct device *dev,
			     struct device_attribute *attr, char *buf)
{
	struct octep *octep = dev_get_drvdata(dev);
	ssize_t len;
	unsigned int i;

	mutex_lock(&octep->lock);
	len = sysfs_emit(buf,
			 "op=%u sub=%u port=%u param=%#x param2=%#x marker=%#x "
			 "status=%#x reply_len=%u words=%u error=%d\n",
			 octep->nwa_last_op, octep->nwa_last_sub,
			 octep->nwa_last_port, octep->nwa_last_param,
			 octep->nwa_last_param2, octep->nwa_last_marker,
			 octep->nwa_last_status, octep->nwa_last_reply_len,
			 octep->nwa_last_words, octep->nwa_last_error);
	if (octep->nwa_last_op == OCTEP_NWA_OP_GET &&
	    octep->nwa_last_sub == OCTEP_NWA_SUB_STATS &&
	    !octep->nwa_last_error &&
	    octep->nwa_last_words == OCTEP_NWA_STATS_WORDS) {
		for (i = 0; i < OCTEP_NWA_STATS_COUNT && len < PAGE_SIZE; i++) {
			u64 value = ((u64)octep->nwa_last_reply[i * 2 + 1] << 32) |
				    octep->nwa_last_reply[i * 2];

			len += sysfs_emit_at(buf, len, "%s=%llu\n",
					     octep_nwa_stat_names[i],
					     (unsigned long long)value);
		}
	} else {
		for (i = 0; i < octep->nwa_last_words && len < PAGE_SIZE; i++)
			len += sysfs_emit_at(buf, len, "word%u=%#010x\n", i,
					     octep->nwa_last_reply[i]);
	}
	mutex_unlock(&octep->lock);
	return len;
}
static DEVICE_ATTR_RO(nwa_last);

static ssize_t nwa_ports_show(struct device *dev,
			      struct device_attribute *attr, char *buf)
{
	struct octep *octep = dev_get_drvdata(dev);
	ssize_t len = 0;
	unsigned int i;

	mutex_lock(&octep->lock);
	if (!octep->nwa_discovered) {
		len = sysfs_emit(buf, "no successful NWA discovery; write 1 to nwa_discover\n");
		goto out;
	}

	len += sysfs_emit_at(buf, len, "ports=%u marker=%#x status=%#x reply_len=%u\n",
			     octep->nwa_nports, octep->nwa_marker,
			     octep->nwa_status, octep->nwa_reply_len);
	len += sysfs_emit_at(buf, len, "index tag flags mtu uc mc mac valid config\n");
	for (i = 0; i < octep->nwa_nports && len < PAGE_SIZE; i++) {
		const u32 *words = &octep->nwa_reply[1 + i * 5];

		len += sysfs_emit_at(buf, len,
				     "%u %#06x %#06x %u %u %u %u %#010x %#010x\n",
				     i, words[0] & 0xffff, words[0] >> 16,
				     words[1] & 0xffff, words[1] >> 16,
				     words[2] & 0xffff, words[2] >> 16,
				     words[3], words[4]);
	}
out:
	mutex_unlock(&octep->lock);
	return len;
}
static DEVICE_ATTR_RO(nwa_ports);

static ssize_t barmap_rescan_store(struct device *dev,
				   struct device_attribute *attr,
				   const char *buf, size_t count)
{
	struct octep *octep = dev_get_drvdata(dev);
	int err;

	mutex_lock(&octep->lock);
	err = octep_read_barmap_locked(octep);
	if (!err)
		octep_log_sdp_rinfo(octep);
	mutex_unlock(&octep->lock);
	if (!err)
		dev_info(dev,
			 "barmap v%u at BAR2+%#x; PEM %u; GICD offset %#x\n",
			 octep->barmap_version, octep->barmap_offset,
			 octep->pem_num, octep->gicd_offset);
	if (err == -EAGAIN) {
		dev_info(dev,
			 "barmap not published yet; retry with: echo 1 > "
			 "/sys/bus/pci/devices/%s/barmap_rescan\n",
			 dev_name(dev));
		return err;
	}
	if (err)
		return err;
	return count;
}
static DEVICE_ATTR_WO(barmap_rescan);

static struct attribute *octep_attrs[] = {
	&dev_attr_state.attr,
	&dev_attr_sdp_rinfo.attr,
	&dev_attr_sdp_state.attr,
	&dev_attr_sdp_start.attr,
	&dev_attr_sdp_handshake.attr,
	&dev_attr_sdp_stop.attr,
	&dev_attr_sdp_port_add.attr,
	&dev_attr_sdp_coproc_ticks_per_us.attr,
	&dev_attr_rpc_state.attr,
	&dev_attr_rpc_configure.attr,
	&dev_attr_rpc_allow_write.attr,
	&dev_attr_offload.attr,
	&dev_attr_rpc_lif_add.attr,
	&dev_attr_rpc_lif_read.attr,
	&dev_attr_rpc_sys_counters.attr,
	&dev_attr_rpc_mflow_read.attr,
	&dev_attr_rpc_conn_read.attr,
	&dev_attr_rpc_conn_reclaim.attr,
	&dev_attr_rpc_pport_update.attr,
	&dev_attr_rpc_fw_rev_bump.attr,
	&dev_attr_rpc_flow_write.attr,
	&dev_attr_rpc_raw_write.attr,
	&dev_attr_flow_stats.attr,
	&dev_attr_rx_flow.attr,
	&dev_attr_ft_diag.attr,
	&dev_attr_rpc_last.attr,
	&dev_attr_facilities.attr,
	&dev_attr_nwa_discover.attr,
	&dev_attr_nwa_request.attr,
	&dev_attr_nwa_last.attr,
	&dev_attr_nwa_ports.attr,
	&dev_attr_barmap_rescan.attr,
	NULL,
};
ATTRIBUTE_GROUPS(octep);

static void octep_vf_mbox_poll_work(struct work_struct *work)
{
	struct octep *octep = container_of(to_delayed_work(work),
					   struct octep, vf_mbox_work);
	union octep_vf_mbox_word req, rsp;
	u64 pending;
	u32 num_vfs, ring_start, vf;

	if (!READ_ONCE(octep->vf_mbox_enabled))
		return;

	num_vfs = min_t(u32, pci_num_vf(octep->pdev),
			OCTEP_SRIOV_VF_COUNT);
	ring_start = READ_ONCE(octep->vf_mbox_ring_start);
	pending = readq(octep->bar0 + OCTEP_SDP_EPF_MBOX_RINT);

	for (vf = 0; vf < num_vfs; vf++) {
		resource_size_t mbox_offset;
		void __iomem *mbox;
		u32 ring = ring_start + vf * OCTEP_SRIOV_RINGS_PER_VF;

		mbox_offset = OCTEP_SDP_R_MBOX_VF_PF_DATA +
			      (resource_size_t)ring * OCTEP_SDP_RING_STRIDE;
		if (ring >= 64 || mbox_offset > octep->bar0_len ||
		    sizeof(u64) > octep->bar0_len - mbox_offset) {
			dev_err_ratelimited(&octep->pdev->dev,
					    "sriov: VF%u mailbox register is outside BAR0\n",
					    vf + 1);
			break;
		}

		mbox = octep->bar0 + mbox_offset;
		req.u64 = readq(mbox);
		if (req.s.type != OCTEP_VF_MBOX_TYPE_CMD)
			continue;

		rsp.u64 = 0;
		rsp.s.opcode = req.s.opcode;
		rsp.s.type = OCTEP_VF_MBOX_TYPE_RSP_NACK;
		switch (req.s.opcode) {
		case OCTEP_VF_MBOX_CMD_VERSION:
			rsp.s_version.type = OCTEP_VF_MBOX_TYPE_RSP_ACK;
			rsp.s_version.version =
				min_t(u64, req.s_version.version,
				      OCTEP_VF_MBOX_VERSION_V1);
			break;
		case OCTEP_VF_MBOX_CMD_GET_MAC_ADDR:
			rsp.s_mac.type = OCTEP_VF_MBOX_TYPE_RSP_ACK;
			ether_addr_copy(rsp.s_mac.mac_addr, octep->vf_mac[vf]);
			break;
		case OCTEP_VF_MBOX_CMD_GET_MTU:
			rsp.s_mtu.type = OCTEP_VF_MBOX_TYPE_RSP_ACK;
			rsp.s_mtu.mtu = OCTEP_DP_PKT_MAX;
			break;
		case OCTEP_VF_MBOX_CMD_DEV_REMOVE:
			rsp.s.type = OCTEP_VF_MBOX_TYPE_RSP_ACK;
			break;
		default:
			dev_dbg(&octep->pdev->dev,
				"sriov: NACK VF%u mailbox opcode %u\n",
				vf + 1, req.s.opcode);
			break;
		}

		if (pending != U64_MAX && (pending & BIT_ULL(ring))) {
			writeq(BIT_ULL(ring),
			       octep->bar0 + OCTEP_SDP_EPF_MBOX_RINT);
			pending &= ~BIT_ULL(ring);
		}
		writeq(rsp.u64, mbox);
		if (!octep->vf_mbox_logged[vf]) {
			dev_info(&octep->pdev->dev,
				 "sriov: VF%u mailbox active; only bootstrap commands are supported\n",
				 vf + 1);
			octep->vf_mbox_logged[vf] = true;
		}
	}

	if (READ_ONCE(octep->vf_mbox_enabled))
		queue_delayed_work(system_dfl_wq, &octep->vf_mbox_work,
				   msecs_to_jiffies(OCTEP_VF_MBOX_POLL_MS));
}

static int octep_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
	struct octep *octep;
	int err;

	octep_dp_max_mtu = clamp(octep_dp_max_mtu, 1500u, 9000u);
	err = pci_enable_device_mem(pdev);
	if (err)
		return err;

	err = pci_request_regions(pdev, "octep");
	if (err)
		goto err_disable;

	if (!(pci_resource_flags(pdev, 0) & IORESOURCE_MEM) ||
	    !(pci_resource_flags(pdev, 2) & IORESOURCE_MEM)) {
		dev_err(&pdev->dev, "BAR0 and BAR2 must be memory resources\n");
		err = -ENODEV;
		goto err_regions;
	}

	octep = devm_kzalloc(&pdev->dev, sizeof(*octep), GFP_KERNEL);
	if (!octep) {
		err = -ENOMEM;
		goto err_regions;
	}
	octep->pdev = pdev;
	octep->bar0_len = pci_resource_len(pdev, 0);
	octep->bar2_len = pci_resource_len(pdev, 2);
	mutex_init(&octep->lock);
	spin_lock_init(&octep->mgmt_lock);
	spin_lock_init(&octep->dp_tx_lock);
	spin_lock_init(&octep->dp_stats_lock);
	spin_lock_init(&octep->flow_stats_lock);
	INIT_DELAYED_WORK(&octep->mgmt_poll_work, octep_mgmt_poll_work);
	INIT_DELAYED_WORK(&octep->dp_poll_work, octep_dp_poll_work);
	INIT_DELAYED_WORK(&octep->vf_mbox_work, octep_vf_mbox_poll_work);
	INIT_DELAYED_WORK(&octep->ft_work, octep_ft_work);
	INIT_DELAYED_WORK(&octep->ft_guard_work, octep_ft_guard_work);

	if (octep->bar0_len < OCTEP_SDP_SCRATCH + sizeof(u64) ||
	    octep->bar2_len < OCTEP_BARMAP_SIZE) {
		dev_err(&pdev->dev, "BAR0 or BAR2 is too small\n");
		err = -ENXIO;
		goto err_regions;
	}

	octep->bar0 = pci_iomap(pdev, 0, 0);
	octep->bar2 = pci_iomap(pdev, 2, 0);
	if (!octep->bar0 || !octep->bar2) {
		dev_err(&pdev->dev, "cannot map BAR0 or BAR2\n");
		err = -ENOMEM;
		goto err_iomap;
	}

	pci_set_drvdata(pdev, octep);
	if (pdev->bus->self)
		dev_info(&pdev->dev, "upstream PCI bridge %s [%04x:%04x]\n",
			 pci_name(pdev->bus->self), pdev->bus->self->vendor,
			 pdev->bus->self->device);
	mutex_lock(&octep->lock);
	err = octep_read_barmap_locked(octep);
	mutex_unlock(&octep->lock);
	octep_log_sdp_rinfo(octep);
	if (err == -EAGAIN) {
		dev_info(&pdev->dev,
			 "attached; re-read with: echo 1 > "
			 "/sys/bus/pci/devices/%s/barmap_rescan\n",
			 dev_name(&pdev->dev));
	} else if (err) {
		goto err_iomap;
	} else {
		dev_info(&pdev->dev,
			 "barmap v%u at BAR2+%#x; PEM %u; GICD offset %#x\n",
			 octep->barmap_version, octep->barmap_offset,
			 octep->pem_num, octep->gicd_offset);
	}

	err = octep_mgmt_netdev_register(octep);
	if (err) {
		dev_err(&pdev->dev, "failed to register management netdev: %d\n",
			err);
		goto err_iomap;
	}

	dev_info(&pdev->dev,
		 "BAR0 [%#llx-%#llx] (%#llx bytes), BAR2 [%#llx-%#llx] "
		 "(%#llx bytes); SDP DMA is stopped until explicitly started\n",
		 (unsigned long long)pci_resource_start(pdev, 0),
		 (unsigned long long)pci_resource_end(pdev, 0),
		 (unsigned long long)octep->bar0_len,
		 (unsigned long long)pci_resource_start(pdev, 2),
		 (unsigned long long)pci_resource_end(pdev, 2),
		 (unsigned long long)octep->bar2_len);
	octep_ft_trig_set_ready(true);
	return 0;

err_iomap:
	if (octep->bar2)
		pci_iounmap(pdev, octep->bar2);
	if (octep->bar0)
		pci_iounmap(pdev, octep->bar0);
err_regions:
	pci_release_regions(pdev);
err_disable:
	pci_disable_device(pdev);
	return err;
}

static void octep_remove(struct pci_dev *pdev)
{
	struct octep *octep = pci_get_drvdata(pdev);

	octep_ft_trig_set_ready(false);
	WRITE_ONCE(octep->vf_mbox_enabled, false);
	cancel_delayed_work_sync(&octep->vf_mbox_work);
	WRITE_ONCE(octep->dp_poll_enabled, false);
	cancel_delayed_work_sync(&octep->dp_poll_work);
	octep_dp_napi_destroy(octep);
	octep_ft_release_all(octep);
	octep_ft_trig_forget(octep);
	octep_dp_netdev_unregister_all(octep);
	octep_mgmt_netdev_unregister(octep);
	mutex_lock(&octep->lock);
	if (octep->dp_up)
		octep_dp_stop_locked(octep, true);
	mutex_unlock(&octep->lock);
	if (pci_num_vf(pdev))
		pci_disable_sriov(pdev);
	if (octep->bar2)
		pci_iounmap(pdev, octep->bar2);
	if (octep->bar0)
		pci_iounmap(pdev, octep->bar0);
	pci_release_regions(pdev);
	pci_disable_device(pdev);
}

static int octep_sriov_configure(struct pci_dev *pdev, int num_vfs)
{
	struct octep *octep = pci_get_drvdata(pdev);
	struct octep_sdp_rinfo rinfo;
	u32 pf_start_ring, vf;
	int enabled_vfs, err, rollback_err;
	u64 scratch;

	if (!octep)
		return -ENODEV;
	if (num_vfs < 0 ||
	    (num_vfs != 0 && num_vfs != OCTEP_SRIOV_VF_COUNT))
		return -EINVAL;

	enabled_vfs = pci_num_vf(pdev);
	if (num_vfs == enabled_vfs)
		return enabled_vfs;

	mutex_lock(&octep->lock);
	scratch = readq(octep->bar0 + OCTEP_SLI_EPF_SCRATCH);
	if (octep->dp_up || octep->hs_done || scratch) {
		dev_err(&pdev->dev,
			"sriov: refusing VF change while SDP is active or handshake scratch is owned\n");
		err = -EBUSY;
		goto out;
	}

	if (num_vfs) {
		rinfo = octep_read_sdp_rinfo(octep);
		err = octep_sdp_validate_vfs(octep, &rinfo, num_vfs,
					     &pf_start_ring);
		if (err)
			goto out;
		if (pci_sriov_get_totalvfs(pdev) < num_vfs) {
			err = -ENOSPC;
			goto out;
		}
		err = pci_enable_sriov(pdev, num_vfs);
		if (err)
			goto out;
		rinfo = octep_read_sdp_rinfo(octep);
		err = octep_sdp_prepare_vfs_locked(octep, &rinfo,
						   &pf_start_ring);
		if (err) {
			pci_disable_sriov(pdev);
			rollback_err = octep_sdp_clear_vf_split_locked(octep);
			if (rollback_err)
				dev_err(&pdev->dev,
					"sriov: failed to roll back VF ring split after setup error: %d\n",
					rollback_err);
			goto out;
		}
		WRITE_ONCE(octep->vf_mbox_ring_start, rinfo.start_ring);
		for (vf = 0; vf < num_vfs; vf++) {
			eth_random_addr(octep->vf_mac[vf]);
			octep->vf_mbox_logged[vf] = false;
		}
		WRITE_ONCE(octep->vf_mbox_enabled, true);
		mod_delayed_work(system_dfl_wq, &octep->vf_mbox_work, 0);
		dev_info(&pdev->dev,
			 "sriov: enabled %d VFs; RINFO split published and mailbox polling started\n",
			 num_vfs);
		err = num_vfs;
	} else {
		WRITE_ONCE(octep->vf_mbox_enabled, false);
		cancel_delayed_work_sync(&octep->vf_mbox_work);
		pci_disable_sriov(pdev);
		err = octep_sdp_clear_vf_split_locked(octep);
		if (!err)
			dev_info(&pdev->dev,
				 "sriov: disabled VFs and cleared the unhandshaken RINFO split\n");
	}

out:
	mutex_unlock(&octep->lock);
	return err;
}

static const struct pci_device_id octep_pci_ids[] = {
	{ PCI_DEVICE(OCTEP_VENDOR_ID, OCTEP_CN83XX_PF_ID) },
	{ }
};
MODULE_DEVICE_TABLE(pci, octep_pci_ids);

static struct pci_driver octep_driver = {
	.name = "octep",
	.id_table = octep_pci_ids,
	.probe = octep_probe,
	.remove = octep_remove,
	.sriov_configure = octep_sriov_configure,
	.dev_groups = octep_groups,
};
module_pci_driver(octep_driver);

MODULE_DESCRIPTION("OCTEON TX CN83XX PCIe endpoint core");
MODULE_LICENSE("GPL");
