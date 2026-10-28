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

// v2.2 keeps the lifecycle guard but moved .pipe() outside the call. Both
// layouts exist in the wild; prefer the current one and fall back to the 2.0
// shape so an older vendor bundle still builds.
const modernPattern =
  /[A-Za-z_$][\w$]*&&\((yield\*installRestartContinuity\(get\$l\([^)]*\)\)\.pipe\(provideService\$2\([^)]*\)\))\)/g;
const modernMatches = [...source.matchAll(modernPattern)];

if (modernMatches.length === 1) {
  source = source.replace(modernPattern, (_, inner) => inner);
  console.log("restart continuity enabled for serve mode (v2.2 layout)");
} else if (source.includes(guarded)) {
  source = source.replace(guarded, enabled);
} else if (source.includes(enabled)) {
  console.log("restart continuity already enabled");
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

// ChatGPT's token-sharing OAuth callback binds to 127.0.0.1 on the iPhone.
// When the user opens the authorization URL on a different device, that
// device's loopback receives the callback and returns 404. Make the required
// same-device behavior explicit in the sign-in UI instead of failing silently.
const sameDevice =
  "Open this sign-in link in a browser on this same iPhone. Its 127.0.0.1 callback cannot complete on another device.";

if (source.includes(sameDevice)) {
  console.log("same-device ChatGPT OAuth instruction already installed");
} else {
  const oauthPattern =
    /(mode:"auto",url:authorizeURL\$1\([^)]*\),instructions:)"Complete authorization in your browser\. This window will close automatically\."/g;
  const oauthMatches = [...source.matchAll(oauthPattern)];
  if (oauthMatches.length !== 1) {
    console.error(
      `ChatGPT OAuth instruction anchor not found exactly once (matches=${oauthMatches.length}); refusing to patch`,
    );
    process.exit(1);
  }
  source = source.replace(oauthPattern, (_, prefix) => `${prefix}${JSON.stringify(sameDevice)}`);
}

const temporary = `${target}.tmp`;
writeFileSync(temporary, source);
renameSync(temporary, target);
console.log("server patch applied");
