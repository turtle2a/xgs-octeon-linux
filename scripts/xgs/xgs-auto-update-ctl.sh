#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 turtle2a <354865938+turtle2a@users.noreply.github.com>
# Turn the XGS unattended updates (cron 05:00 and 13:00) off or on.
#   sudo xgs-auto-update-ctl.sh disable | enable | status
# The off switch is /etc/xgs-auto-update-off, so it survives reinstalls and upgrades.
set -eu
OFF=/etc/xgs-auto-update-off
case ${1:-status} in
disable)
	[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
	: >"$OFF"
	echo "XGS auto update disabled (cron still runs but exits immediately)"
	;;
enable)
	[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
	rm -f "$OFF"
	echo "XGS auto update enabled (05:00 and 13:00)"
	;;
status)
	if [ -e "$OFF" ]; then echo "disabled"; else echo "enabled"; fi
	[ -e /etc/cron.d/xgs-auto-update ] && cat /etc/cron.d/xgs-auto-update | grep -v '^#' || echo "cron file missing"
	[ -r /var/log/xgs-auto-update.log ] && tail -3 /var/log/xgs-auto-update.log || true
	;;
*) echo "usage: $0 disable|enable|status" >&2; exit 64 ;;
esac
