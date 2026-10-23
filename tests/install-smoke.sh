#!/usr/bin/env bash
# Run only on a disposable Ubuntu VM (GitHub hosted runner), as root.
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
SCRATCH=$(mktemp -d /tmp/ygg-vless-smoke.XXXXXXXX)
PEER_PID=''
cleanup() {
    [[ -z "$PEER_PID" ]] || kill "$PEER_PID" 2>/dev/null || true
    rm -rf -- "$SCRATCH"
}
trap cleanup EXIT
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates jq python3
curl -fL --retry 3 \
    https://github.com/yggdrasil-network/yggdrasil-go/releases/download/v0.5.14/yggdrasil-0.5.14-amd64.deb \
    -o "$SCRATCH/yggdrasil.deb"
echo "72745496b09baa1c3f5a6741e1257a704cfdb9d00cdf3ddbef025987b239699d  $SCRATCH/yggdrasil.deb" | sha256sum -c -
chmod 755 "$SCRATCH"
chmod 644 "$SCRATCH/yggdrasil.deb"
apt-get install -y "$SCRATCH/yggdrasil.deb"

# Reproduce v1.0.0 failure: the real package config and a different orphan exist.
ACTIVE=/etc/yggdrasil/yggdrasil.conf
test -s "$ACTIVE"
systemctl show yggdrasil --property=ExecStart --value | grep -F "$ACTIVE"
BEFORE=$(yggdrasil -useconffile "$ACTIVE" -address)
yggdrasil -genconf -json >/etc/yggdrasil.conf
ORPHAN_SHA=$(sha256sum /etc/yggdrasil.conf)

# Use a local real Yggdrasil peer, rather than depending on public peer uptime.
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
yggdrasil -genconf -json | jq --arg uri "tcp://127.0.0.1:$PORT" \
    '.IfName="none" | .AdminListen="none" | .MulticastInterfaces=[] | .Peers=[] | .Listen=[$uri]' >"$SCRATCH/peer.json"
yggdrasil -useconffile "$SCRATCH/peer.json" >"$SCRATCH/peer.log" 2>&1 &
PEER_PID=$!
sleep 1
kill -0 "$PEER_PID"
bash "$ROOT/install-ygg-vless.sh" --yes --name 'Тестовая нода NL' --peer "tcp://127.0.0.1:$PORT" --firewall-ready
AFTER=$(yggdrasil -useconffile "$ACTIVE" -address)
test "$BEFORE" = "$AFTER"
test "$ORPHAN_SHA" = "$(sha256sum /etc/yggdrasil.conf)"
test "$(jq -r .address /etc/ygg-vless/settings.json)" = "$BEFORE"
systemctl is-active --quiet yggdrasil ygg-vless
UUID_BEFORE=$(jq -r .uuid /etc/ygg-vless/settings.json)
REALITY_KEY_BEFORE=$(jq -r .reality_private_key /etc/ygg-vless/settings.json)
test "$(jq -r .name /etc/ygg-vless/settings.json)" = 'Тестовая нода NL'
# Repeat the full install to prove the repair/rerun preserves UUID and address.
bash "$ROOT/install-ygg-vless.sh" --yes --name 'Новое имя NL' --firewall-ready
test "$UUID_BEFORE" = "$(jq -r .uuid /etc/ygg-vless/settings.json)"
test "$BEFORE" = "$(yggdrasil -useconffile "$ACTIVE" -address)"
test "$ORPHAN_SHA" = "$(sha256sum /etc/yggdrasil.conf)"
test "$REALITY_KEY_BEFORE" = "$(jq -r .reality_private_key /etc/ygg-vless/settings.json)"
test "$(jq -r .name /etc/ygg-vless/settings.json)" = 'Новое имя NL'
grep -q 'security=reality' /etc/ygg-vless/client.txt
echo 'PASS: package + systemd + TUN + peer + VLESS Reality HTTPS + rename; identity, UUID and Reality keys retained'
