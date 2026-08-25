//! One golden transcript per fault mode.
//!
//! The mock and the cadence engine are both pure, and the renderer is a pure
//! function of what it is fed, so a fault mode's whole observable behaviour is a
//! byte string — reviewable, and identical on every platform. That is why these
//! run in process rather than through a pty: the bytes are the same either way,
//! and a pty capture depends on `TERM`, the window size and the capability
//! probe's timing, none of which belong in an assertion.
//!
//! `scripts/mock-modes.sh` covers what only a pty can: that the flags reach the
//! code, that the process exits on its own, and that the loop's own body
//! survives each mode.
//!
//! No thread and no sleeping. `delayMs` is called and its answer discarded,
//! which is exactly what makes the transcript deterministic while still driving
//! the same code path a real run would.

const std = @import("std");
const testing = std.testing;

const core = @import("tugcore");

const Counting = @import("../render/counting_writer.zig").Counting;
const renderer_mod = @import("../render/renderer.zig");
const transcript = @import("../render/transcript.zig");
const cadence_mod = @import("cadence.zig");

const plain_caps: renderer_mod.Capabilities = .{
    .color = .none,
    .kitty_keyboard = false,
    .synchronized_output = false,
    .bracketed_paste = true,
    .size = .{ .cols = 40, .rows = 12 },
};

/// Chunks between paints. A paint per chunk would make every golden enormous
/// and would be testing the renderer's frame code rather than the fault's
/// behaviour; four is enough that a stall or an error lands mid-frame at least
/// once.
const paint_every: usize = 4;

/// What `oversized_chunk` uses instead: paint once, at the end.
///
/// Its delta is 8 KiB on its own, and painting through it every four chunks
/// produces a thousand lines of transcript — which nobody reviews, and an
/// unreviewed golden records whatever the code did last. One frame is enough to
/// record what the fault is actually claimed to do: the delta arrives whole and
/// the tail still adds up.
const paint_at_end: usize = std.math.maxInt(usize);

fn paintInto(
    renderer: *renderer_mod.Renderer,
    frames: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
) !void {
    var buffer: [256 * 1024]u8 = undefined;
    var sink: [256 * 1024]u8 = undefined;
    var counting: Counting = .init(&buffer, &sink);

    _ = try renderer.paint(&counting.writer);
    try counting.writer.flush();
    // Every golden is also a one-write-per-frame assertion, for free.
    try testing.expect(counting.writes <= 1);
    try frames.appendSlice(gpa, counting.bytes());
}

/// Runs one fault mode end to end and compares the frames against its golden.
fn run(
    name: []const u8,
    config: core.mock.Config,
    preset: cadence_mod.Preset,
    every: usize,
) !void {
    const gpa = testing.allocator;

    var mock: core.mock.Mock = .init(config);
    var cadence: cadence_mod.Cadence = .init(
        config.seed,
        cadence_mod.presetFor(config.fault, preset),
        config.fault,
        config.stall_ms,
    );

    var renderer: renderer_mod.Renderer = .init(gpa, plain_caps, plain_caps.size);
    defer renderer.deinit();

    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(gpa);

    var since_paint: usize = 0;
    try renderer.beginBlock(.assistant);
    while (mock.next()) |event| switch (event) {
        .text_delta => |bytes| {
            var rest = bytes;
            while (rest.len > 0) {
                const take = cadence.chunkLen(rest);
                _ = cadence.delayMs();
                try renderer.feed(rest[0..take]);
                rest = rest[take..];
                since_paint += 1;
                if (since_paint >= every) {
                    since_paint = 0;
                    try paintInto(&renderer, &frames, gpa);
                }
            }
        },
        .err => |failure| {
            // A notice block, which commits the partial assistant block above
            // it — the same thing `MockSession.apply` does in the binary.
            try renderer.beginBlock(.notice);
            try renderer.feed(failure.message);
            try renderer.feed("\n");
        },
        // The mock emits neither, and a golden that rendered a tool call would
        // be pinning bytes nothing produces. Phase 7 renders the real notice.
        .tool_call_delta, .usage, .stop => {},
    };
    try renderer.endBlock();
    try paintInto(&renderer, &frames, gpa);

    try transcript.expectGolden(gpa, name, frames.items);
}

test "golden: a clean mock response" {
    try run("mock-none", .{ .seed = 1, .units = 4 }, .normal, paint_every);
}

test "golden: stall" {
    // The pause is a number `delayMs` returned and nobody slept on, so what
    // this records is the screen either side of it.
    try run("mock-stall", .{ .seed = 1, .units = 4, .fault = .stall }, .normal, paint_every);
}

test "golden: midstream_error commits the partial block and adds a notice" {
    try run("mock-midstream-error", .{ .seed = 1, .units = 6, .fault = .midstream_error }, .normal, paint_every);
}

test "golden: oversized_chunk" {
    try run("mock-oversized-chunk", .{ .seed = 1, .units = 2, .fault = .oversized_chunk }, .normal, paint_at_end);
}

test "golden: split_utf8" {
    try run("mock-split-utf8", .{ .seed = 2, .units = 4, .fault = .split_utf8 }, .normal, paint_every);
}

test "golden: instant" {
    try run("mock-instant", .{ .seed = 1, .units = 4, .fault = .instant }, .normal, paint_every);
}

test "golden: firehose" {
    // `.fault = .firehose` would pull in `firehose_units` and produce a golden
    // measured in megabytes, which is not a thing anyone reviews. The core half
    // of that fault is *volume*, and volume is what the firehose frame-budget
    // test proves; what a golden can record is the cadence half — whole-slot
    // chunks with no delay — so drive that directly.
    try run("mock-firehose", .{ .seed = 1, .units = 3 }, .firehose, paint_every);
}

test "golden: empty" {
    try run("mock-empty", .{ .seed = 1, .fault = .empty }, .normal, paint_every);
}
