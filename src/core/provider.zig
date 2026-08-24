//! The provider seam.
//!
//! A provider is a blocking iterator of `StreamEvent` and nothing else. It has
//! no idea what a socket is, no idea what a terminal is, and no opinion about
//! how fast its events should arrive — that is the cadence engine's job, one
//! layer out, where the clock lives.
//!
//! One function pointer and an erased context, which is the shape
//! `Bus.Subscriber` already uses; a second idiom for the same thing would be a
//! second thing to learn. There is deliberately no `deinit`, no `cancel` and no
//! error union: a provider that fails says so by emitting an `err` event,
//! because that is the failure the renderer already knows how to draw, and
//! cancellation is the frontend's business — it owns the thread.
//!
//! v0.2's HTTP provider satisfies this signature without either side changing,
//! which is the entire reason it is written a version early.

const std = @import("std");

const proto = @import("tugproto");

pub const Provider = struct {
    context: ?*anyopaque = null,

    /// The next event, or null once the stream is over. Blocking: a real
    /// provider sits in a read here, which is why it runs on its own thread.
    next: *const fn (context: ?*anyopaque) ?proto.StreamEvent,

    pub fn nextEvent(self: Provider) ?proto.StreamEvent {
        return self.next(self.context);
    }
};

const testing = std.testing;

const TwoEvents = struct {
    sent: usize = 0,

    fn nextErased(context: ?*anyopaque) ?proto.StreamEvent {
        const self: *TwoEvents = @ptrCast(@alignCast(context.?));
        defer self.sent += 1;
        return switch (self.sent) {
            0 => .{ .text_delta = "hi" },
            1 => .{ .stop = .{ .reason = .end_turn } },
            else => null,
        };
    }

    fn provider(self: *TwoEvents) Provider {
        return .{ .context = self, .next = nextErased };
    }
};

test "a provider is an iterator that ends" {
    var source: TwoEvents = .{};
    const p = source.provider();

    try testing.expectEqualStrings("hi", p.nextEvent().?.text_delta);
    try testing.expectEqual(proto.StopReason.end_turn, p.nextEvent().?.stop.reason);
    try testing.expect(p.nextEvent() == null);
}
