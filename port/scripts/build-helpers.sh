#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
OUT="$ROOT/build/v2-candidate"
mkdir -p "$OUT"
if [ -d /var/jb/usr/share/SDKs/iPhoneOS.sdk ]; then
  /var/jb/usr/bin/clang -arch arm64 -isysroot /var/jb/usr/share/SDKs/iPhoneOS.sdk -miphoneos-version-min=17.0 -O2 -Wall -Wextra "$ROOT/port/src/pty-helper.c" -o "$OUT/pty-helper"
  /var/jb/usr/bin/ldid -S "$OUT/pty-helper"
else
  sdk=$(xcrun --sdk iphoneos --show-sdk-path)
  xcrun --sdk iphoneos clang -arch arm64 -isysroot "$sdk" -miphoneos-version-min=17.0 -O2 -Wall -Wextra "$ROOT/port/src/pty-helper.c" -o "$OUT/pty-helper"
fi
