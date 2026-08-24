//! The draft, and nothing else.
//!
//! Bytes, a cursor, and one kill slot. No terminal, no screen, no allocator
//! held across a call that does not need one. Everything here is a pure
//! function of the buffer's own state, which is what lets the whole emacs set
//! be tested without a pty in sight.
//!
//! The cursor is a **byte offset** and every movement lands on a codepoint
//! boundary. Storing a codepoint index instead would make every edit an O(n)
//! re-scan to find the bytes; storing a byte offset makes every *movement* the
//! O(1) one, and movement is what a keypress does.
//!
//! `up` and `down` move between **logical** lines — the ones separated by an
//! embedded `\n` — not between the physical rows a narrow terminal wraps them
//! into. The editor cannot see the terminal's width, and giving it one would
//! put the wrap in two places (`DR-011` puts it in exactly one).

const std = @import("std");

const width_mod = @import("../render/width.zig");

pub const Edge = enum { moved, at_edge };

/// Whitespace for word movement: the three bytes a draft can actually contain
/// after the decoder's paste filter. Deliberately ASCII — a Unicode word
/// segmenter is a `DR-005` conversation (graphemes, v0.9), not a v0.1 one.
fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n';
}

/// The codepoint boundary at or before `index`.
fn prevBoundary(text: []const u8, index: usize) usize {
    if (index == 0) return 0;
    var at = index - 1;
    // Continuation bytes are 10xxxxxx. Walking back over them lands on the
    // lead byte, which is the boundary.
    while (at > 0 and text[at] & 0xc0 == 0x80) at -= 1;
    return at;
}

/// The codepoint boundary after `index`.
fn nextBoundary(text: []const u8, index: usize) usize {
    if (index >= text.len) return text.len;
    const length = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
    return @min(index + length, text.len);
}

fn lineStart(text: []const u8, index: usize) usize {
    if (std.mem.lastIndexOfScalar(u8, text[0..index], '\n')) |at| return at + 1;
    return 0;
}

fn lineEnd(text: []const u8, index: usize) usize {
    if (std.mem.indexOfScalar(u8, text[index..], '\n')) |at| return index + at;
    return text.len;
}

/// The offset into `line` at the first codepoint boundary whose display column
/// reaches `goal`, or the end of the line when it is shorter than that.
///
/// Cells rather than codepoints, because a CJK character occupies two of them
/// and a cursor that ignored the difference would land visibly in the wrong
/// place on the row above.
fn columnToOffset(line: []const u8, goal: usize) usize {
    var column: usize = 0;
    var at: usize = 0;
    while (at < line.len) {
        if (column >= goal) return at;
        const end = nextBoundary(line, at);
        column += width_mod.stringWidth(line[at..end]);
        at = end;
    }
    return line.len;
}

pub const Editor = struct {
    gpa: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    /// A byte offset, always on a codepoint boundary.
    cursor: usize = 0,
    /// One slot, per the scope guard. A kill ring is post-v0.1.
    kill: std.ArrayList(u8) = .empty,
    /// The display column a run of `up`/`down` is aiming for.
    ///
    /// Sticky, because recomputing it from the cursor on every press makes the
    /// cursor drift left: pass over a short line and the goal shrinks to that
    /// line's width, permanently. Every editor remembers the column instead,
    /// and every other movement and edit clears it.
    goal_column: ?usize = null,

    pub fn init(gpa: std.mem.Allocator) Editor {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Editor) void {
        self.text.deinit(self.gpa);
        self.kill.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn items(self: *const Editor) []const u8 {
        return self.text.items;
    }

    pub fn isEmpty(self: *const Editor) bool {
        return self.text.items.len == 0;
    }

    pub fn clear(self: *Editor) void {
        self.text.clearRetainingCapacity();
        self.setCursor(0);
    }

    /// Moves the cursor and forgets the vertical goal, which is what every
    /// method below `moveUp`/`moveDown` wants and what a bare field assignment
    /// would silently skip.
    pub fn setCursor(self: *Editor, at: usize) void {
        self.cursor = at;
        self.goal_column = null;
    }

    pub fn setText(self: *Editor, text: []const u8) std.mem.Allocator.Error!void {
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(self.gpa, text);
        self.setCursor(self.text.items.len);
    }

    /// Inserts at the cursor. One call, whatever the size — a paste is a single
    /// insert and therefore a single repaint, which is the whole of what
    /// "atomically" means here.
    pub fn insert(self: *Editor, bytes: []const u8) std.mem.Allocator.Error!void {
        if (bytes.len == 0) return;
        try self.text.ensureUnusedCapacity(self.gpa, bytes.len);
        const old_len = self.text.items.len;
        self.text.items.len = old_len + bytes.len;
        const text = self.text.items;
        // Backwards: source and destination overlap and the destination starts
        // later, so a forward copy would eat its own tail.
        std.mem.copyBackwards(u8, text[self.cursor + bytes.len ..], text[self.cursor..old_len]);
        @memcpy(text[self.cursor..][0..bytes.len], bytes);
        self.setCursor(self.cursor + bytes.len);
    }

    pub fn insertCodepoint(self: *Editor, codepoint: u21) std.mem.Allocator.Error!void {
        var buffer: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(codepoint, &buffer) catch return;
        try self.insert(buffer[0..length]);
    }

    pub fn moveLeft(self: *Editor) void {
        self.setCursor(prevBoundary(self.text.items, self.cursor));
    }

    pub fn moveRight(self: *Editor) void {
        self.setCursor(nextBoundary(self.text.items, self.cursor));
    }

    pub fn moveLineStart(self: *Editor) void {
        self.setCursor(lineStart(self.text.items, self.cursor));
    }

    pub fn moveLineEnd(self: *Editor) void {
        self.setCursor(lineEnd(self.text.items, self.cursor));
    }

    pub fn moveWordLeft(self: *Editor) void {
        self.setCursor(self.wordLeft());
    }

    pub fn moveWordRight(self: *Editor) void {
        self.setCursor(self.wordRight());
    }

    /// Where `alt+b` and `ctrl+w` both aim: back over any whitespace, then back
    /// over the word behind it.
    fn wordLeft(self: *const Editor) usize {
        const text = self.text.items;
        var at = self.cursor;
        while (at > 0 and isSpace(text[at - 1])) at -= 1;
        while (at > 0 and !isSpace(text[at - 1])) at = prevBoundary(text, at);
        return at;
    }

    fn wordRight(self: *const Editor) usize {
        const text = self.text.items;
        var at = self.cursor;
        while (at < text.len and isSpace(text[at])) at += 1;
        while (at < text.len and !isSpace(text[at])) at = nextBoundary(text, at);
        return at;
    }

    pub fn moveUp(self: *Editor) Edge {
        const text = self.text.items;
        const start = lineStart(text, self.cursor);
        if (start == 0) return .at_edge;
        const goal = self.goalColumn(text, start);
        const previous = lineStart(text, start - 1);
        self.cursor = previous + columnToOffset(text[previous .. start - 1], goal);
        return .moved;
    }

    pub fn moveDown(self: *Editor) Edge {
        const text = self.text.items;
        const start = lineStart(text, self.cursor);
        const end = lineEnd(text, self.cursor);
        if (end == text.len) return .at_edge;
        const goal = self.goalColumn(text, start);
        const next = end + 1;
        self.cursor = next + columnToOffset(text[next..lineEnd(text, next)], goal);
        return .moved;
    }

    /// The column a vertical move aims for: the remembered one if this is not
    /// the first of a run, otherwise the cursor's own.
    fn goalColumn(self: *Editor, text: []const u8, start: usize) usize {
        const goal = self.goal_column orelse width_mod.stringWidth(text[start..self.cursor]);
        self.goal_column = goal;
        return goal;
    }

    pub fn deleteBack(self: *Editor) void {
        const at = prevBoundary(self.text.items, self.cursor);
        self.removeRange(at, self.cursor);
    }

    pub fn deleteForward(self: *Editor) void {
        const to = nextBoundary(self.text.items, self.cursor);
        self.removeRange(self.cursor, to);
    }

    pub fn killWordBack(self: *Editor) std.mem.Allocator.Error!void {
        try self.killRange(self.wordLeft(), self.cursor);
    }

    pub fn killToLineStart(self: *Editor) std.mem.Allocator.Error!void {
        try self.killRange(lineStart(self.text.items, self.cursor), self.cursor);
    }

    pub fn killToLineEnd(self: *Editor) std.mem.Allocator.Error!void {
        try self.killRange(self.cursor, lineEnd(self.text.items, self.cursor));
    }

    pub fn yank(self: *Editor) std.mem.Allocator.Error!void {
        // The kill slot is the source and `insert` may reallocate `text`, but
        // the two lists are separate allocations, so the slice stays valid.
        try self.insert(self.kill.items);
    }

    /// Moves `[from, to)` into the kill slot, replacing whatever was there.
    fn killRange(self: *Editor, from: usize, to: usize) std.mem.Allocator.Error!void {
        if (to <= from) return;
        self.kill.clearRetainingCapacity();
        try self.kill.appendSlice(self.gpa, self.text.items[from..to]);
        self.removeRange(from, to);
    }

    fn removeRange(self: *Editor, from: usize, to: usize) void {
        if (to <= from) return;
        const text = self.text.items;
        std.mem.copyForwards(u8, text[from..], text[to..]);
        self.text.items.len -= to - from;
        self.setCursor(from);
    }
};

const testing = std.testing;

test "typing lands bytes at the cursor and moves it along" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();

    try editor.insert("hello");
    try testing.expectEqualStrings("hello", editor.items());
    try testing.expectEqual(@as(usize, 5), editor.cursor);

    editor.moveLineStart();
    try editor.insert("say ");
    try testing.expectEqualStrings("say hello", editor.items());
    try testing.expectEqual(@as(usize, 4), editor.cursor);
}

test "movement steps whole codepoints, never bytes" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();

    // Three codepoints, seven bytes: 1 + 3 + 3.
    try editor.insert("a\u{4e16}\u{754c}");
    try testing.expectEqual(@as(usize, 7), editor.cursor);

    editor.moveLeft();
    try testing.expectEqual(@as(usize, 4), editor.cursor);
    editor.moveLeft();
    try testing.expectEqual(@as(usize, 1), editor.cursor);
    editor.moveLeft();
    try testing.expectEqual(@as(usize, 0), editor.cursor);
    // Already home: another press is not an underflow.
    editor.moveLeft();
    try testing.expectEqual(@as(usize, 0), editor.cursor);

    editor.moveRight();
    try testing.expectEqual(@as(usize, 1), editor.cursor);
    editor.moveRight();
    try testing.expectEqual(@as(usize, 4), editor.cursor);
}

test "backspace removes a codepoint, not a byte" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();

    try editor.insert("a\u{4e16}");
    editor.deleteBack();
    try testing.expectEqualStrings("a", editor.items());
    editor.deleteBack();
    try testing.expectEqualStrings("", editor.items());
    editor.deleteBack();
    try testing.expectEqualStrings("", editor.items());
}

test "delete forward removes the codepoint under the cursor" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();

    try editor.insert("a\u{4e16}b");
    editor.moveLineStart();
    editor.deleteForward();
    try testing.expectEqualStrings("\u{4e16}b", editor.items());
    editor.deleteForward();
    try testing.expectEqualStrings("b", editor.items());
    editor.deleteForward();
    try testing.expectEqualStrings("", editor.items());
    editor.deleteForward();
    try testing.expectEqualStrings("", editor.items());
}

test "word movement skips whitespace then the word" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();

    try editor.insert("alpha  beta gamma");
    editor.moveWordLeft();
    try testing.expectEqual(@as(usize, 12), editor.cursor); // start of "gamma"
    editor.moveWordLeft();
    try testing.expectEqual(@as(usize, 7), editor.cursor); // start of "beta"
    editor.moveWordLeft();
    try testing.expectEqual(@as(usize, 0), editor.cursor);
    editor.moveWordLeft();
    try testing.expectEqual(@as(usize, 0), editor.cursor);

    editor.moveWordRight();
    try testing.expectEqual(@as(usize, 5), editor.cursor); // end of "alpha"
    editor.moveWordRight();
    try testing.expectEqual(@as(usize, 11), editor.cursor); // end of "beta"
    editor.moveWordRight();
    try testing.expectEqual(@as(usize, 17), editor.cursor);
    editor.moveWordRight();
    try testing.expectEqual(@as(usize, 17), editor.cursor);
}

test "line start and end stop at the embedded newlines" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();

    try editor.insert("one\ntwo\nthree");
    editor.moveLineStart();
    try testing.expectEqual(@as(usize, 8), editor.cursor);
    editor.moveLineEnd();
    try testing.expectEqual(@as(usize, 13), editor.cursor);

    editor.setCursor(5);
    editor.moveLineStart();
    try testing.expectEqual(@as(usize, 4), editor.cursor);
    editor.moveLineEnd();
    try testing.expectEqual(@as(usize, 7), editor.cursor);
}

test "up and down keep the display column and report the edges" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();

    try editor.insert("alpha\nhi\nomega");
    // Cursor at the end of "omega", display column 5.
    try testing.expectEqual(Edge.moved, editor.moveUp());
    // "hi" is only two cells wide, so the cursor clamps to its end.
    try testing.expectEqual(@as(usize, 8), editor.cursor);
    try testing.expectEqual(Edge.moved, editor.moveUp());
    // Back on "alpha", and the goal column of 5 is restored.
    try testing.expectEqual(@as(usize, 5), editor.cursor);
    try testing.expectEqual(Edge.at_edge, editor.moveUp());
    try testing.expectEqual(@as(usize, 5), editor.cursor);

    editor.setCursor(0);
    try testing.expectEqual(Edge.moved, editor.moveDown());
    try testing.expectEqual(@as(usize, 6), editor.cursor);
    try testing.expectEqual(Edge.moved, editor.moveDown());
    try testing.expectEqual(@as(usize, 9), editor.cursor);
    try testing.expectEqual(Edge.at_edge, editor.moveDown());
    try testing.expectEqual(@as(usize, 9), editor.cursor);
}

test "the goal column is measured in cells, not codepoints" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();

    // Two wide codepoints are four cells, so a goal column of six clamps to the
    // end of that line rather than landing six codepoints into it.
    try editor.insert("\u{4e16}\u{754c}\nabcdef");
    editor.moveLineEnd();
    try testing.expectEqual(Edge.moved, editor.moveUp());
    try testing.expectEqual(@as(usize, 6), editor.cursor);

    // And back down returns to column six, not to the four the clamp left the
    // cursor on. That is the whole point of remembering the goal.
    try testing.expectEqual(Edge.moved, editor.moveDown());
    try testing.expectEqual(@as(usize, 13), editor.cursor);
}

test "a horizontal move forgets the vertical goal" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();

    try editor.insert("alpha\nhi\nomega");
    try testing.expectEqual(Edge.moved, editor.moveUp()); // onto "hi", clamped
    editor.moveLeft();
    try testing.expectEqual(@as(usize, 7), editor.cursor);

    // The goal is gone, so this aims at column one rather than at column five.
    try testing.expectEqual(Edge.moved, editor.moveUp());
    try testing.expectEqual(@as(usize, 1), editor.cursor);
}

test "the three kills fill one slot and yank puts it back" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();

    try editor.insert("alpha beta");
    try editor.killWordBack();
    try testing.expectEqualStrings("alpha ", editor.items());
    try editor.yank();
    try testing.expectEqualStrings("alpha beta", editor.items());

    editor.moveLineStart();
    editor.moveWordRight();
    try editor.killToLineEnd();
    try testing.expectEqualStrings("alpha", editor.items());
    try editor.killToLineStart();
    try testing.expectEqualStrings("", editor.items());

    // One slot: the last kill is what a yank produces.
    try editor.yank();
    try testing.expectEqualStrings("alpha", editor.items());
}

test "a kill spanning a newline stays inside its own line" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();

    try editor.insert("one\ntwo");
    try editor.killToLineStart();
    try testing.expectEqualStrings("one\n", editor.items());
    try testing.expectEqual(@as(usize, 4), editor.cursor);

    editor.setCursor(0);
    try editor.killToLineEnd();
    try testing.expectEqualStrings("\n", editor.items());
}

test "setText replaces everything and parks the cursor at the end" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();

    try editor.insert("draft");
    try editor.setText("recalled\nentry");
    try testing.expectEqualStrings("recalled\nentry", editor.items());
    try testing.expectEqual(@as(usize, 14), editor.cursor);

    editor.clear();
    try testing.expect(editor.isEmpty());
    try testing.expectEqual(@as(usize, 0), editor.cursor);
}

test "an insert in the middle does not disturb what follows it" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();

    try editor.insert("ac");
    editor.moveLeft();
    try editor.insertCodepoint('b');
    try testing.expectEqualStrings("abc", editor.items());
    try testing.expectEqual(@as(usize, 2), editor.cursor);

    // A paste is an insert like any other, and its newlines are just bytes.
    editor.moveLineEnd();
    try editor.insert("\nsecond line");
    try testing.expectEqualStrings("abc\nsecond line", editor.items());
}
