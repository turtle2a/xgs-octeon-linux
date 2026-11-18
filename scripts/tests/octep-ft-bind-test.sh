#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Bind an offload flowtable on one octep port in a throwaway nft table, show it, then
# remove it and re-run the offload agent as a regression. Other rules are untouched.
#   octep-ft-bind-test.sh [PORT] [PEER]
set -u
PORT=${1:-octep3}
PEER=${2:-192.168.1.1}
TABLE=octep_ftt
ROOT=$(cd "$(dirname "$0")/../.." && pwd)

[ "$(id -u)" -eq 0 ] || { echo "SUDO REQUIRED: sudo $0 $*" >&2; exit 1; }
trap 'nft delete table inet "$TABLE" 2>/dev/null' EXIT

nft add table inet "$TABLE"
if nft add flowtable inet "$TABLE" f "{ hook ingress priority 0; devices = { $PORT }; flags offload; }"; then
	echo "FLOWTABLE-BIND-OK on $PORT"
else
	echo "FLOWTABLE-BIND-FAILED on $PORT"
fi
nft list table inet "$TABLE"
nft delete table inet "$TABLE"
echo "== offload agent regression"
"$ROOT/scripts/octep/offload-agent.py" --demo "$PEER" --seconds 60 --lease 12 2>&1
