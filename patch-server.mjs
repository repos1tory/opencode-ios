#!/var/jb/usr/bin/env node
// Enable restart continuity in headless `serve` mode.
//
// Upstream only installs the SessionRestart service when an onListen callback
// is supplied (the interactive TUI/service path). The iOS package runs
// `opencode serve`, so sessions that were mid-turn when the server process
// died stayed suspended forever: the web UI showed them idle and the user had
// to type "proceed" in every affected session. Resume them automatically.
//
// The bundle is minified, so patch a small, uniquely identifiable expression
// and fail the build if the expected shape is missing rather than shipping a
// silently unpatched server.

import { readFileSync, renameSync, writeFileSync } from "node:fs";

const target = process.argv[2];
if (!target) {
  console.error("usage: patch-server.mjs <path/to/opencode.mjs>");
  process.exit(2);
}

const enabled =
  "yield*installRestartContinuity(get$l(yn,Service$z)).pipe(provideService$2(Scope$1,_n))";
const guarded = `$t&&(${enabled})`;

let source = readFileSync(target, "utf8");

if (source.includes(guarded)) {
  source = source.replace(guarded, enabled);
} else if (source.includes(enabled)) {
  console.log("restart continuity already enabled");
  process.exit(0);
} else {
  // Tolerate minifier identifier churn between base package versions.
  const pattern =
    /[$A-Za-z_][\w$]*&&\(yield\*installRestartContinuity\((get\$l\([^)]*\)\.pipe\(provideService\$2\([^)]*\)\))\)\)/g;
  const matches = [...source.matchAll(pattern)];
  if (matches.length !== 1) {
    console.error(
      `restart continuity anchor not found exactly once (matches=${matches.length}); refusing to patch`,
    );
    process.exit(1);
  }
  source = source.replace(pattern, "yield*installRestartContinuity($1)");
}

const temporary = `${target}.tmp`;
writeFileSync(temporary, source);
renameSync(temporary, target);
console.log("restart continuity enabled for serve mode");
