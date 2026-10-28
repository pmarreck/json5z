# PLAN log

Completed PLAN.md items retired by plan-retire, oldest retirement first.

## Retired 2026-10-21

- [x] [Upstream sync (requested by validate)] Merge upstream septag/cj5 5fe4821 (token factory, short-primitive memcpy fix) into master, porting fork fixes to `parser.tokens` (done 2026-10-14 16:55 EDT, f7b960a)
- [x] [Upstream sync (requested by validate)] Refresh flake inputs (nixpkgs 2026-10-10, Zig 0.16.0) and pass `zig build test` plus `nix flake check` (done 2026-10-14 16:55 EDT, f7b960a)
- [x] [Upstream sync (requested by validate)] Push master and reply to validate's inbox with the pushed SHA (done 2026-10-14 17:05 EDT, f7b960a)
- [x] [Large-document validity (requested by validate)] Add uncapped `validateAll` (allocator-grown tokens, byte offset of first error) and stop `isValid`/`validate` reporting overflow as valid (done 2026-10-14 17:35 EDT)

## Retired 2026-10-23

- [x] [Large-document validity (requested by validate)] Reply to validate with the pushed SHA and the new API shape (done 2026-10-14 17:38 EDT, 3a32d25)
- [x] [Large-document validity (requested by validate)] Add a validate-only cj5 path with O(depth) state (no token storage), proven against a frozen pre-refactor parser by differential corpus and fuzz tests; repoint validateAll/isValid at it (done 2026-10-18 23:40 EDT)
- [x] [Large-document validity (requested by validate)] Bound the `}` parent walk so a corrupt chain ends with no verdict instead of spinning; add ./mutate with per-mutant timeouts (done 2026-10-18 23:40 EDT)
- [x] [Housekeeping] Add a `./test` entry point that runs `zig build test`, ./mutate and the flake check (done 2026-10-18 23:40 EDT)
- [x] [Large-document validity (requested by validate)] Tell validate that validateAll now uses memory proportional to nesting depth (done 2026-10-18 23:45 EDT, dd955d2)
- [x] [Become json5z (spec-accurate JSON5 validation)] Record the json5z decision and goals (context: docs/plan_context/json5z.md) (done 2026-10-21 14:10 EDT)
- [x] [Become json5z (spec-accurate JSON5 validation)] BDFN renames the project directory to json5z; then rename the branch to yolo, update README, build.zig.zon name and flake pname (done 2026-10-21 14:15 EDT)
- [x] [Become json5z (spec-accurate JSON5 validation)] Create GitHub pmarreck/json5z (not a fork) and push yolo (done 2026-10-21 14:18 EDT)
- [x] [Become json5z (spec-accurate JSON5 validation)] Quarantine the modified cj5 and its refactoring check under interim/cj5_modified (done 2026-10-21 14:55 EDT)
- [x] [Become json5z (spec-accurate JSON5 validation)] Ask validate to switch its dependency from pmarreck/cj5 to pmarreck/json5z (done 2026-10-21 14:40 EDT, 03b88d8)
- [x] [Become json5z (spec-accurate JSON5 validation)] After validate switched (validate 40ec7df70), archive GitHub pmarreck/cj5 so old validate commits stay buildable (done 2026-10-23 11:27 EDT)

## Retired 2026-10-24

- [x] [Become json5z (spec-accurate JSON5 validation)] Vendor unmodified septag/cj5 5fe4821 cj5.h under tests/upstream_cj5 with a blessed sha256 check, compiled with static symbols, as the degraded oracle (done 2026-10-23 11:33 EDT)
- [x] [Become json5z (spec-accurate JSON5 validation)] Add the official JSON5 conformance suite (json5/json5-tests ceb24d4) to ./test with exact disagreement ledgers: upstream and interim cj5 each miss 51 of 114 cases (done 2026-10-23 12:20 EDT)
- [x] [Become json5z (spec-accurate JSON5 validation)] Write the Zig-core streaming validator (one bit per open container, chunked feed) test-first; it passes all 114 conformance cases with an empty ledger (done 2026-10-23 12:45 EDT)

## Retired 2026-10-28

- [x] [Become json5z (spec-accurate JSON5 validation)] Mutants for json5z itself (raw LF in strings, surrogates, literal letters, object comma) all caught; one found a test gap, another found dead code (done 2026-10-23 12:58 EDT)
- [x] [Become json5z (spec-accurate JSON5 validation)] Differential fuzz against the reference JavaScript json5 library (npm 2.2.3) plus random chunk-split invariance; 20k cases in ./test, 0 disagreements, bites on a planted bug (done 2026-10-23 13:02 EDT)
- [x] [Become json5z (spec-accurate JSON5 validation)] C FFI (include/json5z.h, pointer+length, streaming) plus a C CLI through it, with ABI and CLI contract tests (done 2026-10-23 13:40 EDT)
- [x] [Become json5z (spec-accurate JSON5 validation)] Ask validate to move from the interim cj5 module to the json5z module, with expected verdict changes (done 2026-10-23 13:45 EDT)
- [x] [Become json5z (spec-accurate JSON5 validation)] Spec-derived case corpus: 687 cases from the JSON5 1.0 and ES5.1 grammars, written by an agent that never read json5z's source (context: docs/plan_context/spec_cases.md) (done 2026-10-23 14:42 EDT)
- [x] [Become json5z (spec-accurate JSON5 validation)] Mine other JSON5 parsers for inputs they mishandle or never test: 84 sourced cases in tests/spec_cases/mined.cases (done 2026-10-23 14:42 EDT)
- [x] [Become json5z (spec-accurate JSON5 validation)] Run the spec corpus against json5z (0 disagreements), upstream cj5 (304) and the reference json5 library (1, a Unicode 10 table gap), each with an exact ledger (done 2026-10-23 14:42 EDT)
