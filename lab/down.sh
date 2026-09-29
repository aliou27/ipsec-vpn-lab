#!/usr/bin/env bash
# Tear the lab down: stop every process started inside the machines, then
# delete the namespaces (which also deletes their interfaces and cables).

source "$(dirname "$0")/common.sh"
require_root

for n in "${NODES[@]}"; do
  if ip netns list | grep -qw "^$n"; then
    pids=$(ip netns pids "$n" || true)
    [[ -n "$pids" ]] && kill $pids 2>/dev/null || true
    ip netns del "$n"
  fi
done
rm -rf "$STATE_DIR"
info "Lab is down"
