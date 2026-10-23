# PLAN

Open work for json5z, in priority order (context: docs/plan_context/json5z.md). Modified cj5 is interim library code; only unmodified upstream cj5 is the degraded oracle. Completed items retire to `docs/PLAN_LOG.md`.

## Become json5z (spec-accurate JSON5 validation)

- [x] Record the json5z decision and goals (context: docs/plan_context/json5z.md) (done 2026-10-21 14:10 EDT)
- [x] BDFN renames the project directory to json5z; then rename the branch to yolo, update README, build.zig.zon name and flake pname (done 2026-10-21 14:15 EDT)
- [x] Create GitHub pmarreck/json5z (not a fork) and push yolo (done 2026-10-21 14:18 EDT)
- [x] Quarantine the modified cj5 and its refactoring check under interim/cj5_modified (done 2026-10-21 14:55 EDT)
- [ ] Vendor unmodified septag/cj5 5fe4821 cj5.h under tests/upstream_cj5 with a blessed sha256 check, compiled with renamed symbols, as the degraded oracle
- [ ] Add the official JSON5 conformance suite (json5/json5-tests) to ./test and record every cj5 disagreement in a quirk ledger
- [ ] Write the Zig-core streaming validator (O(depth) state) test-first against the conformance suite, with unmodified upstream cj5 as the degraded differential oracle
- [ ] C FFI plus a C CLI that validates files through it
- [ ] Once validate uses the json5z module, delete interim/cj5_modified and its build targets
- [ ] Benchmark against cj5 under the performance-profiling contract
- [x] Ask validate to switch its dependency from pmarreck/cj5 to pmarreck/json5z (done 2026-10-21 14:40 EDT, 03b88d8)
- [x] After validate switched (validate 40ec7df70), archive GitHub pmarreck/cj5 so old validate commits stay buildable (done 2026-10-23 11:27 EDT)

## Upstream sync (requested by validate)


## Large-document validity (requested by validate)

- [x] Add a validate-only cj5 path with O(depth) state (no token storage), proven against a frozen pre-refactor parser by differential corpus and fuzz tests; repoint validateAll/isValid at it (done 2026-10-18 23:40 EDT)
- [x] Bound the `}` parent walk so a corrupt chain ends with no verdict instead of spinning; add ./mutate with per-mutant timeouts (done 2026-10-18 23:40 EDT)
- [x] Tell validate that validateAll now uses memory proportional to nesting depth (done 2026-10-18 23:45 EDT, dd955d2)

## Housekeeping

- [x] Add a `./test` entry point that runs `zig build test`, ./mutate and the flake check (done 2026-10-18 23:40 EDT)
- [ ] Replace the stale Garnix comment in flake.nix and onboard Mechatron Prime CI (target manifest, webhook, badge)
- [ ] Default build.zig optimize mode to ReleaseFast instead of `standardOptimizeOption`
