#!/usr/bin/env bash
#
# Foreign VPS provisioning — sing-box as VLESS+Reality server.
#
# Outputs /root/smart-vpn/foreign.env with connection info to feed into
# ru-vps/install.sh. Safe to re-run (idempotent).
#
# Tunables (override via env or CLI flags):
#   REALITY_SNI   — TLS SNI Reality masquerades under (default: www.microsoft.com)
#   LISTEN_PORT   — sing-box inbound port              (default: 443)
#   ENV_OUT       — path to write connection info      (default: /root/smart-vpn/foreign.env)

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"
LISTEN_PORT="${LISTEN_PORT:-443}"
ENV_OUT="${ENV_OUT:-/root/smart-vpn/foreign.env}"
CONFIG_PATH="/etc/sing-box/config.json"

usage() {
  cat <<EOF
Usage: sudo $0 [--sni DOMAIN] [--port N] [--env-out PATH]

Provisions this VPS as a sing-box VLESS+Reality server. Writes a credentials
env file that ru-vps/install.sh will consume.

Options:
  --sni DOMAIN     SNI Reality poses as (default: ${REALITY_SNI})
  --port N         TCP port to listen on (default: ${LISTEN_PORT})
  --env-out PATH   Where to write connection info (default: ${ENV_OUT})
  -h, --help       Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sni)     REALITY_SNI="$2"; shift 2 ;;
    --port)    LISTEN_PORT="$2"; shift 2 ;;
    --env-out) ENV_OUT="$2";     shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown arg: $1 (try --help)" ;;
  esac
done

require_root "$@"
detect_os

log "updating apt and installing base packages"
apt-get update -qq
apt_install ca-certificates curl gnupg openssl jq qrencode ufw

install_singbox
enable_ip_forwarding

# --- generate secrets (idempotent: reuse if an existing config exists) ------
if [[ -f "$CONFIG_PATH" ]] && jq -e '.inbounds[0].tls.reality.private_key' "$CONFIG_PATH" >/dev/null 2>&1; then
  warn "existing config found at $CONFIG_PATH — reusing Reality keys and UUID"
  REALITY_PRIV="$(jq -r '.inbounds[0].tls.reality.private_key' "$CONFIG_PATH")"
  UUID="$(jq -r '.inbounds[0].users[0].uuid' "$CONFIG_PATH")"
  SHORT_ID="$(jq -r '.inbounds[0].tls.reality.short_id[0]' "$CONFIG_PATH")"
  # derive public key from private via sing-box helper
  REALITY_PUB="$(sing-box generate reality-keypair --private-key "$REALITY_PRIV" 2>/dev/null \
                 | awk '/PublicKey/{print $2}')" || REALITY_PUB=""
  if [[ -z "$REALITY_PUB" ]]; then
    warn "could not derive public key from existing private key — regenerating keypair"
    KP="$(sing-box generate reality-keypair)"
    REALITY_PRIV="$(awk '/PrivateKey/{print $2}' <<<"$KP")"
    REALITY_PUB="$(awk '/PublicKey/{print $2}'  <<<"$KP")"
  fi
else
  log "generating Reality keypair, UUID, short_id"
  KP="$(sing-box generate reality-keypair)"
  REALITY_PRIV="$(awk '/PrivateKey/{print $2}' <<<"$KP")"
  REALITY_PUB="$(awk '/PublicKey/{print $2}'  <<<"$KP")"
  UUID="$(sing-box generate uuid)"
  SHORT_ID="$(random_hex 8)"
fi

# --- write sing-box config ---------------------------------------------------
log "writing sing-box config to $CONFIG_PATH"
install -d -m 0755 /etc/sing-box
umask 077
cat >"$CONFIG_PATH" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${LISTEN_PORT},
      "users": [
        { "uuid": "${UUID}" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SNI}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${REALITY_SNI}", "server_port": 443 },
          "private_key": "${REALITY_PRIV}",
          "short_id": ["${SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "rules": [
      { "ip_is_private": true, "outbound": "direct" }
    ],
    "final": "direct"
  }
}
EOF
chmod 0600 "$CONFIG_PATH"

log "validating sing-box config"
sing-box check -c "$CONFIG_PATH" >/dev/null || die "sing-box config validation failed"

# --- firewall ---------------------------------------------------------------
log "configuring ufw (allow SSH + ${LISTEN_PORT}/tcp)"
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null
ufw allow "${LISTEN_PORT}/tcp" >/dev/null
ufw --force enable >/dev/null

# --- enable service ---------------------------------------------------------
log "enabling sing-box systemd service"
systemctl enable sing-box >/dev/null
systemctl restart sing-box
sleep 1
if ! systemctl is-active --quiet sing-box; then
  journalctl -u sing-box -n 40 --no-pager >&2
  die "sing-box failed to start — see logs above"
fi
ok "sing-box is running"

# --- dump connection info ---------------------------------------------------
PUBLIC_IP="$(public_ipv4)"
write_env_file "$ENV_OUT" \
  "FOREIGN_HOST=${PUBLIC_IP}" \
  "FOREIGN_PORT=${LISTEN_PORT}" \
  "FOREIGN_UUID=${UUID}" \
  "FOREIGN_PBK=${REALITY_PUB}" \
  "FOREIGN_SID=${SHORT_ID}" \
  "FOREIGN_SNI=${REALITY_SNI}"

cat >&2 <<EOF

${C_GREEN}=== Foreign VPS ready ===${C_RESET}

Connection details (also saved to ${ENV_OUT}):
  host:        ${PUBLIC_IP}
  port:        ${LISTEN_PORT}
  uuid:        ${UUID}
  public key:  ${REALITY_PUB}
  short id:    ${SHORT_ID}
  sni:         ${REALITY_SNI}

Next step — on the RU VPS, run:

  scp root@${PUBLIC_IP}:${ENV_OUT} /root/smart-vpn/foreign.env
  sudo ./ru-vps/install.sh --foreign-env /root/smart-vpn/foreign.env

EOF
