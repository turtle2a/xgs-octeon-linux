# Boot Loader Requirements

The tested Fedora appliance requires these GRUB settings to expose the PCI bus
at boot. The same settings also work on Debian and Linux Mint, and most
GRUB-based Linux distributions, including Arch Linux, use the same
`/etc/default/grub` configuration format. Other distributions may use a
different bootloader or require distribution-specific adjustments. These
settings are documented for the tested system; `install.sh` does not edit the
boot loader. Add or merge these values in `/etc/default/grub`, keeping any
unrelated settings already needed by the system. Set `GRUB_DISTRIBUTOR` to
match the installed distribution if desired:

```sh
GRUB_DEFAULT=0
GRUB_TIMEOUT='5'
GRUB_DISTRIBUTOR='Fedora'
GRUB_CMDLINE_LINUX_DEFAULT='nowatchdog nvme_load=YES splash loglevel=3'

GRUB_CMDLINE_LINUX="processor.max_cstate=0 selinux=0 clearcpuid=smap iommu=pt rdrand=force amd_iommu=on console=tty0 console=ttyS0,115200n8 spectre_v2=off clearcpuid=smap spec_rstack_overflow=off hw.pci.realloc_bars=1 hint.uart.0.flags=0x00"

GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB_TERMINAL="console serial"
```

After changing `/etc/default/grub`, regenerate the GRUB configuration using the
command for the installed distribution:

```sh
# Fedora
sudo grub2-mkconfig -o /boot/grub2/grub.cfg

# Debian and Linux Mint
sudo update-grub

# Arch Linux (use the GRUB configuration path for your installation)
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

Keep a working boot entry available before rebooting. The Fedora installation
ISO did not provide serial output on the appliance, so a minimal Fedora
installation was first performed on another system. Its `/etc/default/grub`
was then configured and regenerated with the settings above before moving the
drive to the appliance, where setup was completed. In that configuration, the
`console=ttyS0,115200n8` kernel argument together with `GRUB_SERIAL_COMMAND`
and `GRUB_TERMINAL` enables the serial console. The appliance's micro-USB port
provides this serial connection, exposed to Linux as `ttyS0`. For boot
diagnostics or interaction, connect a USB-to-serial cable to that port and
open its host-side adapter in PuTTY at `115200 8N1` (115200 baud, 8 data bits,
no parity, 1 stop bit). The same serial-console settings can be used when
setting up Debian or Linux Mint on the appliance.

For XGS 2300 and XGS 3300 appliances, have a USB-to-serial cable available
for console access through the micro-USB port. Some other XGS appliances may
provide a monitor output such as HDMI or DisplayPort instead; check the
specific model's available console connections.

On BSD, the corresponding boot settings are placed in `/boot/loader.conf`;
the syntax differs slightly. The GRUB file and regeneration commands above
apply to Linux only.
