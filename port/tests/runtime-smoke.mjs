import assert from 'node:assert/strict'
import { DatabaseSync } from 'node:sqlite'
import { spawnSync } from 'node:child_process'
import { rootCertificates } from 'node:tls'

assert.equal(process.platform, 'ios')
assert.equal(process.arch, 'arm64')
for (const flag of ['--predictable', '--single-threaded', '--disable-wasm-trap-handler']) assert.ok(process.execArgv.includes(flag), flag)
const memory = new SharedArrayBuffer(4)
const values = new Int32Array(memory)
assert.equal(Atomics.add(values, 0, 1), 0)
assert.equal(Atomics.load(values, 0), 1)
const text = [...new Intl.Segmenter('en', { granularity: 'grapheme' }).segment('A👨‍👩‍👧‍👦e\u0301')]
assert.equal(text.length, 3)
assert.equal(text[1].segment, '👨‍👩‍👧‍👦')
assert.equal([...new Intl.Segmenter('en', { granularity: 'word' }).segment('hello world')].length, 3)
const db = new DatabaseSync(':memory:')
assert.equal(db.prepare('select 42 as value').get().value, 42)
db.close()
assert.equal(new WebAssembly.Memory({ initial: 1 }).buffer.byteLength, 65536)
assert.ok(rootCertificates.length)
assert.equal(spawnSync('/var/jb/bin/sh', ['-c', 'exit 0']).status, 0)
console.log('Runtime smoke passed:', process.version)
