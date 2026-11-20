# Security review (Task 10)

Scope: kernel module `octep/`, installer, systemd units, NAT/firewall scripts, auto-update cron, helper scripts.
Method: static read-only review. Findings are not yet fixed; none were exploited. No critical or high issues found.
Scores: confidence is the reviewer's, out of 10.

## Findings

| # | Severity | File | Lines | Issue | Fix | Confidence |
|---|----------|------|-------|-------|-----|-----------|
| 1 | Medium | scripts/tests/octep-fastdeploy.sh | 14, 44, 54 | Predictable `/var/tmp/octep.ko.xz.prev`; a planted file or symlink is restored as the root-loaded module | Backup in a root-only dir (`/var/lib/xgs/` or `mktemp -d`), `cp --no-dereference`, refuse symlinks | 8 |
| 2 | Medium | scripts/tests/octep-hook-live.sh | 111, 140-144 | Root evaluates world-writable `/var/tmp/octep-ft-*` files as bash arithmetic (command injection) | Validate values (`case` on digits/hex) or read from a root-owned dir | 8 |
| 3 | Medium | scripts/nat/xgs-nat.sh, systemd/xgs-nat.service | 27-33 | Forwarding on, no default-deny, no rp_filter/iif checks, blanket MASQUERADE | Default-deny FORWARD, `rp_filter=1`, `-i` on rules, scope MASQUERADE to LAN nets | 7 |
| 4 | Medium | install.sh (ufw block) | ~395-410 | Opens all ports on LAN octeps and the mgmt NIC, contrary to install-requirements.md | Allow only DHCP (udp 67) on LAN ports; mgmt access operator-configured | 7 |
| 5 | Low | systemd/xgs-octep-mailbox-compat.service | - | Unhardened root unit runs an uninstalled test script | Do not ship, or harden | 7 |
| 6 | Low | scripts/xgs/xgs-auto-update.sh | 16, 20 | Conf sourced as root; log created with default umask | `umask 077`, `install -m 0640` log, parse KEY=VALUE | 7 |
| 7 | Low | scripts/xgs/xgs-auto-update.sh | 31-61 | Unattended root upgrade; holds miss dkms and kernel meta-packages | Extend holds; consider security-only updates | 6 |
| 8 | Low | scripts/xgs/npu-run.sh, scripts/npuctl/mgmt-link.sh | 20-24, 63-69 | `accept-new` host key; passwordless root console autologin | Pin host key in a `UserKnownHostsFile` | 6 |
| 9 | Low | scripts/nat/xgs-nat.sh, xgs-lan.sh, npu-health.sh | 16, 2, 192 | Root-sourced conf; PATH-resolved binary | Absolute paths; validate values | 6 |
| 10 | Low | kea/kea-dhcp4.conf, install.sh | ~376 | DNS hardcoded to public resolvers; reservations file 0644 | Make DNS configurable; 0640 root:kea | 6 |
| 11 | Low | octep/octep.c | ~2318-2330 | RX `frame_len` cast from a device-controlled u64 | Clamp `wire_len` before the u32 cast | 5 |

## Areas reviewed

| Area | Result |
|------|--------|
| Kernel module memory safety (sysfs/params, reply bounds) | Good; knobs root-only; item 11 is hardening |
| Root scripts and temp files | Fair (items 1, 2) |
| Auto-update (apt/dnf/pacman) | Good; items 6, 7 |
| Installer modes and ownership | Good; run from a root-owned copy |
| Firewall / NAT / exposure of host services | Weak (items 3, 4) |
| Secrets and PII in repo | Good; logs and Ghidra output are untracked, keep them out of release archives |

## Test spec (per fix)

- Items 1, 2: as a non-root user, pre-create the backup symlink or a malicious value file; run the script as root; PASS if nothing outside the intended path is written and no command runs.
- Items 3, 4: from a device on a LAN port, `nmap` the host and try WAN to LAN and LAN to mgmt forwarding; PASS if only DHCP is reachable and forwarding is denied.
- Items 6, 10: `stat -c %a` on the log and reservations files shows 640.
- Offload must be verified ON before any throughput test.

## Re-assessment after fixes (2026-11-20; static and stub tests only, live retest pending)

Scope: only Medium and High findings are addressed (none are High). Low findings (5-11) are recorded above and deliberately left unchanged. Defaults preserve existing behaviour; anything that could alter operation is opt-in. Backup/restore point: `~/backup/<date>/`.

| # | Before | After | Status | Notes |
|---|--------|-------|--------|-------|
| 1 | Medium | Resolved | Fixed | Backup in `/var/lib/xgs` (0700), `cp -P`; injection-free |
| 2 | Medium | Resolved | Fixed | Values validated before arithmetic; guard tested against `a[$(cmd)]` |
| 3 | Medium | Low | Mitigated | Scoped MASQUERADE; `XGS-FWD` chain drops new WAN-initiated traffic to LAN/mgmt; LAN->mgmt block opt-in (`BLOCK_LAN_TO_MGMT=1`); conf values validated. Routing lines unchanged. Both NAT variants (repo, and a variant built from the older script deployed on lill1) pass the stub test |
| 4 | Medium | Low | Fixed for new installs | Default is DHCP-only on LAN ports; `XGS_UFW_LAN_DHCP_ONLY=0` leaves it open for testing (lill1 stays open) |

Live retest (deploy, reboot, offload verified ON first) is in the maintainer's local changelog (S1-S11). The kernel module is untouched.

User guide and options: [vulnerability-mitigation.md](../vulnerabilities/docs/vulnerability-mitigation.md).
