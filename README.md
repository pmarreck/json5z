# json5z

json5z validates [JSON5](https://spec.json5.org/) documents against the
specification. It is being written in Zig: a core with no I/O, a C FFI and a
small C command-line tool that calls the core through that FFI. The validator
reads its input once and keeps only a stack of open containers, so memory
grows with nesting depth, not document size, and it never builds tokens or
values.

## Status

Early. The Zig validator is not written yet. Until it is, the library is an
interim C parser derived from cj5 (described below), with its tests and the
controls that will check json5z (`./test`, `./mutate`). Open work is in
[PLAN.md](PLAN.md).

## How correctness is checked

1. The official JSON5 conformance suite
   ([json5/json5-tests](https://github.com/json5/json5-tests)) is the source
   of truth.
2. Unmodified upstream cj5 ([septag/cj5](https://github.com/septag/cj5) at
   `5fe4821`) is a degraded oracle: an independent JSON5 parser that json5z
   is expected to beat on both accuracy and speed. Every disagreement between
   json5z and upstream cj5 must be a recorded cj5 defect. Only septag's
   code qualifies; our modified copy is not independent of us.
3. Seeded fuzzing and mutation testing (`./mutate`) show the tests catch
   deliberate bugs and that no run can hang.

Run everything with `./test`.

## The interim parser: modified cj5

The `cj5.h`, `cj5.c` and `cj5.zig` files come from
[septag/cj5](https://github.com/septag/cj5) (MIT, copyright Sepehr
Taghdisian). They carry our grammar fixes and a validate-only mode, so they
are our code, not an oracle. They serve as the library until the Zig
validator replaces them. `tests/oracle/` holds a frozen copy of the modified
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

