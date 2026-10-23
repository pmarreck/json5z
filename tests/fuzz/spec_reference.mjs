// Runs the spec-derived corpus (tests/spec_cases/json5_1.0.cases) through the
// reference JavaScript json5 library and compares its disagreements with
// tests/ledgers/spec_reference_json5.txt as sets, like tests/harness.zig.
//
// Usage: node spec_reference.mjs LEDGER CASES...
// Env:   JSON5_REFERENCE  directory of the json5 npm package (set by the flake)

import { readFileSync } from "node:fs";
import { createRequire } from "node:module";

const [ledgerPath, ...casesPaths] = process.argv.slice(2);
const reference = createRequire(import.meta.url)(`${process.env.JSON5_REFERENCE}/lib/index.js`);
console.warn = () => {};
const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });

// Same escapes as tests/spec_cases.zig: \\ \t \n \r \xHH \u{H...}.
function decodeInput(text) {
	const out = [];
	const utf8 = (cp) => {
		if (cp < 0x80) out.push(cp);
		else if (cp < 0x800) out.push(0xc0 | (cp >> 6), 0x80 | (cp & 63));
		else if (cp < 0x10000) out.push(0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
		else out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 63), 0x80 | ((cp >> 6) & 63), 0x80 | (cp & 63));
	};
	for (let i = 0; i < text.length; i++) {
		const ch = text.codePointAt(i);
		if (ch > 0xffff) i++;
		if (ch !== 0x5c) {
			utf8(ch);
			continue;
		}
		const e = text[++i];
		if (e === "\\") out.push(0x5c);
		else if (e === "t") out.push(9);
		else if (e === "n") out.push(10);
		else if (e === "r") out.push(13);
		else if (e === "x") {
			out.push(parseInt(text.slice(i + 1, i + 3), 16));
			i += 2;
		} else if (e === "u") {
			const close = text.indexOf("}", i);
			utf8(parseInt(text.slice(i + 2, close), 16));
			i = close;
		} else throw new Error(`bad escape \\${e}`);
	}
	return Uint8Array.from(out);
}

function accepts(bytes) {
	let text;
	try {
		text = decoder.decode(bytes);
	} catch {
		return false;
	}
	try {
		reference.parse(text);
		return true;
	} catch {
		return false;
	}
}

const listed = new Set(readFileSync(ledgerPath, "utf8").split("\n").map((l) => l.trim().split(/\s/)[0]).filter((l) => l && !l.startsWith("#")));
let problems = 0;
let seen = 0;
let cases = 0;
for (const line of casesPaths.flatMap((p) => readFileSync(p, "utf8").split("\n"))) {
	if (!line || line.startsWith("#")) continue;
	const [id, verdict, , ...rest] = line.split("\t");
	const want = verdict === "accept";
	const got = accepts(decodeInput(rest.join("\t")));
	cases++;
	if (listed.has(id)) seen++;
	if (got !== want && !listed.has(id)) {
		console.log(`reference json5: unledgered disagreement: ${id} (expected: ${verdict}, got: ${got ? "accept" : "reject"})`);
		problems++;
	} else if (got === want && listed.has(id)) {
		console.log(`reference json5: ledgered case now agrees: ${id}`);
		problems++;
	}
}
if (seen !== listed.size) {
	console.log(`reference json5: ledger names ${listed.size - seen} case(s) that are not in the corpus`);
	problems++;
}
console.log(`reference json5: ${cases} spec cases, ${problems} problem(s)`);
process.exit(problems > 0 ? 1 : 0);
