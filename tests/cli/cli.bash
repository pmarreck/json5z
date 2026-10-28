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
# Settings come from the environment and the user's settings file, so the
# tests own both: a private HOME and XDG_CONFIG_HOME, and no inherited JSON5Z_*.
export HOME="$work/home" XDG_CONFIG_HOME="$work/config"
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
for name in "${!JSON5Z_@}"; do unset "$name"; done
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
check "invalid file reports line, column and byte offset" 1 "✗ bad.json5: invalid at line 1, column 4 (byte 3)" ""

run short.json5 </dev/null
check "incomplete file" 1 "✗ short.json5: incomplete, input ended at line 1, column 6 (byte 5)" ""

printf '[\n  1,\n  ,]' >multiline.json5
run multiline.json5 </dev/null
check "lines and columns count from 1" 1 "✗ multiline.json5: invalid at line 3, column 3 (byte 9)" ""

# 70,000 blank lines span the CLI's 64 KiB read chunks.
yes '' | head -n 70000 >long.json5
printf x >>long.json5
run long.json5 </dev/null
check "line counting crosses read chunks" 1 "✗ long.json5: invalid at line 70001, column 1 (byte 70000)" ""

run good.json5 bad.json5 </dev/null
check "any invalid input fails the run" 1 "$(printf '✓ good.json5: valid\n✗ bad.json5: invalid at line 1, column 4 (byte 3)')" ""

run "with space/doc one.json5" </dev/null
check "path with spaces" 0 "✓ with space/doc one.json5: valid" ""

run with\ space/doc\ one.json5 </dev/null
check "path with escaped spaces" 0 "✓ with space/doc one.json5: valid" ""

run - <good.json5
check "stdin via -" 0 "✓ -: valid" ""

run @stdin <bad.json5
check "stdin via @stdin" 1 "✗ -: invalid at line 1, column 4 (byte 3)" ""

run <good.json5
check "stdin when no FILE is given" 0 "✓ -: valid" ""

run -- -dash.json5 </dev/null
check "-- makes a dash-prefixed name a FILE" 0 "✓ -dash.json5: valid" ""

run good.json5 --ascii </dev/null
check "options after files; --ascii" 0 "OK   good.json5: valid" ""

run --simple bad.json5 </dev/null
check "--simple is --ascii" 1 "FAIL bad.json5: invalid at line 1, column 4 (byte 3)" ""

run --json good.json5 bad.json5 short.json5 </dev/null
check "--json emits JSON Lines" 1 "$(printf '%s\n' '{"path":"good.json5","verdict":"valid","notes":[]}' '{"path":"bad.json5","verdict":"invalid","offset":3,"line":1,"column":4,"notes":[]}' '{"path":"short.json5","verdict":"incomplete","offset":5,"line":1,"column":6,"notes":[]}')" ""

run --json "with space/doc one.json5" </dev/null
check "--json path with spaces" 0 '{"path":"with space/doc one.json5","verdict":"valid","notes":[]}' ""

run --quiet bad.json5 </dev/null
check "--quiet prints nothing" 1 "" ""

run --json --quiet good.json5 </dev/null
check "a later output option overrides an earlier one" 0 "" ""

run --quiet --json good.json5 </dev/null
check "and the other way round" 0 '{"path":"good.json5","verdict":"valid","notes":[]}' ""

run missing.json5 </dev/null
check "unreadable input exits 2" 2 "" "json5z: cannot open 'missing.json5': No such file or directory"

run missing.json5 bad.json5 </dev/null
check "trouble outranks an invalid verdict" 2 "✗ bad.json5: invalid at line 1, column 4 (byte 3)" "json5z: cannot open 'missing.json5': No such file or directory"

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


# ---- Settings layers and notes (docs/plan_context/settings_and_notes.md).
mute="Mute with JSON5Z_MUTE_INFO=1."
printf '[\xe2\x80\xa8,]' >ls.json5          # U+2028, then a stray comma
printf '{\xf0\x9d\x90\x80: 1}' >astral.json5 # U+1D400 as an unquoted key
printf '[\xe2\x80\xa81]' >ls-valid.json5

run ls.json5 </dev/null
check "a line separator before a failure is noted with its default" 1 \
	"✗ ls.json5: invalid at line 2, column 1 (byte 4)" \
	"json5z: note: ls.json5: 1 line separator (U+2028/U+2029) before the failure ended a line, first at line 1, column 2 (byte 1); line_separators=end-line (default). $mute"

run ls-valid.json5 </dev/null
check "no note when no position is reported" 0 "✓ ls-valid.json5: valid" ""

run astral.json5 </dev/null
check "an astral key letter is rejected by default, with a note" 1 \
	"✗ astral.json5: invalid at line 1, column 2 (byte 1)" \
	"json5z: note: astral.json5: an identifier character beyond U+FFFF in an unquoted key at line 1, column 2 (byte 1) was rejected; astral_identifiers=reject (default). $mute"

run --astral-identifiers=accept astral.json5 </dev/null
check "a flag selects the other reading" 0 "✓ astral.json5: valid" \
	"json5z: note: astral.json5: 1 identifier character beyond U+FFFF in unquoted keys was accepted, first at line 1, column 2 (byte 1); astral_identifiers=accept (from --astral-identifiers). $mute"

run --line-separators same-line ls.json5 </dev/null
check "flag value as a separate argument" 1 \
	"✗ ls.json5: invalid at line 1, column 3 (byte 4)" \
	"json5z: note: ls.json5: 1 line separator (U+2028/U+2029) before the failure stayed on its line, first at line 1, column 2 (byte 1); line_separators=same-line (from --line-separators). $mute"

JSON5Z_MUTE_INFO=1 run ls.json5 </dev/null
check "JSON5Z_MUTE_INFO mutes notes" 1 "✗ ls.json5: invalid at line 2, column 1 (byte 4)" ""

run --quiet ls.json5 </dev/null
check "--quiet prints no notes either" 1 "" ""

run --json ls.json5 astral.json5 good.json5 </dev/null
check "--json always carries notes" 1 "$(printf '%s\n' \
	'{"path":"ls.json5","verdict":"invalid","offset":4,"line":2,"column":1,"notes":[{"setting":"line_separators","value":"end-line","source":"default","count":1,"first":{"offset":1,"line":1,"column":2}}]}' \
	'{"path":"astral.json5","verdict":"invalid","offset":1,"line":1,"column":2,"notes":[{"setting":"astral_identifiers","value":"reject","source":"default","count":1,"first":{"offset":1,"line":1,"column":2}}]}' \
	'{"path":"good.json5","verdict":"valid","notes":[]}')" ""

JSON5Z_MUTE_INFO=1 run --json ls.json5 </dev/null
check "muting leaves --json notes in place" 1 \
	'{"path":"ls.json5","verdict":"invalid","offset":4,"line":2,"column":1,"notes":[{"setting":"line_separators","value":"end-line","source":"default","count":1,"first":{"offset":1,"line":1,"column":2}}]}' ""

# Environment overrides the settings file; flags override both.
cfgdir="$XDG_CONFIG_HOME/json5z"
mkdir -p "$cfgdir"
printf '# BDFN default reversed for the test\nastral_identifiers = "accept"\n' >"$cfgdir/config.toml"
run astral.json5 </dev/null
check "the settings file applies" 0 "✓ astral.json5: valid" \
	"json5z: note: astral.json5: 1 identifier character beyond U+FFFF in unquoted keys was accepted, first at line 1, column 2 (byte 1); astral_identifiers=accept (from $cfgdir/config.toml). $mute"

JSON5Z_ASTRAL_IDENTIFIERS=reject run astral.json5 </dev/null
check "the environment overrides the file" 1 "✗ astral.json5: invalid at line 1, column 2 (byte 1)" \
	"json5z: note: astral.json5: an identifier character beyond U+FFFF in an unquoted key at line 1, column 2 (byte 1) was rejected; astral_identifiers=reject (from JSON5Z_ASTRAL_IDENTIFIERS). $mute"

JSON5Z_ASTRAL_IDENTIFIERS=reject run --astral-identifiers=reject --astral-identifiers=accept astral.json5 </dev/null
check "a flag overrides the environment, and a later flag an earlier one" 0 "✓ astral.json5: valid" \
	"json5z: note: astral.json5: 1 identifier character beyond U+FFFF in unquoted keys was accepted, first at line 1, column 2 (byte 1); astral_identifiers=accept (from --astral-identifiers). $mute"

run --json astral.json5 </dev/null
check "--json names the file a setting came from" 0 \
	"{\"path\":\"astral.json5\",\"verdict\":\"valid\",\"notes\":[{\"setting\":\"astral_identifiers\",\"value\":\"accept\",\"source\":\"file\",\"from\":\"$cfgdir/config.toml\",\"count\":1,\"first\":{\"offset\":1,\"line\":1,\"column\":2}}]}" ""

printf 'line_separators = "same-line"\n' >"other config.toml"
run --config "other config.toml" ls.json5 </dev/null
check "--config names another file, spaces allowed" 1 "✗ ls.json5: invalid at line 1, column 3 (byte 4)" \
	"json5z: note: ls.json5: 1 line separator (U+2028/U+2029) before the failure stayed on its line, first at line 1, column 2 (byte 1); line_separators=same-line (from other config.toml). $mute"

# Mistakes in settings are usage errors, never silently ignored.
printf 'astral_identifier = "accept"\n' >typo.toml
run --config typo.toml good.json5 </dev/null
check "unknown setting" 2 "" "json5z: typo.toml: unknown setting 'astral_identifier'"

printf 'astral_identifiers = "maybe"\n' >value.toml
run --config value.toml good.json5 </dev/null
check "unknown value in a file" 2 "" "json5z: value.toml: astral_identifiers must be \"reject\" or \"accept\", not \"maybe\""

printf 'astral_identifiers = true\n' >type.toml
run --config type.toml good.json5 </dev/null
check "wrong type in a file" 2 "" "json5z: type.toml: astral_identifiers must be a string"

printf 'astral_identifiers = \n' >broken.toml
run --config broken.toml good.json5 </dev/null
if [ "$rc" = 2 ] && [ -z "$out" ] && [[ "$err" == "json5z: broken.toml: "* ]]; then
	passes=$((passes + 1))
else
	failures=$((failures + 1))
	printf 'FAIL malformed TOML: rc=%s out=%q err=%q\n' "$rc" "$out" "$err"
fi

run --config missing.toml good.json5 </dev/null
check "a named settings file must exist" 2 "" "json5z: cannot open settings file 'missing.toml': No such file or directory"

JSON5Z_LINE_SEPARATORS=sideways run good.json5 </dev/null
check "unknown value in the environment" 2 "" "json5z: JSON5Z_LINE_SEPARATORS must be \"end-line\" or \"same-line\", not \"sideways\""

run --line-separators=sideways good.json5 </dev/null
check "unknown value in a flag" 2 "" "json5z: --line-separators must be \"end-line\" or \"same-line\", not \"sideways\""

run good.json5 --line-separators </dev/null
check "a flag missing its value" 2 "" "json5z: --line-separators needs a value (try --help)"

JSON5Z_ASTRAL_IDENTIFIERS=reject run --print-config </dev/null
check "--print-config shows effective settings and sources as TOML" 0 "$(cat <<EOF
# json5z settings (TOML). Sources override in this order: default,
# settings file, environment (JSON5Z_*), flags. Values below are in effect.
# Settings file: $cfgdir/config.toml

# Whether U+2028 and U+2029 end a line in reported positions:
# "end-line" or "same-line". Source: default.
line_separators = "end-line"

# Whether unquoted keys may contain letters beyond U+FFFF, raw or as
# escaped surrogate pairs: "reject" or "accept". Source: JSON5Z_ASTRAL_IDENTIFIERS.
astral_identifiers = "reject"

# Whether a \\uXXXX escape may spell a letter of null, true, false,
# Infinity or NaN: "reject" or "accept". Source: default.
escaped_literals = "reject"

# Whether a number that rounds to infinity in IEEE 754 binary64 is
# rejected: "unlimited" or "binary64". Source: default.
number_range = "unlimited"

# The deepest nesting allowed, counting each open array or object:
# "unlimited" or a positive integer. Source: default.
max_depth = "unlimited"
EOF
)" ""

printf '[n\\u0075ll, 1e400, [[1]]]' >rulings.json5
run rulings.json5 </dev/null
check "escaped literals are rejected by default" 1 "✗ rulings.json5: invalid at line 1, column 3 (byte 2)" \
	"json5z: note: rulings.json5: a Unicode escape in a literal at line 1, column 3 (byte 2) was rejected; escaped_literals=reject (default). $mute"

run --escaped-literals=accept rulings.json5 </dev/null
check "accepted escapes and huge numbers are noted" 0 "✓ rulings.json5: valid" \
	"$(printf '%s\n' "json5z: note: rulings.json5: 1 Unicode escape in literals was read as a letter, first at line 1, column 3 (byte 2); escaped_literals=accept (from --escaped-literals). $mute" \
		"json5z: note: rulings.json5: 1 number that rounds to infinity in binary64 was accepted, first at line 1, column 13 (byte 12); number_range=unlimited (default). $mute")"

JSON5Z_NUMBER_RANGE=binary64 run --escaped-literals=accept rulings.json5 </dev/null
check "number_range from the environment" 1 "✗ rulings.json5: invalid at line 1, column 13 (byte 12)" \
	"$(printf '%s\n' "json5z: note: rulings.json5: 1 Unicode escape in literals was read as a letter, first at line 1, column 3 (byte 2); escaped_literals=accept (from --escaped-literals). $mute" \
		"json5z: note: rulings.json5: a number at line 1, column 13 (byte 12) rounds to infinity in binary64 and was rejected; number_range=binary64 (from JSON5Z_NUMBER_RANGE). $mute")"

run --escaped-literals=accept --max-depth=2 --json rulings.json5 </dev/null
check "max_depth limits nesting; --json lists every note" 1 \
	'{"path":"rulings.json5","verdict":"invalid","offset":20,"line":1,"column":21,"notes":[{"setting":"escaped_literals","value":"accept","source":"flag","from":"--escaped-literals","count":1,"first":{"offset":2,"line":1,"column":3}},{"setting":"number_range","value":"unlimited","source":"default","count":1,"first":{"offset":12,"line":1,"column":13}},{"setting":"max_depth","value":2,"source":"flag","from":"--max-depth","count":1,"first":{"offset":20,"line":1,"column":21}}]}' ""

run --escaped-literals=accept --max-depth 2 rulings.json5 </dev/null
check "max_depth note" 1 "✗ rulings.json5: invalid at line 1, column 21 (byte 20)" \
	"$(printf '%s\n' "json5z: note: rulings.json5: 1 Unicode escape in literals was read as a letter, first at line 1, column 3 (byte 2); escaped_literals=accept (from --escaped-literals). $mute" \
		"json5z: note: rulings.json5: 1 number that rounds to infinity in binary64 was accepted, first at line 1, column 13 (byte 12); number_range=unlimited (default). $mute" \
		"json5z: note: rulings.json5: nesting deeper than 2 at line 1, column 21 (byte 20) was rejected; max_depth=2 (from --max-depth). $mute")"

printf 'max_depth = 3\n' >depth.toml
run --config depth.toml --print-config </dev/null
check "an integer setting in the file" 0 "$(cat <<EOT
# json5z settings (TOML). Sources override in this order: default,
# settings file, environment (JSON5Z_*), flags. Values below are in effect.
# Settings file: depth.toml

# Whether U+2028 and U+2029 end a line in reported positions:
# "end-line" or "same-line". Source: default.
line_separators = "end-line"

# Whether unquoted keys may contain letters beyond U+FFFF, raw or as
# escaped surrogate pairs: "reject" or "accept". Source: default.
astral_identifiers = "reject"

# Whether a \\uXXXX escape may spell a letter of null, true, false,
# Infinity or NaN: "reject" or "accept". Source: default.
escaped_literals = "reject"

# Whether a number that rounds to infinity in IEEE 754 binary64 is
# rejected: "unlimited" or "binary64". Source: default.
number_range = "unlimited"

# The deepest nesting allowed, counting each open array or object:
# "unlimited" or a positive integer. Source: depth.toml.
max_depth = 3
EOT
)" ""

for bad in 0 -1 1x '' ' 2'; do
	run --max-depth="$bad" good.json5 </dev/null
	check "max_depth rejects '$bad'" 2 "" "json5z: --max-depth must be \"unlimited\" or a positive integer, not \"$bad\""
done
run --max-depth=unlimited good.json5 </dev/null
check "max_depth unlimited" 0 "✓ good.json5: valid" ""
printf 'max_depth = 0\n' >depth0.toml
run --config depth0.toml good.json5 </dev/null
check "max_depth 0 in a file" 2 "" "json5z: depth0.toml: max_depth must be \"unlimited\" or a positive integer, not 0"

run --config - bad.json5 <<<'number_range = "binary64"'
check "--config - reads settings from stdin" 1 "✗ bad.json5: invalid at line 1, column 4 (byte 3)" ""
run --config @stdin - </dev/null
check "settings and a document cannot share stdin" 2 "" "json5z: the settings file and a document cannot both come from standard input"
cd "$root" || exit 1
# The scratch directory lives under TMPDIR, which build-budget cleans.
printf 'cli: %d passed, %d failed\n' "$passes" "$failures"
[ "$failures" -eq 0 ]
