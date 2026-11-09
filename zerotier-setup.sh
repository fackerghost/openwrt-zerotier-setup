#!/bin/sh
#
# zerotier-setup.sh - install and configure ZeroTier on OpenWrt
#
# License: MIT
# Repository: https://github.com/fackerghost/openwrt-zerotier-setup
#
# Options:
#   -n, --network ID   ZeroTier network ID (default: 8d1c312afa6d0fe8)
#       --lan          allow forwarding between ZeroTier and LAN
#       --no-firewall  do not touch the firewall configuration
#       --no-install   do not install the zerotier package
#   -h, --help         show this help

NETWORK_ID="${ZEROTIER_NETWORK_ID:-8d1c312afa6d0fe8}"
LAN_ACCESS=0
SETUP_FIREWALL=1
DO_INSTALL=1

NODE_ID=""
STATUS=""
NETLINE=""

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
	cat <<'EOF'
Install and configure ZeroTier on OpenWrt.

Usage: sh zerotier-setup.sh [options]

Options:
  -n, --network ID   ZeroTier network ID (default: 8d1c312afa6d0fe8)
      --lan          allow forwarding between ZeroTier and LAN
      --no-firewall  do not touch the firewall configuration
      --no-install   do not install the zerotier package
  -h, --help         show this help

The network ID can also be set with ZEROTIER_NETWORK_ID.
EOF
}

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
			-n|--network)
				[ $# -ge 2 ] || die "option $1 requires a network ID"
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
				die "unknown option: $1 (use --help)"
				;;
		esac
	done

	# Normalize to the 16-character lowercase hex format used by ZeroTier.
	NETWORK_ID=$(printf '%s' "$NETWORK_ID" | tr 'A-F' 'a-f')
	case "$NETWORK_ID" in
		*[!0-9a-f]*) die "invalid network ID: $NETWORK_ID" ;;
	esac
	[ ${#NETWORK_ID} -eq 16 ] || die "network ID must be 16 hex characters: $NETWORK_ID"
}

# List section names of a given type from a UCI config.
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
		log "ZeroTier package is already installed."
		return 0
	fi

	log "Installing the zerotier package..."
	if command -v apk >/dev/null 2>&1; then
		apk update || warn "apk update reported errors, trying install anyway"
		apk add zerotier || die "failed to install zerotier (check feeds and free space)"
	else
		opkg update || warn "opkg update reported errors, trying install anyway"
		opkg install zerotier || die "failed to install zerotier (check feeds and free space)"
	fi
}

# OpenWrt 23.05+ uses one UCI network section per ZeroTier network.
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

	# Drop the sample "Earth" network shipped with the package.
	for sec in $(section_list zerotier network); do
		id=$(uci get "zerotier.$sec.id" 2>/dev/null || true)
		if [ "$id" = "8056c2e21c000001" ]; then
			uci_quiet delete "zerotier.$sec"
		fi
	done

	# Reuse an existing section for this network if there is one.
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
	[ -n "$found" ] || die "failed to create a ZeroTier network section"

	uci_quiet set "zerotier.$found.id=$NETWORK_ID"
	uci_quiet set "zerotier.$found.allow_managed=1"
	uci_quiet set "zerotier.$found.allow_global=0"
	uci_quiet set "zerotier.$found.allow_default=0"
	uci_quiet set "zerotier.$found.allow_dns=0"
}

# OpenWrt 22.03 and older use a single section with a "join" list.
configure_old_schema() {
	local sec

	sec=$(section_list zerotier zerotier | head -n 1)
	if [ -z "$sec" ]; then
		sec=$(uci add zerotier zerotier)
	fi
	[ -n "$sec" ] || die "failed to create a ZeroTier config section"

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
	[ -n "$sec" ] || die "failed to add a firewall forwarding rule"
	uci_quiet set "firewall.$sec.src=$src"
	uci_quiet set "firewall.$sec.dest=$dst"
}

configure_firewall() {
	local zone=""

	if ! command -v fw4 >/dev/null 2>&1; then
		warn "fw4 not found (OpenWrt 21.02 or older); skipping firewall setup"
		return 0
	fi

	zone=$(find_zone zerotier)
	if [ -z "$zone" ]; then
		zone=$(uci add firewall zone)
		[ -n "$zone" ] || die "failed to add a firewall zone"
		uci_quiet set "firewall.$zone.name=zerotier"
		uci_quiet set "firewall.$zone.input=ACCEPT"
		uci_quiet set "firewall.$zone.output=ACCEPT"
		uci_quiet set "firewall.$zone.forward=ACCEPT"
		uci_quiet set "firewall.$zone.masq=1"
		uci_quiet set "firewall.$zone.mtu_fix=1"
		uci_quiet add_list "firewall.$zone.device=zt+"
		log "Added firewall zone 'zerotier' for zt+ interfaces."
	else
		if uci get "firewall.$zone.device" 2>/dev/null | grep -qF 'zt+'; then
			log "Firewall zone 'zerotier' is already present."
		else
			uci_quiet add_list "firewall.$zone.device=zt+"
			log "Added zt+ device to the existing 'zerotier' firewall zone."
		fi
	fi

	if [ "$LAN_ACCESS" -eq 1 ]; then
		if [ -z "$(find_zone lan)" ]; then
			warn "firewall zone 'lan' not found; skipping LAN forwarding"
		else
			ensure_forwarding zerotier lan
			ensure_forwarding lan zerotier
			log "Enabled forwarding between ZeroTier and LAN."
		fi
	fi

	uci commit firewall || die "failed to commit the firewall configuration"
	/etc/init.d/firewall reload || warn "firewall reload failed; run '/etc/init.d/firewall reload' manually"
}

wait_for_daemon() {
	local i=0 info=""
	log "Waiting for the ZeroTier daemon..."
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
	printf ' ZeroTier setup complete\n'
	printf '============================================================\n'
	printf ' Network ID : %s\n' "$NETWORK_ID"
	printf ' Node ID    : %s\n' "${NODE_ID:-unknown}"
	printf ' Status     : %s\n' "${STATUS:-unknown}"
	printf ' Network    : %s\n' "${NETLINE:-not visible yet}"
	printf '============================================================\n'

	if [ "$STATUS" != "OK" ]; then
		printf '\nThe node is not fully connected yet.\n'
		printf 'Authorize it in ZeroTier Central:\n'
		printf '  https://my.zerotier.com/network/%s\n' "$NETWORK_ID"
		printf '  Node ID: %s\n' "${NODE_ID:-unknown}"
		printf 'Then check again with: zerotier-cli listnetworks\n'
	fi

	if [ "$LAN_ACCESS" -eq 0 ]; then
		printf '\nLAN access is disabled. Re-run with --lan to forward traffic\n'
		printf 'between the ZeroTier network and your LAN.\n'
	fi

	printf '\nUseful commands:\n'
	printf '  zerotier-cli info\n'
	printf '  zerotier-cli listnetworks\n'
	printf '  logread -e zerotier\n\n'
}

main() {
	parse_args "$@"

	[ "$(id -u 2>/dev/null)" = "0" ] || die "run this script as root"
	[ -f /etc/openwrt_release ] || die "this script is for OpenWrt"
	command -v uci >/dev/null 2>&1 || die "uci not found"

	if [ "$DO_INSTALL" -eq 1 ]; then
		install_package
	fi

	command -v zerotier-cli >/dev/null 2>&1 ||
		die "zerotier-cli not found; install the 'zerotier' package first"
	[ -x /etc/init.d/zerotier ] || die "/etc/init.d/zerotier not found"
	[ -f /etc/config/zerotier ] || touch /etc/config/zerotier

	modprobe tun 2>/dev/null || true
	if [ ! -e /dev/net/tun ]; then
		warn "/dev/net/tun is missing; ZeroTier needs kmod-tun to work"
	fi

	log "Configuring ZeroTier for network $NETWORK_ID..."
	if uses_network_sections; then
		configure_new_schema
	else
		configure_old_schema
	fi
	uci commit zerotier || die "failed to commit /etc/config/zerotier"

	if [ "$SETUP_FIREWALL" -eq 1 ]; then
		configure_firewall
	else
		log "Skipping firewall setup (--no-firewall)."
	fi

	log "Enabling and starting ZeroTier..."
	/etc/init.d/zerotier enable >/dev/null 2>&1 || warn "failed to enable ZeroTier at boot"
	if ! /etc/init.d/zerotier restart; then
		logread -e zerotier 2>/dev/null | tail -n 20
		die "failed to start the ZeroTier service"
	fi

	wait_for_daemon || die "the ZeroTier daemon did not come up; see 'logread -e zerotier'"

	if ! zerotier-cli listnetworks 2>/dev/null | grep -qF "$NETWORK_ID"; then
		log "Requesting to join network $NETWORK_ID..."
		zerotier-cli join "$NETWORK_ID" >/dev/null 2>&1 || warn "zerotier-cli join failed"
	fi

	poll_network_status
	print_summary

	[ -n "$NETLINE" ] || die "network $NETWORK_ID is not visible in 'zerotier-cli listnetworks'"
}

main "$@"
