#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 turtle2a <354865938+turtle2a@users.noreply.github.com>
# Merge the boot options in docs/boot-loader-requirements.md into /etc/default/grub.
#
#   xgs-grub-required.sh [--check]
#
# Only options that are missing are appended; existing options and values are never changed.
# The file is backed up first, GRUB is regenerated for the installed distribution, and the
# backup is restored if regeneration fails. --check prints the plan and changes nothing.
# XGS_BOOT_EDIT=0 skips everything. XGS_GRUB_DEFAULT_FILE overrides the file (testing).
# Exit codes: 0 nothing to do or skipped, 3 changed (reboot required), 1 failed.
set -eu

REQUIRED="processor.max_cstate=0 selinux=0 clearcpuid=smap iommu=pt rdrand=force amd_iommu=on console=tty0 console=ttyS0,115200n8 spectre_v2=off"
GRUB_FILE=${XGS_GRUB_DEFAULT_FILE:-/etc/default/grub}
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1
say() { echo "xgs-grub: $*"; }

if [ "${XGS_BOOT_EDIT:-1}" = 0 ]; then
	say "XGS_BOOT_EDIT=0: boot loader left unchanged; see docs/boot-loader-requirements.md"
	exit 0
fi
if [ ! -f "$GRUB_FILE" ]; then
	say "$GRUB_FILE not found (not a GRUB system?): apply docs/boot-loader-requirements.md manually"
	exit 0
fi

line=$(grep -m1 '^GRUB_CMDLINE_LINUX=' "$GRUB_FILE" || true)
cur=$(printf '%s\n' "$line" | sed -e 's/^GRUB_CMDLINE_LINUX=//' -e "s/^[\"']//" -e "s/[\"'][[:space:]]*\$//")

missing=
for opt in $REQUIRED; do
	key=${opt%%=*}
	case $key in
	console) pat=$opt ;; # several console= entries are normal; match the whole token
	*) pat=$key ;;
	esac
	found=0
	for tok in $cur; do
		case $tok in
		"$pat" | "$pat"=*) found=1 ;;
		esac
	done
	[ $found = 1 ] || missing="$missing $opt"
done
missing=${missing# }

add_serial_cmd=0
add_terminal=0
grep -q '^GRUB_SERIAL_COMMAND=' "$GRUB_FILE" || add_serial_cmd=1
grep -q '^GRUB_TERMINAL=' "$GRUB_FILE" || add_terminal=1

if [ -z "$missing" ] && [ $add_serial_cmd = 0 ] && [ $add_terminal = 0 ]; then
	say "boot options already present: nothing to change"
	exit 0
fi

say "will add to GRUB_CMDLINE_LINUX: ${missing:-nothing}"
[ $add_serial_cmd = 1 ] && say "will add GRUB_SERIAL_COMMAND (serial 115200 8N1)"
[ $add_terminal = 1 ] && say "will add GRUB_TERMINAL=\"console serial\""
[ $CHECK = 1 ] && exit 0

ts=$(date +%Y%m%d-%H%M%S)
bdir=${XGS_GRUB_BACKUP_DIR:-/var/backups/xgs-grub-$ts}
mkdir -p "$bdir"
cp -p "$GRUB_FILE" "$bdir/grub.default"
(cd "$bdir" && sha256sum grub.default >SHA256SUMS)
say "backup: $bdir/grub.default (SHA256SUMS alongside)"

tmp=$(mktemp "${GRUB_FILE}.xgs.XXXXXX")
trap 'rm -f "$tmp"' EXIT
NEWCMD="${cur:+$cur }$missing" HAVE_LINE="$line" awk '
	BEGIN { done = 0 }
	/^GRUB_CMDLINE_LINUX=/ && !done { print "GRUB_CMDLINE_LINUX=\"" ENVIRON["NEWCMD"] "\""; done = 1; next }
	{ print }
	END { if (!done) print "GRUB_CMDLINE_LINUX=\"" ENVIRON["NEWCMD"] "\"" }
' "$GRUB_FILE" >"$tmp"
if [ $add_serial_cmd = 1 ]; then
	echo 'GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"' >>"$tmp"
fi
if [ $add_terminal = 1 ]; then
	echo 'GRUB_TERMINAL="console serial"' >>"$tmp"
fi
cat "$tmp" >"$GRUB_FILE"
rm -f "$tmp"

restore() {
	cp -p "$bdir/grub.default" "$GRUB_FILE"
	say "FAILED: $GRUB_FILE restored from backup; boot loader unchanged"
	exit 1
}

# Test overrides skip regeneration.
if [ -n "${XGS_GRUB_DEFAULT_FILE:-}" ]; then
	say "test file updated; GRUB not regenerated"
	exit 3
fi

if command -v update-grub >/dev/null 2>&1; then
	cfg=/boot/grub/grub.cfg
	update-grub || restore
elif command -v grub2-mkconfig >/dev/null 2>&1; then
	cfg=/boot/grub2/grub.cfg
	grub2-mkconfig -o "$cfg" || restore
elif command -v grub-mkconfig >/dev/null 2>&1; then
	cfg=/boot/grub/grub.cfg
	grub-mkconfig -o "$cfg" || restore
else
	cp -p "$bdir/grub.default" "$GRUB_FILE"
	say "no GRUB generator found: file restored; apply docs/boot-loader-requirements.md manually"
	exit 0
fi

[ -s "$cfg" ] && grep -q 'amd_iommu=on' "$cfg" || restore
say "GRUB regenerated ($cfg); new options apply after reboot"
exit 3
