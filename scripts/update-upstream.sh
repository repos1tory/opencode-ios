#!/var/jb/bin/sh
# Move VERSION to the latest official OpenCode release.
#
#   ./scripts/update-upstream.sh          # update VERSION only
#   ./scripts/update-upstream.sh --push   # update, commit, and trigger CI
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

if [ -z "$latest" ] || [ -z "$commit" ]; then
  echo "Update check returned incomplete release information." >&2
  exit 1
fi

if [ "$latest" = "$UPSTREAM_VERSION" ]; then
  echo "OpenCode $UPSTREAM_VERSION is already pinned."
  exit 0
fi

cat >"$ROOT/VERSION" <<EOF
# Upstream OpenCode release this iOS port is built from.
UPSTREAM_VERSION=$latest
UPSTREAM_COMMIT=$commit

# iOS port revision for this upstream version. Bump when the port layer
# (patches, packaging, helpers) changes without a new upstream release.
PORT_REVISION=1
EOF

echo "Pinned OpenCode $latest ($commit)."

if [ "${1:-}" != "--push" ]; then
  cat <<EOF

Next:
  git checkout -b upgrade/$latest
  git add VERSION
  git commit -m "chore: upgrade to OpenCode $latest"
  git push -u origin upgrade/$latest
  ./scripts/fetch-bundle.sh
  ./build-package.sh
EOF
  exit 0
fi

cd "$ROOT"
git checkout -b "upgrade/$latest"
git add VERSION
git -c user.name="OpenCode iOS" -c user.email="al5ina5@users.noreply.github.com" \
  commit -m "chore: upgrade to OpenCode $latest"
GIT_ASKPASS="$ROOT/scripts/git-askpass.sh" GIT_TERMINAL_PROMPT=0 \
  git -c credential.helper= push -u origin "upgrade/$latest"

echo "Pushed upgrade/$latest; the bundle workflow will start automatically."
