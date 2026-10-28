#!/bin/sh
# Extract the exact ICU data bundled in the pinned Node source. The iOS Node
# 22 small-ICU build has Segmenter but crashes without this full data file.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
source_file="${1:?usage: prepare-icu.sh <node-source-directory>}"
source_file="$source_file/deps/icu-small/source/data/in/icudt77l.dat.bz2"
[ -f "$source_file" ] || { echo 'Pinned Node ICU archive missing' >&2; exit 1; }
expected=488a0a666ba33dace736d0788a8973729c8d83f3f4966d0fed1be7ad162d4729
actual=$(shasum -a 256 "$source_file" | cut -d ' ' -f 1)
[ "$actual" = "$expected" ] || { echo 'Unexpected ICU archive digest' >&2; exit 1; }
mkdir -p "$ROOT/build/v2-candidate/icu"
bzip2 -dc "$source_file" > "$ROOT/build/v2-candidate/icu/icudt77l.dat.tmp"
actual=$(shasum -a 256 "$ROOT/build/v2-candidate/icu/icudt77l.dat.tmp" | cut -d ' ' -f 1)
[ "$actual" = 3e07ab54bbe6d54050dac2a408c0331cbfc3c0574fa4a580b7440d06e05c09ef ] || { echo 'ICU data digest mismatch' >&2; exit 1; }
mv "$ROOT/build/v2-candidate/icu/icudt77l.dat.tmp" "$ROOT/build/v2-candidate/icu/icudt77l.dat"
