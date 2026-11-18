#!/bin/bash
# NAT content test (Task 9 item 2, "Flow-write path"): closes the "NAT bytes unproven" gap.
# octep-nat-offload.sh shows that a NAT block is derived and frames are forwarded; it does not
# show the rewritten bytes are right. This test SNATs one fixed UDP flow (host -> TARGET:53) to
# SNAT_IP, lets the offload agent write it to the NPU, and round-trips DNS queries through it.
# Every reply is checked byte-for-byte: TXID, header flags, question section (QNAME case is
# randomised per query, 0x20-style, so each reply is matched unambiguously), and the A record
# rdata against EXPECT_A. tcpdump on IFACE independently checks the wire: source address of
# queries is SNAT_IP, and no "bad udp cksum" / "bad cksum" on any packet.
# PASS means: the flow offloaded (nat from conntrack with nat_src=SNAT_IP, EFFECTIVE), all N
# replies arrived intact (0 malformed, 0 mismatched, 0 lost, no retries sent), and 0 bad checksums
# were seen on the wire. A lost or corrupted reply is a FAIL, never retried.
# Needs a resolver at TARGET that answers QNAME with the fixed A record EXPECT_A.
#   sudo scripts/tests/octep-nat-dns-echo.sh [IFACE] [TARGET] [SNAT_IP] [SECONDS]
# Env: QNAME (default example.com)  EXPECT_A (required, e.g. 93.184.216.34)  RATE (queries/s, default 5)
#      SPORT (fixed UDP source port, default 41053)  LEASE (agent lease, default 8)
set -u
IFACE=${1:-octep1}
TARGET=${2:-192.168.1.1}
SNAT_IP=${3:-}
SECS=${4:-45}
QNAME=${QNAME:-example.com}
EXPECT_A=${EXPECT_A:-}
RATE=${RATE:-5}
SPORT=${SPORT:-41053}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
LOG="$ROOT/testlogs/task9-natdnsecho-$(date -u +%Y%m%dT%H%MZ).log"
WORK="$ROOT/testlogs/.natdnsecho-$$"
TABLE=xgs_natdns

[ "$(id -u)" -eq 0 ] || { echo "SUDO REQUIRED: sudo $0 $IFACE $TARGET $SNAT_IP $SECS" >&2; exit 1; }
[ -n "$SNAT_IP" ] || { echo "SNAT_IP is required" >&2; exit 1; }
[ -n "$EXPECT_A" ] || { echo "EXPECT_A (known A record of $QNAME at $TARGET) is required" >&2; exit 1; }
for t in tcpdump python3 nft ip; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }; done
mkdir -p "$ROOT/testlogs" "$WORK"
cleanup() {
	[ -n "${TCPD:-}" ] && kill "$TCPD" 2>/dev/null
	nft delete table ip $TABLE 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

dev=$(ip route get "$TARGET" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
[ "$dev" = "$IFACE" ] || { echo "route to $TARGET uses $dev, not $IFACE" >&2; exit 1; }
ip -4 addr show | grep -q "inet $SNAT_IP/" || { echo "$SNAT_IP is not a local address" >&2; exit 1; }

nft add table ip $TABLE
nft "add chain ip $TABLE post { type nat hook postrouting priority 100; }"
nft add rule ip $TABLE post oifname "$IFACE" ip daddr "$TARGET" udp dport 53 snat to "$SNAT_IP"
# octep3 holds SNAT_IP on the same LAN, so the peer may resolve it to octep3's MAC; point it at IFACE
arping -q -c 2 -U -I "$IFACE" -s "$SNAT_IP" "$SNAT_IP" 2>/dev/null

dnsclient() {
	python3 - "$@" <<'PY'
import random, socket, struct, sys, time
target, qname, expect, sport, rate, secs = sys.argv[1:7]
sport, rate, secs = int(sport), float(rate), float(secs)
want = socket.inet_aton(expect)
labels = qname.rstrip(".").split(".")
sent = ok = lost = bad = mism = 0
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("", sport))
end = time.time() + secs
interval = 1.0 / rate
n = 0
while n == 0 or time.time() < end:
    t0 = time.time()
    n += 1
    txid = random.getrandbits(16)
    # random case per query: the server must echo it, so the question bytes are unique per query
    cased = [("".join(c.upper() if random.getrandbits(1) else c.lower() for c in l)).encode() for l in labels]
    q = b"".join(bytes([len(l)]) + l for l in cased) + b"\0" + struct.pack(">HH", 1, 1)
    pkt = struct.pack(">HHHHHH", txid, 0x0100, 1, 0, 0, 0) + q
    sock.sendto(pkt, (target, 53))
    sent += 1
    reply = None
    sock.settimeout(1.0)
    try:
        while True:
            data, addr = sock.recvfrom(4096)
            if addr[0] == target and len(data) >= 2 and struct.unpack(">H", data[:2])[0] == txid:
                reply = data
                break
    except socket.timeout:
        lost += 1
        print("LOST txid=%04x" % txid)
    if reply is not None:
        why = None
        if len(reply) < 12 + len(q) + 16:
            why = ("malformed", "short reply len=%d" % len(reply))
        else:
            _, flags, qd, an = struct.unpack(">HHHH", reply[:8])
            if not flags & 0x8000 or flags & 0xF != 0 or qd != 1 or an < 1:
                why = ("malformed", "bad header flags=%04x qd=%d an=%d" % (flags, qd, an))
            elif reply[12:12 + len(q)] != q:
                why = ("mismatch", "question not echoed byte-exact")
            else:
                # first answer: name (pointer or inline), type, class, ttl, rdlength, rdata
                i = 12 + len(q)
                i = i + 2 if reply[i] & 0xC0 == 0xC0 else i
                if len(reply) < i + 10 + 4 or struct.unpack(">HH", reply[i:i + 4]) != (1, 1):
                    why = ("malformed", "answer is not IN A / truncated")
                else:
                    rdlen = struct.unpack(">H", reply[i + 8:i + 10])[0]
                    rdata = reply[i + 10:i + 10 + rdlen]
                    if rdlen != 4 or len(rdata) != 4:
                        why = ("malformed", "rdlength %d" % rdlen)
                    elif rdata != want:
                        why = ("mismatch", "A rdata %s != %s" % (socket.inet_ntoa(rdata), expect))
        if why is None:
            ok += 1
        else:
            bad += why[0] == "malformed"
            mism += why[0] == "mismatch"
            print("BAD txid=%04x %s: %s" % (txid, why[1], reply.hex()))
    time.sleep(max(0, interval - (time.time() - t0)))
print("sent=%d\nok=%d\nlost=%d\nmalformed=%d\nmismatch=%d" % (sent, ok, lost, bad, mism))
sys.exit(0 if ok == sent else 1)
PY
}

echo "== preflight: one plain query before the agent starts"
dnsclient "$TARGET" "$QNAME" "$EXPECT_A" $((SPORT + 1)) 1 0 >/dev/null ||
	{ echo "FAIL: preflight (no valid reply from $TARGET for $QNAME; fix resolver/EXPECT_A first)"; exit 1; }
echo "== SNAT-udp-dns: $QNAME A via $TARGET from $SNAT_IP, ${RATE}/s for ${SECS}s"
tcpdump -l -n -vv -i "$IFACE" "udp port 53 and host $TARGET" >"$WORK/wire.txt" 2>&1 &
TCPD=$!
sleep 1

env SRC_IF="$IFACE" "$ROOT/scripts/octep/offload-agent.py" --seconds "$SECS" --lease "${LEASE:-8}" 2>&1 |
	tee -a "$LOG" | grep -E "nat from conntrack|^conn |reclaim conn|Traceback|Error|rate:|per-second" &
AGENT=$!
sleep 3
dnsclient "$TARGET" "$QNAME" "$EXPECT_A" "$SPORT" "$RATE" $((SECS - 6)) >"$WORK/client.txt"
wait $AGENT 2>/dev/null
sleep 1
kill "$TCPD" 2>/dev/null; TCPD=""
wait 2>/dev/null

echo "-- client:"
cat "$WORK/client.txt" | tee -a "$LOG"
echo "-- conntrack during phase:"
grep -E "udp" /proc/net/nf_conntrack | grep -E "dport=53" | grep -E "$TARGET" | head -2

echo "== summary"
sent=$(sed -n 's/^sent=//p' "$WORK/client.txt")
ok=$(sed -n 's/^ok=//p' "$WORK/client.txt")
lost=$(sed -n 's/^lost=//p' "$WORK/client.txt")
bad=$(sed -n 's/^malformed=//p' "$WORK/client.txt")
mism=$(sed -n 's/^mismatch=//p' "$WORK/client.txt")
nat_blocks=$(grep -c "nat from conntrack.*'nat_src': '$SNAT_IP'" "$LOG")
effective=$(grep -c ': EFFECTIVE' "$LOG")
ineffective=$(grep -c ': INEFFECTIVE' "$LOG")
badck=$(grep -ciE "bad (udp )?cksum|incorrect" "$WORK/wire.txt")
qwire=$(grep -cE "IP .*\.$SPORT > $TARGET\.53|$SNAT_IP\.[0-9]+ > $TARGET\.53" "$WORK/wire.txt")
qsnat=$(grep -cE "$SNAT_IP\.[0-9]+ > $TARGET\.53" "$WORK/wire.txt")
echo "NAT blocks derived (nat_src=$SNAT_IP): $nat_blocks"
echo "EFFECTIVE:   $effective"
echo "INEFFECTIVE: $ineffective"
echo "queries sent:        ${sent:-0}"
echo "replies byte-correct: ${ok:-0}"
echo "lost/timeout:        ${lost:-0}"
echo "malformed/truncated: ${bad:-0}"
echo "mismatched content:  ${mism:-0}"
echo "retries:             0"
echo "wire queries seen: $qwire (with source $SNAT_IP: $qsnat)"
echo "wire bad checksums:  $badck"
echo "log: $LOG"

fail=0
chk() { if [ "$2" = ok ]; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }
[ "$nat_blocks" -ge 1 ] && chk "NAT block derived with nat_src=$SNAT_IP" ok || chk "NAT block derived with nat_src=$SNAT_IP" no
[ "$effective" -ge 1 ] && [ "$ineffective" -eq 0 ] && chk "flow offload EFFECTIVE" ok || chk "flow offload EFFECTIVE" no
[ "${sent:-0}" -gt 0 ] && [ "${ok:-0}" -eq "${sent:-0}" ] && chk "all ${sent:-0} replies byte-correct" ok || chk "all replies byte-correct" no
[ "${bad:-1}" -eq 0 ] && [ "${mism:-1}" -eq 0 ] && chk "0 malformed, 0 mismatched" ok || chk "0 malformed, 0 mismatched" no
[ "${lost:-1}" -eq 0 ] && chk "0 lost (no retries needed)" ok || chk "0 lost (no retries needed)" no
[ "$qsnat" -ge 1 ] && [ "$qsnat" -eq "$qwire" ] && chk "wire queries all sourced from $SNAT_IP" ok || chk "wire queries all sourced from $SNAT_IP" no
[ "$badck" -eq 0 ] && chk "0 bad checksums on the wire" ok || chk "0 bad checksums on the wire" no
[ "$fail" -eq 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$fail"
