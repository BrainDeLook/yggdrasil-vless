# Yggdrasil + VLESS Reality

[![Проверки](https://github.com/BrainDeLook/yggdrasil-vless/actions/workflows/check.yml/badge.svg)](https://github.com/BrainDeLook/yggdrasil-vless/actions/workflows/check.yml)

Интерактивный установщик прокси для **Debian 12+ / Ubuntu 22.04+**, **amd64 / arm64**. Устанавливает Yggdrasil, VLESS + Reality + Vision, автозапуск и выдаёт ссылку с выбранным вами названием.

Нужен VPS с systemd, доступным `/dev/net/tun` и выходом в интернет. Публичный IPv6, собственный домен и сертификат не нужны. IPv6 внутри ОС должен быть включён.

## Установка или обновление

Выполните на VPS по SSH от root:

```bash
curl -fsSL https://raw.githubusercontent.com/BrainDeLook/yggdrasil-vless/main/install.sh -o /tmp/ygg-vless-install.sh && bash /tmp/ygg-vless-install.sh
```

Если `curl` отсутствует: `apt-get update && apt-get install -y curl ca-certificates`.

Загрузчик скачивает релиз **v1.1.1**, проверяет SHA256 и запускает мастер. Он спросит:

```text
Название подключения [Yggdrasil VLESS]: Моя нода NL
Порт прокси [1488]:

[1/6] Установка необходимых пакетов…
[2/6] Установка Yggdrasil…
[3/6] Подключение к сети Yggdrasil…
[4/6] Установка прокси и настройка VLESS + Reality…
[5/6] Запуск служб и настройка автозагрузки…
[6/6] Проверка подключения через VLESS + Reality…

ГОТОВО — Моя нода NL

[ ССЫЛКА · INCY / Xray / sing-box ]
vless://…

[ КОНФИГУРАЦИЯ ТАХИОНА · JSON с привязкой интерфейса ]
{ …, "bind_interface": "yggdrasil" }
```

Enter оставляет значение по умолчанию. Кириллица, пробелы и специальные символы в названии корректно кодируются в ссылке. Детальный вывод APT и служб сохраняется в закрытый журнал `/var/log/ygg-vless/install-*.log`, а на экране остаются этапы и результат. При ошибке мастер показывает причину или путь к журналу.

**Обновление с v1.0.x:** прежняя ссылка без TLS заменяется на Reality. Адрес Yggdrasil, UUID и порт сохраняются. После обновления импортируйте новую ссылку в клиенты. При дальнейших запусках сохраняются также ключи Reality; можно изменить название и порт.

Без вопросов, например для автоматической установки:

```bash
sudo bash /tmp/ygg-vless-install.sh --yes --name 'Моя нода NL' --port 1488
```

## Клиенты

Ссылка использует **VLESS TCP + Reality + xtls-rprx-vision**. Она предназначена для клиентов с поддержкой этих протоколов, в том числе INCY с ядром Xray. Новые Xray запрещают голый VLESS для Yggdrasil IPv6; Reality устраняет именно это ограничение.

Проверяется настоящий обмен данными через sing-box и официальный Xray, настроенный по параметрам сгенерированной ссылки. Сам интерфейс INCY автоматически не тестируется. Совместимость с каждым существующим клиентом не гарантируется: старые версии и клиенты без Reality/VLESS Vision не поддерживаются. Telegram непосредственно VLESS не принимает — нужен Тахион или отдельный прокси-клиент.

Для рукопожатия Reality VPS должен достигать `www.microsoft.com:443` по TLS 1.3. Установщик проверяет это заранее. При необходимости можно выбрать другой совместимый сервер:

```bash
sudo ygg-vless --reality-server ДОМЕН
```

На устройстве с клиентом должен работать маршрут до IPv6-адреса ноды через Yggdrasil:

- Yggdrasil работает на самом устройстве; либо
- роутер раздаёт клиентам IPv6 из выделенной подсети Yggdrasil и маршрут к `200::/7`, с рабочим forwarding и обратным трафиком.

Одной установки Yggdrasil на произвольном устройстве LAN недостаточно. Если клиент работает в TUN/VPN-режиме, соединение к VLESS-серверу и соединения Yggdrasil к его пирам не должны попадать обратно в этот же прокси-туннель.

## Особенность Тахиона

При `route.auto_detect_interface=true` ядро может привязать прокси к WAN, хотя адрес сервера достижим через Yggdrasil. Настройка общего выходного интерфейса на Yggdrasil повлияет и на остальные прокси.

Поэтому установщик сохраняет отдельный JSON для этой ноды с `bind_interface: "yggdrasil"` и **автоматически показывает его целиком в рамке после ссылки**. В нём уже есть адрес, порт, UUID и параметры Reality. Содержимое выводится без префиксов и принудительных переносов, чтобы его можно было копировать. Повторно показать оба блока: `sudo ygg-vless --result`.

Получить только JSON на VPS:

```bash
sudo ygg-vless --tachyon
```

Файл: `/etc/ygg-vless/client-tachyon.json`. Вставьте его в JSON-подключения нужной секции Тахиона и выберите эту ноду. Если интерфейс Yggdrasil на роутере называется иначе, укажите его фактическое имя в `bind_interface`. Его показывает `ip -6 route get IPv6_СЕРВЕРА`.

Привязку интерфейса нельзя надёжно передать стандартной VLESS-ссылкой: это локальная настройка роутера. Обычный JSON без привязки — `/etc/ygg-vless/client-outbound.json`.

## Управление

```bash
sudo ygg-vless --result      # показать ссылку и JSON в рамке
sudo ygg-vless --show-link   # показать только ссылку
sudo ygg-vless --tachyon     # JSON для Тахиона
sudo ygg-vless --status      # состояние служб
sudo ygg-vless --test        # проверка Reality, авторизации, DNS и HTTPS
sudo journalctl -u ygg-vless -f
```

Ссылка: `/etc/ygg-vless/client.txt`. Параметры ноды: `/etc/ygg-vless/settings.json`. Сервер: `/etc/ygg-vless/server.json`. Эти файлы содержат секреты доступа — не публикуйте их.

Путь действующего конфига Yggdrasil берётся из systemd; в официальном пакете это `/etc/yggdrasil/yggdrasil.conf`. Ключ, существующие пиры и настройки сохраняются; старый неиспользуемый `/etc/yggdrasil.conf` не изменяется. Резервные копии — `/etc/ygg-vless/backups/`. При обновлении Yggdrasil кратковременно перезапускается.

Свой список пиров (заменяет текущий `Peers`, сохраняя ключ):

```bash
sudo ygg-vless --peer 'tls://ПИР_1:ПОРТ' --peer 'tls://ПИР_2:ПОРТ'
```

Установщик использует проверенные SHA256 официальных Yggdrasil **0.5.14** и sing-box **1.14.3**. Уже установленный Yggdrasil **0.5.x** сохраняется. Отдельный sing-box устанавливается в `/opt/ygg-vless/`, не меняя другие службы sing-box на VPS. VLESS слушает только адрес Yggdrasil; выход в интернет и разрешение сайтов настроены на IPv4 VPS.

## Firewall и проверки

Активные UFW/firewalld получают узкое разрешение входящего TCP к адресу и порту этой ноды. Firewall не включается и не сбрасывается. Для UFW требуется `IPV6=yes`.

При нестандартном nftables/ip6tables установщик останавливается: настройте разрешение TCP с интерфейса Yggdrasil к порту ноды и повторите с `--firewall-ready`. Флаг ничего не открывает автоматически. При ограничениях OUTPUT нужны выход к пирам, DNS, Reality-серверу и сайтам назначения. Публичный VLESS-порт в панели VPS открывать не требуется.

Пиры по умолчанию взяты из официального каталога. Установка ждёт хотя бы одного живого пира. Локальный HTTPS-тест через Reality не доказывает доступность с удалённого клиента — после импорта ссылки проверьте соединение с вашего устройства.

Проверки: синтаксис Bash, интерактивный ввод через PTY, кодирование названия, сохранение ключей/UUID, sing-box и Xray, обмен VLESS Reality по IPv6 и отказ при неверном UUID. Полный тест установки Ubuntu использует настоящий пакет, systemd, TUN и локальный Yggdrasil-пир. UFW/firewalld и связь удалённых узлов проверяются отдельно на целевой сети.

## Источники

- [Yggdrasil](https://github.com/yggdrasil-network/yggdrasil-go)
- [Каталог пиров](https://github.com/yggdrasil-network/public-peers)
- [VLESS sing-box](https://sing-box.sagernet.org/configuration/inbound/vless/)
- [Reality sing-box](https://sing-box.sagernet.org/configuration/shared/tls/#reality-fields)
- [Xray](https://github.com/XTLS/Xray-core)
