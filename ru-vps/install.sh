#!/usr/bin/env bash
#
# RU VPS provisioning:
#   - AmneziaWG (default) or plain WireGuard server for clients
#   - sing-box with TUN + auto_route + auto_redirect:
#       * sniffs destination domain of forwarded traffic
#       * resolves DNS directly from RU DNS servers on the VPS
#       * RU geoip / geosite -> direct  (traffic appears to originate from this VPS)
#       * everything else    -> VLESS+Reality chain to the foreign VPS
#   Side-effect: the VPS's own outbound traffic (apt/git/curl on the host)
#   is routed through the same chain. Cosmetic, not functional, and the
#   client-facing endpoint IP is still detected from the interface so that's
#   not affected.
#
# Inputs (any one of these sets foreign VPS creds):
#   --foreign-env PATH          (env file produced by foreign-vps/install.sh)
#   FOREIGN_HOST / FOREIGN_PORT / FOREIGN_UUID / FOREIGN_PBK / FOREIGN_SID / FOREIGN_SNI
#
# Tunables:
#   --protocol amneziawg|wireguard   (default: amneziawg)
#   --wg-port N                      (default: 51820)
#   WG_SUBNET       default 10.13.13.0/24
#   WG_SERVER_IP    default 10.13.13.1/24

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

VPN_PROTO="${VPN_PROTO:-amneziawg}"
WG_PORT="${WG_PORT:-51820}"
WG_SUBNET="${WG_SUBNET:-10.13.13.0/24}"
WG_SERVER_IP="${WG_SERVER_IP:-10.13.13.1/24}"
WG_V6_SUBNET="fd13:13:13::/64"
WG_SERVER_V6="fd13:13:13::1/64"
DIRECT_DOMAIN_SUFFIXES="${DIRECT_DOMAIN_SUFFIXES:-ozon.ru,ozone.ru,ozonusercontent.com,ozoncdn.ru,okko.tv,okko.ru}"
DIRECT_IP_CIDRS="${DIRECT_IP_CIDRS:-76.76.2.22/32,108.157.214.0/24,17.253.39.0/24,17.57.146.0/24,5.45.121.63/32}"
FOREIGN_ENV=""

SB_CONFIG="/etc/sing-box/config.json"
STATE_DIR="/root/smart-vpn"
RU_ENV="$STATE_DIR/ru.env"

usage() {
  cat <<EOF
Usage: sudo $0 --foreign-env PATH [--protocol amneziawg|wireguard] [--wg-port N]

Provisions this VPS as a WG/AWG gateway that chains domain-based routing
through a foreign VLESS+Reality exit.

Options:
  --foreign-env PATH           env file produced by foreign-vps/install.sh
  --protocol amneziawg|wireguard   client-facing protocol (default: amneziawg)
  --wg-port N                  UDP port for the tunnel (default: ${WG_PORT})
  WG_SUBNET / WG_SERVER_IP     IPv4 client subnet and server address (CIDR)
  DIRECT_DOMAIN_SUFFIXES       comma-separated domain suffixes forced to direct/RU DNS
  DIRECT_IP_CIDRS              comma-separated destination CIDRs forced to direct
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --foreign-env) FOREIGN_ENV="$2"; shift 2 ;;
    --protocol)    VPN_PROTO="$2";   shift 2 ;;
    --wg-port)     WG_PORT="$2";     shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) die "unknown arg: $1 (try --help)" ;;
  esac
done

case "$VPN_PROTO" in
  amneziawg|wireguard) ;;
  *) die "invalid --protocol: $VPN_PROTO (expected: amneziawg | wireguard)" ;;
esac

require_root "$@"
detect_os

if [[ -n "$FOREIGN_ENV" ]]; then
  load_env_file "$FOREIGN_ENV"
fi

: "${FOREIGN_HOST:?FOREIGN_HOST not set (pass --foreign-env or export vars)}"
: "${FOREIGN_PORT:?FOREIGN_PORT not set}"
: "${FOREIGN_UUID:?FOREIGN_UUID not set}"
: "${FOREIGN_PBK:?FOREIGN_PBK not set}"
: "${FOREIGN_SID:?FOREIGN_SID not set}"
: "${FOREIGN_SNI:?FOREIGN_SNI not set}"

WG_NETWORK="${WG_SUBNET%/*}"
WG_PREFIX="${WG_SUBNET#*/}"
[[ "$WG_NETWORK" != "$WG_SUBNET" && "$WG_PREFIX" =~ ^[0-9]+$ ]] || \
  die "WG_SUBNET must be an IPv4 CIDR like 10.13.13.0/24"
(( WG_PREFIX >= 1 && WG_PREFIX <= 30 )) || \
  die "WG_SUBNET prefix must be between /1 and /30"
WG_NETWORK_INT="$(ipv4_network_int "$WG_NETWORK" "$WG_PREFIX")" || \
  die "WG_SUBNET has an invalid IPv4 network: $WG_SUBNET"
WG_BROADCAST_INT="$(ipv4_broadcast_int "$WG_NETWORK" "$WG_PREFIX")" || \
  die "WG_SUBNET has an invalid IPv4 range: $WG_SUBNET"
WG_CANONICAL_NETWORK="$(int_to_ipv4 "$WG_NETWORK_INT")" || \
  die "failed to canonicalize WG_SUBNET"
[[ "$WG_NETWORK" == "$WG_CANONICAL_NETWORK" ]] || \
  die "WG_SUBNET must use the network address ${WG_CANONICAL_NETWORK}/${WG_PREFIX}"

WG_SERVER_ADDR="${WG_SERVER_IP%/*}"
WG_SERVER_PREFIX="${WG_SERVER_IP#*/}"
[[ "$WG_SERVER_ADDR" != "$WG_SERVER_IP" && "$WG_SERVER_PREFIX" =~ ^[0-9]+$ ]] || \
  die "WG_SERVER_IP must be an IPv4 CIDR like 10.13.13.1/${WG_PREFIX}"
(( WG_SERVER_PREFIX == WG_PREFIX )) || \
  die "WG_SERVER_IP prefix (${WG_SERVER_PREFIX}) must match WG_SUBNET prefix (${WG_PREFIX})"
WG_SERVER_INT="$(ipv4_to_int "$WG_SERVER_ADDR")" || \
  die "WG_SERVER_IP has an invalid IPv4 address: $WG_SERVER_IP"
(( WG_SERVER_INT > WG_NETWORK_INT && WG_SERVER_INT < WG_BROADCAST_INT )) || \
  die "WG_SERVER_IP (${WG_SERVER_ADDR}) must be inside ${WG_SUBNET} and not use network/broadcast"
WG_SERVER_OFFSET=$(( WG_SERVER_INT - WG_NETWORK_INT ))
NEXT_IP_DEFAULT=$(( WG_SERVER_OFFSET + 1 ))
(( NEXT_IP_DEFAULT < (WG_BROADCAST_INT - WG_NETWORK_INT) )) || \
  die "WG_SERVER_IP leaves no allocatable client addresses inside ${WG_SUBNET}"

DIRECT_DOMAIN_SUFFIXES_JSON="[]"
if [[ -n "$DIRECT_DOMAIN_SUFFIXES" ]]; then
  IFS=',' read -r -a DIRECT_SUFFIX_ARRAY <<<"$DIRECT_DOMAIN_SUFFIXES"
  DIRECT_JSON_ITEMS=()
  for suffix in "${DIRECT_SUFFIX_ARRAY[@]}"; do
    suffix="${suffix## }"
    suffix="${suffix%% }"
    [[ -n "$suffix" ]] || continue
    DIRECT_JSON_ITEMS+=("\"${suffix}\"")
  done
  if (( ${#DIRECT_JSON_ITEMS[@]} > 0 )); then
    DIRECT_DOMAIN_SUFFIXES_JSON="[$(IFS=,; echo "${DIRECT_JSON_ITEMS[*]}")]"
  fi
fi

DIRECT_IP_CIDRS_JSON="[]"
if [[ -n "$DIRECT_IP_CIDRS" ]]; then
  IFS=',' read -r -a DIRECT_CIDR_ARRAY <<<"$DIRECT_IP_CIDRS"
  DIRECT_CIDR_JSON_ITEMS=()
  for cidr in "${DIRECT_CIDR_ARRAY[@]}"; do
    cidr="${cidr## }"
    cidr="${cidr%% }"
    [[ -n "$cidr" ]] || continue
    DIRECT_CIDR_JSON_ITEMS+=("\"${cidr}\"")
  done
  if (( ${#DIRECT_CIDR_JSON_ITEMS[@]} > 0 )); then
    DIRECT_IP_CIDRS_JSON="[$(IFS=,; echo "${DIRECT_CIDR_JSON_ITEMS[*]}")]"
  fi
fi

# --- pick command names + paths per protocol --------------------------------
if [[ "$VPN_PROTO" == "amneziawg" ]]; then
  WG_CMD="awg"
  WG_QUICK="awg-quick"
  WG_UNIT="awg-quick@awg0"
  WG_IF="awg0"
  WG_DIR="/etc/amnezia/amneziawg"
else
  WG_CMD="wg"
  WG_QUICK="wg-quick"
  WG_UNIT="wg-quick@wg0"
  WG_IF="wg0"
  WG_DIR="/etc/wireguard"
fi
WG_CONF="$WG_DIR/${WG_IF}.conf"
WG_META="$WG_DIR/smart-vpn.meta"

log "base packages"
apt-get update -qq
apt_install ca-certificates curl gnupg openssl jq qrencode ufw iptables nftables resolvconf

if [[ "$VPN_PROTO" == "amneziawg" ]]; then
  install_amneziawg
else
  install_wireguard
fi
install_singbox
enable_ip_forwarding

install -d -m 0700 "$STATE_DIR"
install -d -m 0700 "$WG_DIR"

# --- server keypair (idempotent) --------------------------------------------
if [[ -f "$WG_DIR/server.key" ]]; then
  WG_SERVER_PRIV="$(cat "$WG_DIR/server.key")"
  WG_SERVER_PUB="$(cat "$WG_DIR/server.pub")"
  ok "reusing existing ${WG_CMD} server keys"
else
  log "generating ${WG_CMD} server keypair"
  umask 077
  "$WG_CMD" genkey | tee "$WG_DIR/server.key" | "$WG_CMD" pubkey >"$WG_DIR/server.pub"
  WG_SERVER_PRIV="$(cat "$WG_DIR/server.key")"
  WG_SERVER_PUB="$(cat "$WG_DIR/server.pub")"
fi

# --- AmneziaWG obfuscation params (idempotent) ------------------------------
AWG_INTERFACE_BLOCK=""
if [[ "$VPN_PROTO" == "amneziawg" ]]; then
  # Reuse only if the file exists AND looks valid; a truncated file from a
  # past failed run would otherwise break `load_env_file` silently.
  if [[ -s "$WG_DIR/awg-params.env" ]] && grep -q '^AWG_JC=' "$WG_DIR/awg-params.env"; then
    ok "reusing existing AmneziaWG obfuscation params"
  else
    log "generating fresh AmneziaWG obfuscation params"
    umask 077
    # Generate into a variable first so the destination file isn't truncated
    # on failure. Only once generation fully succeeded do we write it out.
    awg_params="$(generate_awg_params)"
    printf '%s\n' "$awg_params" >"$WG_DIR/awg-params.env"
    unset awg_params
  fi
  load_env_file "$WG_DIR/awg-params.env"
  AWG_INTERFACE_BLOCK="\
Jc   = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1   = ${AWG_S1}
S2   = ${AWG_S2}
H1   = ${AWG_H1}
H2   = ${AWG_H2}
H3   = ${AWG_H3}
H4   = ${AWG_H4}"
fi

# --- preserve existing [Peer] blocks across reruns --------------------------
PEER_BLOCKS=""
if [[ -f "$WG_CONF" ]]; then
  PEER_BLOCKS="$(awk '/^\[Peer\]/{found=1} found' "$WG_CONF" || true)"
fi

log "writing server config: $WG_CONF"
umask 077
{
  cat <<EOF
# Managed by smart-vpn. Protocol: ${VPN_PROTO}. Edit peers via ru-vps/add-client.sh.
[Interface]
Address    = ${WG_SERVER_IP}, ${WG_SERVER_V6}
ListenPort = ${WG_PORT}
PrivateKey = ${WG_SERVER_PRIV}
EOF
  if [[ -n "$AWG_INTERFACE_BLOCK" ]]; then
    printf '%s\n' "$AWG_INTERFACE_BLOCK"
  fi
  if [[ -n "$PEER_BLOCKS" ]]; then
    printf '\n%s\n' "$PEER_BLOCKS"
  fi
} >"$WG_CONF"
chmod 0600 "$WG_CONF"

if [[ ! -f "$WG_META" ]]; then
  printf 'next_ip=%s\n' "$NEXT_IP_DEFAULT" >"$WG_META"
fi

# --- sing-box config: TUN in, direct + VLESS chain out ----------------------
log "writing sing-box config: $SB_CONFIG"
install -d -m 0755 /etc/sing-box
umask 077
cat >"$SB_CONFIG" <<EOF
{
  "log": { "level": "warn", "timestamp": true },

  "dns": {
    "servers": [
      { "type": "udp", "tag": "ru-dns",      "server": "77.88.8.8" },
      { "type": "udp", "tag": "ru-dns-alt",  "server": "77.88.8.1" },
      { "type": "udp", "tag": "global-dns",  "server": "1.1.1.1" }
    ],
    "rules": [
      { "domain_suffix": ${DIRECT_DOMAIN_SUFFIXES_JSON}, "server": "ru-dns" },
      { "rule_set": ["geosite-ru"], "server": "ru-dns" }
    ],
    "final": "ru-dns",
    "strategy": "prefer_ipv4",
    "reverse_mapping": true,
    "cache_capacity": 4096
  },

  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "sbtun",
      "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
      "mtu": 1500,
      "auto_route": true,
      "auto_redirect": true,
      "exclude_mptcp": true,
      "strict_route": false,
      "stack": "system"
    }
  ],

  "outbounds": [
    { "type": "direct", "tag": "direct" },
    {
      "type": "vless",
      "tag":  "foreign",
      "server":      "${FOREIGN_HOST}",
      "server_port": ${FOREIGN_PORT},
      "uuid":        "${FOREIGN_UUID}",
      "tls": {
        "enabled": true,
        "server_name": "${FOREIGN_SNI}",
        "utls": { "enabled": true, "fingerprint": "chrome" },
        "reality": {
          "enabled":    true,
          "public_key": "${FOREIGN_PBK}",
          "short_id":   "${FOREIGN_SID}"
        }
      }
    }
  ],

  "route": {
    "default_domain_resolver": { "server": "ru-dns" },
    "rules": [
      { "action": "sniff" },
      { "protocol": "dns", "action": "hijack-dns" },
      { "domain_suffix": ${DIRECT_DOMAIN_SUFFIXES_JSON}, "outbound": "direct" },
      { "ip_cidr": ${DIRECT_IP_CIDRS_JSON}, "outbound": "direct" },
      { "ip_is_private": true, "outbound": "direct" },
      { "rule_set": ["geoip-ru", "geosite-ru"], "outbound": "direct" }
    ],
    "rule_set": [
      {
        "type": "remote", "tag": "geoip-ru", "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-ru.srs",
        "download_detour": "direct",
        "update_interval": "72h0m0s"
      },
      {
        "type": "remote", "tag": "geosite-ru", "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ru.srs",
        "download_detour": "direct",
        "update_interval": "72h0m0s"
      }
    ],
    "final": "foreign",
    "auto_detect_interface": true
  }
}
EOF
chmod 0600 "$SB_CONFIG"

log "validating sing-box config"
sing-box check -c "$SB_CONFIG" >/dev/null || die "sing-box config validation failed"

# --- cleanup from earlier tproxy attempt (if present) -----------------------
# Previous revisions of this installer deployed a tproxy + custom nftables
# setup. It's harmless to leave in place on an old machine but pointless, and
# its restart dependency on sing-box would cause spurious failures. Purge.
if [[ -f /etc/systemd/system/smart-vpn-nft.service ]]; then
  log "removing legacy smart-vpn-nft.service"
  systemctl disable --now smart-vpn-nft.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/smart-vpn-nft.service
  rm -f /etc/systemd/system/sing-box.service.d/10-smart-vpn.conf
  rmdir /etc/systemd/system/sing-box.service.d 2>/dev/null || true
  rm -f /usr/local/sbin/smart-vpn-nft-up /usr/local/sbin/smart-vpn-nft-down
  rm -f /etc/sing-box/smart-vpn.nft
  nft delete table inet smart_vpn 2>/dev/null || true
  ip rule del fwmark 0x1 table 100 2>/dev/null || true
  ip route flush table 100 2>/dev/null || true
  systemctl daemon-reload
fi

# --- firewall ---------------------------------------------------------------
log "configuring ufw (allow SSH + ${WG_PORT}/udp; open awg0; permit forwarding)"
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null
ufw allow "${WG_PORT}/udp" >/dev/null
# Allow everything arriving on the WG interface to reach local sockets.
# sing-box auto_redirect REDIRECTs forwarded TCP to an ephemeral local port
# (chosen at startup, e.g. 41379). Without this rule, ufw's default-deny
# INPUT policy silently drops those SYNs and clients time out on every
# connection attempt while DNS still appears to work.
ufw allow in on "${WG_IF}" to any >/dev/null
sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
ufw --force enable >/dev/null
ufw reload >/dev/null

# --- start services ---------------------------------------------------------
log "enabling ${WG_UNIT} and sing-box"
systemctl enable "${WG_UNIT}" >/dev/null
systemctl restart "${WG_UNIT}"
systemctl enable sing-box >/dev/null
systemctl restart sing-box
sleep 2
if ! systemctl is-active --quiet sing-box; then
  journalctl -u sing-box -n 60 --no-pager >&2
  die "sing-box failed to start — see logs above"
fi
if ! systemctl is-active --quiet "${WG_UNIT}"; then
  journalctl -u "${WG_UNIT}" -n 40 --no-pager >&2
  die "${WG_UNIT} failed to start — see logs above"
fi
ok "${WG_UNIT} and sing-box are running"

# --- persist state ----------------------------------------------------------
# add-client.sh reads this to know which protocol/paths to use.
RU_ENV_LINES=(
  "VPN_PROTO=${VPN_PROTO}"
  "WG_CMD=${WG_CMD}"
  "WG_QUICK=${WG_QUICK}"
  "WG_UNIT=${WG_UNIT}"
  "WG_IF=${WG_IF}"
  "WG_DIR=${WG_DIR}"
  "WG_CONF=${WG_CONF}"
  "WG_META=${WG_META}"
  "WG_PORT=${WG_PORT}"
  "WG_SUBNET=${WG_SUBNET}"
  "WG_SERVER_IP=${WG_SERVER_IP}"
  "WG_V6_SUBNET=${WG_V6_SUBNET}"
  "WG_SERVER_V6=${WG_SERVER_V6}"
  "WG_SERVER_PUB=${WG_SERVER_PUB}"
)
if [[ "$VPN_PROTO" == "amneziawg" ]]; then
  RU_ENV_LINES+=(
    "AWG_JC=${AWG_JC}"   "AWG_JMIN=${AWG_JMIN}" "AWG_JMAX=${AWG_JMAX}"
    "AWG_S1=${AWG_S1}"   "AWG_S2=${AWG_S2}"
    "AWG_H1=${AWG_H1}"   "AWG_H2=${AWG_H2}"     "AWG_H3=${AWG_H3}" "AWG_H4=${AWG_H4}"
  )
fi
write_env_file "$RU_ENV" "${RU_ENV_LINES[@]}"

PUBLIC_IP="$(public_ipv4)"
cat >&2 <<EOF

${C_GREEN}=== RU VPS ready (protocol: ${VPN_PROTO}) ===${C_RESET}

Tunnel endpoint    : ${PUBLIC_IP}:${WG_PORT}
Server pubkey      : ${WG_SERVER_PUB}
Client subnet      : ${WG_SUBNET}
EOF

if [[ "$VPN_PROTO" == "amneziawg" ]]; then
  cat >&2 <<EOF

AmneziaWG obfuscation params (embedded in every client profile):
  Jc=${AWG_JC}  Jmin=${AWG_JMIN}  Jmax=${AWG_JMAX}
  S1=${AWG_S1}  S2=${AWG_S2}
  H1=${AWG_H1}
  H2=${AWG_H2}
  H3=${AWG_H3}
  H4=${AWG_H4}

Client app (mobile/desktop): use the dedicated ${C_YELLOW}AmneziaWG${C_RESET} app
  (fork of WireGuard), NOT the main AmneziaVPN app. AmneziaVPN uses its own
  vpn:// format and won't reliably import QR codes generated from a raw .conf.

    iOS      — AmneziaWG on the App Store
    Android  — Google Play, package: org.amnezia.awg
    Windows  — github.com/amnezia-vpn/amneziawg-windows-client/releases
    macOS    — build amneziawg-apple from source
    Linux    — amneziawg-tools (awg-quick up <client>.conf)
    Keenetic — KeeneticOS 4.2+ with the "amneziawg" component installed
               (System → Components), then Internet → Other connections → AmneziaWG.
EOF
fi

cat >&2 <<EOF

Next — add a client profile:

  sudo ./ru-vps/add-client.sh my-keenetic
  sudo ./ru-vps/add-client.sh iphone
  sudo ./ru-vps/add-client.sh laptop

EOF
