# Conforming to the cross-platform build convention

The fleet's cross-platform-project-build-arch convention (2026-10-23) sets the
layout json5z should adopt. Read its verification-and-migration reference
before implementing or claiming conformance.

Gaps today:

- No top-level `./build`. It should default to Nix, offer `--backend=direct`,
  build optimized by default with explicit debug and test modes, and document
  the equivalent `zig build` command.
- Outputs go to a flat `zig-out/`. Products should be installation trees at
  `zig-out/<PF>/[<VARIANT>/]<profile>/` (PF such as `linux-amd64`; VARIANT
  `musl` or `gnu` only where it applies), with the compiler still receiving
  its native triple.
- No PATH-facing entrypoint. `bin/<PF>/json5z` should be a relative symlink
  to the selected host product, published only after a successful build,
  ignored by Git.
- build.zig defaults to Debug. Release builds should default to ReleaseFast,
  while `./test` keeps runtime safety checks (Debug or ReleaseSafe) and
  benchmarks name their profile.
- No `./run`. It should build the host product if needed, then launch it.
- `./test` must exercise the exact products it built, never a PATH copy.

Supported matrix: macos-arm64, linux-amd64, linux-arm64, mswin-amd64,
mswin-arm64. Cross-compiles are compile evidence only; label platforms that
have no native test run.
