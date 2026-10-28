// Differential fuzzer for number_range = binary64: json5z (WebAssembly build
// of the core) against JavaScript's own number parsing, which rounds
// correctly. A decimal literal overflows exactly when Number() of it is not
// finite; a hexadecimal one when its BigInt value reaches 2^1024 - 2^970, the
// smallest magnitude that rounds to infinity. Literals cluster around that
// boundary. Under the default (unlimited) every literal must stay valid, with
// a number_range note exactly when it overflows.
//
// Usage: node number_range.mjs WASM SEED COUNT

import { readFileSync } from "node:fs";

const [wasmPath, seedArg, countArg] = process.argv.slice(2);
if (!wasmPath || !seedArg || !countArg) {
	console.error("usage: node number_range.mjs WASM SEED COUNT");
	process.exit(2);
}
const { instance } = await WebAssembly.instantiate(readFileSync(wasmPath));
const z = instance.exports;
const encoder = new TextEncoder();

// mulberry32: small, seedable, deterministic.
let state = Number(seedArg) >>> 0;
function random() {
	state = (state + 0x6d2b79f5) >>> 0;
	let t = state;
	t = Math.imul(t ^ (t >>> 15), t | 1);
	t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
	return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const int = (n) => Math.floor(random() * n);
const pick = (list) => list[int(list.length)];
const chance = (p) => random() < p;

// Digits of the boundary come from BigInt arithmetic here, not from json5z.
const limit = 2n ** 1024n - 2n ** 970n;
const limitDigits = limit.toString();

function digitsNear(source) {
	const take = 1 + int(source.length + 5);
	let d = source.slice(0, Math.min(take, source.length));
	while (d.length < take) d += String(int(10));
	if (chance(0.5)) {
		// Nudge one digit up or down.
		const i = int(d.length);
		const v = (Number(d[i]) + pick([1, 9])) % 10;
		d = d.slice(0, i) + v + d.slice(i + 1);
	}
	if (chance(0.3)) d += "0".repeat(int(5));
	return d.replace(/^0+(?=.)/, "") || "0";
}

function decimal() {
	const digits = chance(0.8) ? digitsNear(limitDigits) : String(1 + int(9)) + "0".repeat(int(4));
	// Place the point, add leading zeros, then choose an exponent that lands
	// the order of magnitude near 309.
	const point = int(digits.length + 1);
	let whole = digits.slice(0, point);
	let fraction = digits.slice(point);
	if (chance(0.3)) {
		fraction = "0".repeat(int(4)) + whole + fraction;
		whole = chance(0.5) ? "0" : "";
	}
	if (whole === "" && fraction === "") whole = "0";
	const order = whole.replace(/^0+/, "").length || -(fraction.match(/^0*/)[0].length);
	let exponent = 309 - order + pick([-1, 0, 0, 0, 1]);
	if (chance(0.1)) exponent = pick([-1e6, 1e6, 99999999999999999999]);
	let s = whole + (fraction !== "" || chance(0.2) ? "." + fraction : "");
	if (s === ".") s = "0.";
	const e = exponent === 0 && chance(0.5) ? "" : pick(["e", "E"]) + (exponent >= 0 && chance(0.3) ? "+" : "") + BigInt(exponent);
	return s + e;
}

function hexadecimal() {
	const top = "FFFFFFFFFFFFFC";
	let d = chance(0.7) ? top.slice(0, 1 + int(top.length)) : (1 + int(15)).toString(16);
	if (chance(0.5)) {
		const i = int(d.length);
		const v = (parseInt(d[i], 16) + pick([1, 15])) % 16;
		d = d.slice(0, i) + v.toString(16) + d.slice(i + 1);
	}
	const length = 256 + pick([-1, 0, 0, 0, 1]);
	while (d.length < length) d += chance(0.7) ? "0" : int(16).toString(16);
	d = d.slice(0, Math.max(length, 1));
	return pick(["0x", "0X"]) + "0".repeat(chance(0.2) ? int(3) : 0) + (chance(0.5) ? d.toLowerCase() : d);
}

function overflows(literal) {
	const unsigned = literal.replace(/^[+-]/, "");
	if (/^0x/i.test(unsigned)) return BigInt(unsigned) >= limit;
	return !Number.isFinite(Number(unsigned));
}

function judge(bytes, binary64) {
	z.setNumberRange(binary64 ? 1 : 0);
	new Uint8Array(z.memory.buffer, z.inputBuffer(), bytes.length).set(bytes);
	z.begin();
	if (z.feed(0, bytes.length) !== 0) throw new Error("json5z ran out of stack memory");
	return { valid: z.finish() === 0, notes: z.numberRangeNotes() };
}

const count = Number(countArg);
const tally = { overflow: 0, finite: 0 };
const failures = [];
for (let i = 0; i < count && failures.length < 10; i++) {
	const literal = pick(["", "", "-", "+"]) + (chance(0.8) ? decimal() : hexadecimal());
	const bytes = encoder.encode(literal);
	if (bytes.length > z.inputCapacity()) continue;
	const want = overflows(literal);
	tally[want ? "overflow" : "finite"]++;
	const strict = judge(bytes, true);
	const loose = judge(bytes, false);
	if (strict.valid === want) failures.push(`binary64 ${want ? "accepts an overflowing" : "rejects a finite"} literal: ${literal}`);
	else if (!loose.valid || loose.notes !== (want ? 1 : 0)) failures.push(`unlimited: valid=${loose.valid} notes=${loose.notes} for ${literal}`);
}
for (const f of failures) console.log(f);
console.log(`number_range cases=${tally.overflow + tally.finite} overflow=${tally.overflow} finite=${tally.finite} failures=${failures.length}`);
const cases = tally.overflow + tally.finite;
const vacuous = tally.overflow < cases / 10 || tally.finite < cases / 10;
if (vacuous) console.log("campaign is lopsided: fewer than 10% of cases on one side");
process.exit(failures.length > 0 || vacuous ? 1 : 0);
