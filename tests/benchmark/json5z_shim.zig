//! Benchmark shim: json5z's validator behind a C-callable function, with an
//! allocator that counts the validator's own requests (live, peak, count and
//! total bytes), so ./bm can report memory exactly instead of guessing from
//! process RSS. It wraps the same general-purpose allocator the C ABI uses.

const std = @import("std");
const builtin = @import("builtin");
const json5z = @import("json5z");

/// Mirrors `bench_json5z_counts` in bench.c.
const Counts = extern struct {
    live: usize = 0,
    peak: usize = 0,
    allocations: usize = 0,
    total: usize = 0,
};

const backing = std.heap.smp_allocator;
var counts: Counts = .{};

fn grow(by: usize) void {
    counts.total += by;
    counts.live += by;
    counts.peak = @max(counts.peak, counts.live);
}

fn account(old_len: usize, new_len: usize) void {
    if (new_len > old_len) grow(new_len - old_len) else counts.live -= old_len - new_len;
}

fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const ptr = backing.rawAlloc(len, alignment, ret_addr) orelse return null;
    counts.allocations += 1;
    grow(len);
    return ptr;
}

fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    if (!backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
    account(memory.len, new_len);
    return true;
}

fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const ptr = backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
    account(memory.len, new_len);
    return ptr;
}

fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    backing.rawFree(memory, alignment, ret_addr);
    counts.live -= memory.len;
}

const counting: std.mem.Allocator = .{
    .ptr = @ptrCast(&counts),
    .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
};

/// Validate a whole document; 0 valid, 1 invalid, 2 incomplete, -1 out of
/// memory. `out` receives the allocator counts for this call; `live` is the
/// residual after the validator is freed.
export fn bench_json5z_validate(data: [*]const u8, length: usize, out: *Counts) c_int {
    counts = .{};
    defer out.* = counts;
    const verdict = json5z.validate(counting, data[0..length]) catch return -1;
    return switch (verdict) {
        .valid => 0,
        .invalid => |f| if (f.kind == .invalid) 1 else 2,
    };
}

/// The Zig optimization mode this shim and the json5z core were built with.
export fn bench_build_mode() [*:0]const u8 {
    return @tagName(builtin.mode);
}
