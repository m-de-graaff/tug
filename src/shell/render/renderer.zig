//! Streaming into normal scrollback, without ever rewriting it.
//!
//! The screen has two regions and they never mix. **Committed scrollback** has
//! been printed and belongs to the terminal from that moment on — tug will not
//! move the cursor over it again, which is why reflowing it on a resize is the
//! terminal's problem and why a crash cannot corrupt it. The **active tail** is
//! the last few rows: erased and repainted every frame, and bounded to fit on
//! screen so the cursor-up that starts a repaint can always reach its top row.
//!
//! A frame is one buffer and one flush:
//!
//!     [?2026h]  \r  CPL(tail_rows)  ED(0)  <aged-out rows>  <tail rows>  [?2026l]
//!
//! and it always ends having emitted `\r\n` after its last row, so the cursor
//! parks at column 0 of a fresh row below the tail. That is the invariant every
//! piece of arithmetic here rests on: `tail_rows` counts the rows *above* the
//! cursor that belong to the tail, and the next frame moves up exactly that
//! many. One too high and the repaint erases a line of the user's scrollback,
//! permanently. One too low and the old tail is left on screen under the new.
//!
//! Rows are counted by the same function that emits them, called once with a
//! null writer to measure and once with the real one to draw. Two functions
//! would drift, and drift here is exactly the failure above.

const std = @import("std");

const backend = @import("../term/backend.zig");
const caps_mod = @import("../term/caps.zig");
const md = @import("markdown.zig");
const prompt_mod = @import("prompt.zig");
const width_mod = @import("width.zig");

pub const Size = backend.Size;
pub const Capabilities = caps_mod.Capabilities;

pub const BlockKind = enum { user, assistant, notice };

pub const Prompt = prompt_mod.Prompt;

/// What one paint put on screen. `committed_rows` have gone into scrollback and
/// will never be repainted; `tail_rows` are the ones the next paint moves back
/// over. `cursor_row` and `cursor_col` are where the cursor was left inside the
/// tail, and are zero when there is no prompt — in which case it parks below
/// the tail as it has since Phase 4.
pub const Frame = struct {
    committed_rows: u32 = 0,
    tail_rows: u32 = 0,
    cursor_row: u32 = 0,
    cursor_col: u16 = 0,
};

pub const Error = std.Io.Writer.Error || std.mem.Allocator.Error;

/// The status hint: one dim row while a block is open, gone the moment it
/// commits (`DR-008`). ASCII on purpose — a status line is the last place to
/// discover that a terminal disagrees about a glyph's width.
const status_hint = "... streaming";

/// Below two columns there is nothing sensible to wrap to: a single wide
/// character would not fit on a row of its own, and every row the renderer
/// emitted would be re-wrapped by the terminal underneath it, which puts the
/// row count out. A one-column terminal is documented as unsupported rather
/// than silently mis-counted.
const min_cols: usize = 2;

/// A tab is expanded to this many spaces before wrapping. Terminals advance to
/// the next eight-column stop, which the renderer cannot reproduce without
/// tracking absolute columns through a soft wrap; expanding here means the wrap
/// arithmetic and the screen agree, which is the thing that must not drift.
const tab_width: usize = 4;

fn isPlain(style: md.Style) bool {
    return @as(u8, @bitCast(style)) == 0;
}

/// The bytes that move the terminal from `from` to `to`.
///
/// SGR 22 turns off bold *and* dim together, so an incremental encoding would
/// have to track which of the two a `22` was meant to clear. A reset costs four
/// bytes and removes the question — and is skipped entirely when there is
/// nothing to reset, which is what keeps a plain paragraph free of escapes.
fn styleBytes(from: md.Style, to: md.Style, buffer: *[16]u8) []const u8 {
    var len: usize = 0;
    const put = struct {
        fn f(buf: *[16]u8, n: *usize, bytes: []const u8) void {
            @memcpy(buf[n.*..][0..bytes.len], bytes);
            n.* += bytes.len;
        }
    }.f;

    if (!isPlain(from)) put(buffer, &len, "\x1b[0m");
    if (to.bold) put(buffer, &len, "\x1b[1m");
    if (to.dim) put(buffer, &len, "\x1b[2m");
    if (to.italic) put(buffer, &len, "\x1b[3m");
    return buffer[0..len];
}

/// The longest complete UTF-8 prefix of `bytes`.
///
/// The tail's incomplete trailing line can end mid-codepoint, and painting half
/// a codepoint puts a replacement character on screen that vanishes on the next
/// frame. Holding the fragment back costs one comparison and one frame.
fn completePrefix(bytes: []const u8) usize {
    var index = bytes.len;
    var back: usize = 0;
    while (index > 0 and back < 4) : (back += 1) {
        index -= 1;
        const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch continue;
        // The last lead byte decides it: if its sequence is complete the whole
        // slice is usable, and if it is not, everything before it is.
        return if (index + length <= bytes.len) bytes.len else index;
    }
    return bytes.len;
}

/// The longest prefix of `text` that fits in `cols` cells, cut on a codepoint
/// boundary. Used only by the status hint, which has to fit on one row.
fn truncateToWidth(text: []const u8, cols: usize) []const u8 {
    var width: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch 1;
        const end = @min(index + length, text.len);
        const cells = width_mod.stringWidth(text[index..end]);
        if (width + cells > cols) return text[0..index];
        width += cells;
        index = end;
    }
    return text;
}

/// One logical line, and which block it came from. The block is stored per line
/// rather than read from the renderer's current block, because a frame can
/// carry the tail of one block and the start of the next.
const Entry = struct { line: md.Line, block: BlockKind };

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    caps: Capabilities,
    size: Size,

    /// Every logical line's bytes, back to back. `Line` ranges index into this.
    text: std.ArrayList(u8) = .empty,
    lines: std.ArrayList(Entry) = .empty,
    /// Bytes of the incomplete trailing line, which has no entry yet.
    partial: std.ArrayList(u8) = .empty,
    /// Rows per line, recomputed each paint. A field so the commit decision can
    /// be made without wrapping every line twice.
    row_cache: std.ArrayList(u32) = .empty,
    /// The word the wrapper has not committed to a row yet.
    word: std.ArrayList(u8) = .empty,

    block: ?BlockKind = null,
    in_fence: bool = false,
    /// Lines from the front belonging to blocks that have closed. They commit
    /// on the next paint no matter how much room is left.
    closed_lines: usize = 0,

    /// The draft, when one is being edited. Borrowed: valid from the
    /// `setPrompt` that installed it until the next one, which in practice
    /// means the session sets it immediately before each paint.
    prompt: ?Prompt = null,

    tail_rows: u32 = 0,
    /// How many rows above the parking row the last frame left the cursor. The
    /// next frame's rewind is short by exactly this much (`DR-011`).
    cursor_up: u32 = 0,
    painted: bool = false,
    /// The width the last frame was drawn at. A frame drawn at a different one
    /// cannot trust its own row count — see `paint`.
    painted_cols: u16 = 0,

    pub fn init(gpa: std.mem.Allocator, caps: Capabilities, size: Size) Renderer {
        return .{ .gpa = gpa, .caps = caps, .size = size };
    }

    pub fn deinit(self: *Renderer) void {
        self.text.deinit(self.gpa);
        self.lines.deinit(self.gpa);
        self.partial.deinit(self.gpa);
        self.row_cache.deinit(self.gpa);
        self.word.deinit(self.gpa);
        self.* = undefined;
    }

    /// A resize invalidates nothing but the wrap: lines are stored unwrapped
    /// precisely so this is a field assignment.
    ///
    /// `tail_rows` is a count taken at the *old* width and is deliberately left
    /// alone. Every terminal in the v0.1 matrix reflows its own scrollback on
    /// resize, so the rows the next paint moves back over are the reflowed
    /// ones; re-deriving the count here would mean assuming a reflow policy tug
    /// has no way to observe.
    pub fn setSize(self: *Renderer, size: Size) void {
        self.size = size;
    }

    /// Installs or removes the draft. Null means the session is not accepting
    /// input, and the tail ends where the content does.
    pub fn setPrompt(self: *Renderer, value: ?Prompt) void {
        self.prompt = value;
    }

    /// Replaces the capability set. Called once, after the probe: the first
    /// paint happens before the probe so the prompt is on screen inside the
    /// 10 ms budget, and the probe's answers arrive a frame later.
    pub fn setCaps(self: *Renderer, value: Capabilities) void {
        self.caps = value;
    }

    /// Clears the screen and forgets the tail.
    ///
    /// Not a repaint: it erases and then lets the next frame draw from the top,
    /// which is why `painted` goes false. The tail's *content* survives — this
    /// clears the screen, not the conversation.
    pub fn clearScreen(self: *Renderer, out: *std.Io.Writer) Error!void {
        try out.writeAll("\x1b[H\x1b[2J");
        self.painted = false;
        self.tail_rows = 0;
        self.cursor_up = 0;
    }

    pub fn beginBlock(self: *Renderer, kind: BlockKind) Error!void {
        if (self.block != null) try self.endBlock();
        self.block = kind;
        self.in_fence = false;
    }

    pub fn endBlock(self: *Renderer) Error!void {
        if (self.block == null) return;
        if (self.partial.items.len > 0) try self.finishLine();
        self.closed_lines = self.lines.items.len;
        self.block = null;
        self.in_fence = false;
    }

    /// Feeding without an open block opens an assistant one. A provider that
    /// starts sending before anyone said so is a bug somewhere else; losing the
    /// bytes over it would be a worse one.
    pub fn feed(self: *Renderer, bytes: []const u8) Error!void {
        if (self.block == null) try self.beginBlock(.assistant);

        var rest = bytes;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |newline| {
            try self.partial.appendSlice(self.gpa, rest[0..newline]);
            try self.finishLine();
            rest = rest[newline + 1 ..];
        }
        try self.partial.appendSlice(self.gpa, rest);
    }

    /// Turns the accumulated partial into a classified logical line.
    fn finishLine(self: *Renderer) Error!void {
        // Carriage returns arrive from providers that think they are writing to
        // a terminal. They are not markup and they would wreck the cursor
        // arithmetic, so they go rather than pass through.
        const raw = std.mem.trimEnd(u8, self.partial.items, "\r");
        const kind = self.block orelse .assistant;

        if (kind != .assistant) {
            try self.appendLine(kind, .{ .kind = .paragraph }, raw);
        } else if (md.isFence(raw)) {
            // The marker only toggles the state; it is never echoed.
            self.in_fence = !self.in_fence;
        } else {
            try self.appendLine(kind, md.classify(raw, self.in_fence), raw);
        }
        self.partial.clearRetainingCapacity();
    }

    fn appendLine(
        self: *Renderer,
        block: BlockKind,
        classified: md.Classified,
        raw: []const u8,
    ) Error!void {
        const content = raw[@min(classified.marker_len, raw.len)..];
        const start: u32 = @intCast(self.text.items.len);
        try self.text.appendSlice(self.gpa, content);
        try self.lines.append(self.gpa, .{
            .block = block,
            .line = .{
                .kind = classified.kind,
                .level = classified.level,
                .start = start,
                .len = @intCast(content.len),
            },
        });
    }

    /// User and notice blocks are text, not markdown. A user's own words are
    /// echoed as typed, and a notice is one sentence from tug itself.
    fn baseStyle(entry: Entry) md.Style {
        var style: md.Style = .{};
        switch (entry.block) {
            .assistant => {},
            .user => style.bold = true,
            .notice => style.dim = true,
        }
        switch (entry.line.kind) {
            .heading => style.bold = true,
            .code => style.dim = true,
            else => {},
        }
        return style;
    }

    fn markerFor(kind: md.LineKind, level: u8, buffer: []u8) []const u8 {
        return switch (kind) {
            .bullet => "\u{2022} ",
            .ordered => std.fmt.bufPrint(buffer, "{d}. ", .{level}) catch "- ",
            else => "",
        };
    }

    fn marker(entry: Entry, buffer: []u8) []const u8 {
        if (entry.block != .assistant) return "";
        return markerFor(entry.line.kind, entry.line.level, buffer);
    }

    pub fn paint(self: *Renderer, out: *std.Io.Writer) Error!Frame {
        // Two rows are held back: one for the status hint, and one so the
        // cursor's parking row is never the top of the screen.
        const capacity: u32 = @max(1, @as(u32, self.size.rows) -| 2);

        // A line that outgrows the screen before its newline arrives cannot be
        // committed — it is still being written — and would leave a tail the
        // cursor-up can no longer reach the top of. Ending it here splits the
        // line and loses nothing: the bytes are all still on their way to
        // scrollback, just as two lines instead of one.
        //
        // ponytail: the split lands wherever the wrap did, not at a word or a
        // sentence. A provider that streams a screenful without a newline is
        // getting the honest rendering of what it sent.
        if (self.partial.items.len > 0 and try self.renderPartial(null) > capacity) {
            try self.splitPartial();
        }

        try self.row_cache.resize(self.gpa, self.lines.items.len);
        var tail_total: u32 = 0;
        for (self.lines.items, self.row_cache.items) |entry, *rows| {
            rows.* = try self.renderEntry(entry, null);
            tail_total += rows.*;
        }
        tail_total += try self.renderPartial(null);
        const hint = self.block != null;
        if (hint) tail_total += try self.renderHint(null);

        // Measured before the aging loop, because the prompt is part of the
        // tail and content has to age out into scrollback to make room for it.
        if (self.prompt) |draft| {
            const measured = try prompt_mod.render(draft, self.size.cols, capacity, null);
            tail_total += measured.rows;
        }

        // Age lines out of the tail from the front until what is left fits on
        // screen. Closed blocks age out whole: that is the commit rule.
        var commit_count = self.closed_lines;
        for (self.row_cache.items[0..commit_count]) |rows| tail_total -= rows;
        while (tail_total > capacity and commit_count < self.lines.items.len) {
            tail_total -= self.row_cache.items[commit_count];
            commit_count += 1;
        }

        if (self.caps.synchronized_output) try out.writeAll("\x1b[?2026h");

        // A width change makes `tail_rows` a lie, and not a harmless one. The
        // rows already on screen are hard lines terminated by `\r\n`, so the
        // terminal re-wraps each of them at the new width: narrowing turns the
        // tail into *more* physical rows than were counted, and widening into
        // fewer. Moving back over the recorded count then stops short of the
        // tail's top — leaving stale rows that compound every frame — or, worse,
        // overshoots into committed scrollback, where `\x1b[0J` erases lines tug
        // has promised never to touch.
        //
        // There is no count that fixes this: the terminal breaks rows at the
        // column and tug breaks them at spaces, so the two disagree about how
        // many rows the same text occupies. So the old tail is abandoned where
        // it stands — it becomes scrollback, which is exactly the doctrine
        // everywhere else in this file — and the new one is drawn below it. The
        // cost is the tail appearing twice across a resize. The alternative is
        // erasing something that cannot be redrawn.
        const reflowed = self.painted and self.painted_cols != self.size.cols;
        if (self.painted and reflowed and self.cursor_up > 0) {
            // The cursor is parked inside the tail, and a reflowed tail is
            // abandoned rather than erased. Step down to the parking row first
            // or the new frame lands on top of the old prompt.
            try out.print("\x1b[{d}E", .{self.cursor_up});
        }
        if (self.painted and !reflowed) {
            try out.writeAll("\r");
            // Short by however far up the last frame left the cursor. CPL from
            // the parking row is what the arithmetic assumes, and the cursor is
            // no longer there.
            const back = self.tail_rows - self.cursor_up;
            if (back > 0) try out.print("\x1b[{d}F", .{back});
            try out.writeAll("\x1b[0J");
        }

        var frame: Frame = .{};
        for (self.lines.items[0..commit_count]) |entry| {
            frame.committed_rows += try self.renderEntry(entry, out);
            try out.writeAll("\r\n");
        }
        for (self.lines.items[commit_count..]) |entry| {
            frame.tail_rows += try self.renderEntry(entry, out);
            try out.writeAll("\r\n");
        }
        frame.tail_rows += try self.renderPartial(out);
        if (hint) frame.tail_rows += try self.renderHint(out);

        if (self.prompt) |draft| {
            const placed = try prompt_mod.render(draft, self.size.cols, capacity, out);
            frame.tail_rows += placed.rows;
            frame.cursor_row = placed.cursor_row;
            frame.cursor_col = placed.cursor_col;

            // Inside the synchronized-output window on purpose: a terminal that
            // honours it should never show the cursor at the parking row.
            // `rows - cursor_row` is at least one, because the cursor is always
            // on a row that was emitted.
            try out.print("\x1b[{d}F", .{placed.rows - placed.cursor_row});
            if (placed.cursor_col > 0) try out.print("\x1b[{d}C", .{placed.cursor_col});
        }

        if (self.caps.synchronized_output) try out.writeAll("\x1b[?2026l");

        self.dropCommitted(commit_count);
        self.closed_lines = 0;
        self.tail_rows = frame.tail_rows;
        self.cursor_up = if (self.prompt == null) 0 else frame.tail_rows - frame.cursor_row;
        self.painted = true;
        self.painted_cols = self.size.cols;
        return frame;
    }

    /// The status hint, wrapped like every other row.
    ///
    /// It used to be written straight to the writer and counted as one row,
    /// which is right until the terminal is narrower than the hint: the
    /// terminal then wraps it into two, every later frame moves back one row
    /// too few, and the screen fills with orphaned fragments. Nothing may reach
    /// the terminal except through `wrap`, because `wrap` is the only thing
    /// that counts.
    /// Ends the incomplete line where it stands, because it has outgrown the
    /// screen and cannot be committed while it is still being written.
    ///
    /// Deliberately not `finishLine`. That routes through the fence check, so a
    /// fence opener long enough to trigger this would toggle the fence state and
    /// emit no line at all — the bytes would simply vanish. It also takes the
    /// whole buffer, trailing half-codepoint included, which would bake a
    /// replacement character into scrollback permanently and leave the
    /// continuation bytes to make a second one on the next line.
    fn splitPartial(self: *Renderer) Error!void {
        const take = completePrefix(self.partial.items);
        if (take == 0) return;

        const block = self.block orelse .assistant;
        const raw = self.partial.items[0..take];
        const classified: md.Classified = if (block != .assistant)
            .{ .kind = .paragraph }
        else if (self.in_fence)
            .{ .kind = .code }
        else
            md.classify(raw, false);

        try self.appendLine(block, classified, raw);

        const rest = self.partial.items[take..];
        std.mem.copyForwards(u8, self.partial.items, rest);
        self.partial.items.len = rest.len;
    }

    /// Exactly one row, always.
    ///
    /// Written straight to the writer and counted as one row, this was right
    /// until the terminal was narrower than its 13 cells: the terminal wrapped
    /// it, every later frame moved back one row too few, and the screen filled
    /// with orphaned fragments. Wrapping it properly fixes the count and buys a
    /// worse problem — on a very narrow terminal the hint alone can be taller
    /// than the screen, and unlike a content line it cannot be aged out into
    /// scrollback, so the tail stops fitting at all.
    ///
    /// So it is cut to what fits. A hint is a hint; the part of it that would
    /// have cost four rows of a six-column terminal was never worth them.
    fn renderHint(self: *Renderer, out: ?*std.Io.Writer) Error!u32 {
        const cols: usize = @max(min_cols, self.size.cols);
        const fits = truncateToWidth(status_hint, cols);
        const rows = try self.wrap(fits, .{ .dim = true }, "", true, out);
        std.debug.assert(rows == 1);
        if (out) |writer| try writer.writeAll("\r\n");
        return rows;
    }

    fn renderEntry(self: *Renderer, entry: Entry, out: ?*std.Io.Writer) Error!u32 {
        var marker_buffer: [8]u8 = undefined;
        const content = self.text.items[entry.line.start..][0..entry.line.len];
        const literal = entry.block != .assistant or entry.line.kind == .code;
        return self.wrap(content, baseStyle(entry), marker(entry, &marker_buffer), literal, out);
    }

    /// The incomplete trailing line, rendered as a paragraph and truncated to
    /// its last whole codepoint. An empty partial emits nothing at all, so an
    /// idle renderer paints nothing.
    fn renderPartial(self: *Renderer, out: ?*std.Io.Writer) Error!u32 {
        const usable = self.partial.items[0..completePrefix(self.partial.items)];
        if (usable.len == 0) return 0;

        const block = self.block orelse .assistant;

        var content = usable;
        var marker_buffer: [8]u8 = undefined;
        var marker_text: []const u8 = "";
        var style: md.Style = .{};
        var literal = true;

        switch (block) {
            .user => style.bold = true,
            .notice => style.dim = true,
            .assistant => if (self.in_fence) {
                style.dim = true;
            } else {
                // Block classification is a prefix scan, so it is already
                // decided on a line that has only half arrived: `# ` is a
                // heading whether or not its newline has turned up. Inline
                // spans are the part that has to wait, because `**` is only
                // emphasis once it closes — which is the whole of what "hold
                // back the trailing incomplete line" buys.
                const classified = md.classify(content, false);
                content = content[@min(classified.marker_len, content.len)..];
                marker_text = markerFor(classified.kind, classified.level, &marker_buffer);
                if (classified.kind == .heading) style.bold = true;
                literal = false;
            },
        }

        const rows = try self.wrap(content, style, marker_text, literal, out);
        if (out) |writer| try writer.writeAll("\r\n");
        return rows;
    }

    /// Emits one logical line as physical rows and returns how many. With a
    /// null writer it does the identical walk and emits nothing, which is what
    /// makes the count and the output unable to disagree.
    ///
    /// Rows break at the last space that fits; a word too long for a whole row
    /// is broken where it lands, because the alternative is a row of nothing.
    /// Continuation rows are indented under the marker, so a wrapped list item
    /// still reads as one item.
    fn wrap(
        self: *Renderer,
        content: []const u8,
        base: md.Style,
        marker_text: []const u8,
        literal: bool,
        out: ?*std.Io.Writer,
    ) Error!u32 {
        const cols: usize = @max(min_cols, self.size.cols);
        const indent = width_mod.stringWidth(marker_text);

        // A marker is dropped rather than shrunk when it would leave less than
        // one wide character of room. Emitting it anyway would overflow the row
        // it sits on, the terminal would wrap it, and the row count would be
        // out by one before a single character of content had been drawn. This
        // also guarantees `cols - hanging >= 2`, which is what stops `push`
        // from admitting a codepoint too wide for the row it will land on.
        const shown = if (indent > cols -| 2) "" else marker_text;
        const width_of_marker = if (shown.len == 0) 0 else indent;

        var state: Wrap = .{
            .gpa = self.gpa,
            .word = &self.word,
            .out = out,
            .cols = cols,
            .hanging = width_of_marker,
            .column = width_of_marker,
            .current = base,
            .word_style = base,
        };
        self.word.clearRetainingCapacity();

        // The marker is emitted unstyled; the line's own style opens right
        // after it, so a bullet never carries the emphasis of the sentence
        // beside it while a code line's leading indent still gets the code
        // style. Inline changes *within* the line are held back to the word
        // they apply to — see `Wrap.setStyle`.
        if (out) |writer| try writer.writeAll(shown);
        try state.emitStyle(base);

        var pieces: md.Inline = .init(content, base);
        var literal_done = false;
        while (true) {
            const piece: md.Piece = if (literal) blk: {
                if (literal_done) break;
                literal_done = true;
                break :blk .{ .bytes = content, .style = base };
            } else pieces.next() orelse break;

            try state.setStyle(piece.style);

            var index: usize = 0;
            while (index < piece.bytes.len) {
                const length = std.unicode.utf8ByteSequenceLength(piece.bytes[index]) catch 1;
                const end = @min(index + length, piece.bytes.len);
                const slice = piece.bytes[index..end];
                index = end;

                // Decoded, not sniffed byte by byte: C1 controls arrive as two
                // bytes in UTF-8, and U+009B is an eight-bit CSI — the very
                // escape-sequence injection this filter exists to defuse — while
                // U+0085 moves the cursor down a line and puts the row count
                // out. A slice-length test lets both straight through.
                const codepoint = std.unicode.utf8Decode(slice) catch
                    std.unicode.replacement_character;

                if (prompt_mod.isControl(codepoint)) {
                    // Control characters never reach the terminal. A text delta
                    // is whatever a provider chose to send, and a raw ESC in it
                    // is an escape-sequence injection into the user's terminal —
                    // the same attack the decoder strips out of a paste. A stray
                    // CR would be quieter and just as bad: it moves the cursor to
                    // column 0 and puts the row count out.
                    //
                    // Tab is the one that carries meaning, and it is expanded
                    // rather than dropped so indented code keeps its shape.
                    if (codepoint == '\t') for (0..tab_width) |_| try state.space();
                } else if (codepoint == ' ') {
                    try state.space();
                } else {
                    try state.push(slice, width_mod.stringWidth(slice));
                }
            }
        }
        try state.flushWord();
        try state.emitStyle(.{});
        return state.rows;
    }

    /// Removes the lines that have gone into scrollback and compacts the text
    /// behind them.
    ///
    /// ponytail: this memmoves the survivors to the front, so a commit is
    /// linear in the tail's size. The tail is one screenful by construction, so
    /// that is a few kilobytes at 125 frames a second. A ring buffer would
    /// avoid it and cost every reader a wrap-around branch.
    fn dropCommitted(self: *Renderer, count: usize) void {
        if (count == 0) return;
        if (count >= self.lines.items.len) {
            self.lines.clearRetainingCapacity();
            self.text.clearRetainingCapacity();
            return;
        }
        const cut = self.lines.items[count].line.start;
        std.mem.copyForwards(u8, self.text.items, self.text.items[cut..]);
        self.text.items.len -= cut;
        std.mem.copyForwards(Entry, self.lines.items, self.lines.items[count..]);
        self.lines.items.len -= count;
        for (self.lines.items) |*entry| entry.line.start -= cut;
    }
};

/// The wrapping state machine, pulled out of `wrap` so the row break and the
/// word flush are two named things rather than two copies of the same eight
/// lines.
const Wrap = struct {
    gpa: std.mem.Allocator,
    word: *std.ArrayList(u8),
    out: ?*std.Io.Writer,
    cols: usize,
    hanging: usize,
    column: usize,
    rows: u32 = 1,
    /// What the terminal has actually been told. Distinct from `current`
    /// because a style change is held back until the word it applies to is
    /// emitted — otherwise the space in front of that word gets the new style,
    /// which is invisible with an attribute and a stray painted cell once
    /// Phase 9 makes it a background colour.
    emitted: md.Style = .{},
    /// The style in force at the end of the pending word.
    current: md.Style,
    /// The style in force where the pending word begins, so a row break can
    /// re-open it before replaying the word.
    word_style: md.Style,
    word_cells: usize = 0,
    /// Spaces seen since the last word. Held back so a break at a space does
    /// not leave trailing whitespace in scrollback.
    spaces: usize = 0,

    /// Moves the terminal to `style`, if it is not already there.
    fn emitStyle(self: *Wrap, style: md.Style) Error!void {
        if (@as(u8, @bitCast(style)) == @as(u8, @bitCast(self.emitted))) return;
        if (self.out) |writer| {
            var buffer: [16]u8 = undefined;
            try writer.writeAll(styleBytes(self.emitted, style, &buffer));
        }
        self.emitted = style;
    }

    fn setStyle(self: *Wrap, style: md.Style) Error!void {
        if (@as(u8, @bitCast(style)) == @as(u8, @bitCast(self.current))) return;
        if (self.word.items.len == 0) {
            // Nothing pending: the change belongs to the next word, and is
            // emitted when that word is.
            self.word_style = style;
        } else {
            // Mid-word: the escape rides along inside the word so a row break
            // replays it in the right place.
            var buffer: [16]u8 = undefined;
            try self.word.appendSlice(self.gpa, styleBytes(self.current, style, &buffer));
        }
        self.current = style;
    }

    fn newRow(self: *Wrap, restore: md.Style) Error!void {
        try self.emitStyle(.{});
        if (self.out) |writer| {
            try writer.writeAll("\r\n");
            for (0..self.hanging) |_| try writer.writeAll(" ");
        }
        try self.emitStyle(restore);
        self.rows += 1;
        self.column = self.hanging;
    }

    fn flushWord(self: *Wrap) Error!void {
        // Pending spaces deliberately survive an empty flush. They are only
        // ever emitted in front of a word, which is what drops them at a row
        // break and at the end of a line — and what lets a run of them
        // accumulate, so indented code keeps its indentation.
        if (self.word.items.len == 0) return;

        if (self.column + self.spaces + self.word_cells > self.cols) {
            try self.newRow(self.word_style);
        } else {
            if (self.spaces > 0) {
                if (self.out) |writer| for (0..self.spaces) |_| try writer.writeAll(" ");
                self.column += self.spaces;
            }
            try self.emitStyle(self.word_style);
        }
        self.spaces = 0;

        if (self.out) |writer| try writer.writeAll(self.word.items);
        // The word replayed its own mid-word escapes, so the terminal is now
        // wherever the word ended.
        self.emitted = self.current;
        self.column += self.word_cells;

        self.word.clearRetainingCapacity();
        self.word_cells = 0;
        self.word_style = self.current;
    }

    fn space(self: *Wrap) Error!void {
        try self.flushWord();
        self.spaces += 1;
        if (self.column + self.spaces > self.cols) {
            try self.newRow(.{});
            self.spaces = 0;
        }
    }

    fn push(self: *Wrap, slice: []const u8, cells: usize) Error!void {
        // Keep the pending word inside one row's worth of cells, so flushing it
        // can never overflow a row and let the terminal wrap behind our back.
        if (self.word_cells + cells > self.cols -| self.hanging) try self.flushWord();
        if (self.word.items.len == 0) self.word_style = self.current;
        try self.word.appendSlice(self.gpa, slice);
        self.word_cells += cells;
    }
};

const testing = std.testing;

const Counting = @import("counting_writer.zig").Counting;

const test_caps: Capabilities = .{
    .color = .none,
    .kitty_keyboard = false,
    .synchronized_output = false,
    .bracketed_paste = true,
    .size = .{ .cols = 20, .rows = 10 },
};

const Painted = struct { frame: Frame, output: []const u8, writes: usize };

/// Paints once into a fresh counting writer. `buffer` and `sink` are the
/// caller's so the bytes outlive this call.
fn paintOnce(renderer: *Renderer, buffer: []u8, sink: []u8) !Painted {
    var counting: Counting = .init(buffer, sink);
    const frame = try renderer.paint(&counting.writer);
    try counting.writer.flush();
    return .{ .frame = frame, .output = counting.bytes(), .writes = counting.writes };
}

test "an empty renderer paints nothing at all" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 20, .rows = 10 });
    defer renderer.deinit();

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const painted = try paintOnce(&renderer, &buffer, &sink);

    try testing.expectEqual(@as(u32, 0), painted.frame.committed_rows);
    try testing.expectEqual(@as(u32, 0), painted.frame.tail_rows);
    try testing.expectEqual(@as(usize, 0), painted.output.len);
}

test "a short line is one row plus the hint, and the repaint moves over both" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 20, .rows = 10 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    try renderer.feed("hello\n");

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const first = try paintOnce(&renderer, &buffer, &sink);
    try testing.expectEqual(@as(u32, 2), first.frame.tail_rows);
    try testing.expect(std.mem.indexOf(u8, first.output, "hello") != null);
    // Nothing to move back over yet, so no cursor-up on the first paint.
    try testing.expect(std.mem.indexOf(u8, first.output, "F\x1b[0J") == null);

    var buffer2: [4096]u8 = undefined;
    var sink2: [4096]u8 = undefined;
    const second = try paintOnce(&renderer, &buffer2, &sink2);
    try testing.expectEqual(@as(u32, 2), second.frame.tail_rows);
    try testing.expect(std.mem.startsWith(u8, second.output, "\r\x1b[2F\x1b[0J"));
}

test "a line wider than the terminal wraps at a space, not mid-word" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 10, .rows = 10 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    try renderer.feed("alpha bravo charlie\n");

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const painted = try paintOnce(&renderer, &buffer, &sink);

    // Three content rows plus the status hint, which is cut to the ten columns
    // it has rather than wrapping onto a second.
    try testing.expectEqual(@as(u32, 4), painted.frame.tail_rows);
    try testing.expect(std.mem.indexOf(u8, painted.output, "alpha\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, painted.output, "bravo\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, painted.output, "charlie") != null);
}

test "a word longer than the terminal is hard-broken rather than dropped" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 5, .rows = 10 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    try renderer.feed("abcdefghij\n");

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const painted = try paintOnce(&renderer, &buffer, &sink);

    try testing.expectEqual(@as(u32, 3), painted.frame.tail_rows);
    try testing.expect(std.mem.indexOf(u8, painted.output, "abcde\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, painted.output, "fghij") != null);
}

test "wide characters cost two cells when wrapping" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 4, .rows = 10 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    try renderer.feed("日本語版\n");

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const painted = try paintOnce(&renderer, &buffer, &sink);
    try testing.expectEqual(@as(u32, 3), painted.frame.tail_rows);
}

test "a codepoint split across two feeds renders as one character" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 20, .rows = 10 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);

    const nihon = "日本";
    try renderer.feed(nihon[0..1]);

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const mid = try paintOnce(&renderer, &buffer, &sink);
    try testing.expect(std.mem.indexOf(u8, mid.output, nihon[0..1]) == null);

    try renderer.feed(nihon[1..]);
    var buffer2: [4096]u8 = undefined;
    var sink2: [4096]u8 = undefined;
    const done = try paintOnce(&renderer, &buffer2, &sink2);
    try testing.expect(std.mem.indexOf(u8, done.output, nihon) != null);
}

test "the whole frame reaches the sink in exactly one write" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 40, .rows = 10 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    try renderer.feed(
        \\# Heading
        \\
        \\Some **bold** and some `code` in a paragraph long enough to wrap twice.
        \\
        \\- one
        \\- two
        \\
    );

    var buffer: [8192]u8 = undefined;
    var sink: [8192]u8 = undefined;
    const painted = try paintOnce(&renderer, &buffer, &sink);
    try testing.expectEqual(@as(usize, 1), painted.writes);
    try testing.expect(painted.output.len > 0);
}

test "synchronized output guards wrap the frame when the terminal has them" {
    var caps = test_caps;
    caps.synchronized_output = true;
    var renderer: Renderer = .init(testing.allocator, caps, .{ .cols = 20, .rows = 10 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    try renderer.feed("hi\n");

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const painted = try paintOnce(&renderer, &buffer, &sink);
    try testing.expect(std.mem.startsWith(u8, painted.output, "\x1b[?2026h"));
    try testing.expect(std.mem.endsWith(u8, painted.output, "\x1b[?2026l"));
}

test "fence markers are never echoed and their contents are dimmed" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 40, .rows = 10 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    try renderer.feed("```zig\nconst x = 1;\n```\n");

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const painted = try paintOnce(&renderer, &buffer, &sink);
    try testing.expect(std.mem.indexOf(u8, painted.output, "```") == null);
    try testing.expect(std.mem.indexOf(u8, painted.output, "const x = 1;") != null);
    try testing.expect(std.mem.indexOf(u8, painted.output, "\x1b[2m") != null);
}

test "a wrapped list item hangs under its own text" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 12, .rows = 10 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    try renderer.feed("- alpha bravo\n");

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const painted = try paintOnce(&renderer, &buffer, &sink);
    try testing.expectEqual(@as(u32, 3), painted.frame.tail_rows);
    try testing.expect(std.mem.indexOf(u8, painted.output, "\u{2022} alpha") != null);
    try testing.expect(std.mem.indexOf(u8, painted.output, "\r\n  bravo") != null);
}

test "a tail taller than the screen commits its oldest rows to scrollback" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 20, .rows = 5 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    for (0..8) |i| {
        var line: [8]u8 = undefined;
        try renderer.feed(try std.fmt.bufPrint(&line, "line{d}\n", .{i}));
    }

    var buffer: [8192]u8 = undefined;
    var sink: [8192]u8 = undefined;
    const painted = try paintOnce(&renderer, &buffer, &sink);

    // capacity is rows - 2, and the status hint is one of the rows that has to
    // fit inside it.
    try testing.expectEqual(@as(u32, 6), painted.frame.committed_rows);
    try testing.expectEqual(@as(u32, 3), painted.frame.tail_rows);
    try testing.expect(std.mem.indexOf(u8, painted.output, "line0") != null);
    try testing.expect(std.mem.indexOf(u8, painted.output, "line7") != null);
}

test "committed lines are dropped and never painted twice" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 20, .rows = 5 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    for (0..8) |i| {
        var line: [8]u8 = undefined;
        try renderer.feed(try std.fmt.bufPrint(&line, "line{d}\n", .{i}));
    }

    var buffer: [8192]u8 = undefined;
    var sink: [8192]u8 = undefined;
    _ = try paintOnce(&renderer, &buffer, &sink);

    var buffer2: [8192]u8 = undefined;
    var sink2: [8192]u8 = undefined;
    const second = try paintOnce(&renderer, &buffer2, &sink2);
    try testing.expectEqual(@as(u32, 0), second.frame.committed_rows);
    try testing.expect(std.mem.indexOf(u8, second.output, "line0") == null);
    try testing.expect(std.mem.indexOf(u8, second.output, "line7") != null);
}

test "closing a block commits all of it and clears the status hint" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 20, .rows = 10 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    try renderer.feed("done");

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const streaming = try paintOnce(&renderer, &buffer, &sink);
    try testing.expect(std.mem.indexOf(u8, streaming.output, "streaming") != null);

    try renderer.endBlock();
    var buffer2: [4096]u8 = undefined;
    var sink2: [4096]u8 = undefined;
    const closed = try paintOnce(&renderer, &buffer2, &sink2);

    try testing.expectEqual(@as(u32, 0), closed.frame.tail_rows);
    try testing.expectEqual(@as(u32, 1), closed.frame.committed_rows);
    try testing.expect(std.mem.indexOf(u8, closed.output, "streaming") == null);
    try testing.expect(std.mem.indexOf(u8, closed.output, "done") != null);
}

test "after a committed block the next paint moves back over nothing" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 20, .rows = 10 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    try renderer.feed("done");
    try renderer.endBlock();

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    _ = try paintOnce(&renderer, &buffer, &sink);

    var buffer2: [4096]u8 = undefined;
    var sink2: [4096]u8 = undefined;
    const after = try paintOnce(&renderer, &buffer2, &sink2);
    try testing.expectEqualStrings("\r\x1b[0J", after.output);
}

test "a resize abandons the old tail rather than erasing rows it cannot count" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 20, .rows = 10 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    try renderer.feed("alpha bravo charlie\n");

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const wide_frame = try paintOnce(&renderer, &buffer, &sink);
    try testing.expectEqual(@as(u32, 2), wide_frame.frame.tail_rows);

    renderer.setSize(.{ .cols = 10, .rows = 10 });
    var buffer2: [4096]u8 = undefined;
    var sink2: [4096]u8 = undefined;
    const narrow = try paintOnce(&renderer, &buffer2, &sink2);

    // The tail is rewrapped at the new width: three content rows plus the hint.
    try testing.expectEqual(@as(u32, 4), narrow.frame.tail_rows);
    try testing.expect(std.mem.indexOf(u8, narrow.output, "alpha\r\n") != null);

    // And no cursor-up at all. The terminal rewrapped the rows already on
    // screen, so the recorded count no longer describes them, and moving back
    // over it would either strand rows or erase committed scrollback.
    try testing.expect(std.mem.indexOf(u8, narrow.output, "F\x1b[0J") == null);
}

test "a height change alone still repaints normally" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 20, .rows = 10 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    try renderer.feed("alpha\n");

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    _ = try paintOnce(&renderer, &buffer, &sink);

    renderer.setSize(.{ .cols = 20, .rows = 24 });
    var buffer2: [4096]u8 = undefined;
    var sink2: [4096]u8 = undefined;
    const taller = try paintOnce(&renderer, &buffer2, &sink2);
    try testing.expect(std.mem.startsWith(u8, taller.output, "\r\x1b[2F\x1b[0J"));
}

test "the status hint is cut to one row on a terminal narrower than itself" {
    // Six columns against the hint's thirteen. Written unwrapped it would be
    // wrapped by the terminal into three rows counted as one, and every later
    // frame would move back two rows too few.
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 6, .rows = 10 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const painted = try paintOnce(&renderer, &buffer, &sink);

    try testing.expectEqual(@as(u32, 1), painted.frame.tail_rows);
    try testing.expect(std.mem.indexOf(u8, painted.output, "... st") != null);
    try testing.expect(std.mem.indexOf(u8, painted.output, "streaming") == null);

    var rows: u32 = 0;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, painted.output, index, "\r\n")) |at| {
        rows += 1;
        index = at + 2;
    }
    try testing.expectEqual(painted.frame.tail_rows, rows);
}

test "a marker too wide for the terminal is dropped rather than overflowing" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 4, .rows = 10 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    // "255. " is five cells; the terminal is four.
    try renderer.feed("255. x\n");

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const painted = try paintOnce(&renderer, &buffer, &sink);
    try testing.expect(std.mem.indexOf(u8, painted.output, "255. ") == null);
    try testing.expect(std.mem.indexOf(u8, painted.output, "x") != null);
}

test "an eight-bit CSI in a text delta never reaches the terminal" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 40, .rows = 10 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    // U+009B is CSI as a C1 control and arrives as two bytes in UTF-8; U+0085
    // is NEL, which moves the cursor down a line. A filter that only looks at
    // single-byte slices lets both straight through.
    try renderer.feed("a\u{009b}31mb\u{0085}c\n");

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const painted = try paintOnce(&renderer, &buffer, &sink);
    try testing.expect(std.mem.indexOf(u8, painted.output, "\u{009b}") == null);
    try testing.expect(std.mem.indexOf(u8, painted.output, "\u{0085}") == null);
    try testing.expect(std.mem.indexOf(u8, painted.output, "a31mbc") != null);
}

test "a forced split keeps a straddled codepoint whole" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 10, .rows = 5 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    // Enough to outgrow the screen, then a lead byte whose tail has not
    // arrived. Splitting the whole buffer would bake a replacement character
    // into scrollback, where nothing can ever repair it.
    try renderer.feed("x" ** 300);
    try renderer.feed("\xe6\x97");

    var buffer: [16384]u8 = undefined;
    var sink: [16384]u8 = undefined;
    const painted = try paintOnce(&renderer, &buffer, &sink);
    try testing.expect(std.mem.indexOf(u8, painted.output, "\xe6\x97") == null);

    try renderer.feed("\xa5\n");
    var buffer2: [16384]u8 = undefined;
    var sink2: [16384]u8 = undefined;
    const done = try paintOnce(&renderer, &buffer2, &sink2);
    try testing.expect(std.mem.indexOf(u8, done.output, "\u{65e5}") != null);
}

test "a forced split of a fence opener does not swallow it" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 10, .rows = 5 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    // A fence opener long enough to outgrow the screen before its newline.
    // Routed through `finishLine` it would toggle the fence state, emit no
    // line, and every byte of it would vanish.
    try renderer.feed("```" ++ "z" ** 300);

    var buffer: [16384]u8 = undefined;
    var sink: [16384]u8 = undefined;
    const painted = try paintOnce(&renderer, &buffer, &sink);

    var count: usize = 0;
    for (painted.output) |byte| {
        if (byte == 'z') count += 1;
    }
    try testing.expectEqual(@as(usize, 300), count);
}

test "a notice block renders dim and plain, markdown untouched" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 40, .rows = 10 });
    defer renderer.deinit();
    try renderer.beginBlock(.notice);
    try renderer.feed("stream failed: **not** markdown\n");

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const painted = try paintOnce(&renderer, &buffer, &sink);
    try testing.expect(std.mem.indexOf(u8, painted.output, "**not**") != null);
    try testing.expect(std.mem.indexOf(u8, painted.output, "\x1b[2m") != null);
}

test "opening a block while one is open closes the first" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 20, .rows = 10 });
    defer renderer.deinit();
    try renderer.beginBlock(.user);
    try renderer.feed("question");
    try renderer.beginBlock(.assistant);
    try renderer.feed("answer");

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const painted = try paintOnce(&renderer, &buffer, &sink);
    try testing.expectEqual(@as(u32, 1), painted.frame.committed_rows);
    try testing.expect(std.mem.indexOf(u8, painted.output, "question") != null);
    try testing.expect(std.mem.indexOf(u8, painted.output, "answer") != null);
}

test "a one-row terminal still paints and still commits" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 20, .rows = 1 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    try renderer.feed("a\nb\nc\n");

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const painted = try paintOnce(&renderer, &buffer, &sink);
    try testing.expectEqual(@as(u32, 3), painted.frame.committed_rows);
    try testing.expectEqual(@as(u32, 1), painted.frame.tail_rows);
}

test "control bytes never reach the terminal" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 40, .rows = 10 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    try renderer.feed("a\x1b[31mb\x07c\x7fd\n");

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const painted = try paintOnce(&renderer, &buffer, &sink);
    try testing.expect(std.mem.indexOf(u8, painted.output, "\x1b[31m") == null);
    // Only the ESC byte is a control character: `[31m` is ordinary text and
    // stays, which is exactly the point -- the sequence is defused, not the
    // provider's words.
    try testing.expect(std.mem.indexOf(u8, painted.output, "a[31mbcd") != null);
    try testing.expectEqual(@as(u32, 2), painted.frame.tail_rows);
}

test "a tab keeps indentation instead of disappearing" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 40, .rows = 10 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    try renderer.feed("```\n\tindented\n```\n");

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const painted = try paintOnce(&renderer, &buffer, &sink);
    try testing.expect(std.mem.indexOf(u8, painted.output, "    indented") != null);
}

test "a line that outgrows the screen before its newline is split, not lost" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 10, .rows = 5 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    // Thirty rows of content at ten columns, with no newline anywhere in it.
    try renderer.feed("x" ** 300);

    var buffer: [16384]u8 = undefined;
    var sink: [16384]u8 = undefined;
    const painted = try paintOnce(&renderer, &buffer, &sink);

    // The tail still fits on screen, and every byte reached the frame.
    try testing.expect(painted.frame.tail_rows <= 5);
    try testing.expect(painted.frame.committed_rows > 0);
    var count: usize = 0;
    for (painted.output) |byte| {
        if (byte == 'x') count += 1;
    }
    try testing.expectEqual(@as(usize, 300), count);
}

test "a half-arrived line is already classified at block level" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 40, .rows = 10 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    // No newline yet: the marker is decided by a prefix scan, so it does not
    // have to wait for one. Without this the bullet shows as a literal "- " and
    // then jumps to a dot the instant the line ends, which is a visible flinch
    // on every list a model streams.
    try renderer.feed("- half a bul");

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const painted = try paintOnce(&renderer, &buffer, &sink);
    try testing.expect(std.mem.indexOf(u8, painted.output, "\u{2022} half a bul") != null);
    try testing.expect(std.mem.indexOf(u8, painted.output, "- half") == null);
}

test "a half-arrived heading is already bold" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 40, .rows = 10 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    try renderer.feed("## Half a hea");

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const painted = try paintOnce(&renderer, &buffer, &sink);
    try testing.expect(std.mem.indexOf(u8, painted.output, "\x1b[1mHalf a hea") != null);
    try testing.expect(std.mem.indexOf(u8, painted.output, "##") == null);
}

test "inline markers in a half-arrived line stay literal until the line ends" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 40, .rows = 10 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    try renderer.feed("some **bold");

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const open = try paintOnce(&renderer, &buffer, &sink);
    try testing.expect(std.mem.indexOf(u8, open.output, "some **bold") != null);

    try renderer.feed("** text\n");
    var buffer2: [4096]u8 = undefined;
    var sink2: [4096]u8 = undefined;
    const closed = try paintOnce(&renderer, &buffer2, &sink2);
    try testing.expect(std.mem.indexOf(u8, closed.output, "\x1b[1mbold\x1b[0m text") != null);
}

test "a prompt is drawn under the tail and the cursor is left inside it" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 20, .rows = 10 });
    defer renderer.deinit();

    renderer.setPrompt(.{ .text = "hi", .cursor = 2 });

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const first = try paintOnce(&renderer, &buffer, &sink);

    try testing.expectEqual(@as(u32, 1), first.frame.tail_rows);
    try testing.expect(std.mem.indexOf(u8, first.output, "> hi") != null);
    // One row of prompt, cursor on its only row: one row above the parking row.
    try testing.expect(std.mem.endsWith(u8, first.output, "\x1b[1F\x1b[4C"));

    // The next frame moves back `tail_rows - cursor_up` rows, which is zero
    // here: the cursor is already on the tail's top row.
    var buffer2: [4096]u8 = undefined;
    var sink2: [4096]u8 = undefined;
    const second = try paintOnce(&renderer, &buffer2, &sink2);
    try testing.expect(std.mem.startsWith(u8, second.output, "\r\x1b[0J"));
}

test "content above a prompt commits and leaves the prompt alone in the tail" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 20, .rows = 10 });
    defer renderer.deinit();

    try renderer.beginBlock(.assistant);
    try renderer.feed("hello\n");
    try renderer.endBlock();
    renderer.setPrompt(.{ .text = "", .cursor = 0 });

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const first = try paintOnce(&renderer, &buffer, &sink);

    // The closed block commits, so only the prompt is left in the tail.
    try testing.expectEqual(@as(u32, 1), first.frame.committed_rows);
    try testing.expectEqual(@as(u32, 1), first.frame.tail_rows);
    try testing.expectEqual(@as(u32, 0), first.frame.cursor_row);
    try testing.expectEqual(@as(u16, 2), first.frame.cursor_col);
}

test "a multi-row prompt parks the cursor on the right row" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 20, .rows = 10 });
    defer renderer.deinit();

    // Three rows, cursor at the end of the first.
    renderer.setPrompt(.{ .text = "one\ntwo\nthree", .cursor = 3 });

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const first = try paintOnce(&renderer, &buffer, &sink);

    try testing.expectEqual(@as(u32, 3), first.frame.tail_rows);
    try testing.expectEqual(@as(u32, 0), first.frame.cursor_row);
    // Three rows below the cursor's row, counting the parking row.
    try testing.expect(std.mem.endsWith(u8, first.output, "\x1b[3F\x1b[5C"));

    var buffer2: [4096]u8 = undefined;
    var sink2: [4096]u8 = undefined;
    const second = try paintOnce(&renderer, &buffer2, &sink2);
    // tail_rows 3 minus cursor_up 3: the cursor is already at the top.
    try testing.expect(std.mem.startsWith(u8, second.output, "\r\x1b[0J"));
}

test "a resize steps down out of the prompt before abandoning the old tail" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 20, .rows = 10 });
    defer renderer.deinit();

    renderer.setPrompt(.{ .text = "one\ntwo", .cursor = 0 });

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    _ = try paintOnce(&renderer, &buffer, &sink);

    renderer.setSize(.{ .cols = 12, .rows = 10 });

    var buffer2: [4096]u8 = undefined;
    var sink2: [4096]u8 = undefined;
    const second = try paintOnce(&renderer, &buffer2, &sink2);

    // Two rows of prompt with the cursor on the first: two rows to step down.
    // No erase, because the old tail is abandoned rather than repainted over.
    try testing.expect(std.mem.startsWith(u8, second.output, "\x1b[2E"));
    try testing.expect(std.mem.indexOf(u8, second.output, "\x1b[0J") == null);
}

test "clearing the screen forgets the tail rather than moving over it" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 20, .rows = 10 });
    defer renderer.deinit();

    renderer.setPrompt(.{ .text = "hi", .cursor = 2 });

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    _ = try paintOnce(&renderer, &buffer, &sink);

    var cleared: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&cleared);
    try renderer.clearScreen(&writer);
    try testing.expectEqualStrings("\x1b[H\x1b[2J", writer.buffered());

    var buffer2: [4096]u8 = undefined;
    var sink2: [4096]u8 = undefined;
    const after = try paintOnce(&renderer, &buffer2, &sink2);
    // Nothing to move back over: the screen is empty.
    try testing.expect(std.mem.indexOf(u8, after.output, "\x1b[0J") == null);
    try testing.expect(std.mem.indexOf(u8, after.output, "> hi") != null);
}

test "a prompt taller than the tail is capped at the capacity" {
    // Six rows of screen, so `capacity` is four.
    const small: Capabilities = .{
        .color = .none,
        .kitty_keyboard = false,
        .synchronized_output = false,
        .bracketed_paste = true,
        .size = .{ .cols = 20, .rows = 6 },
    };
    var renderer: Renderer = .init(testing.allocator, small, small.size);
    defer renderer.deinit();

    renderer.setPrompt(.{ .text = "a\nb\nc\nd\ne\nf", .cursor = 11 });

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    const painted = try paintOnce(&renderer, &buffer, &sink);

    try testing.expectEqual(@as(u32, 4), painted.frame.tail_rows);
    // The window ends on the cursor, so the last line is on screen and the
    // first is not.
    try testing.expect(std.mem.indexOf(u8, painted.output, "f") != null);
    try testing.expect(std.mem.indexOf(u8, painted.output, "> a") == null);
}

test "no prompt leaves every frame exactly as Phase 4 drew it" {
    var renderer: Renderer = .init(testing.allocator, test_caps, .{ .cols = 20, .rows = 10 });
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);
    try renderer.feed("hello\n");

    var buffer: [4096]u8 = undefined;
    var sink: [4096]u8 = undefined;
    _ = try paintOnce(&renderer, &buffer, &sink);

    var buffer2: [4096]u8 = undefined;
    var sink2: [4096]u8 = undefined;
    const second = try paintOnce(&renderer, &buffer2, &sink2);

    // The cursor never left the parking row, so the rewind is the full count.
    try testing.expect(std.mem.startsWith(u8, second.output, "\r\x1b[2F\x1b[0J"));
    try testing.expectEqual(@as(u32, 0), second.frame.cursor_row);
}
