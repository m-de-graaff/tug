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

/// Asks the terminal what it supports, and takes silence for an answer.
pub fn run(io: std.Io, terminal: *backend.Backend) caps.Probe {
    var write_buffer: [64]u8 = undefined;
    var terminal_writer = terminal.writer(io, &write_buffer);
    const out = &terminal_writer.interface;

    out.writeAll(modes.kitty_query) catch return .{};
    out.writeAll(modes.sync_output_query) catch return .{};
    out.flush() catch return .{};

    var read_buffer: [256]u8 = undefined;
    var terminal_reader = terminal.reader(io, &read_buffer);

    var reply_buffer: [256]u8 = undefined;
    var reply_len: usize = 0;
    const deadline = waiting.nowMs(io) + modes.probe_timeout_ms;

    while (reply_len < reply_buffer.len) {
        const now = waiting.nowMs(io);
        if (now >= deadline) break;

        const remaining: u32 = @intCast(deadline - now);
        const ready = waiting.wait(terminal.handle(), null, remaining) catch break;
        if (!ready.input) break;

        const chunk = terminal_reader.interface.peekGreedy(1) catch break;
        if (chunk.len == 0) break;

        const take = @min(chunk.len, reply_buffer.len - reply_len);
        @memcpy(reply_buffer[reply_len..][0..take], chunk[0..take]);
        reply_len += take;
        terminal_reader.interface.toss(chunk.len);

        if (repliesComplete(reply_buffer[0..reply_len])) break;
    }

    const reply = reply_buffer[0..reply_len];
    return .{
        .kitty_keyboard = std.mem.indexOf(u8, reply, "\x1b[?") != null and
            modes.kittyReplyMeansSupported(firstReply(reply)),
        .synchronized_output = std.mem.indexOf(u8, reply, "2026;") != null,
    };
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
