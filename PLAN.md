# PLAN

Open work for json5z, in priority order (context: docs/plan_context/json5z.md). Modified cj5 is interim library code; only unmodified upstream cj5 is the degraded oracle. Completed items retire to `docs/PLAN_LOG.md`.

## Become json5z (spec-accurate JSON5 validation)

- [x] Vendor unmodified septag/cj5 5fe4821 cj5.h under tests/upstream_cj5 with a blessed sha256 check, compiled with static symbols, as the degraded oracle (done 2026-10-23 11:33 EDT)
- [x] Add the official JSON5 conformance suite (json5/json5-tests ceb24d4) to ./test with exact disagreement ledgers: upstream and interim cj5 each miss 51 of 114 cases (done 2026-10-23 12:20 EDT)
- [x] Write the Zig-core streaming validator (one bit per open container, chunked feed) test-first; it passes all 114 conformance cases with an empty ledger (done 2026-10-23 12:45 EDT)
- [x] Mutants for json5z itself (raw LF in strings, surrogates, literal letters, object comma) all caught; one found a test gap, another found dead code (done 2026-10-23 12:58 EDT)
- [x] Differential fuzz against the reference JavaScript json5 library (npm 2.2.3) plus random chunk-split invariance; 20k cases in ./test, 0 disagreements, bites on a planted bug (done 2026-10-23 13:02 EDT)
- [x] C FFI (include/json5z.h, pointer+length, streaming) plus a C CLI through it, with ABI and CLI contract tests (done 2026-10-23 13:40 EDT)
- [x] Ask validate to move from the interim cj5 module to the json5z module, with expected verdict changes (done 2026-10-23 13:45 EDT)
- [x] Spec-derived case corpus: 687 cases from the JSON5 1.0 and ES5.1 grammars, written by an agent that never read json5z's source (context: docs/plan_context/spec_cases.md) (done 2026-10-23 14:42 EDT)
- [x] Mine other JSON5 parsers for inputs they mishandle or never test: 84 sourced cases in tests/spec_cases/mined.cases (done 2026-10-23 14:42 EDT)
- [x] Run the spec corpus against json5z (0 disagreements), upstream cj5 (304) and the reference json5 library (1, a Unicode 10 table gap), each with an exact ledger (done 2026-10-23 14:42 EDT)
- [ ] BDFN decides the six spec ambiguities (escaped literals, astral identifiers, escaped surrogate pairs in keys, number range, nesting depth) and records them in the corpus
- [ ] Once validate uses the json5z module, delete interim/cj5_modified and its build targets
- [ ] Benchmark against cj5 under the performance-profiling contract

## Upstream sync (requested by validate)


## Large-document validity (requested by validate)


## Housekeeping

- [ ] Onboard Mechatron Prime CI (target manifest, webhook, badge); the stale Garnix comment is already gone
- [ ] Conform to cross-platform-project-build-arch: ./build (Nix default, --backend=direct), zig-out/<PF>/[<VARIANT>/]<profile>/ product trees, bin/<PF>/json5z entrypoint, ReleaseFast default with safety-checked tests, ./run (context: docs/plan_context/build_arch.md)
