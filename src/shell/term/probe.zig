//! Asking the terminal what it supports, and taking silence for an answer.
//!
//! Extracted from `main.zig` in Phase 6, when the shell became the fourth
//! caller. Every read is gated on `wait`, because a terminal that supports
//! neither protocol answers neither query and the descriptor is in raw mode
//! with `VMIN=1`: a read that is not gated never returns. That was `--caps`
//! hanging on a terminal that answers nothing, closed in Phase 3, and it stays
//! closed because the gate moved with the code.
//!
//! The whole 50 ms budget is spent once rather than once per query, so a
//! terminal that answers the first and not the second costs one timeout rather
//! than two.

const std = @import("std");

const backend = @import("backend.zig");
const caps = @import("caps.zig");
const modes = @import("modes.zig");
const waiting = @import("../loop/wait.zig");

/// How much the probe will read before it stops. A terminal that sends more
/// than this during the probe window is sending a paste, and the overflow is
/// dropped rather than grown into.
pub const buffer_bytes: usize = 256;

pub const Result = struct {
    probe: caps.Probe = .{},
    /// Bytes that arrived during the probe window and were not replies: a
    /// keystroke from someone who started typing before the terminal answered.
    /// Borrows the caller's buffer.
    leftover: []const u8 = "",
};

/// Asks the terminal what it supports, and takes silence for an answer.
///
/// `buffer` is the caller's because `leftover` borrows it. Anything typed
/// inside the probe window has to outlive this call — it belongs to the
/// decoder, not to the probe — and on a terminal that answers neither query
/// that window is the whole 50 ms, which is long enough to lose a real
/// keystroke in.
pub fn run(io: std.Io, terminal: *backend.Backend, buffer: *[buffer_bytes]u8) Result {
    var write_buffer: [64]u8 = undefined;
    var terminal_writer = terminal.writer(io, &write_buffer);
    const out = &terminal_writer.interface;

    out.writeAll(modes.kitty_query) catch return .{};
    out.writeAll(modes.sync_output_query) catch return .{};
    out.flush() catch return .{};

    var read_buffer: [256]u8 = undefined;
    var terminal_reader = terminal.reader(io, &read_buffer);

    var reply_len: usize = 0;
    const deadline = waiting.nowMs(io) + modes.probe_timeout_ms;

    while (reply_len < buffer.len) {
        const now = waiting.nowMs(io);
        if (now >= deadline) break;

        const remaining: u32 = @intCast(deadline - now);
        const ready = waiting.wait(terminal.handle(), null, remaining) catch break;
        if (!ready.input) break;

        const chunk = terminal_reader.interface.peekGreedy(1) catch break;
        if (chunk.len == 0) break;

        const take = @min(chunk.len, buffer.len - reply_len);
        @memcpy(buffer[reply_len..][0..take], chunk[0..take]);
        reply_len += take;
        terminal_reader.interface.toss(chunk.len);

        if (repliesComplete(buffer[0..reply_len])) break;
    }

    const reply = buffer[0..reply_len];
    const detected: caps.Probe = .{
        .kitty_keyboard = std.mem.indexOf(u8, reply, "\x1b[?") != null and
            modes.kittyReplyMeansSupported(firstReply(reply)),
        .synchronized_output = std.mem.indexOf(u8, reply, "2026;") != null,
    };

    // The verdict is read first: `stripReplies` rewrites the buffer it is read
    // from.
    return .{ .probe = detected, .leftover = stripReplies(buffer[0..reply_len]) };
}

/// Removes every `CSI ? ... <final>` sequence from `bytes`, in place, and
/// returns what is left.
///
/// Both probe replies start `CSI ?` — kitty answers `CSI ? <flags> u` and
/// synchronized output answers `CSI ? 2026 ; <state> $y` — and nothing a
/// keyboard produces does. An arrow key is `CSI A`, a paste marker is
/// `CSI 200 ~`; neither carries the `?`, and both survive.
fn stripReplies(bytes: []u8) []u8 {
    var out: usize = 0;
    var at: usize = 0;
    while (at < bytes.len) {
        const is_reply = at + 2 < bytes.len and
            bytes[at] == 0x1b and bytes[at + 1] == '[' and bytes[at + 2] == '?';
        if (is_reply) {
            // Skip to the sequence's final byte, which is 0x40-0x7e. `$` is an
            // intermediate and does not end it.
            var end = at + 3;
            while (end < bytes.len and (bytes[end] < 0x40 or bytes[end] > 0x7e)) end += 1;
            at = @min(end + 1, bytes.len);
            continue;
        }
        bytes[out] = bytes[at];
        out += 1;
        at += 1;
    }
    return bytes[0..out];
}

/// True once both replies are present, so a terminal that answers promptly
/// costs a round trip rather than the whole 50 ms budget.
///
/// The kitty reply is `CSI ? <flags> u` and the synchronized-output reply is
/// `CSI ? 2026 ; <state> $y`, so `CSI ?` identifies neither of them on its own
/// — the `u` terminator and the mode number are what tell them apart.
///
/// This is only an early exit. Getting it wrong costs the rest of the 50 ms
/// budget; it can never produce a wrong verdict, because the verdict is read
/// from the accumulated bytes either way.
fn repliesComplete(reply: []const u8) bool {
    return std.mem.indexOf(u8, reply, "2026;") != null and
        std.mem.indexOfScalar(u8, reply, 'u') != null;
}

/// The terminal may answer both probes in one read, so split at the second CSI.
fn firstReply(reply: []const u8) []const u8 {
    if (reply.len < 3) return reply;
    if (std.mem.indexOfPos(u8, reply, 1, "\x1b[")) |second| return reply[0..second];
    return reply;
}

const testing = std.testing;

test "the probe replies are removed and everything else survives" {
    const cases = [_]struct { input: []const u8, want: []const u8 }{
        // Both replies and nothing else.
        .{ .input = "\x1b[?3u\x1b[?2026;2$y", .want = "" },
        // A keystroke that arrived while the terminal was thinking.
        .{ .input = "\x1b[?3u" ++ "hi" ++ "\x1b[?2026;2$y", .want = "hi" },
        // A terminal that answered nothing: it is all input.
        .{ .input = "hello", .want = "hello" },
        // An arrow key, which is a CSI without the `?` and must not be eaten.
        .{ .input = "\x1b[?3u\x1b[A", .want = "\x1b[A" },
        // A paste that started inside the window.
        .{ .input = "\x1b[200~text", .want = "\x1b[200~text" },
        .{ .input = "", .want = "" },
    };

    for (cases) |case| {
        var buffer: [64]u8 = undefined;
        @memcpy(buffer[0..case.input.len], case.input);
        try testing.expectEqualStrings(case.want, stripReplies(buffer[0..case.input.len]));
    }
}

test "the probe stops early only once both replies have arrived" {
    try testing.expect(!repliesComplete(""));
    try testing.expect(!repliesComplete("\x1b[?3u"));

    // The synchronized-output reply on its own also starts `CSI ?`, so a
    // marker that only looked for that would call this pair complete.
    try testing.expect(!repliesComplete("\x1b[?2026;2$y"));

    try testing.expect(repliesComplete("\x1b[?3u\x1b[?2026;2$y"));
    try testing.expect(repliesComplete("\x1b[?2026;2$y\x1b[?3u"));
}

test "splitting a combined probe reply keeps the first response" {
    try testing.expectEqualStrings("\x1b[?3u", firstReply("\x1b[?3u\x1b[?2026;2$y"));
    try testing.expectEqualStrings("\x1b[?3u", firstReply("\x1b[?3u"));
    try testing.expectEqualStrings("", firstReply(""));
}
