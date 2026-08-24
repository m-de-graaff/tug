//! Markdown-lite: enough of the syntax to read a model's answer, and no more.
//!
//! Two rules keep this small enough to trust. **Everything is line-local** —
//! there is no cross-line emphasis, so a stray `*` can never style the rest of
//! a response, and a line can be classified the moment it terminates.
//! **Unmatched markers are text** — the parser never speculates about bytes it
//! has not seen, which is what makes it correct on a stream that stops
//! mid-line and correct again once the rest arrives.
//!
//! What it deliberately does not do: nested lists (a marker must start at
//! column 0), setext headings, block quotes, tables, links, images, HTML,
//! backslash escapes, and syntax highlighting inside fences. Each is either a
//! later phase or one of Phase 4's scope guards, not an oversight.

const std = @import("std");

/// Styling is attributes only — bold, dim, italic. There is no colour anywhere
/// in Phase 4: colour is a theme slot, themes are Phase 9, and a renderer that
/// hardcodes colours now is a renderer Phase 9 has to unpick.
pub const Style = packed struct(u8) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    _padding: u5 = 0,
};

pub const LineKind = enum { blank, paragraph, heading, bullet, ordered, code };

/// One logical line, stored as a range into the owning text buffer. Logical,
/// not physical: wrapping happens at paint time, which is what makes a resize
/// a field assignment rather than a reparse.
pub const Line = struct {
    kind: LineKind,
    /// Heading depth 1–6 for `.heading`; the list number for `.ordered`;
    /// 0 otherwise.
    level: u8 = 0,
    start: u32,
    len: u32,
};

pub const Classified = struct {
    kind: LineKind,
    level: u8 = 0,
    /// Bytes to skip from the start of the raw line to reach the content.
    marker_len: u32 = 0,
};

/// Whether a raw line is a fence marker. Fence markers toggle the state and are
/// never echoed — the backticks are syntax, not content.
pub fn isFence(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "```");
}

/// Classifies one raw line, newline excluded.
pub fn classify(text: []const u8, in_fence: bool) Classified {
    // Inside a fence the bytes are the user's, verbatim. A `#` there is a
    // comment in half the languages a model writes.
    if (in_fence) return .{ .kind = .code };

    if (std.mem.trim(u8, text, " \t").len == 0) return .{ .kind = .blank };

    if (text[0] == '#') {
        var hashes: u8 = 0;
        while (hashes < text.len and text[hashes] == '#') hashes += 1;
        if (hashes <= 6 and hashes < text.len and text[hashes] == ' ') {
            return .{ .kind = .heading, .level = hashes, .marker_len = hashes + 1 };
        }
        return .{ .kind = .paragraph };
    }

    if (text.len >= 2 and (text[0] == '-' or text[0] == '*' or text[0] == '+') and text[1] == ' ') {
        return .{ .kind = .bullet, .marker_len = 2 };
    }

    var digits: usize = 0;
    while (digits < text.len and std.ascii.isDigit(text[digits])) digits += 1;
    if (digits > 0 and digits + 1 < text.len and text[digits] == '.' and text[digits + 1] == ' ') {
        // A list numbered past 255 is not a list anyone is reading. Saturating
        // keeps `level` a byte and the rendered prefix short.
        const number = std.fmt.parseInt(u8, text[0..digits], 10) catch 255;
        return .{ .kind = .ordered, .level = number, .marker_len = @intCast(digits + 2) };
    }

    return .{ .kind = .paragraph };
}

pub const Piece = struct { bytes: []const u8, style: Style };

/// Walks one line's content, yielding runs of bytes that share a style.
///
/// Matched markers are consumed; everything else is text. An unmatched `**`,
/// and an empty span like `****`, both come out as the characters they are —
/// which is the behaviour that makes a half-arrived line render sensibly and
/// then re-render correctly when its closing marker turns up.
pub const Inline = struct {
    text: []const u8,
    base: Style,
    index: usize = 0,

    pub fn init(text: []const u8, base: Style) Inline {
        return .{ .text = text, .base = base };
    }

    const Match = struct { marker: usize, content_end: usize, style: Style };

    /// The marker at `index` and where its content ends, or null when there is
    /// no marker there, when it is unclosed on this line, or when it would
    /// wrap nothing at all.
    fn matchAt(self: *const Inline, index: usize) ?Match {
        const rest = self.text[index..];
        // Code first: inside a span, `**` is two asterisks and nothing else.
        if (std.mem.startsWith(u8, rest, "`")) {
            if (std.mem.indexOfPos(u8, self.text, index + 1, "`")) |close| {
                if (close > index + 1) {
                    return .{ .marker = 1, .content_end = close, .style = .{ .dim = true } };
                }
            }
            return null;
        }
        if (std.mem.startsWith(u8, rest, "**")) {
            if (std.mem.indexOfPos(u8, self.text, index + 2, "**")) |close| {
                if (close > index + 2) {
                    return .{ .marker = 2, .content_end = close, .style = .{ .bold = true } };
                }
            }
            // Fall through: `**` that opens nothing may still be a lone `*`
            // followed by text, so the single-asterisk case gets its own look.
        }
        if (std.mem.startsWith(u8, rest, "*")) {
            if (std.mem.indexOfPos(u8, self.text, index + 1, "*")) |close| {
                if (close > index + 1) {
                    return .{ .marker = 1, .content_end = close, .style = .{ .italic = true } };
                }
            }
        }
        return null;
    }

    fn merge(base: Style, overlay: Style) Style {
        return .{
            .bold = base.bold or overlay.bold,
            .dim = base.dim or overlay.dim,
            .italic = base.italic or overlay.italic,
        };
    }

    pub fn next(self: *Inline) ?Piece {
        if (self.index >= self.text.len) return null;

        if (self.matchAt(self.index)) |match| {
            const content_start = self.index + match.marker;
            self.index = match.content_end + match.marker;
            return .{
                .bytes = self.text[content_start..match.content_end],
                .style = merge(self.base, match.style),
            };
        }

        // Plain text runs until the next marker that actually matches. Scanning
        // for *matches* rather than for marker bytes is the whole trick: it is
        // what makes an unmatched `**` part of the sentence instead of a style
        // change with no end.
        //
        // ponytail: this rescans from each position, so a line of nothing but
        // unmatched markers is quadratic in its length. Lines are one screen
        // wide in practice. If a pathological line ever shows up in a profile,
        // remember the failed scan rather than repeating it.
        var scan = self.index + 1;
        while (scan < self.text.len) : (scan += 1) {
            if (self.matchAt(scan) != null) break;
        }
        const piece = self.text[self.index..scan];
        self.index = scan;
        return .{ .bytes = piece, .style = self.base };
    }
};

const testing = std.testing;

test "a plain line is a paragraph" {
    const result = classify("hello world", false);
    try testing.expectEqual(LineKind.paragraph, result.kind);
    try testing.expectEqual(@as(u32, 0), result.marker_len);
}

test "an empty or all-space line is blank" {
    try testing.expectEqual(LineKind.blank, classify("", false).kind);
    try testing.expectEqual(LineKind.blank, classify("   ", false).kind);
}

test "headings carry their depth and drop their marker" {
    const h1 = classify("# Title", false);
    try testing.expectEqual(LineKind.heading, h1.kind);
    try testing.expectEqual(@as(u8, 1), h1.level);
    try testing.expectEqual(@as(u32, 2), h1.marker_len);

    const h3 = classify("### Deep", false);
    try testing.expectEqual(@as(u8, 3), h3.level);
    try testing.expectEqual(@as(u32, 4), h3.marker_len);
}

test "seven hashes is not a heading" {
    try testing.expectEqual(LineKind.paragraph, classify("####### no", false).kind);
}

test "a hash with no space is not a heading" {
    try testing.expectEqual(LineKind.paragraph, classify("#tag", false).kind);
}

test "all three bullet markers classify" {
    for ([_][]const u8{ "- one", "* one", "+ one" }) |line| {
        const result = classify(line, false);
        try testing.expectEqual(LineKind.bullet, result.kind);
        try testing.expectEqual(@as(u32, 2), result.marker_len);
    }
}

test "ordered items carry their number" {
    const result = classify("12. item", false);
    try testing.expectEqual(LineKind.ordered, result.kind);
    try testing.expectEqual(@as(u8, 12), result.level);
    try testing.expectEqual(@as(u32, 4), result.marker_len);
}

test "inside a fence everything is code and nothing is stripped" {
    const result = classify("# not a heading", true);
    try testing.expectEqual(LineKind.code, result.kind);
    try testing.expectEqual(@as(u32, 0), result.marker_len);
}

test "fence markers are recognised with and without an info string" {
    try testing.expect(isFence("```"));
    try testing.expect(isFence("```zig"));
    try testing.expect(isFence("````"));
    try testing.expect(!isFence("``"));
    try testing.expect(!isFence("text ```"));
}

test "a line with no markers is one plain piece" {
    var it: Inline = .init("hello", .{});
    const piece = it.next().?;
    try testing.expectEqualStrings("hello", piece.bytes);
    try testing.expectEqual(Style{}, piece.style);
    try testing.expectEqual(@as(?Piece, null), it.next());
}

test "bold, italic and code become styled pieces without their markers" {
    var it: Inline = .init("a **b** c *d* e `f`", .{});
    try testing.expectEqualStrings("a ", it.next().?.bytes);

    const bold = it.next().?;
    try testing.expectEqualStrings("b", bold.bytes);
    try testing.expect(bold.style.bold);

    try testing.expectEqualStrings(" c ", it.next().?.bytes);

    const italic = it.next().?;
    try testing.expectEqualStrings("d", italic.bytes);
    try testing.expect(italic.style.italic);

    try testing.expectEqualStrings(" e ", it.next().?.bytes);

    const code = it.next().?;
    try testing.expectEqualStrings("f", code.bytes);
    try testing.expect(code.style.dim);

    try testing.expectEqual(@as(?Piece, null), it.next());
}

test "an unclosed marker is emitted literally" {
    var it: Inline = .init("a **b", .{});
    try testing.expectEqualStrings("a **b", it.next().?.bytes);
    try testing.expectEqual(@as(?Piece, null), it.next());
}

test "markers inside a code span are literal" {
    var it: Inline = .init("`a **b** c`", .{});
    const code = it.next().?;
    try testing.expectEqualStrings("a **b** c", code.bytes);
    try testing.expect(code.style.dim);
    try testing.expectEqual(@as(?Piece, null), it.next());
}

test "the base style is inherited by every piece" {
    var it: Inline = .init("a `b`", .{ .bold = true });
    const plain = it.next().?;
    try testing.expect(plain.style.bold);
    const code = it.next().?;
    try testing.expect(code.style.bold and code.style.dim);
}

test "an empty span is literal text, not an empty piece" {
    var it: Inline = .init("****", .{});
    const piece = it.next().?;
    try testing.expectEqualStrings("****", piece.bytes);
    try testing.expectEqual(Style{}, piece.style);
    try testing.expectEqual(@as(?Piece, null), it.next());
}

test "the iterator always terminates on adversarial input" {
    const cases = [_][]const u8{ "*", "**", "***", "`", "``", "*`*`", "**`**`", "" };
    for (cases) |case| {
        var it: Inline = .init(case, .{});
        var guard: usize = 0;
        while (it.next()) |_| {
            guard += 1;
            try testing.expect(guard <= case.len + 1);
        }
    }
}
