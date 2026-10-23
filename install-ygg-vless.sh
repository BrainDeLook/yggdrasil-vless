#!/usr/bin/env bash
# Debian 12+/Ubuntu 22.04+, systemd, amd64/arm64. Run as root.
set -Eeuo pipefail
umask 077
export LC_ALL=C
BASE=/etc/ygg-vless
APP=/opt/ygg-vless
SERVICE=ygg-vless
YGG_VERSION=0.5.14
SB_VERSION=1.14.3
MODE=install
PORT=''
FIREWALL_READY=0
PEERS=()
TMP=''
TEST_PID=''
log() { printf '\n[ygg-vless] %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
cleanup() {
    if [[ -n "$TEST_PID" ]]; then kill "$TEST_PID" 2>/dev/null || true; wait "$TEST_PID" 2>/dev/null || true; fi
    if [[ -n "$TMP" && "$TMP" == /tmp/ygg-vless.* ]]; then rm -rf -- "$TMP"; fi
}
trap cleanup EXIT
trap 'printf "\nFailed at line %s. Existing identity and backups are retained.\n" "$LINENO" >&2' ERR
while (($#)); do
    case "$1" in
        --show-link) MODE=link; shift ;;
        --status) MODE=status; shift ;;
        --test) MODE=test; shift ;;
        --port) [[ $# -ge 2 ]] || die 'Missing --port value'; PORT=$2; shift 2 ;;
        --peer) [[ $# -ge 2 ]] || die 'Missing --peer URI'; PEERS+=("$2"); shift 2 ;;
        --firewall-ready) FIREWALL_READY=1; shift ;;
        -h|--help)
            cat <<'HELP'
sudo bash install-ygg-vless.sh [--port 1488] [--peer tls://HOST:PORT ...]
sudo ygg-vless --show-link | --status | --test
Existing Yggdrasil identity and peers are preserved. --peer replaces the peer list.
Custom firewall: configure IPv6 TCP input on the Yggdrasil interface yourself,
then use --firewall-ready. UFW/firewalld are configured automatically if active.
HELP
            exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
[[ $EUID -eq 0 ]] || die 'Run with sudo bash install-ygg-vless.sh'
if [[ "$MODE" == link ]]; then cat "$BASE/client.txt"; exit 0; fi
if [[ "$MODE" == status ]]; then
    systemctl --no-pager --full status yggdrasil "$SERVICE" || true
    ss -lntp
    journalctl -u "$SERVICE" -n 20 --no-pager
    exit 0
fi

self_test() {
    [[ -s "$BASE/settings.json" && -x "$APP/sing-box" ]] || die 'Install first'
    TMP=${TMP:-$(mktemp -d /tmp/ygg-vless.XXXXXXXX)}
    local test_port result
    test_port=$(python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(('127.0.0.1',0)); print(s.getsockname()[1])
PY
)
    python3 - "$BASE/settings.json" "$TMP/test.json" "$test_port" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
c={"log":{"level":"warn"},
   "inbounds":[{"type":"socks","tag":"test-in","listen":"127.0.0.1","listen_port":int(sys.argv[3])}],
   "outbounds":[{"type":"vless","tag":"test-out","server":s['address'],
                 "server_port":s['port'],"uuid":s['uuid']}],
   "route":{"final":"test-out"}}
with open(sys.argv[2],'w') as f: json.dump(c,f,indent=2)
PY
    "$APP/sing-box" check -c "$TMP/test.json"
    "$APP/sing-box" run -c "$TMP/test.json" >"$TMP/test.log" 2>&1 &
    TEST_PID=$!
    local ready=0
    for _ in {1..20}; do
        kill -0 "$TEST_PID" 2>/dev/null || { cat "$TMP/test.log"; die 'Test client failed to start'; }
        if python3 - "$test_port" <<'PY'
import socket,sys
try:
    with socket.create_connection(('127.0.0.1',int(sys.argv[1])),timeout=.3): pass
except OSError: sys.exit(1)
PY
        then ready=1; break; fi
        sleep .2
    done
    [[ $ready == 1 ]] || die 'Test client did not become ready'
    log 'Testing domain-name destination through SOCKS -> VLESS -> server DNS -> Internet'
    if ! result=$(curl --silent --show-error --noproxy '' \
        --proxy "socks5h://127.0.0.1:$test_port" --connect-timeout 15 --max-time 35 \
        --output /dev/null --write-out '%{http_code}' https://www.gstatic.com/generate_204); then
        cat "$TMP/test.log"
        journalctl -u "$SERVICE" -n 25 --no-pager
        die 'VLESS HTTPS test failed. Fix the error and rerun: sudo ygg-vless --test'
    fi
    [[ "$result" == 204 ]] || die "Test URL returned HTTP $result instead of 204"
    kill "$TEST_PID" 2>/dev/null || true
    wait "$TEST_PID" 2>/dev/null || true
    TEST_PID=''
    log 'PASS: VLESS authentication, server-side DNS and HTTPS (HTTP 204).'
    printf '%s\n' 'This local test does not prove reachability from a remote Yggdrasil client.'
}
if [[ "$MODE" == test ]]; then self_test; exit 0; fi

[[ -r /etc/os-release ]] || die 'No /etc/os-release'
. /etc/os-release
case "${ID:-}:" in
    debian:) [[ ${VERSION_ID%%.*} -ge 12 ]] || die 'Debian 12+ required' ;;
    ubuntu:) [[ ${VERSION_ID%%.*} -ge 22 ]] || die 'Ubuntu 22.04+ required' ;;
    *) die 'Supported: Debian 12+ or Ubuntu 22.04+, not OpenWrt' ;;
esac
[[ -d /run/systemd/system ]] || die 'A running systemd is required (use a VPS, not an ordinary Docker container)'
command -v dpkg >/dev/null || die 'dpkg not found'
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
    amd64)
        YGG_SHA=72745496b09baa1c3f5a6741e1257a704cfdb9d00cdf3ddbef025987b239699d
        SB_SHA=e2bdf179c15a3652955dc44867e33ca0965c9c9b91b34267dcc5a5d639a5feee ;;
    arm64)
        YGG_SHA=ac8c9a9a76c54b878fd251aef5a2bbd20375c6109b28b32435683441462360c9
        SB_SHA=29dae24d76bea3bc62d07dd3e60cfc12003de7debbd6b768df9be9c68360174e ;;
    *) die 'Only amd64 and arm64 are supported' ;;
esac
[[ -z "$PORT" || ( "$PORT" =~ ^[0-9]{1,5}$ && $((10#$PORT)) -ge 1024 && $((10#$PORT)) -le 65535 ) ]] || die 'Port must be 1024..65535'
if [[ ${#PEERS[@]} -gt 0 ]]; then
    for peer in "${PEERS[@]}"; do [[ "$peer" == tls://* || "$peer" == tcp://* || "$peer" == quic://* ]] || die "Invalid peer URI: $peer"; done
fi
[[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) == 0 ]] || die 'IPv6 is disabled. Enable IPv6 in the OS first; public ISP IPv6 is not required.'
FW=none
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    FW=ufw
    grep -Eq '^IPV6=yes' /etc/default/ufw || die 'Active UFW has IPV6 disabled; enable IPv6 support in UFW first'
elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    FW=firewalld
elif [[ $FIREWALL_READY == 0 ]]; then
    if command -v nft >/dev/null && nft list ruleset 2>/dev/null | grep 'hook input' >/dev/null; then
        die 'Custom nftables input firewall detected. Permit this node TCP port on its Yggdrasil interface, then rerun with --firewall-ready. Existing rules have not been changed.'
    fi
    if command -v ip6tables-save >/dev/null && ip6tables-save 2>/dev/null | grep -E '^:INPUT DROP|^-A INPUT' >/dev/null; then
        die 'Custom IPv6 iptables input firewall detected. Configure its Yggdrasil permit rule, then rerun with --firewall-ready.'
    fi
fi
log "Installing dependencies ($ID, $ARCH)"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl jq python3 iproute2 iputils-ping tar coreutils kmod util-linux passwd
modprobe tun 2>/dev/null || true
[[ -c /dev/net/tun ]] || die '/dev/net/tun unavailable; enable TUN in the VPS/container control panel'
install -d -m 700 "$BASE" "$BASE/backups"
install -d -m 755 "$APP"
TMP=$(mktemp -d /tmp/ygg-vless.XXXXXXXX)
STAMP=$(date -u +%Y%m%dT%H%M%S)-$$
exec 9>"$BASE/install.lock"
flock -n 9 || die 'Another installation is running'
download_checked() {
    local url=$1 path=$2 digest=$3
    curl --fail --show-error --location --retry 3 --connect-timeout 20 --max-time 300 \
        --proto '=https' --proto-redir '=https' "$url" -o "$path"
    printf '%s  %s\n' "$digest" "$path" | sha256sum --check --status || die "SHA256 mismatch: $url"
}
if ! command -v yggdrasil >/dev/null; then
    log "Installing official Yggdrasil $YGG_VERSION package (SHA256 verified)"
    download_checked "https://github.com/yggdrasil-network/yggdrasil-go/releases/download/v$YGG_VERSION/yggdrasil-$YGG_VERSION-$ARCH.deb" "$TMP/yggdrasil.deb" "$YGG_SHA"
    chmod 755 "$TMP"
    chmod 644 "$TMP/yggdrasil.deb"
    apt-get install -y "$TMP/yggdrasil.deb"
else
    log 'Keeping installed Yggdrasil and its identity'
    yggdrasil -version
    yggdrasil -version | grep -Eq 'Build version: 0\.5\.' || die 'Existing Yggdrasil must be version 0.5.x. Upgrade it without deleting its configuration, then rerun.'
fi
command -v yggdrasilctl >/dev/null || die 'yggdrasilctl not found; install the official Yggdrasil package'
YGG_BIN=$(command -v yggdrasil)
if [[ ! -s /etc/yggdrasil.conf ]]; then
    "$YGG_BIN" -genconf -json >"$TMP/ygg-original.json"
else
    cp -p /etc/yggdrasil.conf "$BASE/backups/yggdrasil.conf.$STAMP"
    "$YGG_BIN" -useconffile /etc/yggdrasil.conf -normaliseconf -json >"$TMP/ygg-original.json"
fi
python3 - "$TMP/ygg-original.json" "$TMP/yggdrasil.json" "${PEERS[@]}" <<'PY'
import json,sys
c=json.load(open(sys.argv[1])); peers=sys.argv[3:]
if peers:
    c['Peers']=peers
elif not c.get('Peers') and not any(c.get('InterfacePeers',{}).values()):
    c['Peers']=[
      'tls://nl1.route172.de:443?key=000000002643ae27bad63e2a81f1d30554ce9ea634f5990062a9e079e23593cd',
      'tls://cirno.nadeko.net:44442',
      'tls://vpn.itrus.su:7992']
# Retain existing listeners and multicast settings. Fresh nodes need only outbound peers.
if not c.get('AdminListen') or c['AdminListen']=='none':
    c['AdminListen']='unix:///var/run/yggdrasil.sock'
if not c.get('IfName') or c['IfName']=='none': c['IfName']='ygg0'
with open(sys.argv[2],'w') as f: json.dump(c,f,indent=2)
PY
"$YGG_BIN" -useconffile "$TMP/yggdrasil.json" -normaliseconf -json >/dev/null
if getent group yggdrasil >/dev/null; then
    install -o root -g yggdrasil -m 640 "$TMP/yggdrasil.json" /etc/yggdrasil.conf
else
    install -o root -g root -m 600 "$TMP/yggdrasil.json" /etc/yggdrasil.conf
fi
ADDRESS=$("$YGG_BIN" -useconffile /etc/yggdrasil.conf -address)
python3 - "$ADDRESS" <<'PY'
import ipaddress,sys
a=ipaddress.IPv6Address(sys.argv[1])
assert a in ipaddress.IPv6Network('200::/7'), 'Unexpected Yggdrasil address'
PY
ADMIN=$(jq -r '.AdminListen' "$TMP/yggdrasil.json")
systemctl enable yggdrasil
systemctl restart yggdrasil
log 'Waiting for Yggdrasil address and at least one connected peer (up to 90 seconds)'
READY=0
for _ in {1..45}; do
    if ip -j -6 address show | jq -e --arg a "$ADDRESS" 'any(.[].addr_info[]?; .local == $a)' >/dev/null && \
       timeout 3 yggdrasilctl -endpoint="$ADMIN" -json getPeers >"$TMP/peers.json" 2>/dev/null && \
       jq -e 'any(.peers[]?; .up == true)' "$TMP/peers.json" >/dev/null; then
        READY=1; break
    fi
    sleep 2
done
if [[ $READY != 1 ]]; then
    journalctl -u yggdrasil -n 30 --no-pager
    [[ ! -s "$TMP/peers.json" ]] || cat "$TMP/peers.json"
    die 'No connected Yggdrasil peer/address. Check VPS outbound connectivity or rerun with --peer URI.'
fi
IFACE=$(ip -j -6 address show | jq -r --arg a "$ADDRESS" '.[] | select(any(.addr_info[]?; .local == $a)) | .ifname' | head -n1)
log "Yggdrasil ready: $ADDRESS on $IFACE"
if [[ ! -x "$APP/sing-box" ]] || ! "$APP/sing-box" version | head -n1 | grep -Fq "version $SB_VERSION"; then
    download_checked "https://github.com/SagerNet/sing-box/releases/download/v$SB_VERSION/sing-box-$SB_VERSION-linux-$ARCH.tar.gz" "$TMP/sing-box.tar.gz" "$SB_SHA"
    tar -xzf "$TMP/sing-box.tar.gz" -C "$TMP" "sing-box-$SB_VERSION-linux-$ARCH/sing-box"
    install -m 755 "$TMP/sing-box-$SB_VERSION-linux-$ARCH/sing-box" "$APP/sing-box.new"
    "$APP/sing-box.new" version
    mv -f "$APP/sing-box.new" "$APP/sing-box"
fi
[[ ! -f "$BASE/settings.json" ]] || cp -p "$BASE/settings.json" "$BASE/backups/settings.$STAMP.json"
[[ ! -f "$BASE/server.json" ]] || cp -p "$BASE/server.json" "$BASE/backups/server.$STAMP.json"
python3 - "$BASE" "$TMP" "$ADDRESS" "$PORT" <<'PY'
import json,sys,uuid,pathlib
base,tmp=map(pathlib.Path,sys.argv[1:3]); addr=sys.argv[3]; port=sys.argv[4]
p=base/'settings.json'; old=json.loads(p.read_text()) if p.exists() else {}
s={'address':addr,'port':int(port or old.get('port',1488)), 'uuid':str(uuid.UUID(old['uuid'])) if old.get('uuid') else str(uuid.uuid4())}
assert 1024<=s['port']<=65535
c={'log':{'level':'info','timestamp':True},
   'dns':{'servers':[{'type':'local','tag':'system-dns'}]},
   'inbounds':[{'type':'vless','tag':'ygg-vless-in','listen':addr,'listen_port':s['port'],
                'users':[{'name':'owner','uuid':s['uuid']}]}],
   'outbounds':[{'type':'direct','tag':'internet'}],
   'route':{'default_domain_resolver':{'server':'system-dns','strategy':'ipv4_only'},
            'rules':[{'action':'resolve','strategy':'ipv4_only'}], 'final':'internet'}}
for name,data in [('settings.json',s),('server.json',c)]:
    (tmp/name).write_text(json.dumps(data,indent=2)+'\n')
(tmp/'client.txt').write_text(f"vless://{s['uuid']}@[{addr}]:{s['port']}?encryption=none&security=none&type=tcp#Yggdrasil-VLESS\n")
(tmp/'client-outbound.json').write_text(json.dumps({'type':'vless','tag':'Yggdrasil-VLESS','server':addr,'server_port':s['port'],'uuid':s['uuid']},indent=2)+'\n')
PY
"$APP/sing-box" check -c "$TMP/server.json"
PORT=$(jq -r .port "$TMP/settings.json")
if ! id -u ygg-vless >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin ygg-vless
fi
for name in settings.json client.txt client-outbound.json; do install -m 600 "$TMP/$name" "$BASE/$name"; done
chown root:ygg-vless "$BASE"
chmod 750 "$BASE"
install -o root -g ygg-vless -m 640 "$TMP/server.json" "$BASE/server.json"
if [[ "$FW" == ufw ]]; then
    ufw allow in on "$IFACE" from 200::/7 to "$ADDRESS" port "$PORT" proto tcp comment 'ygg-vless'
elif [[ "$FW" == firewalld ]]; then
    ZONE=$(firewall-cmd --get-zone-of-interface="$IFACE" 2>/dev/null || true)
    [[ -n "$ZONE" && "$ZONE" != 'no zone' ]] || ZONE=$(firewall-cmd --get-default-zone)
    RULE="rule family=ipv6 source address=200::/7 destination address=$ADDRESS port port=$PORT protocol=tcp accept"
    firewall-cmd --permanent --zone="$ZONE" --add-rich-rule="$RULE"
    firewall-cmd --zone="$ZONE" --add-rich-rule="$RULE"
fi
cat >/etc/systemd/system/ygg-vless.service <<'UNIT'
[Unit]
Description=VLESS proxy over Yggdrasil
Wants=network-online.target yggdrasil.service
After=network-online.target yggdrasil.service
StartLimitIntervalSec=0

[Service]
Type=simple
User=ygg-vless
Group=ygg-vless
ExecStartPre=/opt/ygg-vless/sing-box check -c /etc/ygg-vless/server.json
ExecStart=/opt/ygg-vless/sing-box run -c /etc/ygg-vless/server.json
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable "$SERVICE"
systemctl restart "$SERVICE"
ACTIVE=0
for _ in {1..15}; do
    if systemctl is-active --quiet "$SERVICE" && ss -H -lnt "sport = :$PORT" | grep -Fq "$ADDRESS"; then ACTIVE=1; break; fi
    sleep 1
done
if [[ $ACTIVE != 1 ]]; then journalctl -u "$SERVICE" -n 30 --no-pager; die 'VLESS service did not bind'; fi
if [[ -f "$0" ]]; then
    if [[ $(readlink -f "$0") != "$APP/manage.sh" ]]; then install -m 700 "$0" "$APP/manage.sh"; fi
    ln -sfn "$APP/manage.sh" /usr/local/sbin/ygg-vless
fi
self_test
log 'Installation complete. Copy this link into Tachyon or a VLESS client:'
cat "$BASE/client.txt"
printf '\n%s\n' \
    'Show link: sudo ygg-vless --show-link' \
    'Check: sudo ygg-vless --test' \
    'Logs: sudo journalctl -u ygg-vless -f' \
    'Client must have IPv6 routing to 200::/7 through Yggdrasil.' \
    'If a provider firewall filters outbound traffic, permit the configured peer endpoints.' \
    'IPv4 Internet egress is intentional; no public IPv6, domain or certificate is required.'
