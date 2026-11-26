# OCTEP Linux Driver and Install Tools

This project contains the Linux OCTEP driver source, DKMS configuration,
installer, service scripts, and clean-install instructions for the tested
OCTEON TX NPU appliance. It is not a complete Linux image or a general-purpose
installer for every OCTEON or XGS appliance.

The current boot-verified configuration is Fedora 44 with kernel
`7.3.3-200.fc44` on the tested appliance. Debian/Linux Mint and other
appliances or kernel versions need separate testing. Debian, openSUSE, and
Arch Linux have booted on the appliance, but full NPU functionality remains a
work in progress. XGS 136 uses a different Armada platform; SFP cage operation
and hardware acceleration are not verified. NPU flow offload is opt-in and
experimental; see [docs/npu-flow-offload.md](docs/npu-flow-offload.md). The installed
bring-up service enables it at every boot (`offload-enable.sh`); check with
`/usr/local/xgs/linux/scripts/octep/offload-check.sh`.

The optional NAT helper is under `scripts/nat/`. It is not invoked or installed
by `install.sh`; it adds NAT rules only when explicitly run and confirmed.

Project page: <https://turtle2a.github.io/xgs-octeon-linux/>

Keywords: OCTEON TX, OCTEP, Linux NPU driver, DKMS, XGS 2300, XGS 3300, Fedora, Debian,
Linux Mint, network appliance, NAT router, flow offload, nftables, kea DHCP.

## Hardware Compatibility

| Appliance or family | Status | Notes |
| --- | --- | --- |
| XGS 2300 | Tested for OCTEP startup | Fedora 44, kernel `7.3.3-200.fc44`; ten front-port interfaces were observed. This does not verify SFP cages or hardware acceleration. |
| XGS 3300 | Unverified candidate | Do not assume compatibility from the model name. Confirm the OCTEON TX PCI ID, firmware/NWA interface, and port mapping, then test on the appliance. |
| Other OCTEON TX appliances | Unverified candidates | The installer expects PCI vendor/device `177d:a300`; matching that ID alone does not establish firmware, port-map, or full hardware compatibility. |
| Armada appliances (XGS 87 to 138) | Installer option available, not validated | `install.sh --allow-untested-platform`. Armada needs vendor drivers that are not included, so the NPU ports will not appear. See [appliances/](appliances/). |

The optional NAT helper is currently specific to the tested port layout: WAN
choices are physical ports 2 and 4. Check the target appliance's port mapping
before using it; it does not configure other models automatically.

The NPU-bearing appliances found in the vendor property spec files (Octeon, Armada and
others) are listed in [docs/compatible-appliances.md](docs/compatible-appliances.md).
It is an inference from spec files, not a test result: use it at your own risk.

## Vulnerabilities

Brief: the router was reviewed for security. Medium and High findings were fixed without changing how
the appliance operates (NAT, DHCP, NPU offload all unchanged). Low findings and platform limits are
documented and accepted. Everything lives in the [`vulnerabilities/`](vulnerabilities/) tree.

| Area | Where |
| --- | --- |
| Changes, options, test results, assessment table, risk register (R1-R17) | [vulnerabilities/docs/vulnerability-mitigation.md](vulnerabilities/docs/vulnerability-mitigation.md) |
| Review findings | [docs/security-review.md](docs/security-review.md) |
| Stub and `--live` test script | `vulnerabilities/scripts/xgs-hardening-test.sh` |
| IOMMU strict-mode test script | `vulnerabilities/scripts/octep-iommu-strict-test.sh` |

| Risk | Status |
| --- | --- |
| WAN reaching LAN or management (R2), LAN reaching router services (R3), NPU network attack (R4) | Fixed |
| Flood and malformed traffic (R6) | Optional `xgs-hardening` service |
| OS and kernel updates (R9, R10) | Fixed (auto-update) |
| NPU DMA (R5), CPU side channels (R7), unpatchable BIOS and NPU firmware (R8) | Accepted |
| ssh and RDP open to the WAN (R13) | Open, awaiting decision |

## Installation (in order)

1. **Check the requirements.** Matching kernel headers (`linux-headers-$(uname -r)`
   on Debian/Mint, `kernel-devel` on Fedora) and root access. See
   [Install Requirements](docs/install-requirements.md). The installer itself
   installs `dkms`, build tools, `kmod`, `iptables` and the Kea DHCP server
   (`kea-dhcp4-server` on Debian/Mint, `kea` on Fedora) if they are missing; it
   never installs or upgrades the kernel.
2. **Configure the boot loader** (PCI bus and serial console settings):
   [Boot Loader Requirements](docs/boot-loader-requirements.md). `install.sh`
   merges any missing options into `/etc/default/grub` (backup first;
   `XGS_BOOT_EDIT=0` skips), so this is only needed before moving a donor disk.
3. **Clone and install:**

   ```sh
   git clone https://github.com/turtle2a/xgs-octeon-linux.git
   cd xgs-octeon-linux
   sudo sh ./install.sh
   ```

   The installer prints nine numbered steps with timestamps
   (`[3/9] compiling the OCTEP module ...`). The module compile, the DKMS
   build and the initramfs update are slow and can each take a minute or more;
   that is normal, the current step is always shown.

   Re-running over an existing install: if the installer stops with
   `refusing to overwrite a different file: <path>`, a managed file under
   `/usr/local/xgs/linux` or `/etc` was changed by hand. Check the file, then
   rerun with `sudo sh ./install.sh --replace-managed`, which replaces the files
   the installer manages (your edits to them are lost).

   The installer checks the NPU PCI ID. On an Armada (`11ab:7080`) or OCTEON TX2
   (`177d:b200`, `177d:b100`) appliance it prints a disclaimer and stops, because
   those need vendor drivers that are not in this project. `sudo sh ./install.sh
   --allow-untested-platform` continues anyway; that is untested and the NPU
   ports will not appear.
4. **Reboot**, then verify:

   ```sh
   systemctl status xgs-octep-sdp-bringup.service --no-pager
   dkms status -m xgs-octep -v 0.1.2 -k "$(uname -r)"
   ip -o link show | grep -E ': octep[0-9]+:' | wc -l
   ```

   Expected: bring-up service `active (exited)` and ten `octep` interfaces
   (`octep0` through `octep9`). Physical port N maps to `octep(N-1)`. Test
   copper links separately. SFP cage operation and hardware acceleration are
   not verified by this startup test.
5. **Router use:** plug the WAN into faceplate Port 2 and the LAN clients into
   the other ports. NAT, DHCP and the firewall rules are set up by the
   installer; see [NAT, DHCP and firewall](#nat-dhcp-and-firewall).

### Offline alternative: copy a test bundle instead of cloning

From this directory on the source machine, create a temporary bundle of this
Linux install folder, excluding Git metadata and compiled kernel artifacts:

```sh
tar -czf "$HOME/xgs-linux-test.tar.gz" \
  --exclude='.git' \
  --exclude='*.o' --exclude='*.ko' --exclude='*.mod' \
  --exclude='*.mod.c' --exclude='*.cmd' \
  --exclude='Module.symvers' --exclude='modules.order' \
  .
```

Copy the archive to the test machine using USB or another trusted method. Use a
separate machine or spare SSD so the working installation remains available as
a fallback.

Then extract it on the test machine and run the same installer:

```sh
mkdir -p "$HOME/xgs-test"
tar -xzf "$HOME/xgs-linux-test.tar.gz" -C "$HOME/xgs-test"
cd "$HOME/xgs-test" && sudo sh ./install.sh
```

## Uninstall

From a local console, run:

```sh
sudo /usr/local/xgs/linux/uninstall.sh
```

The script stops and disables this installer's systemd units and removes its
OCTEP DKMS registration across kernels. It removes installed files only when
they still match the managed versions, preserving locally modified files. It
does not remove OS packages or local health data, and it does not forcibly
unload a running module; reboot to complete removal if OCTEP is still loaded.

This uninstaller is scoped to the OCTEON TX `xgs-octep` installation described
here. It does not remove or manage XGS 136 (Armada) software or other NPU
families. Those need their own validated installation and removal paths.

## NAT, DHCP and firewall

The installer sets up the router functions automatically:

- **NAT:** every LAN port is NATed out **Port 2 (WAN)**, which is `octep1`.
  Faceplate Port N is interface `octep(N-1)`. `xgs-nat.service` applies this at
  every boot (iptables masquerade plus a policy route, table 100, so LAN
  traffic uses the WAN even if another uplink has a lower-metric default
  route; the gateway is read from the WAN's DHCP default route).
- **LAN addressing:** `scripts/nat/xgs-lan.sh` (run by `xgs-nat.service`)
  gives each LAN port its router address: `octep0` = `10.4.4.10/28`, `octepN`
  (N = 2 to 9) = `10.4.(10+N).10/28`, through NetworkManager profiles or plain
  `ip addr` when NetworkManager is not running.
- **DHCP:** the Kea DHCPv4 server (installed by `install.sh`, config
  `/etc/kea/kea-dhcp4.conf`) serves `.2`-`.9` on each LAN `/28`. A distro
  default config is kept as `/etc/kea/kea-dhcp4.conf.dist`. Static leases go
  in `/etc/kea/xgs-reservations.json`.
- **Firewall:** if `ufw` is active, the installer allows inbound traffic on the
  LAN octeps and `enp2s0`, and, when ufw forwards are dropped by default,
  routes from each LAN octep to `octep1`. Without ufw nothing is added.

`octep1` (WAN) and the management port `enp2s0` are never reconfigured; set
them up yourself (WAN via DHCP is typical). `enp2s0` is the out-of-band management port; see
[docs/install-requirements.md](docs/install-requirements.md) for how to give it an address.

If you only have the WAN gateway and don't want `enp2s0` (management) NATed out the WAN, put `MGMT_NAT=0` in `/etc/xgs-nat.conf` and run `sudo systemctl restart xgs-nat`; the LAN ports are still NATed.

Optional scripts in `/usr/local/xgs/linux/scripts/nat/` (run with `sudo`):

| Script | Result |
| --- | --- |
| `xgs-nat.sh start` | Default: LAN and management subnet out Port 2 (`octep1`) |
| `nat-port4.sh` | Same, but out Port 4 (`octep3`) |
| `nat-off.sh` | No NAT |
| `xgs-nat.sh stop` | Remove NAT and the policy routes |

To keep NAT off across reboots run `sudo touch /etc/xgs-nat-off`. Overrides
(`WAN=`, `GW=`, `LAN_NETS=`, `MGMT_NET=`, `MGMT_IF=`) go in `/etc/xgs-nat.conf`.

## Automatic system updates

`install.sh` installs a cron job (`/etc/cron.d/xgs-auto-update`) that runs
`xgs-auto-update.sh` as root at **05:00 and 13:00** daily. It works on Fedora
(`dnf`), Debian/Ubuntu/Mint (`apt`) and Arch (`pacman`), never prompts, and never reboots.

- **Kernel is held back** (`kernel*` on dnf; `linux-image`, `linux-headers`
  and similar on apt) because the OCTEP driver is built for the running
  kernel. If a reboot is needed, only `reboot required` is logged.
- Log: `/var/log/xgs-auto-update.log`. A lock prevents overlapping runs.
- Preview without changing anything: `sudo DRY_RUN=1 /usr/local/xgs/linux/scripts/xgs/xgs-auto-update.sh`
- Switch off or on: `sudo /usr/local/xgs/linux/scripts/xgs/xgs-auto-update-ctl.sh disable|enable|status`
  (creates or removes `/etc/xgs-auto-update-off`).
- Overrides in `/etc/xgs-auto-update.conf`: `DNF_EXCLUDE`, `APT_SKIP`, `PACMAN_IGNORE`.
- On Arch, `pacman -Syu` ignores `linux*` kernels (`PACMAN_IGNORE`); only full syncs are run, never partial.
- On Debian-based systems `needrestart` runs in list-only mode, so services
  are not restarted automatically.
- `install.sh` installs and enables `cronie` (dnf) or `cron` (apt) if missing.

## Performance Testing and Scripts

Layout (Linux):

```
octep/            OCTEP kernel driver (octep.c, Makefile)
scripts/
  boot/           boot-option merge and CPU/DMA boot profiles
  nat/            NAT, DHCP and LAN/WAN port routing
  npuctl/         NPU management-link helper
  octep/          port bring-up, offload enable, health checks
  xgs/            auto-update and NPU run helpers
  tests/          performance and offload tests
docs/             install, boot loader and offload notes
```

Test scripts live in `scripts/tests/`. A one-line summary of each is in
[Performance Testing and Scripts/README.md](Performance%20Testing%20and%20Scripts/README.md).

## Pre-Upload Test Record

Running the uninstaller is optional and is not required to upload the source.
Use it only when intentionally removing this installer's managed runtime from a
test system before reinstalling. It does not remove the source tree or create a
provenance report by itself.

For a reproducible pre-upload test record, save the uninstaller output if used,
then record the distribution, running kernel, DKMS result, service state,
interface count, and relevant boot logs after installation. For example:

```sh
cat /etc/os-release
uname -a
dkms status -m xgs-octep -v 0.1.2 -k "$(uname -r)"
systemctl status xgs-octep-sdp-bringup.service --no-pager
ip -o link show | grep -E ': octep[0-9]+:' | wc -l
sudo journalctl -b -u xgs-octep-sdp-bringup.service \
  -u xgs-octep-sdp-status.service --no-pager
```

Keep the saved test record with the tested source/archive and clearly identify
the distribution and kernel. Do not describe other distributions, kernels,
SFP cages, or hardware acceleration as tested unless they were verified
separately.

## Failure Logs

If bring-up fails, collect the service and kernel logs:

```sh
sudo journalctl -b -u xgs-octep-sdp-bringup.service \
  -u xgs-octep-sdp-status.service --no-pager
sudo journalctl -k -b --no-pager > "$HOME/kernel-log.txt"
```

Record the distribution and `uname -r` with the results. The currently
boot-verified combination is Fedora 44 with kernel
`7.3.3-200.fc44`; other distribution and kernel combinations require their own
clean-install test.

## License

This project is licensed under the GNU General Public License, version 2 or
(at your option) any later version. See [LICENSE](LICENSE). Source files use
the SPDX identifier `GPL-2.0-or-later`.

The following file carries portions derived from
[os-xgs-npu](https://github.com/AbdelmonemAwad/os-xgs-npu), which is
BSD-2-Clause licensed. The notice is at the top of the file and the licence
text is in [LICENSES/BSD-2-Clause-os-xgs-npu.txt](LICENSES/BSD-2-Clause-os-xgs-npu.txt):

- `octep/octep.c`
