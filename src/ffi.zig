//! C ABI for json5z (include/json5z.h): pointer-plus-length input, integer
//! status codes, and an opaque streaming validator. The validator and its
//! container stack use the general-purpose allocator; no libc is required.

const std = @import("std");
const json5z = @import("json5z.zig");

const allocator = std.heap.smp_allocator;

/// `json5z_location` in include/json5z.h.
const Location = extern struct {
    offset: usize,
    line: usize,
    column: usize,
};

/// `json5z_options`: plain ints, so an out-of-range value from C is
/// representable and can be rejected instead of becoming an invalid enum.
const Options = extern struct {
    line_separators: c_int,
    astral_identifiers: c_int,
};

/// `json5z_note` and `json5z_notes`.
const Note = extern struct {
    count: usize,
    first: Location,
};

const Notes = extern struct {
    line_separators: Note,
    astral_identifiers: Note,
};

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

/// Core options from C ones; NULL means the defaults, an out-of-range value null.
fn options(from: ?*const Options) ?json5z.Options {
    const o = from orelse return .{};
    return .{
        .line_separators = std.enums.fromInt(json5z.LineSeparators, o.line_separators) orelse return null,
        .astral_identifiers = std.enums.fromInt(json5z.AstralIdentifiers, o.astral_identifiers) orelse return null,
    };
}

fn location(p: anytype) Location {
    return .{ .offset = p.offset, .line = p.line, .column = p.column };
}

fn cNote(n: json5z.Note) Note {
    return .{ .count = n.count, .first = location(n.first) };
}

fn report(r: json5z.Report, failure: ?*Location, notes: ?*Notes) c_int {
    if (notes) |out| out.* = .{
        .line_separators = cNote(r.notes.line_separators),
        .astral_identifiers = cNote(r.notes.astral_identifiers),
    };
    return switch (r.verdict) {
        .valid => code(.valid),
        .invalid => |f| blk: {
            if (failure) |out| out.* = location(f);
            break :blk code(switch (f.kind) {
                .invalid => .invalid,
                .incomplete => .incomplete,
            });
        },
    };
}

export fn json5z_validator_create(from: ?*const Options, out: ?*?*json5z.Validator) c_int {
    const dest = out orelse return code(.invalid_argument);
    const opts = options(from) orelse return code(.invalid_argument);
    const v = allocator.create(json5z.Validator) catch return code(.out_of_memory);
    v.* = .initOptions(allocator, opts);
    dest.* = v;
    return code(.valid);
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

export fn json5z_validator_finish(validator: *json5z.Validator, failure: ?*Location, notes: ?*Notes) c_int {
    const verdict = validator.finish();
    return report(.{ .verdict = verdict, .notes = validator.notes }, failure, notes);
}

export fn json5z_validate(data: ?[*]const u8, length: usize, from: ?*const Options, failure: ?*Location, notes: ?*Notes) c_int {
    const bytes = slice(data, length) orelse return code(.invalid_argument);
    const opts = options(from) orelse return code(.invalid_argument);
    const r = json5z.check(allocator, bytes, opts) catch return code(.out_of_memory);
    return report(r, failure, notes);
}
