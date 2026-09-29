#!/usr/bin/env bash
# Entry point.
#   sudo bash run.sh        full scenario: network, test without VPN,
#                           start the VPN, test with VPN, tear down
#   sudo bash run.sh up     build the network AND start the VPN (to explore)
#   sudo bash run.sh test   run the VPN tests on a lab that is up
#   sudo bash run.sh down   destroy the lab
set -euo pipefail
cd "$(dirname "$0")"

vpn_tests() {
  local rc=0
  for t in tests/0[2-9]*.sh; do bash "$t" || rc=1; done
  return $rc
}

save_logs() {
  mkdir -p results/logs
  for s in site-a site-b site-c; do
    cp "/tmp/ipsec-lab/$s/charon.log" "results/logs/$s-charon.log" 2>/dev/null || true
  done
}

case "${1:-all}" in
  up)
    bash lab/up.sh
    bash lab/vpn-up.sh
    ;;
  test) vpn_tests ;;
  down) bash lab/down.sh ;;
  all)
    rc=0
    bash lab/up.sh
    echo; echo "=== BEFORE: no VPN ==="
    bash tests/01-baseline.sh || rc=1
    echo; echo "=== AFTER: IPsec VPN ==="
    bash lab/vpn-up.sh
    vpn_tests || rc=1
    save_logs
    bash lab/down.sh
    exit $rc
    ;;
  *) echo "usage: sudo bash run.sh [up|test|down]"; exit 2 ;;
esac
