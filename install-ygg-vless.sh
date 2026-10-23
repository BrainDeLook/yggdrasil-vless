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
INSTALLER_VERSION=1.4.0
ALLOW_IPS=()
SSH_PORT=''
MODE=install
PORT=''
NODE_NAME=''
REALITY_SERVER=''
ASSUME_YES=0
INSTALL_LOG=''
exec 3>&1
FIREWALL_READY=0
PEERS=()
TMP=''
TEST_PID=''
C_RESET='' C_CYAN='' C_GREEN='' C_YELLOW='' C_RED='' C_BOLD=''
if [[ -t 3 && ${TERM:-} != dumb && ! ${NO_COLOR+x} ]]; then
    C_RESET=$'\033[0m' C_CYAN=$'\033[36m' C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m' C_RED=$'\033[31m' C_BOLD=$'\033[1m'
fi
log() {
    local color=$C_CYAN
    [[ "$*" != '✓'* ]] || color=$C_GREEN
    printf '\n  %s%s%s\n' "$color" "$*" "$C_RESET" >&3
}
die() { printf '\n  %sОшибка: %s%s\n' "$C_RED" "$*" "$C_RESET" >&3; [[ -z "$INSTALL_LOG" ]] || printf '  Журнал: %s\n' "$INSTALL_LOG" >&3; exit 1; }
on_error() {
    printf '\n  Установка остановлена. Изменения не завершены.\n' >&3
    if [[ -n "$INSTALL_LOG" ]]; then
        printf '  Подробный журнал: %s\n\n' "$INSTALL_LOG" >&3
        tail -n 12 "$INSTALL_LOG" >&3 || true
    fi
    exit 1
}
show_result() {
    python3 - "$BASE" <<'PY'
import json,pathlib,sys,os
colored=sys.stdout.isatty() and os.environ.get('TERM')!='dumb' and 'NO_COLOR' not in os.environ
def tint(text,code): return '\033['+code+'m'+text+'\033[0m' if colored else text
base=pathlib.Path(sys.argv[1])
settings=json.loads((base/'settings.json').read_text(encoding='utf-8'))
link=(base/'client.txt').read_text(encoding='utf-8').strip()
tachyon=(base/'client-tachyon.json').read_text(encoding='utf-8').strip()
def panel(title,content,color="36"):
    # Keep the payload unprefixed and unwrapped: copy/paste must preserve valid JSON/URI.
    width=72
    print(tint('\n  ┌'+'─'*(width-2)+'┐',color))
    print(tint('  │ '+title.ljust(width-4)+' │','1;'+color))
    print(tint('  ├'+'─'*(width-2)+'┤',color)+'\n')
    print(content)
    print(tint('\n  └'+'─'*(width-2)+'┘',color))
print(tint('\n  ГОТОВО — '+settings['name'],'1;32'))
print('  Адрес: '+settings['address']+'   Порт: '+str(settings['port']))
if (base/'access.json').exists():
    access=json.loads((base/'access.json').read_text())
    panel('SSH · АДРЕС НОДЫ И КОМАНДА ВХОДА',
          'IPv6: '+settings['address']+'\n\nssh -6 -p '+str(access['ssh_port'])+' '+access['ssh_user']+'@'+settings['address']+'\n\nРазрешённые адреса клиентов:\n'+'\n'.join(access['allowed_ips']),'32')
    print('  Для SSH используйте существующий ключ или пароль пользователя сервера.')
panel('ССЫЛКА · INCY / Xray / sing-box',link,'35')
panel('КОНФИГУРАЦИЯ ТАХИОНА · JSON с привязкой интерфейса',tachyon,'34')
print('\n  Скопируйте JSON целиком, от { до }, в подключение Тахиона.')
print('  В нём уже указано bind_interface: "yggdrasil".')
print('  Если интерфейс на роутере называется иначе, замените только его имя.')
PY
}
normalize_access() {
    python3 - "$@" <<'PY'
import ipaddress,sys
result=set()
args=sys.argv[1:]; mode=args.pop(0)[2:] if args and args[0] in ('--router','--lan') else 'pair'
try:
    for value in args:
        if '%' in value: raise ValueError('Не указывайте зону интерфейса в IPv6')
        net=ipaddress.IPv6Network(value,strict=True)
        if not net.subnet_of(ipaddress.IPv6Network('200::/7')):
            raise ValueError('Нужен адрес Yggdrasil из 200::/7')
        if net.prefixlen<128 and (net.prefixlen<64 or not net.subnet_of(ipaddress.IPv6Network('300::/8'))):
            raise ValueError('Для LAN разрешены подсети 300:…/64 или более узкие; адрес 200:… укажите без /7')
        if mode=='router' and not (net.prefixlen==128 and net.subnet_of(ipaddress.IPv6Network('200::/8'))):
            raise ValueError('IPv6 роутера: нужен адрес 200:… без /7, а не LAN-подсеть')
        if mode=='lan' and not (net.prefixlen==64 and net.subnet_of(ipaddress.IPv6Network('300::/8'))):
            raise ValueError('IPv6-PD LAN: нужна подсеть 300:…/64 вместе с /64')
        result.add(str(net.network_address) if net.prefixlen==128 else str(net))
    if not result: raise ValueError('Поле обязательно: укажите значение из интерфейса Yggdrasil на роутере')
    nets=[ipaddress.IPv6Network(v) for v in result]
    if mode=='pair':
        if not any(n.prefixlen==128 and n.subnet_of(ipaddress.IPv6Network('200::/8')) for n in nets):
            raise ValueError('Не указан IPv6 самого роутера 200:…; одной подсети LAN недостаточно')
        if not any(n.prefixlen==64 and n.subnet_of(ipaddress.IPv6Network('300::/8')) for n in nets):
            raise ValueError('Не указана подсеть LAN 300:…/64; одного адреса роутера недостаточно')
except ValueError as e:
    sys.exit('Ошибка списка доступа: '+str(e))
print('\n'.join(sorted(result)))
PY
}
configure_wizard() {
    local old_name='Yggdrasil VLESS' old_port=1488 old_reality='www.microsoft.com' answer normalized value kind selected router_ip='' lan_subnet=''
    local -a extra_ips=()
    if [[ -s "$BASE/settings.json" ]] && command -v python3 >/dev/null; then
        old_name=$(python3 -c 'import json;print(json.load(open("/etc/ygg-vless/settings.json")).get("name","Yggdrasil VLESS"))')
        old_port=$(python3 -c 'import json;print(json.load(open("/etc/ygg-vless/settings.json")).get("port",1488))')
        old_reality=$(python3 -c 'import json;print(json.load(open("/etc/ygg-vless/settings.json")).get("reality_server","www.microsoft.com"))')
    fi
    # A pasted launch command can leave extra newlines in the terminal queue.
    # Drain type-ahead once, BEFORE showing any prompt; never between fields.
    if [[ $ASSUME_YES == 0 && -t 0 && -t 1 ]]; then
        while IFS= read -r -s -n 1 -t 0.05 answer; do :; done
    fi
    printf '%s' "$C_BOLD$C_CYAN" >&3
    printf '\n  ┌──────────────────────────────────────────┐\n  │       Yggdrasil + VLESS Reality           │\n  └──────────────────────────────────────────┘\n\n' >&3
    printf '%s' "$C_RESET" >&3
    printf '  Установщик %s · Debian / Ubuntu\n' "$INSTALLER_VERSION" >&3
    printf '  Настроит сеть Yggdrasil, защищённый прокси и автозапуск.\n' >&3
    if [[ -s "$BASE/settings.json" ]]; then
        printf '\n  Найдена установленная нода. Адрес и UUID будут сохранены.\n' >&3
        printf '  Старую ссылку без Reality потребуется заменить новой.\n' >&3
    fi
    if [[ $ASSUME_YES == 0 && -t 0 && -t 1 ]]; then
        if [[ -z "$NODE_NAME" ]]; then
            printf '%s' "$C_YELLOW" >&3
            printf '\n  Название подключения [%s]: ' "$old_name" >&3
            IFS= read -r answer
            printf '%s' "$C_RESET" >&3
            NODE_NAME=${answer:-$old_name}
        fi
        if [[ -z "$PORT" ]]; then
            while true; do
                printf '  Порт прокси [%s]: ' "$old_port" >&3
                IFS= read -r answer
                PORT=${answer:-$old_port}
                if [[ "$PORT" =~ ^[0-9]{1,5}$ ]] && ((10#$PORT >= 1024 && 10#$PORT <= 65535)); then break; fi
                printf '  Введите целое число от 1024 до 65535.\n' >&3
            done
        fi
    fi
    if [[ ${#ALLOW_IPS[@]} == 0 && -s "$BASE/access.json" ]]; then
        mapfile -t ALLOW_IPS < <(python3 -c 'import json,sys;print("\n".join(json.load(open(sys.argv[1]))["allowed_ips"]))' "$BASE/access.json")
    fi
    # Recover each required field independently; retain additional allowlist entries.
    for value in "${ALLOW_IPS[@]}"; do
        if [[ -z "$router_ip" && "$value" == 2* && "$value" != */* ]]; then
            router_ip=$value
        elif [[ -z "$lan_subnet" && "$value" == 3* && "$value" == */64 ]]; then
            lan_subnet=$value
        else
            extra_ips+=("$value")
        fi
    done
    if [[ $ASSUME_YES == 0 && -t 0 && -t 1 ]]; then
        printf '%s' "$C_CYAN" >&3
        printf '\n  ДОСТУП К НОДЕ · обязательны ОБА поля\n' >&3
        printf '  Откройте Сеть → Интерфейсы → Yggdrasil на роутере.\n' >&3
        printf '  IPv6 роутера 200:… разрешает Тахион; уберите /7.\n' >&3
        printf '  IPv6-PD 300:…/64 разрешает устройства LAN; сохраните /64.\n' >&3
        printf '  Адрес ПК может меняться внутри /64. SSH требует ключ/пароль.\n' >&3
        printf '  Адрес VPS сюда не вводите. Примеры ниже замените своими значениями.\n' >&3
        printf '%s' "$C_YELLOW" >&3
        for kind in router lan; do
            if [[ "$kind" == router ]]; then
                printf '\n  Пример адреса роутера: 200:1111:2222:3333:4444:5555:6666:7777\n' >&3
                selected=$router_ip
            else
                printf '\n  Пример подсети LAN: 300:1111:2222:3333::/64\n' >&3
                selected=$lan_subnet
            fi
            while true; do
                if [[ "$kind" == router ]]; then
                    printf '  IPv6 роутера (без /7) [%s]: ' "${selected:-обязательно}" >&3
                else
                    printf '  Подсеть LAN IPv6-PD (с /64) [%s]: ' "${selected:-обязательно}" >&3
                fi
                IFS= read -r answer
                value=${answer:-$selected}
                if [[ -z "$value" ]]; then
                    printf '  Это обязательное поле. Скопируйте значение с роутера.\n' >&3
                    continue
                fi
                if command -v python3 >/dev/null; then
                    if ! normalized=$(normalize_access "--$kind" "$value" 2>&1); then
                        printf '  %s\n' "$normalized" >&3; continue
                    fi
                    value=$normalized
                elif [[ ( "$kind" == router && ( "$value" != 2* || "$value" == */* ) ) || ( "$kind" == lan && ( "$value" != 3* || "$value" != */64 ) ) ]]; then
                    printf '  Неверный формат. Скопируйте значение как в примере.\n' >&3; continue
                fi
                if [[ "$kind" == router ]]; then router_ip=$value; else lan_subnet=$value; fi
                break
            done
        done
        printf '%s' "$C_RESET" >&3
    fi
    [[ -n "$router_ip" ]] || die 'Обязателен адрес роутера: --allow-ip 200:… (без /7)'
    [[ -n "$lan_subnet" ]] || die 'Обязательна LAN-подсеть: --allow-ip 300:…/64'
    ALLOW_IPS=("$router_ip" "$lan_subnet" "${extra_ips[@]}")
    printf '\n  IPv6 роутера: %s\n  Подсеть LAN:  %s\n' "$router_ip" "$lan_subnet" >&3
    if [[ -z "${SSH_PORT:-}" && -s "$BASE/access.json" ]]; then
        SSH_PORT=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("ssh_port",22))' "$BASE/access.json")
    fi
    SSH_PORT=${SSH_PORT:-22}
    NODE_NAME=${NODE_NAME:-$old_name}
    PORT=${PORT:-$old_port}
    REALITY_SERVER=${REALITY_SERVER:-$old_reality}
    [[ -n "${NODE_NAME// /}" && ${#NODE_NAME} -le 240 && "$NODE_NAME" != *$'\n'* && "$NODE_NAME" != *$'\r'* ]] || die 'Укажите короткое непустое название без переноса строки'
    [[ "$REALITY_SERVER" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] || die 'Укажите доменное имя для Reality без https:// и порта'
    printf '\n  Подключение: %s\n  Протокол:    VLESS + Reality (TCP)\n  Порт:        %s\n' "$NODE_NAME" "$PORT" >&3
}
detect_ygg_config() {
    # The packaged unit is authoritative; old releases used /etc/yggdrasil.conf.
    # Do not pick an orphan file left by a previous installer over the unit's file.
    local start
    start=$(systemctl show yggdrasil.service --property=ExecStart --value)
    python3 - "$start" <<'PY'
import re,sys
s=sys.argv[1]
m=re.search(r'-useconffile(?:=|\s+)(?:"([^"\n]+)"|([^\s;}]+))',s)
if not m:
    sys.exit('Cannot determine Yggdrasil config path from systemd ExecStart; refusing to guess')
p=m.group(1) or m.group(2)
if not p.startswith('/') or '$' in p:
    sys.exit('Unsupported Yggdrasil config path in systemd unit: '+p)
print(p)
PY
}
ssh_probe() {
    python3 - "$ADDRESS" "$SSH_PORT" <<'PY'
import socket,sys
try:
    with socket.socket(socket.AF_INET6,socket.SOCK_STREAM) as s:
        s.settimeout(2); s.connect((sys.argv[1],int(sys.argv[2])))
        assert s.recv(256).startswith(b'SSH-'), 'Not an SSH server'
except (OSError,AssertionError): sys.exit(1)
PY
}
configure_access() {
    log 'Настраиваю SSH через Yggdrasil и список разрешённых IPv6…'
    local ssh_user=${SUDO_USER:-root} client service_port
    id "$ssh_user" >/dev/null || ssh_user=root
    install -d -m 755 /run/sshd
    ssh-keygen -A
    # Reuse a native listener when possible. Otherwise bind a separate sshd only
    # to the Yggdrasil address; never broaden or restart the public SSH listener.
    if systemctl is-active --quiet ygg-vless-ssh || ! ssh_probe; then
        python3 - "$ADDRESS" "$SSH_PORT" "$TMP/sshd_config" <<'PY'
import glob,pathlib,shlex,sys
lines=[]; stack=[]; in_match=False
def expand(path):
    global in_match
    path=pathlib.Path(path).resolve()
    if path in stack: raise ValueError('Recursive sshd Include: '+str(path))
    stack.append(path)
    for raw in path.read_text().splitlines():
        parts=shlex.split(raw,comments=True)
        if not parts: continue
        key=parts[0].lower()
        if key=='include':
            for pattern in parts[1:]:
                if not pattern.startswith('/'): pattern='/etc/ssh/'+pattern
                for child in sorted(glob.glob(pattern)): expand(child)
        else:
            if key=='match': in_match=True
            if not in_match and key in {'port','listenaddress','addressfamily','pidfile'}: continue
            lines.append(raw)
    stack.pop()
expand('/etc/ssh/sshd_config')
header=f'Port {int(sys.argv[2])}\nAddressFamily inet6\nListenAddress {sys.argv[1]}\nPidFile /run/ygg-vless-sshd.pid\n'
pathlib.Path(sys.argv[3]).write_text(header+'\n'.join(lines)+'\n')
PY
        /usr/sbin/sshd -t -f "$TMP/sshd_config"
        install -m 600 "$TMP/sshd_config" "$BASE/sshd_config"
        cat >/etc/systemd/system/ygg-vless-ssh.service <<'UNIT'
[Unit]
Description=SSH on the Yggdrasil address
After=network-online.target yggdrasil.service ygg-vless-access.service
Wants=yggdrasil.service
Requires=ygg-vless-access.service
StartLimitIntervalSec=0
[Service]
ExecStartPre=/usr/sbin/sshd -t -f /etc/ygg-vless/sshd_config
ExecStart=/usr/sbin/sshd -D -e -f /etc/ygg-vless/sshd_config
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
UNIT
    fi
    python3 - "$BASE" "$ADDRESS" "$SSH_PORT" "$ssh_user" "${ALLOW_IPS[@]}" <<'PY'
import ipaddress,json,pathlib,sys
base=pathlib.Path(sys.argv[1]); address=str(ipaddress.IPv6Address(sys.argv[2]))
allowed=sorted(set(sys.argv[5:])) # Already validated and normalized before changing services.
(base/'access.json').write_text(json.dumps({'ssh_port':int(sys.argv[3]),'ssh_user':sys.argv[4],'allowed_ips':allowed},indent=2)+'\n')
# Only this node destination is filtered; the public SSH path is untouched.
rules='''table inet ygg_vless_access {
 set clients { type ipv6_addr; flags interval; auto-merge; elements = { ALLOWED } }
 chain input {
  type filter hook input priority -10; policy accept;
  ip6 daddr ADDRESS jump node
 }
 chain node {
  iifname "lo" accept
  ct state established,related accept
  icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem } accept
  ip6 saddr @clients accept
  counter drop
 }
}
'''
(base/'access.nft').write_text(rules.replace('ADDRESS',address).replace('ALLOWED',', '.join(allowed)))
PY
    cat >"$APP/apply-access.sh" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
scratch=$(mktemp)
trap 'rm -f -- "$scratch"' EXIT
if nft list table inet ygg_vless_access >/dev/null 2>&1; then
    printf 'delete table inet ygg_vless_access\n' >"$scratch"
fi
cat /etc/ygg-vless/access.nft >>"$scratch"
nft -c -f "$scratch"
nft -f "$scratch"
SH
    chmod 700 "$APP/apply-access.sh"
    cat >/etc/systemd/system/ygg-vless-access.service <<'UNIT'
[Unit]
Description=Yggdrasil node client allowlist
After=network-pre.target nftables.service ufw.service firewalld.service
Before=ygg-vless.service ygg-vless-ssh.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/ygg-vless/apply-access.sh
ExecReload=/opt/ygg-vless/apply-access.sh
ExecStop=-/usr/sbin/nft delete table inet ygg_vless_access
[Install]
WantedBy=multi-user.target
UNIT
    for client in "${ALLOW_IPS[@]}"; do
        for service_port in "$PORT" "$SSH_PORT"; do
            if [[ "$FW" == ufw ]]; then
                ufw allow in from "$client" to "$ADDRESS" port "$service_port" proto tcp comment 'ygg-vless'
            elif [[ "$FW" == firewalld ]]; then
                local zone rule
                zone=$(firewall-cmd --get-zone-of-interface="$IFACE" 2>/dev/null || true)
                [[ -n "$zone" && "$zone" != 'no zone' ]] || zone=$(firewall-cmd --get-default-zone)
                rule="rule family=ipv6 source address=$client destination address=$ADDRESS port port=$service_port protocol=tcp accept"
                firewall-cmd --permanent --zone="$zone" --add-rich-rule="$rule"
                firewall-cmd --zone="$zone" --add-rich-rule="$rule"
            fi
        done
    done
    systemctl daemon-reload
    systemctl enable ygg-vless-access
    systemctl reload-or-restart ygg-vless-access
    if [[ -f /etc/systemd/system/ygg-vless-ssh.service ]]; then
        systemctl enable ygg-vless-ssh
        systemctl restart ygg-vless-ssh
    fi
    local ready=0
    for _ in {1..10}; do if ssh_probe; then ready=1; break; fi; sleep 1; done
    [[ $ready == 1 ]] || die 'SSH на Yggdrasil-адресе не отвечает. Смотрите journalctl -u ygg-vless-ssh'
    log '✓ SSH отвечает на Yggdrasil-адресе. Доступ ограничен указанными IP.'
}
cleanup() {
    if [[ -n "$TEST_PID" ]]; then kill "$TEST_PID" 2>/dev/null || true; wait "$TEST_PID" 2>/dev/null || true; fi
    if [[ -n "$TMP" && "$TMP" == /tmp/ygg-vless.* ]]; then rm -rf -- "$TMP"; fi
}
trap cleanup EXIT
trap on_error ERR
while (($#)); do
    case "$1" in
        --show-link) MODE=link; shift ;;
        --status) MODE=status; shift ;;
        --test) MODE=test; shift ;;
        --tachyon) MODE=tachyon; shift ;;
        --result) MODE=result; shift ;;
        --name) [[ $# -ge 2 ]] || die 'Не указано название после --name'; NODE_NAME=$2; shift 2 ;;
        --reality-server) [[ $# -ge 2 ]] || die 'Не указан домен после --reality-server'; REALITY_SERVER=$2; shift 2 ;;
        --yes|-y) ASSUME_YES=1; shift ;;
        --port) [[ $# -ge 2 ]] || die 'Не указан порт после --port'; PORT=$2; shift 2 ;;
        --allow-ip) [[ $# -ge 2 ]] || die "Не указан IP после --allow-ip"; ALLOW_IPS+=("$2"); shift 2 ;;
        --ssh-port) [[ $# -ge 2 ]] || die "Не указан SSH-порт"; SSH_PORT=$2; shift 2 ;;
        --peer) [[ $# -ge 2 ]] || die 'Не указан адрес пира после --peer'; PEERS+=("$2"); shift 2 ;;
        --firewall-ready) FIREWALL_READY=1; shift ;;
        -h|--help)
            cat <<'HELP'
Yggdrasil + VLESS Reality — интерактивный установщик
sudo bash install-ygg-vless.sh
sudo bash install-ygg-vless.sh --yes --name 'Моя нода' --port 1488 --allow-ip 200:1111:2222:3333:4444:5555:6666:7777 --allow-ip 300:1111:2222:3333::/64
sudo ygg-vless --result | --show-link | --status | --test | --tachyon
--allow-ip IPv6       обязательны адрес роутера 200:… и LAN 300:…/64; повторите флаг
--ssh-port PORT       порт SSH через Yggdrasil, по умолчанию 22
--peer URI             заменить список пиров (можно несколько)
--reality-server HOST  домен TLS 1.3 для рукопожатия Reality
--firewall-ready       нестандартный firewall уже настроен вручную
Адрес Yggdrasil, UUID и ключи Reality сохраняются при обновлении.
HELP
            exit 0 ;;
        *) die "Неизвестный параметр: $1" ;;
    esac
done
[[ $EUID -eq 0 ]] || die 'Запустите от root: sudo bash install-ygg-vless.sh'
if [[ "$MODE" == link ]]; then cat "$BASE/client.txt"; exit 0; fi
if [[ "$MODE" == tachyon ]]; then cat "$BASE/client-tachyon.json"; exit 0; fi
if [[ "$MODE" == result ]]; then show_result; exit 0; fi
if [[ "$MODE" == status ]]; then
    systemctl --no-pager --full status yggdrasil "$SERVICE" || true
    ss -lntp
    journalctl -u "$SERVICE" -n 20 --no-pager
    exit 0
fi

self_test() {
    [[ -s "$BASE/settings.json" && -x "$APP/sing-box" ]] || die 'Нода ещё не установлена'
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
out={'type':'vless','tag':'test-out','server':s['address'],'server_port':s['port'],'uuid':s['uuid'],
     'flow':'xtls-rprx-vision','tls':{'enabled':True,'server_name':s['reality_server'],
       'utls':{'enabled':True,'fingerprint':'chrome'},'reality':{'enabled':True,
       'public_key':s['reality_public_key'],'short_id':s['reality_short_id']}}}
c={"log":{"level":"warn"},
   "inbounds":[{"type":"socks","tag":"test-in","listen":"127.0.0.1","listen_port":int(sys.argv[3])}],
   "outbounds":[out],"route":{"final":"test-out"}}
with open(sys.argv[2],'w') as f: json.dump(c,f,indent=2)
PY
    "$APP/sing-box" check -c "$TMP/test.json"
    "$APP/sing-box" run -c "$TMP/test.json" >"$TMP/test.log" 2>&1 &
    TEST_PID=$!
    local ready=0
    for _ in {1..20}; do
        kill -0 "$TEST_PID" 2>/dev/null || { cat "$TMP/test.log"; die 'Проверочный клиент не запустился'; }
        if python3 - "$test_port" <<'PY'
import socket,sys
try:
    with socket.create_connection(('127.0.0.1',int(sys.argv[1])),timeout=.3): pass
except OSError: sys.exit(1)
PY
        then ready=1; break; fi
        sleep .2
    done
    [[ $ready == 1 ]] || die 'Проверочный клиент не стал готов к работе'
    log 'Проверяю авторизацию, шифрование Reality, DNS и HTTPS…'
    if ! result=$(curl --silent --show-error --noproxy '' \
        --proxy "socks5h://127.0.0.1:$test_port" --connect-timeout 15 --max-time 35 \
        --output /dev/null --write-out '%{http_code}' https://www.gstatic.com/generate_204); then
        cat "$TMP/test.log"
        journalctl -u "$SERVICE" -n 25 --no-pager
        die 'Проверка HTTPS через прокси не прошла. После исправления повторите: sudo ygg-vless --test'
    fi
    [[ "$result" == 204 ]] || die "Проверочный сайт вернул HTTP $result вместо 204"
    kill "$TEST_PID" 2>/dev/null || true
    wait "$TEST_PID" 2>/dev/null || true
    TEST_PID=''
    log '✓ Проверка пройдена: Reality, авторизация, DNS, HTTPS — HTTP 204.'
    printf '%s\n' 'Локальный тест не заменяет проверку с удалённого клиента.'
}
if [[ "$MODE" == test ]]; then self_test; exit 0; fi

perform_install() {
[[ -r /etc/os-release ]] || die 'Не удалось определить операционную систему'
. /etc/os-release
case "${ID:-}:" in
    debian:) [[ ${VERSION_ID%%.*} -ge 12 ]] || die 'Требуется Debian 12 или новее' ;;
    ubuntu:) [[ ${VERSION_ID%%.*} -ge 22 ]] || die 'Требуется Ubuntu 22.04 или новее' ;;
    *) die 'Этот установщик предназначен для VPS с Debian 12+ / Ubuntu 22.04+, не для OpenWrt' ;;
esac
[[ -d /run/systemd/system ]] || die 'Требуется работающий systemd; используйте обычный VPS, не Docker-контейнер'
command -v dpkg >/dev/null || die 'Не найден пакетный менеджер dpkg'
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
    amd64)
        YGG_SHA=72745496b09baa1c3f5a6741e1257a704cfdb9d00cdf3ddbef025987b239699d
        SB_SHA=e2bdf179c15a3652955dc44867e33ca0965c9c9b91b34267dcc5a5d639a5feee ;;
    arm64)
        YGG_SHA=ac8c9a9a76c54b878fd251aef5a2bbd20375c6109b28b32435683441462360c9
        SB_SHA=29dae24d76bea3bc62d07dd3e60cfc12003de7debbd6b768df9be9c68360174e ;;
    *) die 'Поддерживаются только amd64 и arm64' ;;
esac
[[ -z "$PORT" || ( "$PORT" =~ ^[0-9]{1,5}$ && $((10#$PORT)) -ge 1024 && $((10#$PORT)) -le 65535 ) ]] || die 'Порт должен быть числом от 1024 до 65535'
if [[ ${#PEERS[@]} -gt 0 ]]; then
    for peer in "${PEERS[@]}"; do [[ "$peer" == tls://* || "$peer" == tcp://* || "$peer" == quic://* ]] || die "Некорректный адрес пира: $peer"; done
fi
[[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) == 0 ]] || die 'IPv6 отключён внутри ОС. Включите его; публичный IPv6 от провайдера не нужен.'
FW=none
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    FW=ufw
    grep -Eq '^IPV6=yes' /etc/default/ufw || die 'В активном UFW отключена поддержка IPv6. Сначала включите IPV6=yes в /etc/default/ufw.'
elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    FW=firewalld
elif [[ $FIREWALL_READY == 0 && ! -s "$BASE/access.json" ]]; then
    if command -v nft >/dev/null && nft list ruleset 2>/dev/null | grep 'hook input' >/dev/null; then
        die 'Обнаружен нестандартный nftables firewall. Разрешите входящий TCP-порт прокси на интерфейсе Yggdrasil и повторите с --firewall-ready. Правила не изменены.'
    fi
    if command -v ip6tables-save >/dev/null && ip6tables-save 2>/dev/null | grep -E '^:INPUT DROP|^-A INPUT' >/dev/null; then
        die 'Обнаружен нестандартный IPv6 iptables firewall. Разрешите вход к прокси через Yggdrasil и повторите с --firewall-ready.'
    fi
fi
log '[1/6] Установка необходимых пакетов. Подробности записываются в журнал…'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl jq python3 iproute2 iputils-ping tar coreutils kmod util-linux passwd openssl openssh-server nftables
[[ "$SSH_PORT" =~ ^[0-9]{1,5}$ && $((10#$SSH_PORT)) -ge 1 && $((10#$SSH_PORT)) -le 65535 ]] || die 'SSH-порт должен быть числом от 1 до 65535'
normalized=$(normalize_access "${ALLOW_IPS[@]}") || die 'Исправьте IP или подсеть в списке доступа'
mapfile -t ALLOW_IPS <<<"$normalized"
[[ "$SSH_PORT" != "$PORT" ]] || die 'Порты SSH и прокси должны различаться'
modprobe tun 2>/dev/null || true
[[ -c /dev/net/tun ]] || die 'Недоступен /dev/net/tun. Включите TUN в панели VPS или контейнера.'
install -d -m 700 "$BASE" "$BASE/backups"
install -d -m 755 "$APP"
TMP=$(mktemp -d /tmp/ygg-vless.XXXXXXXX)
STAMP=$(date -u +%Y%m%dT%H%M%S)-$$
exec 9>"$BASE/install.lock"
flock -n 9 || die 'Другой экземпляр установщика уже работает'
download_checked() {
    local url=$1 path=$2 digest=$3
    curl --fail --show-error --location --retry 3 --connect-timeout 20 --max-time 300 \
        --proto '=https' --proto-redir '=https' "$url" -o "$path"
    printf '%s  %s\n' "$digest" "$path" | sha256sum --check --status || die "Контрольная сумма файла не совпала: $url"
}
if ! command -v yggdrasil >/dev/null; then
    log "[2/6] Установка Yggdrasil $YGG_VERSION с проверкой контрольной суммы…"
    download_checked "https://github.com/yggdrasil-network/yggdrasil-go/releases/download/v$YGG_VERSION/yggdrasil-$YGG_VERSION-$ARCH.deb" "$TMP/yggdrasil.deb" "$YGG_SHA"
    chmod 755 "$TMP"
    chmod 644 "$TMP/yggdrasil.deb"
    apt-get install -y "$TMP/yggdrasil.deb"
else
    log '[2/6] Yggdrasil уже установлен. Сохраняю ключ и адрес ноды…'
    yggdrasil -version
    yggdrasil -version | grep -Eq 'Build version: 0\.5\.' || die 'Для этой установки требуется Yggdrasil 0.5.x. Обновите его с сохранением конфигурации и повторите.'
fi
command -v yggdrasilctl >/dev/null || die 'Не найден yggdrasilctl. Установите официальный пакет Yggdrasil.'
YGG_BIN=$(command -v yggdrasil)
YGG_CONFIG=$(detect_ygg_config)
printf "Yggdrasil configuration: %s\n" "$YGG_CONFIG"
if [[ ! -s "$YGG_CONFIG" ]]; then
    "$YGG_BIN" -genconf -json >"$TMP/ygg-original.json"
else
    cp -p "$YGG_CONFIG" "$BASE/backups/yggdrasil.conf.$STAMP"
    "$YGG_BIN" -useconffile "$YGG_CONFIG" -normaliseconf -json >"$TMP/ygg-original.json"
    # Yggdrasil 0.5.14 deliberately clears AdminListen in -normaliseconf output.
    # Restore an explicitly configured socket from the original HJSON/JSON file.
    python3 - "$YGG_CONFIG" "$TMP/ygg-original.json" <<'PY'
import json,re,sys
with open(sys.argv[1]) as f: raw=f.read()
try:
    original=json.loads(raw)
except json.JSONDecodeError:
    # Read only this scalar; the Yggdrasil binary parses the rest of HJSON.
    original={}
    m=re.search(r'(?m)^[ \t]*(?:AdminListen|"AdminListen")[ \t]*:[ \t]*("(?:[^"\\]|\\.)*"|[^\r\n]*)',raw)
    if m:
        value=m.group(1).strip()
        original['AdminListen']=json.loads(value) if value.startswith('"') else re.split(r'\s+(?://|#)',value,maxsplit=1)[0].rstrip(',').strip()
with open(sys.argv[2]) as f: normalized=json.load(f)
if 'AdminListen' in original: normalized['AdminListen']=original['AdminListen']
with open(sys.argv[2],'w') as f: json.dump(normalized,f,indent=2)
PY
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
    c['AdminListen']='unix:///var/run/yggdrasil/yggdrasil.sock'
if not c.get('IfName') or c['IfName']=='none': c['IfName']='ygg0'
with open(sys.argv[2],'w') as f: json.dump(c,f,indent=2)
PY
"$YGG_BIN" -useconffile "$TMP/yggdrasil.json" -normaliseconf -json >/dev/null
if getent group yggdrasil >/dev/null; then
    install -o root -g yggdrasil -m 640 "$TMP/yggdrasil.json" "$YGG_CONFIG"
else
    install -o root -g root -m 600 "$TMP/yggdrasil.json" "$YGG_CONFIG"
fi
ADDRESS=$("$YGG_BIN" -useconffile "$YGG_CONFIG" -address)
python3 - "$ADDRESS" <<'PY'
import ipaddress,sys
a=ipaddress.IPv6Address(sys.argv[1])
assert a in ipaddress.IPv6Network('200::/7'), 'Unexpected Yggdrasil address'
PY
ADMIN=$(jq -r '.AdminListen' "$TMP/yggdrasil.json")
systemctl enable yggdrasil
systemctl restart yggdrasil
log '[3/6] Подключение к сети Yggdrasil. Ожидаю живого пира, до 90 секунд…'
READY=0
READY_DEADLINE=$((SECONDS + 90))
while (( SECONDS < READY_DEADLINE )); do
    if systemctl is-failed --quiet yggdrasil; then
        journalctl -u yggdrasil -n 30 --no-pager
        die 'Служба Yggdrasil завершилась с ошибкой. Причина записана в журнал установки.'
    fi
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
    die 'Нет подключённых пиров Yggdrasil. Проверьте исходящие подключения VPS или укажите свои пиры через --peer.'
fi
IFACE=$(ip -j -6 address show | jq -r --arg a "$ADDRESS" '.[] | select(any(.addr_info[]?; .local == $a)) | .ifname' | head -n1)
log "✓ Сеть Yggdrasil подключена: $ADDRESS"
log '[4/6] Установка прокси и настройка VLESS + Reality…'
if [[ ! -x "$APP/sing-box" ]] || ! "$APP/sing-box" version | head -n1 | grep -Fq "version $SB_VERSION"; then
    download_checked "https://github.com/SagerNet/sing-box/releases/download/v$SB_VERSION/sing-box-$SB_VERSION-linux-$ARCH.tar.gz" "$TMP/sing-box.tar.gz" "$SB_SHA"
    tar -xzf "$TMP/sing-box.tar.gz" -C "$TMP" "sing-box-$SB_VERSION-linux-$ARCH/sing-box"
    install -m 755 "$TMP/sing-box-$SB_VERSION-linux-$ARCH/sing-box" "$APP/sing-box.new"
    "$APP/sing-box.new" version
    mv -f "$APP/sing-box.new" "$APP/sing-box"
fi
[[ ! -f "$BASE/settings.json" ]] || cp -p "$BASE/settings.json" "$BASE/backups/settings.$STAMP.json"
[[ ! -f "$BASE/server.json" ]] || cp -p "$BASE/server.json" "$BASE/backups/server.$STAMP.json"
log 'Проверяю доступность сервера рукопожатия Reality…'
timeout 20 openssl s_client -connect "$REALITY_SERVER:443" -servername "$REALITY_SERVER" \
    -tls1_3 -verify_return_error -verify_hostname "$REALITY_SERVER" </dev/null >"$TMP/reality-handshake.log" 2>&1 || {
    cat "$TMP/reality-handshake.log"
    die "Сервер Reality $REALITY_SERVER недоступен по TLS 1.3. Укажите другой через --reality-server ДОМЕН"
}
python3 - "$BASE" "$TMP" "$ADDRESS" "$PORT" "$NODE_NAME" "$REALITY_SERVER" <<'PY'
import json,sys,uuid,pathlib,subprocess,re,secrets,os
from urllib.parse import urlencode,quote
base,tmp=map(pathlib.Path,sys.argv[1:3]); addr=sys.argv[3]; port=sys.argv[4]
p=base/'settings.json'; old=json.loads(p.read_text()) if p.exists() else {}
name=sys.argv[5] if len(sys.argv)>5 else old.get('name','Yggdrasil VLESS')
reality_server=sys.argv[6] if len(sys.argv)>6 else old.get('reality_server','www.microsoft.com')
private_key=old.get('reality_private_key'); public_key=old.get('reality_public_key')
if not private_key or not public_key:
    binary=os.environ.get('SING_BOX_BINARY','/opt/ygg-vless/sing-box')
    keys=subprocess.check_output([binary,'generate','reality-keypair'],text=True)
    private_key=re.search(r'(?m)^PrivateKey:\s*(\S+)',keys).group(1)
    public_key=re.search(r'(?m)^PublicKey:\s*(\S+)',keys).group(1)
s={'schema_version':2,'name':name,'address':addr,'port':int(port or old.get('port',1488)),
   'uuid':str(uuid.UUID(old['uuid'])) if old.get('uuid') else str(uuid.uuid4()),
   'reality_private_key':private_key,'reality_public_key':public_key,
   'reality_short_id':old.get('reality_short_id') or secrets.token_hex(8),'reality_server':reality_server}
assert 1024<=s['port']<=65535
server_tls={'enabled':True,'server_name':reality_server,
            'reality':{'enabled':True,'handshake':{'server':reality_server,'server_port':443},
                       'private_key':private_key,'short_id':[s['reality_short_id']]}}
client_tls={'enabled':True,'server_name':reality_server,'utls':{'enabled':True,'fingerprint':'chrome'},
            'reality':{'enabled':True,'public_key':public_key,'short_id':s['reality_short_id']}}
c={'log':{'level':'info','timestamp':True},
   'dns':{'servers':[{'type':'local','tag':'system-dns'}]},
   'inbounds':[{'type':'vless','tag':'ygg-vless-in','listen':addr,'listen_port':s['port'],
                'users':[{'name':name,'uuid':s['uuid'],'flow':'xtls-rprx-vision'}],'tls':server_tls}],
   'outbounds':[{'type':'direct','tag':'internet'}],
   'route':{'default_domain_resolver':{'server':'system-dns','strategy':'ipv4_only'},
            'rules':[{'action':'resolve','strategy':'ipv4_only'}], 'final':'internet'}}
for filename,data in [('settings.json',s),('server.json',c)]:
    (tmp/filename).write_text(json.dumps(data,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
query=urlencode({'encryption':'none','security':'reality','type':'tcp','flow':'xtls-rprx-vision',
                 'sni':reality_server,'fp':'chrome','pbk':public_key,'sid':s['reality_short_id']})
(tmp/'client.txt').write_text(f"vless://{s['uuid']}@[{addr}]:{s['port']}?{query}#{quote(name,safe='')}\n",encoding='utf-8')
out={'type':'vless','tag':name,'server':addr,'server_port':s['port'],'uuid':s['uuid'],
     'flow':'xtls-rprx-vision','tls':client_tls}
(tmp/'client-outbound.json').write_text(json.dumps(out,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
# On the router, replace the default WAN binding with its Yggdrasil interface.
(tmp/'client-tachyon.json').write_text(json.dumps({**out,'bind_interface':'yggdrasil'},indent=2,ensure_ascii=False)+'\n',encoding='utf-8')

PY
"$APP/sing-box" check -c "$TMP/server.json"
PORT=$(jq -r .port "$TMP/settings.json")
if ! id -u ygg-vless >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin ygg-vless
fi
for name in settings.json client.txt client-outbound.json client-tachyon.json; do install -m 600 "$TMP/$name" "$BASE/$name"; done
chown root:ygg-vless "$BASE"
chmod 750 "$BASE"
install -o root -g ygg-vless -m 640 "$TMP/server.json" "$BASE/server.json"
configure_access
cat >/etc/systemd/system/ygg-vless.service <<'UNIT'
[Unit]
Description=VLESS proxy over Yggdrasil
Wants=network-online.target yggdrasil.service
After=network-online.target yggdrasil.service ygg-vless-access.service
Requires=ygg-vless-access.service
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
log '[5/6] Запуск служб и настройка автозагрузки…'
systemctl daemon-reload
systemctl enable "$SERVICE"
systemctl restart "$SERVICE"
ACTIVE=0
for _ in {1..15}; do
    if systemctl is-active --quiet "$SERVICE" && ss -H -lnt "sport = :$PORT" | grep -Fq "$ADDRESS"; then ACTIVE=1; break; fi
    sleep 1
done
if [[ $ACTIVE != 1 ]]; then journalctl -u "$SERVICE" -n 30 --no-pager; die 'Служба VLESS не смогла открыть порт. Подробности в журнале установки.'; fi
if [[ -f "$0" ]]; then
    if [[ $(readlink -f "$0") != "$APP/manage.sh" ]]; then install -m 700 "$0" "$APP/manage.sh"; fi
    ln -sfn "$APP/manage.sh" /usr/local/sbin/ygg-vless
fi
log '[6/6] Проверка подключения через VLESS + Reality…'
self_test
}
configure_wizard
install -d -m 700 /var/log/ygg-vless
INSTALL_LOG="/var/log/ygg-vless/install-$(date -u +%Y%m%dT%H%M%S)-$$.log"
: >"$INSTALL_LOG"
printf '\n  Журнал установки: %s\n' "$INSTALL_LOG" >&3
perform_install >>"$INSTALL_LOG" 2>&1
show_result >&3
printf '\n  Показать оба блока: sudo ygg-vless --result\n  Проверить ноду:    sudo ygg-vless --test\n  Статус:            sudo ygg-vless --status\n  Журнал:            %s\n\n' "$INSTALL_LOG" >&3
printf '  На клиентском устройстве должен работать маршрут через Yggdrasil.\n  После обновления замените старую ссылку новой.\n' >&3
