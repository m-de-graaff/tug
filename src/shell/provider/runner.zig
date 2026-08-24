//! The provider thread.
//!
//! Pull an event, cut it to the cadence's chunk size, wait the cadence's delay,
//! push it on the queue, ring the waker. That is the whole of it, and it is the
//! shape every real provider will have in v0.2 — only the `Provider` behind it
//! changes, and it changes on the other side of a seam this file never looks
//! through.
//!
//! It runs on its own thread because `Provider.nextEvent` is documented as
//! blocking. The only things it shares with the loop are the queue, which has a
//! mutex, the waker, which coalesces and therefore cannot block, and one atomic
//! bool.
//!
//! Backpressure is the interesting part. The queue is 64 fixed slots, so a
//! producer that outruns the loop gets `error.Full` rather than growing memory
//! without bound. The answer is to ring the doorbell and wait a millisecond:
//! the loop is behind, and the right thing for a producer to do about that is
//! nothing, slowly.

const std = @import("std");

const core = @import("tugcore");
const proto = @import("tugproto");

const cadence_mod = @import("cadence.zig");
const queue_mod = @import("../loop/queue.zig");
const waiting = @import("../loop/wait.zig");

const Cadence = cadence_mod.Cadence;
const Queue = queue_mod.Queue;
const Waker = waiting.Waker;

/// How long to wait before retrying a push onto a full queue. One millisecond
/// is roughly an eighth of a frame: long enough not to spin, short enough that
/// the producer is ready again the moment the loop drains.
pub const backpressure_ms: u32 = 1;

pub const Runner = struct {
    io: std.Io,
    provider: core.Provider,
    cadence: *Cadence,
    queue: *Queue,
    waker: *Waker,
    stop: *std.atomic.Value(bool),

    pub fn spawn(self: *Runner) std.Thread.SpawnError!std.Thread {
        return std.Thread.spawn(.{}, run, .{self});
    }

    /// Never fails.
    ///
    /// A provider thread that returned an error would have nowhere to return it
    /// to. Every failure it can actually have — a full queue, an interrupted
    /// sleep — is handled here, and the one the *user* needs to know about
    /// arrives as an `err` payload like any other event.
    pub fn run(self: *Runner) void {
        self.send(.request_start);

        while (!self.stop.load(.acquire)) {
            const event = self.provider.nextEvent() orelse break;
            switch (event) {
                .text_delta => |bytes| self.sendText(bytes),
                .err => |e| self.send(.{ .err = .{ .message = e.message } }),
                // v0.1 has nowhere to show a token count. The event exists so
                // the seam is complete; `/context` in v0.3 is what consumes it.
                .usage => {},
                .stop => break,
            }
        }

        self.send(.stream_end);
        self.send(.turn_end);
    }

    /// Cuts one delta into chunks a slot can hold, pacing each one.
    fn sendText(self: *Runner, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) {
            if (self.stop.load(.acquire)) return;

            const take = self.cadence.chunkLen(rest);
            if (take == 0) return;

            const delay = self.cadence.delayMs();
            if (delay > 0) self.io.sleep(.fromMilliseconds(delay), .awake) catch return;

            self.send(.{ .stream_delta = .{ .text = rest[0..take] } });
            rest = rest[take..];
        }
    }

    /// Pushes, retrying while the queue is full.
    ///
    /// Rings the waker either way — on a full queue the ring is the whole
    /// point, since it is what gets the loop draining again.
    fn send(self: *Runner, payload: proto.Payload) void {
        while (!self.stop.load(.acquire)) {
            self.queue.push(self.io, payload) catch |err| switch (err) {
                error.Full => {
                    self.waker.wake();
                    self.io.sleep(.fromMilliseconds(backpressure_ms), .awake) catch return;
                    continue;
                },
                // The cadence caps chunks below the slot size — there is a
                // comptime assertion on it — and every other payload here is a
                // fixed string. Dropping one beats panicking on a background
                // thread, where the panic handler cannot restore the terminal.
                error.PayloadTooLarge => return,
            };
            self.waker.wake();
            return;
        }
    }
};

const testing = std.testing;

fn testIo(threaded: *std.Io.Threaded) std.Io {
    threaded.* = .init_single_threaded;
    return threaded.io();
}

/// Drains until the runner has finished, accumulating every delta. Stands in
/// for the loop, which needs a terminal no portable test can produce.
fn collect(io: std.Io, q: *Queue, sink: *std.ArrayList(u8)) !void {
    var out: [queue_mod.max_payload_bytes]u8 = undefined;
    var done = false;
    while (!done) {
        while (q.pop(io, &out)) |payload| switch (payload) {
            .stream_delta => |d| try sink.appendSlice(testing.allocator, d.text),
            .turn_end => done = true,
            else => {},
        };
        if (!done) try io.sleep(.fromMilliseconds(1), .awake);
    }
}

test "every byte the mock produced arrives, in order" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(testing.allocator);
    {
        // What the mock says, with no cadence in the way.
        var reference: core.mock.Mock = .init(.{ .seed = 21, .units = 12 });
        while (reference.next()) |event| switch (event) {
            .text_delta => |bytes| try expected.appendSlice(testing.allocator, bytes),
            else => {},
        };
    }

    var m: core.mock.Mock = .init(.{ .seed = 21, .units = 12 });
    var q: Queue = .{};
    var waker: Waker = try .init();
    defer waker.deinit();
    var stop: std.atomic.Value(bool) = .init(false);
    var c: Cadence = .init(21, .instant, .none, 0);

    var runner: Runner = .{
        .io = io,
        .provider = m.provider(),
        .cadence = &c,
        .queue = &q,
        .waker = &waker,
        .stop = &stop,
    };
    const thread = try runner.spawn();

    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    try collect(io, &q, &got);
    thread.join();

    try testing.expectEqualStrings(expected.items, got.items);
}

test "an oversized delta is split rather than refused" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);

    // oversized_chunk is the one delta that cannot fit a slot, so it is the one
    // that proves the runner splits instead of dropping the push.
    var m: core.mock.Mock = .init(.{ .seed = 22, .units = 4, .fault = .oversized_chunk });
    var q: Queue = .{};
    var waker: Waker = try .init();
    defer waker.deinit();
    var stop: std.atomic.Value(bool) = .init(false);
    var c: Cadence = .init(22, .firehose, .oversized_chunk, 0);

    var runner: Runner = .{
        .io = io,
        .provider = m.provider(),
        .cadence = &c,
        .queue = &q,
        .waker = &waker,
        .stop = &stop,
    };
    const thread = try runner.spawn();

    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    try collect(io, &q, &got);
    thread.join();

    try testing.expect(got.items.len >= core.mock.max_delta_bytes);
}

test "an error event reaches the queue and the turn still ends" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);

    var m: core.mock.Mock = .init(.{ .seed = 23, .units = 6, .fault = .midstream_error });
    var q: Queue = .{};
    var waker: Waker = try .init();
    defer waker.deinit();
    var stop: std.atomic.Value(bool) = .init(false);
    var c: Cadence = .init(23, .instant, .midstream_error, 0);

    var runner: Runner = .{
        .io = io,
        .provider = m.provider(),
        .cadence = &c,
        .queue = &q,
        .waker = &waker,
        .stop = &stop,
    };
    const thread = try runner.spawn();

    var out: [queue_mod.max_payload_bytes]u8 = undefined;
    var saw_err = false;
    var saw_turn_end = false;
    while (!saw_turn_end) {
        while (q.pop(io, &out)) |payload| switch (payload) {
            .err => |e| {
                saw_err = true;
                try testing.expectEqualStrings("the provider hung up mid-stream", e.message);
            },
            .turn_end => saw_turn_end = true,
            else => {},
        };
        if (!saw_turn_end) try io.sleep(.fromMilliseconds(1), .awake);
    }
    thread.join();
    try testing.expect(saw_err);
}

test "setting the stop flag ends the thread before the response does" {
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);

    var m: core.mock.Mock = .init(.{ .seed = 24, .fault = .firehose });
    var q: Queue = .{};
    var waker: Waker = try .init();
    defer waker.deinit();
    var stop: std.atomic.Value(bool) = .init(false);
    var c: Cadence = .init(24, .firehose, .firehose, 0);

    var runner: Runner = .{
        .io = io,
        .provider = m.provider(),
        .cadence = &c,
        .queue = &q,
        .waker = &waker,
        .stop = &stop,
    };
    const thread = try runner.spawn();

    // Let it fill the queue and park on backpressure, then interrupt. The
    // runner has to notice while it is waiting on a full queue, not only
    // between events — a firehose is never between events for long.
    try io.sleep(.fromMilliseconds(20), .awake);
    stop.store(true, .release);
    thread.join();

    // And it stopped early: the whole firehose is megabytes, and 64 slots of
    // 512 bytes is 32 KiB.
    try testing.expect(q.len <= queue_mod.capacity);
}
