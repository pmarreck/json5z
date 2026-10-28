//! C ABI contract tests for include/json5z.h, linked against the static
//! library exactly as a C consumer would be.

const std = @import("std");
const c = @cImport(@cInclude("json5z.h"));
const testing = std.testing;

fn validate(bytes: []const u8, where: *c.json5z_location) c_int {
    return c.json5z_validate(bytes.ptr, bytes.len, null, where, null);
}

fn location(offset: usize, line: usize, column: usize) c.json5z_location {
    return .{ .offset = offset, .line = line, .column = column };
}

fn note(count: usize, offset: usize, line: usize, column: usize) c.json5z_note {
    return .{ .count = count, .first = location(offset, line, column) };
}

const no_note: c.json5z_note = .{ .count = 0, .first = location(0, 0, 0) };

/// A validator under `options`, or a test failure.
fn create(options: ?*const c.json5z_options) !*c.json5z_validator {
    var v: ?*c.json5z_validator = null;
    try testing.expectEqual(@as(c_int, c.JSON5Z_VALID), c.json5z_validator_create(options, &v));
    return v orelse error.TestUnexpectedResult;
}

test "whole-document verdicts and failure locations" {
    var where = location(99, 99, 99);
    try testing.expectEqual(@as(c_int, c.JSON5Z_VALID), validate("{a: [1, 'x']}", &where));
    try testing.expectEqual(location(99, 99, 99), where); // untouched when valid
    try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID), validate("[1,,2]", &where));
    try testing.expectEqual(location(3, 1, 4), where);
    try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID), validate("[\r\n  \xC3\xA9]", &where));
    try testing.expectEqual(location(5, 2, 3), where);
    try testing.expectEqual(@as(c_int, c.JSON5Z_INCOMPLETE), validate("{a: 1", &where));
    try testing.expectEqual(location(5, 1, 6), where);
}

test "options select the alternative readings and notes report each decision" {
    var where = location(0, 0, 0);
    var notes: c.json5z_notes = undefined;
    const doc = "[\xE2\x80\xA8,]"; // U+2028 then a stray comma
    try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID), c.json5z_validate(doc, doc.len, null, &where, &notes));
    try testing.expectEqual(location(4, 2, 1), where);
    try testing.expectEqual(note(1, 1, 1, 2), notes.line_separators);
    try testing.expectEqual(no_note, notes.astral_identifiers);

    const same_line: c.json5z_options = .{ .line_separators = c.JSON5Z_LINE_SEPARATORS_SAME_LINE, .astral_identifiers = c.JSON5Z_ASTRAL_IDENTIFIERS_REJECT };
    try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID), c.json5z_validate(doc, doc.len, &same_line, &where, &notes));
    try testing.expectEqual(location(4, 1, 3), where);
    try testing.expectEqual(note(1, 1, 1, 2), notes.line_separators);

    const key = "{\xF0\x90\x80\x80: 1}"; // U+10000, a letter beyond the BMP
    try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID), c.json5z_validate(key, key.len, null, &where, &notes));
    try testing.expectEqual(note(1, 1, 1, 2), notes.astral_identifiers);
    const accept: c.json5z_options = .{ .line_separators = c.JSON5Z_LINE_SEPARATORS_END_LINE, .astral_identifiers = c.JSON5Z_ASTRAL_IDENTIFIERS_ACCEPT };
    try testing.expectEqual(@as(c_int, c.JSON5Z_VALID), c.json5z_validate(key, key.len, &accept, &where, &notes));
    try testing.expectEqual(note(1, 1, 1, 2), notes.astral_identifiers);
    try testing.expectEqual(no_note, notes.line_separators);
}

test "zeroed or NULL options are the defaults" {
    const zeroed = std.mem.zeroes(c.json5z_options);
    const key = "{\xF0\x90\x80\x80: 1}";
    var where = location(0, 0, 0);
    try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID), c.json5z_validate(key, key.len, &zeroed, &where, null));
    try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID), c.json5z_validate(key, key.len, null, &where, null));
}

test "out-of-range option values are rejected before any input is judged" {
    var where = location(7, 7, 7);
    var notes = std.mem.zeroes(c.json5z_notes);
    notes.line_separators.count = 7;
    for ([_]c.json5z_options{
        .{ .line_separators = 2, .astral_identifiers = 0 },
        .{ .line_separators = -1, .astral_identifiers = 0 },
        .{ .line_separators = 0, .astral_identifiers = 2 },
    }) |bad| {
        try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID_ARGUMENT), c.json5z_validate("]", 1, &bad, &where, &notes));
        var v: ?*c.json5z_validator = null;
        try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID_ARGUMENT), c.json5z_validator_create(&bad, &v));
        try testing.expect(v == null);
    }
    try testing.expectEqual(location(7, 7, 7), where);
    try testing.expectEqual(@as(usize, 7), notes.line_separators.count);
}

test "NULL pointers follow the documented policy" {
    var where = location(9, 9, 9);
    try testing.expectEqual(@as(c_int, c.JSON5Z_INCOMPLETE), c.json5z_validate(null, 0, null, &where, null));
    try testing.expectEqual(location(0, 1, 1), where);
    try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID_ARGUMENT), c.json5z_validate(null, 1, null, &where, null));
    try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID), c.json5z_validate("]", 1, null, null, null));
    try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID_ARGUMENT), c.json5z_validator_create(null, null));
    c.json5z_validator_free(null);
}

test "embedded zero bytes are input, never terminators" {
    var where = location(0, 0, 0);
    // Allowed raw inside a string; invalid at the start, middle and end of structure.
    try testing.expectEqual(@as(c_int, c.JSON5Z_VALID), validate("'a\x00b'", &where));
    try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID), validate("\x00[]", &where));
    try testing.expectEqual(location(0, 1, 1), where);
    try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID), validate("[1,\x002]", &where));
    try testing.expectEqual(location(3, 1, 4), where);
    try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID), validate("[]\x00", &where));
    try testing.expectEqual(location(2, 1, 3), where);
}

test "streaming in chunks matches a single call, notes included" {
    const doc = "{key: 'caf\xC3\xA9\xE2\x80\xA8', list: [1, 2, 3,], /* note */ \xF0\x9D\x90\x80: true,,}";
    const accept: c.json5z_options = .{ .line_separators = c.JSON5Z_LINE_SEPARATORS_SAME_LINE, .astral_identifiers = c.JSON5Z_ASTRAL_IDENTIFIERS_ACCEPT };
    var whole_where = location(0, 0, 0);
    var whole_notes: c.json5z_notes = undefined;
    const whole = c.json5z_validate(doc, doc.len, &accept, &whole_where, &whole_notes);
    try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID), whole);
    try testing.expectEqual(@as(usize, 1), whole_notes.line_separators.count);
    try testing.expectEqual(@as(usize, 1), whole_notes.astral_identifiers.count);
    for (1..doc.len + 1) |chunk| {
        const v = try create(&accept);
        defer c.json5z_validator_free(v);
        var at: usize = 0;
        while (at < doc.len) : (at += chunk) {
            const end = @min(at + chunk, doc.len);
            try testing.expectEqual(@as(c_int, c.JSON5Z_VALID), c.json5z_validator_feed(v, doc.ptr + at, end - at));
        }
        var where = location(0, 0, 0);
        var notes: c.json5z_notes = undefined;
        try testing.expectEqual(whole, c.json5z_validator_finish(v, &where, &notes));
        try testing.expectEqual(whole_where, where);
        try testing.expectEqual(whole_notes, notes);
    }
}

test "feeding NULL with a length is rejected without consuming input" {
    const v = try create(null);
    defer c.json5z_validator_free(v);
    try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID_ARGUMENT), c.json5z_validator_feed(v, null, 4));
    try testing.expectEqual(@as(c_int, c.JSON5Z_VALID), c.json5z_validator_feed(v, null, 0));
    try testing.expectEqual(@as(c_int, c.JSON5Z_VALID), c.json5z_validator_feed(v, "[]", 2));
    try testing.expectEqual(@as(c_int, c.JSON5Z_VALID), c.json5z_validator_finish(v, null, null));
}
