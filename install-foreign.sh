#!/usr/bin/env bash
#
# smart-vpn foreign VPS one-liner bootstrap.
#
#   curl -fsSL https://raw.githubusercontent.com/lenarx/smart-vpn/main/install-foreign.sh | sudo bash
#
# Clones (or updates) this repo at /opt/smart-vpn and invokes the real
# provisioning script. All arguments after `bash -s --` are forwarded.

set -euo pipefail

REPO_URL="${SMART_VPN_REPO:-https://github.com/lenarx/smart-vpn.git}"
REPO_DIR="${SMART_VPN_DIR:-/opt/smart-vpn}"
BRANCH="${SMART_VPN_BRANCH:-main}"

if [[ $EUID -ne 0 ]]; then
  echo "[-] this bootstrap must run as root — use: curl ... | sudo bash" >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "[*] installing git + curl"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git curl ca-certificates
fi

if [[ -d "$REPO_DIR/.git" ]]; then
  echo "[*] updating $REPO_DIR"
  git -C "$REPO_DIR" fetch --quiet origin "$BRANCH"
  git -C "$REPO_DIR" reset --hard "origin/$BRANCH" --quiet
else
  echo "[*] cloning $REPO_URL → $REPO_DIR"
  install -d -m 0755 "$(dirname "$REPO_DIR")"
  git clone --quiet --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
fi

cd "$REPO_DIR"
exec ./foreign-vps/install.sh "$@"
