#!/usr/bin/env bash
# Entry point.
#   sudo bash run.sh up     build the lab
#   sudo bash run.sh test   run the tests
#   sudo bash run.sh down   destroy the lab
#   sudo bash run.sh        all of the above, in order
set -euo pipefail
cd "$(dirname "$0")"

case "${1:-all}" in
  up)   bash lab/up.sh ;;
  down) bash lab/down.sh ;;
  test) for t in tests/*.sh; do bash "$t"; done ;;
  all)
    bash lab/up.sh
    rc=0
    for t in tests/*.sh; do bash "$t" || rc=1; done
    bash lab/down.sh
    exit $rc
    ;;
  *) echo "usage: sudo bash run.sh [up|test|down]"; exit 2 ;;
esac
