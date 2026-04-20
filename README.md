# smart-vpn

Two-tier VPN: clients connect to an AmneziaWG server on a Russian VPS, and
that server chain-routes non-RU traffic through a foreign VPS via a second
AmneziaWG tunnel. RU traffic egresses directly from the RU VPS (so
`gosuslugi.ru`, banks, etc. keep working from a Russian IP), everything
else exits from the foreign VPS IP.

```
clients (Keenetic / iOS / Android / laptop)
  │  AmneziaWG  (managed by you via AmneziaVPN app)
  ▼
RU VPS ─┬─ direct ────▶ RU sites + RU IPs        (real egress IP = RU VPS)
        │
        └─ `foreign` iface ▶ AmneziaWG to foreign VPS ▶ everything else
                                (managed by keen-pbr's policy-routing)
```

## Separation of concerns

| Piece                               | Managed by          |
|-------------------------------------|---------------------|
| AmneziaWG server on RU VPS          | **AmneziaVPN app**  |
| AmneziaWG server on foreign VPS     | **AmneziaVPN app**  |
| Client profiles for your devices    | **AmneziaVPN app**  |
| AmneziaWG tunnel RU VPS → foreign   | **you** (drop a `.conf` under `/etc/amnezia/amneziawg/` and `awg-quick up`) |
| `keen-pbr` install + build          | this repo's installer |
| `awg`/`awg-quick` tooling on host   | this repo's installer |
| Split-routing policy (lists, rules) | **you** (`/etc/keen-pbr/config.json` + Web UI) |

The installer in this repo is deliberately minimal: it installs tools and
gets out of your way. No configs are generated, no services are started,
no firewall rules are added. You own `/etc/amnezia/amneziawg/*.conf` and
`/etc/keen-pbr/config.json`.

## Prerequisites

- **RU VPS**: Debian 12, public IPv4, root SSH.
- **Foreign VPS**: anything AmneziaVPN can deploy to (Debian/Ubuntu), outside
  Russia, ideally NL/DE/FI.
- **AmneziaVPN app** installed on a management workstation
  (macOS/Windows/Linux) with SSH access to both VPSes.

## Run order

### 1. Deploy AmneziaWG servers on both VPSes via AmneziaVPN app

Install [AmneziaVPN](https://amnezia.org/) on your workstation. For each
VPS: *Add server* → enter SSH creds → pick **AmneziaWG** protocol → deploy.
Wait for it to finish; you'll end up with two working AmneziaWG servers.

Then generate client profiles:
- **RU VPS server**: one profile per home device (Keenetic, iPhone, laptop).
  Import each into the AmneziaWG client app on the respective device.
- **Foreign VPS server**: one profile named something like `ru-vps-client`.
  Don't import anywhere — you'll place the raw `.conf` on the RU VPS.

### 2. Install tooling on the RU VPS

```bash
ssh root@RU_VPS
curl -fsSL https://raw.githubusercontent.com/lenarx/smart-vpn/main/install-ru.sh | sudo bash
```

Bootstrap clones the repo into `/opt/smart-vpn` and runs
`ru-vps/install.sh`, which apt-gets build deps, builds `keen-pbr` from
source (~3–5 min first time), and leaves everything stopped/unconfigured.

### 3. Wire the RU VPS → foreign VPS tunnel

Copy the foreign-client `.conf` generated in step 1 onto the RU VPS and
import it through the `import-awg-conf.sh` helper. **Do not** drop the
file into `/etc/amnezia/amneziawg/` and `awg-quick up` it verbatim — the
AmneziaVPN-generated profile has `AllowedIPs = 0.0.0.0/0, ::/0` which,
under plain `awg-quick`, hijacks the host's default route and kills SSH
instantly.

```bash
scp foreign-client.conf root@RU_VPS:/tmp/
ssh root@RU_VPS
cd /opt/smart-vpn
sudo ./ru-vps/import-awg-conf.sh /tmp/foreign-client.conf foreign
sudo systemctl enable --now awg-quick@foreign
awg show foreign                  # 'latest handshake: <a few seconds ago>'
ip -brief addr show foreign       # interface up with the subnet IP from .conf
```

What `import-awg-conf.sh` does before writing the file:

- Injects `Table = off` in `[Interface]` so `awg-quick` brings up the
  interface without touching the routing table (keen-pbr will steer
  matched flows into it via its own policy-routing table).
- Strips `DNS = ...` lines — the host is a gateway, not a client; no need
  to hijack `/etc/resolv.conf`.
- Strips empty `I2..I5 = ` / `S3..S4 = ` lines that current
  `amneziawg-tools` rejects with `Line unrecognized`.

### 4. Configure keen-pbr

Edit `/etc/keen-pbr/config.json`. The package ships a working example at
that path. You'll typically want:

- An **`"interface"` outbound** pointing at the `foreign` iface from step 3
  (this is what non-RU traffic goes into).
- Lists for RU domains and RU IPs to keep on the direct path
  (good sources: `outside-raw.lst` from itdoginfo/allow-domains for
  domains, `ru-aggregated.zone` from ipdeny.com for CIDRs).
- A catch-all to route everything else into the `foreign` outbound.
- `api.listen` bound to an internal IP so the Web UI isn't publicly
  reachable. Good choices: the AmneziaWG-server IP on this VPS (reachable
  only through your home-client tunnel) or `127.0.0.1` (reachable only via
  SSH tunnel).

Then:

```bash
systemctl restart keen-pbr
journalctl -u keen-pbr -f
```

Web UI at `http://<your-bound-address>:12121/`.

## Layout

```
smart-vpn/
├── README.md
├── install-ru.sh              one-liner bootstrap (clones repo, invokes ru-vps/install.sh)
├── lib/common.sh              shared bash helpers
└── ru-vps/
    ├── install.sh             installs amneziawg-tools + keen-pbr; no configs, no services
    └── import-awg-conf.sh     sanitize + install an AmneziaVPN-generated .conf under /etc/amnezia/amneziawg/
```

## Operational notes

- Re-running the installer is safe. If `keen-pbr` is already on PATH the
  rebuild is skipped. If it's not, the build reuses the `/opt/smart-vpn/build/keen-pbr`
  clone (`git fetch` + checkout of `KEENPBR_REF`, default `main`).
- **Why build `keen-pbr` from source?** Upstream's Debian apt repo has
  no published packages yet. The release workflow triggers on tag pattern
  `v-*` but real tags are `v2.2.1`-style, so it never runs. When that's
  fixed the installer will pick up an apt-installed binary automatically.
- **Bun bootstrap gotcha:** upstream's `build-frontend.sh` pipes
  `curl bun.sh/install | sh`. On Debian `/bin/sh` is `dash`, which chokes
  on the bun installer's `set -o pipefail`. `install_keenpbr` pre-installs
  bun with bash so upstream's `ensure_bun()` takes the short-circuit path.
- Switching between `amneziawg` and plain `wireguard` for the RU→foreign
  link? Just change the `.conf` in `/etc/amnezia/amneziawg/` (or
  `/etc/wireguard/` for plain WG), bring it up, point keen-pbr's outbound
  at the new iface. No installer rerun needed — tools for both are there.
