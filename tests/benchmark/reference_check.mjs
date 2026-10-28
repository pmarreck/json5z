// Independent check on a benchmark workload: the reference json5 library
// (npm json5, JSON5_REFERENCE) must parse the document, and must reject the
// same document with its final ']' changed to '}'.
// Usage: node reference_check.mjs FILE
import { createRequire } from 'node:module'
import { readFileSync } from 'node:fs'

const JSON5 = createRequire(import.meta.url)(process.env.JSON5_REFERENCE)
const source = readFileSync(process.argv[2], 'utf8')
JSON5.parse(source)
const last = source.lastIndexOf(']')
const corrupt = source.slice(0, last) + '}' + source.slice(last + 1)
let rejected = false
try {
	JSON5.parse(corrupt)
} catch {
	rejected = true
}
if (!rejected) {
	console.error('reference json5 accepted the corrupted workload')
	process.exit(1)
}
