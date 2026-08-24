//! The cadence engine: how fast a response arrives, and where it is cut.
//!
//! The mock decides what is said; this decides how it is delivered. The split
//! is not tidiness — cadence needs a clock and a say in chunk boundaries, and
//! `tugcore` has neither. It is also the layer a real provider will *not* have:
//! v0.2's HTTP provider gets its cadence from the network, and this file is
//! what stands in for the network until then.
//!
//! Pure. No clock, no IO: `delayMs` returns a number of milliseconds and the
//! runner is what sleeps on it, which is what makes every case below testable
//! without a single real millisecond passing.

const std = @import("std");

const core = @import("tugcore");
const mock = core.mock;
const queue = @import("../loop/queue.zig");

/// The ordinary chunk range. Small enough that a wrapped paragraph arrives over
/// several frames — which is the thing worth watching for flicker — and capped
/// well under a queue slot so a chunk is never refused.
pub const min_chunk_bytes: usize = 8;
pub const max_chunk_bytes: usize = 64;

/// The ordinary delay range. Roughly a real provider's token rate: 4 ms is
/// faster than anything ships, 40 ms is a slow one under load.
pub const min_delay_ms: u32 = 4;
pub const max_delay_ms: u32 = 40;

/// Which chunk the stall lands on. Late enough that a block is open and partly
/// painted, early enough that the response is visibly unfinished.
const stall_at_chunk: u32 = 3;

comptime {
    // The runner pushes a chunk straight into a queue slot. If this ever stops
    // holding, the failure is a `PayloadTooLarge` in the middle of a stream
    // rather than a message here.
    std.debug.assert(max_chunk_bytes <= queue.max_payload_bytes);
}

pub const Preset = enum {
    normal,
    instant,
    firehose,

    pub fn parse(text: []const u8) ?Preset {
        return std.meta.stringToEnum(Preset, text);
    }
};

/// Faults that are *about* timing pick their own preset; the rest leave the
/// user's `--mock-cadence` alone.
pub fn presetFor(fault: mock.Fault, requested: Preset) Preset {
    return switch (fault) {
        .instant => .instant,
        .firehose => .firehose,
        else => requested,
    };
}

pub const Cadence = struct {
    preset: Preset,
    fault: mock.Fault,
    stall_ms: u32,
    prng: std.Random.DefaultPrng,
    chunks: u32 = 0,
    stalled: bool = false,

    pub fn init(seed: u64, preset: Preset, fault: mock.Fault, stall_ms: u32) Cadence {
        return .{
            .preset = preset,
            .fault = fault,
            .stall_ms = stall_ms,
            // A different stream from the mock's, so changing the cadence never
            // changes what is said. The constant is the golden-ratio mix Zig's
            // own hashers use; any fixed odd number would do.
            .prng = .init(seed ^ 0x9e37_79b9_7f4a_7c15),
        };
    }

    /// How many bytes of `remaining` belong in the next chunk.
    pub fn chunkLen(self: *Cadence, remaining: []const u8) usize {
        if (remaining.len == 0) return 0;
        if (self.fault == .split_utf8) {
            if (splitInsideCodepoint(remaining)) |cut| return cut;
        }
        return switch (self.preset) {
            // Not the whole remainder: a slot is the most the queue will take,
            // and `oversized_chunk` deliberately hands over more than that.
            .instant, .firehose => @min(remaining.len, queue.max_payload_bytes),
            .normal => @min(
                remaining.len,
                min_chunk_bytes + self.prng.random().uintLessThan(
                    usize,
                    max_chunk_bytes - min_chunk_bytes + 1,
                ),
            ),
        };
    }

    /// Milliseconds to wait before handing over the next chunk.
    pub fn delayMs(self: *Cadence) u32 {
        self.chunks += 1;
        if (self.fault == .stall and !self.stalled and self.chunks >= stall_at_chunk) {
            self.stalled = true;
            return self.stall_ms;
        }
        return switch (self.preset) {
            .instant, .firehose => 0,
            .normal => min_delay_ms +
                self.prng.random().uintLessThan(u32, max_delay_ms - min_delay_ms + 1),
        };
    }
};

/// A cut length that lands strictly inside the first multi-byte codepoint, or
/// null when there is none to land inside.
fn splitInsideCodepoint(bytes: []const u8) ?usize {
    var index: usize = 0;
    while (index < bytes.len) {
        const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch {
            index += 1;
            continue;
        };
        if (length > 1 and index + length <= bytes.len) return index + 1;
        index += length;
    }
    return null;
}

const testing = std.testing;

test "the normal preset cuts small chunks and waits between them" {
    var c: Cadence = .init(1, .normal, .none, 0);
    const text = "x" ** 1000;

    var chunks: usize = 0;
    var consumed: usize = 0;
    while (consumed < text.len) {
        const take = c.chunkLen(text[consumed..]);
        try testing.expect(take > 0);
        try testing.expect(take <= max_chunk_bytes);
        consumed += take;
        chunks += 1;
        try testing.expect(c.delayMs() <= max_delay_ms);
    }
    try testing.expect(chunks > 10);
}

test "instant and firehose hand over everything with no delay" {
    for ([_]Preset{ .instant, .firehose }) |preset| {
        var c: Cadence = .init(1, preset, .none, 0);
        // Under a slot's worth, so "everything" and "what a slot holds" are the
        // same answer. The next test covers what happens past that.
        const text = "x" ** 300;
        try testing.expectEqual(text.len, c.chunkLen(text));
        try testing.expectEqual(@as(u32, 0), c.delayMs());
    }
}

test "instant still stops at a slot boundary" {
    var c: Cadence = .init(1, .instant, .none, 0);
    const text = "x" ** 10_000;
    try testing.expectEqual(queue.max_payload_bytes, c.chunkLen(text));
}

test "a chunk never exceeds what a queue slot can hold" {
    // Not a cadence property for its own sake: the runner pushes chunks
    // straight into the queue, and a chunk past the slot size would be a
    // PayloadTooLarge in the middle of a stream rather than a failure here.
    var c: Cadence = .init(2, .normal, .none, 0);
    const text = "x" ** 10_000;
    var consumed: usize = 0;
    while (consumed < text.len) {
        const take = c.chunkLen(text[consumed..]);
        try testing.expect(take <= queue.max_payload_bytes);
        consumed += take;
    }
}

test "split_utf8 cuts inside a codepoint" {
    var c: Cadence = .init(3, .instant, .split_utf8, 0);
    const text = "ab日本語";
    const take = c.chunkLen(text);

    // The cut lands strictly inside the three bytes of 日, so the first chunk
    // is not valid UTF-8 on its own and the renderer's completePrefix has to
    // hold the fragment back.
    try testing.expect(take > 2);
    try testing.expect(!std.unicode.utf8ValidateSlice(text[0..take]));
    try testing.expect(std.unicode.utf8ValidateSlice(text));
}

test "split_utf8 falls back to the preset when there is nothing to split" {
    var c: Cadence = .init(3, .instant, .split_utf8, 0);
    const ascii = "plain ascii only";
    try testing.expectEqual(ascii.len, c.chunkLen(ascii));
}

test "stall pauses once, mid-stream, and then behaves" {
    var c: Cadence = .init(4, .instant, .stall, 1500);
    var stalls: usize = 0;
    for (0..20) |_| {
        if (c.delayMs() >= 1500) stalls += 1;
    }
    try testing.expectEqual(@as(usize, 1), stalls);
}

test "the fault picks the preset when it has an opinion" {
    try testing.expectEqual(Preset.instant, presetFor(.instant, .normal));
    try testing.expectEqual(Preset.firehose, presetFor(.firehose, .normal));
    try testing.expectEqual(Preset.normal, presetFor(.midstream_error, .normal));
    // An explicit --mock-cadence still wins for faults with no timing opinion.
    try testing.expectEqual(Preset.instant, presetFor(.split_utf8, .instant));
}

test "the same seed gives the same chunk sequence" {
    const text = "x" ** 500;
    var first: Cadence = .init(11, .normal, .none, 0);
    var second: Cadence = .init(11, .normal, .none, 0);
    for (0..20) |_| {
        try testing.expectEqual(first.chunkLen(text), second.chunkLen(text));
        try testing.expectEqual(first.delayMs(), second.delayMs());
    }
}

test "preset names round-trip and unknown ones are rejected" {
    try testing.expectEqual(Preset.firehose, Preset.parse("firehose").?);
    try testing.expect(Preset.parse("glacial") == null);
}
