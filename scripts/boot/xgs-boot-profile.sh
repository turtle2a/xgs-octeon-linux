#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Switch the CPU/DMA boot options between a performance and a hardened profile.
#
#   xgs-boot-profile.sh performance|hardened|status [--apply]
#
# Dry run by default: prints the plan and changes nothing. Only these options are touched:
#   spectre_v2=off  spec_rstack_overflow=off  iommu=pt
# Other options (selinux, clearcpuid, max_cstate, ...) are never changed.
# Measured on an XGS 2300 (host-path iperf, same IOMMU-translated boot):
#   hardened    about 293 Mbit/s
#   performance about 341-362 Mbit/s (hardened is about 14-19% lower)
# Performance leaves CPU side channels open (spectre_v2, SRSO) and lets the NPU DMA
# through a pass-through IOMMU. Reboot to take effect.
set -eu

OPTS="spectre_v2=off spec_rstack_overflow=off iommu=pt"
GRUB_FILE=${XGS_GRUB_DEFAULT_FILE:-/etc/default/grub}
PROFILE=${1:-status}
APPLY=0
[ "${2:-}" = "--apply" ] && APPLY=1

case $PROFILE in
performance | hardened | status) ;;
*)
	echo "usage: $0 performance|hardened|status [--apply]" >&2
	exit 2
	;;
esac

echo "boot-profile: running cmdline: $(cat /proc/cmdline 2>/dev/null || echo unknown)"
if [ "$PROFILE" = status ]; then
	for o in $OPTS; do
		if grep -qw -- "$o" /proc/cmdline 2>/dev/null; then echo "  $o: set"; else echo "  $o: not set"; fi
	done
	exit 0
fi

if [ "$PROFILE" = performance ]; then
	echo "boot-profile: performance = add: $OPTS"
	echo "boot-profile: WARNING: leaves CPU side channels open and uses a pass-through IOMMU for the NPU (R5, R7)."
else
	echo "boot-profile: hardened = remove: $OPTS"
	echo "boot-profile: note: about 14-19% lower host-path throughput (293 vs 341-362 Mbit/s on an XGS 2300)."
fi

if [ "$APPLY" -ne 1 ]; then
	echo "boot-profile: dry run, nothing changed. Re-run with --apply (as root) to change the boot options."
	exit 0
fi

[ "$(id -u)" -eq 0 ] || [ -n "${XGS_GRUB_DEFAULT_FILE:-}" ] || {
	echo "boot-profile: --apply needs root" >&2
	exit 1
}

[ -f "$GRUB_FILE" ] || { echo "boot-profile: no grubby and no $GRUB_FILE; change the boot options by hand" >&2; exit 1; }
grep -q '^GRUB_CMDLINE_LINUX\(_DEFAULT\)\?=' "$GRUB_FILE" ||
	{ echo "boot-profile: no GRUB_CMDLINE_LINUX line in $GRUB_FILE; change by hand" >&2; exit 1; }
HASDEF=0
grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" && HASDEF=1

cp -p "$GRUB_FILE" "$GRUB_FILE.xgs-bak"
TMP=$(mktemp)
awk -v hasdef="$HASDEF" -v prof="$PROFILE" -v opts="$OPTS" '
BEGIN { n = split(opts, o, " ") }
/^GRUB_CMDLINE_LINUX(_DEFAULT)?=/ {
	line = $0
	pre = line; sub(/=.*/, "=", pre)
	q = substr(line, length(pre) + 1, 1)
	val = substr(line, length(pre) + 2)
	sub(q "[ \t]*$", "", val)
	m = split(val, t, " ")
	out = ""
	for (i = 1; i <= m; i++) {
		drop = 0
		split(t[i], u, "=")
		for (j = 1; j <= n; j++) { split(o[j], k, "="); if (k[1] == u[1]) drop = 1 }
		if (!drop) out = out (out == "" ? "" : " ") t[i]
	}
	if (prof == "performance" && (pre ~ /_DEFAULT=/ || !hasdef)) for (j = 1; j <= n; j++) out = out (out == "" ? "" : " ") o[j]
	print pre q out q
	next
}
{ print }
' "$GRUB_FILE" >"$TMP"
cat "$TMP" >"$GRUB_FILE"
rm -f "$TMP"
echo "boot-profile: updated $GRUB_FILE (backup $GRUB_FILE.xgs-bak)"

[ -z "${XGS_GRUB_DEFAULT_FILE:-}" ] || exit 0
if command -v update-grub >/dev/null 2>&1; then
	update-grub
elif command -v grub2-mkconfig >/dev/null 2>&1; then
	grub2-mkconfig -o /boot/grub2/grub.cfg
elif command -v grub-mkconfig >/dev/null 2>&1; then
	grub-mkconfig -o /boot/grub/grub.cfg
else
	echo "boot-profile: regenerate the grub config by hand" >&2
	exit 1
fi
# Fedora/RHEL boot entries (BLS) keep their own copy of the options; update them too
if command -v grubby >/dev/null 2>&1; then
	if [ "$PROFILE" = performance ]; then
		grubby --update-kernel=ALL --args="$OPTS"
	else
		grubby --update-kernel=ALL --remove-args="$OPTS"
	fi
fi
echo "boot-profile: reboot to apply."
