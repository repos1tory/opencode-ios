#!/var/jb/bin/sh
# Download the CI-built official bundle for the pinned upstream version and
# stage it under vendor/opencode-<version> for build-package.sh.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/VERSION"

REPO="${OPENCODE_IOS_REPO:-repos1tory/opencode-ios}"
WORKFLOW="Build upstream bundle"
BRANCH="upgrade/$UPSTREAM_VERSION"
ARTIFACT="opencode-${UPSTREAM_VERSION}-darwin-arm64"
DEST="$ROOT/vendor/opencode-$UPSTREAM_VERSION"
TMP="$ROOT/build/fetch-$UPSTREAM_VERSION"
GH=/var/jb/usr/bin/gh

run_id="${1:-}"
if [ -z "$run_id" ]; then
  run_id=$("$GH" run list --repo "$REPO" --workflow "$WORKFLOW" \
    --branch "$BRANCH" --limit 20 --json databaseId,conclusion \
    --jq '[.[] | select(.conclusion == "success")][0].databaseId')
fi
if [ -z "$run_id" ] || [ "$run_id" = "null" ]; then
  echo "No successful $WORKFLOW run found for $BRANCH." >&2
  echo "Push the upgrade branch first; the workflow starts automatically." >&2
  exit 1
fi

rm -rf "$TMP"
mkdir -p "$TMP"
"$GH" run download "$run_id" --repo "$REPO" --name "$ARTIFACT" -D "$TMP"

source="$TMP/opencode.mjs"
if [ ! -r "$source" ]; then
  echo "Downloaded artifact is missing opencode.mjs" >&2
  exit 1
fi
if [ -r "$TMP/SHA256SUMS" ]; then
  (cd "$TMP" && /var/jb/usr/bin/sha256sum -c SHA256SUMS)
fi

rm -rf "$DEST"
mkdir -p "$DEST"
cp "$source" "$DEST/opencode.mjs"
cp -R "$TMP/assets" "$DEST/assets"
cp "$TMP/bundle.json" "$DEST/bundle.json" 2>/dev/null || true

# macOS binaries cannot load on iOS; the pty path is redirected to the stub by
# port/ios/bundle.mjs, so the whole native package can go.
rm -rf "$DEST/assets/@opentui/core-darwin-arm64" \
  "$DEST/assets/@parcel/watcher-darwin-arm64" \
  "$DEST/assets/@ff-labs/fff-bin-darwin-arm64" \
  "$DEST/assets/@yuuang/ffi-rs-darwin-arm64" \
  "$DEST/assets/@lydell" \
  "$DEST/assets/opencode-pty"

mkdir -p "$DEST/assets/ios"
cp "$ROOT/port/ios/pty-stub.cjs" "$DEST/assets/ios/pty-stub.cjs"

echo "$DEST"
