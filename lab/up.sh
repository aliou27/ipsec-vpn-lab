#!/usr/bin/env bash
# Build the network: 4 routers, 3 site hosts, 2 public web servers.
#
#                           web1 (.10)   web2 (.20)
#                               \          /
#                            [br0] 203.0.113.0/24
#                                   |
#                                 [wan]
#            62.59.1.0/30  /        |        \  59.62.1.0/30
#                         /    80.59.62.0/30   \
#                   [site-a]     [site-c]      [site-b]
#                      |            |             |
#              192.168.1.0/24  192.168.3.0/24  192.168.2.0/24
#                   host-a        host-c         host-b
#
# Step 1: plain routing, NO VPN. Everything crossing the WAN is readable.

source "$(dirname "$0")/common.sh"
require_root
require_tools

bash "$(dirname "$0")/down.sh" >/dev/null 2>&1 || true
mkdir -p "$STATE_DIR"

info "Creating machines"
for n in "${NODES[@]}"; do
  ip netns add "$n"
  on "$n" ip link set lo up
  # IPv6 off: keeps the packet captures short and readable.
  on "$n" sysctl -qw net.ipv6.conf.all.disable_ipv6=1 2>/dev/null || true
done
for r in "${ROUTERS[@]}"; do
  on "$r" sysctl -qw net.ipv4.ip_forward=1
done

# Cable two machines together: link <nodeA> <ifA> <nodeB> <ifB>
# (a veth pair is a virtual Ethernet cable with one end in each machine)
link() {
  ip link add "$2" netns "$1" type veth peer name "$4" netns "$3"
  on "$1" ip link set "$2" up
  on "$3" ip link set "$4" up
}

info "Cabling"
link wan to-a   site-a wan
link wan to-b   site-b wan
link wan to-c   site-c wan
link site-a lan host-a eth0
link site-b lan host-b eth0
link site-c lan host-c eth0

# Public server segment: a switch (Linux bridge) inside the wan router.
on wan ip link add br0 type bridge
on wan ip link set br0 up
link wan web1-port web1 eth0
link wan web2-port web2 eth0
on wan ip link set web1-port master br0
on wan ip link set web2-port master br0

info "Addressing"
on wan    ip addr add 62.59.1.1/30    dev to-a
on wan    ip addr add 59.62.1.1/30    dev to-b
on wan    ip addr add 80.59.62.1/30   dev to-c
on wan    ip addr add 203.0.113.1/24  dev br0

on site-a ip addr add 62.59.1.2/30    dev wan
on site-a ip addr add 192.168.1.1/24  dev lan
on site-b ip addr add 59.62.1.2/30    dev wan
on site-b ip addr add 192.168.2.1/24  dev lan
on site-c ip addr add 80.59.62.2/30   dev wan
on site-c ip addr add 192.168.3.1/24  dev lan

on host-a ip addr add "$HOST_A/24" dev eth0
on host-b ip addr add "$HOST_B/24" dev eth0
on host-c ip addr add "$HOST_C/24" dev eth0
on web1   ip addr add "$WEB1/24"   dev eth0
on web2   ip addr add "$WEB2/24"   dev eth0

info "Static routing"
# Sites: everything goes to the WAN router.
on site-a ip route add default via 62.59.1.1
on site-b ip route add default via 59.62.1.1
on site-c ip route add default via 80.59.62.1
# Hosts and servers: default gateway.
on host-a ip route add default via 192.168.1.1
on host-b ip route add default via 192.168.2.1
on host-c ip route add default via 192.168.3.1
on web1   ip route add default via 203.0.113.1
on web2   ip route add default via 203.0.113.1
# WAN router: how to reach each site LAN (needed so the public servers can
# answer the sites, since there is no NAT in this lab).
on wan ip route add 192.168.1.0/24 via 62.59.1.2
on wan ip route add 192.168.2.0/24 via 59.62.1.2
on wan ip route add 192.168.3.0/24 via 80.59.62.2

info "Starting web servers"
start_web() {  # start_web <node> <ip> <page text>
  local dir="$STATE_DIR/www/$1"
  mkdir -p "$dir"
  printf '%s\n' "$3" > "$dir/index.html"
  on "$1" python3 -m http.server 80 --bind "$2" --directory "$dir" \
    >"$STATE_DIR/$1-http.log" 2>&1 &
}
start_web host-a "$HOST_A" "Hello from host-a (site A)"
start_web host-b "$HOST_B" "Hello from host-b (site B). CONFIDENTIAL: site B payroll 2026"
start_web host-c "$HOST_C" "Hello from host-c (site C)"
start_web web1   "$WEB1"   "Public web server 1"
start_web web2   "$WEB2"   "Public web server 2"

# Wait until every web server answers locally.
for pair in "host-a $HOST_A" "host-b $HOST_B" "host-c $HOST_C" "web1 $WEB1" "web2 $WEB2"; do
  set -- $pair
  for _ in $(seq 1 50); do
    on "$1" curl -s -o /dev/null "http://$2/" && break
    sleep 0.1
  done
done

info "Lab is up: ${#NODES[@]} machines"
