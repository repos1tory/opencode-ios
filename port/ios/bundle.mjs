#!/var/jb/usr/lib/opencode-ios/node
// Adapt an official OpenCode Node bundle to the jailbroken iOS Node runtime.
//
// The bundle is built by the upstream pipeline in CI for darwin-arm64. This
// script changes only the small set of things that are host-specific:
//
//   1. the shebang (iOS Node does not support --experimental-ffi / --use-system-ca)
//   2. node:sea.getAssetKeys (absent from the jailbroken Node 22)
//   3. node:inspector (absent from the jailbroken Node 22; only used for profiling)
//   4. the node-pty module path (the macOS native addon cannot load on iOS)
//   5. the persistent PTY binary (macOS Mach-O, never shipped)
//
// Every anchor must match exactly once. If an upstream release moves one, the
// build fails instead of silently producing a broken server.

import { readFileSync, renameSync, writeFileSync } from "node:fs";

const target = process.argv[2];
if (!target) {
  console.error("usage: port/ios/bundle.mjs <opencode.mjs>");
  process.exit(2);
}

let source = readFileSync(target, "utf8");

function replaceOnce(from, to, label) {
  const count = source.split(from).length - 1;
  if (count !== 1) {
    console.error(`${label}: expected 1 match, found ${count}; refusing to patch`);
    process.exit(1);
  }
  source = source.replace(from, () => to);
}

function replaceRegexOnce(pattern, to, label) {
  const matches = [...source.matchAll(pattern)];
  if (matches.length !== 1) {
    console.error(`${label}: expected 1 match, found ${matches.length}; refusing to patch`);
    process.exit(1);
  }
  source = source.replace(pattern, () => to);
}

// 1. Use the shared rootless Node wrapper. It owns the required V8 flags, and
// the explicit path avoids relying on launchd's PATH or /usr/bin/env -S.
replaceRegexOnce(/^#![^\n]*\n/g, "#!/var/jb/usr/bin/node\n", "shebang");

// 2. getAssetKeys was added after Node 22. The non-SEA path never calls it, so
// a static no-op keeps the ESM import graph valid.
replaceOnce(
  'import{getAssetKeys as __ocAssetKeys,getRawAsset as __ocRawAsset,isSea as __ocIsSea}from"node:sea";',
  'import{getRawAsset as __ocRawAsset,isSea as __ocIsSea}from"node:sea";const __ocAssetKeys=()=>[];',
  "node:sea import",
);

// 3. The jailbroken Node is built without the inspector. Profiling is the only
// consumer; make the failure lazy instead of failing at module link time.
replaceOnce(
  'import{Session as Session$2}from"node:inspector";',
  'const Session$2=class{connect(){throw new Error("inspector is unavailable on this iOS Node build")}};',
  "node:inspector import",
);

// 4. Point the PTY loader at the tiny CommonJS stub shipped in assets/ios/.
replaceRegexOnce(
  /process\.env\.OPENCODE_NODE_PTY_PATH=__ocPath\.join\(__ocAssetRoot,"[^"]+"\)/g,
  'process.env.OPENCODE_NODE_PTY_PATH=__ocPath.join(__ocAssetRoot,"ios/pty-stub.cjs")',
  "node-pty path",
);

// 5. There is no iOS build of the persistent PTY helper. Leaving the macOS
// asset name in place would try to exec a Mach-O binary that is not shipped.
replaceRegexOnce(/__ocPersistentPty=(?:"[^"]*"|__ocPath\.join\(__ocAssetRoot,"[^"]*"\))/g, "__ocPersistentPty=void 0", "persistent pty binary");

// 6. The port runs the server on loopback/LAN without a browser-visible
// password. Upstream always generates one and fails when it is empty; keep the
// normal path intact and only allow the empty password when the port sets
// OPENCODE_IOS_DISABLE_SERVER_AUTH=1 (server.sh does).
const passwordPattern =
  /([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)\.mode==="service"\?([A-Za-z_$][\w$]*)\.password\|\|([A-Za-z_$][\w$]*)\(32\)\.toString\("base64url"\):([A-Za-z_$][\w$]*)\?([A-Za-z_$][\w$]*)\(([A-Za-z_$][\w$]*)\):([A-Za-z_$][\w$]*)\(32\)\.toString\("base64url"\);if\(!\1\)return yield\*([A-Za-z_$][\w$]*)\(new Error\("Missing server password"\)\)/;
const passwordMatches = [...source.matchAll(new RegExp(passwordPattern.source, "g"))];
if (passwordMatches.length !== 1) {
  console.error(`server password anchor: expected 1 match, found ${passwordMatches.length}; refusing to patch`);
  process.exit(1);
}
source = source.replace(passwordPattern, (...args) => {
  const [, password, mode, serviceConfig, randomA, envPassword, redact, redactArg, randomB, fail] = args;
  return (
    `${password}=${mode}.mode==="service"?${serviceConfig}.password||${randomA}(32).toString("base64url")` +
    `:${envPassword}?${redact}(${redactArg})` +
    `:process.env.OPENCODE_IOS_DISABLE_SERVER_AUTH==="1"?void 0:${randomB}(32).toString("base64url");` +
    `if(!${password}&&process.env.OPENCODE_IOS_DISABLE_SERVER_AUTH!=="1")return yield*${fail}(new Error("Missing server password"))`
  );
});

// The server process has its own empty-password guard after the CLI hands the
// value over. Accept the port's explicit opt-out there too.
const serverPasswordPattern =
  /([A-Za-z_$][\w$]*)=([A-Za-z_$][\w$]*)\.password;if\(!\1\)return yield\*([A-Za-z_$][\w$]*)\(new Error\("Missing server password"\)\)/g;
const serverPasswordMatches = [...source.matchAll(serverPasswordPattern)];
if (serverPasswordMatches.length !== 1) {
  console.error(
    `server process password anchor: expected 1 match, found ${serverPasswordMatches.length}; refusing to patch`,
  );
  process.exit(1);
}
source = source.replace(serverPasswordPattern, (...args) => {
  const [, password, options, fail] = args;
  return (
    `${password}=${options}.password;` +
    `if(!${password}&&process.env.OPENCODE_IOS_DISABLE_SERVER_AUTH!=="1")return yield*${fail}(new Error("Missing server password"))`
  );
});

// The HTTP dispatcher checks credentials before the route tree, so the port's
// opt-out has to short-circuit that helper as well.
replaceOnce(
  "function authorizedRequest(ct,$t){return credentialFromRequest(ct).pipe(",
  'function authorizedRequest(ct,$t){if(process.env.OPENCODE_IOS_DISABLE_SERVER_AUTH==="1")return succeed$4(!0);return credentialFromRequest(ct).pipe(',
  "authorizedRequest helper",
);

// There is no iOS persistent-terminal helper. The upstream bundle advertises
// one unconditionally; report the truth so the UI does not offer terminals.
replaceOnce("const available$1=!0;", "const available$1=!1;", "persistent pty capability");

const temporary = `${target}.tmp`;
writeFileSync(temporary, source);
renameSync(temporary, target);
console.log("iOS bundle adaptation applied");
