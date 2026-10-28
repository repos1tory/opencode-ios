# Experimental OpenCode v2 iOS source port

This is unfinished work. Do not install it as a production package. See `docs/STATUS.md` for observed runtime crashes and outstanding work.

Upstream is pinned by git submodule and `upstream.lock.json`. Run `port/scripts/setup.sh` to apply the source patch, then install upstream's locked dependencies with Bun 1.4.4. The experimental engine builder expects a freshly built `upstream/packages/app/dist` and invokes Vite through Bun: `bun port/scripts/build-engine.ts`. Build the PTY helper with `port/scripts/build-helpers.sh`. The output under `build/v2-candidate` is incomplete and unverified.

Runtime source: https://github.com/repos1tory/node-ios. Native `Intl.Segmenter` and `Atomics.add` crash on the tested device; the candidate must not replace the installed server until those issues and migration/recovery are fixed and tested. The `ios-entry.mjs` grapheme adapter is a diagnostic aid, not a complete ICU replacement.
