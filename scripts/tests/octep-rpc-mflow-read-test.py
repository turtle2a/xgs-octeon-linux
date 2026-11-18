#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
import pathlib
import subprocess
import tempfile

source = (pathlib.Path(__file__).resolve().parents[2] / "octep/octep.c").read_text()
start = source.index("static ssize_t rpc_mflow_read_show(")
end = source.index("\nstatic DEVICE_ATTR_RW(rpc_mflow_read);", start)
functions = source[start:end]

test = r"""
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

#define OCTEP_RPC_TBL_REQ_LEN 12
#define OCTEP_RPC_MFLOW_READ_REPLY_LEN 116
#define OCTEP_RPC_TABLE_FLAG_READ_ALL 2
#define OCTEP_RPC_CMD_LO_MFLOW_READ 40
#define OCTEP_RPC_BUF_DESC_SIZE 8
#define ETH_P_IP 0x0800
typedef uint8_t u8;
typedef uint32_t u32;
struct octep {
    int lock, rpc_last_len, rpc_last_error, result, calls;
    u32 rpc_mflow_read_index;
    u8 rpc_mflow_read_reply[OCTEP_RPC_MFLOW_READ_REPLY_LEN];
    int rpc_mflow_read_valid;
    struct { u8 *vaddr; } rpc_cmd;
    u8 buffer[OCTEP_RPC_BUF_DESC_SIZE + OCTEP_RPC_MFLOW_READ_REPLY_LEN];
    u8 request[OCTEP_RPC_TBL_REQ_LEN];
};
struct device { struct octep *data; };
struct device_attribute { int unused; };
#define dev_get_drvdata(dev) ((dev)->data)
#define mutex_lock(lock) ((void)0)
#define mutex_unlock(lock) ((void)0)
#define DEVICE_ATTR_RW(name)

static u32 get_unaligned_le32(const u8 *p) {
    return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24);
}
static unsigned int get_unaligned_be16(const u8 *p) {
    return ((unsigned int)p[0] << 8) | p[1];
}
static void put_unaligned_le32(u32 v, u8 *p) {
    p[0]=v; p[1]=v>>8; p[2]=v>>16; p[3]=v>>24;
}
static void put_unaligned_le16(u32 v, u8 *p) { p[0]=v; p[1]=v>>8; }
static int kstrtou32(const char *s, unsigned int base, u32 *out) {
    char *end; unsigned long value = strtoul(s, &end, base);
    while (*end == '\n' || *end == ' ' || *end == '\t') end++;
    if (*end || value > UINT32_MAX) return -EINVAL;
    *out = value; return 0;
}
static int emit_at(char *buf, size_t offset, const char *fmt, ...) {
    va_list ap; int n;
    va_start(ap, fmt); n=vsnprintf(buf+offset, 4096-offset, fmt, ap); va_end(ap);
    return n;
}
#define sysfs_emit(buf, ...) emit_at(buf, 0, __VA_ARGS__)
#define sysfs_emit_at(buf, offset, ...) emit_at(buf, offset, __VA_ARGS__)

static int octep_rpc_post_command_locked(struct octep *o, int cmd, u8 *p, int n) {
    o->calls++;
    if (cmd != OCTEP_RPC_CMD_LO_MFLOW_READ || n != OCTEP_RPC_TBL_REQ_LEN)
        return -EINVAL;
    memcpy(o->request, p, n);
    return o->result;
}
""" + functions + r"""
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"failed: %s\n",#x); return 1; } } while (0)
int main(void) {
    struct octep o = {0};
    struct device d = { &o };
    struct device_attribute a = {0};
    char out[4096];
    u8 *reply = o.buffer + OCTEP_RPC_BUF_DESC_SIZE;
    u8 *key = reply + 8;
    u8 *entry = reply + 72;
    u8 *operation = reply + 92;

    o.rpc_cmd.vaddr = o.buffer;
    put_unaligned_le32(7, reply);
    put_unaligned_le32(4096, key);
    key[16] = 8; key[17] = 0; key[18] = 4; key[19] = 6;
    key[20] = 0; key[21] = 80; key[22] = 0x12; key[23] = 0x34;
    key[24] = 192; key[25] = 0; key[26] = 2; key[27] = 1;
    key[28] = 198; key[29] = 51; key[30] = 100; key[31] = 2;
    put_unaligned_le32(0x00010102, entry + 12);
    put_unaligned_le32(0x20000000, operation);
    put_unaligned_le32(19, operation + 8);
    put_unaligned_le32(0x03000005, operation + 16);
    o.rpc_last_len = OCTEP_RPC_MFLOW_READ_REPLY_LEN;
    CHECK(rpc_mflow_read_store(&d, &a, "7\n", 2) == 2);
    CHECK(o.calls == 1 && o.rpc_mflow_read_valid && o.rpc_mflow_read_index == 7);
    CHECK(get_unaligned_le32(o.request) == 7);
    CHECK(o.request[4] == 1 && o.request[5] == 0);
    CHECK(o.request[6] == OCTEP_RPC_TABLE_FLAG_READ_ALL && o.request[7] == 0);
    CHECK(get_unaligned_le32(o.request + 8) == 7);
    CHECK(rpc_mflow_read_show(&d, &a, out) > 0);
    CHECK(strstr(out, "reply_index=7") != NULL);
    CHECK(strstr(out, "fw_valid=1 host_valid=0") != NULL);
    CHECK(strstr(out, "action=0 direction=0 bridge_control=0 state=2") != NULL);
    CHECK(strstr(out, "connection=19 next_hop=5 next_hop_revision=3") != NULL);
    CHECK(strstr(out, "key_lif=4096 key_ethertype=0x0800 key_family=4") != NULL);
    CHECK(strstr(out, "key_protocol=6 key_src_port=4660 key_dst_port=80") != NULL);
    CHECK(strstr(out, "key_src_ipv4=192.0.2.1 key_dst_ipv4=198.51.100.2") != NULL);
    CHECK(strstr(out, "raw=") != NULL);
    CHECK(rpc_mflow_read_store(&d, &a, "invalid", 7) == -EINVAL);
    CHECK(!o.rpc_mflow_read_valid);
    key[16] = 0x86; key[17] = 0xdd;
    CHECK(rpc_mflow_read_store(&d, &a, "7", 1) == 1);
    CHECK(rpc_mflow_read_show(&d, &a, out) > 0);
    CHECK(strstr(out, "key_ethertype=0x86dd") != NULL);
    CHECK(strstr(out, "key_src_ipv4=") == NULL);

    o.rpc_mflow_read_valid = 1;
    o.rpc_last_len = OCTEP_RPC_MFLOW_READ_REPLY_LEN - 1;
    CHECK(rpc_mflow_read_store(&d, &a, "7", 1) == -EPROTO);
    CHECK(!o.rpc_mflow_read_valid && o.rpc_last_error == -EPROTO);
    o.rpc_last_len = OCTEP_RPC_MFLOW_READ_REPLY_LEN;
    put_unaligned_le32(8, reply);
    CHECK(rpc_mflow_read_store(&d, &a, "7", 1) == -EPROTO);
    CHECK(o.rpc_last_error == -EPROTO);
    CHECK(rpc_mflow_read_store(&d, &a, "33554432", 8) == -ERANGE);
    o.result = -ETIMEDOUT;
    CHECK(rpc_mflow_read_store(&d, &a, "7", 1) == -ETIMEDOUT);
    puts("microflow read request, decoding and error handling: PASS");
    return 0;
}
"""

with tempfile.TemporaryDirectory() as directory:
    program = pathlib.Path(directory) / "test.c"
    binary = pathlib.Path(directory) / "test"
    program.write_text(test)
    subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
                    str(program), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
