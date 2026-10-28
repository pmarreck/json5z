# Benchmark: json5z against upstream cj5

`./bm` (timing) and `./mg` (memory) run the shared `performance-profile`
engine over the cases in `profiling.json`. History goes outside the repository
(`PERFORMANCE_HISTORY_URL`, else a per-user state directory). New hardware is
UNBASELINED until an owner approves an observation; no baseline has been
approved yet.

## What is measured

`zig-out/bench/json5z-bench` (always ReleaseFast; it refuses to measure an
unoptimized build) generates each workload from a seed (SplitMix64), checks
the implementation's verdict before timing, then runs 3 warmups and 5 timed
samples per size, checking the verdict on every sample. Each timing workload
runs twice: on 1 CPU (`cpu_ns` gated) and on 12 CPUs (`wall_ns` gated), pinned
with taskset. Both implementations are single-threaded, and the two agree.

Implementations:

- **json5z**: the Zig core, `json5z.validate`, with a counting wrapper over
  the general-purpose allocator the C ABI uses. The C ABI adds one call per
  document, so it was not measured separately.
- **cj5-presized**: upstream cj5 (septag/cj5 `5fe4821`, unmodified) with a
  token array of exactly the needed size, allocated and touched before timing.
  This is cj5's best case and assumes the caller already knows the count.
- **cj5-two-pass**: count the tokens (cj5 parses to the end after its array
  overflows), allocate, parse, free, all timed. This is what a caller that has
  not seen the document must do.

cj5 allocates nothing itself, but needs one 32-byte token per value, key and
container, so its memory grows with the document. json5z keeps one bit per
open container.

Workloads are a top-level array of records: `config` (objects with comments,
unquoted keys, mixed values, trailing commas), `nested` (16 levels per record),
`strings` (escapes, raw UTF-8, long strings), `numbers`, `comments` (line and
block comments), plus `deep` (one array nested `size/2` levels). Upstream cj5
rejects several valid JSON5 forms, so the shared workloads leave them out:
exponents (`1e5`), negative hexadecimal, `Infinity`, `NaN`, `\'` inside single
quotes and `\x` escapes. It accepts comments only at the start of a line.

`./test` runs the untimed contract (`tests/benchmark/contract.bash`): an
optimized build; every workload accepted by the reference json5 library
(npm 2.2.3); both implementations accept it and reject a corrupted and a
truncated copy; the measurement protocol's shape; `./bm` refuses
`MUTE_DEBUG_STATUS`.

## Declared shapes

Bounds are per doubling of the input, gated on every adjacent pair:

| Cases | Bounds | Why |
|---|---|---|
| json5z, cj5-presized timing | 1.5 to 2.8 | Linear. |
| cj5-two-pass timing | 1.2 to 3.2 | Linear, with one doubling step near 8 to 16 MiB that costs about 3x as the fresh token array starts faulting in new pages, seen on every workload. |
| cj5-presized deep timing | 3.0 to 4.6 | Quadratic: closing each container walks back through the parent chain of every container still open. |
| json5z flat memory | exactly 1 | Constant: 136 bytes at every size. |
| json5z deep memory | 1.25 to 2.6 | Linear in depth, in steps: the bit stack grows its capacity geometrically. |
| cj5 memory | 1.8 to 2.2 (deep: exactly 2) | One token per value. |

## Results, 2026-10-28

Benchmark commit `394fe3f` on AMD Ryzen Threadripper 3990X (64 cores, 128
threads), Linux x86_64, Zig 0.16.0 with its bundled clang. The host was shared
with other work (load average 25 to 40 on 128 CPUs). Seed 1. Median of 5
samples at the largest size, single-CPU cases. "Tracked peak" is memory the
implementation itself requested; max RSS is the whole process, including the
generated documents.

| Workload | Size | Implementation | MB/s | Wall ms | Tracked peak | Tokens | Max RSS |
|---|---|---|---|---|---|---|---|
| config | 32 MiB | json5z | 165 | 203 | 136 B | | 49 MiB |
| config | 32 MiB | cj5-presized | 330 | 102 | 120 MiB | 3,942,819 | 183 MiB |
| config | 32 MiB | cj5-two-pass | 137 | 245 | 120 MiB | 3,942,819 | 183 MiB |
| nested | 32 MiB | json5z | 148 | 227 | 136 B | | 49 MiB |
| nested | 32 MiB | cj5-presized | 139 | 242 | 264 MiB | 8,658,001 | 318 MiB |
| nested | 32 MiB | cj5-two-pass | 68 | 495 | 264 MiB | 8,658,001 | 318 MiB |
| strings | 32 MiB | json5z | 185 | 182 | 136 B | | 49 MiB |
| strings | 32 MiB | cj5-presized | 1217 | 28 | 5.0 MiB | 164,652 | 49 MiB |
| strings | 32 MiB | cj5-two-pass | 576 | 58 | 5.0 MiB | 164,652 | 49 MiB |
| numbers | 32 MiB | json5z | 133 | 252 | 136 B | | 49 MiB |
| numbers | 32 MiB | cj5-presized | 282 | 119 | 139 MiB | 4,561,481 | 198 MiB |
| numbers | 32 MiB | cj5-two-pass | 117 | 286 | 139 MiB | 4,561,481 | 198 MiB |
| comments | 32 MiB | json5z | 215 | 156 | 136 B | | 49 MiB |
| comments | 32 MiB | cj5-presized | 1331 | 25 | 8.9 MiB | 290,392 | 49 MiB |
| comments | 32 MiB | cj5-two-pass | 430 | 78 | 8.9 MiB | 290,392 | 49 MiB |
| deep | 16 MiB | json5z | 119 | 141 | 1.3 MiB | | 26 MiB |
| deep | 64 KiB | json5z | 123 | 0.54 | 7.1 KiB | | 1 MiB |
| deep | 64 KiB | cj5-presized | 0.06 | 1123 | 1.0 MiB | 32,768 | 5 MiB |

The 64 KiB json5z deep row is a supplementary direct run of the same binary
(not an engine record), for comparison at cj5's largest deep size.

The json5z and cj5-presized sweeps grew linearly (1.6 to 2.4 per doubling).
cj5-two-pass did too apart from one step of 2.5 to 3.1 per workload, and
cj5's deep workload grew 3.9 to 4.1 per doubling (quadratic). At that rate cj5 would need roughly 20 hours for the 16 MiB
deep document that json5z validates in 141 ms.

Two observations failed their shape check and remain in the history as
failures: the first campaign used bounds truncated to integers by a
configuration generator bug, and one 12-CPU json5z deep sweep ran its first
size at half speed (CPU time doubled too, so the process was slowed, not
waiting); a rerun of that case was clean.

## Optimization checkpoint (SIMD and fast paths)

Deferred, not investigated with a profiler or compiler output. json5z decodes
UTF-8 and runs its grammar state machine once per code point. upstream cj5
skips string and comment bodies byte by byte without validating UTF-8 or the
grammar, which explains its 6 to 7x lead on the `strings` and `comments`
workloads. The likely candidates are bulk scans of string bodies, comment
bodies and whitespace runs: in a string, every byte other than the quote,
backslash, a control character or a byte at or above 0x80 can be skipped
without changing the verdict, which suits a vector compare. Any fast path must
keep the byte-at-a-time path as its equivalence oracle and the chunk-split
invariance the differential fuzzer checks.
