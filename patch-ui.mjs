#!/var/jb/usr/lib/opencode-ios/node
// Add the iOS battery widget to the bundled web UI.
//
// The upstream web UI is a prebuilt archive with no web-plugin extension
// point, so the widget is injected as one extra content-hashed asset plus one
// script tag in index.html. Everything lives in this file so it can be deleted
// together with ui/ios-battery.js without touching the other patches.
//
// The service worker precaches index.html and the assets with integrity
// hashes. Any asset edit invalidates those hashes and would make the next
// service-worker install fail, leaving clients on the previous UI. This script
// therefore re-hashes every manifest entry from the final archive (and follows
// the patch-assets.mjs rename), so the manifest always matches what is served.
//
// Fails the build instead of shipping a silently broken archive.

import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import zlib from "node:zlib";

const archivePath = process.argv[2];
const widgetPath = process.argv[3] ?? path.join(path.dirname(fileURLToPath(import.meta.url)), "ui", "ios-battery.js");

if (!archivePath) {
  console.error("usage: patch-ui.mjs <app-archive.bin> [ios-battery.js]");
  process.exit(2);
}

const WIDGET_ENDPOINT = "/_ios/battery.json";
const TAG_ID = "oc-ios-battery";

const compress = (value) =>
  zlib.brotliCompressSync(Buffer.from(value), {
    params: {
      [zlib.constants.BROTLI_PARAM_QUALITY]: 11,
      [zlib.constants.BROTLI_PARAM_MODE]: zlib.constants.BROTLI_MODE_TEXT,
    },
  });

const decompress = (value) => zlib.brotliDecompressSync(value);
const md5 = (value) => crypto.createHash("md5").update(value).digest("hex");
const sha256 = (value) => `sha256-${crypto.createHash("sha256").update(value).digest("base64")}`;

const widgetSource = fs.readFileSync(widgetPath, "utf8");
if (!widgetSource.includes(WIDGET_ENDPOINT)) {
  console.error(`widget does not reference ${WIDGET_ENDPOINT}; refusing to patch`);
  process.exit(1);
}

const widgetName = `ios-battery-${crypto.createHash("sha256").update(widgetSource).digest("hex").slice(0, 10)}.js`;
const widgetKey = `_assets/${widgetName}`;

const archive = fs.readFileSync(archivePath);
const indexLength = archive.readUInt32LE(0);
const index = JSON.parse(archive.subarray(4, 4 + indexLength).toString("utf8"));
const dataStart = 4 + indexLength;

/** @type {Map<string, Buffer>} compressed entry bytes, in original order */
const entries = new Map();
for (const key of Object.keys(index)) {
  const [offset, length] = index[key];
  entries.set(key, archive.subarray(dataStart + offset, dataStart + offset + length));
}

const fail = (message) => {
  console.error(message);
  process.exit(1);
};

// --- index.html: exactly one widget script tag, before </head> ------------

if (!entries.has("index.html")) fail("index.html is missing from the archive");
const html = decompress(entries.get("index.html")).toString("utf8");

const closeHeads = html.split("</head>").length - 1;
if (closeHeads !== 1) fail(`expected one </head> in index.html, found ${closeHeads}`);

const tag = `<script type="module" crossorigin src="/${widgetKey}" id="${TAG_ID}"></script>`;
const existingTag = new RegExp(`\\n?\\s*<script[^>]*\\bid="${TAG_ID}"[^>]*></script>`, "g");
const nextHtml = html.replace(existingTag, "").replace(/\s*<\/head>/, `\n    ${tag}\n  </head>`);

if ((nextHtml.split(`id="${TAG_ID}"`).length - 1) !== 1) {
  fail("widget script tag was not inserted exactly once");
}
if (!nextHtml.includes(`src="/${widgetKey}"`)) {
  fail("widget script tag does not reference the hashed asset");
}

entries.set("index.html", compress(nextHtml));
entries.set(widgetKey, compress(widgetSource));

// --- service worker: re-hash every precached entry from the final archive --

if (!entries.has("sw.js")) fail("sw.js is missing from the archive");
const sw = decompress(entries.get("sw.js")).toString("utf8");

const entryPattern = /\{url:"([^"]+)",revision:(?:"[^"]*"|null),integrity:"sha256-[^"]*"\}/g;
const matches = [...sw.matchAll(entryPattern)];
if (matches.length < 100) {
  fail(`service worker precache manifest looks wrong (${matches.length} entries); refusing to patch`);
}

// All entries must form one contiguous array, otherwise this is not the
// manifest this script knows how to rewrite safely.
for (let i = 1; i < matches.length; i++) {
  const gap = sw.slice(matches[i - 1].index + matches[i - 1][0].length, matches[i].index);
  if (!/^\s*,\s*$/.test(gap)) {
    fail("service worker precache entries are not one contiguous array; refusing to patch");
  }
}
const spanStart = matches[0].index;
const spanEnd = matches[matches.length - 1].index + matches[matches.length - 1][0].length;

const usedKeys = new Set();
const resolveKey = (url) => {
  if (entries.has(url) && !usedKeys.has(url)) {
    usedKeys.add(url);
    return url;
  }
  // patch-assets.mjs renames an asset (for example solid-xxx.js ->
  // solid-xxx-ios39.js) without touching sw.js. Follow the rename when it is
  // unambiguous: the manifest URL no longer exists under its old name.
  const extension = path.posix.extname(url);
  const stem = extension ? url.slice(0, -extension.length) : url;
  const candidates = [...entries.keys()].filter(
    (key) => key !== url && key.startsWith(`${stem}-`) && key.endsWith(extension) && !usedKeys.has(key),
  );
  if (candidates.length === 1) {
    usedKeys.add(candidates[0]);
    return candidates[0];
  }
  return undefined;
};

const rebuilt = [];
let renamed = 0;
let dropped = 0;
for (const match of matches) {
  const url = match[1];
  const key = resolveKey(url);
  if (!key) {
    dropped += 1;
    console.warn(`  dropping stale precache entry: ${url}`);
    continue;
  }
  if (key !== url) {
    renamed += 1;
    console.log(`  following precache rename: ${url} -> ${key}`);
  }
  const bytes = decompress(entries.get(key));
  rebuilt.push({ url: key, revision: md5(bytes), integrity: sha256(bytes) });
}

if (!usedKeys.has(widgetKey)) {
  const bytes = decompress(entries.get(widgetKey));
  rebuilt.push({ url: widgetKey, revision: md5(bytes), integrity: sha256(bytes) });
}

const manifest = rebuilt
  .map((entry) => `{url:"${entry.url}",revision:"${entry.revision}",integrity:"${entry.integrity}"}`)
  .join(",");
const nextSw = `${sw.slice(0, spanStart)}${manifest}${sw.slice(spanEnd)}`;
entries.set("sw.js", compress(nextSw));

const indexEntry = rebuilt.find((entry) => entry.url === "index.html");
if (!indexEntry) fail("index.html disappeared from the precache manifest");

// --- write ----------------------------------------------------------------

const order = Object.keys(index);
if (!order.includes(widgetKey)) order.push(widgetKey);

const rebuiltIndex = {};
const chunks = [];
let offset = 0;
for (const key of order) {
  const data = entries.get(key);
  if (!data) fail(`missing entry while writing: ${key}`);
  rebuiltIndex[key] = [offset, data.length];
  chunks.push(data);
  offset += data.length;
}

const indexBuffer = Buffer.from(JSON.stringify(rebuiltIndex), "utf8");
const header = Buffer.alloc(4);
header.writeUInt32LE(indexBuffer.length, 0);
const output = Buffer.concat([header, indexBuffer, ...chunks]);

// --- verify round trip ----------------------------------------------------

const outputIndexLength = output.readUInt32LE(0);
const outputIndex = JSON.parse(output.subarray(4, 4 + outputIndexLength).toString("utf8"));
const outputDataStart = 4 + outputIndexLength;
const readOutput = (key) => {
  const [entryOffset, entryLength] = outputIndex[key];
  return decompress(output.subarray(outputDataStart + entryOffset, outputDataStart + entryOffset + entryLength));
};

const verifiedHtml = readOutput("index.html").toString("utf8");
const verifiedSw = readOutput("sw.js").toString("utf8");
const verifiedWidget = readOutput(widgetKey).toString("utf8");

if (verifiedWidget !== widgetSource) fail("widget asset did not round-trip");
if ((verifiedHtml.split(`id="${TAG_ID}"`).length - 1) !== 1) fail("index.html lost the widget tag");
if (!verifiedHtml.includes(`/${widgetKey}`)) fail("index.html does not reference the widget asset");
if (!verifiedSw.includes(`{url:"${widgetKey}"`)) fail("sw.js does not precache the widget asset");
if (!verifiedSw.includes(`{url:"index.html",revision:"${indexEntry.revision}",integrity:"${indexEntry.integrity}"}`)) {
  fail("sw.js index.html hash was not updated");
}

const temporary = `${archivePath}.new`;
fs.writeFileSync(temporary, output, { mode: 0o644 });
fs.chmodSync(temporary, 0o644);
fs.renameSync(temporary, archivePath);
fs.chmodSync(archivePath, 0o644);
console.log(
  `added ${widgetKey}; synced service worker manifest (${rebuilt.length} entries, ${renamed} renamed, ${dropped} dropped)`,
);
