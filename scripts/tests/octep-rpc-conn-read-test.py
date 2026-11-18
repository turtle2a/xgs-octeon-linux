#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
import pathlib
import subprocess
import tempfile

source = (pathlib.Path(__file__).resolve().parents[2] / "octep/octep.c").read_text()
start = source.index("static ssize_t rpc_conn_read_show(")
end = source.index("\nstatic DEVICE_ATTR_RW(rpc_conn_read);", start)

test = r"""
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
#define OCTEP_RPC_TBL_REQ_LEN 12
#define OCTEP_RPC_TABLE_FLAG_READ_ALL 2
#define OCTEP_RPC_CMD_LO_CONN_READ 38
#define OCTEP_RPC_BUF_DESC_SIZE 8
struct octep {
    int lock, rpc_platform_known, rpc_conn_read_valid;
    int rpc_last_error, result, calls;
    u32 rpc_platform_conn, rpc_conn_read_index;
    u16 rpc_conn_read_len, rpc_last_len;
    u8 rpc_conn_read_reply[256], buffer[264], request[12];
    struct { u8 *vaddr; } rpc_cmd;
};
struct device { struct octep *data; };
struct device_attribute { int unused; };
#define dev_get_drvdata(dev) ((dev)->data)
#define mutex_lock(lock) ((void)0)
#define mutex_unlock(lock) ((void)0)
static u32 get_unaligned_le32(const u8 *p) {
    return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24);
}
static void put_unaligned_le32(u32 v, u8 *p) {
    p[0]=v; p[1]=v>>8; p[2]=v>>16; p[3]=v>>24;
}
static void put_unaligned_le16(u32 v, u8 *p) { p[0]=v; p[1]=v>>8; }
static int kstrtou32(const char *s, unsigned int base, u32 *out) {
    char *end; unsigned long v = strtoul(s, &end, base);
    while (*end == '\n' || *end == ' ') end++;
    if (*end || v > UINT32_MAX) return -EINVAL;
    *out = v; return 0;
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
    if (cmd != OCTEP_RPC_CMD_LO_CONN_READ || n != 12) return -EINVAL;
    memcpy(o->request, p, n);
    return o->result;
}
""" + source[start:end] + r"""
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "failed: %s\n", #x); return 1; } } while (0)
int main(void) {
    struct octep o = { .rpc_platform_known=1, .rpc_platform_conn=100, .rpc_last_len=112 };
    struct device d = { &o };
    struct device_attribute a = {0};
    char out[4096];
    u8 *reply = o.buffer + OCTEP_RPC_BUF_DESC_SIZE;
    o.rpc_cmd.vaddr = o.buffer;
    put_unaligned_le32(7, reply);
    reply[4] = 0x42;
    CHECK(rpc_conn_read_store(&d, &a, "7\n", 2) == 2);
    CHECK(o.calls == 1 && o.rpc_conn_read_valid && o.rpc_conn_read_len == 112);
    CHECK(get_unaligned_le32(o.request) == 7 && get_unaligned_le32(o.request+8) == 7);
    CHECK(o.request[4] == 1 && o.request[5] == 0 && o.request[6] == 2 && o.request[7] == 0);
    CHECK(rpc_conn_read_show(&d, &a, out) > 0);
    CHECK(strstr(out, "requested_index=7 reply_index=7 reply_len=112 raw=07 00 00 00 42") != NULL);
    CHECK(rpc_conn_read_store(&d, &a, "invalid", 7) == -EINVAL);
    CHECK(!o.rpc_conn_read_valid);
    CHECK(rpc_conn_read_store(&d, &a, "7", 1) == 1);
    o.rpc_last_len = 11;
    CHECK(rpc_conn_read_store(&d, &a, "7", 1) == -EPROTO);
    CHECK(!o.rpc_conn_read_valid && o.rpc_last_error == -EPROTO);
    o.rpc_last_len = 257;
    CHECK(rpc_conn_read_store(&d, &a, "7", 1) == -EPROTO);
    o.rpc_last_len = 12;
    put_unaligned_le32(8, reply);
    CHECK(rpc_conn_read_store(&d, &a, "7", 1) == -EPROTO);
    CHECK(rpc_conn_read_store(&d, &a, "100", 3) == -ERANGE);
    o.rpc_platform_known = 0;
    CHECK(rpc_conn_read_store(&d, &a, "7", 1) == -EOPNOTSUPP);
    o.rpc_platform_known = 1; o.result = -ETIMEDOUT;
    CHECK(rpc_conn_read_store(&d, &a, "7", 1) == -ETIMEDOUT);
    CHECK(!o.rpc_conn_read_valid);
    puts("connection read request and error handling: PASS");
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
