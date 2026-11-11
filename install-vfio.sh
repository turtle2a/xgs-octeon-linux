#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONFIG="$SCRIPT_DIR/modules-load.d/xgs-vfio.conf"
DESTDIR=${DESTDIR:-}
TARGET_DIR="${DESTDIR}/etc/modules-load.d"
TARGET="$TARGET_DIR/xgs-vfio.conf"

if [ -z "$DESTDIR" ] && [ "$(id -u)" -ne 0 ]; then
	echo "install-vfio: run as root, or set DESTDIR for a staged install" >&2
	exit 1
fi

if [ ! -f "$CONFIG" ]; then
	echo "install-vfio: missing module list: $CONFIG" >&2
	exit 1
fi

if [ -e "$TARGET" ] && ! cmp -s "$CONFIG" "$TARGET"; then
	echo "install-vfio: refusing to overwrite a different file: $TARGET" >&2
	exit 1
fi

install -d -m 0755 "$TARGET_DIR"
install -m 0644 "$CONFIG" "$TARGET"

if [ -n "$DESTDIR" ]; then
	echo "install-vfio: staged module autoload configuration at $TARGET"
	exit 0
fi

command -v modprobe >/dev/null 2>&1 || {
	echo "install-vfio: modprobe is required to load the kernel modules" >&2
	exit 1
}

for module in vfio vfio_iommu_type1 vfio-pci; do
	modprobe "$module"
done

echo "install-vfio: installed and loaded VFIO modules; no PCI devices were configured or bound"
