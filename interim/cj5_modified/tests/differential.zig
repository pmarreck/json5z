//! Differential control for cj5's validate-only mode.
//!
//! Three parsers judge every input: the frozen pre-refactor parser
//! (tests/oracle, commit 3a32d25, symbols renamed cj5ref_*), the live token
//! parser, and the live validate-only parser that keeps only the ancestor
//! chain. The oracle cannot be edited by changes to cj5.h, so agreement is
//! evidence the refactor preserved the grammar, quirks included.

const std = @import("std");
const c = @cImport({
    @cInclude("cj5.h");
    @cInclude("cj5_reference.h");
});

const max_tokens = 512;

/// Judge one input with all three parsers and require identical verdicts,
/// error positions, token counts and (for the two token parsers) token bytes.
fn expectAgreement(json: []const u8) !c_int {
    var ref_tokens: [max_tokens]c.cj5ref_token = undefined;
    var new_tokens: [max_tokens]c.cj5_token = undefined;
    var stack: [max_tokens]c.cj5_frame = undefined;
    const len: c_int = @intCast(json.len);

    const ref = c.cj5ref_parse(json.ptr, len, &ref_tokens, max_tokens);
    const tok = c.cj5_parse(json.ptr, len, &new_tokens, max_tokens);
    const val = c.cj5_validate(json.ptr, len, &stack, max_tokens);

    errdefer std.debug.print("disagreement on input: {f}\n", .{std.zig.fmtString(json)});
    inline for (.{ tok, val }) |r| {
        try std.testing.expectEqual(ref.@"error", r.@"error");
        try std.testing.expectEqual(ref.num_tokens, r.num_tokens);
        try std.testing.expectEqual(ref.error_offset, r.error_offset);
        try std.testing.expectEqual(ref.error_line, r.error_line);
        try std.testing.expectEqual(ref.error_col, r.error_col);
    }
    try std.testing.expect(val.tokens == null);
    if (ref.@"error" == c.CJ5REF_ERROR_NONE) {
        const n: usize = @intCast(ref.num_tokens);
        try std.testing.expectEqualSlices(
            u8,
            std.mem.sliceAsBytes(ref_tokens[0..n]),
            std.mem.sliceAsBytes(new_tokens[0..n]),
        );
    }
    return @intCast(ref.@"error");
}

test "hand-picked inputs, including known cj5 quirks, agree across all three parsers" {
    const corpus = [_][]const u8{
        "",                         "{}",                    "[]",                 "{a: 1}",
        "{a : 1}",                  "{a\n: 1}",              "{a: }",              "{a: , b: 1}",
        "{a : }",                   "[1, 2,]",               "{a: 1",              "[[[[1]]]]",
        "{a: {b: {c: [1, {d: 2}]}}}", "[1] [2]",             "1 2 3",              "]",
        "[}",                       "{]",                    "{a: 1}}",            "'unterminated",
        "{a: 'x}",                  "\"a\\u00e9\"",          "\"bad\\q\"",         "// c\n[1]",
        "/* c */ [1]",              "[1 /* c */]",           "0x1F",               "0xZZ",
        "1.2.3",                    "+1",                    "-.5",                "Infinity",
        "null",                     "true",                  "fals",               "nul",
        "[1: 2]",                   "{1a: 2}",               "{_a: 2, $b: 3}",     "[\"a\" : 1]",
        "{a: [1, {b: }]}",          "{a: {b: 1}, c: 2}",     "[[1], [2], [[3]]]",  "{a: 1,, b: 2}",
    };
    for (corpus) |json| _ = try expectAgreement(json);
}

test "seeded random inputs agree across all three parsers" {
    // Weighted toward structural characters so nesting, keys and errors are common.
    const alphabet = "{}{}[][]::,,,''\"\"\\ \n\t/*abxu0129.+-enultrfs_{[a:1,";
    var prng = std.Random.DefaultPrng.init(0xC15_0005);
    const rand = prng.random();
    var buf: [64]u8 = undefined;
    // Verdict tally guards against a vacuous campaign (e.g. every input
    // rejected at its first byte); each class must be well represented.
    var tally = [_]usize{0} ** 4;
    for (0..50_000) |_| {
        const n = rand.uintLessThan(usize, buf.len + 1);
        for (buf[0..n]) |*b| b.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
        tally[@intCast(try expectAgreement(buf[0..n]))] += 1;
    }
    errdefer std.debug.print("verdict tally none/invalid/incomplete/overflow: {any}\n", .{tally});
    try std.testing.expect(tally[c.CJ5_ERROR_NONE] >= 1_000);
    try std.testing.expect(tally[c.CJ5_ERROR_INVALID] >= 1_000);
    try std.testing.expect(tally[c.CJ5_ERROR_INCOMPLETE] >= 1_000);
}

test "validate-only depth limit reports overflow, never a verdict" {
    var stack: [2]c.cj5_frame = undefined;
    const deep = "[[[1]]]";
    const r = c.cj5_validate(deep, deep.len, &stack, stack.len);
    try std.testing.expectEqual(@as(c_uint, c.CJ5_ERROR_OVERFLOW), @as(c_uint, @intCast(r.@"error")));
}

test "validate-only mode checks a flat array of any length with a two-entry stack" {
    // 100k elements need 100,001 tokens but only depth 2 of ancestor chain
    // (the array and its newest element).
    const n = 100_000;
    const buf = try std.testing.allocator.alloc(u8, 2 * n + 1);
    defer std.testing.allocator.free(buf);
    buf[0] = '[';
    for (0..n) |i| {
        buf[1 + 2 * i] = '1';
        buf[2 + 2 * i] = ',';
    }
    buf[buf.len - 1] = ']';
    var stack: [2]c.cj5_frame = undefined;
    const r = c.cj5_validate(buf.ptr, @intCast(buf.len), &stack, stack.len);
    try std.testing.expectEqual(@as(c_uint, c.CJ5_ERROR_NONE), @as(c_uint, @intCast(r.@"error")));
    try std.testing.expectEqual(@as(c_int, n + 1), r.num_tokens);
}
