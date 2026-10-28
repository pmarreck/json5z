# PLAN

Open work for json5z, in priority order (context: docs/plan_context/json5z.md). Modified cj5 is interim library code; only unmodified upstream cj5 is the degraded oracle. Completed items retire to `docs/PLAN_LOG.md`.

## Become json5z (spec-accurate JSON5 validation)

- [x] Record the BDFN rulings on the six spec ambiguities as cases (tests/spec_cases/rulings.cases) and document them; astral raw identifier characters become rejected, matching the escaped-surrogate-pair ruling (context: docs/plan_context/spec_rulings.md) (done 2026-10-24 00:35 EDT)
- [x] Report line and column (1-based, code points, JSON5 line terminators) with every failure: Zig core, C ABI, CLI text and --json (done 2026-10-24 00:35 EDT)
- [x] README: lead with the accuracy comparison against the reference json5 library and upstream cj5 (done 2026-10-24 00:35 EDT)
- [ ] Once validate uses the json5z module, delete interim/cj5_modified and its build targets
- [x] Benchmark against cj5 under the performance-profiling contract: ./bm and ./mg through performance-profile, contract checks in ./test, results in docs/plan_context/benchmark_cj5.md (done 2026-10-28 10:45 EDT, 394fe3f, 4f3390a)
- [ ] Beat cj5 on speed too: fast paths for string bodies, comment bodies and whitespace (bulk or vector scans), with the byte-at-a-time path as the equivalence oracle; cj5 with a presized token array is 2x faster on config and numbers and 6-7x on strings and comments (context: docs/plan_context/benchmark_cj5.md)
- [ ] Required before optimizing: re-run ./test, then ./bm and ./mg on current yolo; the first campaign predates the per-digit number_range tracking, so README and benchmark_cj5.md numbers are stale (context: docs/plan_context/benchmark_cj5.md)
- [ ] BDFN: should CLI notes print in setting order (current) or sorted by first position?
- [ ] BDFN: approve first benchmark baselines on this host after reviewing the UNBASELINED records (performance-profile accept)
- [x] Core options and notes: line_separators and astral_identifiers as validator options; per-setting note count and first position, recorded only when the rule changed the result (done 2026-10-28 10:05 EDT, 56585a5)
- [x] Every ruling overridable: escaped_literals, number_range (binary64 overflow, fuzzed against JavaScript's Number) and max_depth in the core (done 2026-10-28 10:40 EDT, dad50d5)
- [x] C ABI: json5z_options in, json5z_notes out, invalid option values rejected (done 2026-10-28 10:18 EDT, 1a7b44f)
- [x] C ABI for escaped_literals, number_range and max_depth (done 2026-10-28 10:45 EDT)
- [x] CLI settings layers: default, TOML file (tomlc17, XDG path or --config), JSON5Z_* environment, flags; later overrides earlier; --print-config (done 2026-10-28 11:05 EDT)
- [x] CLI notes: one stderr line per setting per input naming value and source, JSON5Z_MUTE_INFO mutes stderr only, --json always carries notes (done 2026-10-28 11:05 EDT)

## Upstream sync (requested by validate)


## Large-document validity (requested by validate)


## Housekeeping

- [ ] Onboard Mechatron Prime CI (target manifest, webhook, badge); the stale Garnix comment is already gone
- [ ] Conform to cross-platform-project-build-arch: ./build (Nix default, --backend=direct), zig-out/<PF>/[<VARIANT>/]<profile>/ product trees, bin/<PF>/json5z entrypoint, ReleaseFast default with safety-checked tests, ./run (context: docs/plan_context/build_arch.md)
