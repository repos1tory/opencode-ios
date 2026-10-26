#!/var/jb/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN=/var/jb/usr/bin
BASE="$ROOT/base/opencode-server-2.0.28-0ios24_iphoneos-arm64.deb"
BUILD="$ROOT/build"
STAGE="$BUILD/stage"
PACKAGE="$BUILD/opencode-server-2.0.28-0ios40_iphoneos-arm64.deb"

if [ ! -r "$BASE" ]; then
  echo "Missing base package: $BASE" >&2
  exit 1
fi
for source in control postinst-hook.sh postinst-flags.sh prerm-hook.sh \
  opencode-server server.sh watchdog.sh patch-prefs.py patch-assets.mjs \
  patch-server.mjs patch-ui.mjs patch-battery-endpoint.mjs battery.c \
  ui/ios-battery.js \
  com.alsinas.opencode-server.plist com.alsinas.opencode-expose-proxy.plist \
  com.alsinas.opencode-watchdog.plist; do
  if [ ! -r "$ROOT/$source" ]; then
    echo "Missing source file: $ROOT/$source" >&2
    exit 1
  fi
done

# Normal builds stay mobile-owned. Fall back to sudo only if a build directory
# created by an older root-run script cannot be removed.
if [ -e "$BUILD" ] && ! rm -rf "$BUILD" 2>/dev/null; then
  sudo "$BIN/rm" -rf "$BUILD"
fi
mkdir -p "$STAGE"
"$BIN/dpkg-deb" -x "$BASE" "$STAGE"
"$BIN/dpkg-deb" -e "$BASE" "$STAGE/DEBIAN"

cp "$ROOT/control" "$STAGE/DEBIAN/control"
cp "$ROOT/opencode-server" "$STAGE/var/jb/usr/bin/opencode-server"
cp "$ROOT/server.sh" "$STAGE/var/jb/usr/lib/opencode-ios/server.sh"
cp "$ROOT/watchdog.sh" "$STAGE/var/jb/usr/lib/opencode-ios/watchdog.sh"
cp "$ROOT/com.alsinas.opencode-server.plist" \
  "$STAGE/var/jb/Library/LaunchDaemons/com.alsinas.opencode-server.plist"
cp "$ROOT/com.alsinas.opencode-expose-proxy.plist" \
  "$STAGE/var/jb/Library/LaunchDaemons/com.alsinas.opencode-expose-proxy.plist"
cp "$ROOT/com.alsinas.opencode-watchdog.plist" \
  "$STAGE/var/jb/Library/LaunchDaemons/com.alsinas.opencode-watchdog.plist"

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
"$STAGE/var/jb/usr/lib/opencode-ios/node" "$ROOT/patch-assets.mjs" \
  "$STAGE/var/jb/usr/lib/opencode-ios/assets/app-archive.bin"
chmod 644 "$STAGE/var/jb/usr/lib/opencode-ios/assets/app-archive.bin"

# Add the battery widget as a separate hashed asset and sync the service worker
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

# The web UI fetches battery state from this one small virtual path.
"$STAGE/var/jb/usr/lib/opencode-ios/node" "$ROOT/patch-battery-endpoint.mjs" \
  "$STAGE/var/jb/usr/lib/opencode-ios/opencode.mjs"
chmod 664 "$STAGE/var/jb/usr/lib/opencode-ios/opencode.mjs"

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
  "$STAGE/var/jb/Library/LaunchDaemons/com.alsinas.opencode-server.plist" \
  "$STAGE/var/jb/Library/LaunchDaemons/com.alsinas.opencode-expose-proxy.plist" \
  "$STAGE/var/jb/Library/LaunchDaemons/com.alsinas.opencode-watchdog.plist"

# --root-owner-group records root:wheel in the archive without needing root
# to build. Installed files keep the modes set above.
"$BIN/dpkg-deb" --root-owner-group -b "$STAGE" "$PACKAGE"
echo "$PACKAGE"
