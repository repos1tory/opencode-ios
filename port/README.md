# iOS port layer

Everything in this directory adapts an **unmodified official OpenCode bundle**
to jailbroken iOS. Upstream code is never edited by hand; the build downloads
the official bundle for `UPSTREAM_VERSION` (see `../VERSION`) and applies the
patches here.

## Layers

| Layer | What it does |
| --- | --- |
| `upstream/` (workflow) | Builds `opencode.mjs` + `assets/` from the official tag in CI, for `darwin-arm64`. |
| `port/ios/bundle.mjs` | Makes the official bundle run on the shared jailbroken Node 22 runtime (SEA import, inspector, shebang, PTY). |
| `port/ios/endpoints.mjs` | Adds `/_ios/battery.json` and `/_ios/port.json` to the web asset loader. |
| `port/ios/pty-stub.cjs` | Stand-in for the macOS `node-pty` native addon. |
| `patch-server.mjs` | Restart continuity + same-device OAuth text. |
| `patch-assets.mjs` / `patch-ui.mjs` | Web UI fixes and the title widget. |
| `network-gate.cjs` / `server.sh` | Networking and launch. |

## Versioning

- `VERSION` pins the upstream release and commit.
- The Debian package version is `<upstream>-ios<port>` (for example `2.2.0-ios5`).
- The server reports the **upstream** version at `/api/info`.
- `/_ios/port.json` reports upstream, commit, port revision, and update state.

## Upgrade

```sh
./scripts/check-update.sh          # compare installed vs latest official
./scripts/update-upstream.sh       # bump VERSION and trigger the CI build
./scripts/fetch-bundle.sh          # download the built bundle into vendor/
./build-package.sh                 # apply iOS patches and build the .deb
```

The CI workflow only needs the official tag/commit. It does not contain any
iOS patches, so an upstream release can always be built unmodified first and
then validated against the patch anchors.

For the process, supervision, network-gate, and web-UI injection details, see
[`../docs/architecture.md`](../docs/architecture.md).
