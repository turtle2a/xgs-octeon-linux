# SFP cage issues

Host: XGS 2300 (OCTEON TX). Per-attempt detail is in the maintainer's local changelog (entry C1 and the SFP entries on 2026-11-19).

| # | Severity | Issue | Value / evidence | Status |
|---|----------|-------|------------------|--------|
| S-1 | 🟡 Medium | SFP cages pass no frames although firmware reports link | SFP1 = octep8 (tag 35072), SFP2 = octep9 (tag 35328). Tag 35072 link word reads 1 with a copper converter plugged and 0 unplugged; tag 35328 stays 0 (no module light). octep8 rx stays flat at 25, DHCP unanswered | Open, awaiting spare modules |
| S-2 | ⚪ Low | Transceiver compatibility is unknown | Vendor spec gives no compatible list (only SFP-GE-T, SFP-10G-T, 10G-SFP+-T, SR/SX seen on other units); module EEPROM is on the coprocessor I2C and unreadable by the host. Theory (unproven): converter or module mode mismatch | Open |
| S-3 | 🟠 High | Wrong cage map renumbers all ports | `CAGE_MAP="10:0 11:32768"` made octep10 and octep11 (tags 0 and 32768, flags stay 0x0000, rx 0). Those are SoC ports, not the cages. Every other port moved up by 2, and MAC-pinned NetworkManager profiles and NAT lost their ports | Withdrawn (C1). Repo keeps `10:1 11:2`; `CAGE_MAP` needs no change. Reinstall the repo `rpc-port-setup.sh` where the test copy was deployed |
| S-4 | ⚪ Low | NetworkManager profiles SFP1 and SFP2 target the wrong ports | Must be retargeted to octep8 and octep9 (octep8 already carries a LAN address from `xgs-lan.sh`) | Open |

Next test, no code change: swap one module at a time (copper converter vs fibre, SFP vs SFP+ cage), read the tag link word, then rx on octep8 and octep9. Verify offload is on before any traffic test.
