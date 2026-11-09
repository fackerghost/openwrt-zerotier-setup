# ZeroTier на OpenWrt

Скрипт `zerotier-setup.sh` устанавливает и настраивает
[ZeroTier](https://www.zerotier.com/) на OpenWrt одной командой: ставит пакет,
прописывает сеть в UCI, включает автозапуск, создаёт зону firewall и выполняет
join.

Сеть по умолчанию: **`8d1c312afa6d0fe8`**. Другую сеть можно указать
параметром `--network`.

## Быстрый старт

```sh
uclient-fetch -O /tmp/zerotier-setup.sh \
  https://raw.githubusercontent.com/fackerghost/openwrt-zerotier-setup/main/zerotier-setup.sh

sh /tmp/zerotier-setup.sh
```

С доступом из ZeroTier в локальную сеть:

```sh
sh /tmp/zerotier-setup.sh --lan
```

После запуска скрипт покажет **ID узла**. Его нужно авторизовать в
[ZeroTier Central](https://my.zerotier.com/network/8d1c312afa6d0fe8), иначе
узел не получит IP-адрес.

## Что делает скрипт

- устанавливает пакет `zerotier` через `opkg` или `apk`;
- поддерживает оба формата конфига: OpenWrt 23.05+ (`config network`) и
  22.03 и старше (`list join`);
- прописывает сеть, включает службу и генерирует/сохраняет identity узла;
- создаёт зону `fw4` для интерфейсов `zt+` (input/output/forward, masq, MTU fix);
- ждёт запуск демона, выполняет join и показывает ID узла;
- опционально разрешает трафик между ZeroTier и LAN;
- проверяет целостность зависимостей и пытается починить частичную установку
  через `apk fix`;
- можно запускать повторно — существующие секции и правила переиспользуются.

## Требования

- OpenWrt 22.03 или новее (на 21.02 шаг с firewall пропускается);
- root-доступ;
- интернет на роутере (для `opkg`/`apk` и связи с контроллером ZeroTier);
- немного свободного места во flash.

## Сколько места занимает

Пакеты для `aarch64_cortex-a53` (OpenWrt 25.12):

| Пакет | Сжатый размер |
| --- | ---: |
| `zerotier` | 463 КБ |
| `libstdcpp6` | 628 КБ |
| `libminiupnpc` | 22 КБ |
| `libnatpmp1` | 4 КБ |
| `libatomic1` | 8 КБ |
| `kmod-tun` | 25 КБ |
| **Итого** | **≈ 1,1 МБ** |

После распаковки — ориентировочно 3–4 МБ. Точные цифры на роутере:

```sh
apk info -s zerotier libstdcpp6 libminiupnpc libnatpmp1
```

Это минимум для официального пакета: ZeroTier написан на C++, поэтому
`libstdcpp6` обязателен, а `libminiupnpc` и `libnatpmp1` — жёсткие зависимости
пакета (автоматический проброс портов). Убрать их без пересборки нельзя.

Если собираете свою прошивку, добавьте только сам пакет:

```
CONFIG_PACKAGE_zerotier=y
# CONFIG_ZEROTIER_ENABLE_SELFTEST is not set
CONFIG_TARGET_OPTIMIZATION="-Os"
CONFIG_USE_STRIP=y
CONFIG_STRIP_KERNEL_EXPORTS=y
```

`luci-app-zerotier` не нужен — скрипт настраивает всё через UCI. Официальный
пакет уже собирается с `ZT_EMBEDDED=1` и `gc-sections`, поэтому заметно
уменьшить его без потери функциональности не получится.

Если важна именно минимальность, а не ZeroTier: встроенный WireGuard
занимает десятки килобайт, но это другой тип VPN.

## Скачивание

Сначала проверьте, что роутер видит интернет и DNS:

```sh
ping -c 1 1.1.1.1
ping -c 1 raw.githubusercontent.com
```

Если второй `ping` пишет `bad address` — сначала исправьте DNS (раздел
[«Диагностика»](#диагностика)).

### Вариант 1. uclient-fetch (рекомендуется)

```sh
uclient-fetch -O /tmp/zerotier-setup.sh \
  https://raw.githubusercontent.com/fackerghost/openwrt-zerotier-setup/main/zerotier-setup.sh
```

`uclient-fetch` есть в большинстве сборок OpenWrt и обычно работает там, где
`wget` падает с `Failed to send request: Operation not permitted`.

### Вариант 2. wget

Если `wget` не умеет HTTPS, поставьте TLS-пакеты:

```sh
opkg update
opkg install ca-bundle libustream-mbedtls
```

Для сборок с OpenSSL вместо mbedTLS:

```sh
opkg install ca-bundle libustream-openssl
```

Затем:

```sh
wget -O /tmp/zerotier-setup.sh \
  https://raw.githubusercontent.com/fackerghost/openwrt-zerotier-setup/main/zerotier-setup.sh
```

### Вариант 3. Зеркало jsDelivr

Если GitHub или `raw.githubusercontent.com` недоступен:

```sh
uclient-fetch -O /tmp/zerotier-setup.sh \
  https://cdn.jsdelivr.net/gh/fackerghost/openwrt-zerotier-setup@main/zerotier-setup.sh
```

Резервное зеркало:

```sh
uclient-fetch -O /tmp/zerotier-setup.sh \
  https://raw.githack.com/fackerghost/openwrt-zerotier-setup/main/zerotier-setup.sh
```

### Вариант 4. С компьютера

Скачайте файл и передайте на роутер:

```sh
scp zerotier-setup.sh root@192.168.1.1:/tmp/
```

Подойдёт WinSCP или любой SFTP-клиент. Адрес роутера замените на свой.

### Проверить файл

```sh
head -n 1 /tmp/zerotier-setup.sh
wc -c /tmp/zerotier-setup.sh
```

Первая строка должна быть `#!/bin/sh`, размер — около 14 КБ. Если вместо
скрипта скачалась HTML-страница, зеркало вернуло ошибку — попробуйте другой
вариант.

## Запуск

```sh
sh /tmp/zerotier-setup.sh
```

С доступом в локальную сеть:

```sh
sh /tmp/zerotier-setup.sh --lan
```

Другая сеть:

```sh
sh /tmp/zerotier-setup.sh --network 0123456789abcdef
```

### Параметры

| Параметр | Описание |
| --- | --- |
| `-n, --network ID` | ID сети ZeroTier (по умолчанию `8d1c312afa6d0fe8`) |
| `--lan` | Разрешить forwarding между ZeroTier и зоной `lan` |
| `--no-firewall` | Не изменять `/etc/config/firewall` |
| `--no-install` | Только настроить, пакет не устанавливать |
| `-h, --help` | Показать справку |

ID сети можно передать и через переменную `ZEROTIER_NETWORK_ID`.

## Авторизация узла

Скрипт выведет **ID узла**. Без авторизации узел не получит IP, даже если
join выполнен.

1. Откройте <https://my.zerotier.com/network/8d1c312afa6d0fe8>.
2. Найдите ID узла в разделе **Members**.
3. Поставьте галочку **Authorized**.

Если сеть другая — замените ID в ссылке.

## Проверка

```sh
zerotier-cli info
zerotier-cli listnetworks
```

Ожидаемый результат:

- `zerotier-cli info` — `200 info <ID узла> <версия> ONLINE`;
- `zerotier-cli listnetworks` — строка с вашей сетью и статусом `OK`;
- у интерфейса `zt...` появился адрес из сети ZeroTier.

Посмотреть адрес интерфейса:

```sh
ip addr show | grep -A2 'zt'
```

Если статус `REQUESTING_CONFIGURATION` — узел ещё не авторизован или роутер
не может достучаться до контроллера. Если `ACCESS_DENIED` — не отмечен
**Authorized** в ZeroTier Central.

## Постоянное соединение

Да, служба работает постоянно:

- `zerotier-one` запускается при загрузке и перезапускается procd при падении;
- это не одно TCP-соединение, а виртуальный интерфейс `zt...` и UDP-туннель
  к пирам; в простое идут keepalive-пакеты;
- при смене WAN-IP или NAT-маппинга связь переустанавливается автоматически;
- после перезагрузки роутера узел сам переподключается: identity хранится в
  `/etc/config/zerotier`, join прописан в UCI;
- порт `9993/UDP` наружу открывать не нужно — используется NAT traversal,
  при неудаче трафик идёт через relay.

Проверка состояния:

```sh
zerotier-cli info
zerotier-cli listnetworks
zerotier-cli peers
```

В `peers` видно, идёт ли трафик напрямую (`direct`) или через relay.

## Firewall и доступ в LAN

На системах с `fw4` скрипт создаёт зону:

```
config zone
	option name 'zerotier'
	option input 'ACCEPT'
	option output 'ACCEPT'
	option forward 'ACCEPT'
	option masq '1'
	option mtu_fix '1'
	list device 'zt+'
```

По умолчанию клиенты ZeroTier могут обращаться к самому роутеру (SSH, LuCI,
DNS), но не в LAN за ним. Флаг `--lan` добавляет forwarding в обе стороны:

- `zerotier -> lan`;
- `lan -> zerotier`.

Изменения firewall можно не делать вовсе: `--no-firewall`.

## Повторный запуск и обновление

Скрипт идемпотентен: повторный запуск не создаёт дубликаты секций и правил.
Чтобы обновить скрипт, скачайте его заново и запустите снова.

## Удаление

```sh
/etc/init.d/zerotier stop
/etc/init.d/zerotier disable
opkg remove zerotier        # или: apk del zerotier
```

Зону `zerotier` и правила forwarding удалите в LuCI
(**Network → Firewall**) или через UCI, если они больше не нужны.

## Диагностика

### Ошибка `Failed to send request: Operation not permitted`

Это не ошибка скрипта: `wget` не смог даже установить соединение. Чаще всего
виноват DNS, реже — отсутствие маршрута, неверное время или блокировка
GitHub.

Проверьте:

```sh
ping -c 1 1.1.1.1
ping -c 1 raw.githubusercontent.com
nslookup raw.githubusercontent.com 1.1.1.1
date -u
```

- `ping 1.1.1.1` не проходит — нет интернета/WAN. Проверьте `ip route`,
  `logread`, настройки WAN.
- `ping 1.1.1.1` проходит, а по имени — `bad address` — сломан DNS.
- Время сильно отличается от реального — TLS-сертификат будет считаться
  недействительным.
- Всё проходит, но GitHub недоступен — используйте зеркало jsDelivr.

#### Исправить DNS

Замените `wan` на имя вашего WAN-интерфейса, если оно другое:

```sh
uci set network.wan.peerdns='0'
uci -q delete network.wan.dns
uci add_list network.wan.dns='1.1.1.1'
uci add_list network.wan.dns='8.8.8.8'
uci commit network
/etc/init.d/network restart
```

Быстрая проверка без перезапуска сети:

```sh
echo 'nameserver 1.1.1.1' > /etc/resolv.conf
ping -c 1 raw.githubusercontent.com
```

После перезагрузки `/etc/resolv.conf` будет сгенерирован заново, поэтому
постоянно исправляйте DNS через UCI.

#### Если не хватает TLS-пакетов

```sh
opkg update
opkg install ca-bundle libustream-mbedtls
```

или `libustream-openssl`, если сборка на OpenSSL.

### apk установил zerotier, но не установил зависимость

На OpenWrt с `apk` (24.10+ / 25.x) загрузка может оборваться на одном из
пакетов, хотя остальные установятся:

```
(1/4) Installing libminiupnpc (...)
wget: Failed to send request: Operation not permitted
ERROR: libminiupnpc-...: unexpected end of file
...
(4/4) Installing zerotier (...)
1 error; ...
ERROR: failed to install zerotier
```

При этом сам `zerotier` уже стоит, но без `libminiupnpc` не запустится.
Симптом — ошибка при генерации identity:

```
Error loading shared library libminiupnpc.so.18: No such file or directory
(needed by /usr/bin/zerotier-idtool)
```

Скрипт проверяет библиотеки через `ldd` и сам пытается выполнить `apk fix`.
Вручную:

```sh
apk cache clean 2>/dev/null
apk update
apk add libminiupnpc
# или сразу починить все зависимости:
apk fix
```

Если `apk` снова не может скачать пакет, скачайте его через `uclient-fetch`
и поставьте локально (путь для 25.12.4 / aarch64_cortex-a53):

```sh
uclient-fetch -O /tmp/libminiupnpc.apk \
  https://downloads.openwrt.org/releases/25.12.4/packages/aarch64_cortex-a53/packages/libminiupnpc-2.2.8-r1.apk
apk add /tmp/libminiupnpc.apk
```

Проверка:

```sh
ldd /usr/bin/zerotier-one 2>&1 | grep -E 'not found|Error loading'
```

Пустой вывод — всё на месте, можно снова запускать скрипт:

```sh
sh /tmp/zerotier-setup.sh
```

Если `apk` снова обрывается на том же месте, повторите — это сетевой сбой
или нехватка места, а не ошибка пакета.

### Если это не помогло

Скачайте скрипт на компьютер и передайте через `scp`/WinSCP (вариант 4 выше).
Для установки самого ZeroTier интернет на роутере всё равно понадобится:
пакет ставится из репозитория OpenWrt.

## Лицензия

MIT — см. [LICENSE](LICENSE). Текст лицензии — стандартная английская
формулировка.
