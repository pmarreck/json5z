# PLAN

Open work for the cj5 fork, in priority order. Completed items retire to `docs/PLAN_LOG.md`.

## Upstream sync (requested by validate)

- [x] Merge upstream septag/cj5 5fe4821 (token factory, short-primitive memcpy fix) into master, porting fork fixes to `parser.tokens` (done 2026-10-14 16:55 EDT, f7b960a)
- [x] Refresh flake inputs (nixpkgs 2026-10-10, Zig 0.16.0) and pass `zig build test` plus `nix flake check` (done 2026-10-14 16:55 EDT, f7b960a)
- [x] Push master and reply to validate's inbox with the pushed SHA (done 2026-10-14 17:05 EDT, f7b960a)

## Large-document validity (requested by validate)

- [x] Add uncapped `validateAll` (allocator-grown tokens, byte offset of first error) and stop `isValid`/`validate` reporting overflow as valid (done 2026-10-14 17:35 EDT)
- [x] Reply to validate with the pushed SHA and the new API shape (done 2026-10-14 17:38 EDT, 3a32d25)
- [x] Add a validate-only cj5 path with O(depth) state (no token storage), proven against a frozen pre-refactor parser by differential corpus and fuzz tests; repoint validateAll/isValid at it (done 2026-10-18 23:40 EDT)
- [x] Bound the `}` parent walk so a corrupt chain ends with no verdict instead of spinning; add ./mutate with per-mutant timeouts (done 2026-10-18 23:40 EDT)
- [x] Tell validate that validateAll now uses memory proportional to nesting depth (done 2026-10-18 23:45 EDT, dd955d2)

## Housekeeping

- [x] Add a `./test` entry point that runs `zig build test`, ./mutate and the flake check (done 2026-10-18 23:40 EDT)
- [ ] Replace the stale Garnix comment in flake.nix and onboard Mechatron Prime CI (target manifest, webhook, badge)
- [ ] Default build.zig optimize mode to ReleaseFast instead of `standardOptimizeOption`
