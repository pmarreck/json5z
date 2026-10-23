//! Spec-derived corpus control: tests/spec_cases/json5_1.0.cases holds cases
//! written from the JSON5 1.0 and ECMAScript 5.1 grammars alone, each citing
//! the production that decides its verdict. Its author did not read json5z's
//! source. Every implementation is held to an exact disagreement ledger;
//! json5z's must stay empty.
//!
//! Line format: ID <TAB> accept|reject <TAB> PRODUCTION <TAB> INPUT, where
//! INPUT uses only the escapes \\ \t \n \r \xHH and \u{H...} (emitted as UTF-8).

const std = @import("std");
const harness = @import("harness.zig");

/// The grammar-derived corpus plus cases mined from other parsers' bug
/// reports (tests/spec_cases/mined.cases); ids are unique across both.
const source = @embedFile("spec_cases/json5_1.0.cases") ++ "\n" ++ @embedFile("spec_cases/mined.cases");

pub const DecodeError = error{ BadEscape, BadLine, DuplicateId } || std.mem.Allocator.Error;

/// Decode one INPUT field into raw document bytes.
pub fn decodeInput(arena: std.mem.Allocator, text: []const u8) DecodeError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\\') {
            try out.append(arena, text[i]);
            continue;
        }
        i += 1;
        if (i >= text.len) return error.BadEscape;
        switch (text[i]) {
            '\\' => try out.append(arena, '\\'),
            't' => try out.append(arena, '\t'),
            'n' => try out.append(arena, '\n'),
            'r' => try out.append(arena, '\r'),
            'x' => {
                if (i + 2 >= text.len) return error.BadEscape;
                const byte = std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch return error.BadEscape;
                try out.append(arena, byte);
                i += 2;
            },
            'u' => {
                if (i + 1 >= text.len or text[i + 1] != '{') return error.BadEscape;
                const close = std.mem.indexOfScalarPos(u8, text, i + 2, '}') orelse return error.BadEscape;
                const cp = std.fmt.parseInt(u21, text[i + 2 .. close], 16) catch return error.BadEscape;
                var buf: [4]u8 = undefined;
                // Encodes surrogates too (WTF-8), so the file can state them
                // explicitly; \xHH is the usual way to write malformed UTF-8.
                const n = std.unicode.wtf8Encode(cp, &buf) catch return error.BadEscape;
                try out.appendSlice(arena, buf[0..n]);
                i = close;
            },
            else => return error.BadEscape,
        }
    }
    return out.items;
}

/// Parse the whole corpus; ids must be unique.
pub fn parseCases(arena: std.mem.Allocator, text: []const u8) DecodeError![]const harness.Case {
    var cases: std.ArrayList(harness.Case) = .empty;
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    while (lines.next()) |line| {
        number += 1;
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const id = fields.next() orelse return error.BadLine;
        const verdict = fields.next() orelse return error.BadLine;
        _ = fields.next() orelse return error.BadLine; // production
        const input = fields.rest();
        const accept = if (std.mem.eql(u8, verdict, "accept")) true else if (std.mem.eql(u8, verdict, "reject")) false else {
            std.debug.print("line {d}: verdict must be accept or reject\n", .{number});
            return error.BadLine;
        };
        if ((try ids.fetchPut(arena, id, {})) != null) {
            std.debug.print("line {d}: duplicate id {s}\n", .{ number, id });
            return error.DuplicateId;
        }
        const bytes = decodeInput(arena, input) catch |err| {
            std.debug.print("line {d}: {s}\n", .{ number, @errorName(err) });
            return err;
        };
        try cases.append(arena, .{ .id = id, .accept = accept, .bytes = bytes });
    }
    return cases.items;
}

fn loadCases(arena: std.mem.Allocator) ![]const harness.Case {
    const cases = try parseCases(arena, source);
    var accepts: usize = 0;
    for (cases) |c| accepts += @intFromBool(c.accept);
    // Guards against a truncated or one-sided corpus.
    try std.testing.expect(accepts >= 50 and cases.len - accepts >= 50);
    return cases;
}

test "input escapes decode to the exact bytes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("'a\\'b'", try decodeInput(arena, "'a\\\\'b'"));
    try std.testing.expectEqualStrings("\t\n\r\xff", try decodeInput(arena, "\\t\\n\\r\\xff"));
    try std.testing.expectEqualStrings("\u{e9}\u{2028}\u{1F600}", try decodeInput(arena, "\\u{e9}\\u{2028}\\u{1F600}"));
    try std.testing.expectEqualStrings("\xED\xA0\x80", try decodeInput(arena, "\\u{D800}"));
    for ([_][]const u8{ "\\", "\\q", "\\x4", "\\xZZ", "\\u{", "\\u{}", "\\u{110000}", "\\u41" }) |bad|
        try std.testing.expectError(error.BadEscape, decodeInput(arena, bad));
}

test "json5z agrees with every spec-derived case" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cases = try loadCases(arena_state.allocator());
    try harness.expectLedger("json5z", @embedFile("ledgers/spec_json5z.txt"), cases, harness.json5zAccepts);
}

test "upstream cj5 disagrees with the spec-derived cases exactly as ledgered" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const cases = try loadCases(arena_state.allocator());
    try harness.expectLedger("upstream cj5", @embedFile("ledgers/spec_upstream_cj5.txt"), cases, harness.upstreamAccepts);
}
