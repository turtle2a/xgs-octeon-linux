#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Offline check: the C payload builders in octep/octep.c must emit the same
# bytes as scripts/octep/flow-build.py. Needs gcc and python3; touches no hardware.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

sed -n '/BEGIN flowbuild/,/END flowbuild/p' "$root/octep/octep.c" > "$work/body.h"
cat > "$work/main.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdbool.h>
#include <arpa/inet.h>
typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32;
typedef uint16_t __le16, __be16; typedef uint32_t __le32, __be32;
#define __packed __attribute__((packed))
#define static_assert _Static_assert
#define cpu_to_le32(x) ((uint32_t)(x))
#define cpu_to_le16(x) ((uint16_t)(x))
#define BIT(n) (1U << (n))
#define ETH_ALEN 6
#define ETH_P_IP 0x0800
#define OCTEP_RPC_NHOP_REQ_LEN 32
#define OCTEP_RPC_MFLOW_REQ_LEN 32
#define OCTEP_RPC_FLOW_REQ_LEN 180
#include "body.h"

static void dump(const void *p, size_t n)
{
	const unsigned char *b = p;
	while (n--)
		printf("%02x", *b++);
	printf("\n");
}

int main(void)
{
	static const u8 dst[6] = {0x68, 0x05, 0xca, 0x97, 0xc8, 0xb0};
	static const u8 src[6] = {0x7c, 0x5a, 0x1c, 0xc6, 0x54, 0x6c};
	struct octep_rpc_nhop_payload nh;
	struct octep_rpc_mflow_payload o, r;
	struct octep_rpc_flow_create_payload f;
	struct octep_ft_nat nat = {0};

	octep_ft_fill_nhop(&nh, 100, 0, dst, src, 3, 0x8200, 1500);
	dump(&nh, sizeof(nh));
	octep_ft_fill_mflow(&o, 618, 5, 0, 10000, 1, 7, 0, 100, 0, 244141);
	octep_ft_fill_mflow(&r, 355, 3, 1, 10000, 1, 7, 0, 101, 0, 244141);
	octep_ft_fill_flow(&f, 10000, 1, &o, &r, NULL);
	dump(&f, sizeof(f));
	inet_pton(AF_INET, "10.1.1.10", &nat.orig_src);
	inet_pton(AF_INET, "192.168.1.1", &nat.orig_dst);
	inet_pton(AF_INET, "192.168.1.14", &nat.nat_src);
	inet_pton(AF_INET, "192.168.1.1", &nat.nat_dst);
	nat.orig_dst_port = htons(5201); nat.orig_src_port = htons(46498);
	nat.nat_dst_port = htons(5201); nat.nat_src_port = htons(46498);
	nat.snat = true;
	octep_ft_fill_flow(&f, 10000, 1, &o, &r, &nat);
	dump(&f, sizeof(f));
	octep_ft_fill_mflow_clear(&o, 618, 5, 10000, 1, 7, 0, 100);
	dump(&o, sizeof(o));
	return 0;
}
EOF
gcc -Wall -Werror -I"$work" -o "$work/chk" "$work/main.c"
"$work/chk" > "$work/c.out"

python3 - "$root" "$work/c.out" <<'EOF'
import importlib.util, sys
root, cout = sys.argv[1:]
spec = importlib.util.spec_from_file_location("fb", f"{root}/scripts/octep/flow-build.py")
fb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fb)
dst, src = "02:00:00:00:00:00", "02:00:00:00:01:0X"
base = {"conn_idx": 10000, "conn_rev": 1, "fw_rev": 7, "l3_rev": 0,
        "orig": {"id": 618, "rev": 5, "nhop": {"index": 100, "rev": 0}},
        "reply": {"id": 355, "rev": 3, "nhop": {"index": 101, "rev": 0}}}
nat = {"orig_src": "10.1.1.10", "orig_dst": "192.168.1.1", "nat_src": "192.168.1.14",
       "nat_dst": "192.168.1.1", "orig_dst_port": 5201, "orig_src_port": 46498,
       "nat_dst_port": 5201, "nat_src_port": 46498, "snat": 1, "dnat": 0}
want = [fb.nhop(100, 0, dst, src, 3, 0x8200, 1500).hex(),
        fb.flow_create(base).hex(),
        fb.flow_create(dict(base, nat=nat)).hex(),
        fb.mflow_clear(dict(base, orig=dict(base["orig"], id=618, rev=5)), "orig").hex()]
got = open(cout).read().split()
bad = [n for n, (a, b) in enumerate(zip(want, got)) if a != b]
print("flowbuild C vs Python:", "PASS 4/4" if not bad and len(got) == 4 else f"FAIL {bad}")
sys.exit(1 if bad or len(got) != 4 else 0)
EOF
