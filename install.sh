#!/usr/bin/env bash
# Versioned downloader. The installer and package hashes are pinned.
set -Eeuo pipefail
umask 077
VERSION=v1.0.0
INSTALLER_SHA256=33d9369ac6889993d2dc2e698375fec3589849c61c2f8de3f60563345a7a3bfc
URL="https://github.com/BrainDeLook/yggdrasil-vless/releases/download/$VERSION/install-ygg-vless.sh"
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    printf '%s\n' 'Yggdrasil + VLESS installer for Debian 12+/Ubuntu 22.04+, amd64/arm64.' \
        'Run as root. Arguments are forwarded: --port 2443, --peer tls://HOST:PORT.' \
        'This downloader fetches a versioned release and verifies its pinned SHA256.'
    exit 0
fi
[[ $EUID -eq 0 ]] || { echo 'Run as root: sudo bash install.sh' >&2; exit 1; }
if ! command -v curl >/dev/null || [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
    command -v apt-get >/dev/null || { echo 'Debian/Ubuntu with APT required' >&2; exit 1; }
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates
fi
scratch=$(mktemp -d /tmp/ygg-vless-download.XXXXXXXX)
trap 'rm -rf -- "$scratch"' EXIT
curl --fail --show-error --location --retry 3 --connect-timeout 20 --max-time 180 \
    --proto '=https' --proto-redir '=https' "$URL" -o "$scratch/install-ygg-vless.sh"
printf '%s  %s\n' "$INSTALLER_SHA256" "$scratch/install-ygg-vless.sh" | sha256sum --check --status || {
    echo 'Installer SHA256 verification FAILED; nothing has been executed.' >&2
    exit 1
}
bash "$scratch/install-ygg-vless.sh" "$@"
