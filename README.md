# OpenCode Server for iOS

**The official OpenCode v2 server, packaged for jailbroken iPhone and iPad.**

![OpenCode](https://img.shields.io/badge/OpenCode-2.2.0-111111?style=flat-square)
![iOS](https://img.shields.io/badge/iOS-15%2B-lightgrey?style=flat-square)
![Arch](https://img.shields.io/badge/iphoneos--arm64-rootless-blue?style=flat-square)
![Upstream](https://img.shields.io/badge/upstream-MIT-green?style=flat-square)

OpenCode Server (iOS) runs the official OpenCode v2 server and web UI as a
launchd service on rootless jailbroken iOS. Start it once, then use OpenCode
from the device itself, your LAN, or Tailscale.

> [!NOTE]
> This is an unofficial port. It is not affiliated with Anomaly or the OpenCode
> team. Upstream OpenCode is MIT licensed.

## Requirements

| Requirement | Details |
| --- | --- |
| Device | Jailbroken iPhone or iPad |
| Firmware | iOS 15 or newer |
| Architecture | `iphoneos-arm64` (rootless) |
| Package manager | Sileo or Zebra |
| Dependencies | `preferenceloader`, `curl`, `lsof` |

The package bundles its own Node runtime and the official web UI. You do not
need to install Node, Bun, or OpenCode separately.

## Install

### Sileo / Zebra

1. Add **https://repos1tory.github.io/** as a source.
2. Install **OpenCode Server (iOS)**.
3. Open **Settings → OpenCode Server** and tap **Start**.

### Direct .deb

[Download 2.2.0-ios2](https://github.com/repos1tory/opencode-ios/releases/download/opencode-ios-2.2.0-ios2/opencode-server-2.2.0-ios2_iphoneos-arm64.deb)
or install manually:

```sh
sudo /var/jb/usr/bin/dpkg -i opencode-server-2.2.0-ios2_iphoneos-arm64.deb
```

The package starts automatically by default. Set `AUTO_START=0` in
`/var/mobile/.config/opencode-ios/settings.conf` before upgrading if you want it
to stay stopped.

## Open the UI

| From | URL |
| --- | --- |
| The device | http://127.0.0.1:4096/ |
| LAN | `http://<device-ip>:4096/` |
| Tailscale | `http://<tailscale-ip>:4096/` |

Enable **LAN** or **Tailscale** in **Settings → OpenCode Server**. Changes apply
immediately; no restart is needed. The default workspace is
`/var/mobile/OpenCode` (**On My iPhone/iPad → OpenCode**).

> [!WARNING]
> **LAN** allows every device on the current Wi-Fi subnet. **Tailscale** allows
> every peer in your tailnet. Loopback is always allowed. Keep both switches off
> on networks you do not trust.

> [!IMPORTANT]
> Server authentication is disabled for connections that pass the gate. The
> network gate is the access-control boundary.

## What you get

| Feature | What it does |
| --- | --- |
| **Official OpenCode 2.2.0** | The upstream server, web UI, and agent runtime, unmodified except for the iOS port layer. |
| **Browser UI + webclip** | The full OpenCode web app, plus a home-screen webclip. |
| **Live network switches** | LAN and Tailscale access enforced per connection; toggles apply without restarting. |
| **Keep-alive** | launchd `KeepAlive` plus a watchdog that recovers a hung server. |
| **Session resume** | Sessions interrupted by a crash or restart continue automatically. |
| **Title status** | Battery %, upstream version, and an update arrow in the tab title. |
| **Update checks** | A daily check against the official OpenCode release feed. |

> [!NOTE]
> iOS has no persistent PTY helper, so terminal/PTY features are disabled.
> Agents, sessions, files, the web UI, LAN, and Tailscale all work normally.

## Managing the server

`opencode-server` runs as `mobile`; no sudo is required.

```sh
opencode-server status          # job state and health
opencode-server restart
opencode-server version         # upstream, commit, port, package
opencode-server check-update
opencode-server access          # LAN/Tailscale state and gate
opencode-server logs
```

The Settings pane exposes the same controls: **Start**, **Stop**, **Restart**,
**Check**, **LAN**, and **Tailscale**.

## Versions and updates

The package version is `<upstream>-ios<port>`:

```
OpenCode 2.2.0  →  package 2.2.0-ios2
```

- `/api/info` reports the **upstream** version.
- `/_ios/port.json` reports upstream, commit, port revision, and update state.
- `opencode-server version` prints all four values.
- The watchdog checks for updates once a day. The tab title shows `↑<version>`
  when a newer official release exists.

Update through Sileo/Zebra, or rebuild the package:

```sh
./scripts/check-update.sh
./scripts/update-upstream.sh --push
./scripts/fetch-bundle.sh
./build-package.sh
```

See **[docs/architecture.md](docs/architecture.md)** for the build and patch
pipeline, and **[port/README.md](port/README.md)** for the iOS port layer.

## Troubleshooting

| Problem | What to check |
| --- | --- |
| UI does not load | `opencode-server status`; open `http://127.0.0.1:4096/` on the device. |
| Server stopped | Settings → Start, or `opencode-server start`. |
| LAN/Tailscale unreachable | `opencode-server access`; confirm the switch and the device IP. |
| Port conflict | Change `PORT` in `settings.conf`, then restart. |
| Need details | Logs in `/var/mobile/Library/Logs/OpenCode/`. |

Logs:

```
/var/mobile/Library/Logs/OpenCode/server.log
/var/mobile/Library/Logs/OpenCode/server.err.log
/var/mobile/Library/Logs/OpenCode/watchdog.log
/var/mobile/Library/Logs/OpenCode/network.log
```

## Data and settings

| What | Where |
| --- | --- |
| Sessions / SQLite database | `/var/jb/var/mobile/.local/share/opencode/` |
| OpenCode config and credentials | `/var/jb/var/mobile/.config/opencode/` |
| Port / LAN / Tailscale / auto-start | `/var/mobile/.config/opencode-ios/settings.conf` |
| Workspace | `/var/mobile/OpenCode` |
| Logs | `/var/mobile/Library/Logs/OpenCode/` |

State stays under `/var/jb/var/mobile`, away from the File Provider volume.

## Uninstall

Remove **OpenCode Server (iOS)** in Sileo/Zebra. Sessions and settings are left
in place so a reinstall keeps your work. Remove the paths above manually if you
want a clean wipe.

## Development

```
VERSION              upstream version, commit, port revision
port/                iOS port layer (bundle, UI, endpoints, PTY stub)
scripts/             check-update, update-upstream, fetch-bundle
build-package.sh     apply the port and build the .deb
vendor/              downloaded official bundle (gitignored)
```

The CI workflow builds the **unmodified** official bundle from the pinned
commit, then `build-package.sh` applies the iOS layer. Patches fail the build if
an upstream anchor moves, so a broken upgrade cannot be published silently.

More detail: **[docs/architecture.md](docs/architecture.md)**.

## Credits

- [OpenCode](https://github.com/anomalyco/opencode) — the upstream agent, MIT
  licensed.
- This iOS port is maintained in this repository and is not affiliated with
  Anomaly or the OpenCode team.
