#!/usr/bin/env bash
#
# Safely import an AmneziaWG client .conf (from AmneziaVPN app) into
# /etc/amnezia/amneziawg/ on this RU VPS. Sanitizes it in ways you almost
# certainly want when the "client" is actually a router, not an end device:
#
#   1. Adds `Table = off` in [Interface]. Without this, awg-quick installs
#      a default route via the tunnel (because AllowedIPs = 0.0.0.0/0 is
#      present in AmneziaVPN-generated configs), which INSTANTLY KILLS your
#      SSH session: return traffic from the RU VPS tries to egress through
#      the foreign VPS, but there's no SNAT there for the RU VPS's public
#      IP, so packets vanish. keen-pbr's policy routing will send the
#      matched flows into this interface on its own — it doesn't need the
#      main routing table to do so.
#
#   2. Strips `DNS = ...` lines. The tunnel terminates on a gateway, not
#      on an end device — don't hijack /etc/resolv.conf for the host.
#      Whatever local resolver you run (or the one keen-pbr manages via
#      dnsmasq) stays in charge.
#
#   3. Drops empty `I2..I5 =` and `S3/S4 =` lines. AmneziaVPN app emits
#      these with blank values for configs that don't use the full
#      obfuscation suite; the awg-tools parser currently rejects empty
#      values with "Line unrecognized: `I2='".
#
# Usage:
#   sudo ./ru-vps/import-awg-conf.sh <source-conf> [<iface-name>]
#
#   <iface-name> defaults to the source filename with the trailing `.conf`
#   stripped. Must fit IFNAMSIZ (15 chars) and match [a-zA-Z0-9._-].

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

SRC="${1:-}"
NAME="${2:-}"

[[ -n "$SRC" ]] || die "usage: sudo $0 <source-conf> [<iface-name>]"
[[ -f "$SRC"  ]] || die "source file not found: $SRC"

if [[ -z "$NAME" ]]; then
  NAME="$(basename "$SRC" .conf)"
fi
[[ "$NAME" =~ ^[a-zA-Z0-9._-]{1,15}$ ]] || \
  die "iface name must match [a-zA-Z0-9._-]{1,15} (got: $NAME)"

require_root "$@"

DEST="/etc/amnezia/amneziawg/${NAME}.conf"
install -d -m 0700 /etc/amnezia/amneziawg

TMP="$(mktemp -p /etc/amnezia/amneziawg ".${NAME}.tmp.XXXXXX")"
chmod 0600 "$TMP"
trap 'rm -f "$TMP"' EXIT

# Stream the source through awk:
#   * inside [Interface], drop existing Table= / DNS= and empty I2..I5 / S3/S4
#   * inject our Table = off right before the section ends (or at EOF if no
#     [Peer] follows)
awk '
BEGIN { in_iface = 0; emitted_table = 0 }

function flush_table() {
  if (in_iface && !emitted_table) {
    print "Table = off"
    emitted_table = 1
  }
}

/^[[:space:]]*\[Interface\][[:space:]]*$/ { in_iface = 1; print; next }
/^[[:space:]]*\[/                         { flush_table(); in_iface = 0; print; next }

{
  if (in_iface) {
    if ($0 ~ /^[[:space:]]*Table[[:space:]]*=/)             next
    if ($0 ~ /^[[:space:]]*DNS[[:space:]]*=/)               next
    if ($0 ~ /^[[:space:]]*I[2-5][[:space:]]*=[[:space:]]*$/) next
    if ($0 ~ /^[[:space:]]*S[3-4][[:space:]]*=[[:space:]]*$/) next
  }
  print
}

END { flush_table() }
' "$SRC" >"$TMP"

# Minimal sanity check: must have ended up with [Interface] + Table = off
grep -q '^\[Interface\]'    "$TMP" || die "no [Interface] section in source"
grep -q '^Table = off'      "$TMP" || die "awk sanitizer failed to inject Table = off"

mv -f "$TMP" "$DEST"
trap - EXIT
chmod 0600 "$DEST"
ok "wrote $DEST"

cat >&2 <<EOF

${C_YELLOW}Next:${C_RESET}
  systemctl enable --now awg-quick@${NAME}
  awg show ${NAME}              # expect: latest handshake: <a few seconds ago>
  ip -brief addr show ${NAME}   # expect: the v4 address from your .conf

EOF
