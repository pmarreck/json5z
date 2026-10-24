//! C ABI contract tests for include/json5z.h, linked against the static
//! library exactly as a C consumer would be.

const std = @import("std");
const c = @cImport(@cInclude("json5z.h"));
const testing = std.testing;

fn validate(bytes: []const u8, where: *c.json5z_location) c_int {
    return c.json5z_validate(bytes.ptr, bytes.len, where);
}

fn location(offset: usize, line: usize, column: usize) c.json5z_location {
    return .{ .offset = offset, .line = line, .column = column };
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

test "NULL pointers follow the documented policy" {
    var where = location(9, 9, 9);
    try testing.expectEqual(@as(c_int, c.JSON5Z_INCOMPLETE), c.json5z_validate(null, 0, &where));
    try testing.expectEqual(location(0, 1, 1), where);
    try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID_ARGUMENT), c.json5z_validate(null, 1, &where));
    try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID), c.json5z_validate("]", 1, null));
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

test "streaming in chunks matches a single call" {
    const doc = "{key: 'caf\xC3\xA9', list: [1, 2, 3,], /* note */ ok: true}";
    var whole_where = location(0, 0, 0);
    const whole = validate(doc, &whole_where);
    try testing.expectEqual(@as(c_int, c.JSON5Z_VALID), whole);
    for (1..doc.len + 1) |chunk| {
        const v = c.json5z_validator_new() orelse return error.OutOfMemory;
        defer c.json5z_validator_free(v);
        var at: usize = 0;
        while (at < doc.len) : (at += chunk) {
            const end = @min(at + chunk, doc.len);
            try testing.expectEqual(@as(c_int, c.JSON5Z_VALID), c.json5z_validator_feed(v, doc.ptr + at, end - at));
        }
        try testing.expectEqual(whole, c.json5z_validator_finish(v, null));
    }
}

test "feeding NULL with a length is rejected without consuming input" {
    const v = c.json5z_validator_new() orelse return error.OutOfMemory;
    defer c.json5z_validator_free(v);
    try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID_ARGUMENT), c.json5z_validator_feed(v, null, 4));
    try testing.expectEqual(@as(c_int, c.JSON5Z_VALID), c.json5z_validator_feed(v, null, 0));
    try testing.expectEqual(@as(c_int, c.JSON5Z_VALID), c.json5z_validator_feed(v, "[]", 2));
    try testing.expectEqual(@as(c_int, c.JSON5Z_VALID), c.json5z_validator_finish(v, null));
}
