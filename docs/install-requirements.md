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

**Note:** This XGS appliance was built with kernel 7.3.3, a stable release from
kernel.org. A new configuration was created with all Marvell, Cavium, and other
modules selected, along with debugging modules.

Please contact me via GitHub if you need the configuration added to the Git
tree. It was not required for installation, but was used during development.



## Post Donor Disk Installation - XGS Pre-Installation

For easier access and management of the XGS while its disk is connected to the
donor machine, install and configure the SSH server, or leave it as is. Check
that it is running with `systemctl status sshd.server`.

If UFW is installed, allow access from your LAN to the appliance's LAN subnet.
If DHCP is not running on your LAN, configure the adapter address manually
later from the console, along with the required UFW rules.



## Appliance BIOS Setting Requirements

Before booting the XGS appliance with the connected disk:

Open PuTTY (preferred) or a serial terminal on your PC. Set the baud rate and
stop bits according to the GRUB information provided for accessing the XGS BIOS
(press DEL during boot). For this system, the BIOS baud rate must be 38400.

Do not open the connection until the machine is booting.

Hold the DEL key on your PC until the XGS BIOS screen opens.

Enter the XGS BIOS and ensure Secure Boot is off and VT-d/IOMMU is on.

You can select the boot drive in the BIOS or press ESC during boot to select
it in the serial console (38400 baud). Note that you will need to reconnect the
console at 115200 baud to view the Linux OS boot on the XGS.


## Serial Console Access After BIOS Settings - Booting the XGS

Open the serial console on a machine connected to the XGS appliance via USB
serial. Once the XGS is booted from the donor disk installation, set the baud
rate to 115200 and keep the other settings the same as the GRUB settings.



## Network Setup from the Serial Console on the XGS Appliance

After connecting the disk to the XGS appliance, boot the appliance.

Open the serial console on a machine connected to the XGS appliance via USB
serial, which is now booted from the donor disk installation.

Note: The initial XGS boot screen is available only at 38400 baud for BIOS
access and boot-drive selection. Change the baud rate to 115200 to view the OS
boot and access the login prompt.

A serial console window should open on your machine, displaying the XGS
appliance console.

Log in as the user you set up, then configure the interface.

Connect an Ethernet cable to the port labelled MGMT on the XGS appliance, to
the right-hand side (RHS) of the front USB ports. This is the management port
for setting up the appliance until SSH and XRDP are installed and running. On
Fedora, it should appear as `enp2s0`.

If the LAN to which the cable is connected has a DHCP server, the MGMT adapter
may obtain an address.

Run `ifconfig` to check which adapter (LAN) has an address.

Run `lsof` to check whether the SSH ports are open.

Connect to your SSH server on the XGS appliance.

`ssh -l <yourusername> -p <theportforssh> <xgs-hostname-or-IP>`

If successful, you will be logged in as the user you selected, hopefully with
sudo privileges.



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


This machine was built with kernel 7.3.3, a stable release from kernel.org.

`make menuconfig` was run with all Marvell and Cavium modules selected, along
with debugging modules.

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
