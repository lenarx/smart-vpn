#!/usr/bin/env bash
#
# RU VPS provisioning:
#   - AmneziaWG (default) or plain WireGuard server for clients
#   - sing-box: minimal VLESS+Reality client. Creates TUN device `sbtun` with
#     `auto_route=false` (sing-box owns the device, keen-pbr owns the routing)
#     and forwards everything it receives on `sbtun` into the foreign VPS via
#     VLESS+Reality.
#   - keen-pbr: policy-based routing daemon. Uses dnsmasq + nftables/ipset to
#     split destinations:
#       * RU geosite (outside-raw.lst) + RU geoip (ipdeny ru-aggregated.zone)
#         + manual overrides from DIRECT_DOMAIN_SUFFIXES / DIRECT_IP_CIDRS
#                     -> outbound=direct (packet leaves via ens3 with MASQUERADE
#                        to ens3 IP, clients look like they're in Russia to
#                        gosuslugi/banks/etc.)
#       * catch-all 0.0.0.0/0 + ::/0
#                     -> outbound=vpn (fwmark'd into keen-pbr's routing table,
#                        default via `sbtun`, sing-box tunnels it to foreign VPS)
#   - keen-pbr Web UI bound ONLY to the server's AWG IP so it's reachable only
#     through the AWG tunnel; nothing exposed to the public internet.
#
# Inputs (any one of these sets foreign VPS creds):
#   --foreign-env PATH          (env file produced by foreign-vps/install.sh)
#   FOREIGN_HOST / FOREIGN_PORT / FOREIGN_UUID / FOREIGN_PBK / FOREIGN_SID / FOREIGN_SNI
#
# Tunables:
#   --protocol amneziawg|wireguard   (default: amneziawg)
#   --wg-port N                      (default: 51820)
#   WG_SUBNET / WG_SERVER_IP         default 10.13.13.0/24 + 10.13.13.1/24
#   DIRECT_DOMAIN_SUFFIXES           comma-separated RU domains forced to direct
#   DIRECT_IP_CIDRS                  comma-separated CIDRs forced to direct
#   RU_SITES_URL                     override plaintext RU-domains list URL
#   RU_CIDRS_URL                     override plaintext RU-IPv4 CIDR list URL
#   KEENPBR_API_PORT                 default 12121
#   KEENPBR_REF / KEENPBR_BUILD_DIR  (consumed by install_keenpbr helper)

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
DIRECT_IP_CIDRS="${DIRECT_IP_CIDRS:-76.76.2.22/32,108.157.214.0/24,17.0.0.0/8,5.45.121.63/32}"
# Plaintext lists keen-pbr pulls at boot. Both URLs are one-entry-per-line.
RU_SITES_URL="${RU_SITES_URL:-https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/outside-raw.lst}"
RU_CIDRS_URL="${RU_CIDRS_URL:-https://www.ipdeny.com/ipblocks/data/aggregated/ru-aggregated.zone}"
KEENPBR_API_PORT="${KEENPBR_API_PORT:-12121}"
FOREIGN_ENV=""

SB_CONFIG="/etc/sing-box/config.json"
KPB_CONFIG="/etc/keen-pbr/config.json"
KPB_FALLBACK_DNS="/etc/keen-pbr/dnsmasq-fallback.conf"
STATE_DIR="/root/smart-vpn"
RU_ENV="$STATE_DIR/ru.env"

# sbtun point-to-point subnet (tiny — only the daemon and keen-pbr talk here).
SBTUN_V4="172.19.0.1/30"
SBTUN_V4_GW="172.19.0.1"
SBTUN_V6="fdfe:dcba:9876::1/126"

usage() {
  cat <<EOF
Usage: sudo $0 --foreign-env PATH [--protocol amneziawg|wireguard] [--wg-port N]

Provisions this VPS as a WG/AWG gateway with keen-pbr for policy-based
splitting and sing-box as the VLESS+Reality client to the foreign exit.

Options:
  --foreign-env PATH           env file produced by foreign-vps/install.sh
  --protocol amneziawg|wireguard   client-facing protocol (default: amneziawg)
  --wg-port N                  UDP port for the tunnel (default: ${WG_PORT})
  WG_SUBNET / WG_SERVER_IP     IPv4 client subnet and server address (CIDR)
  DIRECT_DOMAIN_SUFFIXES       comma-separated domains forced to direct
  DIRECT_IP_CIDRS              comma-separated destination CIDRs forced to direct
  RU_SITES_URL / RU_CIDRS_URL  override plaintext list sources
  KEENPBR_API_PORT             Web UI port on the AWG-side IP (default: 12121)
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

# Convert comma-separated env values into JSON arrays usable inside config.json.
csv_to_json_array() {
  local csv="$1"
  local items=()
  local item
  IFS=',' read -r -a items <<<"$csv"
  local out=""
  for item in "${items[@]}"; do
    item="${item## }"
    item="${item%% }"
    [[ -n "$item" ]] || continue
    # quote + escape embedded double quotes
    item="${item//\"/\\\"}"
    out+="\"${item}\","
  done
  printf '[%s]' "${out%,}"
}
DIRECT_DOMAIN_SUFFIXES_JSON="$(csv_to_json_array "$DIRECT_DOMAIN_SUFFIXES")"
DIRECT_IP_CIDRS_JSON="$(csv_to_json_array "$DIRECT_IP_CIDRS")"

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
install_keenpbr
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
  if [[ -s "$WG_DIR/awg-params.env" ]] && grep -q '^AWG_JC=' "$WG_DIR/awg-params.env"; then
    ok "reusing existing AmneziaWG obfuscation params"
  else
    log "generating fresh AmneziaWG obfuscation params"
    umask 077
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

# --- sing-box: minimal VLESS+Reality client with bare sbtun -----------------
# No auto_route, no auto_redirect, no rule-sets. The TUN device is only a
# transport — keen-pbr decides what gets routed into it via policy routing.
log "writing sing-box config: $SB_CONFIG"
install -d -m 0755 /etc/sing-box
umask 077
cat >"$SB_CONFIG" <<EOF
{
  "log": { "level": "warn", "timestamp": true },

  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "sbtun",
      "address": ["${SBTUN_V4}", "${SBTUN_V6}"],
      "mtu": 1420,
      "auto_route": false,
      "auto_redirect": false,
      "stack": "system"
    }
  ],

  "outbounds": [
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
    "final": "foreign",
    "auto_detect_interface": true
  }
}
EOF
chmod 0600 "$SB_CONFIG"

log "validating sing-box config"
sing-box check -c "$SB_CONFIG" >/dev/null || die "sing-box config validation failed"

# --- keen-pbr config --------------------------------------------------------
# Rule order (first match wins):
#   1. private CIDRs -> direct   (keep AWG subnet, LAN, loopback off the VPN)
#   2. RU sites/CIDRs/overrides -> direct (ens3 + MASQUERADE, RU-looking src)
#   3. catch-all 0.0.0.0/0 + ::/0 -> vpn (fwmark -> table -> sbtun -> VLESS)
log "writing keen-pbr config: $KPB_CONFIG"
install -d -m 0755 /etc/keen-pbr
umask 077
cat >"$KPB_CONFIG" <<EOF
{
  "daemon": {
    "pid_file": "/var/run/keen-pbr.pid",
    "cache_dir": "/var/cache/keen-pbr",
    "firewall_backend": "auto",
    "strict_enforcement": false
  },
  "api": {
    "enabled": true,
    "listen": "${WG_SERVER_ADDR}:${KEENPBR_API_PORT}"
  },
  "outbounds": [
    { "type": "interface", "tag": "vpn",    "interface": "sbtun", "gateway": "${SBTUN_V4_GW}" },
    { "type": "ignore",    "tag": "direct" }
  ],
  "lists": {
    "private": {
      "ip_cidrs": [
        "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16",
        "127.0.0.0/8", "224.0.0.0/4",
        "fc00::/7", "fe80::/10", "::1/128", "ff00::/8"
      ]
    },
    "ru_sites":     { "url": "${RU_SITES_URL}" },
    "ru_cidrs":     { "url": "${RU_CIDRS_URL}" },
    "ru_overrides": {
      "domains":  ${DIRECT_DOMAIN_SUFFIXES_JSON},
      "ip_cidrs": ${DIRECT_IP_CIDRS_JSON}
    },
    "catchall":     { "ip_cidrs": ["0.0.0.0/0", "::/0"] }
  },
  "dns": {
    "system_resolver": { "address": "127.0.0.1" },
    "servers": [
      { "tag": "ru_dns", "address": "77.88.8.8" },
      { "tag": "cf_dns", "address": "1.1.1.1" }
    ],
    "rules": [
      { "list": ["ru_sites", "ru_overrides"], "server": "ru_dns" }
    ],
    "fallback": ["cf_dns"]
  },
  "fwmark":  { "start": "0x00010000", "mask": "0x00FF0000" },
  "iproute": { "table_start": 150 },
  "route": {
    "rules": [
      { "list": ["private"],                                  "outbound": "direct" },
      { "list": ["ru_sites", "ru_cidrs", "ru_overrides"],     "outbound": "direct" },
      { "list": ["catchall"],                                 "outbound": "vpn" }
    ]
  }
}
EOF
chmod 0644 "$KPB_CONFIG"

log "writing dnsmasq fallback servers: $KPB_FALLBACK_DNS"
cat >"$KPB_FALLBACK_DNS" <<'EOF'
# Used when keen-pbr is stopped. Kept intentionally small.
server=77.88.8.8
server=1.1.1.1
EOF
chmod 0644 "$KPB_FALLBACK_DNS"

# --- systemd: keen-pbr must start AFTER sing-box so sbtun exists ------------
log "installing systemd drop-in for keen-pbr ordering"
install -d -m 0755 /etc/systemd/system/keen-pbr.service.d
cat >/etc/systemd/system/keen-pbr.service.d/10-smart-vpn.conf <<EOF
[Unit]
After=sing-box.service ${WG_UNIT}.service dnsmasq.service network-online.target
Wants=sing-box.service dnsmasq.service
EOF
systemctl daemon-reload

# --- cleanup from earlier sing-box tproxy/auto_redirect attempts ------------
# Previous revisions of this installer either baked routing into sing-box
# (auto_redirect) or set up a tproxy+nftables table. Both are now obsolete.
if nft list table inet smart_vpn >/dev/null 2>&1; then
  log "removing legacy 'inet smart_vpn' nftables table"
  nft delete table inet smart_vpn 2>/dev/null || true
fi
if nft list table inet smart-vpn >/dev/null 2>&1; then
  log "removing legacy 'inet smart-vpn' nftables table"
  nft delete table inet smart-vpn 2>/dev/null || true
fi
if [[ -f /etc/systemd/system/smart-vpn-nft.service ]]; then
  systemctl disable --now smart-vpn-nft.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/smart-vpn-nft.service \
        /etc/systemd/system/sing-box.service.d/10-smart-vpn.conf \
        /usr/local/sbin/smart-vpn-nft-up /usr/local/sbin/smart-vpn-nft-down \
        /etc/sing-box/smart-vpn.nft
  rmdir /etc/systemd/system/sing-box.service.d 2>/dev/null || true
  ip rule del fwmark 0x1 table 100 2>/dev/null || true
  ip route flush table 100 2>/dev/null || true
  systemctl daemon-reload
fi

# --- firewall ---------------------------------------------------------------
PRIMARY_IF="$(primary_iface)"
[[ -n "$PRIMARY_IF" ]] || die "could not determine primary outbound interface"

log "installing MASQUERADE for direct-path traffic (${WG_SUBNET} -> ${PRIMARY_IF})"
# We keep the NAT block inside ufw's before.rules so it survives `ufw reload`
# and reboots. Marked with BEGIN/END smart-vpn banners for idempotent rewrite.
UFW_BEFORE="/etc/ufw/before.rules"
UFW_BEGIN="# BEGIN smart-vpn NAT"
UFW_END="# END smart-vpn NAT"
if ! [[ -f "$UFW_BEFORE" ]]; then
  die "$UFW_BEFORE not found — is ufw installed?"
fi
# Strip any previous block between the banners.
sed -i "/^${UFW_BEGIN}\$/,/^${UFW_END}\$/d" "$UFW_BEFORE"
# Prepend a fresh block at the top of the file (NAT must come before *filter).
NAT_BLOCK=$(cat <<EOF
${UFW_BEGIN}
*nat
:POSTROUTING ACCEPT [0:0]
# MASQUERADE direct-path traffic from AWG clients to the primary interface.
# Packets heading into sbtun (VPN path) don't hit this because sing-box opens
# its own sockets; only client->ens3 direct traffic matches the -s rule.
-A POSTROUTING -s ${WG_SUBNET} -o ${PRIMARY_IF} -j MASQUERADE
COMMIT
${UFW_END}

EOF
)
printf '%s\n%s' "$NAT_BLOCK" "$(cat "$UFW_BEFORE")" >"${UFW_BEFORE}.new"
mv "${UFW_BEFORE}.new" "$UFW_BEFORE"
chmod 0640 "$UFW_BEFORE"

log "configuring ufw (SSH + ${WG_PORT}/udp; open ${WG_IF}; allow forwarding)"
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null
ufw allow "${WG_PORT}/udp" >/dev/null
# AWG clients must reach dnsmasq:53 and keen-pbr Web UI:${KEENPBR_API_PORT}
# on the server's AWG address. A blanket "allow in on awg0" covers both plus
# any forwarded outbound traffic (the same thing the old installer needed for
# sing-box's auto_redirect REDIRECT ports).
ufw allow in on "${WG_IF}" to any >/dev/null
sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
ufw --force enable >/dev/null
ufw reload >/dev/null

# --- start services ---------------------------------------------------------
# Order: AWG (creates awg0) → sing-box (creates sbtun) → dnsmasq → keen-pbr.
# Systemd drop-in declares the deps, but we also restart sequentially so any
# startup error surfaces immediately instead of via `systemctl is-failed` 10s
# later.
log "enabling and (re)starting services"
systemctl enable "${WG_UNIT}" >/dev/null
systemctl restart "${WG_UNIT}"
systemctl enable sing-box >/dev/null
systemctl restart sing-box
# dnsmasq was pulled in as a dep of keen-pbr; postinst already replaced
# /etc/dnsmasq.conf with the upstream template that includes the managed
# conf-dir block. Just enable+start it.
systemctl enable dnsmasq >/dev/null
systemctl restart dnsmasq
systemctl enable keen-pbr >/dev/null
systemctl restart keen-pbr

sleep 2
for svc in "${WG_UNIT}" sing-box dnsmasq keen-pbr; do
  if ! systemctl is-active --quiet "$svc"; then
    journalctl -u "$svc" -n 60 --no-pager >&2
    die "$svc failed to start — see logs above"
  fi
done
ok "all services running: ${WG_UNIT}, sing-box, dnsmasq, keen-pbr"

# --- persist state ----------------------------------------------------------
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
  "WG_SERVER_ADDR=${WG_SERVER_ADDR}"
  "WG_V6_SUBNET=${WG_V6_SUBNET}"
  "WG_SERVER_V6=${WG_SERVER_V6}"
  "WG_SERVER_PUB=${WG_SERVER_PUB}"
  "KEENPBR_API_PORT=${KEENPBR_API_PORT}"
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
Server AWG IP      : ${WG_SERVER_ADDR}  (DNS for clients; keen-pbr API host)
keen-pbr Web UI    : http://${WG_SERVER_ADDR}:${KEENPBR_API_PORT}/  (open ONLY via AWG)
EOF

if [[ "$VPN_PROTO" == "amneziawg" ]]; then
  cat >&2 <<EOF

AmneziaWG obfuscation params (embedded in every client profile):
  Jc=${AWG_JC}  Jmin=${AWG_JMIN}  Jmax=${AWG_JMAX}
  S1=${AWG_S1}  S2=${AWG_S2}
  H1=${AWG_H1}  H2=${AWG_H2}  H3=${AWG_H3}  H4=${AWG_H4}

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

Next — add a client profile (DNS defaults to ${WG_SERVER_ADDR} so keen-pbr's
dnsmasq sees all queries and can populate its domain->ipset mappings):

  sudo ./ru-vps/add-client.sh my-keenetic
  sudo ./ru-vps/add-client.sh iphone
  sudo ./ru-vps/add-client.sh laptop

EOF
