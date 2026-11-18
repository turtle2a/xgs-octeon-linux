#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
import pathlib
import subprocess
import tempfile

source = (pathlib.Path(__file__).resolve().parents[2] / "octep/octep.c").read_text()
start = source.index("static int octep_rpc_read_connection_locked(")
end = source.index("\nstatic DEVICE_ATTR_WO(rpc_flow_write);", start)
functions = source[start:end]

test = r"""
#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <stdbool.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
#define GFP_KERNEL 0
#define OCTEP_RPC_TBL_REQ_LEN 12
#define OCTEP_RPC_TABLE_FLAG_READ_ALL 2
#define OCTEP_RPC_CMD_LO_MFLOW_READ 40
#define OCTEP_RPC_CMD_LO_CONN_READ 38
#define OCTEP_RPC_CMD_NHOP_PROGRAM 6
#define OCTEP_RPC_CMD_MFLOW_PROGRAM 8
#define OCTEP_RPC_CMD_FLOW_CREATE_FP 10
#define OCTEP_RPC_NHOP_REQ_LEN 32
#define OCTEP_RPC_MFLOW_REQ_LEN 32
#define OCTEP_RPC_FLOW_REQ_LEN 180
#define OCTEP_RPC_MFLOW_READ_REPLY_LEN 116
#define OCTEP_RPC_BUF_DESC_SIZE 8
#define OCTEP_RPC_FLOW_OFF_MFLOW_O 116
#define OCTEP_RPC_FLOW_OFF_MFLOW_R 148
#define BIT(n) (1U << (n))
#define GENMASK(h, l) ((UINT32_MAX >> (31 - (h))) & (UINT32_MAX << (l)))
struct pci_dev { int dev; };
struct octep {
    int lock, rpc_allow_write, rpc_last_len, rpc_last_error;
    int reads, writes, validation_error, transport_error, short_reply, wrong_index;
    int bad_operation_offset;
    int conn_reads, conn_len, conn_wrong_index, conn_bad_offset, conn_error;
    u32 invalid_index, stale_index, bad_post_index, bad_operation_index;
    struct pci_dev *pdev;
    u8 programmed[2][32];
    u8 conn_entry[108];
    u8 buffer[8 + 116];
    struct { u8 *vaddr; } rpc_cmd;
};
struct device { struct octep *data; };
struct device_attribute { int unused; };
#define dev_get_drvdata(dev) ((dev)->data)
#define mutex_lock(lock) ((void)0)
#define mutex_unlock(lock) ((void)0)
#define dev_warn(dev, ...) ((void)(dev))
#define kfree(p) free(p)
static char *kstrndup(const char *s, size_t n, int flags) {
    (void)flags; return strndup(s, n);
}
static char *strim(char *s) {
    char *end;
    while (isspace((unsigned char)*s)) s++;
    end = s + strlen(s);
    while (end > s && isspace((unsigned char)end[-1])) *--end = 0;
    return s;
}
static int kstrtou32(const char *s, unsigned int base, u32 *out) {
    char *end;
    unsigned long v = strtoul(s, &end, base);
    if (*end || v > UINT32_MAX) return -EINVAL;
    *out = v; return 0;
}
static int hex2bin(u8 *out, const char *s, size_t len) {
    size_t i;
    for (i = 0; i < len; i++) {
        unsigned int v;
        if (sscanf(s + i * 2, "%2x", &v) != 1) return -EINVAL;
        out[i] = v;
    }
    return 0;
}
static u32 get_unaligned_le32(const u8 *p) {
    return (u32)p[0] | ((u32)p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24);
}
static u16 get_unaligned_le16(const u8 *p) {
    return (u16)p[0] | ((u16)p[1] << 8);
}
static void put_unaligned_le32(u32 v, u8 *p) {
    p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24;
}
static void put_unaligned_le16(u32 v, u8 *p) { p[0] = v; p[1] = v >> 8; }
static int octep_rpc_validate_flow_command(struct octep *o, u8 cmd, const u8 *p, u16 len) {
    (void)cmd; (void)p; (void)len; return o->validation_error;
}
static int octep_rpc_post_command_locked(struct octep *o, u8 cmd, const u8 *p, u16 len) {
    u8 *reply = o->buffer + 8;
    u32 index;
    if (cmd == OCTEP_RPC_CMD_LO_CONN_READ) {
        int header = o->conn_len == 116 ? 8 : 4;
        o->conn_reads++;
        if (len != 12 || p[4] != 1 || p[5] != 0 || p[6] != 2 || p[7] != 0 ||
            get_unaligned_le32(p) != get_unaligned_le32(p + 8)) return -EINVAL;
        if (o->conn_error) return o->conn_error;
        memset(reply, 0, 116);
        put_unaligned_le32(get_unaligned_le32(p) + !!o->conn_wrong_index, reply);
        memcpy(reply + header, o->conn_entry, sizeof(o->conn_entry));
        if (o->conn_bad_offset >= 0)
            reply[header + o->conn_bad_offset] ^= 1;
        o->rpc_last_len = o->conn_len ? o->conn_len : 112;
        return 0;
    }
    if (cmd != OCTEP_RPC_CMD_LO_MFLOW_READ) {
        o->writes++;
        if (cmd == OCTEP_RPC_CMD_MFLOW_PROGRAM)
            memcpy(o->programmed[get_unaligned_le32(p) % 2], p, 32);
        else if (cmd == OCTEP_RPC_CMD_FLOW_CREATE_FP) {
            memcpy(o->programmed[get_unaligned_le32(p + 116) % 2], p + 116, 32);
            memcpy(o->programmed[get_unaligned_le32(p + 148) % 2], p + 148, 32);
            memcpy(o->conn_entry, p + 4, sizeof(o->conn_entry));
        }
        return 0;
    }
    o->reads++;
    if (len != 12 || p[4] != 1 || p[5] != 0 || p[6] != 2 || p[7] != 0 ||
        get_unaligned_le32(p) != get_unaligned_le32(p + 8)) return -EINVAL;
    if (o->transport_error) return o->transport_error;
    index = get_unaligned_le32(p);
    memset(reply, 0, 116);
    put_unaligned_le32(index + !!o->wrong_index, reply);
    put_unaligned_le32((index == o->invalid_index ? 0 : 0x10000) |
                       ((index == o->stale_index ? 4 : 3) << 8) |
                       ((get_unaligned_le32(o->programmed[index % 2]) & 0x1ffffff) == index &&
                        index != o->bad_post_index ? 0x1000000 : 0), reply + 84);
    if ((get_unaligned_le32(o->programmed[index % 2]) & 0x1ffffff) == index)
        memcpy(reply + 92, o->programmed[index % 2] + 4, 20);
    if (index == o->bad_operation_index)
        reply[92 + o->bad_operation_offset] ^= 1;
    o->rpc_last_len = o->short_reply ? 115 : 116;
    return 0;
}
""" + functions + r"""
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "failed: %s\n", #x); return 1; } } while (0)
static void make_command(char *command, unsigned int cmd, u8 *payload, size_t n) {
    size_t i;
    int offset = sprintf(command, "%u ", cmd);
    for (i = 0; i < n; i++) sprintf(command + offset + i * 2, "%02x", payload[i]);
}
int main(void) {
    struct pci_dev pdev = {0};
    struct octep o = { .rpc_allow_write = 1, .pdev = &pdev, .conn_bad_offset = -1 };
    struct device d = { &o };
    struct device_attribute a = {0};
    u8 payload[180] = {0};
    char command[400];
    ssize_t n;
    o.rpc_cmd.vaddr = o.buffer;
    put_unaligned_le32(0x86000007, payload + 116);
    put_unaligned_le32(0x86000008, payload + 148);
    make_command(command, 10, payload, sizeof(payload));
    n = strlen(command);
    CHECK(rpc_flow_write_store(&d, &a, command, n) == n);
    CHECK(o.reads == 4 && o.writes == 1);
    o.invalid_index = 8;
    CHECK(rpc_flow_write_store(&d, &a, command, n) == -EAGAIN);
    CHECK(o.reads == 6 && o.writes == 1);
    o.invalid_index = 0; o.stale_index = 7;
    CHECK(rpc_flow_write_store(&d, &a, command, n) == -ESTALE);
    CHECK(o.reads == 7 && o.writes == 1);
    o.stale_index = 0; o.short_reply = 1;
    CHECK(rpc_flow_write_store(&d, &a, command, n) == -EPROTO);
    CHECK(o.rpc_last_error == -EPROTO && o.writes == 1);
    o.short_reply = 0; o.wrong_index = 1;
    CHECK(rpc_flow_write_store(&d, &a, command, n) == -EPROTO);
    CHECK(o.writes == 1);
    o.wrong_index = 0; o.transport_error = -ETIMEDOUT;
    CHECK(rpc_flow_write_store(&d, &a, command, n) == -ETIMEDOUT);
    CHECK(o.writes == 1);
    o.transport_error = 0; o.rpc_allow_write = 0;
    { int reads = o.reads;
      CHECK(rpc_flow_write_store(&d, &a, command, n) == -EPERM);
      CHECK(o.reads == reads && o.writes == 1); }
    o.rpc_allow_write = 1; o.validation_error = -EINVAL;
    { int reads = o.reads;
      CHECK(rpc_flow_write_store(&d, &a, command, n) == -EINVAL);
      CHECK(o.reads == reads && o.writes == 1); }
    o.validation_error = 0;
    o.bad_post_index = 8;
    CHECK(rpc_flow_write_store(&d, &a, command, n) == -EIO);
    CHECK(o.writes == 2);
    o.bad_post_index = 0;
    {
      int offsets[] = {0, 2, 3, 4, 8, 12, 16, 20};
      size_t i;
      o.bad_operation_index = 7;
      for (i = 0; i < sizeof(offsets) / sizeof(offsets[0]); i++) {
          o.bad_operation_offset = offsets[i];
          CHECK(rpc_flow_write_store(&d, &a, command, n) == -EIO);
      }
      CHECK(o.writes == 10);
    }
    o.bad_operation_index = 0;
    memset(payload, 0, sizeof(payload));
    put_unaligned_le32(0x86000007, payload);
    make_command(command, 8, payload, 32);
    n = strlen(command);
    o.stale_index = 7;
    CHECK(rpc_flow_write_store(&d, &a, command, n) == -ESTALE);
    CHECK(o.writes == 10);
    o.stale_index = 0;
    CHECK(rpc_flow_write_store(&d, &a, command, n) == n);
    CHECK(o.writes == 11);
    make_command(command, 6, payload, 32);
    n = strlen(command);
    { int reads = o.reads;
      CHECK(rpc_flow_write_store(&d, &a, command, n) == n);
      CHECK(o.reads == reads && o.writes == 12); }
    memset(payload, 0, sizeof(payload));
    put_unaligned_le32(15, payload);
    put_unaligned_le32(0x40580003, payload + 4);
    put_unaligned_le32(15, payload + 12);
    payload[84] = 192; payload[107] = 42;
    put_unaligned_le32(0x86000007, payload + 116);
    put_unaligned_le32(0x86000008, payload + 148);
    make_command(command, 10, payload, sizeof(payload));
    n = strlen(command);
    o.conn_len = 116;
    CHECK(rpc_flow_write_store(&d, &a, command, n) == n);
    o.conn_len = 112;
    CHECK(rpc_flow_write_store(&d, &a, command, n) == n);
    o.conn_bad_offset = 0;
    CHECK(rpc_flow_write_store(&d, &a, command, n) == -EIO);
    o.conn_bad_offset = 8;
    CHECK(rpc_flow_write_store(&d, &a, command, n) == -EIO);
    o.conn_bad_offset = 80;
    CHECK(rpc_flow_write_store(&d, &a, command, n) == -EIO);
    o.conn_bad_offset = -1;
    o.conn_wrong_index = 1;
    CHECK(rpc_flow_write_store(&d, &a, command, n) == -EPROTO);
    o.conn_wrong_index = 0; o.conn_len = 111;
    CHECK(rpc_flow_write_store(&d, &a, command, n) == -EPROTO);
    o.conn_len = 112; o.conn_error = -ETIMEDOUT;
    CHECK(rpc_flow_write_store(&d, &a, command, n) == -ETIMEDOUT);
    CHECK(o.conn_reads == 9);
    puts("flow programming candidate preflight and failures: PASS");
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
