#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
import pathlib
import subprocess
import tempfile

source = (pathlib.Path(__file__).resolve().parents[2] / "octep/octep.c").read_text()
track = source[source.index("struct octep_rx_flow_track {"):
               source.index("\nstruct octep {")]
functions = source[source.index("static bool octep_dp_rx_flow_tuple("):
                   source.index("\nstatic bool octep_dp_copy_frame(")]

test = r"""
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/if_ether.h>
#include <netinet/in.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
#define U64_MAX UINT64_MAX
#define VLAN_HLEN 4
#define VLAN_VID_MASK 0x0fff
#define OCTEP_DP_IPV4_FRAGMENT_MASK 0x3fffU
#define OCTEP_DP_RX_META_OFF 18
#define OCTEP_DP_RX_META_SIG 0xb44399a2U
#define OCTEP_DP_RX_META_VALID_SHIFT 8
#define OCTEP_DP_RX_FLOW_OFF (OCTEP_DP_RX_META_OFF + 8)
#define OCTEP_DP_RX_FLOW_ID_MASK 0x01ffffffU
#define OCTEP_DP_RX_FLOW_REV_MASK 0x7e000000U
#define OCTEP_DP_RX_FLOW_VALID 0x80000000U
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
""" + track + r"""
struct octep {
    int flow_stats_lock;
    u64 rx_meta_frames, rx_meta_signature_matches, rx_meta_valid_frames;
    u64 rx_flow_valid_frames, rx_flow_track_sequence;
    u32 rx_flow_last_id, rx_flow_last_valid_id;
    u16 rx_flow_last_tag, rx_flow_last_valid_tag;
    u8 rx_flow_last_revision, rx_flow_last_valid_revision, rx_flow_last_md_valid;
    bool rx_flow_last_signature, rx_flow_last_valid;
    unsigned long rx_flow_last_jiffies, rx_flow_last_valid_jiffies;
    struct octep_rx_flow_track rx_flow_tracks[4];
};
static unsigned long jiffies = 1;
#define spin_lock_irqsave(lock, flags) do { (void)(lock); (flags) = 0; } while (0)
#define spin_unlock_irqrestore(lock, flags) do { (void)(lock); (void)(flags); } while (0)
static u16 get_unaligned_be16(const u8 *p) { return ((u16)p[0] << 8) | p[1]; }
static u32 get_unaligned_le32(const u8 *p) {
    return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24);
}
static void put_le32(u32 v, u8 *p) {
    p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24;
}
static bool ether_addr_equal(const u8 *a, const u8 *b) {
    return memcmp(a, b, ETH_ALEN) == 0;
}
""" + functions + r"""
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "failed: %s\n", #x); return 1; } } while (0)
int main(void) {
    struct octep o = {0};
    u8 prefix[32] = {0};
    u8 frame[60] = {0};
    struct octep_rx_flow_track *t = &o.rx_flow_tracks[0];
    put_le32(OCTEP_DP_RX_META_SIG, prefix + OCTEP_DP_RX_META_OFF);
    put_le32(0x100, prefix + OCTEP_DP_RX_META_OFF + 4);
    put_le32(OCTEP_DP_RX_FLOW_VALID | 7, prefix + OCTEP_DP_RX_FLOW_OFF);
    frame[12] = 0x08; frame[13] = 0x00;
    frame[14] = 0x45; frame[16] = 0; frame[17] = 24;
    frame[23] = IPPROTO_TCP;
    frame[26] = 192; frame[29] = 1;
    frame[30] = 198; frame[33] = 2;
    frame[34] = 0x12; frame[35] = 0x34;
    frame[36] = 0x00; frame[37] = 0x50;
    octep_dp_rx_flow_metadata(&o, prefix, 1, frame, sizeof(frame));
    CHECK(t->used && t->tuple_valid && t->id == 7 && t->src_port == 0x1234);
    CHECK(t->dst_port == 80 && t->frames == 1);
    octep_dp_rx_flow_metadata(&o, prefix, 1, frame, 20);
    CHECK(!t->tuple_valid && t->src_port == 0 && t->frames == 1);
    octep_dp_rx_flow_metadata(&o, prefix, 1, frame, sizeof(frame));
    CHECK(t->tuple_valid && t->src_port == 0x1234 && t->frames == 1);
    frame[20] = 0x20;
    octep_dp_rx_flow_metadata(&o, prefix, 1, frame, sizeof(frame));
    CHECK(!t->tuple_valid && t->frames == 1);
    frame[20] = 0; frame[17] = 22;
    octep_dp_rx_flow_metadata(&o, prefix, 1, frame, sizeof(frame));
    CHECK(!t->tuple_valid);
    frame[17] = 24;
    octep_dp_rx_flow_metadata(&o, prefix, 1, frame, sizeof(frame));
    CHECK(t->tuple_valid && t->frames == 1);
    octep_dp_rx_flow_metadata(&o, prefix, 1, frame, sizeof(frame));
    CHECK(t->tuple_valid && t->frames == 2);
    {
        u8 v6[80] = {0};
        v6[12] = 0x86; v6[13] = 0xdd; v6[14] = 0x60;
        v6[18] = 0; v6[19] = 4;
        v6[20] = IPPROTO_UDP;
        v6[54] = 0x12; v6[55] = 0x34; v6[56] = 0; v6[57] = 0x35;
        octep_dp_rx_flow_metadata(&o, prefix, 1, v6, sizeof(v6));
        CHECK(t->tuple_valid && t->family == 6 && t->src_port == 0x1234);
        v6[19] = 3;
        octep_dp_rx_flow_metadata(&o, prefix, 1, v6, sizeof(v6));
        CHECK(!t->tuple_valid && t->src_port == 0);
        v6[19] = 27;
        octep_dp_rx_flow_metadata(&o, prefix, 1, v6, sizeof(v6));
        CHECK(!t->tuple_valid);
        v6[19] = 4;
        octep_dp_rx_flow_metadata(&o, prefix, 1, v6, sizeof(v6));
        CHECK(t->tuple_valid && t->dst_port == 53);
    }
    puts("candidate parsing and stale tuple invalidation: PASS");
    return 0;
}
"""

with tempfile.TemporaryDirectory() as directory:
    program = pathlib.Path(directory) / "test.c"
    binary = pathlib.Path(directory) / "test"
    program.write_text(test)
    subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", str(program),
                    "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
