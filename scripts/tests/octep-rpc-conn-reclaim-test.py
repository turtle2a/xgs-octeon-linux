#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
import pathlib
import subprocess
import tempfile

source = (pathlib.Path(__file__).resolve().parents[2] / "octep/octep.c").read_text()
read_start = source.index("static int octep_rpc_read_connection_locked(")
read_end = source.index("\nstatic int octep_rpc_check_mflow_candidate_locked(", read_start)
reclaim_start = source.index("static ssize_t rpc_conn_reclaim_show(")
reclaim_end = source.index("\nstatic DEVICE_ATTR(rpc_conn_reclaim,", reclaim_start)

test = r"""
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <sys/types.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
#define U16_MAX UINT16_MAX
#define OCTEP_RPC_TBL_REQ_LEN 12
#define OCTEP_RPC_TABLE_FLAG_READ_ALL 2
#define OCTEP_RPC_CMD_LO_CONN_READ 38
#define OCTEP_RPC_CMD_CONN_RECLAIM_FP 16
#define OCTEP_RPC_BUF_DESC_SIZE 8
#define OCTEP_RPC_CONN_RECLAIM_REQ_LEN 8
#define OCTEP_RPC_CONN_RECLAIM_REPLY_LEN 64
#define OCTEP_RPC_CONN_STATE_VALID 1
#define OCTEP_RPC_CONN_STATE_RECLAIM_PENDING 2
#define OCTEP_RPC_CONN_STATE_RECLAIMED 3
struct pci_dev { int dev; };
struct octep {
    int lock, rpc_allow_write, rpc_platform_known, rpc_last_len, rpc_last_error;
    int reads, writes, read_error, reclaim_error, bad_index, short_read, short_reply, no_transition;
    u32 rpc_platform_conn, index, flags;
    u32 rpc_conn_reclaim_index;
    u16 rpc_conn_reclaim_revision;
    bool rpc_conn_reclaim_valid, rpc_conn_reclaim_verified;
    u8 rpc_conn_reclaim_reply[64];
    struct pci_dev *pdev;
    u8 buffer[124];
    struct { u8 *vaddr; } rpc_cmd;
};
struct device { struct octep *data; };
struct device_attribute { int unused; };
#define dev_get_drvdata(dev) ((dev)->data)
#define mutex_lock(lock) ((void)0)
#define mutex_unlock(lock) ((void)0)
#define dev_warn(dev, ...) ((void)(dev))
static int emit_at(char *buf, size_t offset, const char *fmt, ...) {
    va_list ap; int n;
    va_start(ap, fmt); n=vsnprintf(buf+offset, 4096-offset, fmt, ap); va_end(ap);
    return n;
}
#define sysfs_emit(buf, ...) emit_at(buf, 0, __VA_ARGS__)
#define sysfs_emit_at(buf, offset, ...) emit_at(buf, offset, __VA_ARGS__)
static u32 get_unaligned_le32(const u8 *p) {
    return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24);
}
static void put_unaligned_le32(u32 v, u8 *p) {
    p[0]=v; p[1]=v>>8; p[2]=v>>16; p[3]=v>>24;
}
static void put_unaligned_le16(u32 v, u8 *p) { p[0]=v; p[1]=v>>8; }
static int octep_rpc_post_command_locked(struct octep *o, int cmd, const u8 *p, int n) {
    u8 *reply = o->buffer + 8;
    if (cmd == OCTEP_RPC_CMD_LO_CONN_READ) {
        o->reads++;
        if (n != 12 || get_unaligned_le32(p) != o->index || p[4] != 1 ||
            p[5] != 0 || p[6] != 2 || p[7] != 0 ||
            get_unaligned_le32(p+8) != o->index) return -EINVAL;
        if (o->read_error) return o->read_error;
        memset(reply, 0, 116);
        put_unaligned_le32(o->index + !!o->bad_index, reply);
        put_unaligned_le32(o->flags, reply + 8);
        o->rpc_last_len = o->short_read ? 111 : 116;
        return 0;
    }
    if (cmd != OCTEP_RPC_CMD_CONN_RECLAIM_FP || n != 8 ||
        get_unaligned_le32(p) != o->index ||
        (p[4] | ((u32)p[5] << 8)) != (o->flags & 0xffff) ||
        p[6] || p[7]) return -EINVAL;
    o->writes++;
    if (o->reclaim_error) return o->reclaim_error;
    if (!o->no_transition) o->flags = (o->flags & 0x3fffffff) | (3U << 30);
    memset(reply, 0xa5, 64);
    o->rpc_last_len = o->short_reply ? 63 : 64;
    return 0;
}
""" + source[read_start:read_end] + source[reclaim_start:reclaim_end] + r"""
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "line %d: %s\n", __LINE__, #x); return 1; } } while (0)
int main(void) {
    struct pci_dev pdev = {0};
    struct octep o = { .rpc_allow_write=1, .rpc_platform_known=1,
        .rpc_platform_conn=100, .index=15, .flags=(1U<<30)|3, .pdev=&pdev };
    struct device d = { &o };
    struct device_attribute a = {0};
    char out[4096];
    o.rpc_cmd.vaddr = o.buffer;
    CHECK(rpc_conn_reclaim_store(&d, &a, "15 3\n", 5) == 5);
    CHECK(o.reads == 2 && o.writes == 1 && (o.flags >> 30) == 3);
    CHECK(o.rpc_conn_reclaim_valid && o.rpc_conn_reclaim_verified);
    CHECK(rpc_conn_reclaim_show(&d, &a, out) > 0);
    CHECK(strstr(out, "index=15 revision=3 verified=1 raw=a5 a5") != NULL);
    CHECK(rpc_conn_reclaim_store(&d, &a, "invalid", 7) == -EINVAL);
    CHECK(!o.rpc_conn_reclaim_valid && !o.rpc_conn_reclaim_verified);
    CHECK(rpc_conn_reclaim_store(&d, &a, "15 3", 4) == -EALREADY);
    o.flags=(2U<<30)|3;
    CHECK(rpc_conn_reclaim_store(&d, &a, "15 3", 4) == 4);
    o.flags=(1U<<30)|4;
    CHECK(rpc_conn_reclaim_store(&d, &a, "15 3", 4) == -ESTALE);
    CHECK(o.writes == 2);
    o.rpc_allow_write=0;
    CHECK(rpc_conn_reclaim_store(&d, &a, "15 3", 4) == -EPERM);
    o.rpc_allow_write=1; o.rpc_platform_known=0;
    CHECK(rpc_conn_reclaim_store(&d, &a, "15 3", 4) == -EOPNOTSUPP);
    o.rpc_platform_known=1;
    CHECK(rpc_conn_reclaim_store(&d, &a, "100 3", 5) == -ERANGE);
    CHECK(rpc_conn_reclaim_store(&d, &a, "1 3", 3) == -ERANGE);
    CHECK(rpc_conn_reclaim_store(&d, &a, "15 65536", 8) == -ERANGE);
    CHECK(rpc_conn_reclaim_store(&d, &a, "15 3 x", 6) == -EINVAL);
    o.flags=(1U<<30)|3; o.bad_index=1;
    CHECK(rpc_conn_reclaim_store(&d, &a, "15 3", 4) == -EPROTO);
    o.bad_index=0; o.short_read=1;
    CHECK(rpc_conn_reclaim_store(&d, &a, "15 3", 4) == -EPROTO);
    o.short_read=0; o.read_error=-ETIMEDOUT;
    CHECK(rpc_conn_reclaim_store(&d, &a, "15 3", 4) == -ETIMEDOUT);
    o.read_error=0; o.reclaim_error=-ETIMEDOUT;
    CHECK(rpc_conn_reclaim_store(&d, &a, "15 3", 4) == -ETIMEDOUT);
    o.reclaim_error=0; o.no_transition=1;
    CHECK(rpc_conn_reclaim_store(&d, &a, "15 3", 4) == -EIO);
    CHECK(o.rpc_conn_reclaim_valid && !o.rpc_conn_reclaim_verified);
    o.no_transition=0; o.short_reply=1;
    CHECK(rpc_conn_reclaim_store(&d, &a, "15 3", 4) == -EPROTO);
    CHECK(!o.rpc_conn_reclaim_valid);
    puts("connection reclaim gating, revision and verification: PASS");
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
