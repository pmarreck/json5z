//! WebAssembly exports of the json5z core for the differential fuzzer
//! (tests/fuzz/differential.mjs). No I/O: the host writes input into
//! `inputBuffer()` and reads verdicts back through these functions.

const std = @import("std");
const json5z = @import("json5z");

var input: [1 << 16]u8 = undefined;
var stack_memory: [1 << 16]u8 = undefined;
var fba: std.heap.FixedBufferAllocator = undefined;
var validator: json5z.Validator = undefined;
var failure: json5z.Failure = undefined;
var options: json5z.Options = .{};

export fn inputBuffer() [*]u8 {
    return &input;
}

export fn inputCapacity() usize {
    return input.len;
}

/// Options for the following documents: 0 for the default number_range,
/// 1 for binary64 (tests/fuzz/number_range.mjs).
export fn setNumberRange(value: u32) void {
    options.number_range = if (value == 0) .unlimited else .binary64;
}

/// Start a new document, discarding any previous one.
export fn begin() void {
    fba = .init(&stack_memory);
    validator = .initOptions(fba.allocator(), options);
}

/// After `finish`: how many number literals number_range decided.
export fn numberRangeNotes() usize {
    return validator.notes.number_range.count;
}

/// Feed `len` bytes of the input buffer starting at `offset`.
/// Returns 0, or 1 when the container stack ran out of memory.
export fn feed(offset: usize, len: usize) u32 {
    validator.feed(input[offset..][0..len]) catch return 1;
    return 0;
}

/// 0 valid, 1 invalid, 2 incomplete; see `failureOffset`, `failureLine` and
/// `failureColumn` for the last two.
export fn finish() u32 {
    return switch (validator.finish()) {
        .valid => 0,
        .invalid => |f| blk: {
            failure = f;
            break :blk switch (f.kind) {
                .invalid => 1,
                .incomplete => 2,
            };
        },
    };
}

export fn failureOffset() usize {
    return failure.offset;
}

export fn failureLine() usize {
    return failure.line;
}

export fn failureColumn() usize {
    return failure.column;
}
