//! The terminal mode stack.
//!
//! tug turns on three terminal modes and must turn all three off again on every
//! exit path. Leaving the kitty keyboard flags pushed is the worst of them:
//! the next program to run in that terminal receives key events in a protocol
//! it does not speak, and the user has no idea tug did it.
//!
//! So pushes are recorded and `popAll` emits the exact inverse in reverse
//! order. The stack is pure — it writes into a writer the caller owns — which
//! is what makes that property testable without a terminal.
//!
//! Probing is the other half and is deliberately paranoid. Every query carries
//! a timeout, and a terminal that does not answer is a terminal that does not
//! support the feature. Waiting longer would trade a capability nobody needs
//! against the 10 ms startup budget, which is the wrong way round.

const std = @import("std");

const backend = @import("backend.zig");

pub const Mode = enum {
    /// DECSET 2004. Pasted text arrives wrapped in markers, so the decoder can
    /// tell a paste from typing and sanitize it.
    bracketed_paste,
    /// The kitty keyboard protocol, progressive enhancement flags. This is what
    /// makes shift+enter a distinct chord.
    kitty_keyboard,
    /// DECSET 2026. Lets a repaint arrive as one atomic screen update.
    synchronized_output,

    fn enterSequence(self: Mode) []const u8 {
        return switch (self) {
            .bracketed_paste => "\x1b[?2004h",
            // Flags 1 (disambiguate escape codes) and 2 (report event types).
            // Deliberately not 8 (report all keys as escape codes): tug wants
            // text to stay text.
            .kitty_keyboard => "\x1b[>3u",
            .synchronized_output => "\x1b[?2026h",
        };
    }

    fn exitSequence(self: Mode) []const u8 {
        return switch (self) {
            .bracketed_paste => "\x1b[?2004l",
            // Pops one entry off the terminal's own stack, which is why the
            // push above must be matched exactly once.
            .kitty_keyboard => "\x1b[<u",
            .synchronized_output => "\x1b[?2026l",
        };
    }
};

pub const max_modes = @typeInfo(Mode).@"enum".fields.len;

pub const Stack = struct {
    entries: [max_modes]Mode = undefined,
    len: usize = 0,

    pub fn push(self: *Stack, out: *std.Io.Writer, mode: Mode) std.Io.Writer.Error!void {
        std.debug.assert(self.len < max_modes);
        try out.writeAll(mode.enterSequence());
        self.entries[self.len] = mode;
        self.len += 1;
    }

    /// Unwinds everything, most recent first. Errors are swallowed on purpose:
    /// this runs on exit paths that have nothing useful to do with a write
    /// failure, and half-restoring is strictly better than not restoring.
    pub fn popAll(self: *Stack, out: *std.Io.Writer) void {
        while (self.len > 0) {
            self.len -= 1;
            out.writeAll(self.entries[self.len].exitSequence()) catch {};
        }
        out.flush() catch {};
    }
};

/// How long a probe waits before concluding the feature is absent.
///
/// 50 ms is chosen against the two failure modes rather than against any
/// terminal's measured latency: a local terminal answers in well under a
/// millisecond, and one that has not answered in fifty is either not going to
/// or is behind a link where the feature would be unpleasant anyway. It is also
/// well inside the 10 ms *first paint* budget only because probing happens
/// after the first paint, which is the point of that ordering (`DR-004`).
pub const probe_timeout_ms: u32 = 50;

/// Queries the kitty keyboard protocol.
///
/// `CSI ? u` asks the terminal to report its current flags. A terminal that
/// speaks the protocol replies `CSI ? <flags> u`; one that does not replies
/// nothing at all, which is why this needs a timeout rather than a read.
pub const kitty_query = "\x1b[?u";

/// Queries synchronized output with `DECRQM` on mode 2026. A supporting
/// terminal replies `CSI ? 2026 ; <state> $y` with a state of 1 or 2.
pub const sync_output_query = "\x1b[?2026$p";

/// Classifies a probe reply. Pure, so the parsing is testable without a
/// terminal; the backend owns the read and the timeout.
pub fn kittyReplyMeansSupported(reply: []const u8) bool {
    // CSI ? <flags> u
    if (reply.len < 4) return false;
    if (!std.mem.startsWith(u8, reply, "\x1b[?")) return false;
    return reply[reply.len - 1] == 'u';
}

pub fn syncOutputReplyMeansSupported(reply: []const u8) bool {
    // CSI ? 2026 ; <state> $ y — state 0 means the mode is not recognized,
    // 4 means permanently reset. 1, 2 and 3 all mean the terminal knows it.
    if (!std.mem.startsWith(u8, reply, "\x1b[?2026;")) return false;
    if (!std.mem.endsWith(u8, reply, "$y")) return false;

    const state_start = "\x1b[?2026;".len;
    const state_end = reply.len - "$y".len;
    if (state_end <= state_start) return false;

    const state = std.fmt.parseInt(u8, reply[state_start..state_end], 10) catch return false;
    return state != 0 and state != 4;
}

const testing = std.testing;

test "popAll emits the exact inverse in reverse order" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    var stack: Stack = .{};
    try stack.push(&writer, .bracketed_paste);
    try stack.push(&writer, .kitty_keyboard);
    try stack.push(&writer, .synchronized_output);

    const after_push = writer.buffered().len;
    stack.popAll(&writer);

    const popped = writer.buffered()[after_push..];

    var expected_buffer: [64]u8 = undefined;
    var expected: std.Io.Writer = .fixed(&expected_buffer);
    for ([_]Mode{ .synchronized_output, .kitty_keyboard, .bracketed_paste }) |mode| {
        try expected.writeAll(mode.exitSequence());
    }
    try testing.expectEqualStrings(expected.buffered(), popped);
}

test "popAll on an empty stack writes nothing" {
    var buffer: [16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    var stack: Stack = .{};
    stack.popAll(&writer);
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);
}

test "popAll is idempotent" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    var stack: Stack = .{};
    try stack.push(&writer, .kitty_keyboard);
    stack.popAll(&writer);
    const after_first = writer.buffered().len;
    stack.popAll(&writer);

    try testing.expectEqual(after_first, writer.buffered().len);
}

test "every mode has a distinct enter and exit sequence" {
    inline for (@typeInfo(Mode).@"enum".fields) |field| {
        const mode: Mode = @enumFromInt(field.value);
        try testing.expect(mode.enterSequence().len > 0);
        try testing.expect(mode.exitSequence().len > 0);
        try testing.expect(!std.mem.eql(u8, mode.enterSequence(), mode.exitSequence()));
    }
}

test "a kitty reply is recognized and silence is not" {
    try testing.expect(kittyReplyMeansSupported("\x1b[?3u"));
    try testing.expect(kittyReplyMeansSupported("\x1b[?0u"));
    try testing.expect(!kittyReplyMeansSupported(""));
    try testing.expect(!kittyReplyMeansSupported("\x1b[?2026;1$y"));
}

test "synchronized output states 1 through 3 mean supported" {
    try testing.expect(syncOutputReplyMeansSupported("\x1b[?2026;1$y"));
    try testing.expect(syncOutputReplyMeansSupported("\x1b[?2026;2$y"));
    try testing.expect(!syncOutputReplyMeansSupported("\x1b[?2026;0$y"));
    try testing.expect(!syncOutputReplyMeansSupported("\x1b[?2026;4$y"));
    try testing.expect(!syncOutputReplyMeansSupported(""));
    try testing.expect(!syncOutputReplyMeansSupported("\x1b[?2026;$y"));
}
