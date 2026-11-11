# OCTEP Linux Driver and Install Tools

This project contains the Linux OCTEP driver source, DKMS configuration,
installer, service scripts, and clean-install instructions for the tested
OCTEON TX NPU appliance. It is not a complete Linux image or a general-purpose
installer for every OCTEON or XGS appliance.

The current boot-verified configuration is Fedora 44 with kernel
`7.3.3-200.fc44` on the tested appliance. Debian/Linux Mint and other
appliances or kernel versions need separate testing. XGS 136 uses a different
Armada platform; SFP cage operation and hardware acceleration are not verified.

The optional NAT helper is under `scripts/nat/`. It is not invoked or installed
by `install.sh`; it adds NAT rules only when explicitly run and confirmed.

Keywords: OCTEON TX, OCTEP, Linux NPU driver, DKMS, XGS 3300, Fedora, Debian,
Linux Mint, network appliance.

## Hardware Compatibility

| Appliance or family | Status | Notes |
| --- | --- | --- |
| XGS 3300 | Tested for OCTEP startup | Fedora 44, kernel `7.3.3-200.fc44`; ten front-port interfaces were observed. This does not verify SFP cages or hardware acceleration. |
| XGS 2300 | Unverified candidate | Do not assume compatibility from the model name. Confirm the OCTEON TX PCI ID, firmware/NWA interface, and port mapping, then test on the appliance. |
| Other OCTEON TX appliances | Unverified candidates | The installer expects PCI vendor/device `177d:a300`; matching that ID alone does not establish firmware, port-map, or full hardware compatibility. |
| XGS 136 | Not supported by this installer | It uses an Armada platform and needs a separate Linux implementation. |

The optional NAT helper is currently specific to the tested port layout: WAN
choices are physical ports 2 and 4. Check the target appliance's port mapping
before using it; it does not configure other models automatically.

## Boot Loader Configuration

See [Boot Loader Requirements](docs/boot-loader-requirements.md) for the GRUB
PCI-bus and serial-console settings, distro-specific regeneration commands,
and the BSD `bootloader.conf` note.

## Installation and Clean-Install Test

See [Install Requirements](docs/install-requirements.md) for supported system
prerequisites, matching kernel headers/build files, and package setup.

## Prepare a Clean-Install Test Bundle

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

## Install and Verify

On the test machine, extract the archive and run the installer:

```sh
mkdir -p "$HOME/xgs-test"
tar -xzf "$HOME/xgs-linux-test.tar.gz" -C "$HOME/xgs-test"
cd "$HOME/xgs-test"
sudo sh ./install.sh
```

Reboot, then verify the service and front-port interfaces:

```sh
systemctl status xgs-octep-sdp-bringup.service --no-pager
dkms status -m xgs-octep -v 0.1.2 -k "$(uname -r)"
ip -o link show | grep -E ': octep[0-9]+:' | wc -l
```

Expected results are a bring-up service state of `active (exited)` and ten
`octep` interfaces (`octep0` through `octep9`). Physical port N maps to
`octep(N-1)`. Test copper links separately. SFP cage operation and hardware
acceleration are not verified by this startup test.

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

## Optional NAT Helper

`scripts/nat/nat-options.sh` is an optional, manually run helper. It is not
installed, enabled at boot, or invoked by `install.sh`; no installer or
`rc.local` changes are made.

Run it from this source directory:

```sh
sudo sh scripts/nat/nat-options.sh status
sudo sh scripts/nat/nat-options.sh apply
sudo sh scripts/nat/nat-options.sh undo
```

`status` is read-only. `apply` offers only physical port 2 (`octep1`) or
physical port 4 (`octep3`) as WAN, with port 2 as the default, and prompts for
one or more LAN IPv4 CIDRs. Other OCTEP ports remain LAN and are not matched by
the NAT rules. The helper previews the rules and requires the user to type
`APPLY` before adding a dedicated `ip xgs_nat` nftables table. It adds IPv4
source-NAT rules only; it does not add firewall/filter rules, configure
NetworkManager, enable IP forwarding, or create port forwards.

Only one WAN is selected per apply. To switch WANs, run `undo` and then `apply`
again with the other physical port. This helper does not implement automatic
failover; NetworkManager routing must be configured separately if desired.
IPv4 forwarding must already be enabled. Rules are runtime-only and are not
restored automatically after reboot.

`undo` requires the user to type `UNDO` and removes only the dedicated table
recorded as created by this helper. It refuses to delete an unrecognized table
and leaves all other nftables tables and NetworkManager settings untouched.
Do not run `apply` on a working appliance until the WAN ports, LAN subnets,
routing, and rollback procedure have been reviewed.

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
