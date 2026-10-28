# v2 source-port implementation status

Candidate in development; not a production release.

- Upstream pinned: v2.2.0 / 1097e2668b1e08ad63bdf0b1c4860b9bc01e420c.
- Source and SQLite backup verified on iPad (212 sessions, integrity_check=ok), under the private `.local/state/opencode-port-backups/20261027T213820` directory.
- Existing unpublished ios42 source retained in `port/legacy/ios42` for reconciliation. These files are historical input, not the new build pipeline.
- Upstream web UI built from pinned source; initial Node artifact built successfully on Mac.
- iOS loose bundle builds from original source via `port/scripts/build-engine.ts` and `port/patches/ios-platform.patch`; no binary/minified patching.
- Isolated iPad launch exposed a genuine Node runtime gap: Node was built without Inspector, while upstream eagerly imported it. CPU profiling is being changed to load Inspector on demand and use Node file APIs.
- Ordinary PTY adapter/helper implemented; tests and device verification pending. Persistent terminal support and interactive TUI are explicitly unverified/unavailable in this candidate.
- Full on-device build loop, authenticated gateway, new controller, migration, endurance, package deployment and publication remain unfinished. The installed server has not been replaced.

## Device investigation: 27 October

The iOS source bundle launched on Node 22.19, served the v2 UI and returned authenticated `/api/info` on an isolated port. The actual migration test is not complete. A copy of the database was preserved; the live database was not changed.

The Node runtime reproducibly crashes on this iPad for `new Intl.Segmenter().segment("hello")` (SIGSEGV) and `Atomics.add(new Int32Array(new SharedArrayBuffer(4)),0,1)` (SIGILL, including with `--jitless`). The crash report points to `Builtins_AtomicsAdd`. A vendored MIT-licensed grapheme adapter avoids the first crash, but deliberately does not implement word or sentence segmentation. This is experimental and is not sufficient to certify runtime correctness. Correct the Node port and validate on A10 before deployment. Do not install this candidate or use the workaround as a substitute for a fixed runtime.

Four PTY helper tests passed on macOS and the iPad. Upstream full `bun run check` completed 35/35 tasks; focused CLI tests passed. The `ios` patches and PTY adapter require further integration testing. Network gateway, controller, package, on-device build, migration and soak tests are not yet implemented.

A runtime rebuild is in progress from the `ios-a10-runtime` branch of `repos1tory/node-ios` (commit `062e63d`). V8's `CpuFeaturesFromCompiler()` takes ARM atomics and dot-product assumptions from the build compiler; the experimental patch excludes these compiler assumptions for iOS, relying on runtime detection. This is a hypothesis until the actual rebuilt runtime passes `port/tests/runtime-smoke.mjs` on A10. GitHub Actions dispatch returned HTTP 422 (Actions disabled), so the build is running locally. The Unicode failure still needs a real runtime fix or a documented compatibility layer with complete tested behavior.
