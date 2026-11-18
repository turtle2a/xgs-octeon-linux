#!/bin/sh
# Run on the iperf server after a capture of the NAT stall:
#   sudo tcpdump -nn -e -i any 'tcp port 5201' -w /tmp/stall.pcap
# Usage: server-stall-check.sh [/tmp/stall.pcap] [client-ip]
# Prints the bad-checksum count, the first bad frames with MACs, and packets per second.
PCAP=${1:-/tmp/stall.pcap}
CLIENT=${2:-192.168.1.14}
[ -r "$PCAP" ] || { echo "server-stall-check: cannot read $PCAP" >&2; exit 2; }
TXT=$(mktemp) || exit 2
trap 'rm -f "$TXT"' EXIT
tcpdump -nn -vv -e -tt -r "$PCAP" >"$TXT" 2>/dev/null

echo "== total frames: $(grep -c . "$TXT")"
echo "== frames from $CLIENT: $(grep -c "$CLIENT\.[0-9]* >" "$TXT")"
echo "== bad checksum (all): $(grep -c -iE 'bad cksum|incorrect' "$TXT")"
echo "== bad checksum from $CLIENT: $(grep -iE 'bad cksum|incorrect' "$TXT" | grep -c "$CLIENT\.[0-9]* >")"
echo "== first 6 bad frames"
grep -m6 -iE 'bad cksum|incorrect|bad hdr|bad length' "$TXT"
echo "== source MAC / dest MAC pairs from $CLIENT"
grep "$CLIENT\.[0-9]* >" "$TXT" | awk '{print $2, $3, $4}' | sort | uniq -c | sort -rn | head -5
echo "== frames per second from $CLIENT (epoch second, count, bad)"
grep "$CLIENT\.[0-9]* >" "$TXT" | awk '{t=int($1); n[t]++; if ($0 ~ /bad cksum|incorrect/) b[t]++}
	END {for (t in n) print t, n[t], b[t]+0}' | sort -n | head -40
