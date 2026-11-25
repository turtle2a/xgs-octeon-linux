# Hardware offload: kernel alignment (Task 9a)

How the Linux flow-offload model differs from what the OCTEON NPU firmware offers,
what this driver already does about it, and what an upstream change would need.

## Summary (Task 9a)

The Linux flow-offload API and the OCTEON NPU firmware do not line up, so the
kernel's standard offload path cannot drive this hardware today:

1. **Who names the flow.** Linux hands the driver a finished 5-tuple. The NPU
   firmware names its own flow slots: a flow can only be written into a slot id the
   firmware has just offered on a punted frame. The kernel API has no step for
   "wait for the hardware to pick the slot".
2. **Egress, NAT and statistics.** Linux expresses egress as an ifindex, NAT as
   header-mangle actions and counters per flow. The NPU wants an NWA port index, an
   opaque 24-byte NAT block inside the connection entry, and has only global and
   per-port counters.
3. **Release.** Linux removes each direction with `FLOW_CLS_DESTROY`; the NPU
   reclaims a whole connection (`CONN_RECLAIM_FP`), and stale slots keep punting.
4. **Mainline driver.** To my knowledge (unchecked against a current tree) mainline
   `octeon_ep` has no `TC_SETUP_FT` support, so there is nothing upstream to build on.
5. **Result on this appliance (2026-11-19).** Everything the host programs matches the
   BSD reference, yet the NPU forwards only the original direction of a NAT'd TCP
   flow: the reply microflow never goes active (`MFLOW_NOT_ACTIVE`), the flow stalls,
   and the driver's guard returns it to the host within about 0.3 s. Sustained
   hardware forwarding of real TCP has never been demonstrated; the likely cause is
   in the firmware, which is not in the tree.

What the driver does instead: it binds `TC_SETUP_FT`, declines offload requests
(`-EOPNOTSUPP`) so the kernel software fast path stays correct, and an out-of-tree
agent writes flows when conntrack approves them. Kernel patching is deferred.

**Task 9a status: 100%** (summary written 2026-11-19). The upstream patch and
kernel patching are deferred by decision, not done.

## Where the models disagree

| Linux (`nf_flow_table`, `TC_SETUP_FT`) | OCTEON NPU firmware as observed here |
|---|---|
| The stack hands the driver a complete 5-tuple, egress device and next-hop MACs in one synchronous `FLOW_CLS_REPLACE` per direction. | A microflow slot can only be written after the firmware has *named* it: a punted frame carries a candidate id, and `FLOW_CREATE_FP` must reuse live `fw_valid=1`, `state=0` candidates. A tuple cannot be written on its own. |
| A flow is offloaded when the stack decides, independent of traffic. | Candidates appear only while the offload gate is open and traffic is flowing (about 20s before an established candidate). Only reply-direction candidates were offered. |
| Egress is an `ifindex`. | The next hop's `iface` is the NWA port index (`octepN` = N+2), not `lif>>12`. A wrong value stalls all wire RX on that port. |
| One flow entry per direction, removed with `FLOW_CLS_DESTROY`. | One connection entry plus two microflows; release is `CONN_RECLAIM_FP`. Stale slots from a reclaimed connection can punt frames and block fresh candidates. |
| NAT is expressed as header mangle actions. | NAT lives in an 24-byte block inside the connection entry (flags bits 19/20 select DNAT/SNAT). The driver's readback compares it byte for byte. |
| Counters come back through `FLOW_CLS_STATS`. | Hardware counters are global (`rpc_sys_counters`) and per NWA port; there are no per-flow statistics yet. |

## What this driver does

- `ndo_setup_tc` handles `TC_SETUP_FT` and sets `NETIF_F_HW_TC`, so
  `nft ... flowtable ... { flags offload; }` binds on an octep port
  (verified on hardware).
- `FLOW_CLS_REPLACE` parses the tuple, egress device and MACs, logs them and
  returns `-EOPNOTSUPP`. The stack then keeps the flow in the software fast path,
  which is the safe fallback.
- Policy safety lives in `scripts/octep/offload-agent.py`: a candidate pair is
  offloaded only when conntrack shows both directions as replied. The NAT block is
  taken from the conntrack entry.

## What is still missing for a real upstream series

1. **Candidate pairing in the kernel.** `FLOW_CLS_REPLACE` must park the request
   and complete it when the matching candidate arrives (the RX path already tracks
   candidates with their tuples). A pending-request table with a timeout, and
   `-EOPNOTSUPP` on expiry, keeps the software path correct.
2. **Egress mapping.** Resolve `act->dev` to the NWA port index, not the lif.
3. **Per-flow statistics** for `FLOW_CLS_STATS`, which the firmware does not
   expose today.
4. **Two-port validation.** Everything proven so far is a bounce (reply returned
   out the arrival port). Real transit, NAT content on the wire and zero-loss TCP
   have not been tested; they need two cabled wire ports.

## Upstream position

Mainline `octeon_ep` has no `TC_SETUP_FT` handling to my knowledge; this is not
checked against a current tree. This driver is an out-of-tree PF driver for the
XGS NPU, so the practical upstream step is the plumbing patch (features plus
`ndo_setup_tc` plus the decline path), sent as an RFC together with this table, and
the candidate-pairing work after two-port validation.

## Hardware test results (octep1, 2026-11-15)

| Test | Result |
|---|---|
| ICMP bounce, busiest-candidate pick + defer | 4/4 EFFECTIVE, every reclaim `verified=1` |
| Host-terminated TCP offloaded (iperf3, bounce) | Destructive: 424 -> 208 Mbit/s, stalls to 0 in offload windows, 17 retransmits |
| Agent skips flows with a local endpoint (default) | TCP 409 vs 422 Mbit/s baseline, 0 retransmits, 0 offloads |
| `--allow-local` ICMP regression | 2/2 EFFECTIVE |
| Microflow action values | Only FWD (1) and IPS (2) are accepted by the driver; IPS diverts to inspection (counter `#67`, nothing forwarded). Other values return EINVAL. No host-delivery action exists in the ABI |
| SNAT, conntrack-derived NAT block (ICMP, `--allow-local`) | Block correct (nat_src = local address, `snat=1`), conn EFFECTIVE 28/29, reclaim `verified=1` |
| SNAT with real TCP/UDP, guard on (`scripts/tests/octep-nat-offload.sh`) | TCP 404 Mbit/s, 0 retransmits; UDP 200 Mbit/s, 0/777015 lost; 0 offloads, 0 INEFFECTIVE |
| SNAT, TCP forced with `--allow-local` (forward and `-R`) | Block correct 7/7, 0/7 EFFECTIVE (2-21% forwarded); `-R` receiver 126 Mbit/s vs ~400 baseline |
| Forced TCP `-R`, per-second after write, forwarding off/on (no NAT) | Write engages within the first second (46%, 18%, 75% forwarded in that second); the host-terminated flow then collapses to 1-3 frames/s because bounced data never reaches the host. Forwarding sysctls made no difference (0/3 vs 1/3 EFFECTIVE) |
| After reclaim, hot flow slot | Frames count as `CONN_RECLAIMED` (~5s) then `MFLOW_NOT_ACTIVE`, about 32-39k frames/s, all punted to the host; no fresh candidate is offered. The driver only accepts ACTIVE microflow writes, so the agent cannot clear a stale slot |
| Hook run 13 (rollback build, `testlogs/task9-hook-live13.log`) | All `FLOW_CREATE_FP` failed (`-5` x3, `-11` x1) and were rolled back; no stall, 341 Mbit/s over 60s, 83 retransmits. Idle spare slots ignore writes (read-back all zero), so the post-write verify returns -EIO |
| Hook run 14 (live-partner + rollback, `testlogs/task9-hook-live14.record.log`) | Offloaded conn 10000 with reply id 255 (spare), verify passed; 0 Mbit/s for about 3s (client s1-4, 3 retransmits), guard released the flow at +3s, 185 retransmits at s4-5, then slow path about 300 Mbit/s with 0 retransmits to s60. Offload programs but forwards nothing |
| NPU TX queue | `TX_DROP_QUEUE_FULL` 0-6 per second outside a few spikes (435 once); host octep1 shows 0 rx errors/drops |
| Hook runs 15-26 (real LAN host 10.4.4.2 -> 192.168.1.1, TCP, NAT out octep1) | Every run: offload lands on live slot pairs, the NPU forwards 393-1000 `WIRE_TO_WIRE` frames in the first second, then `RX_WIRE` falls to 1-2/s with the microflow state words frozen; the guard releases at +3 s; the client sees ~3 s at 0 Mbit/s and 105-185 retransmits, then ~360-400 Mbit/s on the slow path. Forward and `-R` behave alike |
| Probes that changed nothing (runs 20-25) | Flag bits 16-18 and 22-29, mflow operation bits 24-27, zero NAT ports, `ft_l3_rev=1`, both-direction NAT. Readback confirms the firmware stores every value (conn flags `0x7ff70001`); no `-EIO`, no rollback |
| Ruled out | NHOP iface/MAC/MTU, qdisc (fq_codel, 0 drops), host checksum/TSO/GRO (host checksum offload is off), server TSO/LRO/checksum offload (off on the server), host polling (not on the offloaded path) |
| Most likely cause (unproven) | NPU NAT rewrite leaves the TCP checksum stale (ICMP, which has no pseudo-header, offloaded fine; TCP never has) so the server drops the frames; the server verifies checksums in software |

### Task 9 completion (octep1 only)

| Piece | Status |
|---|---|
| Gate and candidate discovery | 100% |
| Flow write (next hops, `FLOW_CREATE_FP`) | 100% |
| Release and reclaim | 100% (all `verified=1`) |
| Lifecycle agent with conntrack policy check | 100% for bounce, soaked 5/5 |
| Local-flow guard (TCP/UDP safety) | 100% |
| Non-NPU-source guard (source behind a host NIC such as the management port) | 100%: live, `skip offload` printed, no write, flow stayed in software |
| Pairing (spare slot) and NAT block from the matching conntrack entry | Live with the hook (run 2): offloaded within about 10s. Run 5 (host .2 behind octep0, NAT out octep1): every attempt failed with -11 from the microflow candidate pre-check; no offload landed |
| Host delivery for non-NPU sources (`--egress-host`) | Experiment, untested: the ABI has no host-delivery action, so the NPU may be unable to hand a reply to a host NIC |
| Port-to-port forwarding on hardware | Proven with ICMP bounce, 4/4 EFFECTIVE |
| Real conntrack-approved transit | **0% (corrected 2026-11-19: the NPU has never sustained forwarding; 1 to 8 s per run, then the reply microflow ts freezes and the host path carries the rest. The 62 and 0 retry runs were host-path results.)** Earlier note, About 85% (hook runs 42-45, 2026-11-16): root cause found and fixed — `mflow_timeout` was hardcoded to 244141 (~2.8 days in the firmware's seconds unit), causing near-instant self-invalidation; `ft_mflow_timeout` param (default 60) fixed that, then a second firmware bug (microflow still expires after ~75-90s under continuous active traffic) was worked around with a proactive re-arm (`ft_mflow_rearm`, default 20s, re-issues `MFLOW_PROGRAM` per live connection before firmware can age it out). Live result: a fresh TCP connection ran 308s with zero retransmits at 367 Mbit/s average (vs ~300 Mbit/s host-softpath baseline), after one stall at the old ~60s mark. Remaining: longer soak (>400s), multiple concurrent connections, confirm WIRE_TO_WIRE sustains (not just a brief spike), and NAT/DNAT transit combined with the fix. See CHANGELOG 2026-11-16 |
| NAT SNAT | About 55%: block derived from the matching conntrack entry, ICMP EFFECTIVE; TCP wire content unverified |
| NAT DNAT | 0%, not run |
| Failed-write rollback and black-hole guard | 100%: runs 13 and 14, no stall beyond the 3s guard window |
| In-kernel flowtable hook | About 55%: loads and runs live. Fixed: NHOP iface = LIF + 2, conntrack-direction roles. Stall gone (run 5: 423 Mbit/s over 160s, 0 retransmits) but offload does not engage (-11, spare candidate has no frames). Diagnostics added; next run names the failing step |
| Automated recovery (wedged and module-gone) | Module-gone restart proven live (22:53:04, about 30s after `rmmod`); wedged-NPU timer path not yet run on hardware. Known limit: `--wedged` refuses a bus reset when another PCI function shares NPU bus 0000:01 (deliberate safety guard); every deploy still recovered in 126-209 s through the status timer's `--auto` path, before the 300 s backstop |
| Final commit and install (scrubbed logs, `install.sh --replace-managed`, sudoers removal) | TBC |

Overall about 58%. Item 7 is 0%: the hook and flow write run live, but the NPU forwards for only 1 to 8 s per flow and nothing is proven sustained; the low retry counts (62, 0) came from the host path.

Full-NAT findings: a source behind a non-NPU port stalls each write until the lease reclaim (every offload of such a flow stalled iperf 8-10s; 1.50 GB against 3.09 GB with no write), so the agent keeps those flows in software. A flow whose original source is the appliance itself is a local flow and is skipped; the agent now reports it as `local-flow` instead of `not-in-conntrack`.

Conclusion: offload is valid only for forwarded flows (neither endpoint local), with the egress on an NPU wire port.
Host-terminated TCP stays in software. Forwarded TCP/UDP and NAT wire content remain untested and need a second host on the wire side.
Test scripts: `scripts/tests/octep-tcp-offload.sh` (TCP), `scripts/octep/offload-agent.py --allow-local` (ICMP bounce only).
