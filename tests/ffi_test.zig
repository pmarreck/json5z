//! C ABI contract tests for include/json5z.h, linked against the static
//! library exactly as a C consumer would be.

const std = @import("std");
const c = @cImport(@cInclude("json5z.h"));
const testing = std.testing;

fn validate(bytes: []const u8, offset: *usize) c_int {
    return c.json5z_validate(bytes.ptr, bytes.len, offset);
}

test "whole-document verdicts and offsets" {
    var offset: usize = 99;
    try testing.expectEqual(@as(c_int, c.JSON5Z_VALID), validate("{a: [1, 'x']}", &offset));
    try testing.expectEqual(@as(usize, 99), offset); // untouched when valid
    try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID), validate("[1,,2]", &offset));
    try testing.expectEqual(@as(usize, 3), offset);
    try testing.expectEqual(@as(c_int, c.JSON5Z_INCOMPLETE), validate("{a: 1", &offset));
    try testing.expectEqual(@as(usize, 5), offset);
}

test "NULL pointers follow the documented policy" {
    var offset: usize = 0;
    try testing.expectEqual(@as(c_int, c.JSON5Z_INCOMPLETE), c.json5z_validate(null, 0, &offset));
    try testing.expectEqual(@as(usize, 0), offset);
    try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID_ARGUMENT), c.json5z_validate(null, 1, &offset));
    try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID), c.json5z_validate("]", 1, null));
    c.json5z_validator_free(null);
}

test "embedded zero bytes are input, never terminators" {
    var offset: usize = 0;
    // Allowed raw inside a string; invalid at the start, middle and end of structure.
    try testing.expectEqual(@as(c_int, c.JSON5Z_VALID), validate("'a\x00b'", &offset));
    try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID), validate("\x00[]", &offset));
    try testing.expectEqual(@as(usize, 0), offset);
    try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID), validate("[1,\x002]", &offset));
    try testing.expectEqual(@as(usize, 3), offset);
    try testing.expectEqual(@as(c_int, c.JSON5Z_INVALID), validate("[]\x00", &offset));
    try testing.expectEqual(@as(usize, 2), offset);
}

test "streaming in chunks matches a single call" {
    const doc = "{key: 'caf\xC3\xA9', list: [1, 2, 3,], /* note */ ok: true}";
    var whole_offset: usize = 0;
    const whole = validate(doc, &whole_offset);
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
