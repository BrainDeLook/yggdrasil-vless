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
bash "$ROOT/install-ygg-vless.sh" --yes --ssh-port 2222 --allow-ip 200:db8::111 --allow-ip 300:db8:1:1::/64 --allow-ip 300:db8:1:1::111 --name 'Тестовая нода NL' --peer "tcp://127.0.0.1:$PORT" --firewall-ready
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
# Verify access from an actual remote network namespace, with two source IPv6s.
ip netns add ygg-test
ip link add ygg-host type veth peer name ygg-client
ip link set ygg-client netns ygg-test
ip -6 addr add fd42:1234::1/64 dev ygg-host nodad
ip link set ygg-host up
ip -6 route add 200:db8::/64 via fd42:1234::2 dev ygg-host
ip -6 route add 300:db8:1::/48 via fd42:1234::2 dev ygg-host
ip netns exec ygg-test ip link set lo up
ip netns exec ygg-test ip link set ygg-client up
ip netns exec ygg-test ip -6 addr add fd42:1234::2/64 dev ygg-client nodad
ip netns exec ygg-test ip -6 addr add 200:db8::111/128 dev ygg-client nodad
ip netns exec ygg-test ip -6 addr add 200:db8::222/128 dev ygg-client nodad
for source in 300:db8:1:1::111 300:db8:1:1::222 300:db8:1:2::111; do
    ip netns exec ygg-test ip -6 addr add "$source/128" dev ygg-client nodad
done
ip netns exec ygg-test ip -6 route add "$BEFORE/128" via fd42:1234::1 dev ygg-client
ip netns exec ygg-test python3 - "$BEFORE" <<'PY'
import socket,sys
for source,allowed in [('200:db8::111',True),('200:db8::222',False),('300:db8:1:1::111',True),('300:db8:1:1::222',True),('300:db8:1:2::111',False)]:
    for port in [2222,1488]:
        with socket.socket(socket.AF_INET6,socket.SOCK_STREAM) as s:
            s.settimeout(3); s.bind((source,0))
            try:
                s.connect((sys.argv[1],port)); connected=True
                if port==2222: assert s.recv(256).startswith(b'SSH-')
            except (TimeoutError,ConnectionRefusedError): connected=False
            assert connected==allowed,(source,port,connected)
print('PASS: SSH and proxy allow node IP and two changing LAN IPs; reject other node and LAN prefix')
PY
# Authenticate over IPv6 and execute a command, using a throwaway CI-only key.
ssh-keygen -q -t ed25519 -N '' -f "$SCRATCH/ssh-key"
install -d -m 700 /root/.ssh
cat "$SCRATCH/ssh-key.pub" >>/root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
ip netns exec ygg-test ssh -6 -b 200:db8::111 -p 2222 -i "$SCRATCH/ssh-key" \
    -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile="$SCRATCH/known_hosts" \
    -o ConnectTimeout=5 "root@$BEFORE" 'printf SSH_YGG_OK' | grep -q SSH_YGG_OK
echo 'PASS: SSH public-key login and remote command over allowed Yggdrasil IPv6'
ip link del ygg-host
ip netns del ygg-test
systemctl is-active --quiet ygg-vless-access ygg-vless-ssh
# Rules and allowlist survive a full rerun; local self-test still works.
test "$(jq -r '.allowed_ips[0]' /etc/ygg-vless/access.json)" = 200:db8::111
echo 'PASS: package + systemd + TUN + peer + VLESS Reality HTTPS + rename; identity, UUID and Reality keys retained'
