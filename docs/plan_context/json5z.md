# json5z: spec-accurate JSON5 validation in Zig

Decision (2026-10-21): this repository stops being a fork of septag/cj5 and
becomes json5z, a new project that validates JSON5 against the specification.
The fork accumulated a rewrite of cj5's parser loop, and aiming for spec
accuracy means deliberately diverging from cj5's grammar quirks, so the code
no longer has cj5's identity.

Goals:

- Validation follows the JSON5 specification exactly. Spec accuracy is the
  default; cj5 compatibility is not a goal.
- A pure Zig core with no I/O, a C FFI, and a small C CLI that calls the core
  through the FFI. The validator reads the input once and keeps a stack of
  open containers, so memory grows with nesting depth and no tokens or values
  are materialized.
- Faster than cj5 on the same inputs, measured under the shared profiling
  contract.

Oracles, from most to least independent:

1. The official JSON5 conformance suite (github.com/json5/json5-tests).
2. Unmodified upstream cj5 (septag/cj5 at 5fe4821, byte-identical and
   hash-checked) as a degraded oracle: every disagreement must be a ledgered
   cj5 defect, never an unexplained difference. Our modified cj5 is not an
   oracle; it is interim library code, and the frozen copy in tests/oracle
   only checks that the validate-only refactor kept that code's behavior.
3. Seeded fuzzing and the ./mutate mutation controls.

cj5 is MIT licensed; its copyright notice stays with the frozen oracle copy.
