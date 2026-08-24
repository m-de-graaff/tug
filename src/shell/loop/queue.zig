//! The cross-thread event queue.
//!
//! Multi-producer, single-consumer: producers are provider threads, and the
//! consumer is always the loop thread. This is the only way an event reaches the
//! bus from off the loop thread, and it exists so `tugcore`'s bus can stay free
//! of locks — and free of `std.Io.Mutex`, which needs an `Io` that a sans-IO
//! module has no business holding.
//!
//! A mutex and a ring is the right size here. At one event per streamed chunk
//! the contention is a handful of uncontended lock/unlock pairs per frame, and a
//! lock-free ring would cost more in memory-ordering reasoning than it could
//! ever return in throughput.
//!
//! A producer pushes and then rings the `Waker`; the loop wakes, drains, and
//! publishes.

const std = @import("std");

const core = @import("tugcore");
const proto = @import("tugproto");

/// One turn of the loop drains the whole queue, so this only has to absorb what
/// arrives between two wakeups. A producer outrunning that is the firehose case
/// Phase 5 exists to test.
pub const capacity = 64;

pub const Queue = struct {
    /// Uncancelable throughout. A producer handing over an event it has already
    /// produced must not fail because something elsewhere was cancelled, and the
    /// critical sections here are three array writes long.
    mutex: std.Io.Mutex = .init,
    items: [capacity]proto.Payload = undefined,
    head: usize = 0,
    len: usize = 0,

    /// ponytail: payload slices are borrowed, and a queued payload outlives the
    /// stack frame that made it. Nothing crosses a thread boundary carrying
    /// bytes in Phase 3 — the only cross-thread signal is a resize, which has no
    /// payload — so ownership is deferred rather than solved. Phase 5's mock
    /// provider is the first real producer and is where it gets decided: either
    /// an arena drained alongside the queue, or a byte pool behind it.
    pub fn push(self: *Queue, io: std.Io, payload: proto.Payload) error{Full}!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.len == capacity) return error.Full;
        self.items[(self.head + self.len) % capacity] = payload;
        self.len += 1;
    }

    pub fn pop(self: *Queue, io: std.Io) ?proto.Payload {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.len == 0) return null;
        const payload = self.items[self.head];
        self.head = (self.head + 1) % capacity;
        self.len -= 1;
        return payload;
    }

    /// Publishes everything queued onto the bus, and reports how many. The count
    /// is what lets a caller tell an empty wake — a resize — from a full one.
    ///
    /// Pops one at a time and publishes outside the lock, so a subscriber that
    /// pushes cannot deadlock against the drain. Looping until `pop` comes back
    /// empty rather than taking a count up front also collects anything a
    /// producer added mid-drain.
    pub fn drainInto(self: *Queue, io: std.Io, bus: *core.Bus) usize {
        var delivered: usize = 0;
        while (self.pop(io)) |payload| {
            bus.publish(payload);
            delivered += 1;
        }
        return delivered;
    }
};

const testing = std.testing;

/// The tests need an `Io` and nothing more from it than a working futex, so the
/// single-threaded executor is enough even where the test spawns real threads:
/// what it configures is the async worker pool, not whether locks work.
fn testIo(threaded: *std.Io.Threaded) std.Io {
    threaded.* = .init_single_threaded;
    return threaded.io();
}

test "a queue drains in the order it was filled" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);

    var queue: Queue = .{};
    try queue.push(io, .session_start);
    try queue.push(io, .stream_end);
    try queue.push(io, .shutdown);

    try testing.expectEqual(proto.Event.session_start, queue.pop(io).?.event());
    try testing.expectEqual(proto.Event.stream_end, queue.pop(io).?.event());
    try testing.expectEqual(proto.Event.shutdown, queue.pop(io).?.event());
    try testing.expect(queue.pop(io) == null);
}

test "the ring wraps rather than growing" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);

    var queue: Queue = .{};
    for (0..capacity) |_| try queue.push(io, .session_start);
    try testing.expectError(error.Full, queue.push(io, .session_start));

    // Drain half, refill half: the indices have to wrap without losing order.
    for (0..capacity / 2) |_| _ = queue.pop(io);
    for (0..capacity / 2) |_| try queue.push(io, .shutdown);

    // The remaining originals come out first, then the new ones.
    for (0..capacity / 2) |_| {
        try testing.expectEqual(proto.Event.session_start, queue.pop(io).?.event());
    }
    for (0..capacity / 2) |_| {
        try testing.expectEqual(proto.Event.shutdown, queue.pop(io).?.event());
    }
    try testing.expect(queue.pop(io) == null);
}

const Recorder = struct {
    count: usize = 0,

    fn onEvent(context: ?*anyopaque, payload: proto.Payload) void {
        _ = payload;
        const self: *Recorder = @ptrCast(@alignCast(context.?));
        self.count += 1;
    }
};

test "draining publishes everything onto the bus and reports the count" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);

    var recorder: Recorder = .{};
    var bus: core.Bus = .{};
    try bus.subscribe(.{ .context = &recorder, .handler = Recorder.onEvent });

    var queue: Queue = .{};
    try queue.push(io, .session_start);
    try queue.push(io, .turn_end);

    try testing.expectEqual(@as(usize, 2), queue.drainInto(io, &bus));
    try testing.expectEqual(@as(usize, 2), recorder.count);
    try testing.expectEqual(@as(usize, 0), queue.drainInto(io, &bus));
}

test "pushes from other threads all arrive" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);

    var queue: Queue = .{};

    const Producer = struct {
        fn run(target: *Queue, producer_io: std.Io) void {
            for (0..16) |_| target.push(producer_io, .stream_end) catch return;
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Producer.run, .{ &queue, io });
    for (threads) |thread| thread.join();

    var drained: usize = 0;
    while (queue.pop(io)) |_| drained += 1;
    try testing.expectEqual(@as(usize, 64), drained);
}
