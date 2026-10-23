//! Shared pieces of the corpus controls: judges for each implementation and
//! the exact-ledger comparison.

const std = @import("std");
const cj5_interim = @import("cj5");
const upstream_cj5 = @import("upstream_cj5");
const json5z = @import("json5z");

/// One corpus case with the verdict its source decrees.
pub const Case = struct {
    id: []const u8,
    accept: bool,
    bytes: []const u8,
};

pub const Judge = fn ([]const u8) anyerror!bool;

pub fn json5zAccepts(bytes: []const u8) anyerror!bool {
    return switch (try json5z.validate(std.testing.allocator, bytes)) {
        .valid => true,
        .invalid => false,
    };
}

pub fn upstreamAccepts(bytes: []const u8) anyerror!bool {
    return switch (upstream_cj5.judge(bytes)) {
        upstream_cj5.valid => true,
        upstream_cj5.invalid, upstream_cj5.incomplete => false,
        else => error.NoVerdict,
    };
}

pub fn interimAccepts(bytes: []const u8) anyerror!bool {
    return switch (try cj5_interim.validateAll(std.testing.allocator, bytes)) {
        .valid => true,
        .invalid => false,
    };
}

/// Compare an implementation's disagreements with a corpus against its
/// ledger as sets: every disagreement must be ledgered and every ledger
/// entry must still disagree. Ledger lines start with a case id; `#` lines
/// are comments.
pub fn expectLedger(name: []const u8, ledger: []const u8, cases: []const Case, accepts: Judge) !void {
    const gpa = std.testing.allocator;
    var listed: std.StringHashMapUnmanaged(void) = .empty;
    defer listed.deinit(gpa);
    var lines = std.mem.splitScalar(u8, ledger, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
        try listed.put(gpa, line[0..end], {});
    }

    var problems: usize = 0;
    var seen: usize = 0;
    for (cases) |case| {
        const got = accepts(case.bytes) catch |err| {
            std.debug.print("{s}: no verdict on {s}: {s}\n", .{ name, case.id, @errorName(err) });
            problems += 1;
            continue;
        };
        const disagrees = got != case.accept;
        if (listed.contains(case.id)) seen += 1;
        if (disagrees and !listed.contains(case.id)) {
            std.debug.print("{s}: unledgered disagreement: {s} (expected: {s}, got: {s})\n", .{
                name, case.id, verdictName(case.accept), verdictName(got),
            });
            problems += 1;
        } else if (!disagrees and listed.contains(case.id)) {
            std.debug.print("{s}: ledgered case now agrees: {s}\n", .{ name, case.id });
            problems += 1;
        }
    }
    if (seen != listed.count()) {
        std.debug.print("{s}: ledger names {d} case(s) that are not in the corpus\n", .{ name, listed.count() - seen });
        problems += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), problems);
}

fn verdictName(accept: bool) []const u8 {
    return if (accept) "accept" else "reject";
}
