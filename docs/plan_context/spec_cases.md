# Spec-derived cases beyond the official suite

The official json5-tests suite has 114 cases: 83 that must be accepted and 31
that must be rejected. Many JSON5 1.0 grammar rules get one example or none.
Unicode in unquoted keys has only two cases, both in a `todo` folder because
the reference parser did not handle them when they were written. Passing the
suite is therefore a minimum, not proof of spec accuracy.

Plan:

1. Write cases from the JSON5 1.0 grammar itself: at least one accept and one
   reject case per production (JSON5Text, values, objects, arrays, member
   names, identifiers and their ES5.1 Unicode categories and escapes, strings
   and every escape form, line continuations, numbers in every form,
   whitespace including Zs and BOM, line terminators, comments). Each case
   cites the production it exercises, so the expected verdict comes from the
   spec, not from any implementation.
2. Mine other JSON5 parsers for inputs they get wrong or never test: issue
   trackers and test suites of json5/json5 (reference JavaScript), septag/cj5,
   Himujjal/zig-json5 and other maintained parsers. Every input found becomes a
   spec-cited case.
3. Run the corpus against json5z (ledger must stay empty), unmodified upstream
   cj5 and the reference json5 library, each with an exact disagreement
   ledger, so every parser's failures are recorded rather than assumed.
4. Consider a second independent strict parser for the differential fuzzer.
