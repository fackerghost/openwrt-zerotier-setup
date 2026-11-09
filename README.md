# ZeroTier setup for OpenWrt

One-shot shell script that installs and configures [ZeroTier](https://www.zerotier.com/)
on OpenWrt. It joins a network, enables the service at boot and, optionally,
creates the firewall zone needed for ZeroTier traffic.

The script defaults to network **`8d1c312afa6d0fe8`**; any other network ID can
be passed with `--network`.

🇷🇺 Пошаговая инструкция на русском: **[README.ru.md](README.ru.md)**

## Features

- Installs `zerotier` via `opkg` or `apk` (whichever the firmware uses)
- Supports both UCI layouts: OpenWrt 23.05+ (`config network`) and 22.03
  and older (`list join`)
- Enables and restarts the service, generates and persists the node identity
- Adds an `fw4` zone for `zt+` interfaces (input/output/forward, masq, MTU fix)
- Waits for the daemon, joins the network and prints the node ID
- Optional LAN forwarding and a `--no-firewall` escape hatch
- Safe to re-run: existing sections, zones and forwarding rules are reused

## Requirements

- OpenWrt 22.03 or newer (on 21.02 the firewall step is skipped)
- Root shell
- Internet access on the router
- Enough flash for the package and its dependencies

## Quick start

```sh
wget -O /tmp/zerotier-setup.sh https://raw.githubusercontent.com/fackerghost/openwrt-zerotier-setup/main/zerotier-setup.sh
sh /tmp/zerotier-setup.sh
```

Allow ZeroTier clients to reach the LAN (and the LAN to reach ZeroTier):

```sh
sh /tmp/zerotier-setup.sh --lan
```

Use a different network:

```sh
sh /tmp/zerotier-setup.sh --network 0123456789abcdef
```

## Options

| Option | Description |
| --- | --- |
| `-n, --network ID` | ZeroTier network ID (default `8d1c312afa6d0fe8`) |
| `--lan` | Add firewall forwardings between the ZeroTier zone and `lan` |
| `--no-firewall` | Do not modify `/etc/config/firewall` |
| `--no-install` | Configure only, do not install the package |
| `-h, --help` | Show help |

The network ID can also be supplied through the `ZEROTIER_NETWORK_ID`
environment variable.

## After installation

ZeroTier networks are private by default: the node must be authorized before
it receives an IP address.

1. Open <https://my.zerotier.com/network/8d1c312afa6d0fe8> (replace the ID if
   you used another network).
2. Find the node ID printed by the script under **Members** and tick
   **Authorized**.
3. Check the result on the router:

```sh
zerotier-cli info
zerotier-cli listnetworks
```

The status should become `OK` and the interface (`zt...`) should get an
address. If it stays at `REQUESTING_CONFIGURATION`, the node is not authorized
yet or the router cannot reach the ZeroTier controller.

The network ID is not a secret — it only identifies the network, and access is
controlled by the authorization list in ZeroTier Central.

## Firewall notes

On `fw4` systems the script creates:

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

`--lan` additionally creates forwardings `zerotier -> lan` and `lan -> zerotier`.
Without `--lan`, clients can reach the router itself but not the LAN behind it.

Firewall changes are skipped on `fw3` (OpenWrt 21.02 and older); add the zone
manually there if needed.

## Configuration details

- New layout (OpenWrt 23.05+): `zerotier.global.enabled=1` plus a
  `config network` section with the requested ID in `/etc/config/zerotier`.
- Old layout (OpenWrt 22.03-): `option enabled 1` plus the ID in the `join`
  list.
- The sample `Earth` network is removed from the default configuration.
- The node identity is generated on first start and stored in
  `/etc/config/zerotier`, so it survives reboots and sysupgrades.

## Uninstall

```sh
/etc/init.d/zerotier stop
/etc/init.d/zerotier disable
opkg remove zerotier        # or: apk del zerotier
```

Remove the `zerotier` firewall zone and the forwarding rules in LuCI
(**Network → Firewall**) if you no longer need them.

## License

MIT — see [LICENSE](LICENSE).

---

## Русский

Подробная инструкция: **[README.ru.md](README.ru.md)** — скачивание,
установка, авторизация узла, проверка, удаление и разбор ошибки
`Failed to send request: Operation not permitted`.
