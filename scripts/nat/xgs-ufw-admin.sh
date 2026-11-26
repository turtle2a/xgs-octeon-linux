#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 turtle2a <354865938+turtle2a@users.noreply.github.com>
# Optional: limit admin services (ssh, RDP) to a trusted subnet with ufw. The installer does not run it.
# Prints what it would do; changes nothing until --apply. Existing rules are never deleted, so a
# session you are using cannot be cut off: review the "broad allows" it lists and remove them yourself
# (ufw delete <number>) once you have tested from the admin subnet.
#
#   ADMIN_NET=10.1.1.0/28 xgs-ufw-admin.sh [--apply]
#   ADMIN_PORTS="22 3389" overrides the ports (default 22 3389)
set -u

ADMIN_NET=${ADMIN_NET:-}
ADMIN_PORTS=${ADMIN_PORTS:-22 3389}
APPLY=0
[ "${1:-}" = --apply ] && APPLY=1

case $ADMIN_NET in
'' | *[!0-9./]*) echo "set ADMIN_NET to the trusted IPv4 subnet, e.g. ADMIN_NET=10.1.1.0/28" >&2; exit 64 ;;
esac
case $ADMIN_PORTS in *[!0-9\ ]*) echo "ADMIN_PORTS must be port numbers" >&2; exit 64 ;; esac
command -v ufw >/dev/null 2>&1 || { echo "ufw is not installed" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
ufw status 2>/dev/null | grep -q '^Status: active' || { echo "ufw is not active" >&2; exit 1; }

for p in $ADMIN_PORTS; do
	if [ "$APPLY" = 1 ]; then
		ufw allow proto tcp from "$ADMIN_NET" to any port "$p" && echo "allowed tcp $p from $ADMIN_NET"
	else
		echo "would run: ufw allow proto tcp from $ADMIN_NET to any port $p"
	fi
done

echo "--- broad allows still present (remove after testing from $ADMIN_NET) ---"
for p in $ADMIN_PORTS; do
	ufw status numbered | grep -E "^\[ *[0-9]+\] +$p(/tcp|/udp)? .*ALLOW IN +Anywhere"
done
[ "$APPLY" = 1 ] || echo "dry run: nothing changed; add --apply to add the rules"
exit 0
