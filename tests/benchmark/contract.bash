#!/usr/bin/env bash
# Cheap acceptance checks for the json5z/cj5 benchmark (./bm), run by ./test
# inside `nix develop`. They do not time anything. They check that:
#   - the benchmark binary is an optimized build and says so;
#   - every workload is valid JSON5 according to the reference library (npm
#     json5), which shares no code with json5z or the generator;
#   - json5z and upstream cj5 both accept every workload, and both reject a
#     corrupted copy, so the benchmark's verdict check can fail;
#   - a measurement emits the performance-measurement/v1 protocol;
#   - ./bm refuses to run with the debug banner muted.
set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root" || exit 1
bench="$root/zig-out/bench/json5z-bench"
work="$(mktemp -d "${TMPDIR:-/tmp}/json5z-bench-contract.XXXXXX")"
passes=0
failures=0

pass() { passes=$((passes + 1)); }
fail() {
	failures=$((failures + 1))
	printf 'FAIL %s\n' "$*"
}

if [ -z "${JSON5_REFERENCE:-}" ]; then
	echo "contract: JSON5_REFERENCE is unset; run inside nix develop" >&2
	exit 1
fi
unset MUTE_DEBUG_STATUS

zig build bench >"$work/build.log" 2>&1 || {
	cat "$work/build.log"
	fail "zig build bench"
	exit 1
}

# The binary reports how it was built; refuse anything but an optimized build.
about="$("$bench" about 2>"$work/about.err")"
rc=$?
if [ "$rc" = 0 ] && [ "$about" = '{"build_mode":"ReleaseFast","c_optimized":true}' ] && [ ! -s "$work/about.err" ]; then
	pass
else
	fail "about: rc=$rc out=$about err=$(cat "$work/about.err")"
fi

# check_kind KIND SIZE: verdicts from both implementations, and the reference
# library on the same bytes, intact and corrupted.
check_kind() {
	local kind="$1" size="$2" verdicts want
	verdicts="$("$bench" verdicts "$kind" "$size" 7 2>"$work/verdicts.err")"
	want='{"json5z":"valid","cj5":"valid","corrupt_json5z":"invalid","corrupt_cj5":"invalid","truncated_json5z":"incomplete","truncated_cj5":"incomplete"}'
	if [ "$verdicts" = "$want" ] && [ ! -s "$work/verdicts.err" ]; then
		pass
	else
		fail "verdicts $kind: got $verdicts $(cat "$work/verdicts.err")"
	fi
	"$bench" emit "$kind" "$size" 7 >"$work/$kind.json5" 2>"$work/emit.err"
	if [ "$(wc -c <"$work/$kind.json5")" -ge "$size" ] && [ ! -s "$work/emit.err" ]; then
		pass
	else
		fail "emit $kind: $(wc -c <"$work/$kind.json5") bytes, err $(cat "$work/emit.err")"
	fi
	if node tests/benchmark/reference_check.mjs "$work/$kind.json5" >"$work/ref.out" 2>&1; then
		pass
	else
		fail "reference json5 on $kind: $(cat "$work/ref.out")"
	fi
}

for kind in config nested strings numbers comments; do
	check_kind "$kind" 65536
done
check_kind deep 4096

# The same seed gives the same bytes; a different seed gives different bytes.
a="$("$bench" emit config 65536 7 | sha256sum)"
b="$("$bench" emit config 65536 7 | sha256sum)"
c="$("$bench" emit config 65536 8 | sha256sum)"
if [ "$a" = "$b" ] && [ "$a" != "$c" ]; then pass; else fail "emit is not deterministic per seed"; fi

# A measurement in the engine's protocol, with every size, metric and impl.
for impl in json5z cj5-presized cj5-two-pass; do
	"$bench" measure "$impl" numbers 65536,131072 3 >"$work/m.json" 2>"$work/m.err"
	rc=$?
	if [ "$rc" = 0 ] && [ ! -s "$work/m.err" ] && node -e '
		const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
		const ok = m.schema === "performance-measurement/v1" && m.correct === true &&
			m.build_mode === "ReleaseFast" && m.impl === process.argv[2] &&
			m.rows.length === 2 && m.rows[0].size === 65536 && m.rows[1].size === 131072 &&
			m.rows.every(r => ["cpu_ns", "wall_ns", "peak_bytes", "allocation_count", "total_bytes", "operations"]
				.every(k => r.samples[k].length >= 3 && r.samples[k].every(v => Number.isInteger(v) && v > 0)) &&
				r.residual_bytes.length >= 3 && r.residual_bytes.every(v => v === 0) &&
				r.samples.operations.every(v => v === r.bytes));
		process.exit(ok ? 0 : 1);' "$work/m.json" "$impl"; then
		pass
	else
		fail "measure $impl: rc=$rc err=$(cat "$work/m.err") out=$(head -c 400 "$work/m.json")"
	fi
done

# Unknown arguments are usage errors, not measurements.
"$bench" measure nope config 65536 1 >"$work/u.out" 2>"$work/u.err"
rc=$?
if [ "$rc" = 2 ] && [ ! -s "$work/u.out" ] && grep -q 'unknown implementation' "$work/u.err"; then pass; else fail "unknown impl: rc=$rc"; fi

# ./bm must never measure with the debug banner suppressed.
MUTE_DEBUG_STATUS=1 ./bm >"$work/bm.out" 2>"$work/bm.err"
rc=$?
if [ "$rc" = 2 ] && [ ! -s "$work/bm.out" ] && grep -q 'MUTE_DEBUG_STATUS' "$work/bm.err"; then pass; else fail "bm with MUTE_DEBUG_STATUS: rc=$rc"; fi

printf 'benchmark contract: %d passed, %d failed\n' "$passes" "$failures"
if [ "$failures" = 0 ]; then mv "$work" "$HOME/.Trash/" 2>/dev/null; fi
[ "$failures" = 0 ]
