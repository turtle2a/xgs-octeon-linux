# Install Requirements

The installer supports DNF/YUM and APT for missing build tools. It does not
install or upgrade the running kernel or its matching build files.

## Requirements

- A supported OCTEON TX appliance and a Linux system using systemd.
- Root access to install the driver and systemd units.
- Build files matching the running kernel:
  - Fedora, RHEL, Rocky Linux, or AlmaLinux: `kernel-devel` for `uname -r`.
  - Debian or Linux Mint: `linux-headers` for `uname -r`.
- Network access to the distribution's package repositories if the installer
  needs to install missing build tools.

The installer checks for `/lib/modules/$(uname -r)/build/Makefile` before
installing the driver. Do not continue if this file is missing.

## Fedora, RHEL, Rocky Linux, and AlmaLinux

On the test machine, install the build files matching its running kernel:

```sh
sudo dnf makecache
sudo dnf install "kernel-devel-$(uname -r)"
```

Verify the build tree exists:

```sh
test -f "/lib/modules/$(uname -r)/build/Makefile" \
  && echo "Matching kernel build files found"
```

If the exact `kernel-devel` package is unavailable, stop and resolve the
kernel/package version mismatch before running the installer. The installer
will use DNF or YUM to install missing build tools.

## Debian and Linux Mint

Update package lists and install headers for the running kernel:

```sh
sudo apt-get update
sudo apt-get install "linux-headers-$(uname -r)"
```

Verify the build tree exists:

```sh
test -f "/lib/modules/$(uname -r)/build/Makefile" \
  && echo "Matching kernel build files found"
```

If matching headers are unavailable, stop and resolve the kernel/package
version mismatch before running the installer. The installer uses APT to
install missing build tools (`dkms`, `build-essential`, and `kmod`).

Linux Mint 22.x is Ubuntu-based; Linux Mint Debian Edition (LMDE) is
Debian-based. Both use APT, but their kernel packages may differ. Always verify
that `/lib/modules/$(uname -r)/build/Makefile` exists before installing.
