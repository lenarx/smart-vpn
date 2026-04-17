# smart-vpn

Two-tier VPN where clients see one WireGuard tunnel to a Russian VPS, and the
RU VPS transparently splits traffic by destination: Russian domains go out
directly (so `gosuslugi.ru`, banks, etc. still work), everything else is
chained through a foreign VPS via VLESS+Reality.

```
clients (Keenetic / iOS / Android / laptop)
  │  AmneziaWG (default, DPI-obfuscated) — or plain WireGuard with --protocol wireguard
  ▼
RU VPS  ─── direct ────▶  *.ru, *.su, Russia geoip       (real client-facing IP = RU VPS)
  │
  │  VLESS + Reality  (DPI-resistant; masquerades as TLS to the configured SNI)
  ▼
Foreign VPS ──────────▶  blocked sites (YouTube, Meta, etc.)
```

Why this shape:

- **Clients stay dumb.** One WG profile, no per-device domain lists. Add a
  new device → one QR code, it just works.
- **Domain-based split lives on the RU VPS**, not on clients. sing-box picks
  the outbound using auto-updated `geoip-ru` + `geosite-ru` rule-sets from
  SagerNet — no manual IP lists, no Keenetic tricks.
- **Link to foreign VPS is the only place DPI matters**, so that's where we
  use VLESS+Reality. The RU-side WireGuard is a plain tunnel to a domestic
  IP, which Russian ISPs don't block.

## Prerequisites

- **Foreign VPS**: Debian 12 (or Ubuntu 24.04), public IPv4, port 443 free.
  Outside Russia, ideally NL/DE/FI.
- **RU VPS**: Debian 12, public IPv4, a UDP port reachable from home (default
  51820). *Check the hoster's ToS — some RU providers forbid running VPNs for
  circumvention purposes.*
- Root SSH on both.

## Run order

### 1. Provision the foreign VPS

```bash
ssh root@FOREIGN_VPS
curl -fsSL https://raw.githubusercontent.com/lenarx/smart-vpn/main/install-foreign.sh | sudo bash
# optional args after '-s --':
# curl ... | sudo bash -s -- --sni addons.mozilla.org --port 8443
```

Writes `/root/smart-vpn/foreign.env` with the Reality credentials the RU VPS
will consume. Prints the next command to run.

### 2. Provision the RU VPS

Copy the env file from the foreign VPS, then run the installer:

```bash
ssh root@RU_VPS
mkdir -p /root/smart-vpn
scp root@FOREIGN_VPS:/root/smart-vpn/foreign.env /root/smart-vpn/foreign.env
curl -fsSL https://raw.githubusercontent.com/lenarx/smart-vpn/main/install-ru.sh | \
  sudo bash -s -- --foreign-env /root/smart-vpn/foreign.env
# default is AmneziaWG. For plain WireGuard (no obfuscation), add:
#   --protocol wireguard
```

The bootstrap scripts clone (or update) this repo at `/opt/smart-vpn` and
then invoke the real provisioning script, forwarding all extra arguments.
Re-run the same command later to pull fresh config changes.

### 3. Add clients

After the RU VPS is up, client profiles are generated via the checked-out
repo at `/opt/smart-vpn`:

```bash
cd /opt/smart-vpn
sudo ./ru-vps/add-client.sh my-keenetic
sudo ./ru-vps/add-client.sh iphone
sudo ./ru-vps/add-client.sh laptop
```

Each run prints a QR code and writes the profile to
`/root/smart-vpn/clients/<name>.conf`. Import target depends on the protocol
picked at install time.

**If you chose AmneziaWG (default):**

Use the dedicated **AmneziaWG** app — *not* the main AmneziaVPN app. The
two are separate products: AmneziaVPN uses its own `vpn://` connection
format and doesn't reliably import QR codes generated from raw `.conf`
files, while AmneziaWG is a fork of the WireGuard app that natively
understands `.conf` profiles with `Jc/Jmin/Jmax/S1/S2/H1-H4` parameters.

- **iOS** — AmneziaWG on the App Store.
- **Android** — AmneziaWG on Google Play (package `org.amnezia.awg`).
- **Windows** — AmneziaWG Windows client from the project's GitHub releases.
- **macOS** — build [`amneziawg-apple`](https://github.com/amnezia-vpn/amneziawg-apple)
  from source (no App Store build at the moment).
- **Linux** — `amneziawg-tools` (provides `awg-quick`), then
  `awg-quick up <path>/<name>.conf`.
- **Keenetic** — KeeneticOS 4.2+ with the `amneziawg` component
  (`System → Components → amneziawg`), then
  `Internet → Other connections → AmneziaWG` and paste the config.

The main AmneziaVPN app can also import the `.conf` via the file picker
as a fallback, but QR scan into AmneziaVPN will typically fail.

**If you chose plain WireGuard:**

- **Keenetic** — `Internet → Other connections → WireGuard`.
- Everywhere else — the stock WireGuard app (or AmneziaVPN via file import).

## Layout

```
smart-vpn/
├── README.md
├── lib/common.sh           shared bash helpers (logging, apt, sing-box install)
├── foreign-vps/install.sh  VLESS+Reality server (sing-box)
└── ru-vps/
    ├── install.sh          WG server + sing-box TUN + geosite/geoip routing
    └── add-client.sh       per-client WG profile + QR
```

## Operational notes

- Re-running either installer is safe; existing keys and AmneziaWG
  obfuscation params are reused, only configs are rewritten.
- `add-client.sh` hot-reloads the tunnel via `wg syncconf` / `awg syncconf`
  so existing peers aren't interrupted.
- `geoip-ru` and `geosite-ru` rule-sets auto-update every 72h inside
  sing-box. No cron needed.
- Logs: `journalctl -u sing-box -f` on either VPS. Peer status:
  `wg show` or `awg show` depending on the protocol chosen.
- If the chain to the foreign VPS breaks, clients lose non-RU connectivity
  but RU sites keep working — a nice-to-have fault mode.
- Switching between AmneziaWG and WireGuard later means rerunning
  `ru-vps/install.sh --protocol ...`, regenerating client profiles, and
  reimporting them — the on-the-wire formats aren't compatible.
