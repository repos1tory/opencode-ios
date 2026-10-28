import { mkdir, readFile, readdir, copyFile, writeFile, stat } from "node:fs/promises"
import path from "node:path"
import { fileURLToPath, pathToFileURL } from "node:url"
import { brotliCompressSync, constants } from "node:zlib"
import { createHash } from "node:crypto"

const root = fileURLToPath(new URL("../../", import.meta.url))
const source = path.resolve(process.env.OPENCODE_UPSTREAM_DIR ?? path.join(root, "upstream"))
const cli = path.join(source, "packages/cli")
const dest = path.join(root, "build/v2-candidate")
const { build } = await import(pathToFileURL(path.join(cli, "node_modules/vite/dist/node/index.js")).href)
const { mainConfig } = await import(pathToFileURL(path.join(cli, "vite.node.config.ts")).href)
const { nodeTarget, shellParserWasmAssets, photonWasmAsset, attentionSoundAssets } = await import(pathToFileURL(path.join(cli, "src/node/target.ts")).href)
const { createRequire } = await import("node:module")
const require = createRequire(path.join(cli, "package.json"))
const lock = JSON.parse(await readFile(path.join(root, "port/upstream.lock.json"), "utf8"))
const assets = path.join(dest, "assets")
await mkdir(assets, { recursive: true })
for (const name of [photonWasmAsset, ...Object.values(shellParserWasmAssets)]) {
  const target = path.join(assets, name)
  await mkdir(path.dirname(target), { recursive: true })
  await copyFile(require.resolve(name), target)
}
for (const name of attentionSoundAssets) {
  const target = path.join(assets, name)
  await mkdir(path.dirname(target), { recursive: true })
  await copyFile(path.join(source, "packages/ui/src/assets/audio", path.basename(name)), target)
}
// Use the upstream UI output, freshly built with its own pinned dependencies.
// The archive encoding is the upstream documented u32 + index + Brotli layout.
async function files(dir: string): Promise<string[]> {
  const result: string[] = []
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const item = path.join(dir, entry.name)
    if (entry.isDirectory()) result.push(...await files(item))
    else if (!item.endsWith(".map")) result.push(item)
  }
  return result.sort()
}
const ui = path.join(source, "packages/app/dist")
await stat(path.join(ui, "index.html"))
const index: Record<string, number[]> = {}
const chunks: Buffer[] = []
let offset = 0
for (const file of await files(ui)) {
  const data = brotliCompressSync(await readFile(file), { params: { [constants.BROTLI_PARAM_QUALITY]: 6 } })
  index[path.relative(ui, file).replaceAll(path.sep, "/")] = [offset, data.length]
  chunks.push(data)
  offset += data.length
}
const encoded = Buffer.from(JSON.stringify(index))
const header = Buffer.alloc(4)
header.writeUInt32LE(encoded.length)
await writeFile(path.join(assets, "app-archive.bin"), Buffer.concat([header, encoded, ...chunks]))
const config = mainConfig({ version: lock.tag.slice(1), channel: "latest", assetHash: "ios-loose", target: nodeTarget("ios", "arm64") })
config.configFile = false
config.build.outDir = dest
config.build.minify = false
await build(config)
const manifest = {
  upstream: lock.commit,
  version: lock.tag.slice(1),
  target: "ios-arm64",
  runtime: lock.runtimeVersion,
  engineSha256: createHash("sha256").update(await readFile(path.join(dest, "opencode.mjs"))).digest("hex"),
  capabilities: { persistentPty: false, interactiveTui: false, ordinaryPty: "requires-helper" },
  status: "unverified-candidate",
}
await writeFile(path.join(dest, "build-manifest.json"), JSON.stringify(manifest, null, 2) + "\n")
console.log(dest)
