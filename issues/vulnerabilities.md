# Vulnerability issues

Source: [vulnerabilities/docs/vulnerability-mitigation.md](../vulnerabilities/docs/vulnerability-mitigation.md)

| ID | Sev | Risk | Correction | Status | Outstanding |
|----|-----|------|------------|--------|-------------|
| R1 | 🟡 | Planted file or symlink makes a root test script run commands | Root-only backup dir; inputs validated | ✅ Fixed, stub test pass | - |
| R2 | 🟡 | WAN host reaches LAN or management hosts | Per-subnet NAT; `XGS-FWD` drops new WAN-initiated traffic | ✅ Fixed, live pass | - |
| R3 | 🟡 | LAN host reaches services on the router | ufw allows only DHCP on LAN ports (`XGS_UFW_LAN_DHCP_ONLY=0` for testing) | ✅ Fixed for new installs; test host left open | nmap scan |
| R4 | 🟡 | Compromised NPU attacks the host over its link | ufw on the NPU link `enp1s0` (not `mvmgmt0`, a macvlan on `enp2s0`): only NPU address to host; no forwarding | ✅ On the test host: NPU reaches 169.254.254.1, other host addresses blocked. Forwarded ICMP still passes (ufw `before.rules`); forwarded TCP not yet tested | Move installer rules and the `mgmt-link.sh` default from `mvmgmt0` to `enp1s0`; run the TCP forward test |
| R5 | 🟠 | NPU reads or writes host memory by DMA | `iommu=pt` removed from boot options: all 14 IOMMU groups, including the NPU's, are translated (`DMA-FQ`) | ✅ Fixed on the test host: boots, rings armed, 40 s iperf (about 300 Mbit/s, every packet through NPU DMA) with 0 `IO_PAGE_FAULT`, offload enabled | NPU-offloaded forwarding under translation is not proven (item 7 stall); restore `iommu=pt` if faults appear |
| R6 | ⚪ | Flood or malformed TCP | Optional `xgs-hardening` service | Optional | - |
| R7 | 🟡 | CPU side channels (`spectre_v2=off`, `spec_rstack_overflow=off`, left from the vendor install) | `spec_rstack_overflow=off` removed (Safe RET active). `spectre_v2` is a speed trade-off left to the operator (the installer does not change boot options) | 🔶 Test host runs `spectre_v2=off` by choice. Host-path iperf (40-60 s, same IOMMU-translated boot): 293-294 Mbit/s with it on, 341 with it off; 362-368 with everything off and `iommu=pt`. Offload stalls after 1 s in all runs (item 7) | Optional: test `spec_rstack_overflow=off` to explain the last ~6% |
| R8 | ⚪ | Unpatchable BIOS and NPU firmware | Distro microcode and kernel updates; NPU isolated (R4, R5) | Accepted | - |
| R9 | 🟡 | Unpatched OS or kernel | Auto-update cron including kernels | ✅ Fixed | - |
| R10 | 🟡 | Auto-update breaks the `octep` module | Old kernel stays bootable; check `dkms status` first | ✅ Fixed | - |
| R11 | ⚪ | `octep` RX length handling | Clamp patch kept, not applied | Deferred | - |
| R12 | ⚪ | NPU ssh host key trust, passwordless console | Link isolated (R4) | Accepted | - |
| R13 | 🟠 | ssh (22) and RDP (3389) open to any address, including the WAN | Restrict to the management subnet | ⚪ Accepted on the test host: left as is, ufw-managed (3389 is the admin session path). Optional script for other users | `xgs-ufw-admin.sh` (dry run by default) |
| R14 | 🟡 | Changing `CAGE_MAP` renumbers ports; breaks MAC-pinned profiles and NAT | Repo default `10:1 11:2` | ✅ Fixed, verified after reboot | - |
| R15 | 🟡 | SELinux disabled (`selinux=0`); enabling it hung the boot | None | ⚪ Accepted on the test host: enabling it stops the boot | Cause unknown; revisit with serial-console access |
| R16 | ⚪ | SMAP disabled (`clearcpuid=smap`, vendor option) | None yet | 🔴 Open | Test removal |
| R17 | 🟠 | NPU root ssh key `/etc/keys/mvmgt.x86` was world-readable (0644); ssh also refused it, forcing the serial-console fallback | `chmod 600`; installer sets it | ✅ Fixed on the test host and in the installer | None |
