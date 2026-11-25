#!/usr/bin/env python3
"""Classify the client's TCP data segments of one offloaded iperf3 flow from the router-side captures.

Usage: octep-frame-ident.py LAN.pcap WAN.pcap [bin_ms]

The pcaps are taken on the host netdevs, so they hold only frames the host saw. A segment the NPU
forwarded wire-to-wire is in neither file, so it is identified by absence:
  host-fwd   seen on LAN in and WAN out
  host-drop  seen on LAN in, never on WAN out (dropped by the host)
  npu-fwd    on neither, but covered by a later server ACK and never retransmitted
  retx       the client sent the same seq more than once (the first copy was lost or its ACK was)
Server ACKs are split into host-seen ACKs on WAN (punted or host-routed) and ACKs sent to the client on LAN.
"""
import re
import subprocess
import sys
from collections import defaultdict

LINE = re.compile(r"^(\d+\.\d+) IP (\S+)\.(\d+) > (\S+)\.(\d+): Flags \[([^\]]*)\], (?:seq (\d+)(?::(\d+))?, )?(?:ack (\d+), )?.*length (\d+)")


def read(pcap):
    out = subprocess.run(["tcpdump", "-nn", "-tt", "-r", pcap, "tcp port 5201"],
                         capture_output=True, text=True, check=False).stdout
    for ln in out.splitlines():
        m = LINE.match(ln)
        if m:
            t, _, sport, _, dport, _, seq, _, ack, length = m.groups()
            yield float(t), int(sport), int(dport), (int(seq) if seq else None), (int(ack) if ack else None), int(length)


def main():
    lan, wan = sys.argv[1], sys.argv[2]
    bin_s = (int(sys.argv[3]) if len(sys.argv) > 3 else 100) / 1000.0
    lan_data, wan_data = defaultdict(list), defaultdict(list)
    wan_acks, lan_acks = [], []
    t0 = None
    rows = [(0, r) for r in read(lan)] + [(1, r) for r in read(wan)]
    # The data connection is the client port with the most payload segments (the control connection is tiny).
    per_port = defaultdict(int)
    for _, (t, sp, dp, seq, ack, ln) in rows:
        if dp == 5201 and ln > 0:
            per_port[sp] += 1
    if not per_port:
        sys.exit("no data segments to port 5201")
    cport = max(per_port, key=per_port.get)
    print(f"data connection: client port {cport} ({per_port[cport]} data segments seen on both ports)")
    for side, (t, sp, dp, seq, ack, ln) in rows:
        if cport not in (sp, dp):
            continue
        t0 = t if t0 is None else min(t0, t)
        if dp == 5201 and ln > 0:
            (lan_data if side == 0 else wan_data)[seq].append(t)
        elif sp == 5201 and ack is not None:
            (lan_acks if side == 0 else wan_acks).append((t, ack))
    if t0 is None:
        sys.exit("no port-5201 packets in either capture")
    max_ack = max([a for _, a in wan_acks + lan_acks] or [0])
    first_seq = min(list(lan_data) + list(wan_data) or [0])
    # The client's seq range covered by the ACK stream; segments in it that the host never saw went through the NPU.
    seqs = sorted(set(lan_data) | set(wan_data))
    cls = {}
    for s in seqs:
        n_lan, n_wan = len(lan_data.get(s, [])), len(wan_data.get(s, []))
        cls[s] = "retx" if n_lan > 1 or n_wan > 1 else ("host-fwd" if n_lan and n_wan else ("host-drop" if n_lan else "wan-only"))
    # Gaps between seen seqs that a later ACK covers: frames the NPU forwarded.
    gaps = []
    prev = None
    for s in seqs:
        if prev is not None and s - prev > 1448 * 2 and s <= max_ack:
            gaps.append((prev, s, (s - prev) // 1448))
        prev = s
    bins = defaultdict(lambda: defaultdict(int))
    for s, ts in lan_data.items():
        bins[int((min(ts) - t0) / bin_s)]["lan_in:" + cls[s]] += 1
    for s, ts in wan_data.items():
        bins[int((min(ts) - t0) / bin_s)]["wan_out"] += 1
    for t, _ in wan_acks:
        bins[int((t - t0) / bin_s)]["ack_wan_in"] += 1
    for t, _ in lan_acks:
        bins[int((t - t0) / bin_s)]["ack_lan_out"] += 1
    keys = ["lan_in:host-fwd", "lan_in:host-drop", "lan_in:retx", "wan_out", "ack_wan_in", "ack_lan_out"]
    print("bin(ms) " + " ".join(f"{k:>16}" for k in keys))
    for b in sorted(bins):
        print(f"{int(b * bin_s * 1000):7d} " + " ".join(f"{bins[b][k]:16d}" for k in keys))
    npu_frames = sum(g[2] - 1 for g in gaps)
    print(f"\nsegments seen {len(seqs)}: " + ", ".join(f"{c}={sum(1 for v in cls.values() if v == c)}" for c in ("host-fwd", "host-drop", "retx", "wan-only")))
    print(f"npu-fwd candidates (seq gaps covered by a later ACK): {npu_frames} frames in {len(gaps)} gap(s)")
    for g in gaps[:10]:
        print(f"  gap seq {g[0]} -> {g[1]} (~{g[2] - 1} frames)")
    print("first seq", first_seq, "max ack", max_ack)

    # Time delta of the same frame crossing the host: LAN in -> WAN out (data), WAN in -> LAN out (ACKs by ack number).
    d_data = sorted((min(wan_data[x]) - min(lan_data[x])) * 1000 for x in lan_data if x in wan_data)
    wan_ack_first, lan_ack_first = {}, {}
    for t, a in wan_acks:
        wan_ack_first.setdefault(a, t)
    for t, a in lan_acks:
        lan_ack_first.setdefault(a, t)
    d_ack = sorted((lan_ack_first[a] - wan_ack_first[a]) * 1000 for a in wan_ack_first if a in lan_ack_first)
    def pct(v, q):
        return f"{v[min(len(v) - 1, int(len(v) * q))]:.3f}" if v else "n/a"
    print(f"\ndata  LAN-in -> WAN-out delta ms: n={len(d_data)} p50={pct(d_data, .5)} p90={pct(d_data, .9)} p99={pct(d_data, .99)} max={pct(d_data, 1)}")
    print(f"acks  WAN-in -> LAN-out delta ms: n={len(d_ack)} p50={pct(d_ack, .5)} p90={pct(d_ack, .9)} p99={pct(d_ack, .99)} max={pct(d_ack, 1)}")
    print(f"acks seen on WAN {len(wan_ack_first)}, not seen leaving on LAN {len([a for a in wan_ack_first if a not in lan_ack_first])} (dropped or NPU-handled)")


if __name__ == "__main__":
    main()
