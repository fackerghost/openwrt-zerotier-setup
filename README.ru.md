# ZeroTier на OpenWrt — пошаговая инструкция

Скрипт: [`zerotier-setup.sh`](zerotier-setup.sh)
Репозиторий: <https://github.com/fackerghost/openwrt-zerotier-setup>

Сеть по умолчанию: **`8d1c312afa6d0fe8`**

Скрипт устанавливает ZeroTier, настраивает UCI, включает автозапуск и
добавляет зону firewall. После запуска остаётся только авторизовать узел в
ZeroTier Central.

## Что делает скрипт

- ставит пакет `zerotier` через `opkg` или `apk`;
- поддерживает оба формата конфига: OpenWrt 23.05+ (`config network`) и
  22.03 и старше (`list join`);
- прописывает сеть, включает сервис и генерирует/сохраняет identity узла;
- создаёт зону `fw4` для интерфейсов `zt+` (input/output/forward, masq, MTU fix);
- ждёт запуск демона, выполняет join и показывает Node ID;
- опционально разрешает трафик между ZeroTier и LAN;
- можно запускать повторно — существующие секции и правила переиспользуются.

## Требования

- OpenWrt 22.03 или новее (на 21.02 шаг с firewall пропускается);
- root-доступ;
- интернет на роутере (для `opkg`/`apk` и связи с контроллером ZeroTier);
- немного свободного места во flash.

## 1. Скачать скрипт

Сначала проверьте, что роутер видит интернет и DNS:

```sh
ping -c 1 1.1.1.1
ping -c 1 raw.githubusercontent.com
```

Если второй `ping` пишет `bad address` — сначала исправьте DNS (раздел
[«Ошибка Operation not permitted»](#ошибка-failed-to-send-request-operation-not-permitted)).

### Вариант 1. uclient-fetch (штатный загрузчик OpenWrt)

```sh
uclient-fetch -O /tmp/zerotier-setup.sh \
  https://raw.githubusercontent.com/fackerghost/openwrt-zerotier-setup/main/zerotier-setup.sh
```

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

### Вариант 4. Скачать на компьютер и передать на роутер

На компьютере:

```sh
scp zerotier-setup.sh root@192.168.1.1:/tmp/
```

Подойдёт WinSCP или любой SFTP-клиент. Адрес роутера замените на свой.

### Проверить файл

```sh
head -n 1 /tmp/zerotier-setup.sh
wc -c /tmp/zerotier-setup.sh
```

Первая строка должна быть `#!/bin/sh`, размер — около 10 КБ. Если вместо
скрипта скачалась HTML-страница, зеркало вернуло ошибку — попробуйте другой
вариант.

## 2. Запустить

```sh
sh /tmp/zerotier-setup.sh
```

С доступом из ZeroTier в локальную сеть:

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

## 3. Авторизовать узел

Скрипт выведет **Node ID**. Без авторизации узел не получит IP, даже если
join выполнен.

1. Откройте <https://my.zerotier.com/network/8d1c312afa6d0fe8>.
2. Найдите Node ID в разделе **Members**.
3. Поставьте галочку **Authorized**.

Если сеть другая — замените ID в ссылке.

## 4. Проверить

```sh
zerotier-cli info
zerotier-cli listnetworks
```

Ожидаемый результат:

- `zerotier-cli info` — `200 info <Node ID> <версия> ONLINE`;
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

Да, сервис работает постоянно:

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

## Ошибка «Failed to send request: Operation not permitted»

Это не ошибка скрипта: `wget` не смог даже установить соединение. Чаще всего
виноват DNS, реже — отсутствие маршрута, неверное время или блокировка
GitHub.

### Диагностика

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

### Исправить DNS

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

### Если не хватает TLS-пакетов

```sh
opkg update
opkg install ca-bundle libustream-mbedtls
```

или `libustream-openssl`, если сборка на OpenSSL.

### Если это не помогло

Скачайте скрипт на компьютер и передайте через `scp`/WinSCP (вариант 4 выше).
Для установки самого ZeroTier интернет на роутере всё равно понадобится:
пакет ставится из репозитория OpenWrt.

## Лицензия

MIT — см. [LICENSE](LICENSE).
