//! The event bus.
//!
//! Consumers subscribe; the loop publishes. That is the whole design, and the
//! reason it can be an array and a length is a single invariant:
//!
//! **The bus runs on the loop thread only.** Nothing else publishes to it and
//! nothing else subscribes. Cross-thread producers — the provider thread from
//! Phase 5 onward — push onto `tugshell`'s queue, which the loop drains and
//! republishes here. That is what keeps this file free of a mutex, and free of
//! `std.Thread`, which `tugcore` may not import at all.
//!
//! There is no per-event subscription filter. Subscribers switch on the payload
//! themselves, and a filter would be a second dispatch table sitting in front of
//! one that already exists.

const std = @import("std");

const proto = @import("tugproto");

/// Enough for v0.1's consumers — renderer, editor, session log — with room
/// spare. Exceeding it is a wiring bug found at startup, not a runtime
/// condition to recover from.
pub const max_subscribers = 8;

pub const Subscriber = struct {
    context: ?*anyopaque = null,
    handler: *const fn (context: ?*anyopaque, payload: proto.Payload) void,
};

pub const Bus = struct {
    subscribers: [max_subscribers]Subscriber = undefined,
    len: usize = 0,

    pub fn subscribe(self: *Bus, subscriber: Subscriber) error{TooManySubscribers}!void {
        if (self.len == max_subscribers) return error.TooManySubscribers;
        self.subscribers[self.len] = subscriber;
        self.len += 1;
    }

    /// Delivers to every subscriber, in subscription order.
    pub fn publish(self: *Bus, payload: proto.Payload) void {
        for (self.subscribers[0..self.len]) |subscriber| {
            subscriber.handler(subscriber.context, payload);
        }
    }
};

const testing = std.testing;

const Counter = struct {
    seen: usize = 0,
    last: ?proto.Event = null,

    fn onEvent(context: ?*anyopaque, payload: proto.Payload) void {
        const self: *Counter = @ptrCast(@alignCast(context.?));
        self.seen += 1;
        self.last = payload.event();
    }
};

test "publish reaches every subscriber" {
    var first: Counter = .{};
    var second: Counter = .{};
    var bus: Bus = .{};

    try bus.subscribe(.{ .context = &first, .handler = Counter.onEvent });
    try bus.subscribe(.{ .context = &second, .handler = Counter.onEvent });
    bus.publish(.{ .stream_delta = .{ .text = "hello" } });

    try testing.expectEqual(@as(usize, 1), first.seen);
    try testing.expectEqual(@as(usize, 1), second.seen);
    try testing.expectEqual(proto.Event.stream_delta, second.last.?);
}

test "publishing with no subscribers is not an error" {
    var bus: Bus = .{};
    bus.publish(.shutdown);
}

test "subscribing past the cap fails rather than overruns" {
    var counter: Counter = .{};
    var bus: Bus = .{};
    for (0..max_subscribers) |_| {
        try bus.subscribe(.{ .context = &counter, .handler = Counter.onEvent });
    }
    try testing.expectError(
        error.TooManySubscribers,
        bus.subscribe(.{ .context = &counter, .handler = Counter.onEvent }),
    );
}
