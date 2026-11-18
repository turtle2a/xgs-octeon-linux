#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""One bounded offload commissioning cycle on a single octep port (needs root).

Opens the offload gate, drives two ICMP flows from SRC_IF so the firmware makes
two live microflows, programs a bounce next hop (frames return to the sender
through the arrival interface), writes one FLOW_CREATE_FP, then verifies the
readback and whether frames stopped reaching the host. The flow is always
reclaimed and both gates are closed on exit.
"""

import importlib.util
import os
import random
import re
import subprocess
import sys
import time

PF = os.environ.get("PF", "/sys/bus/pci/devices/0000:01:00.0")
SRC_IF = os.environ.get("SRC_IF", "octep3")
TARGET = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.1"
CONN_IDX = int(os.environ.get("CONN_IDX", "10000"))
NHOP_BASE = int(os.environ.get("NHOP_BASE", os.environ.get("NHOP", "100")))
NHOP_REV = int(os.environ.get("NHOP_REV", "1"))
L3_REV = int(os.environ.get("L3_REV", "0"))
# A dummy destination keeps bounced replies from looking like spoofed traffic to the gateway.
NWA_TAG = int(os.environ.get("NWA_TAG", "33792"))
BOUNCE_MAC = os.environ.get("BOUNCE_MAC", "02:00:00:00:00:99")

here = os.path.dirname(os.path.abspath(__file__))
spec_mod = importlib.util.spec_from_file_location(
    "flow_build", os.path.join(here, "..", "octep", "flow-build.py"))
flow_build = importlib.util.module_from_spec(spec_mod)
spec_mod.loader.exec_module(flow_build)


def rd(name):
    with open(f"{PF}/{name}", encoding="utf-8") as handle:
        return handle.read().strip()


def wr(name, value):
    with open(f"{PF}/{name}", "w", encoding="utf-8") as handle:
        handle.write(str(value))


def kv(text):
    return dict(re.findall(r"(\w+)=(\S+)", text))


def mflow(ident):
    wr("rpc_mflow_read", ident)
    return kv(rd("rpc_mflow_read"))


NAMES = {0: "RX_WIRE", 1: "TX_WIRE", 2: "WIRE_TO_WIRE", 3: "RX_KN", 8: "TX_DROP",
         9: "TX_DROP_QUEUE_FULL", 12: "TX_KN", 39: "FORCED", 40: "NON_ACCEL",
         42: "FW_REV_MISMATCH", 43: "L3_FW_REV_MISMATCH", 44: "NHOP_LU_NULL",
         45: "NHOP_UNRESOLVED", 46: "NHOP_REV_MISMATCH", 47: "NHOP_IDX_ERR",
         49: "CONN_REV_MISMATCH", 50: "CONN_ID_ERR", 51: "CONN_INVALID",
         52: "CONN_RECLAIM_PENDING", 53: "CONN_RECLAIMED", 59: "MFLOW_NOT_ACTIVE",
         60: "EG_ERR"}


def counters():
    out = {}
    for line in rd("rpc_sys_counters").splitlines()[1:]:
        idx, _, val = line.partition("=")
        if idx.isdigit() and val.isdigit():
            out[int(idx)] = int(val)
    return out


def counter_delta(a, b, label):
    delta = {NAMES.get(i, f"#{i}"): b[i] - a.get(i, 0)
             for i in b if b[i] != a.get(i, 0)}
    print(f"counters {label}:", delta or "no change")


def nwa(tag):
    wr("nwa_request", f"4 14 {tag} 0 0")
    return {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", rd("nwa_last"))
            if k in ("unicast_frames_received", "unicast_frames_sent",
                     "good_octets_received", "good_octets_sent")}


def nwa_delta(a, b, label):
    print(f"NWA port {label}:", {k: b[k] - a.get(k, 0) for k in b})


def rx_header():
    return kv(rd("rx_flow").splitlines()[0])


def live_candidates():
    found = {}
    for line in rd("rx_flow").splitlines():
        fields = kv(line)
        if "candidate_id" not in fields or int(fields.get("age_ms", "999999")) > 4000:
            continue
        entry = mflow(fields["candidate_id"])
        if entry.get("fw_valid") == "1" and entry.get("state") == "0":
            found[fields["candidate_id"]] = (fields, entry)
    return found


def main():
    if os.geteuid() != 0:
        print(f"SUDO REQUIRED: sudo {sys.argv[0]}", file=sys.stderr)
        return 1
    procs, reclaim = [], None
    try:
        cnt_start = counters()
        wr("offload", "on")
        print("gate:", rd("offload"))
        icmp_ids = [random.randrange(1, 65535) for _ in range(2)]
        for ident in icmp_ids:
            procs.append(subprocess.Popen(
                ["ping", "-I", SRC_IF, "-e", str(ident), "-c", "400", "-i", "0.2",
                 TARGET], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
            time.sleep(0.7)
        cands = {}
        for _ in range(40):
            time.sleep(0.5)
            cands = live_candidates()
            if len(cands) >= 2:
                break
        if len(cands) < 2:
            print("FAIL: fewer than two live fw_valid candidates:", list(cands))
            counter_delta(cnt_start, counters(), "since gate on")
            print(rd("rx_flow")[:900])
            print("rpc_state:", rd("rpc_state")[:260])
            return 2
        ids = sorted(cands, key=int)[:2]
        print("candidates:", ids)
        (cf_a, me_a), (cf_b, me_b) = cands[ids[0]], cands[ids[1]]
        for fields, entry in ((cf_a, me_a), (cf_b, me_b)):
            print(" ", fields["candidate_id"], fields["tuple"], "rev", entry["revision"])
        fw_rev = int(kv(rd("rpc_state")).get("fw_rev", "0"))
        tag = int(cf_a["tag"])
        # The next hop's egress interface is the NWA port index: tag 0x8100 is port 2.
        iface = int(os.environ.get("IFACE", ((tag - 0x8100) >> 8) + 2))
        spec = {
            "conn_idx": CONN_IDX, "conn_rev": 1, "fw_rev": fw_rev, "l3_rev": L3_REV,
            "orig": {"id": int(ids[0]), "rev": int(me_a["revision"]),
                     "nhop": None},
            "reply": {"id": int(ids[1]), "rev": int(me_b["revision"]), "nhop": None},
        }
        for n, side in enumerate(("orig", "reply")):
            spec[side]["nhop"] = {
                "index": NHOP_BASE + n, "rev": NHOP_REV,
                "dst": BOUNCE_MAC, "src": cf_a["dst_mac"],
                "iface": iface, "tag": tag, "mtu": 1500}
        if os.environ.get("VALID") == "1":
            spec["orig_only"] = True
        if os.environ.get("DIRS"):
            for side, d in zip(("orig", "reply"), os.environ["DIRS"].split(",")):
                spec[side]["dir"] = int(d)
        lines = flow_build.build(spec)
        time.sleep(1)
        base_a = int(rx_header()["rx_frames"])
        nwa_p = nwa(NWA_TAG)
        time.sleep(3)
        nwa_delta(nwa_p, nwa(NWA_TAG), "control 3s before write")
        before = rx_header()
        print("control: host-visible frames in 3s before write:",
              int(before["rx_frames"]) - base_a)
        wr("rpc_conn_read", CONN_IDX)
        print("conn before:", rd("rpc_conn_read")[:120])
        cnt_pre = counters()
        wr("rpc_allow_write", 1)
        if (os.environ.get("NOWRITE") or "nowrite" in sys.argv[2:]):
            print("NOWRITE control: nothing written")
            lines = []
        for command, payload in lines:
            stage_a, rx_a = counters(), int(rx_header()["rx_frames"])
            wr("rpc_flow_write", f"{command} {payload.hex()}")
            print("wrote cmd", command, "ok")
            time.sleep(2)
            counter_delta(stage_a, counters(), f"2s after cmd {command}")
            print("  host-visible frames in those 2s:",
                  int(rx_header()["rx_frames"]) - rx_a)
        reclaim = (CONN_IDX, spec["conn_rev"]) if lines else None
        time.sleep(3)
        counter_delta(cnt_pre, counters(), "write -> +3s")
        for ident in ids:
            entry = mflow(ident)
            print("mflow", ident, {k: entry.get(k) for k in (
                "fw_valid", "host_valid", "action", "state", "connection",
                "next_hop", "revision")})
        wr("rpc_conn_read", CONN_IDX)
        print("conn after:", rd("rpc_conn_read")[:160])
        def snap():
            wr("rpc_conn_read", CONN_IDX)
            raw = rd("rpc_conn_read").split("raw=")[1].split()
            return raw, [mflow(i).get("timestamp") for i in ids]

        raw_a, ts_a = snap()
        fresh = subprocess.run(
            ["ping", "-I", SRC_IF, "-e", str(random.randrange(1, 65535)), "-c", "3",
             "-W", "1", TARGET], capture_output=True, text=True, check=False).stdout
        got = re.search(r"(\d+) received", fresh)
        print("active window, fresh-key ping:", got.group(1) if got else "?", "/3 replies")
        mid = rx_header()
        cnt_a = counters()
        nwa_a = nwa(NWA_TAG)
        time.sleep(5)
        nwa_delta(nwa_a, nwa(NWA_TAG), "during 5s active flow")
        counter_delta(cnt_a, counters(), "during 5s active flow")
        raw_b, ts_b = snap()
        print("conn bytes changed (offset: old->new):",
              {n: f"{x}->{y}" for n, (x, y) in enumerate(zip(raw_a, raw_b)) if x != y})
        print("mflow timestamps:", ts_a, "->", ts_b)
        after = rx_header()
        print("rx_frames  before/mid/after:", before["rx_frames"], mid["rx_frames"],
              after["rx_frames"])
        print("host-visible frames in the last 5s:",
              int(after["rx_frames"]) - int(mid["rx_frames"]))
        print("ping replies still reaching host means offload not taking effect")
        wr("rpc_conn_reclaim", f"{CONN_IDX} {spec['conn_rev']}")
        reclaim = None
        print("reclaim:", rd("rpc_conn_reclaim")[:60])
        for ident in ids:
            entry = mflow(ident)
            print("mflow after reclaim", ident, {k: entry.get(k) for k in (
                "fw_valid", "host_valid", "action", "state", "connection",
                "next_hop", "revision")})
        print("pings alive:", [proc.poll() is None for proc in procs])
        time.sleep(1)
        post_a = int(rx_header()["rx_frames"])
        time.sleep(3)
        print("control: host-visible frames in 3s after reclaim:",
              int(rx_header()["rx_frames"]) - post_a)
        wr("offload", "off")
        time.sleep(1)
        gate_a = int(rx_header()["rx_frames"])
        time.sleep(3)
        print("control: host-visible frames in 3s after gate off:",
              int(rx_header()["rx_frames"]) - gate_a)
        for proc in procs:
            proc.terminate()
        time.sleep(1)
        probes = [("same key as flow 1", icmp_ids[0]),
                  ("same key as flow 2", icmp_ids[1]),
                  ("fresh key", random.randrange(1, 65535))]
        for label, ident in probes:
            out = subprocess.run(
                ["ping", "-I", SRC_IF, "-e", str(ident), "-c", "3", "-W", "1", TARGET],
                capture_output=True, text=True, check=False).stdout
            got = re.search(r"(\d+) received", out)
            print(f"gate off, {label}: {got.group(1) if got else '?'}/3 replies")
        t0 = time.time()
        while time.time() - t0 < 60:
            out = subprocess.run(
                ["ping", "-I", SRC_IF, "-c", "1", "-W", "1", TARGET],
                capture_output=True, text=True, check=False).stdout
            if " 1 received" in out:
                print(f"replies back {time.time() - t0:.0f}s after gate off")
                break
            time.sleep(1)
        else:
            print("no replies within 60s after gate off")
        return 0
    except OSError as err:
        print("FAIL:", err)
        return 3
    finally:
        for proc in procs:
            proc.terminate()
        if reclaim:
            try:
                wr("rpc_conn_reclaim", f"{reclaim[0]} {reclaim[1]}")
                print("reclaim:", rd("rpc_conn_reclaim")[:100])
            except OSError as err:
                print("RECLAIM FAILED:", err, "- reload the module or reboot")
        for name, value in (("rpc_allow_write", 0), ("offload", "off")):
            try:
                wr(name, value)
            except OSError as err:
                print("close", name, "failed:", err)
        print("gate:", rd("offload"), "| write_gate:", kv(rd("rpc_state")).get("write_gate"))


if __name__ == "__main__":
    sys.exit(main())
