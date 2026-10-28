#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
git submodule update --init --depth 1 upstream
expected=1097e2668b1e08ad63bdf0b1c4860b9bc01e420c
actual=$(git -C upstream rev-parse HEAD)
[ "$actual" = "$expected" ] || { echo "Unexpected upstream revision: $actual" >&2; exit 1; }
if git -C upstream apply --reverse --check ../port/patches/ios-platform.patch 2>/dev/null; then
  echo 'iOS source patch already applied'
else
  git -C upstream apply --check ../port/patches/ios-platform.patch
  git -C upstream apply ../port/patches/ios-platform.patch
fi
printf '%s\n' 'Pinned upstream prepared. Run bun install --frozen-lockfile in upstream with Bun 1.4.4.'
