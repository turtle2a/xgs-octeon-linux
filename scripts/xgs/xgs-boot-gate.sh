#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 turtle2a <354865938+turtle2a@users.noreply.github.com>
# Boot gate for XGS routers: the OCTEP ports are the LAN/WAN, so the next boot must never default
# to a kernel that has no matching octep module. If the newest installed kernel has none (or the
# module was built for another kernel), pin the default boot entry to the running kernel.
# Exit: 0 = default unchanged or pinned safely, 1 = pin needed but failed, 2 = gate cannot run here.
# Test overrides: XGS_RUN_KV, XGS_NEW_KV, XGS_MODROOT, XGS_GRUBBY, XGS_BOOTDIR, XGS_MODINFO.
set -u
RUN_KV=${XGS_RUN_KV:-$(uname -r)}
MODROOT=${XGS_MODROOT:-/lib/modules}
GRUBBY=${XGS_GRUBBY:-grubby}
BOOTDIR=${XGS_BOOTDIR:-/boot}
MODINFO=${XGS_MODINFO:-modinfo}
log() { echo "$(date '+%F %T') xgs-boot-gate: $*"; }

command -v "$GRUBBY" >/dev/null 2>&1 || { log "no grubby; gate not applicable"; exit 2; }
NEW_KV=${XGS_NEW_KV:-$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' 2>/dev/null | sort -V | tail -1)}
[ -n "$NEW_KV" ] || { log "cannot determine newest kernel; gate not applicable"; exit 2; }
[ "$NEW_KV" != "$RUN_KV" ] || { log "newest kernel is the running kernel ($RUN_KV); nothing to gate"; exit 0; }

ko=
for f in "$MODROOT/$NEW_KV"/extra/octep.ko* "$MODROOT/$NEW_KV"/kernel/drivers/net/ethernet/extra/octep/octep.ko*; do
	[ -e "$f" ] && { ko=$f; break; }
done
vm=
[ -n "$ko" ] && vm=$($MODINFO -F vermagic "$ko" 2>/dev/null | awk '{print $1}')

if [ "$vm" = "$NEW_KV" ]; then
	log "octep module present for $NEW_KV (vermagic ok); default boot unchanged"
	exit 0
fi
log "NO matching octep module for $NEW_KV (found: ${ko:-none}, vermagic: ${vm:-none}); pinning default boot to $RUN_KV"
"$GRUBBY" --set-default "$BOOTDIR/vmlinuz-$RUN_KV" || { log "grubby failed; default boot NOT pinned"; exit 1; }
exit 0
