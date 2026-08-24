//! The one invariant that cannot be allowed to drift.
//!
//! Every frame ends with the cursor at column 0 of a fresh row, `tail_rows`
//! rows below the top of the tail. The next frame moves up exactly that many
//! and erases below. One too many and the repaint eats a row of the user's
//! scrollback — permanently, because scrollback is the one thing tug never
//! rewrites. One too few and the old tail is left on screen under the new one.
//!
//! Goldens pin down what a handful of scripts look like. This pins down the
//! arithmetic underneath all of them, over randomized content and widths:
//! the rows a frame reports are the rows it actually emitted, and the next
//! frame's cursor-up is the previous frame's tail count.

const std = @import("std");
const testing = std.testing;

const Counting = @import("counting_writer.zig").Counting;
const renderer_mod = @import("renderer.zig");
const Renderer = renderer_mod.Renderer;

/// Deliberately adversarial: markers that may or may not close, a fence toggle,
/// wide characters, a combining mark, an emoji, control bytes, and enough
/// spaces and newlines that the wrapper actually gets to make decisions.
const alphabet = [_][]const u8{
    "a",        "bb",       "ccc",       "dddd",      "eeeeeeeeeeeeeeee",
    " ",        " ",        " ",         "  ",        "\t",
    "\n",       "\n",       "\n\n",      "# ",        "- ",
    "1. ",      "**",       "*",         "`",         "```\n",
    "\u{65e5}", "\u{672c}", "\u{1f600}", "e\u{0301}", "\x1b[31m",
};

/// Counts physical rows in a frame the way a terminal would: one per `\r\n`.
/// Every row the renderer emits ends with one, no escape sequence it emits
/// contains one, and control bytes never survive into the content.
fn countRows(frame: []const u8) u32 {
    var rows: u32 = 0;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, frame, index, "\r\n")) |at| {
        rows += 1;
        index = at + 2;
    }
    return rows;
}

/// The cursor-up count a frame opens with, or null when it has none.
fn cursorUp(frame: []const u8) ?u32 {
    const start = std.mem.indexOf(u8, frame, "\r\x1b[") orelse return null;
    const rest = frame[start + 3 ..];
    var digits: usize = 0;
    while (digits < rest.len and std.ascii.isDigit(rest[digits])) digits += 1;
    if (digits == 0 or digits >= rest.len) return null;
    // `\r\x1b[0J` is a repaint with nothing above it to move over.
    if (rest[digits] != 'F') return null;
    return std.fmt.parseInt(u32, rest[0..digits], 10) catch null;
}

test "reported rows are emitted rows, and each frame moves back over exactly the last" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x7c9f_2b41);
    const random = prng.random();

    var buffer: [128 * 1024]u8 = undefined;
    var sink: [128 * 1024]u8 = undefined;

    for (0..400) |_| {
        const caps: renderer_mod.Capabilities = .{
            .color = .none,
            .kitty_keyboard = false,
            .synchronized_output = random.boolean(),
            .bracketed_paste = true,
            .size = .{
                .cols = random.intRangeAtMost(u16, 1, 60),
                .rows = random.intRangeAtMost(u16, 1, 24),
            },
        };

        var renderer: Renderer = .init(gpa, caps, caps.size);
        defer renderer.deinit();
        try renderer.beginBlock(switch (random.uintLessThan(u8, 3)) {
            0 => .user,
            1 => .notice,
            else => .assistant,
        });

        var previous_tail: ?u32 = null;
        const paints = random.intRangeAtMost(usize, 1, 6);
        for (0..paints) |_| {
            for (0..random.intRangeAtMost(usize, 0, 12)) |_| {
                try renderer.feed(alphabet[random.uintLessThan(usize, alphabet.len)]);
            }
            if (random.boolean()) renderer.setSize(.{
                .cols = random.intRangeAtMost(u16, 1, 60),
                .rows = random.intRangeAtMost(u16, 1, 24),
            });
            if (random.uintLessThan(u8, 8) == 0) try renderer.endBlock();

            var counting: Counting = .init(&buffer, &sink);
            const frame = try renderer.paint(&counting.writer);
            try counting.writer.flush();
            const output = counting.bytes();

            // The frame reports what it emitted.
            try testing.expectEqual(
                frame.committed_rows + frame.tail_rows,
                countRows(output),
            );

            // The frame moved back over exactly the previous frame's tail.
            if (previous_tail) |expected| {
                const moved = cursorUp(output);
                if (expected == 0) {
                    try testing.expectEqual(@as(?u32, null), moved);
                } else {
                    try testing.expectEqual(@as(?u32, expected), moved);
                }
            }
            previous_tail = frame.tail_rows;

            // The tail fits on screen, or the cursor-up cannot reach its top.
            // Below three rows there is nowhere for the status hint and the
            // parking row to both go, and the renderer says so rather than
            // pretending otherwise.
            if (renderer.size.rows >= 3) {
                try testing.expect(frame.tail_rows <= renderer.size.rows);
            }
        }
    }
}
