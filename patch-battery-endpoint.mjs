#!/var/jb/usr/bin/env node
// Expose the iOS battery helper to the web UI.
//
// The upstream server has no route/plugin hook that can add an HTTP endpoint
// for the bundled web UI, so this patch teaches the UI asset loader one virtual
// path. Everything else (helper binary, widget, build wiring) lives in its own
// files, so removing the battery feature means deleting this script and its
// build-package.sh line.
//
// The web UI handler already asks the asset loader for every non-API path, so a
// single special case in the loader's proxy getter is enough. The getter must
// return the same shape it always does (a Buffer or string), so no Hono/Effect
// internals are involved and there is nothing to keep in sync with upstream.

import { readFileSync, renameSync, writeFileSync } from "node:fs";

const target = process.argv[2];
if (!target) {
  console.error("usage: patch-battery-endpoint.mjs <path/to/opencode.mjs>");
  process.exit(2);
}

const ENDPOINT = "/_ios/battery.json";
// The asset loader is keyed by the pathname without its leading slash.
const ASSET_KEY = ENDPOINT.slice(1);
const HELPER = "/var/jb/usr/lib/opencode-ios/opencode-battery";
const MARKER = "__ocIosBattery";

// Structure anchor. Minified identifiers change between builds; the shape of
// the asset-loader proxy does not. Group 5 is the requested key.
const anchor =
  /function ([$\w]+)\(([$\w]+),([$\w]+)\)\{return new Proxy\(\{\},\{get:\(([$\w]+),([$\w]+)\)=>\{/g;

let source = readFileSync(target, "utf8");

if (source.includes(MARKER)) {
  console.log("battery endpoint already patched");
  process.exit(0);
}

const matches = [...source.matchAll(anchor)];
if (matches.length !== 1) {
  console.error(
    `asset loader anchor not found exactly once (matches=${matches.length}); refusing to patch`,
  );
  process.exit(1);
}

const [full, fn, firstArg, secondArg, targetArg, keyArg] = matches[0];

const injected =
  `if(${keyArg}==="${ASSET_KEY}"){` +
  `try{` +
  `const g=globalThis,t=Date.now();` +
  `if(!g.${MARKER}||t-g.${MARKER}.at>1000)` +
  `g.${MARKER}={at:t,body:globalThis.process.getBuiltinModule("child_process").execFileSync(${JSON.stringify(HELPER)},[],{timeout:2000,encoding:"utf8"})};` +
  `return g.${MARKER}.body` +
  `}catch{return '{"ok":false,"error":"battery helper unavailable"}'}` +
  `}`;

const replacement =
  `function ${fn}(${firstArg},${secondArg}){return new Proxy({},{get:(${targetArg},${keyArg})=>{${injected}`;

source = source.replace(anchor, () => replacement);

if (!source.includes(`if(${keyArg}==="${ASSET_KEY}"){`) || !source.includes(`g.${MARKER}={at:t`)) {
  console.error("battery endpoint patch did not apply cleanly");
  process.exit(1);
}

const temporary = `${target}.tmp`;
writeFileSync(temporary, source);
renameSync(temporary, target);
console.log(`battery endpoint added: ${ENDPOINT} -> ${HELPER}`);
