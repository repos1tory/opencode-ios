#!/var/jb/bin/sh
# Compare the pinned upstream OpenCode version with the latest official release.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/VERSION"

response=$(/var/jb/usr/bin/curl -fsS --connect-timeout 5 --max-time 20 \
  "https://opencode.ai/update/api/latest/cli/npm?current=${UPSTREAM_VERSION}") || {
  echo "Update check failed (network unavailable)." >&2
  exit 1
}

latest=$(printf '%s' "$response" |
  /var/jb/usr/bin/sed -n 's/^.*"version":"\([^"]*\)".*$/\1/p' |
  /var/jb/usr/bin/head -n 1)
commit=$(printf '%s' "$response" |
  /var/jb/usr/bin/sed -n 's/^.*"sha":"\([0-9a-f]*\)".*$/\1/p' |
  /var/jb/usr/bin/head -n 1)

if [ -z "$latest" ]; then
  echo "Update check returned no version." >&2
  exit 1
fi

newest=$(printf '%s\n%s\n' "$UPSTREAM_VERSION" "$latest" |
  /var/jb/usr/bin/sort -V | /var/jb/usr/bin/tail -n 1)

if [ "$newest" = "$UPSTREAM_VERSION" ]; then
  echo "OpenCode $UPSTREAM_VERSION is current (iOS port $PORT_REVISION)."
else
  echo "OpenCode $latest is available (installed $UPSTREAM_VERSION, upstream ${commit:-unknown})."
fi
