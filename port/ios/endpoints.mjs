#!/var/jb/usr/lib/opencode-ios/node
// Add the iOS-only virtual endpoints to the bundled asset loader.
//
// The upstream server has no route/plugin hook for adding HTTP endpoints to
// the bundled web UI, but the UI asset loader is consulted for every non-API
// path. Teaching that one Proxy getter about two keys keeps the patch tiny and
// independent of Hono/Effect internals:
//
//   /_ios/battery.json  -> live battery helper output
//   /_ios/port.json     -> upstream version, commit, port revision, update state
//
// The loader must keep returning a string/Buffer exactly as before.

import { readFileSync, renameSync, writeFileSync } from "node:fs";

const target = process.argv[2];
if (!target) {
  console.error("usage: port/ios/endpoints.mjs <opencode.mjs>");
  process.exit(2);
}

const BATTERY_KEY = "_ios/battery.json";
const PORT_KEY = "_ios/port.json";
const HELPER = "/var/jb/usr/lib/opencode-ios/opencode-battery";
const PORT_FILE = "/var/jb/usr/lib/opencode-ios/port.json";
const UPDATE_FILE = "/var/mobile/Library/Logs/OpenCode/update.json";
const MARKER = "__ocIosEndpoints";

let source = readFileSync(target, "utf8");

if (source.includes(MARKER)) {
  console.log("iOS endpoints already patched");
  process.exit(0);
}

// The asset loader is a Proxy getter. Match on the shape, not on minified names.
const anchor = /function ([$\w]+)\(([$\w]+),([$\w]+)\)\{return new Proxy\(\{\},\{get:\(([$\w]+),([$\w]+)\)=>\{/g;
const matches = [...source.matchAll(anchor)];
if (matches.length !== 1) {
  console.error(`asset loader anchor not found exactly once (matches=${matches.length}); refusing to patch`);
  process.exit(1);
}

const [full, fn, firstArg, secondArg, targetArg, keyArg] = matches[0];

const battery =
  `if(${keyArg}==="${BATTERY_KEY}"){` +
  `try{` +
  `const g=globalThis,t=Date.now();` +
  `if(!g.${MARKER}||!g.${MARKER}.battery||t-g.${MARKER}.battery.at>1000)` +
  `g.${MARKER}=Object.assign(g.${MARKER}||{},{battery:{at:t,body:g.process.getBuiltinModule("child_process").execFileSync(${JSON.stringify(
    HELPER,
  )},[],{timeout:2000,encoding:"utf8"})}});` +
  `return g.${MARKER}.battery.body` +
  `}catch{return '{"ok":false,"error":"battery helper unavailable"}'}` +
  `}`;

const port =
  `if(${keyArg}==="${PORT_KEY}"){` +
  `try{` +
  `const fs=globalThis.process.getBuiltinModule("fs");` +
  `const meta=JSON.parse(fs.readFileSync(${JSON.stringify(PORT_FILE)},"utf8"));` +
  `try{Object.assign(meta,JSON.parse(fs.readFileSync(${JSON.stringify(UPDATE_FILE)},"utf8")))}catch{}` +
  `return JSON.stringify(meta)` +
  `}catch{return '{}'}` +
  `}`;

const replacement =
  `function ${fn}(${firstArg},${secondArg}){return new Proxy({},{get:(${targetArg},${keyArg})=>{${battery}${port}`;

source = source.replace(anchor, () => replacement);

if (!source.includes(`if(${keyArg}==="${BATTERY_KEY}"){`) || !source.includes(`if(${keyArg}==="${PORT_KEY}"){`)) {
  console.error("iOS endpoint patch did not apply cleanly");
  process.exit(1);
}

const temporary = `${target}.tmp`;
writeFileSync(temporary, source);
renameSync(temporary, target);
console.log(`iOS endpoints added: /${BATTERY_KEY}, /${PORT_KEY}`);
