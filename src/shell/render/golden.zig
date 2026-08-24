//! Golden transcripts: an event script and a fixed width in, ANSI bytes out.
//!
//! The renderer is a pure function, so its whole observable behaviour is a byte
//! string — and a byte string is reviewable. Every golden is checked in, and a
//! diff to one is a diff a human has to look at and agree with. That is the
//! point: the failure this phase guards against is a repaint that looks fine
//! and is off by a row, which no assertion about row counts alone would catch.
//!
//! **Regenerating one:** the test prints the actual transcript to stderr on a
//! mismatch, framed by `--- golden <name> ---` markers. Read it, satisfy
//! yourself the change is intended, and paste it into the file. There is
//! deliberately no `--update` flag: a golden that can be refreshed without
//! being read is a golden that records whatever the code did last.

const std = @import("std");
const testing = std.testing;

const Counting = @import("counting_writer.zig").Counting;
const renderer_mod = @import("renderer.zig");
const transcript = @import("transcript.zig");
const Renderer = renderer_mod.Renderer;

const plain_caps: renderer_mod.Capabilities = .{
    .color = .none,
    .kitty_keyboard = false,
    .synchronized_output = false,
    .bracketed_paste = true,
    .size = .{ .cols = 24, .rows = 8 },
};

const Step = union(enum) {
    begin: renderer_mod.BlockKind,
    feed: []const u8,
    end,
    resize: renderer_mod.Size,
    paint,
};

fn golden(
    name: []const u8,
    caps: renderer_mod.Capabilities,
    script: []const Step,
) !void {
    const gpa = testing.allocator;

    var transcript_bytes: std.ArrayList(u8) = .empty;
    defer transcript_bytes.deinit(gpa);

    var renderer: Renderer = .init(gpa, caps, caps.size);
    defer renderer.deinit();

    for (script) |step| switch (step) {
        .begin => |kind| try renderer.beginBlock(kind),
        .feed => |bytes| try renderer.feed(bytes),
        .end => try renderer.endBlock(),
        .resize => |size| renderer.setSize(size),
        .paint => {
            var buffer: [16 * 1024]u8 = undefined;
            var sink: [16 * 1024]u8 = undefined;
            var counting: Counting = .init(&buffer, &sink);
            _ = try renderer.paint(&counting.writer);
            try counting.writer.flush();
            // Every golden is also a one-write-per-frame assertion, for free.
            try testing.expect(counting.writes <= 1);
            try transcript_bytes.appendSlice(gpa, counting.bytes());
        },
    };

    return transcript.expectGolden(gpa, name, transcript_bytes.items);
}

test "golden: a plain stream in three chunks" {
    try golden("plain", plain_caps, &.{
        .{ .begin = .assistant },
        .{ .feed = "The quick brown " },
        .paint,
        .{ .feed = "fox jumps over the lazy dog.\n" },
        .paint,
        .end,
        .paint,
    });
}

test "golden: wide characters at a narrow width" {
    var caps = plain_caps;
    caps.size = .{ .cols = 8, .rows = 8 };
    try golden("wide", caps, &.{
        .{ .begin = .assistant },
        .{ .feed = "日本語のテキスト\n" },
        .end,
        .paint,
    });
}

test "golden: headings and both kinds of list" {
    try golden("lists", plain_caps, &.{
        .{ .begin = .assistant },
        .{ .feed = "# Title\n\n- alpha bravo charlie\n- two\n\n1. first\n2. second\n" },
        .end,
        .paint,
    });
}

test "golden: a fenced block with inline markers inside it" {
    try golden("fence", plain_caps, &.{
        .{ .begin = .assistant },
        .{ .feed = "Try this:\n\n```zig\nconst x = **not bold**;\n```\n\nDone.\n" },
        .end,
        .paint,
    });
}

test "golden: a resize in the middle of a stream" {
    try golden("resize", plain_caps, &.{
        .{ .begin = .assistant },
        .{ .feed = "alpha bravo charlie delta echo\n" },
        .paint,
        .{ .resize = .{ .cols = 12, .rows = 8 } },
        .paint,
        .end,
        .paint,
    });
}

test "golden: a codepoint split across two chunks" {
    try golden("split-utf8", plain_caps, &.{
        .{ .begin = .assistant },
        .{ .feed = "ab\xe6\x97" },
        .paint,
        .{ .feed = "\xa5cd\n" },
        .paint,
        .end,
        .paint,
    });
}
