#!/var/jb/usr/lib/opencode-ios/node
// Patch the bundled web UI archive.
//
// Two independent changes, both anchored on code shape rather than a fixed
// build hash so an upstream upgrade only needs the pattern re-checked:
//
//   1. The UI creates a session optimistically and immediately syncs it. The
//      server can publish session.created before the projection is readable,
//      so the sync gets a 404 and the first chat is shown as errored even
//      though the prompt succeeds. Retry that one fetch briefly.
//   2. The patched asset is renamed and every reference is rewritten. The web
//      server serves /_assets/* as immutable for a year, so keeping the same
//      filename would leave existing browsers on the old JavaScript.
//
// Fails the build if the session-sync pattern is missing (unless explicitly
// allowed), so a silent upstream drift cannot reintroduce the bug.

import fs from "node:fs";
import path from "node:path";
import zlib from "node:zlib";

const archivePath = process.argv[2];
const allowMissing = process.argv.includes("--allow-missing");
if (!archivePath) {
  console.error("usage: patch-assets.mjs <app-archive.bin> [--allow-missing]");
  process.exit(2);
}

const portRevision = process.env.PORT_REVISION || "1";

const compress = (value) =>
  zlib.brotliCompressSync(Buffer.from(value), {
    params: {
      [zlib.constants.BROTLI_PARAM_QUALITY]: 11,
      [zlib.constants.BROTLI_PARAM_MODE]: zlib.constants.BROTLI_MODE_TEXT,
    },
  });

const decompress = (value) => zlib.brotliDecompressSync(value);

const isText = (key) =>
  key.endsWith(".js") ||
  key.endsWith(".html") ||
  key.endsWith(".json") ||
  key.endsWith(".webmanifest") ||
  key.endsWith(".css");

const archive = fs.readFileSync(archivePath);
const indexLength = archive.readUInt32LE(0);
const index = JSON.parse(archive.subarray(4, 4 + indexLength).toString("utf8"));
const dataStart = 4 + indexLength;

/** @type {Map<string, Buffer>} */
const entries = new Map();
for (const key of Object.keys(index)) {
  const [offset, length] = index[key];
  entries.set(key, archive.subarray(dataStart + offset, dataStart + offset + length));
}

// The optimistic create + immediate sync pair. `t()`/`l()` is the client
// factory in different builds; capture whatever identifier is used.
const syncPattern =
  /let\[([A-Za-z_$][\w$]*),([A-Za-z_$][\w$]*)\]=await Promise\.all\(\[([A-Za-z_$][\w$]*)\(\)\.session\.get\(\{sessionID:([A-Za-z_$][\w$]*)\}\),/g;

let targetKey;
let targetSource;
let match;
for (const [key, data] of entries) {
  if (!key.endsWith(".js")) continue;
  let source;
  try {
    source = decompress(data).toString("utf8");
  } catch {
    continue;
  }
  const found = [...source.matchAll(new RegExp(syncPattern.source, "g"))];
  if (found.length === 0) continue;
  if (found.length > 1) {
    console.error(`${key}: expected one session sync pattern, found ${found.length}`);
    process.exit(1);
  }
  if (targetKey) {
    console.error(`session sync pattern found in both ${targetKey} and ${key}; refusing to patch`);
    process.exit(1);
  }
  targetKey = key;
  targetSource = source;
  match = found[0];
}

if (!targetKey) {
  if (allowMissing) {
    console.log("session sync pattern not present; leaving the archive unchanged");
    process.exit(0);
  }
  console.error("session sync pattern not found in the web UI archive");
  process.exit(1);
}

const [full, resultVar, childrenVar, clientFn, sessionVar] = match;
const retry =
  `let[${resultVar},${childrenVar}]=await Promise.all([(async()=>{` +
  `for(let i=0;i<12;i++){try{return await ${clientFn}().session.get({sessionID:${sessionVar}})}` +
  `catch(r){if(i===11)throw r;await new Promise(e=>setTimeout(e,25))}}})()` +
  `,`;

const extension = path.posix.extname(targetKey);
const stem = targetKey.slice(0, -extension.length);
const newKey = `${stem}-ios${portRevision}${extension}`;
const oldName = path.posix.basename(targetKey);
const newName = path.posix.basename(newKey);

if (entries.has(newKey)) {
  console.log(`session sync asset already patched (${newKey})`);
  process.exit(0);
}

const patchedSource = targetSource.replace(syncPattern, () => retry);
if ((patchedSource.match(/for\(let i=0;i<12;i\+\+\)\{try\{return await /g) || []).length !== 1) {
  console.error("session sync retry was not inserted exactly once");
  process.exit(1);
}

const rebuilt = new Map();
let rewritten = 0;
for (const [key, data] of entries) {
  if (key === targetKey) {
    rebuilt.set(newKey, compress(patchedSource));
    continue;
  }
  if (isText(key)) {
    let source;
    try {
      source = decompress(data).toString("utf8");
    } catch {
      source = undefined;
    }
    if (source !== undefined && source.includes(oldName)) {
      rebuilt.set(key, compress(source.replaceAll(oldName, newName)));
      rewritten += 1;
      continue;
    }
  }
  rebuilt.set(key, data);
}

if (!rebuilt.has(newKey)) {
  console.error("renamed asset was not written");
  process.exit(1);
}
if (rewritten === 0) {
  console.error("no references to the renamed asset were found; refusing to patch");
  process.exit(1);
}

const rebuiltIndex = {};
const chunks = [];
let offset = 0;
for (const [key, data] of rebuilt) {
  rebuiltIndex[key] = [offset, data.length];
  chunks.push(data);
  offset += data.length;
}

const indexBuffer = Buffer.from(JSON.stringify(rebuiltIndex), "utf8");
const header = Buffer.alloc(4);
header.writeUInt32LE(indexBuffer.length, 0);
const output = Buffer.concat([header, indexBuffer, ...chunks]);

// Round-trip the two things that matter before replacing the archive.
const checkIndexLength = output.readUInt32LE(0);
const checkIndex = JSON.parse(output.subarray(4, 4 + checkIndexLength).toString("utf8"));
const checkStart = 4 + checkIndexLength;
const readOutput = (key) => decompress(output.subarray(checkStart + checkIndex[key][0], checkStart + checkIndex[key][0] + checkIndex[key][1]));
if (!readOutput(newKey).toString("utf8").includes("for(let i=0;i<12;i++)")) {
  console.error("patched asset did not round-trip");
  process.exit(1);
}

const temporary = `${archivePath}.new`;
fs.writeFileSync(temporary, output, { mode: 0o644 });
fs.chmodSync(temporary, 0o644);
fs.renameSync(temporary, archivePath);
fs.chmodSync(archivePath, 0o644);
console.log(`patched ${oldName} -> ${newName}; rewrote ${rewritten} references`);
