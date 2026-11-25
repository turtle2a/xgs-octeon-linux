#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Unattended system update for XGS appliances (Fedora: dnf, Debian/Mint: apt, Arch: pacman).
# Run from /etc/cron.d/xgs-auto-update at 05:00 and 13:00. Never prompts, never reboots.
# Kernel packages are updated too; DKMS rebuilds the out-of-tree OCTEP driver for the new kernel
# and the result is logged. The reboot is left to the operator (the old kernel stays bootable).
#   DRY_RUN=1 sudo xgs-auto-update.sh   show what would be installed, change nothing
# Disable/enable: xgs-auto-update-ctl.sh disable|enable (creates /etc/xgs-auto-update-off).
# Optional overrides in /etc/xgs-auto-update.conf: DNF_EXCLUDE, APT_SKIP, PACMAN_IGNORE (set them to hold kernels back again,
# e.g. DNF_EXCLUDE='kernel*').
set -u
LOG=${XGS_UPDATE_LOG:-/var/log/xgs-auto-update.log}
LOCK=${XGS_UPDATE_LOCK:-/run/xgs-auto-update.lock}
DNF_EXCLUDE=${DNF_EXCLUDE:-}
PACMAN_IGNORE=${PACMAN_IGNORE:-}
APT_SKIP=${APT_SKIP:-}
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
	log "start (dnf, excluding: ${DNF_EXCLUDE:-nothing}, dry-run=$DRY)"
	set --
	[ -z "$DNF_EXCLUDE" ] || set -- --exclude="$DNF_EXCLUDE"
	if [ "$DRY" = 1 ]; then
		dnf -y --refresh "$@" upgrade --assumeno
	else
		dnf -y --refresh "$@" upgrade
	fi
	rc=$?
elif command -v apt-get >/dev/null 2>&1; then
	log "start (apt, skipping: ${APT_SKIP:-nothing}, dry-run=$DRY)"
	export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1
	apt-get -q -o DPkg::Lock::Timeout=600 update || rc=$?
	pkgs=$(apt-get -s upgrade 2>/dev/null | awk '/^Inst /{print $2}' | { if [ -n "$APT_SKIP" ]; then grep -Ev "$APT_SKIP"; else cat; fi; } | tr '\n' ' ')
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
elif command -v pacman >/dev/null 2>&1; then
	log "start (pacman, ignoring: ${PACMAN_IGNORE:-nothing}, dry-run=$DRY)"
	# Always a full sync (-Syu); a partial -Sy upgrade breaks Arch.
	if [ "$DRY" = 1 ]; then
		if command -v checkupdates >/dev/null 2>&1; then
			checkupdates || true
		else
			log "dry-run: would run pacman -Syu (install pacman-contrib for a package list)"
		fi
	else
		set --
		[ -z "$PACMAN_IGNORE" ] || set -- --ignore "$PACMAN_IGNORE"
		pacman -Syu --noconfirm --noprogressbar "$@"
		rc=$?
	fi
else
	log "no supported package manager (dnf, apt-get or pacman)"
	exit 1
fi

if [ "$DRY" != 1 ] && command -v dkms >/dev/null 2>&1; then
	dkms status 2>/dev/null | grep -i octep | while read -r l; do log "dkms: $l"; done
fi
[ -e /var/run/reboot-required ] && log "reboot required (not performed)"
log "finished rc=$rc"
exit "$rc"
