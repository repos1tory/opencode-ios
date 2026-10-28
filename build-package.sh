#!/var/jb/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=/var/jb/usr/bin
BUILD="$ROOT/build"
STAGE="$BUILD/stage"

# Upstream pin and port revision live in one place.
. "$ROOT/VERSION"
PKG_VERSION="${UPSTREAM_VERSION}-ios${PORT_REVISION}"
PACKAGE="$BUILD/opencode-server-${PKG_VERSION}_iphoneos-arm64.deb"

# The base package supplies the iOS scaffolding (Node binary, Settings bundle,
# launchd plists) and is independent of the upstream OpenCode version. The
# vendor directory supplies the official JavaScript bundle and assets.
BASE="${BASE_DEB:-$ROOT/base/opencode-server-template.deb}"
if [ ! -r "$BASE" ]; then
  BASE=$(ls -1 "$ROOT"/base/*.deb 2>/dev/null | "$BIN/tail" -n 1 || true)
fi
if [ ! -r "$BASE" ]; then
  echo "Missing base package under $ROOT/base" >&2
  exit 1
fi

VENDOR="$ROOT/vendor/opencode-$UPSTREAM_VERSION"

for source in control postinst-hook.sh postinst-flags.sh prerm-hook.sh \
  opencode-server server.sh watchdog.sh patch-prefs.py patch-postinst.py \
  patch-assets.mjs patch-server.mjs patch-ui.mjs \
  battery.c ui/ios-battery.js network-gate.cjs port/ios/bundle.mjs \
  port/ios/endpoints.mjs port/ios/pty-stub.cjs \
  com.alsinas.opencode-server.plist \
  com.alsinas.opencode-watchdog.plist; do
  if [ ! -r "$ROOT/$source" ]; then
    echo "Missing source file: $ROOT/$source" >&2
    exit 1
  fi
done

if [ -d "$VENDOR" ]; then
  for source in opencode.mjs assets/app-archive.bin; do
    if [ ! -r "$VENDOR/$source" ]; then
      echo "Missing vendor file: $VENDOR/$source" >&2
      exit 1
    fi
  done
else
  echo "No vendor bundle for $UPSTREAM_VERSION; using the base package bundle." >&2
fi

# Normal builds stay mobile-owned. Fall back to sudo only if a build directory
# created by an older root-run script cannot be removed.
if [ -e "$BUILD" ] && ! rm -rf "$BUILD" 2>/dev/null; then
  sudo "$BIN/rm" -rf "$BUILD"
fi
mkdir -p "$STAGE"
"$BIN/dpkg-deb" -x "$BASE" "$STAGE"
"$BIN/dpkg-deb" -e "$BASE" "$STAGE/DEBIAN"

# --- upstream payload -----------------------------------------------------
if [ -d "$VENDOR" ]; then
  cp "$VENDOR/opencode.mjs" "$STAGE/var/jb/usr/lib/opencode-ios/opencode.mjs"
  rm -rf "$STAGE/var/jb/usr/lib/opencode-ios/assets"
  cp -R "$VENDOR/assets" "$STAGE/var/jb/usr/lib/opencode-ios/assets"

  # macOS native addons and helper binaries cannot load on iOS. Removing them
  # is required, not just a size optimization: dlopen() of a macOS Mach-O can
  # terminate the process with SIGILL.
  rm -rf "$STAGE/var/jb/usr/lib/opencode-ios/assets/@opentui/core-darwin-arm64" \
    "$STAGE/var/jb/usr/lib/opencode-ios/assets/@parcel/watcher-darwin-arm64" \
    "$STAGE/var/jb/usr/lib/opencode-ios/assets/@ff-labs/fff-bin-darwin-arm64" \
    "$STAGE/var/jb/usr/lib/opencode-ios/assets/@yuuang/ffi-rs-darwin-arm64" \
    "$STAGE/var/jb/usr/lib/opencode-ios/assets/@lydell" \
    "$STAGE/var/jb/usr/lib/opencode-ios/assets/opencode-pty"

  mkdir -p "$STAGE/var/jb/usr/lib/opencode-ios/assets/ios"
  cp "$ROOT/port/ios/pty-stub.cjs" \
    "$STAGE/var/jb/usr/lib/opencode-ios/assets/ios/pty-stub.cjs"
  chmod 644 "$STAGE/var/jb/usr/lib/opencode-ios/assets/ios/pty-stub.cjs"

  # Version metadata visible to the UI and the control helper.
  cat > "$STAGE/var/jb/usr/lib/opencode-ios/port.json" <<EOF
{"upstream":"$UPSTREAM_VERSION","commit":"$UPSTREAM_COMMIT","port":"$PORT_REVISION","package":"$PKG_VERSION","channel":"latest"}
EOF
  chmod 644 "$STAGE/var/jb/usr/lib/opencode-ios/port.json"

  # Adapt the official bundle to the jailbroken Node runtime and add the two
  # iOS-only endpoints.
  "$STAGE/var/jb/usr/lib/opencode-ios/node" "$ROOT/port/ios/bundle.mjs" \
    "$STAGE/var/jb/usr/lib/opencode-ios/opencode.mjs"
  "$STAGE/var/jb/usr/lib/opencode-ios/node" "$ROOT/port/ios/endpoints.mjs" \
    "$STAGE/var/jb/usr/lib/opencode-ios/opencode.mjs"
  chmod 664 "$STAGE/var/jb/usr/lib/opencode-ios/opencode.mjs"
fi

# --- iOS scaffolding ------------------------------------------------------

"$BIN/sed" "s/^Version: .*/Version: $PKG_VERSION/" "$ROOT/control" > "$STAGE/DEBIAN/control"

cp "$ROOT/opencode-server" "$STAGE/var/jb/usr/bin/opencode-server"
cp "$ROOT/server.sh" "$STAGE/var/jb/usr/lib/opencode-ios/server.sh"
cp "$ROOT/watchdog.sh" "$STAGE/var/jb/usr/lib/opencode-ios/watchdog.sh"
cp "$ROOT/network-gate.cjs" "$STAGE/var/jb/usr/lib/opencode-ios/network-gate.cjs"
cp "$ROOT/com.alsinas.opencode-server.plist" \
  "$STAGE/var/jb/Library/LaunchDaemons/com.alsinas.opencode-server.plist"
cp "$ROOT/com.alsinas.opencode-watchdog.plist" \
  "$STAGE/var/jb/Library/LaunchDaemons/com.alsinas.opencode-watchdog.plist"

# The base package carries the now-retired exposure relay. It is not part of
# this build: the server owns the public port and enforces LAN/Tailscale in
# network-gate.cjs, so drop both the launcher and the binary from the stage.
rm -f "$STAGE/var/jb/Library/LaunchDaemons/com.alsinas.opencode-expose-proxy.plist" \
  "$STAGE/var/jb/usr/lib/opencode-ios/opencode-expose-proxy"

# Battery helper for the web UI indicator. Compiled against the on-device SDK
# and ad-hoc signed so the server (running as mobile) can exec it. It only reads
# the public IOPowerSources API; no entitlements or daemons are involved.
CLANG=/var/jb/usr/bin/clang
SDK=/var/jb/usr/share/SDKs/iPhoneOS.sdk
if [ ! -x "$CLANG" ] || [ ! -d "$SDK" ]; then
  echo "The battery helper needs clang and the iPhoneOS SDK at $SDK." >&2
  exit 1
fi
"$CLANG" -arch arm64 -isysroot "$SDK" -miphoneos-version-min=15.0 -O2 \
  -o "$STAGE/var/jb/usr/lib/opencode-ios/opencode-battery" \
  "$ROOT/battery.c" -framework IOKit -framework CoreFoundation
"$BIN/ldid" -S "$STAGE/var/jb/usr/lib/opencode-ios/opencode-battery"
chmod 755 "$STAGE/var/jb/usr/lib/opencode-ios/opencode-battery"

# The Settings bundle is only available as a compiled binary. Remove its two
# sudo invocations and re-sign the patched Mach-O.
PREFS="$STAGE/var/jb/Library/PreferenceBundles/OpenCodeServerPrefs.bundle/OpenCodeServerPrefs"
"$BIN/python3" "$ROOT/patch-prefs.py" "$PREFS"
"$BIN/ldid" -S "$PREFS"

# Retry the optimistic session sync in the bundled web UI so the first chat is
# not shown as errored while the session projection is still being written.
# The patched chunk is renamed so immutable caches cannot serve the old JS.
"$STAGE/var/jb/usr/lib/opencode-ios/node" "$ROOT/patch-assets.mjs" \
  "$STAGE/var/jb/usr/lib/opencode-ios/assets/app-archive.bin"
chmod 644 "$STAGE/var/jb/usr/lib/opencode-ios/assets/app-archive.bin"

# Add the title widget as a separate hashed asset and sync the service worker
# precache hashes after all asset edits (including the rename above).
"$STAGE/var/jb/usr/lib/opencode-ios/node" "$ROOT/patch-ui.mjs" \
  "$STAGE/var/jb/usr/lib/opencode-ios/assets/app-archive.bin" \
  "$ROOT/ui/ios-battery.js"
chmod 644 "$STAGE/var/jb/usr/lib/opencode-ios/assets/app-archive.bin"

# Headless `serve` must install the SessionRestart service, otherwise sessions
# interrupted by a crash or watchdog recovery never resume on their own.
"$STAGE/var/jb/usr/lib/opencode-ios/node" "$ROOT/patch-server.mjs" \
  "$STAGE/var/jb/usr/lib/opencode-ios/opencode.mjs"
chmod 664 "$STAGE/var/jb/usr/lib/opencode-ios/opencode.mjs"

# --- package metadata -----------------------------------------------------

last_line=$($BIN/tail -n 1 "$STAGE/DEBIAN/postinst")
if [ "$last_line" != "exit 0" ]; then
  echo "Unexpected base postinst ending; refusing to patch it." >&2
  exit 1
fi
$BIN/sed '$d' "$STAGE/DEBIAN/postinst" >"$BUILD/postinst.new"
"$BIN/python3" - "$BUILD/postinst.new" "$ROOT/postinst-flags.sh" <<'PY'
import sys

target, block_path = sys.argv[1], sys.argv[2]
anchor = "/var/jb/usr/bin/chmod 755 /var/jb/Library/LaunchDaemons"
with open(target, "r", encoding="utf-8") as handle:
    text = handle.read()
if text.count(anchor) != 1:
    raise SystemExit(f"expected one postinst anchor, found {text.count(anchor)}")
with open(block_path, "r", encoding="utf-8") as handle:
    block = handle.read()
with open(target, "w", encoding="utf-8") as handle:
    handle.write(text.replace(anchor, block + "\n" + anchor))
PY
cat "$ROOT/postinst-hook.sh" >>"$BUILD/postinst.new"
printf '\nexit 0\n' >>"$BUILD/postinst.new"
"$BIN/python3" "$ROOT/patch-postinst.py" "$BUILD/postinst.new"
cp "$BUILD/postinst.new" "$STAGE/DEBIAN/postinst"

last_line=$($BIN/tail -n 1 "$STAGE/DEBIAN/prerm")
if [ "$last_line" != "exit 0" ]; then
  echo "Unexpected base prerm ending; refusing to patch it." >&2
  exit 1
fi
$BIN/sed '$d' "$STAGE/DEBIAN/prerm" >"$BUILD/prerm.new"
cat "$ROOT/prerm-hook.sh" >>"$BUILD/prerm.new"
printf '\nexit 0\n' >>"$BUILD/prerm.new"
cp "$BUILD/prerm.new" "$STAGE/DEBIAN/prerm"

rm -f "$STAGE/DEBIAN/md5sums"
chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm" \
  "$STAGE/var/jb/usr/bin/opencode-server" \
  "$STAGE/var/jb/usr/lib/opencode-ios/server.sh" \
  "$STAGE/var/jb/usr/lib/opencode-ios/watchdog.sh" \
  "$PREFS"
chmod 644 "$STAGE/DEBIAN/control" \
  "$STAGE/var/jb/usr/lib/opencode-ios/network-gate.cjs" \
  "$STAGE/var/jb/Library/LaunchDaemons/com.alsinas.opencode-server.plist" \
  "$STAGE/var/jb/Library/LaunchDaemons/com.alsinas.opencode-watchdog.plist"

# Vendor assets may inherit a restrictive build umask; the server runs as mobile.
chmod -R a+rX "$STAGE/var/jb/usr/lib/opencode-ios/assets"

# Installed-Size must describe this build, not the base package.
set -- $("$BIN/du" -sk "$STAGE")
"$BIN/sed" "s/^Installed-Size: .*/Installed-Size: $1/" "$STAGE/DEBIAN/control" >"$BUILD/control.new"
cp "$BUILD/control.new" "$STAGE/DEBIAN/control"

# --root-owner-group records root:wheel in the archive without needing root
# to build. Installed files keep the modes set above.
"$BIN/dpkg-deb" --root-owner-group -b "$STAGE" "$PACKAGE"
echo "$PACKAGE"
