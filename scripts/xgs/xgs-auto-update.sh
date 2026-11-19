#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Unattended system update for XGS appliances (Fedora: dnf, Debian/Mint: apt).
# Run from /etc/cron.d/xgs-auto-update at 05:00 and 13:00. Never prompts, never reboots.
# Kernel packages are held back: the out-of-tree OCTEP driver is built for the running
# kernel, so a kernel change is left to the operator (reboot-required is only logged).
#   DRY_RUN=1 sudo xgs-auto-update.sh   show what would be installed, change nothing
# Disable/enable: xgs-auto-update-ctl.sh disable|enable (creates /etc/xgs-auto-update-off).
# Optional overrides in /etc/xgs-auto-update.conf: DNF_EXCLUDE, APT_SKIP.
set -u
LOG=${XGS_UPDATE_LOG:-/var/log/xgs-auto-update.log}
LOCK=${XGS_UPDATE_LOCK:-/run/xgs-auto-update.lock}
DNF_EXCLUDE='kernel*'
APT_SKIP='^(linux-image|linux-headers|linux-modules|linux-kbuild|linux-libc-dev|linux-generic|linux-lowlatency|linux-oem|linux-signed)'
[ -r /etc/xgs-auto-update.conf ] && . /etc/xgs-auto-update.conf

[ -e /etc/xgs-auto-update-off ] && exit 0
[ "$(id -u)" -eq 0 ] || { echo "xgs-auto-update: must run as root" >&2; exit 1; }
exec >>"$LOG" 2>&1
exec 9>"$LOCK"
flock -n 9 || { echo "$(date '+%F %T') another update run is active; skipping"; exit 0; }

log() { echo "$(date '+%F %T') xgs-auto-update: $*"; }
DRY=${DRY_RUN:-0}
rc=0

if command -v dnf >/dev/null 2>&1; then
	log "start (dnf, excluding: $DNF_EXCLUDE, dry-run=$DRY)"
	if [ "$DRY" = 1 ]; then
		dnf -y --refresh --exclude="$DNF_EXCLUDE" upgrade --assumeno
	else
		dnf -y --refresh --exclude="$DNF_EXCLUDE" upgrade
	fi
	rc=$?
elif command -v apt-get >/dev/null 2>&1; then
	log "start (apt, skipping: $APT_SKIP, dry-run=$DRY)"
	export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1
	apt-get -q -o DPkg::Lock::Timeout=600 update || rc=$?
	pkgs=$(apt-get -s upgrade 2>/dev/null | awk '/^Inst /{print $2}' | grep -Ev "$APT_SKIP" | tr '\n' ' ')
	if [ -z "$pkgs" ]; then
		log "nothing to upgrade"
	elif [ "$DRY" = 1 ]; then
		log "would upgrade: $pkgs"
	else
		# shellcheck disable=SC2086
		apt-get -y -q -o DPkg::Lock::Timeout=600 \
			-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
			install --only-upgrade $pkgs || rc=$?
	fi
else
	log "no supported package manager (dnf or apt-get)"
	exit 1
fi

[ -e /var/run/reboot-required ] && log "reboot required (not performed)"
log "finished rc=$rc"
exit "$rc"
