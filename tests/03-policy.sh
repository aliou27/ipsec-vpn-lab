#!/usr/bin/env bash
# Step 3 test: only HTTP, HTTPS and ping may go between the sites, always
# encrypted. Everything else is dropped, and when a tunnel goes down the
# traffic stops instead of leaking in clear (fail-closed).
#
# Must run last: it stops strongSwan on site B.

source "$(dirname "$0")/../lab/common.sh"
require_root

CAP_DIR="${CAP_DIR:-$(dirname "$0")/../results}"
mkdir -p "$CAP_DIR"
CAP_DIR="$(cd "$CAP_DIR" && pwd)"

get() {  # get <from> <url>: print the page, fail if unreachable
  on "$1" curl --noproxy '*' -sk --max-time 3 "$2"
}
allowed() {  # allowed <from> <url> <expected text> <label>
  if get "$1" "$2" | grep -q "$3"; then ok "$4"; else ko "$4"; fi
}
blocked() {  # blocked <from> <url> <label>
  if get "$1" "$2" >/dev/null; then ko "$3 (it went through!)"; else ok "$3"; fi
}
child_bytes() {  # child_bytes <site> <ike> <child> <in|out>
  swan "$1" --list-sas --ike "$2" 2>/dev/null | awk -v c="$3" -v d="$4" '
    $1 ~ /:$/ { cur = ($1 == c":") }
    cur && $1 == d { gsub(",", "", $3); sum += $3 }
    END { print sum + 0 }'
}
drops() {  # drops <site> <rule comment>: packets dropped by that firewall rule
  on "$1" nft list chain inet vpn_guard leak_block \
    | grep "$2" | sed -E 's/.*packets ([0-9]+).*/\1/'
}
capture() {  # capture <name> <interface...>: start tcpdump on the WAN router
  local name=$1; shift
  CAP_PIDS=()
  for itf in "$@"; do
    on wan tcpdump -i "$itf" -U -w "$CAP_DIR/$name-$itf.pcap" >/dev/null 2>&1 &
    CAP_PIDS+=($!)
  done
  sleep 1
}
stop_capture() {
  sleep 1
  kill "${CAP_PIDS[@]}" 2>/dev/null; wait "${CAP_PIDS[@]}" 2>/dev/null || true
}
cleartext_between_sites() {  # cleartext_between_sites <pcap...>: count leaked packets
  local n=0 f
  for f in "$@"; do
    n=$((n + $(tcpdump -nn -r "$f" 2>/dev/null \
      | grep -cE "IP 192\.168\.[0-9.]+ > 192\.168\." || true)))
  done
  echo "$n"
}

info "1. Allowed flows: HTTP, HTTPS and ping, in every direction"
allowed host-a "https://$HOST_B/" "host-b" "host-a -> host-b  HTTPS"
allowed host-b "https://$HOST_C/" "host-c" "host-b -> host-c  HTTPS"
allowed host-c "https://$HOST_A/" "host-a" "host-c -> host-a  HTTPS"
allowed host-b "http://$HOST_A/"  "host-a" "host-b -> host-a  HTTP"
if on host-c ping -c 2 -W 1 -q "$HOST_B" >/dev/null 2>&1; then
  ok "host-c -> host-b  ping"
else
  ko "host-c -> host-b  ping"
fi

info "2. Each direction uses its own IPsec SA (the replies are covered)"
out0=$(child_bytes site-a a-b web-out out); in0=$(child_bytes site-a a-b web-in out)
get host-a "https://$HOST_B/" >/dev/null || true
out1=$(child_bytes site-a a-b web-out out); in1=$(child_bytes site-a a-b web-in out)
if [[ $out1 -gt $out0 && $in1 -eq $in0 ]]; then
  ok "host-a (client) -> host-b (server) used site-a's web-out SA ($out0 -> $out1 bytes)"
else
  ko "host-a -> host-b: web-out $out0 -> $out1, web-in $in0 -> $in1"
fi
get host-b "https://$HOST_A/" >/dev/null || true
out2=$(child_bytes site-a a-b web-out out); in2=$(child_bytes site-a a-b web-in out)
if [[ $in2 -gt $in1 && $out2 -eq $out1 ]]; then
  ok "host-b (client) -> host-a (server) used site-a's web-in SA ($in1 -> $in2 bytes)"
else
  ko "host-b -> host-a: web-in $in1 -> $in2, web-out $out1 -> $out2"
fi

info "3. Everything else between sites is dropped, never sent in clear"
before_out=$(drops site-a "would leave")
capture step3-blocked to-a
blocked host-a "http://$HOST_B:8080/" "host-a -> host-b:8080 (internal app) is blocked"
blocked host-c "http://$HOST_A:8080/" "host-c -> host-a:8080 (internal app) is blocked"
stop_capture
leaks=$(cleartext_between_sites "$CAP_DIR"/step3-blocked-*.pcap)
if [[ $leaks -eq 0 ]] && ! tcpdump -nn -A -r "$CAP_DIR/step3-blocked-to-a.pcap" 2>/dev/null | grep -aq "ADMIN PANEL"; then
  ok "nothing from these attempts reached the WAN in clear"
else
  ko "$leaks cleartext site-to-site packets seen on the WAN"
fi
after_out=$(drops site-a "would leave")
echo "  site-a firewall, rule 'would leave in cleartext': $before_out -> $after_out packets dropped"

# An attacker on the WAN pretends to be site B and knocks on host-a's internal
# app. The packet arrives in clear, so site-a's firewall must drop it.
before_in=$(drops site-a "cleartext from another site")
on wan ip addr add 192.168.2.99/32 dev lo
if on wan curl --noproxy '*' -s --max-time 3 --interface 192.168.2.99 \
     "http://$HOST_A:8080/" >/dev/null; then
  ko "spoofed cleartext packet from the WAN reached host-a"
else
  ok "spoofed cleartext packet from the WAN (fake 192.168.2.99) is dropped by site-a"
fi
on wan ip addr del 192.168.2.99/32 dev lo
after_in=$(drops site-a "cleartext from another site")
echo "  site-a firewall, rule 'cleartext from another site': $before_in -> $after_in packets dropped"

info "4. Fail-closed: strongSwan stops on site B"
pids=$(ip netns pids site-b || true)
kill -TERM $pids 2>/dev/null || true
sleep 3
if swan site-a --list-sas 2>/dev/null | grep -q "a-b.*ESTABLISHED"; then
  echo "  (site-a still lists a tunnel to B)"
else
  echo "  tunnel A <-> B is gone"
fi
capture step3-failclosed to-a to-b
blocked host-a "http://$HOST_B/"  "host-a -> host-b HTTP no longer works"
if on host-a ping -c 2 -W 1 -q "$HOST_B" >/dev/null 2>&1; then
  ko "host-a -> host-b ping still works without the tunnel"
else
  ok "host-a -> host-b ping no longer works"
fi
stop_capture
leaks=$(cleartext_between_sites "$CAP_DIR"/step3-failclosed-*.pcap)
if [[ $leaks -eq 0 ]] && ! tcpdump -nn -A -r "$CAP_DIR/step3-failclosed-to-b.pcap" 2>/dev/null | grep -aq "CONFIDENTIAL"; then
  ok "no cleartext fallback: nothing readable crossed the WAN"
else
  ko "$leaks cleartext site-to-site packets crossed the WAN after the tunnel went down"
fi
allowed host-a "https://$HOST_C/" "host-c" "site A <-> site C is not affected (host-a -> host-c HTTPS)"

echo
info "Result: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
