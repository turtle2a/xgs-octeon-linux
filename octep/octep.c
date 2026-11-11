// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * Linux PCI core for the OCTEON TX CN83XX endpoint (177d:a300).
 *
 * Probe only maps BAR0/BAR2 and reads the published facility map. SDP DMA
 * queues and the EP-mode handshake are started separately by explicit sysfs
 * writes; neither is activated as a side effect of PCI probe.
 */

#include <linux/bitops.h>
#include <linux/dma-mapping.h>
#include <linux/etherdevice.h>
#include <linux/hex.h>
#include <linux/if_ether.h>
#include <linux/if_vlan.h>
#include <linux/io.h>
#include <linux/delay.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/netdevice.h>
#include <linux/pci.h>
#include <linux/skbuff.h>
#include <linux/spinlock.h>
#include <linux/sysfs.h>
#include <linux/unaligned.h>
#include <linux/workqueue.h>

#define OCTEP_VENDOR_ID			0x177d
#define OCTEP_CN83XX_PF_ID		0xa300

#define OCTEP_SDP_SCRATCH		0x20180
#define OCTEP_SDP_EPF_RINFO		0x20190
#define OCTEP_SLI_EPF_SCRATCH		0x28100
#define OCTEP_SDP_RING_STRIDE		0x20000
#define OCTEP_SDP_RING_SPAN		0x10198
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
#define OCTEP_DP_MIN_FRAME		60
#define OCTEP_DP_PKT_MAX		65535
#define OCTEP_DP_OQ_GRANT		(OCTEP_DP_OQ_DESCS + \
					 OCTEP_DP_OQ_WMARK - \
					 OCTEP_DP_OQ_FETCH)
#define OCTEP_DP_TXBUF_SIZE		(OCTEP_MGMT_MTU + ETH_HLEN + VLAN_HLEN + \
					 OCTEP_DP_TAG_LEN)
#define OCTEP_DP_TXBUF_STRIDE		ALIGN(OCTEP_DP_TXBUF_SIZE, \
					      OCTEP_DP_BUF_ALIGN)
#define OCTEP_DP_PORT_MAX		32
#define OCTEP_DP_P_KIND		40
#define OCTEP_DP_OP_PACKET		0x1220
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
#define OCTEP_RPC_CMD_LIF_ADD_UPDATE	3
#define OCTEP_RPC_CMD_PPORT_UPDATE	5
#define OCTEP_RPC_LIF_M_ALL		0x00ff
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
	struct delayed_work mgmt_poll_work;
	struct delayed_work dp_poll_work;
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
	u32 dp_tx_prod;
	u32 dp_port_count;
	struct octep_dp_port dp_port[OCTEP_DP_PORT_MAX];
	struct octep_dp_ring dp_ring[OCTEP_DP_RING_COUNT];
	struct octep_dma_mem rpc_cmd;
	u32 rpc_desc_off;
	u32 rpc_desc_count;
	u64 rpc_posted;
	bool rpc_ready;
	bool rpc_allow_write;
	u32 rpc_last_cmd;
	u16 rpc_last_rc;
	u16 rpc_last_len;
	int rpc_last_error;
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
			dev_info(&octep->pdev->dev,
				 "doorbell write attempt: SPI %u to BAR2+%#x\n",
				 spi, octep->gicd_offset);
			writel(spi, octep->bar2 + octep->gicd_offset);
			wmb();
			dev_info(&octep->pdev->dev,
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
		if (sub != OCTEP_NWA_SUB_STATE &&
		    sub != OCTEP_NWA_SUB_MAC)
			return -EPERM;
		if (param || param2)
			return -EINVAL;
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
		u32 idx, span, frame_len, chunk, copied, j;
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

		if (port && frame_len >= ETH_HLEN &&
		    frame_len <= OCTEP_MGMT_MTU + ETH_HLEN + VLAN_HLEN) {
			skb = netdev_alloc_skb_ip_align(port->netdev, frame_len);
			if (skb) {
				dst = skb_put(skb, frame_len);
				chunk = min_t(u32, frame_len,
					      OCTEP_DP_BUF_SIZE -
					      OCTEP_DP_RX_PREFIX_LEN);
				memcpy(dst, buf + OCTEP_DP_RX_PREFIX_LEN, chunk);
				copied = chunk;
				for (j = 1; j < span && copied < frame_len; j++) {
					u8 *next = (u8 *)ring->bufs.vaddr +
						   (size_t)((idx + j) %
							    OCTEP_DP_OQ_DESCS) *
						   OCTEP_DP_BUF_STRIDE;

					chunk = min_t(u32, frame_len - copied,
						      OCTEP_DP_BUF_SIZE);
					memcpy(dst + copied, next, chunk);
					copied += chunk;
				}
				if (copied == frame_len) {
					skb->protocol = eth_type_trans(skb,
								       port->netdev);
					if (netif_rx(skb) == NET_RX_DROP)
						octep_dp_count_rx(octep, port,
								  frame_len, true);
					else
						octep_dp_count_rx(octep, port,
								  frame_len, false);
				} else {
					dev_kfree_skb_any(skb);
					octep_dp_count_rx(octep, port, 0, true);
				}
			} else {
				octep_dp_count_rx(octep, port, 0, true);
			}
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

static void octep_dp_poll_work(struct work_struct *work)
{
	struct octep *octep = container_of(to_delayed_work(work),
					   struct octep, dp_poll_work);
	unsigned long flags;
	unsigned int i;
	u32 pending;

	if (!READ_ONCE(octep->dp_poll_enabled))
		return;

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

	if (READ_ONCE(octep->dp_poll_enabled))
		schedule_delayed_work(&octep->dp_poll_work,
				      msecs_to_jiffies(OCTEP_DP_POLL_MS));
}

static int octep_dp_open(struct net_device *netdev)
{
	struct octep_netdev_priv *priv = netdev_priv(netdev);
	struct octep *octep = priv->octep;

	if (!READ_ONCE(octep->dp_io_enabled) || !READ_ONCE(octep->hs_done))
		return -ENETDOWN;
	netif_carrier_on(netdev);
	netif_start_queue(netdev);
	return 0;
}

static int octep_dp_stop(struct net_device *netdev)
{
	netif_stop_queue(netdev);
	netif_carrier_off(netdev);
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

	len = skb->len;
	if (len < ETH_HLEN ||
	    len > netdev->mtu + ETH_HLEN + VLAN_HLEN ||
	    len + OCTEP_DP_TAG_LEN > OCTEP_DP_TXBUF_SIZE) {
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

static const struct net_device_ops octep_dp_netdev_ops = {
	.ndo_open		= octep_dp_open,
	.ndo_stop		= octep_dp_stop,
	.ndo_start_xmit		= octep_dp_xmit,
	.ndo_get_stats64	= octep_dp_get_stats64,
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
	if (rinfo.num_vfs || rinfo.pf_rings < OCTEP_DP_RING_COUNT) {
		dev_err(&octep->pdev->dev,
			"dp: this PF-only setup needs %u PF rings and no VFs; RINFO is %#018llx\n",
			OCTEP_DP_RING_COUNT, (unsigned long long)rinfo.value);
		return -EINVAL;
	}
	base_ring = rinfo.start_ring;
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
		schedule_delayed_work(&octep->dp_poll_work,
				      msecs_to_jiffies(OCTEP_DP_POLL_MS));
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
	cancel_delayed_work_sync(&octep->dp_poll_work);
	mutex_lock(&octep->lock);
	err = octep_dp_stop_locked(octep, false);
	if (err && octep->dp_up &&
	    (octep->hs_done ||
	     readq(octep->bar0 + OCTEP_SLI_EPF_SCRATCH)))
		WRITE_ONCE(octep->dp_poll_enabled, true);
	mutex_unlock(&octep->lock);
	if (err && READ_ONCE(octep->dp_poll_enabled))
		schedule_delayed_work(&octep->dp_poll_work,
				      msecs_to_jiffies(OCTEP_DP_POLL_MS));
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
	u32 i, ticks_per_us;
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
	if (rinfo.value == U64_MAX || rinfo.pf_rings < OCTEP_DP_RING_COUNT) {
		err = -ENXIO;
		goto out;
	}
	info_word = ((u64)OCTEP_SDP_APP_MODE_NIC << 40) |
		    ((u64)rinfo.start_ring << 32) |
		    ((u64)OCTEP_DP_RING_COUNT << 24);

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
		 "sdp: target asked; published %#018llx (app %u, pf_srn %u, rppf %u, 0 VFs)\n",
		 (unsigned long long)info_word, OCTEP_SDP_APP_MODE_NIC,
		 rinfo.start_ring, OCTEP_DP_RING_COUNT);
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
	netdev->min_mtu = ETH_MIN_MTU;
	netdev->max_mtu = OCTEP_MGMT_MTU;
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
	int err;

	lockdep_assert_held(&octep->lock);
	if (!octep->dp_up || !octep->hs_reply_received)
		return -ENXIO;
	if (octep->rpc_ready)
		return -EALREADY;
	if (!octep->ready || !facility->size || !facility->dbell_count)
		return -ENXIO;

	desc_end = (u64)OCTEP_RPC_DESC_OFFSET +
		   (u64)OCTEP_RPC_DESC_COUNT * OCTEP_RPC_BAR_DESC_SIZE;
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

		octep_rpc_writeq(octep, hi + OCTEP_RPC_RING_POSTED, 0);
		octep_rpc_writeq(octep, hi + OCTEP_RPC_RING_DONE, 0);
		octep_rpc_writel(octep, hi + OCTEP_RPC_RING_OFFSET, 0);
		octep_rpc_writel(octep, hi + OCTEP_RPC_RING_DESC_OFF, 0);
		octep_rpc_writel(octep, hi + OCTEP_RPC_RING_DESC_CNT, 0);
		octep_rpc_writel(octep, hi + OCTEP_RPC_RING_CFG, 0);
	}
	wmb();

	cfg = OCTEP_RPC_STATE_CFG_MAGIC | ((u64)revision << 32);
	octep_rpc_writeq(octep, OCTEP_RPC_STATE_CFG, cfg);
	wmb();
	dev_info(&octep->pdev->dev,
		 "rpc: published low-ring config revision %u, %u descriptors at BAR2+%#x, doorbell 0\n",
		 revision, OCTEP_RPC_DESC_COUNT,
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
			octep->rpc_ready = true;
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

static int octep_rpc_post_port_command_locked(struct octep *octep, u8 command,
					      const u8 *payload,
					      u16 payload_len)
{
	struct octep_facility *facility = &octep->facility[OCTEP_FCLT_RPC];
	u8 *buffer = octep->rpc_cmd.vaddr;
	u64 posted, done, desc;
	u32 index, offset, i;
	u16 rc, reply_len;
	int err;

	lockdep_assert_held(&octep->lock);
	if (!octep->rpc_ready)
		return -ENXIO;
	if (!octep->rpc_allow_write)
		return -EPERM;
	if (command != OCTEP_RPC_CMD_LIF_ADD_UPDATE &&
	    command != OCTEP_RPC_CMD_PPORT_UPDATE)
		return -EPERM;
	if (OCTEP_RPC_BUF_DESC_SIZE + payload_len > OCTEP_RPC_DATA_MAX_SIZE)
		return -EMSGSIZE;

	posted = octep_rpc_readq(octep, OCTEP_RPC_STATE_RING_LO +
				 OCTEP_RPC_RING_POSTED);
	done = octep_rpc_readq(octep, OCTEP_RPC_STATE_RING_LO +
			       OCTEP_RPC_RING_DONE);
	if (posted != octep->rpc_posted || done != posted) {
		dev_err(&octep->pdev->dev,
			"rpc: low ring is not idle (host=%llu posted=%llu done=%llu)\n",
			(unsigned long long)octep->rpc_posted,
			(unsigned long long)posted, (unsigned long long)done);
		return -EBUSY;
	}

	memset(buffer, 0x5a, OCTEP_RPC_DATA_MAX_SIZE);
	buffer[0] = (OCTEP_RPC_DATA_MAX_SIZE - OCTEP_RPC_BUF_DESC_SIZE) & 0xff;
	buffer[1] = (OCTEP_RPC_DATA_MAX_SIZE - OCTEP_RPC_BUF_DESC_SIZE) >> 8;
	buffer[2] = 0;
	buffer[3] = command;
	memset(buffer + 4, 0, 4);
	memcpy(buffer + OCTEP_RPC_BUF_DESC_SIZE, payload, payload_len);
	dma_wmb();

	index = (u32)(posted & (octep->rpc_desc_count - 1));
	offset = octep->rpc_desc_off + index * OCTEP_RPC_BAR_DESC_SIZE;
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
	octep_rpc_writeq(octep, OCTEP_RPC_STATE_RING_LO +
			  OCTEP_RPC_RING_POSTED, posted + 1);
	wmb();
	octep->rpc_posted = posted + 1;
	octep->rpc_last_cmd = command;
	octep->rpc_last_rc = 0;
	octep->rpc_last_len = 0;
	octep->rpc_last_error = 0;
	err = octep_ring_dbell_locked(octep, facility->dbell_start);
	if (err)
		return err;

	for (i = 0; i < OCTEP_RPC_CMD_WAIT_MS; i++) {
		done = octep_rpc_readq(octep, OCTEP_RPC_STATE_RING_LO +
				       OCTEP_RPC_RING_DONE);
		if (done > posted)
			break;
		if (i < 2)
			usleep_range(20, 40);
		else
			msleep(1);
	}
	if (i == OCTEP_RPC_CMD_WAIT_MS) {
		octep->rpc_last_error = -ETIMEDOUT;
		octep->rpc_timeouts++;
		octep->rpc_ready = false;
		dev_err(&octep->pdev->dev,
			"rpc: command %u timed out; posted=%llu done=%llu\n",
			command, (unsigned long long)(posted + 1),
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
		return -EPROTO;
	}
	if (rc) {
		octep->rpc_last_error = -EREMOTEIO;
		dev_err(&octep->pdev->dev,
			"rpc: command %u refused with return code %#x\n",
			command, rc);
		return -EREMOTEIO;
	}
	dev_info(&octep->pdev->dev,
		 "rpc: command %u completed successfully (reply %u bytes)\n",
		 command, reply_len);
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
	octep->rpc_allow_write = value;
	mutex_unlock(&octep->lock);
	return count;
}
static DEVICE_ATTR_RW(rpc_allow_write);

static ssize_t rpc_lif_add_store(struct device *dev,
				 struct device_attribute *attr,
				 const char *buf, size_t count)
{
	struct octep *octep = dev_get_drvdata(dev);
	u8 payload[18] = {};
	u8 mac[ETH_ALEN];
	char mac_text[18];
	u32 iface, vlan;
	int err;

	if (sscanf(buf, "%u %u %17s", &iface, &vlan, mac_text) != 3 ||
	    !mac_pton(mac_text, mac) || !is_valid_ether_addr(mac))
		return -EINVAL;
	if (iface > 0x7f || vlan > 0xfff)
		return -ERANGE;

	payload[0] = ((iface << 12) | vlan) & 0xff;
	payload[1] = ((iface << 12) | vlan) >> 8;
	payload[2] = ((iface << 12) | vlan) >> 16;
	payload[3] = ((iface << 12) | vlan) >> 24;
	ether_addr_copy(payload + 4, mac);
	payload[10] = OCTEP_RPC_LIF_MTU & 0xff;
	payload[11] = OCTEP_RPC_LIF_MTU >> 8;
	payload[12] = OCTEP_RPC_LIF_FWD_L3;
	payload[14] = OCTEP_RPC_LIF_FP_PRIV_MASK_DF;
	payload[15] = 0;
	payload[16] = OCTEP_RPC_LIF_M_ALL & 0xff;
	payload[17] = OCTEP_RPC_LIF_M_ALL >> 8;

	mutex_lock(&octep->lock);
	err = octep_rpc_post_port_command_locked(octep,
						 OCTEP_RPC_CMD_LIF_ADD_UPDATE,
						 payload, sizeof(payload));
	mutex_unlock(&octep->lock);
	return err ? err : count;
}
static DEVICE_ATTR_WO(rpc_lif_add);

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
	err = octep_rpc_post_port_command_locked(octep,
						 OCTEP_RPC_CMD_PPORT_UPDATE,
						 payload, sizeof(payload));
	mutex_unlock(&octep->lock);
	return err ? err : count;
}
static DEVICE_ATTR_WO(rpc_pport_update);

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
			 "write_gate=%u\n",
			 octep->ready && facility->size != 0,
			 octep->rpc_ready, (unsigned long long)cfg,
			 (unsigned int)(cfg >> 56),
			 (unsigned long long)posted, (unsigned long long)done,
			 octep->rpc_desc_off, octep->rpc_desc_count,
			 octep->rpc_allow_write);
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
	for (i = 0; i < octep->nwa_last_words && len < PAGE_SIZE; i++)
		len += sysfs_emit_at(buf, len, "word%u=%#010x\n", i,
				     octep->nwa_last_reply[i]);
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
	&dev_attr_rpc_lif_add.attr,
	&dev_attr_rpc_pport_update.attr,
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

static int octep_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
	struct octep *octep;
	int err;

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
	INIT_DELAYED_WORK(&octep->mgmt_poll_work, octep_mgmt_poll_work);
	INIT_DELAYED_WORK(&octep->dp_poll_work, octep_dp_poll_work);

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

	WRITE_ONCE(octep->dp_poll_enabled, false);
	cancel_delayed_work_sync(&octep->dp_poll_work);
	octep_dp_netdev_unregister_all(octep);
	octep_mgmt_netdev_unregister(octep);
	mutex_lock(&octep->lock);
	if (octep->dp_up)
		octep_dp_stop_locked(octep, true);
	mutex_unlock(&octep->lock);
	if (octep->bar2)
		pci_iounmap(pdev, octep->bar2);
	if (octep->bar0)
		pci_iounmap(pdev, octep->bar0);
	pci_release_regions(pdev);
	pci_disable_device(pdev);
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
	.dev_groups = octep_groups,
};
module_pci_driver(octep_driver);

MODULE_DESCRIPTION("OCTEON TX CN83XX PCIe endpoint core");
MODULE_LICENSE("GPL");
