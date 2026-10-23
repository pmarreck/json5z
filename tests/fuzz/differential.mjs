// Differential fuzzer: json5z (WebAssembly build of the core) against the
// reference JavaScript json5 library. Inputs come from a seeded generator of
// grammar-shaped documents plus byte-level mutations. For every input the
// two must agree on accept/reject, and json5z must return the same verdict
// and offset when the input is fed in random chunks.
//
// Usage: node differential.mjs WASM SEED COUNT
// Env:   JSON5_REFERENCE  directory of the json5 npm package (set by the flake)

import { readFileSync } from "node:fs";
import { createRequire } from "node:module";

const [wasmPath, seedArg, countArg] = process.argv.slice(2);
if (!wasmPath || !seedArg || !countArg) {
	console.error("usage: node differential.mjs WASM SEED COUNT");
	process.exit(2);
}
const reference = createRequire(import.meta.url)(`${process.env.JSON5_REFERENCE}/lib/index.js`);
console.warn = () => {}; // the reference warns about raw U+2028/U+2029 in strings

const { instance } = await WebAssembly.instantiate(readFileSync(wasmPath));
const z = instance.exports;
const capacity = z.inputCapacity();

// mulberry32: small, seedable, deterministic.
let state = Number(seedArg) >>> 0;
function random() {
	state = (state + 0x6d2b79f5) >>> 0;
	let t = state;
	t = Math.imul(t ^ (t >>> 15), t | 1);
	t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
	return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const pick = (list) => list[Math.floor(random() * list.length)];
const chance = (p) => random() < p;

// Non-ASCII samples whose general category is stable across Unicode versions.
const letters = ["a", "Z", "$", "_", "é", "ß", "λ", "中", "Ⅱ"];
const parts = [...letters, "0", "9", "́", "٠", "‍", "‿"];
const spaces = [" ", "\t", "\n", "\r\n", "\r", "\v", "\f", " ", "﻿", " ", " ", "　", " "];
const stringChars = ["a", " ", "'", '"', "\\'", '\\"', "\\\\", "\\n", "\\t", "\\v", "\\0", "\\x41", "\\u00e9", "\\uD800",
	"\\\n", "\\\r\n", "\\ ", " ", "\t", "é", "😀", "\\q", "\\1", "\\x4", "\n"];

function ws() {
	let s = "";
	while (chance(0.3)) {
		s += chance(0.15) ? pick(["// c\n", "/* c */", "/** * **/", "//\r"]) : pick(spaces);
	}
	return s;
}

function number() {
	if (chance(0.15)) return pick(["", "+", "-"]) + pick(["Infinity", "NaN"]);
	let s = pick(["", "", "+", "-"]);
	if (chance(0.15)) return s + pick(["0x", "0X"]) + pick(["", "1", "fF", "A0", "g"]);
	s += pick(["0", "1", "42", "007", "", "10"]);
	if (chance(0.4)) s += "." + pick(["", "5", "25"]);
	if (chance(0.3)) s += pick(["e", "E"]) + pick(["", "+", "-"]) + pick(["", "3", "10"]);
	return s;
}

function string() {
	const q = pick(["'", '"']);
	let s = q;
	const n = Math.floor(random() * 5);
	for (let i = 0; i < n; i++) s += pick(stringChars);
	return s + (chance(0.97) ? q : "");
}

function identifier() {
	let s = chance(0.1) ? pick(["\\u0061", "\\u0031", "\\u00e9"]) : pick(letters);
	const n = Math.floor(random() * 4);
	for (let i = 0; i < n; i++) s += chance(0.1) ? pick(["\\u0062", "\\u0020"]) : pick(parts);
	return s;
}

function value(depth) {
	const r = random();
	if (depth > 4 || r < 0.35) {
		return pick([number, number, string, () => pick(["null", "true", "false", "nul", "truex"])])();
	}
	const open = r < 0.65 ? "[" : "{";
	const close = open === "[" ? "]" : "}";
	const items = [];
	const n = Math.floor(random() * 4);
	for (let i = 0; i < n; i++) {
		if (open === "[") items.push(ws() + value(depth + 1) + ws());
		else items.push(ws() + (chance(0.7) ? identifier() : string()) + ws() + ":" + ws() + value(depth + 1) + ws());
	}
	let body = items.join(",");
	if (n > 0 && chance(0.3)) body += ",";
	return open + body + (chance(0.97) ? close : "");
}

const encoder = new TextEncoder();
const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
const tokens = [..."{}[]:,'\"\\/*-+.eExX0123456789 \n"].map((c) => encoder.encode(c))
	.concat([encoder.encode(" "), Uint8Array.of(0xff), Uint8Array.of(0xc0, 0x80), Uint8Array.of(0xed, 0xa0, 0x80), Uint8Array.of(0xe2, 0x82)]);

function mutate(bytes) {
	let b = Array.from(bytes);
	const edits = 1 + Math.floor(random() * 3);
	for (let i = 0; i < edits; i++) {
		const at = Math.floor(random() * (b.length + 1));
		const op = random();
		if (op < 0.4 && b.length > 0) b.splice(Math.min(at, b.length - 1), 1);
		else if (op < 0.8) b.splice(at, 0, ...pick(tokens));
		else if (b.length > 0) b[Math.min(at, b.length - 1)] = pick(tokens)[0];
	}
	return Uint8Array.from(b);
}

function referenceAccepts(bytes) {
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

function json5z(bytes, chunked) {
	if (bytes.length > capacity) throw new Error("input exceeds the wasm buffer");
	new Uint8Array(z.memory.buffer, z.inputBuffer(), bytes.length).set(bytes);
	z.begin();
	let at = 0;
	while (at < bytes.length) {
		const len = chunked ? 1 + Math.floor(random() * Math.min(8, bytes.length - at)) : bytes.length;
		if (z.feed(at, len) !== 0) throw new Error("json5z ran out of stack memory");
		at += len;
	}
	const code = z.finish();
	return { code, offset: code === 0 ? 0 : z.failureOffset() };
}

const show = (bytes) => "`" + Array.from(bytes, (c) => (c >= 0x20 && c < 0x7f && c !== 0x5c ? String.fromCharCode(c) : `\\x${c.toString(16).padStart(2, "0")}`)).join("") + "`";

// Greedy byte deletion while the disagreement persists, for a readable report.
function shrink(bytes, disagrees) {
	let best = bytes;
	for (let progress = true; progress;) {
		progress = false;
		for (let i = 0; i < best.length; i++) {
			const candidate = Uint8Array.from([...best.slice(0, i), ...best.slice(i + 1)]);
			if (disagrees(candidate)) {
				best = candidate;
				progress = true;
				break;
			}
		}
	}
	return best;
}

const count = Number(countArg);
const tally = { accept: 0, reject: 0 };
let cases = 0;
const failures = [];
for (let i = 0; i < count && failures.length < 10; i++) {
	let bytes = encoder.encode(ws() + value(0) + ws());
	if (chance(0.5)) bytes = mutate(bytes);
	const want = referenceAccepts(bytes);
	const whole = json5z(bytes, false);
	const split = json5z(bytes, true);
	tally[want ? "accept" : "reject"]++;
	cases++;
	if (whole.code !== split.code || whole.offset !== split.offset) {
		failures.push(`chunked verdict differs: ${show(bytes)} whole=${JSON.stringify(whole)} split=${JSON.stringify(split)}`);
	} else if ((whole.code === 0) !== want) {
		const small = shrink(bytes, (b) => (json5z(b, false).code === 0) !== referenceAccepts(b));
		failures.push(`reference ${want ? "accepts" : "rejects"}, json5z ${want ? "rejects" : "accepts"}: ${show(bytes)} (shrunk: ${show(small)})`);
	}
}
for (const f of failures) console.log(f);
console.log(`cases=${cases} reference accept=${tally.accept} reject=${tally.reject} failures=${failures.length}`);
// Guards against a vacuous campaign where nearly everything lands on one side.
const vacuous = tally.accept < cases / 10 || tally.reject < cases / 10;
if (vacuous) console.log("campaign is lopsided: fewer than 10% of cases on one side");
process.exit(failures.length > 0 || vacuous ? 1 : 0);
