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
//!
//! **A slot owns the bytes its payload points at** (`DR-010`). `Payload`
//! documents its slices as borrowed, which is right on the loop thread — the
//! renderer copies on `feed`, so nobody else needs to own anything. It stops
//! being right the moment the producer is a different thread: its buffer is
//! reused for the next chunk long before the loop drains. So `push` copies in
//! and `pop` copies out, which costs two memcpys of at most 512 bytes and
//! removes the lifetime question entirely.

const std = @import("std");

const core = @import("tugcore");
const proto = @import("tugproto");

/// One turn of the loop drains the whole queue, so this only has to absorb what
/// arrives between two wakeups. A producer outrunning that gets `error.Full`
/// and waits, which is the backpressure that keeps a firehose from growing
/// memory without bound.
pub const capacity = 64;

/// The largest text a single queued payload may carry. Chosen against the
/// producer rather than the consumer: the cadence engine's largest ordinary
/// chunk is 64 bytes, and a fault that produces more splits across slots on the
/// way in. 64 slots at this size is 32 KiB of static footprint, against a
/// 10 MiB RSS budget.
pub const max_payload_bytes: usize = 512;

const Slot = struct {
    payload: proto.Payload,
    bytes: [max_payload_bytes]u8,
    len: usize,
};

/// The borrowed slice a payload carries, or an empty one.
///
/// Exactly three arms of the catalog carry bytes. The switch is deliberately
/// exhaustive rather than an `else`: a fourth added later would be silently
/// dropped here, and the compiler refusing to build is how that gets noticed.
fn payloadBytes(payload: proto.Payload) []const u8 {
    return switch (payload) {
        .input_submit => |p| p.text,
        .stream_delta => |p| p.text,
        .err => |p| p.message,
        .session_start, .request_start, .stream_end => "",
        .tool_request, .tool_decision, .tool_result => "",
        .turn_end, .shutdown => "",
    };
}

/// The same payload with its slice repointed at `bytes`.
fn withBytes(payload: proto.Payload, bytes: []const u8) proto.Payload {
    return switch (payload) {
        .input_submit => .{ .input_submit = .{ .text = bytes } },
        .stream_delta => .{ .stream_delta = .{ .text = bytes } },
        .err => .{ .err = .{ .message = bytes } },
        else => payload,
    };
}

pub const Queue = struct {
    /// Uncancelable throughout. A producer handing over an event it has already
    /// produced must not fail because something elsewhere was cancelled, and the
    /// critical sections here are one memcpy long.
    mutex: std.Io.Mutex = .init,
    items: [capacity]Slot = undefined,
    head: usize = 0,
    len: usize = 0,

    /// Copies `payload` and its bytes into a slot.
    ///
    /// A payload larger than a slot is refused rather than truncated. Splitting
    /// it is the producer's job, and it is free: a text delta cut in two is two
    /// text deltas, which is what the whole streaming path is made of anyway.
    pub fn push(self: *Queue, io: std.Io, payload: proto.Payload) error{ Full, PayloadTooLarge }!void {
        const bytes = payloadBytes(payload);
        if (bytes.len > max_payload_bytes) return error.PayloadTooLarge;

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.len == capacity) return error.Full;
        const slot = &self.items[(self.head + self.len) % capacity];
        @memcpy(slot.bytes[0..bytes.len], bytes);
        slot.len = bytes.len;
        slot.payload = payload;
        self.len += 1;
    }

    /// Copies the oldest payload into `out` and returns it pointing there.
    ///
    /// Returning a slice into the ring instead would be a use-after-free with
    /// extra steps: the slot is available to a producer the instant this
    /// returns, and a firehose refills it well before the caller has published.
    /// `out` must outlive the returned payload — the loop's lives in
    /// `drainQueue`, which is exactly the publish-and-forget lifetime the bus
    /// documents.
    pub fn pop(self: *Queue, io: std.Io, out: *[max_payload_bytes]u8) ?proto.Payload {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.len == 0) return null;
        const slot = &self.items[self.head];
        @memcpy(out[0..slot.len], slot.bytes[0..slot.len]);
        const payload = withBytes(slot.payload, out[0..slot.len]);
        self.head = (self.head + 1) % capacity;
        self.len -= 1;
        return payload;
    }

    /// Publishes what is queued onto the bus, and reports how many. The count
    /// is what lets a caller tell an empty wake — a resize — from a full one.
    ///
    /// Pops one at a time and publishes outside the lock, so a subscriber that
    /// pushes cannot deadlock against the drain.
    ///
    /// **Bounded, and that bound is load-bearing.** Draining until `pop` comes
    /// back empty reads as the thorough thing to do and is a livelock against
    /// any producer faster than the consumer: a firehose refills the ring
    /// mid-drain, `pop` never returns null, and the loop never reaches the
    /// paint that the whole frame budget is expressed in. `--provider mock
    /// --mock-fault firehose` did exactly that — one frame, then a process that
    /// looked hung.
    ///
    /// `capacity` is the right bound rather than an arbitrary one: it is
    /// everything that *could* have been queued when the drain began, so
    /// nothing is ever left behind for a wake that may not come.
    pub fn drainInto(self: *Queue, io: std.Io, bus: *core.Bus) usize {
        var out: [max_payload_bytes]u8 = undefined;
        var delivered: usize = 0;
        while (delivered < capacity) : (delivered += 1) {
            const payload = self.pop(io, &out) orelse break;
            bus.publish(payload);
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

    var out: [max_payload_bytes]u8 = undefined;
    try testing.expectEqual(proto.Event.session_start, queue.pop(io, &out).?.event());
    try testing.expectEqual(proto.Event.stream_end, queue.pop(io, &out).?.event());
    try testing.expectEqual(proto.Event.shutdown, queue.pop(io, &out).?.event());
    try testing.expect(queue.pop(io, &out) == null);
}

test "the ring wraps rather than growing" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);

    var queue: Queue = .{};
    for (0..capacity) |_| try queue.push(io, .session_start);
    try testing.expectError(error.Full, queue.push(io, .session_start));

    // Drain half, refill half: the indices have to wrap without losing order.
    var out: [max_payload_bytes]u8 = undefined;
    for (0..capacity / 2) |_| _ = queue.pop(io, &out);
    for (0..capacity / 2) |_| try queue.push(io, .shutdown);

    // The remaining originals come out first, then the new ones.
    for (0..capacity / 2) |_| {
        try testing.expectEqual(proto.Event.session_start, queue.pop(io, &out).?.event());
    }
    for (0..capacity / 2) |_| {
        try testing.expectEqual(proto.Event.shutdown, queue.pop(io, &out).?.event());
    }
    try testing.expect(queue.pop(io, &out) == null);
}

test "a payload's bytes survive the frame that pushed them" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);

    var queue: Queue = .{};

    // The bug this exists to prevent: a producer builds a delta in a local
    // buffer, pushes it, and the buffer is reused for the next chunk long
    // before the loop publishes.
    {
        var scratch: [15]u8 = "hello, tugboat!".*;
        try queue.push(io, .{ .stream_delta = .{ .text = &scratch } });
        @memset(&scratch, 'X');
    }

    var out: [max_payload_bytes]u8 = undefined;
    const popped = queue.pop(io, &out).?;
    try testing.expectEqualStrings("hello, tugboat!", popped.stream_delta.text);
}

test "a slot is not reused under a payload already popped" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);

    var queue: Queue = .{};
    try queue.push(io, .{ .stream_delta = .{ .text = "first" } });

    var out: [max_payload_bytes]u8 = undefined;
    const popped = queue.pop(io, &out).?;

    // The producer refills the very slot that was just freed. `popped` must not
    // change under it, which is only true because `pop` copied out.
    for (0..capacity) |_| try queue.push(io, .{ .stream_delta = .{ .text = "later" } });
    try testing.expectEqualStrings("first", popped.stream_delta.text);
}

test "an oversized payload is refused rather than truncated" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);

    var queue: Queue = .{};
    const huge = "x" ** (max_payload_bytes + 1);
    try testing.expectError(
        error.PayloadTooLarge,
        queue.push(io, .{ .stream_delta = .{ .text = huge } }),
    );
}

test "payloads with no bytes still round-trip" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);

    var queue: Queue = .{};
    try queue.push(io, .session_start);
    try queue.push(io, .{ .err = .{ .message = "boom" } });

    var out: [max_payload_bytes]u8 = undefined;
    try testing.expectEqual(proto.Event.session_start, queue.pop(io, &out).?.event());
    try testing.expectEqualStrings("boom", queue.pop(io, &out).?.err.message);
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

test "a drain returns even against a producer that never stops" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);

    var recorder: Recorder = .{};
    var bus: core.Bus = .{};
    try bus.subscribe(.{ .context = &recorder, .handler = Recorder.onEvent });

    var queue: Queue = .{};
    var running: std.atomic.Value(bool) = .init(true);

    // A producer that refills the ring as fast as it empties. Draining until
    // `pop` returns null against this never returns, and the loop that is
    // supposed to be painting between drains never paints. Before the bound,
    // `--mock-fault firehose` reproduced this as a process that painted one
    // frame and then looked hung.
    const Flood = struct {
        fn run(target: *Queue, producer_io: std.Io, alive: *std.atomic.Value(bool)) void {
            while (alive.load(.acquire)) {
                target.push(producer_io, .{ .stream_delta = .{ .text = "x" } }) catch continue;
            }
        }
    };

    const thread = try std.Thread.spawn(.{}, Flood.run, .{ &queue, io, &running });
    defer {
        running.store(false, .release);
        thread.join();
    }

    // Each of these has to come back. If any one of them hangs, the test times
    // out rather than failing — which is itself the signal. The loop runs until
    // the producer has been scheduled at least once, because a drain that
    // returned only because the queue was still empty proves nothing.
    var rounds: usize = 0;
    while (recorder.count == 0 and rounds < 10_000) : (rounds += 1) {
        try testing.expect(queue.drainInto(io, &bus) <= capacity);
    }
    try testing.expect(recorder.count > 0);
    for (0..8) |_| {
        try testing.expect(queue.drainInto(io, &bus) <= capacity);
    }
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

    var out: [max_payload_bytes]u8 = undefined;
    var drained: usize = 0;
    while (queue.pop(io, &out)) |_| drained += 1;
    try testing.expectEqual(@as(usize, 64), drained);
}
