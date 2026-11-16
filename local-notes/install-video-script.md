# Install Video Script: XGS OCTEON Linux (OCTEP) Install

Screen-recording script for a YouTube walkthrough. Target length 12 to 15 minutes.
Record the screen with any Linux screen recorder; record narration separately or live.

Replace every real IP address, hostname, MAC and serial number shown on screen
with the placeholders in this script, or blur them in the edit.

## Recording tips

- Terminal font 18pt or larger, dark theme, 1920x1080, 30 fps.
- Pause 2 seconds after each command so viewers can read the output.
- Serial console scenes (PuTTY or `screen`) need a second window or a capture of the PC screen.
- Record each scene as its own clip. Re-take freely and join them in the edit.

## Title, description and chapters

**Title:** Install Linux (Fedora, Debian, Linux Mint) on a Sophos XGS 2300 with the OCTEP NPU driver and default NAT

**Description:** Step-by-step install of the OCTEP Linux driver, DKMS module,
services and default NAT on a Sophos XGS 2300 (OCTEON TX) with Fedora, Debian or
Linux Mint. Source and docs: https://github.com/turtle2a/xgs-octeon-linux

The install is validated on the XGS 2300 with Fedora, Debian and Linux Mint. The
XGS 3300 is not yet verified (expected to work, untested). Other appliances are
unverified. You do this at your own risk: check the Hardware Compatibility table
in the README first.

**Chapters:**

| Time | Chapter |
| --- | --- |
| 00:00 | Intro and what this does |
| 01:00 | Requirements and compatibility |
| 02:30 | Prepare the donor disk and GRUB |
| 04:30 | BIOS and serial console |
| 06:00 | Management network and remote access |
| 07:00 | Kernel headers and running install.sh |
| 09:00 | Checking the NPU and ports |
| 10:30 | NAT (default: Port 2 WAN) |
| 12:30 | Testing, undo and troubleshooting |

## Scene 1: Intro (about 1 min)

**Show:** The repository page, then the README hardware table.

**Say:** This video installs Linux with the OCTEP driver on a Sophos XGS 2300 so
its NPU ports work under Linux. It covers the boot settings and the installer.
NAT is fixed by the install: all LAN ports go out faceplate Port 2 (`octep1`),
the WAN port. The options are Port 4 as the WAN instead, or no NAT at all. The
install is validated on the XGS 2300 with Fedora, Debian and Linux Mint. The XGS
3300 is not yet verified. Check the table before you start.

## Scene 2: Requirements (about 1.5 min)

**Show:** `docs/install-requirements.md`, Requirements section.

**Say:** You need a systemd Linux, root access, kernel development files that match
the running kernel, GCC, make, binutils, DKMS and kmod. The installer can add missing
build tools but not the matching kernel files. Without
`/lib/modules/$(uname -r)/build/Makefile` do not continue.

**Run (on the donor system):**

```sh
git clone https://github.com/turtle2a/xgs-octeon-linux.git
cd xgs-octeon-linux
uname -r
ls /lib/modules/$(uname -r)/build/Makefile
```

## Scene 3: Donor disk and GRUB (about 2 min)

**Show:** `docs/boot-loader-requirements.md`, then `/etc/default/grub` in an editor.

**Say:** Install a full bootable Linux onto the donor disk first. Libraries alone do not
work. Before you move the disk, add the GRUB settings so the PCI bus and the serial
console are available at boot, and regenerate the config. The installer does not edit
the boot loader.

**Run (Fedora):**

```sh
sudo nano /etc/default/grub
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

Debian and Linux Mint: `sudo update-grub`.

**Say:** Keep a working boot entry before you reboot. Allow SSH and XRDP from your trusted
management subnet now, in case the serial console is not available:

```sh
sudo ufw allow from 10.1.1.0/28 to any port 22 proto tcp
sudo ufw status
```

## Scene 4: BIOS and serial console (about 1.5 min)

**Show:** A PC with PuTTY or a serial terminal on a USB serial cable.

**Say:** Shut down, move the disk to the XGS and open the serial terminal at 38400 baud.
Do not open the connection until the machine is booting. Hold DEL to enter the BIOS,
turn Secure Boot off, turn VT-d/IOMMU on, and pick the donor disk. After that,
reconnect at 115200 baud to see the Linux boot and the login prompt.

## Scene 5: Management network (about 1 min)

**Show:** The MGMT port and cable, then the terminal.

**Say:** Plug an Ethernet cable into the MGMT port, to the right of the front USB ports.
Check it received an address.

**Run:**

```sh
ip -br addr
ping -c3 <gateway>
```

## Scene 6: Run the installer (about 2 min)

**Show:** Terminal over SSH or serial.

**Say:** Copy the project onto the appliance, then run the installer from the project
root.

**Run:**

```sh
cd xgs-octeon-linux
sudo sh ./install.sh
```

**Say:** It builds the module with DKMS and installs the systemd units and helper
scripts under `/usr/local/xgs/linux`. It does not load the driver immediately.

**Run (reboot):**

```sh
sudo reboot
```

## Scene 7: Check the NPU and ports (about 1.5 min)

**Run (after the reboot, wait about 30 seconds):**

```sh
lsmod | grep octep
ip -br link | grep octep
systemctl status xgs-npu-health --no-pager
sudo sh /usr/local/xgs/linux/scripts/octep/sdp-status-check.sh
```

**Say:** You should see the `octep` module and the front-port interfaces `octep0`
upward. If they are missing, give it another 30 seconds, then check
`docs/debugging.md`.

## Scene 8: NAT, on by default (about 2 min)

**Show:** the README NAT section, then the terminal.

**Say:** NAT is on by default. Every LAN port goes out faceplate Port 2, the WAN port,
which is `octep1`. Plug the WAN cable into Port 2. The `xgs-nat.service` unit applies it at
every boot. Port N on the faceplate is interface octep N minus one, so Port 4 is `octep3`.

**Run (check the default):**

```sh
systemctl status xgs-nat.service
sudo iptables -t nat -S POSTROUTING
```

**Say:** There are two optional scripts. `nat-port4.sh` uses Port 4 as the WAN instead, and
`nat-off.sh` turns NAT off. To keep it off across reboots, create `/etc/xgs-nat-off`.

**Run (optional):**

```sh
sudo /usr/local/xgs/linux/scripts/nat/nat-port4.sh
sudo /usr/local/xgs/linux/scripts/nat/nat-off.sh
sudo /usr/local/xgs/linux/scripts/nat/xgs-nat.sh start
```

Each prints one line, for example "All LAN ports now routed via Port 2 (octep1) WAN".

## Scene 9: Test it (about 1 min)

**Say:** From a client on a LAN port, set the gateway to the appliance and ping out.

**Run (on the client):**

```sh
ping -c3 8.8.4.4
```

**Say:** These are plain iptables rules and do not touch NetworkManager. They are
runtime-only, so the service re-applies them at boot.

## Scene 10: Wrap-up (about 30 s)

**Say:** That is the install. Please report issues on GitHub with the output of the
status commands. Thanks for watching.

**Show:** Repository URL, then the end card.

## Before you publish

- Remove or blur real IP addresses, hostnames, MACs and serial numbers.
- Re-check the commands against the current README, because they can change.
- Run the NAT scene on your own appliance before recording.
