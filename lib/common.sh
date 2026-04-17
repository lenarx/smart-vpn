#!/usr/bin/env bash
# Shared helpers for smart-vpn install scripts.
# Source, don't execute.

set -euo pipefail

C_RESET=$'\033[0m'
C_RED=$'\033[31m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_BLUE=$'\033[34m'

log()  { printf '%s[*]%s %s\n' "$C_BLUE"   "$C_RESET" "$*" >&2; }
ok()   { printf '%s[+]%s %s\n' "$C_GREEN"  "$C_RESET" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[-]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || die "this script must run as root (try: sudo $0 $*)"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

detect_os() {
  [[ -f /etc/os-release ]] || die "/etc/os-release not found — unsupported distro"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) : ;;
    *) die "unsupported distro: ${ID:-unknown} (need Debian or Ubuntu)" ;;
  esac
  OS_ID="$ID"
  OS_VERSION_ID="${VERSION_ID:-}"
  export OS_ID OS_VERSION_ID
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

install_singbox() {
  if command -v sing-box >/dev/null 2>&1; then
    ok "sing-box already installed: $(sing-box version | head -n1)"
    return
  fi
  log "installing sing-box from official apt repo"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
  chmod a+r /etc/apt/keyrings/sagernet.asc
  local arch
  arch="$(dpkg --print-architecture)"
  cat >/etc/apt/sources.list.d/sagernet.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/sagernet.asc] https://deb.sagernet.org/ * *
EOF
  apt-get update -qq
  apt_install sing-box
  ok "sing-box installed: $(sing-box version | head -n1)"
}

install_wireguard() {
  if command -v wg >/dev/null 2>&1; then
    ok "wireguard-tools already installed"
    return
  fi
  log "installing wireguard-tools"
  apt_install wireguard wireguard-tools
}

install_amneziawg() {
  if command -v awg >/dev/null 2>&1; then
    ok "amneziawg already installed"
    return
  fi
  log "installing AmneziaWG from Launchpad PPA (ppa:amnezia/ppa)"
  apt_install software-properties-common gnupg dirmngr ca-certificates curl
  # Kernel headers are needed so amneziawg-dkms can build its module.
  apt_install "linux-headers-$(uname -r)" || \
    warn "no headers for $(uname -r); DKMS build may fail — install a matching kernel then rerun"

  install -d -m 0755 /etc/apt/keyrings
  # Amnezia PPA signing key fingerprint (per Launchpad API). If upstream
  # rotates this, replace with whatever
  #   curl -s https://api.launchpad.net/1.0/~amnezia/+archive/ubuntu/ppa \
  #   | jq -r .signing_key_fingerprint
  # returns.
  local key_fpr="75C9DD72C799870E310542E24166F2C257290828"
  local keyring="/etc/apt/keyrings/amnezia.gpg"
  rm -f "$keyring"
  local fetched=0

  # Try several transports in order — keyserver.ubuntu.com is blocked from
  # some Russian networks / hosters, so we fall back to HTTPS HKP mirrors
  # and finally to a direct Launchpad pool lookup.
  local servers=(
    "hkps://keyserver.ubuntu.com"
    "hkps://keys.openpgp.org"
    "hkps://pgp.mit.edu"
  )
  local srv
  for srv in "${servers[@]}"; do
    log "trying keyserver: $srv"
    if gpg --no-default-keyring --keyring "$keyring" \
           --keyserver "$srv" --recv-keys "$key_fpr" 2>/dev/null; then
      fetched=1; break
    fi
  done

  if [[ $fetched -eq 0 ]]; then
    # HTTPS fallback: ask Ubuntu keyserver via plain https GET (port 443),
    # some networks let this through even when hkps:11371 is blocked.
    log "keyserver --recv-keys all failed, trying HTTPS lookup"
    if curl -fsSL --max-time 15 \
         "https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x${key_fpr}" \
       | gpg --dearmor >"$keyring" 2>/dev/null && [[ -s "$keyring" ]]; then
      fetched=1
    fi
  fi

  if [[ $fetched -eq 0 ]]; then
    rm -f "$keyring"
    cat >&2 <<EOF

All automatic keyserver fetches for the Amnezia PPA key failed. This is
usually because the VPS network blocks outbound HKP and keyserver hosts.

Fetch the key manually from any machine that has internet, then copy it
to the VPS:

  # on a working machine
  gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys $key_fpr
  gpg --export --armor $key_fpr > amnezia.asc

  # then copy amnezia.asc to the VPS and:
  gpg --dearmor < amnezia.asc > $keyring
  chmod a+r $keyring
  # re-run this installer
EOF
    die "could not fetch Amnezia PPA signing key $key_fpr"
  fi
  chmod a+r "$keyring"

  # PPA is built for Ubuntu jammy; the resulting packages install cleanly on
  # Debian 12 since the kernel module is DKMS-built and the userland tool has
  # no exotic deps.
  cat >/etc/apt/sources.list.d/amnezia.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/amnezia.gpg] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu jammy main
EOF
  apt-get update -qq
  apt_install amneziawg amneziawg-dkms amneziawg-tools
  ok "amneziawg installed: $(awg --version 2>&1 | head -n1)"
}

# Random u32 in [min, max] using /dev/urandom (no python/openssl dep).
# NOTE: each local on its own line — single-line `local a=$1 b=$(( a+1 ))`
# breaks under `set -u` because bash declares both locals before running
# the RHS, so `$a` in the second slot reads as unbound.
rand_range() {
  local min="$1"
  local max="$2"
  local span=$(( max - min + 1 ))
  local r
  r=$(od -An -N4 -tu4 /dev/urandom | tr -d ' \n')
  echo $(( min + r % span ))
}

# Random u32 in [5, 2^32-6]; AmneziaWG Hx params must be >= 5 and distinct.
rand_u32() {
  local r
  r=$(od -An -N4 -tu4 /dev/urandom | tr -d ' \n')
  echo $(( (r % 4294967290) + 5 ))
}

# Emit KEY=VALUE lines for a fresh set of AmneziaWG obfuscation params.
# Caller should eval or write to env/config. Ranges follow Amnezia defaults;
# S1+S2 == 632 is forbidden (collides with the WG handshake magic size).
generate_awg_params() {
  local jc jmin jmax s1 s2 h1 h2 h3 h4
  jc=$(rand_range 3 10)
  jmin=$(rand_range 40 70)
  jmax=$(rand_range $((jmin + 20)) 120)
  while :; do
    s1=$(rand_range 15 128)
    s2=$(rand_range 15 128)
    [[ $((s1 + s2)) -ne 632 ]] && break
  done
  h1=$(rand_u32); h2=$(rand_u32); h3=$(rand_u32); h4=$(rand_u32)
  while [[ "$h1" == "$h2" || "$h1" == "$h3" || "$h1" == "$h4" \
        || "$h2" == "$h3" || "$h2" == "$h4" || "$h3" == "$h4" ]]; do
    h1=$(rand_u32); h2=$(rand_u32); h3=$(rand_u32); h4=$(rand_u32)
  done
  printf 'AWG_JC=%s\nAWG_JMIN=%s\nAWG_JMAX=%s\nAWG_S1=%s\nAWG_S2=%s\nAWG_H1=%s\nAWG_H2=%s\nAWG_H3=%s\nAWG_H4=%s\n' \
    "$jc" "$jmin" "$jmax" "$s1" "$s2" "$h1" "$h2" "$h3" "$h4"
}

enable_ip_forwarding() {
  log "enabling IPv4 forwarding"
  cat >/etc/sysctl.d/99-smart-vpn.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv4.conf.all.src_valid_mark = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl --system >/dev/null
}

primary_iface() {
  # default route outbound interface
  ip -4 route show default | awk '{print $5; exit}'
}

public_ipv4() {
  # Prefer the address bound to the default-route interface: on a standard
  # single-IP VPS that IS the public IP, and unlike a curl-based probe it
  # isn't fooled if local traffic happens to be tunnelled elsewhere (e.g.
  # sing-box auto_route hijacking the outbound socket).
  local iface ip
  iface="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
  if [[ -n "$iface" ]]; then
    ip="$(ip -4 addr show dev "$iface" 2>/dev/null \
          | awk '/inet /{split($2,a,"/"); print a[1]; exit}')"
    # reject RFC1918 / loopback / link-local; fall through to curl in that case
    case "$ip" in
      10.*|192.168.*|127.*|169.254.*) ip="" ;;
      172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) ip="" ;;
    esac
    [[ -n "$ip" ]] && { echo "$ip"; return; }
  fi
  curl -fsS --max-time 5 https://api.ipify.org || \
  curl -fsS --max-time 5 https://ifconfig.me || \
  die "could not detect public IPv4 (is curl installed? network OK?)"
}

random_hex() {
  # $1 = bytes
  openssl rand -hex "${1:-8}"
}

write_env_file() {
  # $1 = path, rest = KEY=VALUE lines
  local path="$1"; shift
  install -d -m 0700 "$(dirname "$path")"
  umask 077
  printf '# generated by smart-vpn on %s\n' "$(date -Is)" >"$path"
  local kv
  for kv in "$@"; do printf '%s\n' "$kv" >>"$path"; done
  chmod 0600 "$path"
}

load_env_file() {
  # $1 = path; sources a KEY=VALUE env file into current shell
  local path="$1"
  [[ -r "$path" ]] || die "env file not readable: $path"
  set -a
  # shellcheck disable=SC1090
  . "$path"
  set +a
}
