#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
import pathlib
import subprocess
import tempfile

source = (pathlib.Path(__file__).resolve().parents[2] / "octep/octep.c").read_text()
start = source.index("static ssize_t rpc_sys_counters_show(")
end = source.index("\nstatic DEVICE_ATTR_RO(rpc_sys_counters);", start)
function = source[start:end]

test = r"""
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <sys/types.h>
#define OCTEP_RPC_TBL_REQ_LEN 12
#define OCTEP_RPC_SYS_COUNTER_COUNT 128
#define OCTEP_RPC_CMD_LO_WORKER_SYS_CNT_READ 44
#define OCTEP_RPC_BUF_DESC_SIZE 8
typedef uint8_t u8;
typedef uint64_t u64;
struct octep {
    int lock, rpc_last_len, rpc_last_error, rpc_cmd_shift, result, calls;
    struct { void *vaddr; } rpc_cmd;
};
struct device { struct octep *data; };
struct device_attribute { int unused; };
#define dev_get_drvdata(dev) ((dev)->data)
#define mutex_lock(lock) ((void)0)
#define mutex_unlock(lock) ((void)0)
static void put_unaligned_le16(unsigned int v, u8 *p) { p[0]=v; p[1]=v>>8; }
static void put_unaligned_le32(unsigned int v, u8 *p) {
    for (int i=0; i<4; i++) p[i]=v>>(i*8);
}
static u64 get_unaligned_le64(const u8 *p) {
    u64 v=0;
    for (int i=7; i>=0; i--) v=(v<<8)|p[i];
    return v;
}
static int emit(char *buf, const char *fmt, ...) {
    va_list ap; int n;
    va_start(ap, fmt); n=vsnprintf(buf, 4096, fmt, ap); va_end(ap);
    return n;
}
#define sysfs_emit(buf, ...) emit(buf, __VA_ARGS__)
#define sysfs_emit_at(buf, pos, ...) emit((buf)+(pos), __VA_ARGS__)
static int octep_rpc_post_command_locked(struct octep *o, int cmd, u8 *p, int n) {
    static const u8 expected[12] = {0,0,0,0,128,0,0,0,127,0,0,0};
    o->calls++;
    if (cmd!=44 || n!=12 || memcmp(p,expected,12)) return -EINVAL;
    return o->result;
}
""" + function + r"""
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"failed: %s\n",#x); return 1; } } while (0)
int main(void) {
    u8 reply[8 + 128*8]; char out[4096];
    struct octep o = { .rpc_last_len=1024, .rpc_cmd_shift=1, .rpc_cmd={reply} };
    struct device d = { &o };
    struct device_attribute a;
    memset(reply, 0xff, sizeof(reply));
    ssize_t n=rpc_sys_counters_show(&d,&a,out);
    CHECK(n>0 && n<4096 && o.calls==1);
    CHECK(strstr(out,"count=128 command_shift=1\n") == out);
    CHECK(strstr(out,"0=18446744073709551615\n"));
    CHECK(strstr(out,"127=18446744073709551615\n"));
    o.rpc_last_len=1016;
    CHECK(rpc_sys_counters_show(&d,&a,out)==-EPROTO && o.rpc_last_error==-EPROTO);
    o.result=-ETIMEDOUT;
    CHECK(rpc_sys_counters_show(&d,&a,out)==-ETIMEDOUT);
    puts("system counter request, decoding and error handling: PASS");
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
