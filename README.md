# OpenCode Server package patch

This source updates the existing independent `com.alsinas.opencode-server`
package to `2.0.28-0ios41`. Both the core server and network relay use launchd
`KeepAlive`, so launchd immediately respawns them after a crash or jetsam exit.
A resident watchdog loop checks both health endpoints every 10 seconds, and
launchd keeps the watchdog itself running. It recovers hung processes with
capped retry backoff. OpenLens is not involved.

## Default workspace

New sessions and the web UI's New Project picker start in `/var/mobile/OpenCode`
(`On My iPad/OpenCode`). `$HOME` and all state stay in `/var/jb/var/mobile`, so the
SQLite database is never on the File Provider volume and a session with no project
selected cannot read `.ssh` or provider credentials.

## Server control without sudo

The Settings pane used to run `sudo -n /var/jb/usr/bin/opencode-server ...` for
Start, Stop, Restart, Check, and network changes. That required the user to add
passwordless sudo for `mobile` on every device. It no longer does:

* The compiled Settings bundle is patched at build time to call
  `/var/jb/usr/bin/opencode-server` directly.
* `opencode-server` runs as `mobile` and uses process signals instead of
  privileged `launchctl bootstrap`, `bootout`, `kickstart`, `enable`, or
  `disable`.
* The core and relay plists no longer use `RunAtLoad`. Their `KeepAlive`
  dictionaries use `PathState` on
  `/var/mobile/.config/opencode-ios/server.enabled` and
  `/var/mobile/.config/opencode-ios/relay.enabled`. Creating a flag starts the
  job; removing it plus signalling the process stops it and keeps it stopped.
* The package postinst creates the flags when `AUTO_START=1`, and the settings
  `enable`/`disable` actions create or remove them. No sudoers entry is needed.
* Root is still used internally by the system watchdog to bootstrap a missing
  job after boot. That is automatic and invisible to the user.

The prefs binary patch only rewrites C strings in `__cstring` and re-signs the
bundle with `ldid -S`. `patch-prefs.py` refuses to continue if an expected
string is missing or duplicated.

`patch-assets.mjs` also patches the bundled web UI archive. The UI creates a
session optimistically and immediately fetches it. The server can emit
`session.created` before the session projection is readable, producing a
transient 404 and an "errored" first chat even though the prompt succeeds. The
patched client retries that fetch for up to 300 ms. The asset is also renamed
and every HTML/JS/service-worker reference is rewritten, because the web server
serves `/_assets/*` as immutable for a year. Without the rename, existing
browsers and webclips would keep the old JavaScript.

## iOS battery level in the page title

While the server runs on the device, the browser tab reads `OpenCode • 72%`.
It refreshes once a minute and again when the tab becomes visible or focused.
Nothing is added to the page itself: no overlay, badge, or layout change. If the
endpoint is unavailable the original title is left alone.

This build's plugin system can add TUI features and server RPC methods, but the
bundled web UI has no plugin extension point, so a real UI plugin cannot update
the title either. The feature is instead split into removable pieces:

* `battery.c` compiles to `opencode-battery`, a ~50 KB helper that reads the
  public `IOPowerSources` API and prints one JSON line. No daemon, root, or
  entitlement is involved.
* `patch-battery-endpoint.mjs` adds one virtual path, `/_ios/battery.json`, to
  the web UI asset loader. The request handler already consults that loader for
  every non-API path, so the patch is one special case in one function. The
  helper result is cached for one second.
* `ui/ios-battery.js` is a self-contained module that only sets
  `document.title`; it never touches an application element. `patch-ui.mjs`
  adds it to the asset archive under a content hash and inserts exactly one
  script tag into `index.html`.

`patch-ui.mjs` also re-hashes the service worker precache manifest after all
asset edits. Without that, a modified `index.html` and the renamed `solid`
asset no longer match the integrity hashes in `sw.js`; the next service worker
install fails and clients keep the previous UI. This also fixes that latent
problem for the session-sync patch.

The build needs `clang` and the iPhoneOS SDK at
`/var/jb/usr/share/SDKs/iPhoneOS.sdk` to compile the helper. To remove the
battery level, delete `battery.c`, `ui/ios-battery.js`, `patch-ui.mjs`,
`patch-battery-endpoint.mjs`, and their lines in `build-package.sh`; nothing
else depends on them.

## Why sessions stopped on their own

The watchdog used to treat a slow `/api/info` response as a dead server. The
health check allowed only six seconds, needed two failures, and did not reset
its "seen healthy" flag. A large session row or a long V8 garbage collection
can block the Node event loop for longer than that, so the watchdog sent
SIGKILL to a server that was still working. Every in-flight turn died with it.
After the crash, `opencode serve` did not install the upstream SessionRestart
service, so the interrupted sessions stayed suspended until the user typed
"proceed" in each one.

Three changes address that:

* Health checks allow 20 seconds, a missed check opens a 60 second recovery
  window, and three consecutive failures plus a 15 second confirmation probe
  are required before a SIGKILL. A confirmed kill also resets the seen-healthy
  flag, so the replacement process gets a full startup window instead of being
  killed during boot.
* The V8 old-space limit defaults to 768 MB. The 512 MB limit was reached while
  decoding large SQLite rows, producing `JavaScript heap out of memory` crashes.
* `patch-server.mjs` makes headless `serve` install restart continuity. At
  startup the server injects the upstream "continue after restart" message into
  sessions that were interrupted, up to the upstream retry limit. `server.sh`
  clears suspended claims older than two hours first, so a restart never
  resurrects abandoned work from previous days.

Together these keep a busy server alive and resume the work that a real crash
did interrupt.

## Watchdog behavior

The package depends on `curl` and `lsof`. `curl` is required for the postinst
and watchdog health checks; without it a healthy core would be killed in a
loop and the relay would never start. `lsof` lets `server.sh` reclaim a stale
listener on the loopback port. The watchdog also waits for `curl` to appear
instead of killing services when the binary is missing.

The watchdog runs as root so it can bootstrap missing services in the launchd
domain; the server and relay continue running as `mobile`. It uses absolute
jailbreak utility paths because launchd's default PATH excludes
`/var/jb/usr/bin`. It checks the core and relay every 10 seconds. It allows a
60 second startup/recovery grace and 20 seconds per request, requires three
failed checks plus a 15 second confirmation probe after a service has been
healthy, and retries indefinitely through launchd with 30, 60, 120, 240, then
300 second maximum delays. It sends non-blocking SIGKILLs to hung loaded
jobs; launchd `KeepAlive` handles process respawns. Successful health checks
reset backoff. It honors `AUTO_START=0` and removes the PathState flags at
startup so the services stay off. Missing jobs bootstrap immediately; a job
already queued for KeepAlive is left to launchd instead of being delayed by
watchdog backoff. The relay health check runs only while the core API is
healthy, avoiding a proxy restart caused by a core outage. Legacy relay jobs
are retired by the watchdog.

## Source location on the device

`/var/mobile/OpenCode/opencode-ios`

That folder keeps the package inputs, the base package used for rebuilding,
and the generated `.deb`. `server.sh`, `opencode-server`, and both existing
launchd plists are captured from the device before the package is built so the
update preserves the existing network configuration. The V8 heap defaults to
768 MB and can be overridden with `OPENCODE_HEAP_MB`.

## Rebuild and install

### Install from repos1tory

Add `https://repos1tory.github.io/` to Sileo or Zebra, then install
**OpenCode Server (iOS)**. The repository publishes the same package artifact
from this source tree and records its Debian metadata in `Packages`.

The package targets jailbroken iOS devices running firmware 15 or newer and
the `iphoneos-arm64` architecture. It starts with `AUTO_START=1` by default;
set `AUTO_START=0` in the existing settings file before upgrading if the
services must remain stopped.

```sh
cd /var/mobile/OpenCode/opencode-ios
./build-package.sh
```

Installing from the Sileo/Zebra repository does not require sudo. For a manual
local install, run the package manager as root:

```sh
sudo /var/jb/usr/bin/dpkg -i build/opencode-server-2.0.28-0ios41_iphoneos-arm64.deb
```

Before installing a manually downloaded package, verify its metadata:

```sh
/var/jb/usr/bin/dpkg-deb -I opencode-server-2.0.28-0ios41_iphoneos-arm64.deb
```

The package post-install script verifies `curl`, preserves legacy session data
when present, starts the private core and network relay only after health
checks pass, and loads the watchdog. If startup fails, `dpkg` reports the
failure instead of silently leaving a partially configured service.

The build script runs as `mobile` and creates the `.deb` with
`dpkg-deb --root-owner-group`. It only falls back to `sudo` if a `build/`
directory left by an older root-run script cannot be removed.

The watchdog log is `/var/mobile/Library/Logs/OpenCode/watchdog.log`; retry
state is in `/private/var/tmp/opencode/watchdog.state` and resets on reboot.
