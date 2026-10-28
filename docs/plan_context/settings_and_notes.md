# Settings for ambiguous cases, and notes that report them

Where the JSON5 specification, or the tools around it, allow more than one
reasonable reading, json5z picks a default (docs/plan_context/spec_rulings.md)
and lets the user choose another. Any setting that changes an output is an
input to that output, whether it comes from a file, the environment or a
flag, so json5z reports every setting that affected a result, with its value
and where the value came from.

## Settings

Only rulings that a real implementation or common tooling reads differently
get a setting. The reference library (npm json5 2.2.3) disagrees with ruling 3
alone, and editors disagree with the line-separator ruling. The other rulings
have no known dissenting implementation and stay fixed until one appears.

| Setting | Values (default first) | Affects |
|---|---|---|
| `line_separators` | `end-line`, `same-line` | Positions: whether U+2028 and U+2029 end a line in failure reports, or count as one column on the same line. The grammar treats them as line terminators either way. |
| `astral_identifiers` | `reject`, `accept` | Verdicts: whether unquoted keys may contain letters beyond U+FFFF, raw or as an escaped surrogate pair (rulings 3 and 4 together). |

Columns always count code points (BDFN ruling, 2026-10-28).

Sources, each overriding the one before:

1. Built-in default.
2. Settings file, TOML: `$XDG_CONFIG_HOME/json5z/config.toml`, else
   `$HOME/.config/json5z/config.toml`; on Windows `%APPDATA%\json5z\config.toml`.
   `--config PATH` names a different file. A missing default file is not an
   error; an unreadable or malformed file, or an unknown key or value, is a
   usage error (exit 2), so a typo never silently changes a verdict.
3. Environment: `JSON5Z_LINE_SEPARATORS`, `JSON5Z_ASTRAL_IDENTIFIERS`.
4. Flags: `--line-separators=VALUE`, `--astral-identifiers=VALUE`; a later
   flag overrides an earlier one.

`--print-config` prints the effective settings as a commented TOML file, each
with its source, which doubles as a template.

The TOML parser is tomlc17 (MIT, CK Tan, tag R20260501), compiled into the
CLI only. The Zig core reads no files or environment; settings reach it as an
options value.

## Notes

The core returns, for each setting, how many times its rule changed the result
and the position of the first. A rule changes the result when:

- `line_separators`: a U+2028 or U+2029 precedes a reported failure position
  (in a valid document no position is printed, so there is no note);
- `astral_identifiers`: an unquoted key contains a letter beyond U+FFFF, which
  fails the document under `reject` and is accepted under `accept`. An
  escaped high surrogate in a key is always noted: `reject` fails it at once,
  while `accept` takes it as the first half of a pair and fails later, if at
  all. A character beyond U+FFFF that is not an identifier character, or a
  lone escaped low surrogate, fails at the same place under either value and
  makes no note.

The CLI prints one line per setting per input on stderr, after the verdict
line, naming the value and its source, for example:

```text
json5z: note: config.json5: U+2028 LINE SEPARATOR at line 2, column 9 (byte 41) ended a line (line_separators=end-line, default); 3 more before the failure. Mute with JSON5Z_MUTE_INFO=1.
```

`JSON5Z_MUTE_INFO` (any non-empty value) mutes the stderr notes only. `--json`
output always carries a `notes` array, so a pipeline that discards stderr, or
a muted run, still records which settings shaped each verdict.
