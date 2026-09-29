#!/usr/bin/env bash
# Step 2 test: with the IPsec tunnels up, the sites still talk to each other,
# but the WAN only sees encrypted ESP packets between the gateways.

source "$(dirname "$0")/../lab/common.sh"
require_root

CAP_DIR="${CAP_DIR:-$(dirname "$0")/../results}"
mkdir -p "$CAP_DIR"
CAP_DIR="$(cd "$CAP_DIR" && pwd)"

info "1. Tunnels"
check_tunnels() {  # check_tunnels <site>
  local sas ike child
  sas=$(swan "$1" --list-sas 2>/dev/null || true)
  ike=$(grep -c "ESTABLISHED" <<<"$sas" || true)
  child=$(grep -c "INSTALLED" <<<"$sas" || true)
  if [[ $ike -eq 2 && $child -eq 2 ]]; then
    ok "$1: 2 IKE SAs established, 2 IPsec SAs installed"
  else
    ko "$1: $ike IKE SAs, $child IPsec SAs (expected 2 and 2)"
    tail -n 20 "$STATE_DIR/$1/charon.log" | grep -v "plugin '" | sed 's/^/      /'
  fi
}
for s in "${SITES[@]}"; do check_tunnels "$s"; done
algo=$(swan site-a --list-sas 2>/dev/null | grep -m1 -E "ESP:" | sed 's/.*ESP:/ESP:/' || true)
ike_algo=$(swan site-a --list-sas 2>/dev/null | grep -m1 -E "^  AES" | sed 's/^ *//' || true)
echo "  Negotiated: IKE $ike_algo | $algo"

info "2. Connectivity through the tunnels"
check_ping() {  # check_ping <from> <to-ip> <label>
  if on "$1" ping -c 2 -W 1 -q "$2" >/dev/null 2>&1; then
    ok "$1 -> $3 ($2)"
  else
    ko "$1 -> $3 ($2)"
  fi
}
check_http() {  # check_http <from> <to-ip> <expected text>
  if on "$1" curl -s --max-time 3 "http://$2/" | grep -q "$3"; then
    ok "$1 opens http://$2/"
  else
    ko "$1 opens http://$2/"
  fi
}
check_ping host-a "$HOST_B" host-b
check_ping host-a "$HOST_C" host-c
check_ping host-b "$HOST_C" host-c
check_http host-a "$HOST_B" "host-b"
check_http host-c "$HOST_A" "host-a"
check_http host-b "$HOST_C" "host-c"

info "3. Public servers still reachable (outside the tunnels, as intended)"
check_http host-a "$WEB1" "Public web server 1"
check_http host-c "$WEB2" "Public web server 2"

info "4. What an observer on the WAN sees now"
bytes_out() {  # bytes sent in the site-a -> site-b tunnel
  swan site-a --list-sas --ike a-b 2>/dev/null \
    | awk '/ out /{gsub(",","",$3); print $3; exit}'
}
before=$(bytes_out)

PCAP="$CAP_DIR/step2-wan-encrypted.pcap"
on wan tcpdump -i to-a -U -w "$PCAP" >/dev/null 2>&1 &
TCPDUMP_PID=$!
sleep 1
on host-a ping -c 2 -W 1 -q "$HOST_B" >/dev/null 2>&1 || true
on host-a curl -s --max-time 3 "http://$HOST_B/" >/dev/null || true
on host-a curl -s --max-time 3 "http://$WEB1/" >/dev/null || true
sleep 1
kill "$TCPDUMP_PID" 2>/dev/null; wait "$TCPDUMP_PID" 2>/dev/null || true
after=$(bytes_out)

tcpdump -nn -r "$PCAP" 2>/dev/null > "$CAP_DIR/step2-wan-encrypted.txt"
echo "  Packets seen on the WAN link (site-a <-> site-b, first lines):"
grep "ESP" "$CAP_DIR/step2-wan-encrypted.txt" | head -n 4 | sed 's/^/    /'

if grep -q "62.59.1.2.* > 59.62.1.2.*ESP" "$CAP_DIR/step2-wan-encrypted.txt"; then
  ok "site-a -> site-b traffic crosses the WAN as ESP (encrypted)"
else
  ko "expected ESP packets between 62.59.1.2 and 59.62.1.2"
fi
if grep -qE "192\.168\.[0-9]+\.[0-9]+(\.[0-9]+)? > 192\.168\." "$CAP_DIR/step2-wan-encrypted.txt"; then
  ko "private site-to-site addresses are still visible on the WAN"
else
  ok "private addresses (192.168.x.x <-> 192.168.x.x) are hidden"
fi
if tcpdump -nn -A -r "$PCAP" 2>/dev/null | grep -aq "CONFIDENTIAL"; then
  ko "the confidential page is still readable on the WAN"
else
  ok "the confidential page is NOT readable on the WAN anymore"
fi
if tcpdump -nn -A -r "$PCAP" 2>/dev/null | grep -aq "Public web server 1"; then
  ok "traffic to the public server stays in clear (not a VPN destination)"
else
  ko "expected the public web server traffic in clear"
fi
if [[ -n "$before" && -n "$after" && "$after" -gt "$before" ]]; then
  ok "tunnel a-b byte counter went up ($before -> $after bytes)"
else
  ko "tunnel a-b byte counter did not move ($before -> $after)"
fi

echo
info "Result: $PASS passed, $FAIL failed"
echo "Capture saved to $PCAP (open it with Wireshark)."
[[ $FAIL -eq 0 ]]
