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
