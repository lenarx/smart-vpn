#!/usr/bin/env bash
#
# Generate a WireGuard / AmneziaWG client profile, splice its [Peer] block
# into the server config, and hot-reload. Protocol is auto-detected from
# /root/smart-vpn/ru.env (written by ru-vps/install.sh).
#
# Produces:
#   /root/smart-vpn/clients/<name>.conf  — import into WireGuard or AmneziaVPN app
#   /root/smart-vpn/clients/<name>.png   — QR code

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

STATE_DIR="/root/smart-vpn"
OUT_DIR="$STATE_DIR/clients"
RU_ENV="$STATE_DIR/ru.env"

[[ $# -ge 1 ]] || die "usage: sudo $0 <client-name> [--dns 1.1.1.1]"

CLIENT="$1"; shift || true
CLIENT_DNS="1.1.1.1, 8.8.8.8"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dns) CLIENT_DNS="$2"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[[ "$CLIENT" =~ ^[a-zA-Z0-9._-]+$ ]] || die "client name must match [a-zA-Z0-9._-]+"

require_root "$@"
[[ -f "$RU_ENV" ]] || die "$RU_ENV missing — run ru-vps/install.sh first"
load_env_file "$RU_ENV"
: "${VPN_PROTO:?}" "${WG_CMD:?}" "${WG_QUICK:?}" "${WG_IF:?}" "${WG_CONF:?}" \
  "${WG_META:?}" "${WG_PORT:?}" "${WG_SUBNET:?}" "${WG_SERVER_PUB:?}"

[[ -f "$WG_CONF" ]] || die "$WG_CONF not found — server config missing"

install -d -m 0700 "$OUT_DIR"
CLIENT_CONF="$OUT_DIR/${CLIENT}.conf"
[[ -e "$CLIENT_CONF" ]] && die "client '${CLIENT}' already exists at $CLIENT_CONF — rename or remove first"

# --- allocate next IP in WG_SUBNET ------------------------------------------
# shellcheck disable=SC1090
. "$WG_META"
: "${next_ip:?next_ip missing from $WG_META}"
NETWORK="${WG_SUBNET%/*}"
PREFIX="${WG_SUBNET#*/}"
BASE3="${NETWORK%.*}"
CLIENT_IP="${BASE3}.${next_ip}"
[[ "$next_ip" -lt 255 ]] || die "WG subnet exhausted (next_ip=$next_ip)"

# --- keys --------------------------------------------------------------------
umask 077
CLIENT_PRIV="$("$WG_CMD" genkey)"
CLIENT_PUB="$("$WG_CMD" pubkey <<<"$CLIENT_PRIV")"
CLIENT_PSK="$("$WG_CMD" genpsk)"
PUBLIC_IP="$(public_ipv4)"

# --- append peer + hot-reload -----------------------------------------------
log "registering peer '${CLIENT}' (${CLIENT_IP}/32) on ${WG_IF} (${VPN_PROTO})"
cat >>"$WG_CONF" <<EOF

[Peer]
# ${CLIENT}
PublicKey    = ${CLIENT_PUB}
PresharedKey = ${CLIENT_PSK}
AllowedIPs   = ${CLIENT_IP}/32
EOF

# syncconf applies peer changes without dropping established sessions.
"$WG_CMD" syncconf "$WG_IF" <("$WG_QUICK" strip "$WG_IF")

sed -i "s/^next_ip=.*/next_ip=$((next_ip + 1))/" "$WG_META"

# --- client config -----------------------------------------------------------
{
  cat <<EOF
# smart-vpn client: ${CLIENT}  (protocol: ${VPN_PROTO})
[Interface]
PrivateKey = ${CLIENT_PRIV}
Address    = ${CLIENT_IP}/${PREFIX}
DNS        = ${CLIENT_DNS}
MTU        = 1420
EOF
  if [[ "$VPN_PROTO" == "amneziawg" ]]; then
    cat <<EOF
Jc   = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1   = ${AWG_S1}
S2   = ${AWG_S2}
H1   = ${AWG_H1}
H2   = ${AWG_H2}
H3   = ${AWG_H3}
H4   = ${AWG_H4}
EOF
  fi
  cat <<EOF

[Peer]
PublicKey    = ${WG_SERVER_PUB}
PresharedKey = ${CLIENT_PSK}
Endpoint     = ${PUBLIC_IP}:${WG_PORT}
AllowedIPs   = 0.0.0.0/0
PersistentKeepalive = 25
EOF
} >"$CLIENT_CONF"
chmod 0600 "$CLIENT_CONF"

QR_PATH="$OUT_DIR/${CLIENT}.png"
qrencode -t PNG -o "$QR_PATH" <"$CLIENT_CONF"

ok "client '${CLIENT}' created"
echo >&2
echo "  config : $CLIENT_CONF" >&2
echo "  QR     : $QR_PATH" >&2
if [[ "$VPN_PROTO" == "amneziawg" ]]; then
  echo >&2
  echo "  Import into the dedicated AmneziaWG app (NOT the main AmneziaVPN app):" >&2
  echo "    iOS      — AmneziaWG on the App Store" >&2
  echo "    Android  — Google Play, package: org.amnezia.awg" >&2
  echo "    Windows  — github.com/amnezia-vpn/amneziawg-windows-client/releases" >&2
  echo "    Keenetic — KeeneticOS 4.2+, install the 'amneziawg' component," >&2
  echo "               then Internet -> Other connections -> AmneziaWG." >&2
  echo "  (Stock WireGuard apps won't accept the Jc/S/H obfuscation params.)" >&2
fi
echo >&2
echo "--- QR (scan from the target app) ---" >&2
qrencode -t ANSIUTF8 <"$CLIENT_CONF" >&2
