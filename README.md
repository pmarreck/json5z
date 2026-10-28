# json5z

json5z validates [JSON5](https://spec.json5.org/) documents against the
specification. It is being written in Zig: a core with no I/O, a C FFI and a
small C command-line tool that calls the core through that FFI. The validator
reads its input once and keeps only a stack of open containers, so memory
grows with nesting depth, not document size, and it never builds tokens or
values.

## Status

json5z gets every case in the test corpora right. The two other parsers
measured against the same cases do not:

| Corpus | json5z | reference json5 (npm 2.2.3) | upstream cj5 (`5fe4821`) |
|---|---|---|---|
| Spec-derived cases (687) | 0 wrong | 0 wrong | 272 wrong |
| Cases mined from other parsers' bugs (84) | 0 wrong | 1 wrong | 32 wrong |
| Rulings on ambiguous inputs (22) | 0 wrong | 5 wrong | 6 wrong |
| Official conformance suite (114) | 0 wrong | not measured | 51 wrong |

The reference library's six misses come from two causes. It ships Unicode 10
identifier tables, so it rejects letters added later, such as U+1C90 from
Unicode 11. It also reads source by code point, so it accepts characters
beyond U+FFFF in unquoted keys, which the rulings reject (see
[the rulings](docs/plan_context/spec_rulings.md)). upstream cj5's misses are
recorded case by case in `tests/ledgers/`. json5z also agrees with the
reference library on every input of the differential fuzz campaign in
`./test`, apart from the ruled cases, which the fuzzer does not generate. An interim C parser derived from cj5 (described below) remains in
the build until its last consumer moves to json5z. Open work is in
[PLAN.md](PLAN.md).

## Usage

```sh
zig build                      # library, header and CLI under zig-out/
zig-out/bin/json5z config.json5 other.json5
zig-out/bin/json5z --json - < config.json5
```

The CLI exits 0 when every input is valid, 1 when any is invalid or
incomplete, and 2 for usage errors, unreadable input or no verdict. Failures
report where the first character that cannot continue a valid document sits:
its line and column, both from 1, and its byte offset. Columns count code
points; lines end at LF, CR, CR LF, U+2028 and U+2029, JSON5's line
terminators.

```text
✗ config.json5: invalid at line 3, column 3 (byte 9)
```

See `json5z --help`.

Where the specification leaves a reading open, json5z follows a documented
ruling by default ([the rulings](docs/plan_context/spec_rulings.md)) and
lets you choose the other reading, from a TOML settings file
(`$XDG_CONFIG_HOME/json5z/config.toml` or `--config PATH`), environment
variables or flags, each overriding the one before:

| Setting | Values (default first) |
|---|---|
| `line_separators` | `end-line`, `same-line`: whether U+2028 and U+2029 end a line in reported positions |
| `astral_identifiers` | `reject`, `accept`: letters beyond U+FFFF in unquoted keys |
| `escaped_literals` | `reject`, `accept`: `\uXXXX` escapes spelling `null`, `true`, `false`, `Infinity` or `NaN` |
| `number_range` | `unlimited`, `binary64`: whether numbers that round to infinity in IEEE 754 binary64 fail |
| `max_depth` | `unlimited`, or a positive integer: the deepest nesting allowed |

A setting is an input to every result it changes, so json5z says so. When a
setting decided a verdict or a reported position, a note on stderr names the
setting, its value and where the value came from:

```text
✗ data.json5: invalid at line 1, column 13 (byte 12)
json5z: note: data.json5: a number at line 1, column 13 (byte 12) rounds to infinity in binary64 and was rejected; number_range=binary64 (from JSON5Z_NUMBER_RANGE). Mute with JSON5Z_MUTE_INFO=1.
```

`--json` output always includes the notes, muted or not, and
`json5z --print-config` prints the settings in effect, with their sources,
as a commented TOML file ([design](docs/plan_context/settings_and_notes.md)).

From C, include `json5z.h` and link `libjson5z.a`:

```c
json5z_location where; /* offset, line, column */
json5z_notes notes;    /* which settings decided the result */
int status = json5z_validate(data, length, NULL /* default options */, &where, &notes);
```

`json5z_validator_create`, `json5z_validator_feed` and
`json5z_validator_finish` validate a document in chunks of any size.
`json5z_options` selects the readings above; a zeroed struct is the default. From Zig, depend on this package
and import the `json5z` module (`json5z.validate`, `json5z.check` for options and notes, or `json5z.Validator`).

## Performance

Against unmodified upstream cj5 on 32 MiB documents (one core of an AMD
Ryzen Threadripper 3990X; method and full results in
[the benchmark notes](docs/plan_context/benchmark_cj5.md)), json5z validates
at 133 to 215 MB/s and needs 136 bytes for any flat document, whatever its
size. cj5 needs a 32-byte token for every value, up to 264 MiB for these
documents. Given a token array of exactly the right size, cj5 is currently
faster: 2x on config and number workloads and 6 to 7x on string and comment
workloads, whose bodies it skips without checking UTF-8 or escapes. A caller
that must count tokens first, then allocate and parse, is slower than json5z
on the config, nested and number workloads. cj5's time grows with the square
of nesting depth: 64 KiB of nested arrays takes it 1.1 s and json5z 0.5 ms.
Closing the remaining gap is open work in [PLAN.md](PLAN.md). Run `./bm` and
`./mg` to measure.

## How correctness is checked

The [JSON5 1.0 specification](https://spec.json5.org/) is the source of
truth. No single test corpus covers it, so several independent checks are
combined:

1. A spec-derived corpus (`tests/spec_cases/`): 687 cases written from the
   JSON5 1.0 and ECMAScript 5.1 grammars alone, each citing the production
   that decides it, by an author who did not read json5z's source; 84 cases
   mined from other JSON5 parsers' bug reports; and 22 cases recording BDFN
   (Benevolent Dictator For Now) rulings on inputs the specification leaves
   ambiguous ([reasons](docs/plan_context/spec_rulings.md)). Results are in
   the table above.
2. The official JSON5 conformance suite
   ([json5/json5-tests](https://github.com/json5/json5-tests)). It has only
   114 cases and leaves many grammar rules with one example or none, so
   passing it is a minimum, not proof of spec accuracy.
3. Differential fuzzing against the reference JavaScript implementation
   (npm `json5`), including inputs split into random chunks.
4. Unmodified upstream cj5 ([septag/cj5](https://github.com/septag/cj5) at
   `5fe4821`) as a degraded oracle: an independent JSON5 parser that json5z
   is expected to beat on both accuracy and speed. Every disagreement between
   json5z and upstream cj5 must be a recorded cj5 defect. Only septag's
   code qualifies; our modified copy is not independent of us.
5. Mutation testing (`./mutate`) shows the tests catch deliberate bugs and
   that no run can hang.


Run everything with `./test`.

## The interim parser: modified cj5

The files in `interim/cj5_modified/` come from
[septag/cj5](https://github.com/septag/cj5) (MIT, copyright Sepehr
Taghdisian). They carry our grammar fixes and a validate-only mode, so they
are our code, not an oracle. They serve as the library until the Zig
validator replaces them, and then the directory is deleted. Its
`tests/oracle/` holds a frozen copy of the modified
parser from before the validate-only mode, used only as a refactoring
regression check. cj5's original documentation follows.

Very minimal single header JSON5 parser in C99, derived from [jsmn](https://github.com/zserge/jsmn)

### What is json 5
It is just a less strict standard JSON, which is easier to read and write as well ass some nice added features, for more info see [JSON5](https://json5.org/). Some Json5 features maybe incomplete or not working properly, but currently the features are tested:
- Object keys may be an ECMAScript 5.1 IdentifierName.
- Objects may have a single trailing comma.
- Strings may be single quoted.
- Strings may span multiple lines by escaping new line characters.
- Strings may include character escapes.
- Numbers may be hexadecimal.
- Numbers may have a leading or trailing decimal point.
- Numbers may be IEEE 754 positive infinity, negative infinity, and NaN.
- Numbers may begin with an explicit plus sign.
- Single and multi-line comments are allowed.
- Additional white space characters are allowed.
- Multiline comments are allowed


### Features
- No memory allocations. All allocatrions are managed on the user side
- Fast and Minimal. 
- standard C library functions (memory,string functions) can be overriden
- Easy to use API (one function to parse)
- Portable C API
- Helper functions to use parsed data in DOM manner

### Usage
The main function to parse json is `cj5_parse`. like jsmn, you provide all tokens to be filled as an array and provide the maximum count
The result will be return in `cj5_result` struct, and `num_tokens` will represent the actual token count that is parsed.  
In case of errors, cj_result.error will be set to an error code. Here's a quick example of the usage, first define CJ5_IMPLEMENT to include the implementation:

```c  
        #define CJ5_IMPLEMENT
        #include "cj5.h"

        cj5_token tokens[32];
        cj5_result r = cj5_parse(g_json, (int)strlen(g_json), tokens, 32);
        
        if (r.error != CJ5_ERROR_NONE) {
            if (r.error == CJ5_ERROR_OVERFLOW) {
                // you can use r.num_tokens to determine the actual token count and reparse
                printf("Error: line: %d, col: %d\n", r.error_line, r.error_code);    
            }
        } else {
            // use token helper functions (see below) to access the values 
            float my_num = cj5_seekget_float(&r, 0, "my_num", 0 /* default value if not found*/ );
        } 
```

**NOTE**: Unlike _jsmn_, if number of parsed tokens exceeds the provided ones, parser doesn't return immediately with an error.
          But parses the JSON to the end, counts all needed tokens and returns with an CJ5_ERROR_OVERFLOW, so the user can 
          choose to reparse the json with new memory requirements.

### Links
- [jsmn](https://github.com/zserge/jsmn): Jsmn is a world fastest JSON parser/tokenizer. This is the official repo replacing the old one at Bitbucket
- [sjson](https://github.com/septag/sjson): Fast and portable C single header json Encoder/Decoder


[License (MIT)](https://github.com/septag/cj5/blob/master/LICENSE)
--------------------------------------------------------------------------

<a href="http://opensource.org/licenses/MIT" target="_blank">
<img align="right" src="http://opensource.org/trademarks/opensource/OSI-Approved-License-100x137.png">

