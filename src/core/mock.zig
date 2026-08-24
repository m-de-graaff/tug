//! The mock provider: a seeded generator of markdown-rich responses.
//!
//! Deterministic to the byte. The same seed produces the same response on every
//! platform and in every optimize mode, because the only source of variety is a
//! Xoshiro256 draw over a fixed corpus — no clock, no allocator, no hash order.
//! That is what makes it usable as the input side of a golden test.
//!
//! It decides *what* is said, and emits whole logical units. It has no opinion
//! about how fast they arrive or where they are cut, because both need a clock
//! and this module compiles for `wasm32-freestanding`. Timing lives one layer
//! out, in `tugshell/provider/cadence.zig`.

const std = @import("std");

const proto = @import("tugproto");
const Provider = @import("provider.zig").Provider;

/// The largest single `text_delta`. Sized by `oversized_chunk`, which exists to
/// be far larger than the queue's 512-byte slot so the runner has to split it
/// and then feel the backpressure — 8 KiB is sixteen slots' worth.
pub const max_delta_bytes: usize = 8 * 1024;

/// How many units `firehose` emits. Large enough that the response is measured
/// in megabytes rather than kilobytes, which is what makes the frame-rate proof
/// mean anything.
///
/// ponytail: tuned by measurement, not derivation — `scripts/mock-modes.sh`
/// wants a run of at least a second or two. If a faster machine finishes
/// sooner, raise this rather than lowering the assertion.
pub const firehose_units: u16 = 20_000;

/// The named fault modes.
///
/// Two of them are honoured here and the rest in the cadence engine, because a
/// fault about *timing* or *chunk boundaries* cannot be expressed by a module
/// with no clock and no say in chunking. The enum is shared so the flag stays
/// one flag.
pub const Fault = enum {
    none,
    /// Cadence: pauses mid-stream.
    stall,
    /// Core: gives up halfway through.
    midstream_error,
    /// Core: one absurdly large delta.
    oversized_chunk,
    /// Cadence: cuts a chunk inside a codepoint.
    split_utf8,
    /// Cadence: no delay at all.
    instant,
    /// Core and cadence: no delay, and megabytes of it.
    firehose,
    /// Core: a response with no text in it.
    empty,

    pub fn parse(text: []const u8) ?Fault {
        return std.meta.stringToEnum(Fault, text);
    }
};

pub const Config = struct {
    seed: u64 = 0,
    fault: Fault = .none,
    /// Logical units before the stream ends. `firehose` overrides it.
    units: u16 = 8,
    stall_ms: u32 = 1500,
};

const Unit = enum { heading, paragraph, bullets, ordered, fence, wide };

/// Sentence fragments, drawn from by index. Fixed content on purpose: a corpus
/// that changed would change every golden in the repo.
const sentences = [_][]const u8{
    "A tugboat's power is rated in **bollard pull**, and the number is absurd for its size.",
    "One static binary, no runtime, no telemetry, and a budget that CI enforces.",
    "The core is a *freestanding library*; the CLI is merely its first frontend.",
    "Every token the harness injects into a context is a cost somebody pays.",
    "Anything measurable gets a budget, and budgets are enforced by CI rather than by intentions.",
    "If a feature can be a plugin then it is a plugin, and the bar for core is that the harness is broken without it.",
};

const headings = [_][]const u8{ "Bollard pull", "Budgets", "The seam", "What ships" };

const items = [_][]const u8{
    "a shell, a loop, two providers, four tools",
    "one write per frame, and the row count exact",
    "wrap to the terminal width, never to a guess",
    "repaint the tail, never the scrollback",
};

const fence_body =
    \\```zig
    \\pub fn main() !void {
    \\    // **not bold** inside a fence
    \\    std.debug.print("ship it\n", .{});
    \\}
    \\```
;

const wide_text = "日本語のテキストも折り返します。 🚢 And back to *ASCII* again.";

/// Where the generator is in the fixed tail of every response.
const Phase = enum { text, usage, stop, done };

pub const Mock = struct {
    config: Config,
    prng: std.Random.DefaultPrng,
    buffer: [max_delta_bytes]u8 = undefined,
    emitted: u16 = 0,
    bytes_out: u32 = 0,
    phase: Phase = .text,

    pub fn init(config: Config) Mock {
        return .{ .config = config, .prng = .init(config.seed) };
    }

    pub fn provider(self: *Mock) Provider {
        return .{ .context = self, .next = nextErased };
    }

    fn nextErased(context: ?*anyopaque) ?proto.StreamEvent {
        const self: *Mock = @ptrCast(@alignCast(context.?));
        return self.next();
    }

    fn totalUnits(self: *const Mock) u16 {
        return switch (self.config.fault) {
            .firehose => firehose_units,
            .empty => 0,
            else => self.config.units,
        };
    }

    pub fn next(self: *Mock) ?proto.StreamEvent {
        switch (self.phase) {
            .text => {
                if (self.emitted >= self.totalUnits()) {
                    self.phase = .usage;
                    return self.next();
                }
                const text = self.renderUnit();
                self.emitted += 1;
                self.bytes_out += @intCast(text.len);
                return .{ .text_delta = text };
            },
            .usage => {
                self.phase = .stop;
                // Four bytes to a token is the estimate every provider reaches
                // for when it has nothing better, and v0.1 has nothing better.
                return .{ .usage = .{
                    .input_tokens = 12,
                    .output_tokens = @max(1, self.bytes_out / 4),
                } };
            },
            .stop => {
                self.phase = .done;
                return .{ .stop = .{ .reason = .end_turn } };
            },
            .done => return null,
        }
    }

    /// Writes one unit into the mock's own buffer and returns it. The slice is
    /// valid until the next call, which is exactly the borrow `StreamEvent`
    /// documents.
    fn renderUnit(self: *Mock) []const u8 {
        return self.buffer[0..self.renderUnitInto(&self.buffer)];
    }

    /// One unit into an arbitrary slice, or 0 when it would not fit whole. A
    /// half-written unit is never returned: `renderOversized` packs units back
    /// to back and needs to know where to stop.
    fn renderUnitInto(self: *Mock, into: []u8) usize {
        var writer: std.Io.Writer = .fixed(into);
        self.writeUnit(&writer) catch return 0;
        return writer.buffered().len;
    }

    fn writeUnit(self: *Mock, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const random = self.prng.random();
        const unit: Unit = @enumFromInt(
            random.uintLessThan(usize, @typeInfo(Unit).@"enum".fields.len),
        );
        switch (unit) {
            .heading => try writer.print("# {s}\n\n", .{pick(random, &headings)}),
            .paragraph => try writer.print("{s}\n{s}\n\n", .{
                pick(random, &sentences),
                pick(random, &sentences),
            }),
            .bullets => {
                for (0..3) |_| try writer.print("- {s}\n", .{pick(random, &items)});
                try writer.writeAll("\n");
            },
            .ordered => {
                for (1..4) |n| try writer.print("{d}. {s}\n", .{ n, pick(random, &items) });
                try writer.writeAll("\n");
            },
            .fence => try writer.print("{s}\n\n", .{fence_body}),
            .wide => try writer.print("{s}\n\n", .{wide_text}),
        }
    }
};

fn pick(random: std.Random, table: []const []const u8) []const u8 {
    return table[random.uintLessThan(usize, table.len)];
}

const testing = std.testing;

/// Drains a mock into a buffer, so a test can assert on the whole response
/// rather than on one delta at a time.
fn drain(config: Config, sink: []u8) ![]const u8 {
    var m: Mock = .init(config);
    var len: usize = 0;
    while (m.next()) |event| switch (event) {
        .text_delta => |bytes| {
            if (len + bytes.len > sink.len) return error.SinkTooSmall;
            @memcpy(sink[len..][0..bytes.len], bytes);
            len += bytes.len;
        },
        else => {},
    };
    return sink[0..len];
}

test "the same seed produces the same bytes, twice" {
    var first: [64 * 1024]u8 = undefined;
    var second: [64 * 1024]u8 = undefined;
    const a = try drain(.{ .seed = 7 }, &first);
    const b = try drain(.{ .seed = 7 }, &second);
    try testing.expectEqualStrings(a, b);
    try testing.expect(a.len > 0);
}

test "different seeds produce different bytes" {
    var first: [64 * 1024]u8 = undefined;
    var second: [64 * 1024]u8 = undefined;
    const a = try drain(.{ .seed = 7 }, &first);
    const b = try drain(.{ .seed = 8 }, &second);
    try testing.expect(!std.mem.eql(u8, a, b));
}

test "a response exercises every width path the renderer has" {
    // Not decoration: CJK is two cells wide, the emoji is two cells and four
    // bytes, and the fence is the one classification that suppresses inline
    // markers. A mock that only emitted ASCII paragraphs would be a renderer
    // test that never fails.
    var sink: [64 * 1024]u8 = undefined;
    const text = try drain(.{ .seed = 3, .units = 64 }, &sink);
    for ([_][]const u8{ "# ", "- ", "1. ", "```", "**", "日", "🚢" }) |needle| {
        if (std.mem.indexOf(u8, text, needle) == null) {
            std.debug.print("missing from the mock corpus: {s}\n", .{needle});
            return error.CorpusIncomplete;
        }
    }
}

test "a clean stream ends with usage and then a stop" {
    var m: Mock = .init(.{ .seed = 1, .units = 2 });
    var last: ?proto.StreamEvent = null;
    var second_last: ?proto.StreamEvent = null;
    while (m.next()) |event| {
        second_last = last;
        last = event;
    }
    try testing.expectEqual(proto.StopReason.end_turn, last.?.stop.reason);
    try testing.expect(second_last.?.usage.output_tokens > 0);
}

test "fault names round-trip and unknown ones are rejected" {
    try testing.expectEqual(Fault.midstream_error, Fault.parse("midstream_error").?);
    try testing.expectEqual(Fault.firehose, Fault.parse("firehose").?);
    try testing.expect(Fault.parse("explode") == null);
}
