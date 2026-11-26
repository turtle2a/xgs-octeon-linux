#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 turtle2a <354865938+turtle2a@users.noreply.github.com>
# Standalone (needs no installer and does not re-add anything): secure, low performance boot mode.
# Run after install.sh and a reboot if you do NOT want the vendor-style boot options that leave CPU
# side channels (spectre_v2, SRSO) and NPU DMA less restricted. Removes:
#   spectre_v2=off  spec_rstack_overflow=off  iommu=pt
# Cost: about 14-19% lower host-path throughput (293 vs 341-362 Mbit/s, XGS 2300).
# Dry run by default (changes nothing). To apply, as root:  low_perf_disable_vuln_grub_options.sh --apply
# Distros: Fedora/RHEL/Rocky/Alma (grub2-mkconfig -o /boot/grub2/grub.cfg + grubby), Debian/Ubuntu/
# Mint/LMDE (update-grub), openSUSE (grub2-mkconfig), Arch (grub-mkconfig -o /boot/grub/grub.cfg).
# systemd-boot or other loaders: prints what to change by hand. Reboot afterwards.
# Back to the faster options: xgs-boot-profile.sh performance --apply
set -eu
OPTS="spectre_v2=off spec_rstack_overflow=off iommu=pt"
GRUB_FILE=${XGS_GRUB_DEFAULT_FILE:-/etc/default/grub}

echo "low-perf: running cmdline: $(cat /proc/cmdline 2>/dev/null)"
echo "low-perf: secure mode = remove: $OPTS"
echo "low-perf: note: about 14-19% lower host-path throughput (293 vs 341-362 Mbit/s on an XGS 2300)."
if [ "${1:-}" != "--apply" ]; then
	echo "low-perf: dry run, nothing changed. Re-run with --apply (as root) to change the boot options."
	exit 0
fi
[ "$(id -u)" -eq 0 ] || [ -n "${XGS_GRUB_DEFAULT_FILE:-}" ] || { echo "low-perf: --apply needs root" >&2; exit 1; }
if [ ! -f "$GRUB_FILE" ] || ! grep -q '^GRUB_CMDLINE_LINUX\(_DEFAULT\)\?=' "$GRUB_FILE"; then
	echo "low-perf: no grub options in $GRUB_FILE (systemd-boot or another loader?)." >&2
	echo "low-perf: remove these by hand from the kernel command line ($OPTS)," >&2
	echo "low-perf: e.g. /etc/kernel/cmdline then reinstall the kernel entry, or: grubby --update-kernel=ALL --remove-args=\"$OPTS\"" >&2
	exit 1
fi

cp -p "$GRUB_FILE" "$GRUB_FILE.xgs-bak"
TMP=$(mktemp)
awk -v opts="$OPTS" '
BEGIN { n = split(opts, o, " ") }
/^GRUB_CMDLINE_LINUX(_DEFAULT)?=/ {
	pre = $0; sub(/=.*/, "=", pre)
	q = substr($0, length(pre) + 1, 1)
	val = substr($0, length(pre) + 2)
	sub(q "[ \t]*$", "", val)
	m = split(val, t, " ")
	out = ""
	for (i = 1; i <= m; i++) {
		drop = 0
		split(t[i], u, "=")
		for (j = 1; j <= n; j++) { split(o[j], k, "="); if (k[1] == u[1]) drop = 1 }
		if (!drop) out = out (out == "" ? "" : " ") t[i]
	}
	print pre q out q
	next
}
{ print }
' "$GRUB_FILE" >"$TMP"
cat "$TMP" >"$GRUB_FILE"
rm -f "$TMP"
echo "low-perf: updated $GRUB_FILE (backup $GRUB_FILE.xgs-bak)"

[ -z "${XGS_GRUB_DEFAULT_FILE:-}" ] || exit 0
if command -v update-grub >/dev/null 2>&1; then
	update-grub
elif command -v grub2-mkconfig >/dev/null 2>&1; then
	CFG=/boot/grub2/grub.cfg
	# RHEL 8 and older on UEFI keep the live config under /boot/efi
	[ -f "$CFG" ] && ! [ -L "$CFG" ] || for f in /boot/efi/EFI/*/grub.cfg; do [ -f "$f" ] && CFG=$f && break; done
	grub2-mkconfig -o "$CFG"
elif command -v grub-mkconfig >/dev/null 2>&1; then
	grub-mkconfig -o /boot/grub/grub.cfg
else
	echo "low-perf: no grub tool found; regenerate the grub config by hand" >&2
	exit 1
fi
# Fedora/RHEL boot entries (BLS) keep their own copy of the options
if command -v grubby >/dev/null 2>&1; then
	grubby --update-kernel=ALL --remove-args="$OPTS"
fi
echo "low-perf: done. Reboot to apply."
