//! The draft, as physical rows and a cursor cell.
//!
//! This is the *second* thing in tug that turns text into rows, and the
//! duplication is deliberate — `DR-011` is the argument. In one sentence: the
//! renderer's `wrap` breaks at spaces, and a prompt that breaks at spaces moves
//! the character under your cursor to another row while you are typing the word
//! in front of it. Every line editor anyone has ever used breaks at the column
//! instead, and breaking at the column also makes the cursor cell a running
//! total rather than something recoverable from a word buffer that has not been
//! flushed yet.
//!
//! The contract with the renderer is exactly two numbers: how many rows were
//! emitted, and where in them the cursor landed. The renderer needs the first
//! to keep `tail_rows` honest and the second to leave the cursor somewhere a
//! human would expect. Nothing here writes an escape sequence other than the
//! `\r\n` between rows; the cursor move belongs to `paint`, because `paint`
//! owns the frame.
//!
//! **Windowing.** A draft can be taller than the screen — one paste is enough —
//! and the tail must stay inside `capacity` rows or the cursor-up that starts
//! the next frame cannot reach its top. So `max_rows` is a hard cap and the
//! rows emitted are the window that contains the cursor. Scrolled-off rows are
//! still in the buffer; they are simply not on screen, which is what every
//! editor does with a document longer than a window.

const std = @import("std");

const width_mod = @import("width.zig");

pub const Prompt = struct {
    text: []const u8,
    /// A byte offset into `text`, on a codepoint boundary. Out of range is
    /// treated as the end, because a stale cursor should misplace a caret
    /// rather than read past a buffer.
    cursor: usize,
};

/// What one render put on screen.
///
/// `rows` is what was emitted — never more than `max_rows`. `total` is what the
/// draft would occupy unwindowed, which makes the windowing testable without
/// counting `\r\n` in a byte string. `cursor_row` is relative to the emitted
/// window.
pub const Placement = struct {
    rows: u32 = 0,
    total: u32 = 0,
    cursor_row: u32 = 0,
    cursor_col: u16 = 0,
};

pub const Error = std.Io.Writer.Error;

pub const marker = "> ";
pub const continuation = "  ";

/// Both prefixes are this wide, so a wrapped draft stays aligned under the
/// first row's text and the row arithmetic has one indent rather than two.
const indent: usize = 2;

/// Matches the renderer's own expansion, so a tab looks the same in a draft as
/// it does once the draft has been echoed into scrollback.
const tab_width: usize = 4;

/// Below two columns there is nothing sensible to wrap to. Identical to the
/// renderer's constant and for the identical reason.
const min_cols: usize = 2;

/// C0, DEL, and the C1 block: everything a terminal acts on rather than draws.
///
/// Lives here rather than in `renderer.zig` because both files need it and this
/// one is the leaf — `renderer.zig` imports `prompt.zig` and not the reverse.
pub fn isControl(codepoint: u21) bool {
    return codepoint < 0x20 or (codepoint >= 0x7f and codepoint < 0xa0);
}

/// Hard-wraps `prompt` at `cols` and emits the `max_rows`-row window that
/// contains the cursor.
///
/// With a null writer it walks identically and emits nothing, which is what
/// makes the count and the output unable to disagree — the same discipline
/// `Renderer.wrap` uses, for the same reason.
pub fn render(prompt: Prompt, cols: u16, max_rows: u32, out: ?*std.Io.Writer) Error!Placement {
    const limit = @max(1, max_rows);

    const measured = try walk(prompt, cols, 0, std.math.maxInt(u32), null);
    if (measured.total <= limit) return walk(prompt, cols, 0, limit, out);

    // The window ends on the cursor's row unless that would scroll past the
    // end, which is the behaviour of every editor: you see what you are typing
    // and as much of what precedes it as fits.
    const last_start = measured.total - limit;
    const first = @min(last_start, measured.cursor_row -| (limit - 1));
    return walk(prompt, cols, first, limit, out);
}

/// One pass over the draft. `first` is the first row index to emit and `limit`
/// how many; rows outside that range are counted and discarded.
fn walk(prompt: Prompt, cols: u16, first: u32, limit: u32, out: ?*std.Io.Writer) Error!Placement {
    const usable: usize = @max(min_cols, cols);

    // The marker is dropped rather than shrunk when the terminal is too narrow
    // to hold it plus a wide character. Emitting it anyway would overflow the
    // row, the terminal would wrap it, and the row count would be out by one
    // before a character of the draft had been drawn. It also guarantees
    // `usable - hanging >= 2`, which is what stops `put` from looping on a
    // codepoint too wide for the row it would break onto.
    const hanging: usize = if (usable < indent + 2) 0 else indent;

    var layout: Layout = .{
        .out = out,
        .cols = usable,
        .hanging = hanging,
        .first = first,
        .limit = limit,
        .column = hanging,
    };

    var at: usize = 0;
    while (at < prompt.text.len) {
        if (at == prompt.cursor) try layout.mark();

        const length = std.unicode.utf8ByteSequenceLength(prompt.text[at]) catch 1;
        const end = @min(at + length, prompt.text.len);
        const slice = prompt.text[at..end];
        at = end;

        if (slice.len == 1) switch (slice[0]) {
            '\n' => {
                try layout.breakRow();
                continue;
            },
            '\t' => {
                for (0..tab_width) |_| try layout.put(" ", 1);
                continue;
            },
            else => {},
        };

        // Decoded rather than sniffed byte by byte: U+009B is an eight-bit CSI
        // and U+0085 moves the cursor down a row, and both are two bytes in
        // UTF-8. A byte-level filter lets them straight through.
        const codepoint = std.unicode.utf8Decode(slice) catch std.unicode.replacement_character;
        if (isControl(codepoint)) continue;

        try layout.put(slice, width_mod.stringWidth(slice));
    }
    if (prompt.cursor >= prompt.text.len) try layout.mark();

    return layout.finish();
}

/// The row machine. Pulled out of `walk` so "start a row", "end a row" and
/// "this row is outside the window" are three named things rather than three
/// copies of the same condition.
const Layout = struct {
    out: ?*std.Io.Writer,
    cols: usize,
    hanging: usize,
    first: u32,
    limit: u32,

    /// The absolute row index, counting from the top of the draft.
    row: u32 = 0,
    column: usize,
    /// How many rows have actually been written.
    emitted: u32 = 0,
    /// Whether the current row's prefix has been written.
    open: bool = false,
    found: bool = false,
    place: Placement = .{},

    fn inWindow(self: *const Layout) bool {
        return self.row >= self.first and self.emitted < self.limit;
    }

    /// Writes the row's prefix, the first time anything lands on it.
    ///
    /// Deferred rather than written at the break, because a row outside the
    /// window must produce no bytes at all and the window test is cheapest
    /// here.
    fn openRow(self: *Layout) Error!void {
        if (self.open or !self.inWindow()) return;
        self.open = true;
        if (self.hanging == 0) return;
        if (self.out) |writer| {
            try writer.writeAll(if (self.row == 0) marker else continuation);
        }
    }

    fn breakRow(self: *Layout) Error!void {
        if (self.inWindow()) {
            try self.openRow();
            if (self.out) |writer| try writer.writeAll("\r\n");
            self.emitted += 1;
        }
        self.open = false;
        self.row += 1;
        self.column = self.hanging;
    }

    fn put(self: *Layout, slice: []const u8, cells: usize) Error!void {
        if (self.column + cells > self.cols) try self.breakRow();
        try self.openRow();
        if (self.inWindow()) {
            if (self.out) |writer| try writer.writeAll(slice);
        }
        self.column += cells;
    }

    /// Records where the cursor landed.
    ///
    /// A cursor sitting at the far edge of a full row has no column to occupy —
    /// columns run to `cols - 1` — so the row is broken first and the cursor
    /// goes to the head of the next one. That is also what the next character
    /// typed would do, which is the point: the caret sits where the text will.
    fn mark(self: *Layout) Error!void {
        if (self.found) return;
        if (self.column >= self.cols) try self.breakRow();
        self.found = true;
        self.place.cursor_row = self.row;
        self.place.cursor_col = @intCast(self.column);
    }

    fn finish(self: *Layout) Error!Placement {
        // The last row ends with its own `\r\n`, like every other row the
        // renderer emits, so the caller's cursor arithmetic has one rule.
        try self.breakRow();

        self.place.rows = self.emitted;
        self.place.total = self.row;
        // Relative to the window, now that the window is known.
        self.place.cursor_row -|= self.first;
        return self.place;
    }
};

const testing = std.testing;

/// Paints once into a fixed buffer and returns both the placement and the bytes.
fn place(text: []const u8, cursor: usize, cols: u16, max_rows: u32, buffer: []u8) !struct {
    placement: Placement,
    output: []const u8,
} {
    var writer: std.Io.Writer = .fixed(buffer);
    const placement = try render(.{ .text = text, .cursor = cursor }, cols, max_rows, &writer);
    return .{ .placement = placement, .output = writer.buffered() };
}

test "an empty draft is one row holding just the marker" {
    var buffer: [256]u8 = undefined;
    const result = try place("", 0, 20, 8, &buffer);

    try testing.expectEqual(@as(u32, 1), result.placement.rows);
    try testing.expectEqual(@as(u32, 1), result.placement.total);
    try testing.expectEqual(@as(u32, 0), result.placement.cursor_row);
    try testing.expectEqual(@as(u16, 2), result.placement.cursor_col);
    try testing.expectEqualStrings("> \r\n", result.output);
}

test "a short draft is one row and the cursor sits after what was typed" {
    var buffer: [256]u8 = undefined;
    const result = try place("hello", 5, 20, 8, &buffer);

    try testing.expectEqual(@as(u32, 1), result.placement.rows);
    try testing.expectEqual(@as(u16, 7), result.placement.cursor_col);
    try testing.expectEqualStrings("> hello\r\n", result.output);
}

test "the cursor in the middle reports the cell it is on" {
    var buffer: [256]u8 = undefined;
    const result = try place("hello", 2, 20, 8, &buffer);
    try testing.expectEqual(@as(u32, 0), result.placement.cursor_row);
    try testing.expectEqual(@as(u16, 4), result.placement.cursor_col);
}

test "an embedded newline starts a row with the continuation indent" {
    var buffer: [256]u8 = undefined;
    const result = try place("one\ntwo", 7, 20, 8, &buffer);

    try testing.expectEqual(@as(u32, 2), result.placement.rows);
    try testing.expectEqual(@as(u32, 1), result.placement.cursor_row);
    try testing.expectEqual(@as(u16, 5), result.placement.cursor_col);
    try testing.expectEqualStrings("> one\r\n  two\r\n", result.output);
}

test "a long line breaks at the column, not at a space" {
    var buffer: [256]u8 = undefined;
    // Ten columns, two of them the marker: eight cells of content per row.
    const result = try place("abcdefghijkl", 12, 10, 8, &buffer);

    try testing.expectEqual(@as(u32, 2), result.placement.rows);
    try testing.expectEqualStrings("> abcdefgh\r\n  ijkl\r\n", result.output);
    try testing.expectEqual(@as(u32, 1), result.placement.cursor_row);
    try testing.expectEqual(@as(u16, 6), result.placement.cursor_col);
}

test "a wide codepoint never straddles the last column" {
    var buffer: [256]u8 = undefined;
    // Seven columns: two for the marker, five for content, so two wide
    // characters fit and the third must break.
    const result = try place("\u{4e16}\u{754c}\u{4e16}", 9, 7, 8, &buffer);

    try testing.expectEqual(@as(u32, 2), result.placement.rows);
    try testing.expectEqualStrings("> \u{4e16}\u{754c}\r\n  \u{4e16}\r\n", result.output);
    try testing.expectEqual(@as(u32, 1), result.placement.cursor_row);
    try testing.expectEqual(@as(u16, 4), result.placement.cursor_col);
}

test "a cursor at a full row lands at the start of the next one" {
    var buffer: [256]u8 = undefined;
    // Exactly one row of content, cursor at the end: the terminal has no
    // column to put it in, so it belongs at the head of the row below.
    const result = try place("abcdefgh", 8, 10, 8, &buffer);

    try testing.expectEqual(@as(u32, 2), result.placement.rows);
    try testing.expectEqual(@as(u32, 1), result.placement.cursor_row);
    try testing.expectEqual(@as(u16, 2), result.placement.cursor_col);
    try testing.expectEqualStrings("> abcdefgh\r\n  \r\n", result.output);
}

test "a tab is spaces, and a control character is nothing at all" {
    var buffer: [256]u8 = undefined;
    const tabbed = try place("a\tb", 3, 20, 8, &buffer);
    try testing.expectEqualStrings("> a    b\r\n", tabbed.output);

    var second: [256]u8 = undefined;
    // An ESC that somehow reached the draft must never reach the terminal.
    const escaped = try place("a\x1bb", 3, 20, 8, &second);
    try testing.expectEqualStrings("> ab\r\n", escaped.output);
}

test "a draft taller than the window shows the rows around the cursor" {
    var buffer: [512]u8 = undefined;
    // Six logical lines, a three-row window.
    const text = "l1\nl2\nl3\nl4\nl5\nl6";

    // Cursor on the last line: the window is the last three rows.
    const bottom = try place(text, text.len, 20, 3, &buffer);
    try testing.expectEqual(@as(u32, 3), bottom.placement.rows);
    try testing.expectEqual(@as(u32, 6), bottom.placement.total);
    try testing.expectEqual(@as(u32, 2), bottom.placement.cursor_row);
    try testing.expectEqualStrings("  l4\r\n  l5\r\n  l6\r\n", bottom.output);

    // Cursor on the first line: the window is the first three rows, and the
    // first of them still carries the marker.
    var top_buffer: [512]u8 = undefined;
    const top = try place(text, 0, 20, 3, &top_buffer);
    try testing.expectEqual(@as(u32, 3), top.placement.rows);
    try testing.expectEqual(@as(u32, 0), top.placement.cursor_row);
    try testing.expectEqualStrings("> l1\r\n  l2\r\n  l3\r\n", top.output);

    // Cursor in the middle: the window ends on the cursor's row.
    var middle_buffer: [512]u8 = undefined;
    const middle = try place(text, 12, 20, 3, &middle_buffer);
    try testing.expectEqual(@as(u32, 2), middle.placement.cursor_row);
    try testing.expectEqualStrings("  l3\r\n  l4\r\n  l5\r\n", middle.output);
}

test "a terminal too narrow for the marker drops it rather than miscounting" {
    var buffer: [256]u8 = undefined;
    const result = try place("abcd", 4, 2, 8, &buffer);

    // Two columns, no marker, two characters per row plus the cursor's row.
    try testing.expectEqual(@as(u32, 3), result.placement.total);
    try testing.expectEqualStrings("ab\r\ncd\r\n\r\n", result.output);
}

test "measuring emits nothing and counts the same rows as drawing" {
    const text = "the quick brown fox jumps over the lazy dog";
    const measured = try render(.{ .text = text, .cursor = text.len }, 16, 64, null);

    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const drawn = try render(.{ .text = text, .cursor = text.len }, 16, 64, &writer);

    try testing.expectEqual(measured.rows, drawn.rows);
    try testing.expectEqual(measured.cursor_row, drawn.cursor_row);
    try testing.expectEqual(measured.cursor_col, drawn.cursor_col);
    try testing.expect(writer.buffered().len > 0);
}
