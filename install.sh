#!/usr/bin/env bash
# Versioned downloader. The installer and package hashes are pinned.
set -Eeuo pipefail
umask 077
VERSION=v1.1.0
INSTALLER_SHA256=a9fdc11122d3e855c46d04044ee15f3f126d7c2adac86b13f8be4ec0ee4d05d9
URL="https://github.com/BrainDeLook/yggdrasil-vless/releases/download/$VERSION/install-ygg-vless.sh"
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    printf '%s\n' 'Yggdrasil + VLESS Reality — интерактивная установка на Debian / Ubuntu.' \
        'Запуск: sudo bash install.sh' \
        'Без вопросов: sudo bash install.sh --yes --name "Моя нода" --port 1488' \
        'Установщик скачивается из релиза и проверяется по SHA256.'
    exit 0
fi
[[ $EUID -eq 0 ]] || { echo 'Запустите от root: sudo bash install.sh' >&2; exit 1; }
if ! command -v curl >/dev/null || [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
    command -v apt-get >/dev/null || { echo 'Требуется Debian/Ubuntu с APT' >&2; exit 1; }
    mkdir -p /var/log/ygg-vless
    chmod 700 /var/log/ygg-vless
    printf '\nПодготавливаю загрузчик. Журнал: /var/log/ygg-vless/bootstrap.log\n'
    apt-get update >/var/log/ygg-vless/bootstrap.log 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates >>/var/log/ygg-vless/bootstrap.log 2>&1
fi
scratch=$(mktemp -d /tmp/ygg-vless-download.XXXXXXXX)
trap 'rm -rf -- "$scratch"' EXIT
printf '\nЗагружаю установщик %s и проверяю контрольную сумму…\n' "$VERSION"
curl --fail --silent --show-error --location --retry 3 --connect-timeout 20 --max-time 180 \
    --proto '=https' --proto-redir '=https' "$URL" -o "$scratch/install-ygg-vless.sh"
printf '%s  %s\n' "$INSTALLER_SHA256" "$scratch/install-ygg-vless.sh" | sha256sum --check --status || {
    echo 'Контрольная сумма установщика не совпала. Запуск отменён.' >&2
    exit 1
}
bash "$scratch/install-ygg-vless.sh" "$@"
