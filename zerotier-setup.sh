#!/bin/sh
#
# zerotier-setup.sh — установка и настройка ZeroTier на OpenWrt
#
# Лицензия: MIT
# Репозиторий: https://github.com/fackerghost/openwrt-zerotier-setup
#
# Параметры:
#   -n, --network ID   ID сети ZeroTier (по умолчанию: 8d1c312afa6d0fe8)
#       --lan          разрешить forwarding между ZeroTier и LAN
#       --no-firewall  не изменять настройки firewall
#       --no-install   не устанавливать пакет zerotier
#   -h, --help         показать справку

NETWORK_ID="${ZEROTIER_NETWORK_ID:-8d1c312afa6d0fe8}"
LAN_ACCESS=0
SETUP_FIREWALL=1
DO_INSTALL=1

NODE_ID=""
STATUS=""
NETLINE=""

log()  { printf '%s\n' "$*"; }
warn() { printf 'ПРЕДУПРЕЖДЕНИЕ: %s\n' "$*" >&2; }
die()  { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }

usage() {
	cat <<'EOF'
Установка и настройка ZeroTier на OpenWrt.

Использование: sh zerotier-setup.sh [параметры]

Параметры:
  -n, --network ID   ID сети ZeroTier (по умолчанию: 8d1c312afa6d0fe8)
      --lan          разрешить forwarding между ZeroTier и LAN
      --no-firewall  не изменять настройки firewall
      --no-install   не устанавливать пакет zerotier
  -h, --help         показать эту справку

ID сети также можно задать переменной ZEROTIER_NETWORK_ID.
EOF
}

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
			-n|--network)
				[ $# -ge 2 ] || die "параметр $1 требует ID сети"
				NETWORK_ID=$2
				shift 2
				;;
			--network=*)
				NETWORK_ID=${1#*=}
				shift
				;;
			--lan|--lan-access)
				LAN_ACCESS=1
				shift
				;;
			--no-firewall)
				SETUP_FIREWALL=0
				shift
				;;
			--no-install)
				DO_INSTALL=0
				shift
				;;
			-h|--help)
				usage
				exit 0
				;;
			*)
				die "неизвестный параметр: $1 (используйте --help)"
				;;
		esac
	done

	# Приводим ID к 16-символьному нижнему регистру, как требует ZeroTier.
	NETWORK_ID=$(printf '%s' "$NETWORK_ID" | tr 'A-F' 'a-f')
	case "$NETWORK_ID" in
		*[!0-9a-f]*) die "неверный ID сети: $NETWORK_ID" ;;
	esac
	[ ${#NETWORK_ID} -eq 16 ] || die "ID сети должен состоять из 16 hex-символов: $NETWORK_ID"
}

# Список имён секций заданного типа из конфига UCI.
section_list() {
	uci show "$1" 2>/dev/null | sed -n "s/^$1\.\([^.=]*\)=$2$/\1/p"
}

uci_quiet() {
	uci "$@" >/dev/null 2>&1
}

pkg_installed() {
	if command -v apk >/dev/null 2>&1; then
		apk info -e zerotier >/dev/null 2>&1
	else
		opkg list-installed 2>/dev/null | grep -q '^zerotier '
	fi
}

install_package() {
	if pkg_installed; then
		log "Пакет ZeroTier уже установлен."
		return 0
	fi

	log "Установка пакета zerotier..."
	if command -v apk >/dev/null 2>&1; then
		apk update || warn "apk update сообщил об ошибках, всё равно пробуем установить"
		apk add zerotier || warn "apk сообщил об ошибках; проверяем установку..."
	else
		opkg update || warn "opkg update сообщил об ошибках, всё равно пробуем установить"
		opkg install zerotier || warn "opkg сообщил об ошибках; проверяем установку..."
	fi

	if ! pkg_installed; then
		die "не удалось установить zerotier (проверьте feeds, DNS и свободное место)"
	fi
}

# Частичная транзакция apk может оставить основной пакет установленным,
# но без зависимости. Проверяем это и пытаемся починить до запуска.
missing_libs() {
	[ -x /usr/bin/zerotier-one ] || return 0

	if command -v ldd >/dev/null 2>&1; then
		# glibc печатает "=> not found", musl пишет ошибки загрузчика в stderr.
		ldd /usr/bin/zerotier-one 2>&1 |
			grep -E 'not found|Error loading shared library|Error relocating' || true
		return 0
	fi

	# ldd не всегда установлен в OpenWrt.
	/usr/bin/zerotier-one -v 2>&1 |
		grep -E 'Error loading shared library|Error relocating' || true
}

repair_package() {
	local missing

	missing=$(missing_libs)
	[ -n "$missing" ] || return 0

	warn "У ZeroTier не хватает библиотек: $missing"
	warn "Пробуем починить установку пакета..."
	if command -v apk >/dev/null 2>&1; then
		apk fix >/dev/null 2>&1 || apk add zerotier >/dev/null 2>&1 || true
	else
		opkg install --force-reinstall zerotier >/dev/null 2>&1 || true
	fi

	missing=$(missing_libs)
	if [ -n "$missing" ]; then
		die "У ZeroTier по-прежнему не хватает библиотек: $missing. Выполните 'apk fix' (или переустановите zerotier) и повторите."
	fi
	log "Зависимости пакета ZeroTier в порядке."
}

# OpenWrt 23.05+ использует отдельную секцию UCI для каждой сети ZeroTier.
uses_network_sections() {
	grep -q 'config_foreach join_network network' /etc/init.d/zerotier 2>/dev/null && return 0
	[ -n "$(section_list zerotier network)" ]
}

configure_new_schema() {
	local sec id found

	if ! uci_quiet get zerotier.global; then
		uci_quiet set zerotier.global=zerotier
	fi
	uci_quiet set zerotier.global.enabled=1

	# Удаляем тестовую сеть Earth, которая идёт в комплекте с пакетом.
	for sec in $(section_list zerotier network); do
		id=$(uci get "zerotier.$sec.id" 2>/dev/null || true)
		if [ "$id" = "8056c2e21c000001" ]; then
			uci_quiet delete "zerotier.$sec"
		fi
	done

	# Переиспользуем существующую секцию для этой сети, если она есть.
	found=""
	for sec in $(section_list zerotier network); do
		id=$(uci get "zerotier.$sec.id" 2>/dev/null || true)
		if [ "$id" = "$NETWORK_ID" ]; then
			found=$sec
			break
		fi
	done

	if [ -z "$found" ]; then
		found=$(uci add zerotier network)
	fi
	[ -n "$found" ] || die "не удалось создать секцию сети ZeroTier"

	uci_quiet set "zerotier.$found.id=$NETWORK_ID"
	uci_quiet set "zerotier.$found.allow_managed=1"
	uci_quiet set "zerotier.$found.allow_global=0"
	uci_quiet set "zerotier.$found.allow_default=0"
	uci_quiet set "zerotier.$found.allow_dns=0"
}

# OpenWrt 22.03 и старше используют одну секцию со списком "join".
configure_old_schema() {
	local sec

	sec=$(section_list zerotier zerotier | head -n 1)
	if [ -z "$sec" ]; then
		sec=$(uci add zerotier zerotier)
	fi
	[ -n "$sec" ] || die "не удалось создать секцию конфигурации ZeroTier"

	uci_quiet set "zerotier.$sec.enabled=1"
	uci_quiet del_list "zerotier.$sec.join=8056c2e21c000001"

	if ! uci get "zerotier.$sec.join" 2>/dev/null | grep -qw "$NETWORK_ID"; then
		uci_quiet add_list "zerotier.$sec.join=$NETWORK_ID"
	fi
}

find_zone() {
	local sec
	for sec in $(section_list firewall zone); do
		if [ "$(uci get "firewall.$sec.name" 2>/dev/null)" = "$1" ]; then
			printf '%s\n' "$sec"
			return 0
		fi
	done
	return 1
}

ensure_forwarding() {
	local src=$1 dst=$2 i=0 sec

	while uci get "firewall.@forwarding[$i]" >/dev/null 2>&1; do
		if [ "$(uci get "firewall.@forwarding[$i].src" 2>/dev/null)" = "$src" ] &&
		   [ "$(uci get "firewall.@forwarding[$i].dest" 2>/dev/null)" = "$dst" ]; then
			return 0
		fi
		i=$((i + 1))
	done

	sec=$(uci add firewall forwarding)
	[ -n "$sec" ] || die "не удалось добавить правило forwarding"
	uci_quiet set "firewall.$sec.src=$src"
	uci_quiet set "firewall.$sec.dest=$dst"
}

configure_firewall() {
	local zone=""

	if ! command -v fw4 >/dev/null 2>&1; then
		warn "fw4 не найден (OpenWrt 21.02 или старше); пропускаем настройку firewall"
		return 0
	fi

	zone=$(find_zone zerotier)
	if [ -z "$zone" ]; then
		zone=$(uci add firewall zone)
		[ -n "$zone" ] || die "не удалось добавить зону firewall"
		uci_quiet set "firewall.$zone.name=zerotier"
		uci_quiet set "firewall.$zone.input=ACCEPT"
		uci_quiet set "firewall.$zone.output=ACCEPT"
		uci_quiet set "firewall.$zone.forward=ACCEPT"
		uci_quiet set "firewall.$zone.masq=1"
		uci_quiet set "firewall.$zone.mtu_fix=1"
		uci_quiet add_list "firewall.$zone.device=zt+"
		log "Добавлена зона firewall 'zerotier' для интерфейсов zt+."
	else
		if uci get "firewall.$zone.device" 2>/dev/null | grep -qF 'zt+'; then
			log "Зона firewall 'zerotier' уже существует."
		else
			uci_quiet add_list "firewall.$zone.device=zt+"
			log "Устройство zt+ добавлено в существующую зону firewall 'zerotier'."
		fi
	fi

	if [ "$LAN_ACCESS" -eq 1 ]; then
		if [ -z "$(find_zone lan)" ]; then
			warn "зона firewall 'lan' не найдена; пропускаем forwarding в LAN"
		else
			ensure_forwarding zerotier lan
			ensure_forwarding lan zerotier
			log "Включён forwarding между ZeroTier и LAN."
		fi
	fi

	uci commit firewall || die "не удалось сохранить конфигурацию firewall"
	/etc/init.d/firewall reload || warn "не удалось перезагрузить firewall; выполните '/etc/init.d/firewall reload' вручную"
}

wait_for_daemon() {
	local i=0 info=""
	log "Ожидание демона ZeroTier..."
	while [ "$i" -lt 30 ]; do
		info=$(zerotier-cli info 2>/dev/null)
		if [ -n "$info" ]; then
			NODE_ID=$(printf '%s\n' "$info" | awk '{print $3}')
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done
	return 1
}

poll_network_status() {
	local i=0 line="" st=""

	while [ "$i" -lt 30 ]; do
		line=$(zerotier-cli listnetworks 2>/dev/null | grep -F "$NETWORK_ID" | head -n 1)
		if [ -n "$line" ]; then
			NETLINE=$line
			st=$(printf '%s\n' "$line" | awk '{
				for (j = 1; j <= NF; j++)
					if ($j == "OK" || $j == "ACCESS_DENIED" || $j == "REQUESTING_CONFIGURATION" || $j == "CLIENT_TOO_OLD") {
						print $j
						exit
					}
			}')
			[ -n "$st" ] && STATUS=$st
			case "$st" in
				OK|ACCESS_DENIED|CLIENT_TOO_OLD) return 0 ;;
			esac
		fi
		sleep 1
		i=$((i + 1))
	done
	return 0
}

print_summary() {
	printf '\n'
	printf '============================================================\n'
	printf ' Настройка ZeroTier завершена\n'
	printf '============================================================\n'
	printf ' ID сети    : %s\n' "$NETWORK_ID"
	printf ' ID узла    : %s\n' "${NODE_ID:-неизвестно}"
	printf ' Статус     : %s\n' "${STATUS:-неизвестно}"
	printf ' Сеть       : %s\n' "${NETLINE:-пока не видна}"
	printf '============================================================\n'

	if [ "$STATUS" != "OK" ]; then
		printf '\nУзел ещё не подключён полностью.\n'
		printf 'Авторизуйте его в ZeroTier Central:\n'
		printf '  https://my.zerotier.com/network/%s\n' "$NETWORK_ID"
		printf '  ID узла: %s\n' "${NODE_ID:-неизвестно}"
		printf 'Потом проверьте снова: zerotier-cli listnetworks\n'
	fi

	if [ "$LAN_ACCESS" -eq 0 ]; then
		printf '\nДоступ в LAN выключен. Запустите с --lan, чтобы разрешить\n'
		printf 'трафик между сетью ZeroTier и локальной сетью.\n'
	fi

	printf '\nПолезные команды:\n'
	printf '  zerotier-cli info\n'
	printf '  zerotier-cli listnetworks\n'
	printf '  logread -e zerotier\n\n'
}

main() {
	parse_args "$@"

	[ "$(id -u 2>/dev/null)" = "0" ] || die "запустите скрипт от root"
	[ -f /etc/openwrt_release ] || die "этот скрипт предназначен для OpenWrt"
	command -v uci >/dev/null 2>&1 || die "uci не найден"

	if [ "$DO_INSTALL" -eq 1 ]; then
		install_package
	fi
	repair_package

	command -v zerotier-cli >/dev/null 2>&1 ||
		die "zerotier-cli не найден; сначала установите пакет 'zerotier'"
	[ -x /etc/init.d/zerotier ] || die "/etc/init.d/zerotier не найден"
	[ -f /etc/config/zerotier ] || touch /etc/config/zerotier

	modprobe tun 2>/dev/null || true
	if [ ! -e /dev/net/tun ]; then
		warn "/dev/net/tun отсутствует; для работы ZeroTier нужен kmod-tun"
	fi

	log "Настройка ZeroTier для сети $NETWORK_ID..."
	if uses_network_sections; then
		configure_new_schema
	else
		configure_old_schema
	fi
	uci commit zerotier || die "не удалось сохранить /etc/config/zerotier"

	if [ "$SETUP_FIREWALL" -eq 1 ]; then
		configure_firewall
	else
		log "Пропускаем настройку firewall (--no-firewall)."
	fi

	log "Включаем и запускаем ZeroTier..."
	/etc/init.d/zerotier enable >/dev/null 2>&1 || warn "не удалось включить автозапуск ZeroTier"
	if ! /etc/init.d/zerotier restart; then
		logread -e zerotier 2>/dev/null | tail -n 20
		die "не удалось запустить службу ZeroTier"
	fi

	wait_for_daemon || die "демон ZeroTier не запустился; смотрите 'logread -e zerotier'"

	if ! zerotier-cli listnetworks 2>/dev/null | grep -qF "$NETWORK_ID"; then
		log "Запрос на подключение к сети $NETWORK_ID..."
		zerotier-cli join "$NETWORK_ID" >/dev/null 2>&1 || warn "zerotier-cli join завершился с ошибкой"
	fi

	poll_network_status
	print_summary

	[ -n "$NETLINE" ] || die "сеть $NETWORK_ID не видна в 'zerotier-cli listnetworks'"
}

main "$@"
