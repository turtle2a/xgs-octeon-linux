# OCTEP Linux Driver and Install Tools

This project contains the Linux OCTEP driver source, DKMS configuration,
installer, service scripts, and clean-install instructions for the tested
OCTEON TX NPU appliance. It is not a complete Linux image or a general-purpose
installer for every OCTEON or XGS appliance.

The primary appliance is the XGS 2300: the install is validated on it with
Fedora, Debian and Linux Mint. The XGS 3300 is not yet verified with Linux (it
is expected to work, but that is untested). Other appliances or kernel versions
need separate testing. openSUSE and Arch Linux have booted on the appliance, but
full NPU functionality remains a work in progress. XGS 136 uses a different
Armada platform; SFP cage operation and hardware acceleration are not verified.

By default all LAN ports are NATed out faceplate Port 2 (`octep1`); see
[NAT](#nat-default-all-lan-ports-out-port-2).

Keywords: OCTEON TX, OCTEP, Linux NPU driver, DKMS, XGS 2300, XGS 3300, Fedora, Debian,
Linux Mint, network appliance.

## Hardware Compatibility

| Appliance or family | Status | Notes |
| --- | --- | --- |
| XGS 2300 | Install validated | Fedora, Debian and Linux Mint install verified by the maintainer. SFP cages and hardware acceleration are not verified. |
| XGS 3300 | Not yet verified | Expected to work but untested with Linux by the maintainer. Earlier development boots on Fedora 44 (`7.3.3-200.fc44`) are not a validated install. |
| Other OCTEON TX appliances | Unverified candidates | The installer expects PCI vendor/device `177d:a300`; matching that ID alone does not establish firmware, port-map, or full hardware compatibility. |
| XGS 136 | Not supported yet by this installer | Armada support requires a separate Linux implementation and hardware validation before it can be supported. |


## Boot Loader Configuration

See [Boot Loader Requirements](docs/boot-loader-requirements.md) for the GRUB
PCI-bus and serial-console settings and distro-specific regeneration commands.

## Installation and Clean-Install Test

For a GitHub install, clone the project:

```sh
git clone https://github.com/turtle2a/xgs-octeon-linux.git
cd xgs-octeon-linux
```

Review the install requirements below, then run `sudo sh ./install.sh` from
the project root.

For router use, NAT out faceplate Port 2 is on by default. See
[NAT](#nat-default-all-lan-ports-out-port-2).

See [Install Requirements](docs/install-requirements.md) for supported system
prerequisites, matching kernel headers/build files, and package setup.
See [OCTEP Diagnostics and Debugging](docs/debugging.md) for optional kernel
log capture and dynamic-debug instructions.

### Remote access before attaching the donor disk

Before attaching the donor disk, configure SSH and XRDP access as described in
[Before Attaching the Donor Disk to the Appliance](docs/install-requirements.md#before-attaching-the-donor-disk-to-the-appliance).

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

For a read-only check of driver and SDP packet-path readiness, run:

```sh
sudo /usr/local/xgs/linux/scripts/xgs/accel-status.sh
```

The optional script also supports explicit runtime gate requests:

```sh
sudo /usr/local/xgs/linux/scripts/xgs/accel-status.sh on
sudo /usr/local/xgs/linux/scripts/xgs/accel-status.sh off
```

`on` and `off` write the firmware offload gate through the OCTEP RPC interface;
they are not run by the installer and are not persisted across a coprocessor
reset. The Linux driver writes the documented TCP sequence-check setting with
the offload bit (`0x0003` for on, `0x0002` for off). The firmware has no
read-back for this word, so the status reports the last request acknowledged
by the coprocessor, or `unknown` until this driver has received an
acknowledgement. Gate-on only permits offload; it does not install routes or
flow entries and does not prove any traffic is being accelerated. Use from a
local console with a recovery path, since changing the gate can affect packet
handling.

When run with `sudo`, each report line is also written to the kernel log; view
it with `sudo dmesg | grep xgs-accel-status`.

### NPU flow offload (optional, disabled by default)

Hardware flow offload is **off** after install and after every boot, until the
stall tracked as Task 9 item 7 is fixed: the module loads with `flow_offload=N`,
the write gate stays closed, and all routed traffic takes the host path.
Forwarded TCP flows that the NPU takes over can stall until the driver's guard
releases them, so enable it only for testing. To opt in, uncomment
`options octep flow_offload=1` in
`/etc/modprobe.d/xgs-octep.conf`, reload the module, then run
`sudo /usr/local/xgs/linux/scripts/octep/offload-enable.sh` (add it as an
`ExecStartPost` of `xgs-octep-sdp-bringup.service` to repeat it at boot).

## Optional Transit Throughput Test

`scripts/tests/iperf-transit-test.sh` is a standalone test-host utility; the
installer does not install or run it. Set up an `iperf3` server on a test host
on the far side of the appliance, and run the script from another test host
so traffic traverses the OCTEON ports. First set the gate off on the appliance,
then run the baseline from the test client:

```sh
sudo /usr/local/xgs/linux/scripts/xgs/accel-status.sh off
./scripts/tests/iperf-transit-test.sh <iperf3-server> off
```

Set the gate on from the appliance, then repeat the same test from the client:

```sh
sudo /usr/local/xgs/linux/scripts/xgs/accel-status.sh on
./scripts/tests/iperf-transit-test.sh <iperf3-server> on
```

The second argument labels the gate state; the test script does not change it.
Keep the test client and server on separate networks with the appliance between
them; traffic to or from the appliance itself is not a transit-flow test. Use a
test network and keep a local recovery path. The script runs one TCP stream in
each direction for 10 seconds by default (up to 60 seconds can be specified).
Throughput comparison alone does not prove hardware offload; the current Linux
driver reports NPU per-flow byte counters through `flow_stats`. The
`scripts/tests/octep-accel-telemetry-test.sh` checks that those counters advance
during traffic, but cannot yet correlate a reported counter to the iperf
five-tuple. Boot-time setup enables host IPv4/IPv6 forwarding, creates OCTEP
front-port netdevs, and requests NPU all-multicast admission on each configured
port. `install.sh` installs `smcroute` and bring-up restarts `smcroute.service`
once the netdevs exist, so the kernel reports `mc_forwarding=1` on every port
(the boot warning appears only if that daemon is missing or fails). These are transport-readiness steps only: Linux multicast-routing state
(`mc_forwarding`) and NPU all-multicast admission do not synchronize multicast
groups/routes or return paths into NPU flow state. Automatic Linux flow
programming, persistent per-flow latching, and route/group-change reconciliation
are not implemented; enabling the global offload gate does not install them.
Multicast and automatic flow offload therefore remain unverified and not ready.

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

## NAT (default: all LAN ports out Port 2)

The install default is fixed: every LAN port is NATed out **Port 2 (WAN)**,
the second port on the faceplate, which is `octep1`. Plug the WAN cable into
faceplate **Port 2**. The `xgs-nat.service` unit applies this at every boot.

Port numbering: faceplate Port N is interface `octep(N-1)`, so Port 2 is
`octep1` and Port 4 is `octep3`.

Optional scripts in `/usr/local/xgs/linux/scripts/nat/` (run with `sudo`;
each prints one line):

| Script | Result |
| --- | --- |
| `xgs-nat.sh start` | Default: LAN out Port 2 (`octep1`) |
| `nat-port4.sh` | LAN out Port 4 (`octep3`) instead |
| `nat-off.sh` | No NAT |
| `xgs-nat.sh mgmt` | Also route `10.1.1.0/28` from `enp2s0` out Port 2 |
| `xgs-nat.sh stop` | Remove NAT and the `mgmt` route |

These are plain iptables rules and are not persistent; `xgs-nat.service`
re-applies the default at boot. To keep NAT off across reboots run
`sudo touch /etc/xgs-nat-off`. NetworkManager is never modified.

Besides masquerading, `start` pins the LAN subnet (default `10.4.4.0/28`) to the
WAN with a policy route (`ip rule ... lookup 100`), so internet traffic is not
sent out another uplink that has a lower-metric default route. The gateway is
read from the DHCP default route on the WAN port (`192.168.1.1` is only a
fallback). To change the WAN port, gateway or LAN subnet, set `WAN=`, `GW=` or
`LAN_NET=` in `/etc/xgs-nat.conf`.

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

Record the distribution and `uname -r` with the results. The install is
validated on the XGS 2300 with Fedora, Debian and Linux Mint (XGS 3300 not yet
verified); other distribution and kernel combinations require their own
clean-install test.

## License

This project is licensed under the GNU General Public License, version 2 or
(at your option) any later version. See [LICENSE](LICENSE). Source files use
the SPDX identifier `GPL-2.0-or-later`.
