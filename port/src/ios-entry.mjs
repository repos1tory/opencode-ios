import { Segmenter } from '../vendor/unicode-segmenter/intl-adapter.js'
// Node's iOS small-ICU build has Intl.Segmenter but segmentation segfaults.
// This adapter supports grapheme segmentation; word and sentence segmentation
// intentionally throw rather than pretending to provide locale-aware behavior.
if (process.platform === 'ios') Intl.Segmenter = Segmenter
const entry = process.argv[2]
process.argv.splice(1, 1)
await import(entry)
