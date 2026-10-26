#!/var/jb/usr/lib/opencode-ios/node
// Patch the web UI asset archive.
//
// Two changes:
//   1. The UI optimistically creates a session and immediately syncs it. The
//      server can emit session.created before the session projection is
//      readable, so the sync gets a 404 and the first chat is shown as errored
//      even though the prompt succeeds. Retry the sync fetch briefly.
//   2. The asset is renamed and every reference is rewritten. The web server
//      serves assets as immutable for a year, so keeping the same filename
//      would leave existing browsers and service workers on the old JS.

import fs from "node:fs";
import zlib from "node:zlib";

const archivePath = process.argv[2];
if (!archivePath) {
  console.error("usage: patch-assets.mjs <app-archive.bin>");
  process.exit(2);
}

const oldTarget = "_assets/solid-Cg6qZ2cP.js";
const newTarget = "_assets/solid-Cg6qZ2cP-ios40.js";
const oldName = "solid-Cg6qZ2cP.js";
const newName = "solid-Cg6qZ2cP-ios40.js";
const needle = "let[r,a]=await Promise.all([l().session.get({sessionID:e}),";
const marker = "for(let i=0;i<12;i++){try{return await l().session.get";
const replacement =
  "let[r,a]=await Promise.all([(async()=>{for(let i=0;i<12;i++){try{return await l().session.get({sessionID:e})}catch(r){if(i===11)throw r;await new Promise(e=>setTimeout(e,25))}}})(),";

const compress = (value) =>
  zlib.brotliCompressSync(Buffer.from(value), {
    params: {
      [zlib.constants.BROTLI_PARAM_QUALITY]: 11,
      [zlib.constants.BROTLI_PARAM_MODE]: zlib.constants.BROTLI_MODE_TEXT,
    },
  });

const textEntry = (key) =>
  key.endsWith(".js") ||
  key.endsWith(".html") ||
  key.endsWith(".json") ||
  key.endsWith(".webmanifest");

const archive = fs.readFileSync(archivePath);
const indexLength = archive.readUInt32LE(0);
const index = JSON.parse(archive.subarray(4, 4 + indexLength).toString("utf8"));
const dataStart = 4 + indexLength;

if (index[newTarget] && !index[oldTarget]) {
  console.log("web UI asset already patched");
  process.exit(0);
}
if (!index[oldTarget]) {
  console.error(`asset not found in archive: ${oldTarget}`);
  process.exit(1);
}

const rebuiltIndex = {};
const chunks = [];
let offset = 0;
let patchedSource = false;
let rewrittenReferences = 0;

for (const key of Object.keys(index)) {
  const [entryOffset, entryLength] = index[key];
  let data = archive.subarray(dataStart + entryOffset, dataStart + entryOffset + entryLength);
  let name = key;

  if (key === oldTarget) {
    const source = zlib.brotliDecompressSync(data).toString("utf8");
    if ((source.split(needle).length - 1) !== 1) {
      console.error(`expected one session sync fetch in ${key}`);
      process.exit(1);
    }
    data = compress(source.replace(needle, replacement));
    name = newTarget;
    patchedSource = true;
  } else if (textEntry(key)) {
    let source;
    try {
      source = zlib.brotliDecompressSync(data).toString("utf8");
    } catch {
      source = undefined;
    }
    if (source !== undefined && source.includes(oldName)) {
      data = compress(source.replaceAll(oldName, newName));
      rewrittenReferences += 1;
    }
  }

  rebuiltIndex[name] = [offset, data.length];
  chunks.push(data);
  offset += data.length;
}

if (!patchedSource) {
  console.error("session sync patch was not applied");
  process.exit(1);
}

const indexBuffer = Buffer.from(JSON.stringify(rebuiltIndex), "utf8");
const header = Buffer.alloc(4);
header.writeUInt32LE(indexBuffer.length, 0);
const output = Buffer.concat([header, indexBuffer, ...chunks]);

// Verify the renamed asset and a rewritten reference before replacing the
// archive.
const outputIndexLength = output.readUInt32LE(0);
const outputIndex = JSON.parse(output.subarray(4, 4 + outputIndexLength).toString("utf8"));
const outputDataStart = 4 + outputIndexLength;
const [verifyOffset, verifyLength] = outputIndex[newTarget];
const verified = zlib
  .brotliDecompressSync(
    output.subarray(
      outputDataStart + verifyOffset,
      outputDataStart + verifyOffset + verifyLength,
    ),
  )
  .toString("utf8");
const verifiedHtml = zlib
  .brotliDecompressSync(
    output.subarray(
      outputDataStart + outputIndex["index.html"][0],
      outputDataStart + outputIndex["index.html"][0] + outputIndex["index.html"][1],
    ),
  )
  .toString("utf8");
if (!verified.includes(marker) || !verifiedHtml.includes(newName)) {
  console.error("patched archive did not round-trip");
  process.exit(1);
}

fs.writeFileSync(`${archivePath}.new`, output, { mode: 0o644 });
fs.chmodSync(`${archivePath}.new`, 0o644);
fs.renameSync(`${archivePath}.new`, archivePath);
fs.chmodSync(archivePath, 0o644);
console.log(`patched ${oldTarget} -> ${newTarget}; rewrote ${rewrittenReferences} references`);
