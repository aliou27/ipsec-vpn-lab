#!/usr/bin/env bash
# Step 1 test: the network works, and WITHOUT a VPN the traffic between sites
# is readable by anyone who can see the WAN (an ISP, an attacker on the path).

source "$(dirname "$0")/../lab/common.sh"
require_root

CAP_DIR="${CAP_DIR:-$(dirname "$0")/../results}"
mkdir -p "$CAP_DIR"
CAP_DIR="$(cd "$CAP_DIR" && pwd)"

info "1. Connectivity (ping)"
check_ping() {  # check_ping <from> <to-ip> <label>
  if on "$1" ping -c 2 -W 1 -q "$2" >/dev/null 2>&1; then
    ok "$1 -> $3 ($2)"
  else
    ko "$1 -> $3 ($2)"
  fi
}
check_ping host-a "$HOST_B" host-b
check_ping host-a "$HOST_C" host-c
check_ping host-b "$HOST_C" host-c
check_ping host-a "$WEB1"   web1
check_ping host-b "$WEB2"   web2
check_ping host-c "$WEB1"   web1

info "2. Web access (HTTP)"
check_http() {  # check_http <from> <to-ip> <label>
  if on "$1" curl -s --max-time 3 "http://$2/" | grep -q "$3"; then
    ok "$1 opens http://$2/"
  else
    ko "$1 opens http://$2/"
  fi
}
check_http host-a "$HOST_B" "host-b"
check_http host-c "$HOST_A" "host-a"
check_http host-b "$WEB1"   "Public web server 1"

info "3. What an observer on the WAN sees"
# Capture on the WAN router's cable towards site A while host-a downloads
# host-b's page, which contains a confidential line.
PCAP="$CAP_DIR/step1-wan-cleartext.pcap"
on wan tcpdump -i to-a -U -w "$PCAP" 'host 62.59.1.2 or net 192.168.0.0/16' \
  >/dev/null 2>&1 &
TCPDUMP_PID=$!
sleep 1
on host-a ping -c 2 -W 1 -q "$HOST_B" >/dev/null 2>&1 || true
on host-a curl -s --max-time 3 "http://$HOST_B/" >/dev/null || true
sleep 1
kill "$TCPDUMP_PID" 2>/dev/null; wait "$TCPDUMP_PID" 2>/dev/null || true

tcpdump -nn -r "$PCAP" 2>/dev/null > "$CAP_DIR/step1-wan-cleartext.txt"
tcpdump -nn -A -r "$PCAP" 2>/dev/null | grep -ao "Hello from host-b.*CONFIDENTIAL.*" \
  > "$CAP_DIR/step1-wan-leak.txt" || true

echo "  Packets seen on the WAN link (first lines):"
head -n 6 "$CAP_DIR/step1-wan-cleartext.txt" | sed 's/^/    /'

if grep -q "ICMP echo request" "$CAP_DIR/step1-wan-cleartext.txt"; then
  ok "ping between sites is visible in clear (ICMP, private IPs exposed)"
else
  ko "expected to see the ping in clear on the WAN"
fi
if [[ -s "$CAP_DIR/step1-wan-leak.txt" ]]; then
  ok "web page content is readable on the WAN:"
  sed 's/^/      > /' "$CAP_DIR/step1-wan-leak.txt"
else
  ko "expected to read the confidential line on the WAN"
fi

echo
info "Result: $PASS passed, $FAIL failed"
echo "Capture saved to $PCAP (open it with Wireshark)."
echo "Conclusion: without a VPN, the WAN sees who talks to whom AND what they say."
[[ $FAIL -eq 0 ]]
