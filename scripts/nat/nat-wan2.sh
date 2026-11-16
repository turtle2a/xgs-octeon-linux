#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Optional NAT out WAN physical port 2 (octep1).
# Usage: sudo nat-wan2.sh [apply|apply-mgmt|apply-all|undo|status]
#   apply       octep LAN ports masqueraded out the WAN (standard)
#   apply-mgmt  only the management/holding-gateway subnet (e.g. 10.1.1.0/28) masqueraded out the WAN; its gateway is left alone
#   apply-all   both, LAN rules first
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
case ${1:-apply} in
	apply) exec "$here/nat-options.sh" apply 2 --lans ;;
	apply-mgmt) exec "$here/nat-options.sh" apply 2 --mgmt ;;
	apply-all) exec "$here/nat-options.sh" apply 2 --all-lans ;;
	undo|status) exec "$here/nat-options.sh" "$1" ;;
	*) echo "Usage: $0 [apply|apply-mgmt|apply-all|undo|status]" >&2; exit 64 ;;
esac
