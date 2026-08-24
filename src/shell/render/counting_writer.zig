//! A writer that counts how often bytes actually reach the sink.
//!
//! This exists for one invariant: **one `write()` per frame.** A frame that
//! reaches the terminal in two syscalls can be observed half-drawn, and the
//! flicker-free claim does not rest on the terminal's synchronized-output
//! support — that is an optimization layered on top of it. Composing the whole
//! frame in a buffer and flushing it once is the guarantee, so the test needs
//! to be able to see the syscalls.
//!
//! Test-only: nothing outside a test block imports this.

const std = @import("std");

pub const Counting = struct {
    writer: std.Io.Writer,
    sink: []u8,
    len: usize = 0,
    writes: usize = 0,

    pub fn init(buffer: []u8, sink: []u8) Counting {
        return .{
            .writer = .{ .vtable = &vtable, .buffer = buffer },
            .sink = sink,
        };
    }

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Counting = @alignCast(@fieldParentPtr("writer", w));
        self.writes += 1;

        // Buffered bytes are logically written first, then each slice of
        // `data`, with the last one repeated `splat` times.
        self.append(w.buffer[0..w.end]) catch return error.WriteFailed;
        w.end = 0;

        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            self.append(slice) catch return error.WriteFailed;
            consumed += slice.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            self.append(pattern) catch return error.WriteFailed;
            consumed += pattern.len;
        }
        return consumed;
    }

    fn append(self: *Counting, slice: []const u8) error{Overflow}!void {
        if (self.len + slice.len > self.sink.len) return error.Overflow;
        @memcpy(self.sink[self.len..][0..slice.len], slice);
        self.len += slice.len;
    }

    /// Everything written so far. Call after `flush`, or the tail of the frame
    /// is still sitting in the writer's buffer.
    pub fn bytes(self: *const Counting) []const u8 {
        return self.sink[0..self.len];
    }
};

const testing = std.testing;

test "a frame that fits in the buffer reaches the sink once" {
    var buffer: [64]u8 = undefined;
    var sink: [64]u8 = undefined;
    var counting: Counting = .init(&buffer, &sink);

    try counting.writer.writeAll("one ");
    try counting.writer.writeAll("frame");
    try testing.expectEqual(@as(usize, 0), counting.writes);

    try counting.writer.flush();
    try testing.expectEqual(@as(usize, 1), counting.writes);
    try testing.expectEqualStrings("one frame", counting.bytes());
}

test "a frame that overflows the buffer is more than one write" {
    // Which is the failure this exists to catch: a renderer composing a frame
    // out of many small writes into a buffer too small to hold it hits the sink
    // more than once, and the terminal can show the frame half-drawn.
    var buffer: [8]u8 = undefined;
    var sink: [64]u8 = undefined;
    var counting: Counting = .init(&buffer, &sink);

    for (0..5) |_| try counting.writer.writeAll("abcd");
    try counting.writer.flush();
    try testing.expect(counting.writes > 1);
    try testing.expectEqualStrings("abcd" ** 5, counting.bytes());
}

test "nothing written is nothing counted" {
    var buffer: [16]u8 = undefined;
    var sink: [16]u8 = undefined;
    var counting: Counting = .init(&buffer, &sink);
    try counting.writer.flush();
    try testing.expectEqual(@as(usize, 0), counting.writes);
    try testing.expectEqualStrings("", counting.bytes());
}
