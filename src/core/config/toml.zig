//! A TOML subset, scanned one key at a time.
//!
//! `DR-006` is the argument for why this file exists instead of a vendored
//! parser. The short version: everything tug's config holds is a string, an
//! integer, a boolean, or a table of strings, and the acceptance bar had one
//! item — errors that carry a line and a column — that no candidate promised.
//!
//! Three properties hold, and the rest of the config stack is built on them:
//!
//! **It never fails.** There is no error set. A line it cannot parse yields a
//! `problem` item and the scan resumes on the next line. A config file is not a
//! trust boundary but it is also not a reason to refuse a shell.
//!
//! **It never allocates.** Every string it yields is a slice of the source.
//! That is what lets `Config` borrow rather than own, and it is why escape
//! sequences are refused rather than decoded — see `Problem.escape_unsupported`.
//!
//! **It reports a position for everything**, including the things it refuses,
//! because "line 12, column 3" is the difference between a warning someone can
//! act on and one they scroll past.

const std = @import("std");
const testing = std.testing;

/// A one-based line and a one-based **byte** column. Bytes rather than
/// codepoints because the consumer of this number is a person looking at a text
/// editor's status bar, and every editor worth the name counts the same way for
/// ASCII — which is all a key name can be.
pub const Position = struct {
    line: u32 = 1,
    column: u32 = 1,
};

/// The value shapes the subset accepts. Every string borrows the source.
pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    boolean: bool,
};

/// Everything the scanner can refuse, named so the message can say what to do
/// instead rather than "syntax error".
pub const Problem = enum {
    expected_key,
    expected_equals,
    expected_value,
    unterminated_string,
    unterminated_table,
    escape_unsupported,
    bad_integer,
    trailing_text,
    dotted_key_unsupported,
    array_unsupported,
    inline_table_unsupported,
    array_of_tables_unsupported,
};

pub const Pair = struct {
    /// The current `[table]`, or "" at the top level. Borrows the source.
    table: []const u8,
    key: []const u8,
    value: Value,
    /// Where the key starts.
    at: Position,
};

pub const Item = union(enum) {
    pair: Pair,
    problem: struct { kind: Problem, at: Position },
};

pub const Scanner = struct {
    source: []const u8,
    index: usize = 0,
    line: u32 = 1,
    /// The index the current line starts at, which is what makes a column a
    /// subtraction rather than a second counter to keep in step.
    line_start: usize = 0,
    table: []const u8 = "",

    pub fn init(source: []const u8) Scanner {
        return .{ .source = source };
    }

    /// The next pair or problem, or null at the end of the input.
    ///
    /// Every path through this function either returns or advances `index` past
    /// at least one byte, which is what the garbage-bytes test asserts.
    pub fn next(self: *Scanner) ?Item {
        while (true) {
            self.skipBlank();
            if (self.index >= self.source.len) return null;

            const byte = self.source[self.index];
            if (byte == '#') {
                self.skipLine();
                continue;
            }
            if (byte == '[') {
                if (self.tableHeader()) |problem| return problem;
                continue;
            }
            return self.pair();
        }
    }

    // --- position bookkeeping ----------------------------------------------

    fn at(self: *const Scanner) Position {
        return .{
            .line = self.line,
            .column = @intCast(self.index - self.line_start + 1),
        };
    }

    fn problemHere(self: *Scanner, kind: Problem, position: Position) Item {
        self.skipLine();
        return .{ .problem = .{ .kind = kind, .at = position } };
    }

    /// Whitespace and line breaks. A `\r` is whitespace here and everywhere else
    /// in this file: a config saved on Windows must not give every value a
    /// trailing carriage return.
    fn skipBlank(self: *Scanner) void {
        while (self.index < self.source.len) : (self.index += 1) {
            switch (self.source[self.index]) {
                ' ', '\t', '\r' => {},
                '\n' => {
                    self.line += 1;
                    self.line_start = self.index + 1;
                },
                else => return,
            }
        }
    }

    /// Spaces within a line only.
    fn skipSpace(self: *Scanner) void {
        while (self.index < self.source.len) : (self.index += 1) {
            switch (self.source[self.index]) {
                ' ', '\t', '\r' => {},
                else => return,
            }
        }
    }

    fn skipLine(self: *Scanner) void {
        while (self.index < self.source.len) : (self.index += 1) {
            if (self.source[self.index] == '\n') {
                self.line += 1;
                self.line_start = self.index + 1;
                self.index += 1;
                return;
            }
        }
    }

    /// True when what remains of this line is nothing, or a comment. Consumes
    /// the spaces in front of whatever it finds.
    fn atLineEnd(self: *Scanner) bool {
        self.skipSpace();
        if (self.index >= self.source.len) return true;
        return self.source[self.index] == '\n' or self.source[self.index] == '#';
    }

    // --- the grammar --------------------------------------------------------

    /// Consumes a `[table]` header. Returns a problem item when it cannot, and
    /// null when the header was taken.
    fn tableHeader(self: *Scanner) ?Item {
        const start = self.at();
        self.index += 1; // past '['

        if (self.index < self.source.len and self.source[self.index] == '[') {
            return self.problemHere(.array_of_tables_unsupported, start);
        }

        const name_start = self.index;
        while (self.index < self.source.len and
            self.source[self.index] != ']' and
            self.source[self.index] != '\n') : (self.index += 1)
        {}

        if (self.index >= self.source.len or self.source[self.index] != ']') {
            return self.problemHere(.unterminated_table, start);
        }

        const name = std.mem.trim(u8, self.source[name_start..self.index], " \t\r");
        self.index += 1; // past ']'
        if (name.len == 0) return self.problemHere(.expected_key, start);
        if (!self.atLineEnd()) return self.problemHere(.trailing_text, self.at());

        self.table = name;
        return null;
    }

    fn pair(self: *Scanner) Item {
        const start = self.at();

        const name = self.key() orelse return self.problemHere(.expected_key, start);
        if (self.index < self.source.len and self.source[self.index] == '.') {
            return self.problemHere(.dotted_key_unsupported, self.at());
        }

        self.skipSpace();
        if (self.index >= self.source.len or self.source[self.index] != '=') {
            return self.problemHere(.expected_equals, self.at());
        }
        self.index += 1; // past '='
        self.skipSpace();

        const value_at = self.at();
        const parsed = self.value() catch |problem| return self.problemHere(
            switch (problem) {
                error.Unterminated => .unterminated_string,
                error.Escape => .escape_unsupported,
                error.BadInteger => .bad_integer,
                error.Array => .array_unsupported,
                error.InlineTable => .inline_table_unsupported,
                error.NotAValue => .expected_value,
            },
            value_at,
        );

        if (!self.atLineEnd()) return self.problemHere(.trailing_text, self.at());
        self.skipLine();
        return .{ .pair = .{
            .table = self.table,
            .key = name,
            .value = parsed,
            .at = start,
        } };
    }

    /// A bare or quoted key, or null when there is no key here at all.
    fn key(self: *Scanner) ?[]const u8 {
        if (self.index >= self.source.len) return null;
        const byte = self.source[self.index];
        if (byte == '"' or byte == '\'') {
            return self.quoted(byte) catch null;
        }

        const start = self.index;
        while (self.index < self.source.len) : (self.index += 1) {
            switch (self.source[self.index]) {
                'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {},
                else => break,
            }
        }
        if (self.index == start) return null;
        return self.source[start..self.index];
    }

    const ValueError = error{
        Unterminated,
        Escape,
        BadInteger,
        Array,
        InlineTable,
        NotAValue,
    };

    fn value(self: *Scanner) ValueError!Value {
        if (self.index >= self.source.len) return error.NotAValue;
        switch (self.source[self.index]) {
            '"', '\'' => |quote| return .{ .string = try self.quoted(quote) },
            '[' => return error.Array,
            '{' => return error.InlineTable,
            '\n', '#' => return error.NotAValue,
            't', 'f' => return .{ .boolean = try self.boolean() },
            '-', '+', '0'...'9' => return .{ .integer = try self.integer() },
            else => return error.NotAValue,
        }
    }

    /// The bytes between the quotes. A basic string containing a backslash is
    /// refused rather than decoded.
    ///
    /// ponytail: no escape sequences. Every string here is a slice of the
    /// source, which is what keeps this file allocation-free and lets `Config`
    /// borrow; a decoded escape would need a buffer with an owner. A literal
    /// string — `'C:\tug'` — is the escape hatch, and no v0.1 key needs more.
    /// Revisit when a config value can hold a path or a prompt.
    fn quoted(self: *Scanner, quote: u8) ValueError![]const u8 {
        self.index += 1; // past the opening quote
        const start = self.index;
        while (self.index < self.source.len) : (self.index += 1) {
            const byte = self.source[self.index];
            if (byte == '\n') return error.Unterminated;
            if (byte == '\\' and quote == '"') return error.Escape;
            if (byte == quote) {
                const text = self.source[start..self.index];
                self.index += 1; // past the closing quote
                return text;
            }
        }
        return error.Unterminated;
    }

    fn boolean(self: *Scanner) ValueError!bool {
        if (std.mem.startsWith(u8, self.source[self.index..], "true")) {
            self.index += 4;
            return true;
        }
        if (std.mem.startsWith(u8, self.source[self.index..], "false")) {
            self.index += 5;
            return false;
        }
        return error.NotAValue;
    }

    fn integer(self: *Scanner) ValueError!i64 {
        const start = self.index;
        if (self.source[self.index] == '-' or self.source[self.index] == '+') self.index += 1;
        const digits_start = self.index;
        while (self.index < self.source.len) : (self.index += 1) {
            switch (self.source[self.index]) {
                '0'...'9' => {},
                else => break,
            }
        }
        if (self.index == digits_start) return error.NotAValue;
        return std.fmt.parseInt(i64, self.source[start..self.index], 10) catch
            error.BadInteger;
    }
};

test "a bare key at the top level" {
    var scanner: Scanner = .init("theme = \"dark\"\n");
    const item = scanner.next().?;
    try testing.expectEqualStrings("", item.pair.table);
    try testing.expectEqualStrings("theme", item.pair.key);
    try testing.expectEqualStrings("dark", item.pair.value.string);
    try testing.expectEqual(@as(u32, 1), item.pair.at.line);
    try testing.expectEqual(@as(u32, 1), item.pair.at.column);
    try testing.expectEqual(@as(?Item, null), scanner.next());
}

test "every scalar type the subset accepts" {
    var scanner: Scanner = .init(
        \\name = "tug"
        \\literal = 'C:\tug'
        \\count = 42
        \\negative = -7
        \\yes = true
        \\no = false
        \\
    );
    try testing.expectEqualStrings("tug", scanner.next().?.pair.value.string);
    try testing.expectEqualStrings("C:\\tug", scanner.next().?.pair.value.string);
    try testing.expectEqual(@as(i64, 42), scanner.next().?.pair.value.integer);
    try testing.expectEqual(@as(i64, -7), scanner.next().?.pair.value.integer);
    try testing.expectEqual(true, scanner.next().?.pair.value.boolean);
    try testing.expectEqual(false, scanner.next().?.pair.value.boolean);
    try testing.expectEqual(@as(?Item, null), scanner.next());
}

test "a table header applies to every key under it" {
    var scanner: Scanner = .init(
        \\top = 1
        \\[history]
        \\enabled = false
        \\[keys]
        \\"ctrl+j" = "newline"
        \\
    );
    const first = scanner.next().?.pair;
    try testing.expectEqualStrings("", first.table);

    const second = scanner.next().?.pair;
    try testing.expectEqualStrings("history", second.table);
    try testing.expectEqualStrings("enabled", second.key);

    const third = scanner.next().?.pair;
    try testing.expectEqualStrings("keys", third.table);
    try testing.expectEqualStrings("ctrl+j", third.key);
    try testing.expectEqualStrings("newline", third.value.string);
}

test "a dotted table header is kept whole" {
    var scanner: Scanner = .init("[a.b]\nx = 1\n");
    try testing.expectEqualStrings("a.b", scanner.next().?.pair.table);
}

test "comments and blank lines are not items" {
    var scanner: Scanner = .init(
        \\# a comment
        \\
        \\theme = "dark" # trailing comment
        \\
        \\# another
        \\
    );
    try testing.expectEqualStrings("theme", scanner.next().?.pair.key);
    try testing.expectEqual(@as(?Item, null), scanner.next());
}

test "carriage returns do not become part of a value" {
    // The repo is developed on Windows; a config file saved there has CRLF line
    // endings and `dark\r` is not a theme anybody has.
    var scanner: Scanner = .init("theme = \"dark\"\r\ncount = 3\r\n");
    try testing.expectEqualStrings("dark", scanner.next().?.pair.value.string);
    try testing.expectEqual(@as(i64, 3), scanner.next().?.pair.value.integer);
    try testing.expectEqual(@as(?Item, null), scanner.next());
}

// Every refusal, its position, and the proof that the scan continues past it.
test "malformed lines become problems and the scan continues" {
    const cases = [_]struct {
        source: []const u8,
        want: Problem,
        line: u32,
        column: u32,
    }{
        .{ .source = "= 1\nok = 1\n", .want = .expected_key, .line = 1, .column = 1 },
        .{ .source = "theme\nok = 1\n", .want = .expected_equals, .line = 1, .column = 6 },
        .{ .source = "theme =\nok = 1\n", .want = .expected_value, .line = 1, .column = 8 },
        .{ .source = "theme = \"dark\nok = 1\n", .want = .unterminated_string, .line = 1, .column = 9 },
        .{ .source = "[history\nok = 1\n", .want = .unterminated_table, .line = 1, .column = 1 },
        .{ .source = "theme = \"a\\nb\"\nok = 1\n", .want = .escape_unsupported, .line = 1, .column = 9 },
        .{ .source = "count = 9999999999999999999999\nok = 1\n", .want = .bad_integer, .line = 1, .column = 9 },
        .{ .source = "theme = \"dark\" junk\nok = 1\n", .want = .trailing_text, .line = 1, .column = 16 },
        .{ .source = "a.b = 1\nok = 1\n", .want = .dotted_key_unsupported, .line = 1, .column = 2 },
        .{ .source = "x = [1, 2]\nok = 1\n", .want = .array_unsupported, .line = 1, .column = 5 },
        .{ .source = "x = { a = 1 }\nok = 1\n", .want = .inline_table_unsupported, .line = 1, .column = 5 },
        .{ .source = "[[servers]]\nok = 1\n", .want = .array_of_tables_unsupported, .line = 1, .column = 1 },
        .{ .source = "x = maybe\nok = 1\n", .want = .expected_value, .line = 1, .column = 5 },
        .{ .source = "x = 1.5\nok = 1\n", .want = .trailing_text, .line = 1, .column = 6 },
    };

    for (cases) |case| {
        var scanner: Scanner = .init(case.source);
        const problem = scanner.next().?.problem;
        testing.expectEqual(case.want, problem.kind) catch |err| {
            std.debug.print("\ncase: {s}\n", .{case.source});
            return err;
        };
        testing.expectEqual(case.line, problem.at.line) catch |err| {
            std.debug.print("\ncase: {s}\n", .{case.source});
            return err;
        };
        testing.expectEqual(case.column, problem.at.column) catch |err| {
            std.debug.print("\ncase: {s}\n", .{case.source});
            return err;
        };

        // The line after the bad one still parses. This is the whole posture:
        // one bad key costs one key.
        const recovered = scanner.next().?.pair;
        try testing.expectEqualStrings("ok", recovered.key);
        try testing.expectEqual(@as(u32, 2), recovered.at.line);
        try testing.expectEqual(@as(?Item, null), scanner.next());
    }
}

test "positions survive several lines" {
    var scanner: Scanner = .init("\n\n  theme = \"dark\"\n");
    const at = scanner.next().?.pair.at;
    try testing.expectEqual(@as(u32, 3), at.line);
    try testing.expectEqual(@as(u32, 3), at.column);
}

// Garbage bytes are the case a config file reaches by being the wrong file.
// The requirement is not that anything is understood; it is that the scanner
// terminates, consumes its input, and never reads out of bounds.
test "arbitrary bytes terminate without panicking" {
    var buffer: [256]u8 = undefined;
    var round: usize = 0;
    while (round < 200) : (round += 1) {
        var prng: std.Random.Xoshiro256 = .init(0x5eed +% round);
        const random = prng.random();
        const len = random.uintLessThan(usize, buffer.len);
        for (buffer[0..len]) |*byte| byte.* = random.int(u8);

        var scanner: Scanner = .init(buffer[0..len]);
        var items: usize = 0;
        while (scanner.next()) |_| {
            items += 1;
            // A scanner that yields more items than it has bytes is a scanner
            // that is not consuming input, which is the only way this loop can
            // fail to terminate.
            try testing.expect(items <= len + 1);
        }
        try testing.expectEqual(len, scanner.index);
    }
}
