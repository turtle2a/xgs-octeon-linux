#!/bin/sh
# TCP offload test: iperf3 from the appliance through an OCTEP port while the
# offload agent runs. Compares throughput per interval and counts agent verdicts.
#   sudo scripts/tests/octep-tcp-offload.sh [IFACE] [TARGET] [SECONDS] [ACTION] [iperf3 extra args]
# Example: sudo scripts/tests/octep-tcp-offload.sh octep1 192.168.1.1 40 1 -R
set -u
IFACE=${1:-octep1}
TARGET=${2:-192.168.1.1}
SECS=${3:-40}
ACTION=${4:-1}
[ $# -gt 4 ] && shift 4 || shift $#
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LOG="$ROOT/testlogs/task9-tcp-$(date -u +%Y%m%dT%H%MZ).log"
IP=$(mktemp)
trap 'rm -f "$IP"' EXIT

[ "$(id -u)" -eq 0 ] || { echo "SUDO REQUIRED: sudo $0 $IFACE $TARGET $SECS $ACTION" >&2; exit 1; }
command -v iperf3 >/dev/null || { echo "iperf3 missing" >&2; exit 1; }
dev=$(ip route get "$TARGET" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
[ "$dev" = "$IFACE" ] || { echo "route to $TARGET uses $dev, not $IFACE; pin it: ip route replace $TARGET/32 dev $IFACE" >&2; exit 1; }

echo "== baseline iperf3 (gate off), 10s"
[ -n "${SKIP_BASE:-}" ] || iperf3 -c "$TARGET" -t 10 -i 5 "$@" 2>&1 | grep -E "sec|error" | tee -a "$LOG"

echo "== iperf3 with agent, ${SECS}s, action $ACTION"
iperf3 -c "$TARGET" -t "$SECS" -i 5 "$@" >"$IP" 2>&1 &
IPID=$!
env SRC_IF="$IFACE" "$ROOT/scripts/octep/offload-agent.py" --action "$ACTION" ${ALLOW_LOCAL:+--allow-local} \
	--seconds $((SECS + 2)) --lease 8 2>&1 | tee -a "$LOG" | grep -E "^conn |whole run|gate:"
wait "$IPID"
echo "== iperf3 intervals"
grep -E "sec|error" "$IP" | tee -a "$LOG"
echo "== summary"
echo "EFFECTIVE:   $(grep -c ': EFFECTIVE' "$LOG")"
echo "INEFFECTIVE: $(grep -c ': INEFFECTIVE' "$LOG")"
echo "log: $LOG"
