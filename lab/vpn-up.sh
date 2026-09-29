#!/usr/bin/env bash
# Step 2: start strongSwan on the three site gateways and bring the tunnels up.
#
# For each site:
#   1. generate the pre-shared keys (random, never stored in git)
#   2. start the strongSwan daemon (charon) inside the site's namespace
#   3. load vpn/<site>/swanctl.conf into it
#
# Set LAB_USERSPACE_ESP=1 on machines whose kernel has no ESP support
# (some sandboxes and containers): strongSwan then encrypts in userspace
# through a TUN device instead of in the kernel. GitHub runners don't need it.

source "$(dirname "$0")/common.sh"
require_root
command -v swanctl >/dev/null || { echo "Install strongswan-charon and strongswan-swanctl" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHARON=/usr/lib/ipsec/charon

# Ubuntu confines charon and swanctl with AppArmor profiles that only allow
# the default paths (/etc/swanctl, /run/charon.vici). Our lab runs 3 daemons
# with per-site paths, so we unload these profiles for the lab.
if [[ -r /sys/kernel/security/apparmor/profiles ]]; then
  for prof in usr.lib.ipsec.charon usr.sbin.swanctl; do
    if [[ -f /etc/apparmor.d/$prof ]]; then
      apparmor_parser -R "/etc/apparmor.d/$prof" 2>/dev/null || true
    fi
  done
fi

info "Generating pre-shared keys (one per tunnel)"
key() { echo "0x$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"; }
KEY_AB=$(key); KEY_AC=$(key); KEY_BC=$(key)

secret_block() {  # secret_block <name> <id1> <id2> <key>
  printf '%s {\n  id-1 = %s\n  id-2 = %s\n  secret = %s\n}\n' "$1" "$2" "$3" "$4"
}

for site in "${SITES[@]}"; do
  dir="$STATE_DIR/$site"
  mkdir -p "$dir/run" "$dir/x509" "$dir/x509ca" "$dir/private"
  cp "$REPO_DIR/vpn/$site/swanctl.conf" "$dir/swanctl.conf"
  chmod 700 "$dir"
done

{ secret_block ike-ab site-a site-b "$KEY_AB"; secret_block ike-ac site-a site-c "$KEY_AC"; } \
  > "$STATE_DIR/site-a/secrets.conf"
{ secret_block ike-ab site-a site-b "$KEY_AB"; secret_block ike-bc site-b site-c "$KEY_BC"; } \
  > "$STATE_DIR/site-b/secrets.conf"
{ secret_block ike-ac site-a site-c "$KEY_AC"; secret_block ike-bc site-b site-c "$KEY_BC"; } \
  > "$STATE_DIR/site-c/secrets.conf"

info "Starting strongSwan on each site"
for site in "${SITES[@]}"; do
  dir="$STATE_DIR/$site"

  if [[ "${LAB_USERSPACE_ESP:-0}" == 1 ]]; then
    extra='kernel-libipsec {
      load = yes
    }'
    routes=yes
  else
    extra=''
    routes=no
  fi

  cat > "$dir/strongswan.conf" <<EOF
charon {
  load_modular = yes
  install_routes = $routes
  filelog {
    stderr {
      default = 1
      ike = 1
    }
  }
  plugins {
    include /etc/strongswan.d/charon/*.conf
    vici {
      socket = unix://$dir/run/charon.vici
    }
    $extra
  }
}
include /etc/strongswan.d/*.conf
EOF

  # charon expects to own /run (PID file, sockets). Each site gets a private
  # view where /run is its own folder, so the three daemons don't collide.
  on "$site" unshare -m sh -c "
    mount --bind '$dir/run' /run
    STRONGSWAN_CONF='$dir/strongswan.conf' exec $CHARON
  " > "$dir/charon.log" 2>&1 &
done

# Load the answering sides first: C only answers, B answers A and opens B-C,
# A opens A-B and A-C. Otherwise A would call a peer that isn't ready yet.
for site in site-c site-b site-a; do
  for _ in $(seq 1 50); do
    [[ -S "$STATE_DIR/$site/run/charon.vici" ]] && break
    sleep 0.1
  done
  swan "$site" --load-all --file "$STATE_DIR/$site/swanctl.conf" >/dev/null
done

info "Waiting for the tunnels"
established() {  # number of IKE SAs up on a site
  swan "$1" --list-sas 2>/dev/null | grep -c "ESTABLISHED" || true
}
for _ in $(seq 1 40); do
  a=$(established site-a); b=$(established site-b); c=$(established site-c)
  [[ $a -ge 2 && $b -ge 2 && $c -ge 2 ]] && break
  sleep 0.5
done
echo "  IKE SAs up: site-a=$a site-b=$b site-c=$c (expected 2 each)"
info "VPN is up"
