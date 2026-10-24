# Rulings on ambiguous JSON5 inputs

The author of the spec-derived corpus (`tests/spec_cases/json5_1.0.cases`)
marked six questions `UNSURE`: the JSON5 1.0 specification, read with the
ECMAScript 5.1 grammar it builds on, supports more than one verdict. BDFN
(Benevolent Dictator For Now) ruled on each on 2026-10-23. The rulings are
test cases in `tests/spec_cases/rulings.cases`, which run against json5z,
upstream cj5 and the reference JavaScript library like the rest of the corpus.

| # | Input | Verdict | Reason |
|---|---|---|---|
| 1 | `null` (an escape inside `null`, `true`, `false`) | reject | JSON5Null and JSON5Boolean are spelled with literal characters, which an escape does not match. ES5.1 §7.6 interprets escaped identifiers by their actual characters, but a JSON5 value is not an identifier. |
| 2 | `Infinity`, `NaN` | reject | Same reasoning for the numeric literals. |
| 3 | A raw character outside the Basic Multilingual Plane in an unquoted key, e.g. `{𐀀:1}` | reject | ES5.1 clause 6 defines source text as 16-bit code units and §7.6 classifies code units. A supplementary character is two surrogate code units of category Cs, neither of which is a letter. JSON5 1.0 also calls its terminals "Unicode code units". Quoted keys and strings may contain such characters. |
| 4 | An escaped surrogate pair in a key, `{𝐀:1}` | reject | Each `\uXXXX` must itself name a character allowed at that position, and a lone surrogate never is. This matches ruling 3: the same code units are rejected raw or escaped. |
| 5 | Huge or very precise numbers, `1e400`, 30-digit integers | accept | They are grammatical. Spec §10 lets an implementation limit range and precision but does not require it; json5z checks grammar and builds no values. |
| 6 | Deep nesting | accept | No depth limit beyond memory, at one bit per open container. Unit tests cover 100,000 levels. |

## Differences from the reference library

The reference JavaScript library (npm `json5` 2.2.3) reads source by code
point, so it accepts the ruling-3 cases. Those disagreements are recorded in
`tests/ledgers/spec_reference_json5.txt`. Its maintainer rejects escaped
surrogate pairs in keys (json5/json5 issue 202), which agrees with ruling 4.
