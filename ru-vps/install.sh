#!/usr/bin/env bash
#
# RU VPS tooling installer.
#
# Installs ONLY the tools needed for the two-tier architecture and gets out
# of your way. No configs are generated, no services are started, no firewall
# is touched — that is all intentional: you manage AmneziaWG deployment via
# the AmneziaVPN app and keen-pbr routing via its config file + Web UI.
#
# What this script does:
#   1. apt-get the build and runtime deps
#   2. install amneziawg-dkms + amneziawg-tools
#      (so `awg-quick up <name>` works on the host for the RU→foreign client
#       tunnel — the AmneziaWG server for your home clients is deployed
#       separately via the AmneziaVPN app and runs in Docker)
#   3. build + install keen-pbr from source
#      (upstream publishes no Debian .deb yet — release workflow triggers on
#       a mistyped tag; when that's fixed upstream this script will pick up
#       the apt-installed package via the `command -v keen-pbr` shortcut)
#   4. enable ipv4/ipv6 forwarding + bbr
#
# What you do afterward:
#   a. Deploy AmneziaWG server on THIS VPS via AmneziaVPN app (for home clients)
#   b. Deploy AmneziaWG server on FOREIGN VPS via AmneziaVPN app
#   c. In AmneziaVPN app, create a client profile for the foreign server and
#      copy its .conf to THIS VPS, e.g. /etc/amnezia/amneziawg/foreign.conf
#   d. `systemctl enable --now awg-quick@foreign`
#      → interface `foreign` comes up, tunneling to the foreign VPS
#   e. Edit /etc/keen-pbr/config.json (use the shipped example as a starting
#      point) — point your "vpn" outbound at whatever interface you named in (d)
#   f. `systemctl restart keen-pbr`

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<EOF
Usage: sudo $0

Installs amneziawg-tools + keen-pbr on this RU VPS. No configuration is
written and no services are started; that's the whole point — you run the
AmneziaVPN app and author /etc/keen-pbr/config.json yourself.

Env overrides:
  KEENPBR_REF         git ref of keen-pbr to build (default: main)
  KEENPBR_BUILD_DIR   where to clone keen-pbr (default: /opt/smart-vpn/build/keen-pbr)
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) die "unknown arg: $1 (try --help)" ;;
esac

require_root "$@"
detect_os

log "base packages"
apt-get update -qq
apt_install ca-certificates curl gnupg git

install_amneziawg
install_keenpbr
enable_ip_forwarding

ok "RU VPS tooling ready."

PUBLIC_IP="$(public_ipv4 2>/dev/null || echo 'unknown')"

cat >&2 <<EOF

${C_GREEN}=== Installed ===${C_RESET}
  amneziawg-tools  : $(awg --version 2>&1 | head -n1)
  keen-pbr         : $(keen-pbr --version 2>&1 | head -n1)
  dnsmasq          : $(dnsmasq --version 2>&1 | head -n1 | awk '{print $1, $2, $3}')

${C_YELLOW}=== Manual steps (do these yourself) ===${C_RESET}

1. In AmneziaVPN app, deploy an AmneziaWG server on THIS VPS (${PUBLIC_IP})
   for your home clients (Keenetic / phones / laptop).

2. In AmneziaVPN app, deploy an AmneziaWG server on the foreign VPS.

3. In AmneziaVPN app, create a client profile for the foreign server and
   place its .conf on this VPS, e.g.:
     /etc/amnezia/amneziawg/foreign.conf

4. Bring it up:
     systemctl enable --now awg-quick@foreign
     awg show foreign              # expect 'latest handshake: <a few seconds ago>'
     ip -brief addr show foreign   # expect an address inside the foreign subnet

5. Craft /etc/keen-pbr/config.json. The shipped default at
   /etc/keen-pbr/config.json already parses; you likely want:
     - an "interface" outbound targeting the 'foreign' iface from step 4
     - whatever lists/rules fit your split policy
     - api.listen = "<AmneziaVPN-server-IP>:12121" so the Web UI is only
       reachable through your home-client AWG tunnel, not from the internet

6. systemctl restart keen-pbr
   journalctl -u keen-pbr -f     # watch it converge

EOF
