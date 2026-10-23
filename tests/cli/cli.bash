#!/usr/bin/env bash
# CLI contract tests for zig-out/bin/json5z. Run from the project root inside
# `nix develop` after `zig build` (./test does both). Each case captures
# stdout, stderr and the exit status and asserts on all three.
set -u

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bin="$root/zig-out/bin/json5z"
work="$(mktemp -d "${TMPDIR:-/tmp}/json5z-cli.XXXXXX")"
export MUTE_DEBUG_STATUS=1
unset NO_COLOR
passes=0
failures=0

# run ARGS...: sets out, err and rc; stdin comes from the caller.
run() {
	out="$("$bin" "$@" 2>"$work/stderr")"
	rc=$?
	err="$(cat "$work/stderr")"
}

check() {
	local name="$1" want_rc="$2" want_out="$3" want_err="$4"
	if [ "$rc" = "$want_rc" ] && [ "$out" = "$want_out" ] && [ "$err" = "$want_err" ]; then
		passes=$((passes + 1))
	else
		failures=$((failures + 1))
		printf 'FAIL %s\n  rc:  want %s, got %s\n  out: want %q\n       got  %q\n  err: want %q\n       got  %q\n' \
			"$name" "$want_rc" "$rc" "$want_out" "$out" "$want_err" "$err"
	fi
}

printf '{a: 1, b: [true, null,],}' >"$work/good.json5"
printf '[1,,2]' >"$work/bad.json5"
printf '{a: 1' >"$work/short.json5"
mkdir -p "$work/with space"
printf "'ok'" >"$work/with space/doc one.json5"
printf '[]' >"$work/-dash.json5"

cd "$work" || exit 1

run good.json5 </dev/null
check "valid file" 0 "✓ good.json5: valid" ""

run bad.json5 </dev/null
check "invalid file reports the byte offset" 1 "✗ bad.json5: invalid at byte 3" ""

run short.json5 </dev/null
check "incomplete file" 1 "✗ short.json5: incomplete, input ended at byte 5" ""

run good.json5 bad.json5 </dev/null
check "any invalid input fails the run" 1 "$(printf '✓ good.json5: valid\n✗ bad.json5: invalid at byte 3')" ""

run "with space/doc one.json5" </dev/null
check "path with spaces" 0 "✓ with space/doc one.json5: valid" ""

run with\ space/doc\ one.json5 </dev/null
check "path with escaped spaces" 0 "✓ with space/doc one.json5: valid" ""

run - <good.json5
check "stdin via -" 0 "✓ -: valid" ""

run @stdin <bad.json5
check "stdin via @stdin" 1 "✗ -: invalid at byte 3" ""

run <good.json5
check "stdin when no FILE is given" 0 "✓ -: valid" ""

run -- -dash.json5 </dev/null
check "-- makes a dash-prefixed name a FILE" 0 "✓ -dash.json5: valid" ""

run good.json5 --ascii </dev/null
check "options after files; --ascii" 0 "OK   good.json5: valid" ""

run --simple bad.json5 </dev/null
check "--simple is --ascii" 1 "FAIL bad.json5: invalid at byte 3" ""

run --json good.json5 bad.json5 short.json5 </dev/null
check "--json emits JSON Lines" 1 "$(printf '%s\n' '{"path":"good.json5","verdict":"valid"}' '{"path":"bad.json5","verdict":"invalid","offset":3}' '{"path":"short.json5","verdict":"incomplete","offset":5}')" ""

run --json "with space/doc one.json5" </dev/null
check "--json path with spaces" 0 '{"path":"with space/doc one.json5","verdict":"valid"}' ""

run --quiet bad.json5 </dev/null
check "--quiet prints nothing" 1 "" ""

run --json --quiet good.json5 </dev/null
check "a later output option overrides an earlier one" 0 "" ""

run --quiet --json good.json5 </dev/null
check "and the other way round" 0 '{"path":"good.json5","verdict":"valid"}' ""

run missing.json5 </dev/null
check "unreadable input exits 2" 2 "" "json5z: cannot open 'missing.json5': No such file or directory"

run missing.json5 bad.json5 </dev/null
check "trouble outranks an invalid verdict" 2 "✗ bad.json5: invalid at byte 3" "json5z: cannot open 'missing.json5': No such file or directory"

run --bogus </dev/null
check "unknown option exits 2" 2 "" "json5z: unknown option '--bogus' (try --help)"

run --help </dev/null
if [ "$rc" = 0 ] && [[ "$out" == "Usage: json5z [OPTIONS] [FILE ...]"* ]] && [ -z "$err" ]; then
	passes=$((passes + 1))
else
	failures=$((failures + 1))
	printf 'FAIL --help: rc=%s out=%q err=%q\n' "$rc" "$out" "$err"
fi
help_text="$out"

run -h </dev/null
check "-h is --help" 0 "$help_text" ""

run '/?' </dev/null
check "/? is --help" 0 "$help_text" ""

run --about </dev/null
about="$out"
if [ "$rc" = 0 ] && [ "$(printf '%s\n' "$about" | wc -l)" = 1 ] &&
	[[ "$about" =~ ^json5z\ [0-9]+\.[0-9]+\.[0-9]+:\ spec-accurate\ JSON5\ validator\ \([a-z0-9_]+-[a-z]+,\ [A-Za-z]+\ build\)$ ]]; then
	passes=$((passes + 1))
else
	failures=$((failures + 1))
	printf 'FAIL --about: rc=%s out=%q\n' "$rc" "$about"
fi

# Output is never colored when stdout is not a terminal, as here.
run good.json5 </dev/null
case "$out" in
*$'\e'*) failures=$((failures + 1)); echo "FAIL ANSI escape in non-terminal output" ;;
*) passes=$((passes + 1)) ;;
esac

# Debug builds announce themselves on stderr unless MUTE_DEBUG_STATUS is set.
err="$(env -u MUTE_DEBUG_STATUS "$bin" good.json5 2>&1 >/dev/null </dev/null)"
case "$about" in
*", Debug build)") want=$'\e[33mDEBUG BUILD\e[0m' ;;
*) want="" ;;
esac
if [ "$err" = "$want" ]; then
	passes=$((passes + 1))
else
	failures=$((failures + 1))
	printf 'FAIL debug banner: want %q, got %q\n' "$want" "$err"
fi

cd "$root" || exit 1
# The scratch directory lives under TMPDIR, which build-budget cleans.
printf 'cli: %d passed, %d failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
