#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Run after install.sh if you do NOT want the vendor-style boot options that leave CPU side
# channels (spectre_v2, SRSO) and NPU DMA less restricted. This removes:
#   spectre_v2=off  spec_rstack_overflow=off  iommu=pt
# Cost: about 14-19% lower host-path throughput (293 vs 341-362 Mbit/s, XGS 2300).
# Dry run by default (changes nothing). To apply, as root:
#   low_perf_disable_vuln_grub_options.sh --apply
# Then reboot. To go back to the faster options: xgs-boot-profile.sh performance --apply
set -eu
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "$DIR/xgs-boot-profile.sh" hardened "${1:-}"
