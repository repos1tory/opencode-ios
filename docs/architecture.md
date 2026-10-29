# Architecture

This document describes how the iOS port is assembled. The front page
(`README.md`) is for users; this is for maintainers and anyone auditing the
port.

The short version: **upstream OpenCode is never forked.** CI builds the stock
official bundle from a pinned commit, and `build-package.sh` applies a small
iOS layer on top. If an upstream anchor moves, the build fails instead of
shipping a half-patched server.

## Layers

```
Official OpenCode 2.2.0 (unmodified)
├─ opencode.mjs              post-build text patches
├─ assets/app-archive.bin    web UI archive edits
└─ assets/*                  macOS natives removed, PTY stub added

iOS wrapper (outside upstream logic)
├─ server.sh                 binds 0.0.0.0, sets env, starts shared Node wrapper
├─ network-gate.cjs          Node preload; per-connection access control
├─ launchd plists            server + watchdog jobs
├─ watchdog.sh               health checks and recovery
├─ opencode-server           start/stop/version/check-update helper
└─ port.json                 upstream version, commit, port revision

Package layer
├─ control, postinst, prerm
├─ Settings bundle patch     our compiled prefs binary, re-signed
└─ battery helper            our C binary, IOPowerSources
```

The upstream payload comes from `vendor/opencode-<version>/`; the base package
supplies a build-only Node bootstrap, the Settings bundle, and launchd plists.
The installed package depends on the shared `nodejs` Debian package for runtime.

## Version pin

`VERSION` is the single source of truth:

```
UPSTREAM_VERSION=2.2.0
UPSTREAM_COMMIT=f993a89d13c73ff6f6537d6b97e78e138a3ea363
PORT_REVISION=5
```

- Package version: `<upstream>-ios<port>` (currently `2.2.0-ios5`).
- `/api/info` reports the upstream version.
- `/_ios/port.json` reports upstream, commit, port revision, package, and update
  state.
- `opencode-server version` prints all of it.

## Upstream build

`.github/workflows/upstream-bundle.yml`:

1. Checks out `anomalyco/opencode` at the pinned commit.
2. Installs with Bun 1.4.4.
3. Runs the official `build-node.ts --bundle-only` with
   `OPENCODE_TARGET=darwin-arm64`.
4. Uploads `opencode.mjs`, `assets/`, `SHA256SUMS`, and `bundle.json`.

The workflow contains **no iOS patches**. That keeps the upstream build
validated on its own; the port is a separate layer.

`scripts/fetch-bundle.sh` downloads the matching successful run, verifies the
SHA-256 manifest, and stages it under `vendor/opencode-<version>/`.

## Build order

`build-package.sh`:

1. Extract the base package (build-only Node, Settings bundle, plists).
2. Replace `opencode.mjs` and `assets/` with the vendor bundle.
3. Remove macOS native addons/helpers; add `assets/ios/pty-stub.cjs`.
4. Generate `port.json`.
5. Apply `port/ios/bundle.mjs` (runtime adaptation).
6. Apply `port/ios/endpoints.mjs` (`/_ios/battery.json`, `/_ios/port.json`).
7. Copy `server.sh`, `watchdog.sh`, `network-gate.cjs`, and the plists.
8. Compile `opencode-battery`; patch and re-sign the Settings bundle.
9. Apply `patch-assets.mjs` (session-sync retry, cache-busting rename).
10. Apply `patch-ui.mjs` (title widget, service-worker re-hash).
11. Apply `patch-server.mjs` (restart continuity, same-device OAuth text).
12. Remove the build-only Node binary; installed server uses the `nodejs` dependency.
13. `chmod -R a+rX` the vendored assets; the server runs as `mobile`.
14. Write the version into `control`, patch `postinst`/`prerm`, and build the
    `.deb` with `dpkg-deb --root-owner-group`.

Every patch requires exactly one match and exits non-zero otherwise.

## Bundle patches

`port/ios/bundle.mjs` adapts the stock Node bundle to the jailbroken runtime:

| Change | Reason |
| --- | --- |
| Shebang → `/var/jb/usr/bin/node` | Uses the shared package wrapper, which supplies the required V8 flags. |
| Stub `node:sea.getAssetKeys` | Absent from Node 22; the non-SEA path never calls it. |
| Stub `node:inspector` | The jailbroken Node has no inspector; profiling is the only consumer. |
| `OPENCODE_NODE_PTY_PATH` → `assets/ios/pty-stub.cjs` | The macOS `node-pty` addon cannot load. |
| `__ocPersistentPty = undefined` | No iOS persistent PTY binary is shipped. |
| Empty password when `OPENCODE_IOS_DISABLE_SERVER_AUTH=1` | The gate is the access-control boundary. |
| `authorizedRequest` short-circuit for the same env | The HTTP dispatcher checks credentials before routing. |
| `persistentPty` capability → `false` | Tell the UI the truth. |

`patch-server.mjs` removes the lifecycle guard around
`installRestartContinuity`, so headless `serve` resumes interrupted sessions,
and changes the ChatGPT OAuth instruction to explain that the `127.0.0.1`
callback must complete on the same iPhone.

## Web UI patches

`app-archive.bin` is a custom archive: a 4-byte index length, a JSON index of
`[offset, length]` entries, and brotli-compressed bodies.

`patch-assets.mjs`:

- finds the optimistic session-create/sync code and retries the immediate
  `session.get` for up to 300 ms;
- renames the patched chunk (`solid-…` → `solid-…-iosN`) and rewrites every
  reference. The server serves `/_assets/*` as immutable for a year, so keeping
  the old name would leave browsers on the old JavaScript.

`patch-ui.mjs`:

- adds a content-hashed `ios-battery-<hash>.js` entry;
- inserts exactly one `<script type="module">` in `index.html`;
- rewrites the `sw.js` precache manifest with new MD5 revisions and SHA-256
  integrity hashes after all edits.

The widget only calls `fetch` and sets `document.title`; it never touches
application elements. It reads:

- `/_ios/battery.json` — live battery helper output, cached for one second;
- `/_ios/port.json` — `port.json` merged with the daily update state.

`port/ios/endpoints.mjs` adds those paths by patching the minified asset-loader
Proxy getter. It matches the loader's shape, not identifier names.

## Network gate

`server.sh` starts `opencode serve` on `0.0.0.0` and loads
`network-gate.cjs` with `node --require`. Binding every interface means a new
Wi-Fi network, DHCP lease, or Tailscale reconnect cannot leave the server on a
stale address.

The gate wraps `http.createServer` and inspects each TCP `connection`:

- loopback is always allowed;
- `100.64.0.0/10` and `fd7a:115c:a1e0::/48` when `TAILSCALE=1`;
- the live subnets of `en*`, `eth*`, and `bridge*` when `LAN=1`.

It re-reads `settings.conf` on every connection and every two seconds, so
toggles apply without restarting. Turning a path off also destroys sockets that
no longer match. Denials go to
`/var/mobile/Library/Logs/OpenCode/network.log`.

There is no second proxy process and no relay.

## Supervision and restart continuity

The server job uses launchd `KeepAlive` with a `PathState` flag
(`server.enabled`). The watchdog runs as root every 10 seconds and:

- tolerates a 60-second startup/recovery window;
- allows 20 seconds per health request;
- requires three failed checks plus a 15-second confirmation probe before
  sending SIGKILL;
- retries through launchd with 30, 60, 120, 240, then 300-second maximum
  delays;
- honors `AUTO_START=0` and removes the PathState flag at boot.

The V8 old-space limit defaults to 768 MB. `server.sh` clears suspended-session
claims older than two hours before start, so a restart does not resurrect
abandoned work.

`patch-server.mjs` installs upstream restart continuity in headless `serve`
mode. At startup the server injects the upstream “continue after restart”
message into sessions that were interrupted.

## Settings bundle

The Settings pane is a compiled binary that used to invoke
`sudo -n /var/jb/usr/bin/opencode-server …`. `patch-prefs.py` rewrites the two
C strings in `__cstring` to call the helper directly, then `ldid -S` re-signs
the bundle. This is our own bundle, not upstream code.

## Security model

- The gate is the access-control boundary.
- OpenCode server authentication is disabled for connections that pass the
  gate (`OPENCODE_IOS_DISABLE_SERVER_AUTH=1`).
- Loopback is always trusted.
- `LAN=1` exposes the server to the current Wi-Fi subnet.
- `TAILSCALE=1` exposes the server to the tailnet (`100.64.0.0/10` and
  `fd7a:115c:a1e0::/48`).

## Upgrade procedure

```sh
./scripts/check-update.sh
./scripts/update-upstream.sh --push   # bump VERSION, trigger CI
./scripts/fetch-bundle.sh             # download + verify the stock bundle
./build-package.sh                    # apply the iOS layer
sudo /var/jb/usr/bin/dpkg -i build/opencode-server-<version>_iphoneos-arm64.deb
```

### Likely break points

| Area | Sensitivity |
| --- | --- |
| `port/ios/bundle.mjs` anchors | High — minified names and guard shapes move. |
| `patch-server.mjs` | High — restart and OAuth anchors. |
| `patch-assets.mjs` | Medium-high — minified session-sync pattern. |
| `port/ios/endpoints.mjs` | Medium — asset-loader Proxy shape. |
| `patch-ui.mjs` | Medium — archive format and service-worker manifest. |
| `patch-prefs.py` | Medium — our Settings bundle strings. |
| `network-gate.cjs` | Low — depends on Node `http.createServer`. |
| `VERSION` / `port.json` | Low. |

The build failing is the desired behavior. A silent partial patch is worse
than an afternoon of updating an anchor.

## File map

```
VERSION                     upstream pin and port revision
control                     Debian control template
build-package.sh            assembles the .deb
server.sh                   starts the server and network gate
watchdog.sh                 resident supervisor
network-gate.cjs            per-connection LAN/Tailscale gate
opencode-server             control helper
port/ios/bundle.mjs         Node runtime adaptation
port/ios/endpoints.mjs      /_ios/* endpoints
port/ios/pty-stub.cjs       node-pty stand-in
patch-assets.mjs            session sync + chunk rename
patch-ui.mjs                title widget + service-worker hashes
patch-server.mjs            restart continuity + OAuth text
patch-prefs.py              Settings bundle string patch
battery.c                   IOPowerSources helper
ui/ios-battery.js           title widget source
scripts/                    check-update / update-upstream / fetch-bundle
vendor/                     downloaded official bundle (gitignored)
```
