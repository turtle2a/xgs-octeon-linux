# Install Requirements

The installer supports DNF/YUM and APT for missing build tools. It does not
install or upgrade the running kernel or its matching build files.

## Prepare and Transfer the Linux Installation

First perform a full or minimal Linux OS installation onto the donor disk on
another system. This must be an actual bootable OS installation; installing
only libraries or build dependencies on the donor is not sufficient. Before
moving the disk, apply the GRUB settings and regenerate the boot configuration
as described in [Boot Loader Requirements](boot-loader-requirements.md).

Shut down the donor system, remove the prepared disk, and install or attach it
to the XGS appliance. Configure the appliance's firmware or boot selection to
boot from this donor-installed disk. After booting the appliance, complete any
remaining OS setup there, install the matching kernel build files described
below. Copy or extract the Linux project tree onto the appliance. The OCTEP
project installer is `install.sh` at the root of that tree, alongside
`README.md` and the `octep/` directory. From the project root, run:

```sh
sudo sh ./install.sh
```

Or run it by absolute path from another directory, replacing the example path
with the location of the project tree:

```sh
sudo sh /path/to/xgs-octeon-linux/install.sh
```

## Requirements

- A supported OCTEON TX appliance and a Linux system using systemd.
- Root access to install the driver and systemd units.
- Kernel development files matching the running kernel:
  - Fedora, RHEL, Rocky Linux, or AlmaLinux: `kernel-devel` for `uname -r`.
  - Debian or Linux Mint: `linux-headers` for `uname -r`.
- Kernel-module build tools: GCC (`gcc`), `make`, the linker (`ld`, from
  `binutils`), DKMS, and kmod utilities (`modinfo`, `depmod`, and `modprobe`).
- Network access to the distribution's package repositories if the installer
  needs to install missing build tools.

The installer checks for `/lib/modules/$(uname -r)/build/Makefile` before
installing the driver. Do not continue if this file is missing. The installer
can install missing build tools, but it does not install the matching kernel
development files.

Upstream Linux kernel 7.3.3 from kernel.org was used during development because
it contained upstream patches and Marvell-specific libraries. That exact
kernel version is not required. Kernel 7.2.10 was also compiled and used as a
development reference. Build the module against the target system's running
kernel using its matching development files; other kernel versions still
require testing.

## Optional Fedora Kernel-Source Build Environment

These steps are for rebuilding Fedora's kernel from source, not for the normal
OCTEP DKMS install when matching `kernel-devel` files are available. Run
`dnf builddep` from the Fedora kernel source tree containing `kernel.spec`:

```sh
sudo dnf install fedpkg
sudo dnf builddep kernel.spec
sudo dnf install bc binutils bison dwarves
sudo dnf install elfutils-devel
sudo dnf install elfutils-libelf-devel
sudo dnf install gcc make openssl openssl-devel perl python3 rsync
sudo dnf install ccache
```

`ccache` is optional and can speed up repeated kernel builds.

For the optional `make xconfig` interface, the additional packages used were:

```sh
sudo dnf install qt3-devel libXi-devel gcc-c++
```

Package names and availability can vary between Fedora releases.

## Fedora, RHEL, Rocky Linux, and AlmaLinux

On the test machine, install the build files matching its running kernel:

```sh
sudo dnf makecache
sudo dnf install "kernel-devel-$(uname -r)" dkms make gcc binutils kmod
```

Verify the build tree exists:

```sh
test -f "/lib/modules/$(uname -r)/build/Makefile" \
  && echo "Matching kernel build files found"
```

If the exact `kernel-devel` package is unavailable, stop and resolve the
kernel/package version mismatch before running the installer.

## Debian and Linux Mint

Update package lists and install headers for the running kernel:

```sh
sudo apt-get update
sudo apt-get install "linux-headers-$(uname -r)" dkms build-essential kmod
```

The matching headers provide the build tree needed for this external DKMS
module; the separate full `linux-source` package is not required.

Verify the build tree exists:

```sh
test -f "/lib/modules/$(uname -r)/build/Makefile" \
  && echo "Matching kernel build files found"
```

If matching headers are unavailable, stop and resolve the kernel/package
version mismatch before running the installer. The installer uses APT to
install missing tool packages (`dkms`, `build-essential`, and `kmod`).

Linux Mint 22.x is Ubuntu-based; Linux Mint Debian Edition (LMDE) is
Debian-based. Both use APT, but their kernel packages may differ. Always verify
that `/lib/modules/$(uname -r)/build/Makefile` exists before installing.

## Optional Desktop and Remote-Access Setup

These are host-management choices, not OCTEP build or runtime requirements:

### Fedora

- Install and configure MATE with xrdp for remote desktop access.
- Install and configure SSH access.
- Configure `xrdp.ini` to listen on IPv4 where required by the setup.
- KDE Plasma was removed in favor of MATE because it was too resource-intensive.
- Install AMD SMI separately if it is needed for platform monitoring.

### Ubuntu Server

For a lightweight XFCE desktop with xrdp:

```sh
sudo apt update && sudo apt install -y xfce4 xfce4-goodies xrdp
sudo systemctl enable --now xrdp
```

If prompted to choose a display manager, select one appropriate for the
installation; LightDM is a lightweight option. Review `/etc/xrdp/xrdp.ini` for
the desired session and IPv4 listener configuration. Restrict RDP firewall
access to trusted management hosts or networks; check service status with
`systemctl status xrdp` if needed.

These desktop and remote-access steps are optional and do not establish OCTEP
or NPU compatibility. Package names and configuration details may vary by
distribution release and local network setup.
