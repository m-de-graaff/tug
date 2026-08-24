//! The firehose proof.
//!
//! Half a second of a real provider thread pushing as fast as the queue will
//! take it, against a consumer that paints only when the scheduler says to. The
//! number that matters is writes per second, and the budget is the frame
//! interval: 8 ms, so 125.
//!
//! `Scheduler` already has a unit test for the coalescing arithmetic. What that
//! test cannot cover is whether a *thread* defeats it, which is a race rather
//! than arithmetic — so this one uses a real clock and real wall time.
//!
//! It does not drive `Loop.run`, which needs a terminal file descriptor no
//! portable test can produce. It uses the same four pieces the loop uses, in
//! the same order: drain the queue, mark the scheduler, paint when due. The
//! loop's own body is covered by `scripts/mock-modes.sh`, on a pty.

const std = @import("std");
const testing = std.testing;

const core = @import("tugcore");

const Counting = @import("../render/counting_writer.zig").Counting;
const renderer_mod = @import("../render/renderer.zig");
const cadence_mod = @import("cadence.zig");
const queue_mod = @import("../loop/queue.zig");
const runner_mod = @import("runner.zig");
const waiting = @import("../loop/wait.zig");

const run_ms: u64 = 500;

/// The roadmap's number, verbatim: 125 writes a second, plus three frames of
/// slack for clock granularity at either end of the window.
///
/// Deliberately not padded further. `scheduler.due` enforces 8 ms between
/// paints by construction, so a correct consumer *cannot* legitimately exceed
/// this — and a generous budget here would be a test that passes whatever
/// happens. Measured on the WSL box at 37 writes in 512 ms (Debug) and 34 in
/// 502 ms (ReleaseSafe), against a budget of 66; painting on every drain
/// instead of on the scheduler's say-so gives 85, which fails.
fn frameBudget(elapsed_ms: u64) usize {
    return @intCast(3 + (elapsed_ms * 125) / 1000);
}

test "a firehose still paints at the frame budget" {
    const gpa = testing.allocator;

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var mock: core.mock.Mock = .init(.{ .seed = 31, .fault = .firehose });
    var cadence: cadence_mod.Cadence = .init(31, .firehose, .firehose, 0);
    var queue: queue_mod.Queue = .{};
    var waker: waiting.Waker = try .init();
    defer waker.deinit();
    var stop: std.atomic.Value(bool) = .init(false);

    var runner: runner_mod.Runner = .{
        .io = io,
        .provider = mock.provider(),
        .cadence = &cadence,
        .queue = &queue,
        .waker = &waker,
        .stop = &stop,
    };
    const thread = try runner.spawn();
    defer {
        stop.store(true, .release);
        thread.join();
    }

    const caps: renderer_mod.Capabilities = .{
        .color = .none,
        .kitty_keyboard = false,
        .synchronized_output = false,
        .bracketed_paste = true,
        .size = .{ .cols = 80, .rows = 24 },
    };
    var renderer: renderer_mod.Renderer = .init(gpa, caps, caps.size);
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);

    var scheduler: core.Scheduler = .{};
    var buffer: [256 * 1024]u8 = undefined;
    var sink: [1024 * 1024]u8 = undefined;
    var counting: Counting = .init(&buffer, &sink);

    var out: [queue_mod.max_payload_bytes]u8 = undefined;
    const start = waiting.nowMs(io);
    var bytes_seen: usize = 0;

    while (true) {
        const now = waiting.nowMs(io);
        if (now - start >= run_ms) break;

        while (queue.pop(io, &out)) |payload| switch (payload) {
            .stream_delta => |delta| {
                try renderer.feed(delta.text);
                bytes_seen += delta.text.len;
                scheduler.markDirty();
            },
            else => scheduler.markUrgent(),
        };

        if (scheduler.due(now)) {
            // The sink is rewound every frame: this measures write *count*, and
            // retaining a megabyte of frames would measure nothing but memory.
            counting.len = 0;
            _ = try renderer.paint(&counting.writer);
            try counting.writer.flush();
            scheduler.painted(now);
        }
    }

    const elapsed = waiting.nowMs(io) - start;

    // The firehose has to have actually been a firehose, or the frame count
    // proves nothing: a producer that never started also paints very little.
    try testing.expect(bytes_seen > 256 * 1024);
    try testing.expect(counting.writes <= frameBudget(elapsed));
}
