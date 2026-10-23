//! C ABI for json5z (include/json5z.h): pointer-plus-length input, integer
//! status codes, and an opaque streaming validator. The validator and its
//! container stack use the general-purpose allocator; no libc is required.

const std = @import("std");
const json5z = @import("json5z.zig");

const allocator = std.heap.smp_allocator;

const Status = enum(c_int) {
    invalid_argument = -2,
    out_of_memory = -1,
    valid = 0,
    invalid = 1,
    incomplete = 2,
};

fn code(status: Status) c_int {
    return @intFromEnum(status);
}

/// Bytes for a C (pointer, length) pair; NULL is allowed only for length 0.
fn slice(data: ?[*]const u8, length: usize) ?[]const u8 {
    if (length == 0) return &.{};
    const ptr = data orelse return null;
    return ptr[0..length];
}

fn report(verdict: json5z.Verdict, failure_offset: ?*usize) c_int {
    return switch (verdict) {
        .valid => code(.valid),
        .invalid => |f| blk: {
            if (failure_offset) |out| out.* = f.offset;
            break :blk code(switch (f.kind) {
                .invalid => .invalid,
                .incomplete => .incomplete,
            });
        },
    };
}

export fn json5z_validator_new() ?*json5z.Validator {
    const v = allocator.create(json5z.Validator) catch return null;
    v.* = .init(allocator);
    return v;
}

export fn json5z_validator_free(validator: ?*json5z.Validator) void {
    const v = validator orelse return;
    v.deinit();
    allocator.destroy(v);
}

export fn json5z_validator_feed(validator: *json5z.Validator, data: ?[*]const u8, length: usize) c_int {
    const bytes = slice(data, length) orelse return code(.invalid_argument);
    validator.feed(bytes) catch return code(.out_of_memory);
    return code(.valid);
}

export fn json5z_validator_finish(validator: *json5z.Validator, failure_offset: ?*usize) c_int {
    return report(validator.finish(), failure_offset);
}

export fn json5z_validate(data: ?[*]const u8, length: usize, failure_offset: ?*usize) c_int {
    const bytes = slice(data, length) orelse return code(.invalid_argument);
    const verdict = json5z.validate(allocator, bytes) catch return code(.out_of_memory);
    return report(verdict, failure_offset);
}
