#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Build NHOP_PROGRAM and FLOW_CREATE_FP payloads for rpc_flow_write.

Output only: nothing is sent. Each line is "<command> <hex>", the format the
driver's rpc_flow_write attribute accepts. Microflow identities must come from
the firmware's RX candidates; they are never computed here.
"""

import argparse
import json
import socket
import struct
import sys

CMD_NHOP, CMD_FLOW_CREATE = 6, 10
ACTION_FWD, STATE_ACTIVE, CONN_STATE_VALID = 1, 2, 1
FLOW_VALID_BOTH = 3
CONN_VERDICT_BIT = 21


def mac(text):
    raw = bytes.fromhex(text.replace(":", ""))
    if len(raw) != 6:
        raise ValueError(f"bad MAC {text!r}")
    return raw


def nhop(index, revision, dst, src, iface, tag, mtu, ethertype=0x0800):
    if index < 2:
        raise ValueError("next-hop index must be at least 2")
    out = struct.pack("<IBB2x", index, 1, revision) + mac(dst) + mac(src)
    out += struct.pack(">H", ethertype) + struct.pack("<HHBBH2x", 0, tag, 0, iface, mtu)
    assert len(out) == 32
    return out


def mflow(candidate_id, candidate_rev, direction, conn_idx, conn_rev, fw_rev,
          l3_rev, nhop_idx, nhop_rev, timeout):
    if not 0 < candidate_id < 1 << 25 or candidate_rev > 0x3f:
        raise ValueError("candidate id/revision out of range")
    ident = candidate_id | candidate_rev << 25 | 1 << 31
    operation = ACTION_FWD << 16 | direction << 23 | STATE_ACTIVE << 28
    out = struct.pack("<IIIIIIH2xI", ident, operation, l3_rev, conn_idx,
                      conn_rev << 16 | fw_rev, nhop_idx | nhop_rev << 24, 0, timeout)
    assert len(out) == 32
    return out


def mflow_clear(spec, side):
    """Standalone MFLOW_PROGRAM with state 0: invalidates a stale slot after reclaim."""
    m = spec[side]
    ident = m["id"] | m["rev"] << 25 | 1 << 31
    out = struct.pack("<IIIIIIH2xI", ident, 0, spec["l3_rev"], spec["conn_idx"],
                      spec["conn_rev"] << 16 | spec["fw_rev"], m["nhop"]["index"], 0, 0)
    assert len(out) == 32
    return out


def flow_create(spec):
    conn_idx, conn_rev = spec["conn_idx"], spec["conn_rev"]
    if conn_idx < 2:
        raise ValueError("connection index must be at least 2")
    if spec["orig"]["id"] == spec["reply"]["id"]:
        raise ValueError("original and reply need distinct microflows")
    flags = conn_rev | 1 << CONN_VERDICT_BIT | CONN_STATE_VALID << 30
    head = struct.pack("<II", conn_idx, flags).ljust(112, b"\0")
    parts = []
    for direction, name in ((0, "orig"), (1, "reply")):
        side = spec[name]
        parts.append(mflow(side["id"], side["rev"], side.get("dir", direction), conn_idx, conn_rev,
                           spec["fw_rev"], spec["l3_rev"], side["nhop"]["index"],
                           side["nhop"]["rev"], spec.get("timeout", 244141)))
    nat = spec.get("nat")
    if nat:
        # Ports are destination before source in both pairs; the block is at +84.
        block = (socket.inet_aton(nat["orig_src"]) + socket.inet_aton(nat["orig_dst"]) +
                 socket.inet_aton(nat["nat_src"]) + socket.inet_aton(nat["nat_dst"]) +
                 struct.pack(">HHHH", nat["orig_dst_port"], nat["orig_src_port"],
                             nat["nat_dst_port"], nat["nat_src_port"]))
        head = head[:84] + block + head[108:]
        flags |= (nat["snat"] << 20) | (nat["dnat"] << 19)
        head = head[:4] + struct.pack("<I", flags) + head[8:]
    if spec.get("orig_only"):
        out = head + struct.pack("<I", 1) + parts[0] + bytes(32)
    else:
        out = head + struct.pack("<I", FLOW_VALID_BOTH) + parts[0] + parts[1]
    assert len(out) == 180
    return out


def build(spec):
    lines = []
    for name in ("orig", "reply"):
        n = spec[name]["nhop"]
        lines.append((CMD_NHOP, nhop(n["index"], n["rev"], n["dst"], n["src"],
                                     n["iface"], n["tag"], n["mtu"])))
    lines.append((CMD_FLOW_CREATE, flow_create(spec)))
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("spec", help="JSON file describing the connection")
    args = parser.parse_args()
    with open(args.spec, encoding="utf-8") as handle:
        spec = json.load(handle)
    for command, payload in build(spec):
        print(command, payload.hex())
    return 0


if __name__ == "__main__":
    sys.exit(main())
