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
const harness = @import("harness.zig");

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
    var with_verdict: usize = 0;
    for (corpus) |case| {
        errdefer std.debug.print("hash mismatch: {s}\n", .{case.path});
        try std.testing.expectEqualStrings(case.sha256, &hexSha256(case.bytes));
        if (case.accept != null) with_verdict += 1;
    }
    // Guards against a manifest that silently lost its cases.
    try std.testing.expectEqual(@as(usize, 114), with_verdict);
}

/// The suite's cases with an expected verdict, in harness form.
const judged: []const harness.Case = blk: {
    @setEvalBranchQuota(100_000);
    var count = 0;
    for (corpus) |case| {
        if (case.accept != null) count += 1;
    }
    var cases: [count]harness.Case = undefined;
    var i = 0;
    for (corpus) |case| {
        const accept = case.accept orelse continue;
        cases[i] = .{ .id = case.path, .accept = accept, .bytes = case.bytes };
        i += 1;
    }
    const final = cases;
    break :blk &final;
};

test "json5z agrees with every case in the suite" {
    try harness.expectLedger("json5z", @embedFile("ledgers/json5z.txt"), judged, harness.json5zAccepts);
}

test "upstream cj5 (degraded oracle) disagrees with the suite exactly as ledgered" {
    try harness.expectLedger("upstream cj5", @embedFile("ledgers/upstream_cj5.txt"), judged, harness.upstreamAccepts);
}

test "interim parser disagrees with the suite exactly as ledgered" {
    try harness.expectLedger("interim cj5_modified", @embedFile("ledgers/interim_cj5_modified.txt"), judged, harness.interimAccepts);
}

test {
    _ = @import("spec_cases.zig");
}
