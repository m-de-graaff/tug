//! A `std.Io.Writer` whose bytes land in the renderer's open block.
//!
//! This exists so `/config`, `/keys` and `/theme` reuse `Config.write`,
//! `Keymap.write` and `Theme.write` verbatim. Those three take a writer, the
//! renderer takes `feed`, and the alternative to twenty-five lines here is
//! three report writers reimplemented against a different sink — which is three
//! chances for the screen and `--debug-config` to disagree about what tug read.
//!
//! **The stashed error.** `Renderer.feed` can fail to allocate;
//! `std.Io.Writer.Error` is `error{WriteFailed}` and cannot carry that. The
//! failure is held on the struct and re-raised by `finish`, which is the same
//! shape `Session.failed` uses for the same reason.

const std = @import("std");
const testing = std.testing;

const renderer_mod = @import("renderer.zig");
const Renderer = renderer_mod.Renderer;

pub const BlockWriter = struct {
    writer: std.Io.Writer,
    renderer: *Renderer,
    /// The real error behind a `WriteFailed`, when there was one.
    failed: ?renderer_mod.Error = null,

    /// The caller owns `buffer`, and its size is a batching choice rather than
    /// a limit: the adapter drains whenever it fills.
    pub fn init(renderer: *Renderer, buffer: []u8) BlockWriter {
        return .{
            .writer = .{ .vtable = &vtable, .buffer = buffer },
            .renderer = renderer,
        };
    }

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *BlockWriter = @alignCast(@fieldParentPtr("writer", w));

        // Buffered bytes are logically written first, then each slice of
        // `data`, with the last one repeated `splat` times. Same contract
        // `counting_writer.zig` implements beside this file.
        self.feed(w.buffer[0..w.end]) catch |err| return self.stash(err);
        w.end = 0;

        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            self.feed(slice) catch |err| return self.stash(err);
            consumed += slice.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            self.feed(pattern) catch |err| return self.stash(err);
            consumed += pattern.len;
        }
        return consumed;
    }

    fn feed(self: *BlockWriter, slice: []const u8) renderer_mod.Error!void {
        if (slice.len == 0) return;
        return self.renderer.feed(slice);
    }

    fn stash(self: *BlockWriter, err: renderer_mod.Error) std.Io.Writer.Error {
        self.failed = err;
        return error.WriteFailed;
    }

    /// Flushes what is buffered and re-raises whatever the renderer said.
    /// Call it before `endBlock`, or the tail of the report is still sitting in
    /// the writer.
    pub fn finish(self: *BlockWriter) renderer_mod.Error!void {
        self.writer.flush() catch |err| return self.failed orelse err;
        if (self.failed) |err| return err;
    }
};

const test_caps: renderer_mod.Capabilities = .{
    .color = .none,
    .kitty_keyboard = false,
    .synchronized_output = false,
    .bracketed_paste = true,
    .size = .{ .cols = 40, .rows = 200 },
};

test "everything written reaches the block, buffer or no buffer" {
    var renderer: Renderer = .init(testing.allocator, test_caps, test_caps.size);
    defer renderer.deinit();

    try renderer.beginBlock(.notice);
    // Eight bytes of buffer against far more than eight bytes of output: the
    // adapter has to drain, and draining is the half a one-shot buffer never
    // exercises.
    var buffer: [8]u8 = undefined;
    var block: BlockWriter = .init(&renderer, &buffer);
    for (0..64) |index| try block.writer.print("row {d}\n", .{index});
    try block.finish();
    try renderer.endBlock();

    var out: [64 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);
    _ = try renderer.paint(&writer);
    const painted = writer.buffered();

    try testing.expect(std.mem.indexOf(u8, painted, "row 0") != null);
    try testing.expect(std.mem.indexOf(u8, painted, "row 63") != null);
}

test "an empty write leaves the block empty rather than opening a line" {
    var renderer: Renderer = .init(testing.allocator, test_caps, test_caps.size);
    defer renderer.deinit();

    try renderer.beginBlock(.notice);
    var buffer: [64]u8 = undefined;
    var block: BlockWriter = .init(&renderer, &buffer);
    try block.finish();
    try renderer.endBlock();

    var out: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);
    _ = try renderer.paint(&writer);
}

test "an allocator failure comes back as itself, not as WriteFailed" {
    // `Renderer.feed` can fail to allocate and `std.Io.Writer.Error` cannot
    // carry that, so the adapter stashes it and re-raises at `finish`. Without
    // this a machine out of memory would report a write failure to a terminal
    // that is perfectly healthy.
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var renderer: Renderer = .init(failing.allocator(), test_caps, test_caps.size);
    defer renderer.deinit();

    var buffer: [8]u8 = undefined;
    var block: BlockWriter = .init(&renderer, &buffer);
    block.writer.writeAll("a line long enough to force a drain\n") catch {};
    try testing.expectError(error.OutOfMemory, block.finish());
}
