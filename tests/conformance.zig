//! Conformance control: every case in the official JSON5 suite
//! (tests/json5_tests, json5/json5-tests ceb24d4) is judged against the
//! verdict its file extension encodes. `.json` and `.json5` must be accepted;
//! `.js` and `.txt` must be rejected. Implementations that are not spec
//! accurate must match a ledger of their disagreements exactly, so a new
//! defect and a silent fix both fail.
//!
//! Cases are embedded at compile time from MANIFEST.sha256, so a missing file
//! fails the build and an edited file fails its hash.

const std = @import("std");
const cj5_interim = @import("cj5");
const upstream_cj5 = @import("upstream_cj5");
const json5z = @import("json5z");

/// sha256 of tests/json5_tests/MANIFEST.sha256. Changing any case means
/// regenerating the manifest and this constant in one conspicuous diff.
const blessed_manifest_sha256 = "93cd01b745847698dd25d4439b15000149699fd6750928a0850f5b302dfb2e5f";

const manifest = @embedFile("json5_tests/MANIFEST.sha256");

const Case = struct {
    path: []const u8,
    sha256: []const u8,
    bytes: []const u8,
    /// true: must be accepted; false: must be rejected; null: not a case.
    accept: ?bool,
};

fn expectedVerdict(path: []const u8) ?bool {
    if (std.mem.endsWith(u8, path, ".json") or std.mem.endsWith(u8, path, ".json5")) return true;
    if (std.mem.endsWith(u8, path, ".js") or std.mem.endsWith(u8, path, ".txt")) return false;
    return null;
}

const corpus: []const Case = blk: {
    @setEvalBranchQuota(1_000_000);
    var count = 0;
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |line| {
        if (line.len != 0) count += 1;
    }
    var cases: [count]Case = undefined;
    var i = 0;
    lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // sha256sum format: 64 hex digits, two spaces, path.
        const path = line[66..];
        cases[i] = .{
            .path = path,
            .sha256 = line[0..64],
            .bytes = @embedFile("json5_tests/" ++ path),
            .accept = expectedVerdict(path),
        };
        i += 1;
    }
    const final = cases;
    break :blk &final;
};

fn hexSha256(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "vendored conformance suite matches its blessed manifest" {
    try std.testing.expectEqualStrings(blessed_manifest_sha256, &hexSha256(manifest));
    var judged: usize = 0;
    for (corpus) |case| {
        errdefer std.debug.print("hash mismatch: {s}\n", .{case.path});
        try std.testing.expectEqualStrings(case.sha256, &hexSha256(case.bytes));
        if (case.accept != null) judged += 1;
    }
    // Guards against a manifest that silently lost its cases.
    try std.testing.expectEqual(@as(usize, 114), judged);
}

/// Compare an implementation's disagreements with the suite against its
/// ledger as sets: every disagreement must be ledgered and every ledger
/// entry must still disagree.
fn expectLedger(name: []const u8, ledger: []const u8, accepts: fn ([]const u8) anyerror!bool) !void {
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
    for (corpus) |case| {
        const want = case.accept orelse continue;
        const got = accepts(case.bytes) catch |err| {
            std.debug.print("{s}: no verdict on {s}: {s}\n", .{ name, case.path, @errorName(err) });
            problems += 1;
            continue;
        };
        const disagrees = got != want;
        if (disagrees and !listed.contains(case.path)) {
            std.debug.print("{s}: unledgered disagreement: {s} (suite: {s}, got: {s})\n", .{
                name, case.path, verdictName(want), verdictName(got),
            });
            problems += 1;
        } else if (!disagrees and listed.contains(case.path)) {
            std.debug.print("{s}: ledgered case now agrees with the suite: {s}\n", .{ name, case.path });
            problems += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), problems);
}

fn verdictName(accept: bool) []const u8 {
    return if (accept) "accept" else "reject";
}

fn upstreamAccepts(bytes: []const u8) anyerror!bool {
    return switch (upstream_cj5.judge(bytes)) {
        upstream_cj5.valid => true,
        upstream_cj5.invalid, upstream_cj5.incomplete => false,
        else => error.NoVerdict,
    };
}

fn interimAccepts(bytes: []const u8) anyerror!bool {
    return switch (try cj5_interim.validateAll(std.testing.allocator, bytes)) {
        .valid => true,
        .invalid => false,
    };
}

fn json5zAccepts(bytes: []const u8) anyerror!bool {
    return switch (try json5z.validate(std.testing.allocator, bytes)) {
        .valid => true,
        .invalid => false,
    };
}

test "json5z agrees with every case in the suite" {
    try expectLedger("json5z", @embedFile("ledgers/json5z.txt"), json5zAccepts);
}

test "upstream cj5 (degraded oracle) disagrees with the suite exactly as ledgered" {
    try expectLedger("upstream cj5", @embedFile("ledgers/upstream_cj5.txt"), upstreamAccepts);
}

test "interim parser disagrees with the suite exactly as ledgered" {
    try expectLedger("interim cj5_modified", @embedFile("ledgers/interim_cj5_modified.txt"), interimAccepts);
}
