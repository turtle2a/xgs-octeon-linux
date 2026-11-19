# NPU flow offload issues

Host: XGS 3300 (OCTEON TX). Details and test specs per attempt are in [CHANGELOG.md](../CHANGELOG.md) (entries R16-R25, O1, O2).

| # | Severity | Issue | Value / evidence | Status |
|---|----------|-------|------------------|--------|
| 7 | 🟠 High | NAT'd flows do not stay on the NPU: a stall follows the offload, then the host path carries the traffic | Host path about 367 Mbit/s; 100-142 retries at the 1-2 s dip (115 Mbit/s); `WIRE_TO_WIRE` stays near 450 frames then stops; reply microflow timestamp frozen | Open, parked (R25 last attempt FAIL) |
| 7a | 🟡 Medium | Reply microflow timestamp frozen while the original advances | Reply id 703 frozen at the same value across runs; `bridge_control=14` applied and read back | Open |
| 7b | 🟡 Medium | Possible checksum fault after the NAT rewrite | Test: `ft_offload_nat=1` and compare `nstat TcpInCsumErrors IpInHdrErrors` (about 460 rise confirms) | Untested |
| 9c | 🟡 Medium | SFP cages pass no frames | Mapping works (SFP1 = octep8 in the 10-port layout, tag 35072); rx 0, DHCP unanswered; link word 1 with a copper converter | Open, awaiting test modules |
| F1 | 🟡 Medium | A `CAGE_MAP` change renumbers the `octepN` netdevs and breaks MAC-pinned NetworkManager profiles and NAT | Cages became octep0 and octep1, every other port +2 | Fixed in repo; reinstall the repo `rpc-port-setup.sh` on the test box |
| O1 | ⚪ Low | Offload was off after every boot | Now `ExecStartPost=-offload-enable.sh`; journal shows `OFFLOAD ENABLED`, `offload-check.sh` reads ENABLED | Fixed |
| O2 | ⚪ Low | Offload scripts were not installed; `front_netdevs=10` check hung with 12 netdevs | `install.sh` installs both scripts; check is now `[1-9]` | Fixed |

Rules for any offload test: verify offload is on first (`requested=on acknowledged=yes`), never run iperf from the router, never touch `enp2s0`.
