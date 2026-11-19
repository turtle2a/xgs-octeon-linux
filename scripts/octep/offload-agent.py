#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Bench offload agent for one octep port (needs root).

Opens the offload gate, takes live firmware candidates and offloads a pair only
when conntrack shows both connections as replied (the host's policy already
accepted them). Frames are bounced back through the arrival port. A pair is
reclaimed when either conntrack entry disappears or the lease runs out, and the
gate is always closed on exit.

  offload-agent.py [--seconds N] [--lease N] [--demo TARGET]

--demo starts two pings to TARGET from SRC_IF so candidates exist.
"""

import argparse
import importlib.util
import json
import os
import random
import re
import subprocess
import sys
import time

here = os.path.dirname(os.path.abspath(__file__))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, os.path.join(here, path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


commission = load("commission", "../tests/octep-offload-commission.py")
flow_build = commission.flow_build
rd, wr, kv = commission.rd, commission.wr, commission.kv
SRC_IF = commission.SRC_IF


def local_addrs():
    out = subprocess.run(["ip", "-o", "-4", "addr"], capture_output=True, text=True, check=False).stdout
    return set(re.findall(r"inet (\d+\.\d+\.\d+\.\d+)", out))


def conntrack_replied(skip_local=True):
    """Reply tuples (proto, src, dst) of answered connections; host-terminated flows are skipped."""
    seen = set()
    local = local_addrs() if skip_local else set()
    with open("/proc/net/nf_conntrack", encoding="utf-8") as handle:
        for line in handle:
            if "[UNREPLIED]" in line:
                continue
            pairs = re.findall(r"src=(\S+) dst=(\S+)", line)
            fields = line.split()
            if len(pairs) >= 2 and len(fields) > 3 and fields[3].isdigit():
                if local & {pairs[0][0], pairs[0][1]}:
                    continue
                seen.add((int(fields[3]), pairs[1][0], pairs[1][1]))
    return seen


def ports_of(line):
    return [(int(a), int(b)) for a, b in re.findall(r"sport=(\d+) dport=(\d+)", line)]


def reply_ports(cid):
    """(src_port, dst_port) of the live candidate id, so NAT is taken from the right connection."""
    for line in rd("rx_flow").splitlines():
        if kv(line).get("candidate_id") == cid:
            found = re.search(r":(\d+)->\S+:(\d+)", line)
            if found:
                return int(found.group(1)), int(found.group(2))
    return None


def conntrack_nat(proto, reply_src, reply_dst, want_ports=None):
    """NAT block spec derived from the conntrack entry whose reply tuple is (reply_src -> reply_dst).

    Returns None for a connection without NAT. With SNAT the reply is addressed to the
    translated source; with DNAT the reply comes from the translated destination.
    """
    with open("/proc/net/nf_conntrack", encoding="utf-8") as handle:
        for line in handle:
            fields = line.split()
            if len(fields) < 4 or not fields[3].isdigit() or int(fields[3]) != proto:
                continue
            addrs = re.findall(r"src=(\S+) dst=(\S+)", line)
            ports = [(int(a), int(b)) for a, b in re.findall(r"sport=(\d+) dport=(\d+)", line)]
            if len(addrs) < 2 or addrs[1] != (reply_src, reply_dst):
                continue
            if want_ports and (len(ports_found := ports_of(line)) < 2 or ports_found[1] != want_ports):
                continue
            (osrc, odst), (rsrc, rdst) = addrs[0], addrs[1]
            if (rsrc, rdst) == (odst, osrc):
                return None
            osp, odp = ports[0] if len(ports) > 0 else (0, 0)
            rsp, rdp = ports[1] if len(ports) > 1 else (0, 0)
            return {"orig_src": osrc, "orig_dst": odst, "nat_src": rdst, "nat_dst": rsrc,
                    "orig_dst_port": odp, "orig_src_port": osp,
                    "nat_dst_port": rsp, "nat_src_port": rdp,
                    "snat": int(rdst != osrc), "dnat": int(rsrc != odst)}
    return None


def tuple_of(line):
    proto = re.search(r"proto=(\d+)", line)
    addrs = re.search(r"(\d+\.\d+\.\d+\.\d+):\d+->(\d+\.\d+\.\d+\.\d+):\d+", line)
    if not proto or not addrs:
        return None
    return int(proto.group(1)), addrs.group(1), addrs.group(2)


def eligible_candidates(allowed):
    found = {}
    for line in rd("rx_flow").splitlines():
        fields = kv(line)
        if "candidate_id" not in fields or int(fields.get("age_ms", "999999")) > 4000:
            continue
        key = tuple_of(line)
        if key is None or key not in allowed:
            continue
        entry = commission.mflow(fields["candidate_id"])
        if entry.get("fw_valid") == "1" and entry.get("state") == "0":
            found[fields["candidate_id"]] = (fields, entry, key)
    return found


def live_by_tuple(max_age_ms):
    """Live candidate ids grouped by flow tuple; one flow can appear under several ids."""
    out = {}
    for line in rd("rx_flow").splitlines():
        fields = kv(line)
        if "candidate_id" in fields and int(fields.get("age_ms", "999999")) <= max_age_ms:
            tup = re.search(r"proto=\d+ \S+", line)
            out.setdefault(tup.group(0) if tup else "?", {})[fields["candidate_id"]] = fields["frames"]
    return out


def spare_slot(exclude):
    """A free microflow slot (valid, state 0) for the direction the wire never offers.
    Prefers the quietest, oldest id so no active flow's slot is taken."""
    best = None
    for line in rd("rx_flow").splitlines():
        fields = kv(line)
        cid = fields.get("candidate_id")
        if not cid or cid in exclude or int(fields.get("age_ms", "0")) <= 4000:
            continue
        entry = commission.mflow(cid)
        if entry.get("fw_valid") != "1" or entry.get("state") != "0":
            continue
        rank = (int(fields.get("frames", "0")), -int(fields.get("age_ms", "0")))
        if best is None or rank < best[0]:
            best = (rank, cid, (fields, entry, None))
    return best and (best[1], best[2])


def explain_skips(allowed):
    """Why each live candidate is not eligible: stale age, tuple not in conntrack, or slot state."""
    rows = []
    for line in rd("rx_flow").splitlines():
        fields = kv(line)
        if "candidate_id" not in fields:
            continue
        age, frames = int(fields.get("age_ms", "999999")), int(fields.get("frames", "0"))
        if frames < 100:
            continue
        key = tuple_of(line)
        entry = commission.mflow(fields["candidate_id"])
        local = key is not None and key[2] in local_addrs()
        why = ("age" if age > 4000 else "local-flow" if local and key not in allowed
               else "not-in-conntrack" if key is None or key not in allowed
               else "slot fw_valid=%s state=%s" % (entry.get("fw_valid"), entry.get("state")))
        rows.append(f"id={fields['candidate_id']} frames={frames} age={age}ms -> {why}")
    return rows


def live_ids(max_age_ms):
    out = {}
    for line in rd("rx_flow").splitlines():
        fields = kv(line)
        if "candidate_id" in fields and int(fields.get("age_ms", "999999")) <= max_age_ms:
            out[fields["candidate_id"]] = fields["frames"]
    return out


def egress(dst_ip):
    """(octep netdev, next-hop MAC) the host itself would use for dst_ip."""
    route = subprocess.run(["ip", "-j", "route", "get", dst_ip], capture_output=True,
                           text=True, check=True)
    info = json.loads(route.stdout)[0]
    dev, hop = info["dev"], info.get("gateway", dst_ip)
    neigh = json.loads(subprocess.run(["ip", "-j", "neigh", "show", hop, "dev", dev],
                                      capture_output=True, text=True, check=True).stdout)
    macs = [n["lladdr"] for n in neigh if n.get("lladdr") and
            n.get("state", ["FAILED"])[0] != "FAILED"]
    if not re.fullmatch(r"octep\d", dev) or not macs:
        raise RuntimeError(f"no usable octep egress for {dst_ip}: dev={dev} hop={hop}")
    port_mac = open(f"/sys/class/net/{dev}/address", encoding="utf-8").read().strip()
    return dev, macs[0], port_mac


def src_on_npu(ip):
    """True when the host reaches ip through an octep port, so the NPU can deliver replies to it."""
    route = subprocess.run(["ip", "-j", "route", "get", ip], capture_output=True, text=True, check=False)
    try:
        return bool(re.fullmatch(r"octep\d", json.loads(route.stdout)[0]["dev"]))
    except (ValueError, KeyError, IndexError):
        return False


def neigh_mac(ip, dev):
    out = json.loads(subprocess.run(["ip", "-j", "neigh", "show", ip, "dev", dev],
                                    capture_output=True, text=True, check=True).stdout)
    return out[0]["lladdr"]


def offload_pair(conn_idx, nhop_base, cands, ids, transit=False, force_dev=None, hop_ip=None,
                 snat_ip=None, hot_reply=True, host_iface=None, host_src=None):
    (cf_a, me_a, _), (cf_b, me_b, _) = cands[ids[0]], cands[ids[1]]
    fw_rev = int(kv(rd("rpc_state")).get("fw_rev", "0"))
    tag = int(cf_a["tag"])
    iface = ((tag - 0x8100) >> 8) + 2
    spec = {"conn_idx": conn_idx, "conn_rev": 1, "fw_rev": fw_rev, "l3_rev": 0,
            "orig": {"id": int(ids[0]), "rev": int(me_a["revision"])},
            "reply": {"id": int(ids[1]), "rev": int(me_b["revision"])}}
    if hot_reply:
        # the wire only offers reply-direction candidates, so the busy one is the reply microflow
        spec["orig"], spec["reply"] = ({"id": int(ids[1]), "rev": int(me_b["revision"])},
                                       {"id": int(ids[0]), "rev": int(me_a["revision"])})
    for n, side in enumerate(("orig", "reply")):
        spec[side]["nhop"] = {"index": nhop_base + n, "rev": 0,
                              "dst": cf_a["src_mac"], "src": cf_a["dst_mac"],
                              "iface": iface, "tag": tag, "mtu": 1500}
        if force_dev:
            dev = force_dev
            if hop_ip:
                dst_mac = neigh_mac(hop_ip, dev)
            else:
                dst_mac = egress(cands[ids[0]][2][1])[1]
            src_mac = open(f"/sys/class/net/{dev}/address", encoding="utf-8").read().strip()
        if transit or force_dev:
            if not force_dev:
                dev, dst_mac, src_mac = egress(cands[ids[0]][2][2])
            port = int(dev[5:])
            spec[side]["nhop"].update({"dst": dst_mac, "src": src_mac,
                                       "iface": port + 2, "tag": 0x8100 + 0x100 * port})
            print(f"  {side} nhop: {dev} dst={dst_mac} src={src_mac} iface={port + 2}")
    proto, peer_ip, host_ip = cands[ids[0]][2]
    real_nat = conntrack_nat(proto, peer_ip, host_ip, reply_ports(ids[0]))
    if host_iface is not None and host_src:
        # source is behind a host NIC: the NPU de-NATs the reply and hands it to the kernel, which routes it on
        route = json.loads(subprocess.run(["ip", "-j", "route", "get", host_src], capture_output=True,
                                          text=True, check=True).stdout)[0]
        nic = route["dev"]
        if nic == "lo":
            # the source address is on the appliance itself: hand the reply to the kernel via the owning interface
            owner = json.loads(subprocess.run(["ip", "-j", "addr", "show", "to", host_src], capture_output=True,
                                              text=True, check=True).stdout)
            nic = owner[0]["ifname"]
            own_mac = open(f"/sys/class/net/{nic}/address", encoding="utf-8").read().strip()
            dst_mac = own_mac
        else:
            dst_mac = neigh_mac(host_src, nic)
        spec["reply"]["nhop"].update({
            "dst": dst_mac,
            "src": open(f"/sys/class/net/{nic}/address", encoding="utf-8").read().strip(),
            "iface": host_iface})
        print(f"  host-delivery: reply to {host_src} via {nic}, NPU iface {host_iface}")
    if real_nat and not snat_ip:
        spec["nat"] = real_nat
        print(f"  nat from conntrack: {real_nat}")
    if snat_ip:
        spec["nat"] = {"orig_src": host_ip, "orig_dst": peer_ip, "nat_src": snat_ip,
                       "nat_dst": peer_ip, "orig_dst_port": 0, "orig_src_port": 0,
                       "nat_dst_port": 0, "nat_src_port": 0, "snat": 1, "dnat": 0}
        print(f"  nat: SNAT {host_ip} -> {snat_ip} (peer {peer_ip})")
    wr("rpc_allow_write", 1)
    for command, payload in flow_build.build(spec):
        wr("rpc_flow_write", f"{command} {payload.hex()}")
    return spec


def clear_pair(spec):
    """Invalidate both microflow slots so the flow can be offered as a candidate again."""
    wr("rpc_allow_write", 1)
    for side in ("orig", "reply"):
        try:
            wr("rpc_flow_write", f"8 {flow_build.mflow_clear(spec, side).hex()}")
            print(f"  cleared {side} slot {spec[side]['id']}")
        except OSError as exc:
            print(f"  clear {side} slot {spec[side]['id']} failed: {exc}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=40)
    parser.add_argument("--lease", type=int, default=15)
    parser.add_argument("--demo")
    parser.add_argument("--allow-non-npu-src", action="store_true",
                        help="offload even when the NAT'd original source is not behind an octep port (stalls)")
    parser.add_argument("--egress-host", type=int, metavar="IFACE",
                        help="deliver replies for non-NPU sources (e.g. enp2s0 hosts) to this NWA host/kernel iface (experiment)")
    parser.add_argument("--snat", metavar="IP", help="write an SNAT block rewriting the host address to IP")
    parser.add_argument("--egress", metavar="DEV", help="force egress netdev, with --transit")
    parser.add_argument("--allow-local", action="store_true",
                        help="also offload host-terminated flows (ICMP bounce tests only; breaks TCP)")
    parser.add_argument("--action", type=int, default=1, help="microflow action nibble (experiments; 1 = forward)")
    parser.add_argument("--legacy-order", action="store_true",
                        help="write the busiest candidate as the original-direction microflow (old behaviour)")
    parser.add_argument("--transit", action="store_true",
                        help="forward each direction to its routed egress port, not back out the arrival port")
    args = parser.parse_args()
    if os.geteuid() != 0:
        print(f"SUDO REQUIRED: sudo {sys.argv[0]}", file=sys.stderr)
        return 1
    procs, active = [], {}
    flow_build.ACTION_FWD = args.action
    start_cnt = commission.counters()
    try:
        wr("offload", "on")
        print("gate:", rd("offload"))
        if args.demo:
            for _ in range(2):
                procs.append(subprocess.Popen(
                    ["ping", "-I", SRC_IF, "-e", str(random.randrange(1, 65535)), "-c",
                     "400", "-i", "0.2", args.demo], stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL))
                time.sleep(0.7)
        deadline, next_conn, defer = time.time() + args.seconds, 10000, 0
        last_explain = 0.0
        last_skip = 0.0
        prev = commission.counters()
        while time.time() < deadline:
            time.sleep(1)
            cur = commission.counters()
            print(time.strftime("%H:%M:%S"), "rate:", {n: cur.get(i, 0) - prev.get(i, 0) for n, i in
                            (("rx", 0), ("fwd", 2), ("qfull", 9), ("notact", 59), ("reclaimed", 53))},
                  "offloaded" if active else "gate-open", flush=True)
            prev = cur
            allowed = conntrack_replied(not args.allow_local)
            for conn_idx, pair in list(active.items()):
                gone = not set(pair["keys"]) <= allowed
                if gone or (args.lease > 0 and time.time() - pair["t"] > args.lease):
                    wr("rpc_conn_reclaim", f"{conn_idx} 1")
                    print(f"reclaim conn {conn_idx} ({'conntrack gone' if gone else 'lease'}):",
                          rd("rpc_conn_reclaim")[:60])
                    pair["done"] = commission.counters()
                    clear_pair(pair["spec"])
                    del active[conn_idx]
            if active:
                continue
            cands = eligible_candidates(allowed)
            if len(cands) < 2 and time.time() - last_explain > 10:
                last_explain = time.time()
                print(f"{len(cands)} eligible candidate(s), need 2; live:",
                      explain_skips(allowed) or "none >=100 frames", flush=True)
            busy = {k: int(v) for k, v in live_ids(2000).items()}
            hot = max(busy.values(), default=0)
            best = max((busy.get(c, 0) for c in cands), default=0)
            if hot >= 10 and best * 2 < hot:
                # the busy flow is not an eligible candidate (aged, local or not yet offered): never write an unrelated cold flow instead
                continue
            ids = sorted(cands, key=lambda c: (-busy.get(c, 0), int(c)))[:2]
            if len(ids) == 1:
                spare = spare_slot(set(ids))
                if spare:
                    cands[spare[0]] = spare[1]
                    ids.append(spare[0])
            if len(ids) < 2:
                continue
            proto, peer_ip, host_ip = cands[ids[0]][2]
            hot_nat = conntrack_nat(proto, peer_ip, host_ip, reply_ports(ids[0]))
            off_npu = bool(hot_nat) and not src_on_npu(hot_nat["orig_src"])
            if off_npu and args.egress_host is None and not args.allow_non_npu_src:
                if time.time() - last_skip > 10:
                    last_skip = time.time()
                    print(f"skip offload: original source {hot_nat['orig_src']} is not behind an octep port "
                          "(NPU cannot deliver its replies); flow stays on the kernel path", flush=True)
                continue
            ports = {n: commission.nwa(0x8100 + 0x100 * n) for n in (1,)}
            before = commission.counters()
            print("write-time live candidates (id:frames):", live_ids(2000), "chosen", ids)
            print("  by tuple:", live_by_tuple(2000))
            spec = offload_pair(next_conn, 100 + 2 * (next_conn - 10000), cands, ids, args.transit, args.egress, None, args.snat,
                         not args.legacy_order,
                         args.egress_host if off_npu else None, hot_nat["orig_src"] if off_npu else None)
            print(f"offloaded conn {next_conn}: microflows {ids}")
            active[next_conn] = {"t": time.time(), "before": before, "spec": spec,
                                 "keys": [k for k in (cands[i][2] for i in ids) if k]}
            series, last = [], commission.counters()  # baseline after the write, not before it
            for _ in range(5):
                time.sleep(1)
                now = commission.counters()
                series.append((now.get(2, 0) - last.get(2, 0), now.get(0, 0) - last.get(0, 0)))
                last = now
            print("  per-second forwarded/rx after write:", series)
            after = last
            prev = last
            commission.counter_delta(before, after, "5s after offload")
            for n, snap in ports.items():
                commission.nwa_delta(snap, commission.nwa(0x8100 + 0x100 * n), f"octep{n}")
            rx = after.get(0, 0) - before.get(0, 0)
            fwd = after.get(2, 0) - before.get(2, 0)
            tail_f, tail_r = sum(f for f, _ in series), sum(r for _, r in series)
            verdict = ("IDLE (flow ended)" if tail_r < 20 else
                       "EFFECTIVE" if tail_f * 2 >= tail_r else "INEFFECTIVE")
            print(f"conn {next_conn}: forwarded {tail_f}/{tail_r} wire frames after write: {verdict}")
            if verdict != "EFFECTIVE":
                for ident in ids:
                    commission.wr("rpc_mflow_read", ident)
                    print("  readback", ident, rd("rpc_mflow_read")[:200])
                print("  candidates receiving frames now (id:frames):", live_ids(1500))
                print("  by tuple now:", live_by_tuple(1500))
                active[next_conn]["t"] = 0
            next_conn += 1
        commission.counter_delta(start_cnt, commission.counters(), "whole run")
        return 0
    finally:
        for proc in procs:
            proc.terminate()
        for conn_idx in active:
            wr("rpc_conn_reclaim", f"{conn_idx} 1")
        for name, value in (("rpc_allow_write", 0), ("offload", "off")):
            wr(name, value)
        print("gate:", rd("offload"))


if __name__ == "__main__":
    sys.exit(main())
