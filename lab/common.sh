#!/usr/bin/env bash
# Shared settings for the lab. Every other script sources this file.
#
# Each "machine" of the lab is a Linux network namespace: an isolated copy of
# the network stack (its own interfaces, IP addresses, routes and firewall).
# It is the same technology Docker uses for container networking, without the
# rest of Docker.

set -euo pipefail

# Where runtime files go (web pages, PIDs, captures). Not committed to git.
STATE_DIR="${STATE_DIR:-/tmp/ipsec-lab}"

# All the machines of the lab.
ROUTERS=(wan site-a site-b site-c)
HOSTS=(host-a host-b host-c web1 web2)
NODES=("${ROUTERS[@]}" "${HOSTS[@]}")

# Addressing plan (same as the IPSL exercise 1 subject).
#   WAN links (/30)          Site LANs (/24)          Public servers (/24)
#   A: 62.59.1.0/30          A: 192.168.1.0/24        203.0.113.0/24
#   B: 59.62.1.0/30          B: 192.168.2.0/24        (RFC 5737 documentation range)
#   C: 80.59.62.0/30         C: 192.168.3.0/24
HOST_A=192.168.1.10
HOST_B=192.168.2.10
HOST_C=192.168.3.10
WEB1=203.0.113.10
WEB2=203.0.113.20

# Run a command inside a machine:  on host-a ping 192.168.2.10
on() {
  local node="$1"; shift
  ip netns exec "$node" "$@"
}

# Pretty output for tests.
PASS=0
FAIL=0
ok()   { printf '  \033[32m[PASS]\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
ko()   { printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
info() { printf '\033[1m%s\033[0m\n' "$*"; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This lab creates network namespaces and needs root. Run it with sudo." >&2
    exit 1
  fi
}

require_tools() {
  local missing=()
  for t in ip tcpdump curl ping python3; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if ((${#missing[@]})); then
    echo "Missing tools: ${missing[*]}" >&2
    echo "On Ubuntu/Debian: sudo apt-get install -y iproute2 tcpdump curl iputils-ping python3" >&2
    exit 1
  fi
}
