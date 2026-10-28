//! json5z: spec-accurate JSON5 validation (JSON5 1.0.0, https://spec.json5.org/).
//!
//! The validator is a streaming state machine. It decodes UTF-8 one byte at a
//! time, so input can arrive in chunks of any size, and it keeps one bit per
//! open container (array or object). Memory therefore grows with nesting
//! depth, never with document size, and no tokens or values are built.

const std = @import("std");

pub const Failure = struct {
    kind: Kind,
    /// Byte offset of the first code point that cannot continue a valid
    /// document; for `incomplete`, the length of the input.
    offset: usize,
    /// 1-based line of that position. Lines end at LF, CR, CR LF, U+2028
    /// and U+2029, the JSON5 LineTerminator set, wherever they appear.
    line: usize,
    /// 1-based column of that position, counted in code points.
    column: usize,

    pub const Kind = enum { invalid, incomplete };
};

pub const Verdict = union(enum) {
    valid,
    invalid: Failure,
};

pub const Error = std.mem.Allocator.Error;

/// Choices where the JSON5 specification, or the tools around it, allow more
/// than one reading (docs/plan_context/settings_and_notes.md). The defaults
/// are the BDFN rulings in docs/plan_context/spec_rulings.md.
pub const Options = struct {
    line_separators: LineSeparators = .end_line,
    astral_identifiers: AstralIdentifiers = .reject,
};

/// Whether U+2028 and U+2029 end a line in reported positions. The grammar
/// treats them as line terminators either way.
pub const LineSeparators = enum { end_line, same_line };

/// Whether unquoted keys may contain letters beyond U+FFFF, raw or as an
/// escaped surrogate pair (rulings 3 and 4).
pub const AstralIdentifiers = enum { reject, accept };

pub const Position = struct {
    offset: usize = 0,
    line: usize = 0,
    column: usize = 0,
};

/// How many times a setting decided the result, and where it first did.
/// `first` is meaningful only when `count` is nonzero.
pub const Note = struct {
    count: usize = 0,
    first: Position = .{},
};

/// One note per setting. A setting decides the result when the other value
/// would have produced a different verdict or reported position.
pub const Notes = struct {
    line_separators: Note = .{},
    astral_identifiers: Note = .{},
};

pub const Report = struct {
    verdict: Verdict,
    notes: Notes,
};

const tables = @import("unicode_tables.zig");

/// What the grammar accepts next, outside any token.
const Expect = enum {
    top_value,
    top_end,
    /// After `[` or after `,` in an array: a value, or `]` (trailing comma).
    array_value_or_close,
    array_comma_or_close,
    /// After `{` or after `,` in an object: a key, or `}` (trailing comma).
    object_key_or_close,
    object_colon,
    object_value,
    object_comma_or_close,
};

/// The token in progress, if any. Comments count as tokens here.
const Lex = enum {
    none,
    slash,
    line_comment,
    block_comment,
    block_comment_star,
    string,
    string_escape,
    string_hex,
    /// After `\0`: a decimal digit may not follow.
    string_zero,
    /// After `\` CR: an LF completes the line continuation.
    string_cr,
    number_sign,
    number_zero,
    number_int,
    /// After digits and `.`, e.g. `5.`
    number_int_dot,
    /// After a leading `.`, e.g. `.5`
    number_leading_dot,
    number_frac,
    number_exp,
    number_exp_sign,
    number_exp_digits,
    number_hex_start,
    number_hex,
    word,
    ident,
    ident_backslash,
    ident_hex,
    /// After an escaped high surrogate: an escaped low surrogate must follow.
    ident_pair_backslash,
};

const Container = enum(u1) { array, object };

pub const Validator = struct {
    gpa: std.mem.Allocator,
    options: Options = .{},
    /// Which settings decided the result; read after `finish`.
    notes: Notes = .{},
    /// One bit per open container, innermost last (1 = object).
    containers: std.ArrayList(u64) = .empty,
    depth: usize = 0,
    expect: Expect = .top_value,
    lex: Lex = .none,
    failure: ?Failure = null,
    /// Bytes consumed so far.
    offset: usize = 0,
    /// Offset of the code point being processed.
    cp_start: usize = 0,
    /// Line and column of the next code point.
    line: usize = 1,
    column: usize = 1,
    /// The previous code point was CR, so an LF now ends no further line.
    after_cr: bool = false,
    // UTF-8 decoding across chunk boundaries.
    utf8_need: u2 = 0,
    utf8_cp: u21 = 0,
    utf8_min: u21 = 0,
    utf8_start: usize = 0,
    // Token details.
    quote: u21 = 0,
    in_key: bool = false,
    hex_left: u3 = 0,
    hex_value: u21 = 0,
    ident_escape_starts: bool = false,
    /// Where the current identifier escape's backslash sits.
    escape_at: Position = .{},
    /// The escaped high surrogate awaiting its low half, or 0.
    pending_high: u21 = 0,
    word: []const u8 = "",
    word_index: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Validator {
        return .{ .gpa = gpa };
    }

    pub fn initOptions(gpa: std.mem.Allocator, options: Options) Validator {
        return .{ .gpa = gpa, .options = options };
    }

    pub fn deinit(self: *Validator) void {
        self.containers.deinit(self.gpa);
        self.* = undefined;
    }

    /// Consume the next chunk of the document. A chunk may end anywhere,
    /// including inside a UTF-8 sequence or a token. After the first
    /// failure, further input is ignored.
    pub fn feed(self: *Validator, chunk: []const u8) Error!void {
        for (chunk) |b| {
            if (self.failure != null) return;
            try self.byte(b);
            self.offset += 1;
        }
    }

    /// End of input: the verdict on everything fed so far. `notes` is final
    /// afterwards.
    pub fn finish(self: *Validator) Verdict {
        const verdict = self.judge();
        // A valid document reports no position for a line separator to move.
        if (verdict == .valid) self.notes.line_separators = .{};
        return verdict;
    }

    fn judge(self: *Validator) Verdict {
        if (self.failure) |f| return .{ .invalid = f };
        const incomplete: Verdict = .{ .invalid = .{ .kind = .incomplete, .offset = self.offset, .line = self.line, .column = self.column } };
        if (self.utf8_need != 0) return incomplete;
        switch (self.lex) {
            .none, .line_comment => {},
            .number_zero, .number_int, .number_int_dot, .number_frac, .number_exp_digits, .number_hex => self.valueDone(),
            .word => if (self.word_index == self.word.len) self.valueDone() else return incomplete,
            else => return incomplete,
        }
        return if (self.expect == .top_end) .valid else incomplete;
    }

    /// UTF-8 decoding: rejects overlong forms, surrogates and code points
    /// above U+10FFFF, then hands each code point to `step`.
    fn byte(self: *Validator, b: u8) Error!void {
        if (self.utf8_need == 0) {
            self.utf8_start = self.offset;
            switch (b) {
                0x00...0x7F => return self.codePoint(b),
                0xC2...0xDF => self.beginSequence(1, b & 0x1F, 0x80),
                0xE0...0xEF => self.beginSequence(2, b & 0x0F, 0x800),
                0xF0...0xF4 => self.beginSequence(3, b & 0x07, 0x10000),
                else => self.failAt(self.offset),
            }
            return;
        }
        if (b & 0xC0 != 0x80) return self.failAt(self.utf8_start);
        self.utf8_cp = (self.utf8_cp << 6) | (b & 0x3F);
        self.utf8_need -= 1;
        if (self.utf8_need != 0) return;
        const cp = self.utf8_cp;
        if (cp < self.utf8_min or (cp >= 0xD800 and cp <= 0xDFFF) or cp > 0x10FFFF) return self.failAt(self.utf8_start);
        return self.codePoint(cp);
    }

    fn beginSequence(self: *Validator, need: u2, bits: u21, min: u21) void {
        self.utf8_need = need;
        self.utf8_cp = bits;
        self.utf8_min = min;
    }

    fn codePoint(self: *Validator, cp: u21) Error!void {
        self.cp_start = self.utf8_start;
        try self.step(cp);
        self.advancePosition(cp);
    }

    /// Line and column bookkeeping after each code point; CR LF ends one line.
    /// U+2028 and U+2029 follow `line_separators`, noted when they precede
    /// the position a failure will report.
    fn advancePosition(self: *Validator, cp: u21) void {
        const lf_after_cr = cp == '\n' and self.after_cr;
        self.after_cr = cp == '\r';
        if (lf_after_cr) return;
        if (cp == 0x2028 or cp == 0x2029) {
            if (self.failure == null) self.noteHere(&self.notes.line_separators);
            if (self.options.line_separators == .same_line) {
                self.column += 1;
                return;
            }
        }
        if (isLineTerminator(cp)) {
            self.line += 1;
            self.column = 1;
        } else self.column += 1;
    }

    /// Every failure lies at the code point being decoded, which has not yet
    /// advanced the line and column.
    fn failAt(self: *Validator, offset: usize) void {
        self.failure = .{ .kind = .invalid, .offset = offset, .line = self.line, .column = self.column };
    }

    fn fail(self: *Validator) void {
        self.failAt(self.cp_start);
    }

    fn here(self: *const Validator) Position {
        return .{ .offset = self.cp_start, .line = self.line, .column = self.column };
    }

    fn noteHere(self: *Validator, n: *Note) void {
        noteAt(n, self.here());
    }

    fn noteAt(n: *Note, at: Position) void {
        if (n.count == 0) n.first = at;
        n.count += 1;
    }

    /// ES5.1 IdentifierStart or IdentifierPart for a raw code point, with
    /// `astral_identifiers` deciding letters beyond U+FFFF (noted).
    fn identifierChar(self: *Validator, cp: u21, start: bool) bool {
        const allowed = if (start) isIdentifierStart(cp) else isIdentifierPart(cp);
        if (!allowed or cp <= max_bmp) return allowed;
        self.noteHere(&self.notes.astral_identifiers);
        return self.options.astral_identifiers == .accept;
    }

    fn beginIdentEscape(self: *Validator, starts: bool) void {
        self.ident_escape_starts = starts;
        self.escape_at = self.here();
        self.lex = .ident_backslash;
    }

    /// Advance the grammar by one code point. A state that ends its token on
    /// a code point belonging to what follows re-dispatches that code point.
    fn step(self: *Validator, cp: u21) Error!void {
        while (true) switch (self.lex) {
            .none => return self.structural(cp),
            .slash => return switch (cp) {
                '/' => self.lex = .line_comment,
                '*' => self.lex = .block_comment,
                else => self.fail(),
            },
            .line_comment => {
                if (isLineTerminator(cp)) self.lex = .none;
                return;
            },
            .block_comment => {
                if (cp == '*') self.lex = .block_comment_star;
                return;
            },
            .block_comment_star => {
                self.lex = switch (cp) {
                    '/' => .none,
                    '*' => .block_comment_star,
                    else => .block_comment,
                };
                return;
            },
            .string => {
                if (cp == self.quote) {
                    self.lex = .none;
                    if (self.in_key) self.expect = .object_colon else self.valueDone();
                } else if (cp == '\\') {
                    self.lex = .string_escape;
                } else if (cp == '\n' or cp == '\r') {
                    self.fail();
                }
                return;
            },
            .string_escape => {
                self.lex = switch (cp) {
                    '0' => .string_zero,
                    '1'...'9' => return self.fail(),
                    'x' => self.beginHex(2),
                    'u' => self.beginHex(4),
                    '\r' => .string_cr,
                    // Single escapes, line continuations and any other
                    // character, which escapes to itself.
                    else => .string,
                };
                return;
            },
            .string_hex => {
                if (!isHexDigit(cp)) return self.fail();
                self.hex_left -= 1;
                if (self.hex_left == 0) self.lex = .string;
                return;
            },
            .string_zero => {
                if (isDecimalDigit(cp)) return self.fail();
                self.lex = .string;
            },
            .string_cr => {
                self.lex = .string;
                if (cp == '\n') return;
            },
            .number_sign => {
                self.lex = switch (cp) {
                    '0' => .number_zero,
                    '1'...'9' => .number_int,
                    '.' => .number_leading_dot,
                    'I' => self.beginWord("Infinity"),
                    'N' => self.beginWord("NaN"),
                    else => return self.fail(),
                };
                return;
            },
            .number_zero => switch (cp) {
                '.' => return self.setLex(.number_int_dot),
                'e', 'E' => return self.setLex(.number_exp),
                'x', 'X' => return self.setLex(.number_hex_start),
                else => self.endValueToken(),
            },
            .number_int => switch (cp) {
                '0'...'9' => return,
                '.' => return self.setLex(.number_int_dot),
                'e', 'E' => return self.setLex(.number_exp),
                else => self.endValueToken(),
            },
            .number_int_dot, .number_frac => switch (cp) {
                '0'...'9' => return self.setLex(.number_frac),
                'e', 'E' => return self.setLex(.number_exp),
                else => self.endValueToken(),
            },
            .number_leading_dot => {
                if (!isDecimalDigit(cp)) return self.fail();
                return self.setLex(.number_frac);
            },
            .number_exp => return switch (cp) {
                '+', '-' => self.setLex(.number_exp_sign),
                '0'...'9' => self.setLex(.number_exp_digits),
                else => self.fail(),
            },
            .number_exp_sign => {
                if (!isDecimalDigit(cp)) return self.fail();
                return self.setLex(.number_exp_digits);
            },
            .number_exp_digits => {
                if (isDecimalDigit(cp)) return;
                self.endValueToken();
            },
            .number_hex_start => {
                if (!isHexDigit(cp)) return self.fail();
                return self.setLex(.number_hex);
            },
            .number_hex => {
                if (isHexDigit(cp)) return;
                self.endValueToken();
            },
            .word => {
                if (self.word_index < self.word.len) {
                    if (cp != self.word[self.word_index]) return self.fail();
                    self.word_index += 1;
                    return;
                }
                self.endValueToken();
            },
            .ident => {
                if (self.identifierChar(cp, false)) return;
                if (cp == '\\') return self.beginIdentEscape(false);
                self.lex = .none;
                self.expect = .object_colon;
            },
            .ident_backslash => {
                if (cp != 'u') return self.fail();
                self.lex = .ident_hex;
                self.hex_left = 4;
                self.hex_value = 0;
                return;
            },
            .ident_hex => {
                const digit = hexValue(cp) orelse return self.fail();
                self.hex_value = (self.hex_value << 4) | digit;
                self.hex_left -= 1;
                if (self.hex_left != 0) return;
                var named = self.hex_value;
                if (self.pending_high != 0) {
                    if (named < 0xDC00 or named > 0xDFFF) return self.fail();
                    named = 0x10000 + ((self.pending_high - 0xD800) << 10) + (named - 0xDC00);
                    self.pending_high = 0;
                } else if (named >= 0xD800 and named <= 0xDBFF) {
                    // An escaped pair is decided by `astral_identifiers`.
                    noteAt(&self.notes.astral_identifiers, self.escape_at);
                    if (self.options.astral_identifiers == .reject) return self.fail();
                    self.pending_high = named;
                    self.lex = .ident_pair_backslash;
                    return;
                }
                // An escape must name a character the identifier could contain.
                const ok = if (self.ident_escape_starts) isIdentifierStart(named) else isIdentifierPart(named);
                if (!ok) return self.fail();
                self.lex = .ident;
                return;
            },
            .ident_pair_backslash => {
                if (cp != '\\') return self.fail();
                self.lex = .ident_backslash;
                return;
            },
        };
    }

    fn setLex(self: *Validator, lex: Lex) void {
        self.lex = lex;
    }

    fn beginHex(self: *Validator, digits: u3) Lex {
        self.hex_left = digits;
        return .string_hex;
    }

    fn beginWord(self: *Validator, word: []const u8) Lex {
        self.word = word;
        self.word_index = 1;
        return .word;
    }

    /// A number or literal ended on `cp`, which the caller re-dispatches.
    /// ECMAScript 5.1 forbids an IdentifierStart or digit straight after a
    /// numeric literal, and a literal followed by an IdentifierPart would be
    /// a longer identifier. Neither needs a check here: no token that may
    /// follow a JSON5 value (whitespace, comment, `,`, `]`, `}`) begins with
    /// such a character, so re-dispatching rejects it at the same offset.
    fn endValueToken(self: *Validator) void {
        self.lex = .none;
        self.valueDone();
    }

    /// Dispatch a code point outside any token.
    fn structural(self: *Validator, cp: u21) Error!void {
        if (isWhitespace(cp) or isLineTerminator(cp)) return;
        if (cp == '/') return self.setLex(.slash);
        switch (self.expect) {
            .top_value, .object_value => return self.startValue(cp),
            .array_value_or_close => {
                if (cp == ']') return self.close(.array);
                return self.startValue(cp);
            },
            .top_end => return self.fail(),
            .array_comma_or_close => switch (cp) {
                ',' => self.expect = .array_value_or_close,
                ']' => self.close(.array),
                else => self.fail(),
            },
            .object_key_or_close => switch (cp) {
                '}' => self.close(.object),
                '"', '\'' => self.beginString(cp, true),
                '\\' => self.beginIdentEscape(true),
                else => if (self.identifierChar(cp, true)) {
                    self.lex = .ident;
                } else self.fail(),
            },
            .object_colon => if (cp == ':') {
                self.expect = .object_value;
            } else self.fail(),
            .object_comma_or_close => switch (cp) {
                ',' => self.expect = .object_key_or_close,
                '}' => self.close(.object),
                else => self.fail(),
            },
        }
    }

    fn startValue(self: *Validator, cp: u21) Error!void {
        switch (cp) {
            '{' => {
                try self.open(.object);
                self.expect = .object_key_or_close;
            },
            '[' => {
                try self.open(.array);
                self.expect = .array_value_or_close;
            },
            '"', '\'' => self.beginString(cp, false),
            '+', '-' => self.lex = .number_sign,
            '0' => self.lex = .number_zero,
            '1'...'9' => self.lex = .number_int,
            '.' => self.lex = .number_leading_dot,
            'n' => self.lex = self.beginWord("null"),
            't' => self.lex = self.beginWord("true"),
            'f' => self.lex = self.beginWord("false"),
            'I' => self.lex = self.beginWord("Infinity"),
            'N' => self.lex = self.beginWord("NaN"),
            else => self.fail(),
        }
    }

    fn beginString(self: *Validator, quote: u21, in_key: bool) void {
        self.quote = quote;
        self.in_key = in_key;
        self.lex = .string;
    }

    fn open(self: *Validator, kind: Container) Error!void {
        const word = self.depth / 64;
        if (word == self.containers.items.len) try self.containers.append(self.gpa, 0);
        const bit = @as(u64, 1) << @intCast(self.depth % 64);
        if (kind == .object) self.containers.items[word] |= bit else self.containers.items[word] &= ~bit;
        self.depth += 1;
    }

    fn close(self: *Validator, kind: Container) void {
        std.debug.assert(self.depth > 0 and self.innermost() == kind);
        self.depth -= 1;
        self.valueDone();
    }

    fn innermost(self: *const Validator) Container {
        const d = self.depth - 1;
        return @enumFromInt(@as(u1, @truncate(self.containers.items[d / 64] >> @intCast(d % 64))));
    }

    /// A value just ended; what may follow depends on the enclosing container.
    fn valueDone(self: *Validator) void {
        self.expect = if (self.depth == 0) .top_end else switch (self.innermost()) {
            .array => .array_comma_or_close,
            .object => .object_comma_or_close,
        };
    }
};

fn isDecimalDigit(cp: u21) bool {
    return cp >= '0' and cp <= '9';
}

fn hexValue(cp: u21) ?u21 {
    return switch (cp) {
        '0'...'9' => cp - '0',
        'a'...'f' => cp - 'a' + 10,
        'A'...'F' => cp - 'A' + 10,
        else => null,
    };
}

fn isHexDigit(cp: u21) bool {
    return hexValue(cp) != null;
}

fn isLineTerminator(cp: u21) bool {
    return cp == '\n' or cp == '\r' or cp == 0x2028 or cp == 0x2029;
}

/// JSON5 WhiteSpace: TAB, VT, FF, SP, NBSP, BOM and category Zs.
fn isWhitespace(cp: u21) bool {
    return switch (cp) {
        '\t', 0x0B, 0x0C, ' ', 0xA0, 0xFEFF => true,
        else => cp >= 0x80 and inRanges(&tables.space_separator, cp),
    };
}

/// ECMAScript 5.1 IdentifierStart, less the `\` escape form: letters
/// (Lu Ll Lt Lm Lo Nl), `$` and `_`, judged by code point. ES5.1 source
/// text is UTF-16 code units, so beyond U+FFFF it sees two surrogates, neither
/// a letter: `Validator.identifierChar` applies that reading (ruling 3) unless
/// `astral_identifiers` is `accept`.
fn isIdentifierStart(cp: u21) bool {
    if (cp < 0x80) return switch (cp) {
        'a'...'z', 'A'...'Z', '$', '_' => true,
        else => false,
    };
    return inRanges(&tables.id_start, cp);
}

const max_bmp = 0xFFFF;

/// ECMAScript 5.1 IdentifierPart, less the `\` escape form: IdentifierStart
/// plus Mn Mc Nd Pc, ZWNJ and ZWJ.
fn isIdentifierPart(cp: u21) bool {
    if (isIdentifierStart(cp) or isDecimalDigit(cp)) return true;
    if (cp < 0x80) return false;
    return cp == 0x200C or cp == 0x200D or inRanges(&tables.id_continue_only, cp);
}

/// Binary search over sorted inclusive ranges.
fn inRanges(ranges: []const [2]u21, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid][0]) {
            hi = mid;
        } else if (cp > ranges[mid][1]) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

/// Validate a whole document held in memory under the default options.
pub fn validate(gpa: std.mem.Allocator, input: []const u8) Error!Verdict {
    return (try check(gpa, input, .{})).verdict;
}

/// Validate a whole document held in memory, reporting which settings
/// decided the result.
pub fn check(gpa: std.mem.Allocator, input: []const u8, options: Options) Error!Report {
    var v = Validator.initOptions(gpa, options);
    defer v.deinit();
    try v.feed(input);
    const verdict = v.finish();
    return .{ .verdict = verdict, .notes = v.notes };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Judge `input` whole and again one byte per feed; the verdicts must match.
fn judge(input: []const u8) !Verdict {
    const whole = try validate(testing.allocator, input);
    var v = Validator.init(testing.allocator);
    defer v.deinit();
    for (0..input.len) |i| try v.feed(input[i .. i + 1]);
    try testing.expectEqualDeep(whole, v.finish());
    return whole;
}

fn expectValid(input: []const u8) !void {
    errdefer std.debug.print("expected valid: {f}\n", .{std.zig.fmtString(input)});
    try testing.expectEqualDeep(Verdict.valid, try judge(input));
}

fn expectFailure(input: []const u8, kind: Failure.Kind, offset: usize) !void {
    errdefer std.debug.print("expected {t} at {d}: {f}\n", .{ kind, offset, std.zig.fmtString(input) });
    const verdict = try judge(input);
    try testing.expect(verdict == .invalid);
    try testing.expectEqual(kind, verdict.invalid.kind);
    try testing.expectEqual(offset, verdict.invalid.offset);
}

fn expectRejected(input: []const u8) !void {
    errdefer std.debug.print("expected rejection: {f}\n", .{std.zig.fmtString(input)});
    try testing.expect((try judge(input)) == .invalid);
}

test "values and containers" {
    for ([_][]const u8{
        "{}",       "[]",     "null",         "true",              "false",
        "[[], {}]", "[1, 2]", "[1, 2,]",      "{a: 1, b: 2,}",     "{'a': 1, \"b\": [null]}",
        " \t1\n",   "[\r\n]", "[\x0B\x0C 1]", "{a: {b: {c: []}}}",
    }) |s| try expectValid(s);
}

test "numbers" {
    for ([_][]const u8{
        "0",    "-0",   "+1",       "123",       ".5",        "5.",  "1.5",  "1e3",
        "1E+3", "1e-3", "1.e3",     ".5e3",      "0e0",       "0.0", "0x1F", "0XaB",
        "-0x1", "+0x0", "Infinity", "-Infinity", "+Infinity", "NaN", "-NaN", "+NaN",
    }) |s| try expectValid(s);
    for ([_][]const u8{
        "01",  "00",  "-01",      "0x",  "1e",        "1e+",      ".",    "+",   "-",   "1a", "0x1g", "1.2.3", "0b1", "--1",
        "+-1", "- 1", "infinity", "nan", "Infinityx", "1\\u0041", "0123", ".e1", "1.e", "08",
    }) |s| try expectRejected(s);
}

test "literals end at the identifier boundary" {
    for ([_][]const u8{ "nullx", "truex", "false1", "true\\u0041", "nul", "tru", "NaNa", "null_" }) |s|
        try expectRejected(s);
    // Right length, wrong letter: every letter of a literal is checked.
    for ([_][]const u8{ "nulL", "trve", "fakse", "Infinitz", "NaM", "-Infinitz", "+NaM", "[nUll]" }) |s|
        try expectRejected(s);
    try expectValid("[null,true]");
}

test "strings" {
    for ([_][]const u8{
        "'a'",         "\"a\"",      "''",       "'\\''",                "\"\\\"\"",
        "'\\x41'",     "'\\u0041'",  "'\\0'",    "'\\b\\f\\n\\r\\t\\v'", "'\\a\\q'",
        "'a\\\nb'",    "'a\\\r\nb'", "'a\\\rb'", "'a\\\u{2028}b'",       "'a\\\u{2029}b'",
        "'\u{2028}'",  "'\u{2029}'", "'\t'",     "'\"'",                 "\"'\"",
        "'\u{1F600}'", "'\\uD800'",
    }) |s| try expectValid(s);
    for ([_][]const u8{ "'a\nb'", "'a\rb'", "'\\1'", "'\\08'", "'\\x4'", "'\\u004'", "'\\9'", "'a\"", "\"a'" }) |s|
        try expectRejected(s);
}

test "object keys" {
    for ([_][]const u8{
        "{$: 1}",         "{_: 1}",        "{a1: 1}",       "{$_$a1_$: 1}",   "{null: 1, true: 2}",
        "{\\u0061: 1}",   "{a\\u0062: 1}", "{\u{00E4}: 1}", "{a\u{0301}: 1}", "{a\u{200D}b: 1}",
        "{a\u{0660}: 1}", "{\u{2160}: 1}", "{a : 1}",       "{a/*c*/: 1}",    "{'a b': 1}",
    }) |s| try expectValid(s);
    for ([_][]const u8{
        "{1: 2}",         "{a b: 1}",        "{a}",     "{a:}",    "{a: 1 b: 2}",   "{\\u0031: 1}",
        "{a\\u0020: 1}",  "{\\x61: 1}",      "{-a: 1}", "{'a' 1}", "{\u{0301}: 1}", "{a\u{00A0}b: 1}",
        // Raw characters beyond the BMP cannot appear in unquoted keys.
        "{\u{10000}: 1}", "{a\u{1D400}: 1}",
    }) |s| try expectRejected(s);
}

test "commas" {
    for ([_][]const u8{ "[,]", "[,1]", "[1,,2]", "[1,,]", "{,}", "{a: 1,,}", "{,a: 1}", "[1 2]" }) |s|
        try expectRejected(s);
}

test "whitespace and comments" {
    for ([_][]const u8{
        "// c\n1",               "1 // c",            "1 // c\n",   "/* c */ 1 /* d */", "/** x **/ 1",
        "\u{FEFF}1",             "\u{00A0}1\u{3000}", "1\u{2028}",  "1\u{2029}",         "[1 /* , */]",
        "{/**/a/**/:/**/1/**/}", "1\u{2009}",         "// only\r1",
    }) |s| try expectValid(s);
    for ([_][]const u8{ "/ x", "1 /", "/* x", "1 /* x *", "# c\n1" }) |s| try expectRejected(s);
}

test "exactly one top-level value" {
    for ([_][]const u8{ "", " ", "// c", "1 2", "[1] [2]", "{a: 1} x", "'a' 'b'" }) |s| try expectRejected(s);
}

test "failure kinds and offsets" {
    try expectFailure("", .incomplete, 0);
    try expectFailure("{a: 1", .incomplete, 5);
    try expectFailure("[1, 'x", .incomplete, 6);
    try expectFailure("/* x", .incomplete, 4);
    try expectFailure("1e", .incomplete, 2);
    try expectFailure("[1,,2]", .invalid, 3);
    try expectFailure("01", .invalid, 1);
    try expectFailure("1a", .invalid, 1);
    try expectFailure("'a\nb'", .invalid, 2);
    try expectFailure("[1] x", .invalid, 4);
    try expectFailure("{1: 2}", .invalid, 1);
}

test "malformed UTF-8 is invalid wherever it appears" {
    try expectFailure("\xFF", .invalid, 0);
    try expectFailure("'\xC0\x80'", .invalid, 1); // overlong NUL
    try expectFailure("'\xED\xA0\x80'", .invalid, 1); // encoded surrogate
    try expectFailure("'\xF4\x90\x80\x80'", .invalid, 1); // above U+10FFFF
    try expectFailure("// \x80\n1", .invalid, 3); // stray continuation byte in a comment
    try expectFailure("'\xE2\x82'", .invalid, 1); // truncated sequence before the quote
    try expectFailure("'\xE2\x82", .incomplete, 3); // truncated at end of input
}

test "memory grows with depth only" {
    const depth = 100_000;
    const buf = try testing.allocator.alloc(u8, 2 * depth);
    defer testing.allocator.free(buf);
    @memset(buf[0..depth], '[');
    @memset(buf[depth..], ']');
    // One bit per open container: 100k levels need about 12.5 KiB, well under
    // the 200 KB document; a flat document of any length needs one word.
    var arena: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena);
    try testing.expectEqualDeep(Verdict.valid, try validate(fba.allocator(), buf));

    var flat = try testing.allocator.alloc(u8, 2 * depth + 1);
    defer testing.allocator.free(flat);
    flat[0] = '[';
    for (0..depth) |i| {
        flat[1 + 2 * i] = '1';
        flat[2 + 2 * i] = ',';
    }
    flat[flat.len - 1] = ']';
    var tiny: [256]u8 = undefined;
    var tiny_fba = std.heap.FixedBufferAllocator.init(&tiny);
    try testing.expectEqualDeep(Verdict.valid, try validate(tiny_fba.allocator(), flat));
}

test "running out of memory is an error, never a verdict" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, validate(failing.allocator(), "[1]"));
}

fn expectLocation(input: []const u8, kind: Failure.Kind, offset: usize, line: usize, column: usize) !void {
    errdefer std.debug.print("expected {t} at {d} ({d}:{d}): {f}\n", .{ kind, offset, line, column, std.zig.fmtString(input) });
    const want: Verdict = .{ .invalid = .{ .kind = kind, .offset = offset, .line = line, .column = column } };
    try testing.expectEqualDeep(want, try judge(input));
}

test "failures report a 1-based line and column in code points" {
    try expectLocation("x", .invalid, 0, 1, 1);
    try expectLocation("[1,,2]", .invalid, 3, 1, 4);
    try expectLocation("[\n  1,\n  ,]", .invalid, 9, 3, 3);
    // Every JSON5 LineTerminator ends a line; CR LF counts once.
    try expectLocation("[\r\n,]", .invalid, 3, 2, 1);
    try expectLocation("[\r,]", .invalid, 2, 2, 1);
    try expectLocation("[\r\r,]", .invalid, 3, 3, 1);
    try expectLocation("[\n\r,]", .invalid, 3, 3, 1);
    try expectLocation("[\u{2028},]", .invalid, 4, 2, 1);
    try expectLocation("[\u{2029},]", .invalid, 4, 2, 1);
    // Columns count code points, not bytes or UTF-16 units; a tab is one.
    try expectLocation("['\u{E9}\u{1F600}' x]", .invalid, 10, 1, 7);
    try expectLocation("\t\t?", .invalid, 2, 1, 3);
    // Line terminators inside comments and strings count too.
    try expectLocation("/*\n\n*/ ?", .invalid, 7, 3, 4);
    try expectLocation("['a\\\nb' ?]", .invalid, 8, 2, 4);
    // Malformed UTF-8 is located at the start of its sequence.
    try expectLocation("\n '\xE2\x82'", .invalid, 3, 2, 3);
    // Incomplete input is located just past its last character.
    try expectLocation("", .incomplete, 0, 1, 1);
    try expectLocation("{a: 1\n", .incomplete, 6, 2, 1);
    try expectLocation("[\n'\u{E9}", .incomplete, 5, 2, 3);
}

/// Judge `input` under `options` whole and again one byte per feed; the
/// verdicts and notes must match.
fn judgeWith(input: []const u8, options: Options) !Report {
    const whole = try check(testing.allocator, input, options);
    var v = Validator.initOptions(testing.allocator, options);
    defer v.deinit();
    for (0..input.len) |i| try v.feed(input[i .. i + 1]);
    try testing.expectEqualDeep(whole, Report{ .verdict = v.finish(), .notes = v.notes });
    return whole;
}

fn note(count: usize, offset: usize, line: usize, column: usize) Note {
    return .{ .count = count, .first = .{ .offset = offset, .line = line, .column = column } };
}

fn expectReport(input: []const u8, options: Options, want: Report) !void {
    errdefer std.debug.print("under {any}: {f}\n", .{ options, std.zig.fmtString(input) });
    try testing.expectEqualDeep(want, try judgeWith(input, options));
}

fn invalidAt(offset: usize, line: usize, column: usize) Verdict {
    return .{ .invalid = .{ .kind = .invalid, .offset = offset, .line = line, .column = column } };
}

test "default options are the BDFN rulings and record no notes on plain input" {
    try testing.expectEqualDeep(Options{ .line_separators = .end_line, .astral_identifiers = .reject }, Options{});
    try expectReport("{a: [1, 'x']}", .{}, .{ .verdict = .valid, .notes = .{} });
}

test "line_separators decides whether U+2028 and U+2029 end a line in positions" {
    // Each LS or PS before a reported position is a note; LF and CR are not.
    try expectReport("[\u{2028}\n\u{2029},]", .{}, .{ .verdict = invalidAt(8, 4, 1), .notes = .{ .line_separators = note(2, 1, 1, 2) } });
    try expectReport("[\u{2028}\n\u{2029},]", .{ .line_separators = .same_line }, .{ .verdict = invalidAt(8, 2, 2), .notes = .{ .line_separators = note(2, 1, 1, 2) } });
    // Inside strings too, where JSON5 allows them unescaped.
    try expectReport("['a\u{2028}b' ?]", .{ .line_separators = .same_line }, .{ .verdict = invalidAt(9, 1, 8), .notes = .{ .line_separators = note(1, 3, 1, 4) } });
    // A valid document prints no position, so no note.
    try expectReport("[\u{2028}1\u{2029}]", .{}, .{ .verdict = .valid, .notes = .{} });
    // A separator at the failure itself does not precede it.
    try expectReport("'\\u\u{2028}'", .{}, .{ .verdict = invalidAt(3, 1, 4), .notes = .{} });
    // Incomplete input reports a position as well.
    try expectReport("[\u{2028}", .{}, .{ .verdict = .{ .invalid = .{ .kind = .incomplete, .offset = 4, .line = 2, .column = 1 } }, .notes = .{ .line_separators = note(1, 1, 1, 2) } });
}

test "astral_identifiers decides letters beyond U+FFFF in unquoted keys" {
    const accept: Options = .{ .astral_identifiers = .accept };
    // Rejected by default, with a note at the character that decided it.
    try expectReport("{\u{10000}: 1}", .{}, .{ .verdict = invalidAt(1, 1, 2), .notes = .{ .astral_identifiers = note(1, 1, 1, 2) } });
    try expectReport("{a\u{1D400}: 1}", .{}, .{ .verdict = invalidAt(2, 1, 3), .notes = .{ .astral_identifiers = note(1, 2, 1, 3) } });
    // Accepted on request: letters, marks and digits after the start.
    try expectReport("{\u{10000}: 1, a\u{1D400}\u{1D167}\u{1D7CE}: 2}", accept, .{ .verdict = .valid, .notes = .{ .astral_identifiers = note(4, 1, 1, 2) } });
    // A mark or digit still cannot start a key, and a non-letter is never
    // part of one: the setting decides nothing there, so no note.
    try expectReport("{\u{1D7CE}: 1}", accept, .{ .verdict = invalidAt(1, 1, 2), .notes = .{} });
    try expectReport("{a\u{1F600}: 1}", accept, .{ .verdict = invalidAt(2, 1, 3), .notes = .{} });
    try expectReport("{a\u{1F600}: 1}", .{}, .{ .verdict = invalidAt(2, 1, 3), .notes = .{} });
    // Quoted keys and strings never consult the setting.
    try expectReport("{'\u{10000}': '\u{1D400}'}", .{}, .{ .verdict = .valid, .notes = .{} });
}

test "astral_identifiers governs escaped surrogate pairs the same way" {
    const accept: Options = .{ .astral_identifiers = .accept };
    // The escape's backslash locates the note. Rejected at the high
    // surrogate by default, as before.
    try expectReport("{\\uD835\\uDC00: 1}", .{}, .{ .verdict = invalidAt(6, 1, 7), .notes = .{ .astral_identifiers = note(1, 1, 1, 2) } });
    try expectReport("{\\uD835\\uDC00: 1, a\\uD835\\uDC00: 2}", accept, .{ .verdict = .valid, .notes = .{ .astral_identifiers = note(2, 1, 1, 2) } });
    // Under accept a high surrogate must be followed by an escaped low one,
    // and the pair must name an identifier character.
    try expectReport("{a\\uD835: 1}", accept, .{ .verdict = invalidAt(8, 1, 9), .notes = .{ .astral_identifiers = note(1, 2, 1, 3) } });
    try expectReport("{a\\uD835\\u0041: 1}", accept, .{ .verdict = invalidAt(13, 1, 14), .notes = .{ .astral_identifiers = note(1, 2, 1, 3) } });
    try expectReport("{\\uD83D\\uDE00: 1}", accept, .{ .verdict = invalidAt(12, 1, 13), .notes = .{ .astral_identifiers = note(1, 1, 1, 2) } });
    // A lone low surrogate fails the same way under either value.
    try expectReport("{\\uDC00: 1}", accept, .{ .verdict = invalidAt(6, 1, 7), .notes = .{} });
    try expectReport("{\\uDC00: 1}", .{}, .{ .verdict = invalidAt(6, 1, 7), .notes = .{} });
}
