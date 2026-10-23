//! Controls on the degraded oracle: the vendored cj5.h must be exactly
//! septag/cj5 at 5fe4821, and the judge must report upstream's verdicts.

const std = @import("std");
const c = @cImport(@cInclude("upstream_cj5_judge.h"));

/// sha256 of cj5.h at septag/cj5 5fe48214ffe0f46d0ed3f909ce3a2d8e51d45fb1
/// (git blob e30564eaab0b9729723280c53b11792e6f263a4b). Changing the vendored
/// file breaks this on purpose: the oracle must stay upstream's code.
const blessed_sha256 = "e58bef96f29281aa248a417d4e2c0b24e3007b828914093f86cfd62794024592";

pub fn judge(json: []const u8) c_int {
    var line: c_int = 0;
    var col: c_int = 0;
    return c.upstream_cj5_judge(json.ptr, @intCast(json.len), &line, &col);
}

test "vendored cj5.h is byte-identical to upstream 5fe4821" {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(@embedFile("cj5.h"), &digest, .{});
    try std.testing.expectEqualStrings(blessed_sha256, &std.fmt.bytesToHex(digest, .lower));
}

test "judge reports upstream verdicts" {
    try std.testing.expectEqual(@as(c_int, c.UPSTREAM_CJ5_VALID), judge("{a: 1, b: [1, 'x']}"));
    try std.testing.expectEqual(@as(c_int, c.UPSTREAM_CJ5_INCOMPLETE), judge("{a: 1"));
    try std.testing.expectEqual(@as(c_int, c.UPSTREAM_CJ5_INVALID), judge("]"));
}

test "judge grows its buffer for documents past the initial token capacity" {
    const n = 10_000;
    const buf = try std.testing.allocator.alloc(u8, 2 * n + 1);
    defer std.testing.allocator.free(buf);
    buf[0] = '[';
    for (0..n) |i| {
        buf[1 + 2 * i] = '1';
        buf[2 + 2 * i] = ',';
    }
    buf[buf.len - 1] = ']';
    try std.testing.expectEqual(@as(c_int, c.UPSTREAM_CJ5_VALID), judge(buf));
    buf[buf.len - 1] = '}';
    try std.testing.expectEqual(@as(c_int, c.UPSTREAM_CJ5_INVALID), judge(buf));
}

test "judge runs upstream's grammar, including defects our modified copy fixed" {
    // Fixed in the interim copy by f7355f6: a missing object value is accepted.
    try std.testing.expectEqual(@as(c_int, c.UPSTREAM_CJ5_VALID), judge("{foo: }"));
    // Fixed in the interim copy by a97d86f: whitespace before ':' is rejected.
    try std.testing.expectEqual(@as(c_int, c.UPSTREAM_CJ5_INVALID), judge("{a : 1}"));
}
