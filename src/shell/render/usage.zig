//! The one dim line at the end of a turn.
//!
//! Tokens in and out, the cached share, the cost, how long it took, and which
//! model. Pure formatting: the caller owns the buffer and the renderer applies
//! the dim styling, which is what lets every case here be a string comparison
//! rather than a terminal transcript.
//!
//! Two rules come from reading how `pi` — the TypeScript predecessor this
//! project ports the philosophy of — handles the same line, and both are about
//! not claiming things:
//!
//! 1. **A cached share below the noise floor is not shown.** Cache breakpoints
//!    have granularity, and a handful of tokens either way is that granularity
//!    rather than a result. pi puts the floor at 1024 and so does this.
//! 2. **Zero cached tokens from a provider that does not report caching is not
//!    a cache miss.** Ollama reports nothing; Anthropic reporting zero means it
//!    missed. `Usage` has no "unknown" by design (`DR-022`), so the caller
//!    passes `reports_cache` and this file refuses to draw a conclusion the
//!    numbers do not support.

const std = @import("std");

const proto = @import("tugproto");

/// Below this, a cached count is cache-breakpoint granularity rather than a
/// result worth a user's attention.
pub const cache_noise_floor: u32 = 1024;

pub const Line = struct {
    usage: proto.Usage,
    model_id: []const u8,
    /// False when nothing knows this model's price. The cost is then omitted
    /// rather than printed as zero — see `tugcore.models`.
    priced: bool = false,
    /// Dollars, already computed by the caller from usage and price.
    cost: f64 = 0,
    elapsed_ms: u64 = 0,
    /// Whether this provider reports cache activity at all. See rule 2 above.
    reports_cache: bool = true,
};

/// Writes the line, without styling and without a trailing newline.
pub fn write(line: Line, out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.print("{d} in, {d} out", .{ line.usage.input_tokens, line.usage.output_tokens });

    if (showCache(line)) {
        try out.print(", {d} cached", .{line.usage.cache_read_tokens});
    }

    if (line.priced) {
        try out.writeAll(", ");
        try writeCost(line.cost, out);
    }

    try out.writeAll(", ");
    try writeElapsed(line.elapsed_ms, out);

    try out.print(", {s}", .{line.model_id});
}

fn showCache(line: Line) bool {
    if (!line.reports_cache) return false;
    return line.usage.cache_read_tokens >= cache_noise_floor;
}

/// Money, at a resolution that does not lie in either direction.
///
/// A real cost under a cent rendered as `$0.00` reads as free, and the whole
/// point of the line is that it is not. Below a cent it becomes a fraction of
/// one; below a hundredth of a cent it becomes `<$0.0001`, because at that
/// point more digits are noise.
fn writeCost(cost: f64, out: *std.Io.Writer) std.Io.Writer.Error!void {
    if (cost <= 0) return out.writeAll("$0");
    if (cost < 0.0001) return out.writeAll("<$0.0001");
    if (cost < 0.01) return out.print("${d:.4}", .{cost});
    return out.print("${d:.2}", .{cost});
}

/// Elapsed time, at one useful digit.
///
/// Milliseconds under a second, because a 400 ms turn reported as `0.4 s` reads
/// slower than it was; seconds above, because nobody counts in thousands.
fn writeElapsed(ms: u64, out: *std.Io.Writer) std.Io.Writer.Error!void {
    if (ms < 1000) return out.print("{d} ms", .{ms});

    const seconds = @as(f64, @floatFromInt(ms)) / 1000.0;
    if (seconds < 60) return out.print("{d:.1} s", .{seconds});

    const minutes = @divTrunc(ms, 60_000);
    const rest = @divTrunc(ms - minutes * 60_000, 1000);
    return out.print("{d}m{d:0>2}s", .{ minutes, rest });
}

const testing = std.testing;

fn render(buffer: []u8, line: Line) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try write(line, &writer);
    return writer.buffered();
}

test "the line has tokens, cost, elapsed and model" {
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "24 in, 317 out, $0.01, 2.4 s, claude-sonnet-4-5",
        try render(&buffer, .{
            .usage = .{ .input_tokens = 24, .output_tokens = 317 },
            .model_id = "claude-sonnet-4-5",
            .priced = true,
            .cost = 0.0125,
            .elapsed_ms = 2_400,
        }),
    );
}

test "a cached share above the noise floor is shown" {
    var buffer: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "24 in, 317 out, 12000 cached, $0.01, 2.4 s, claude-sonnet-4-5",
        try render(&buffer, .{
            .usage = .{ .input_tokens = 24, .output_tokens = 317, .cache_read_tokens = 12_000 },
            .model_id = "claude-sonnet-4-5",
            .priced = true,
            .cost = 0.0125,
            .elapsed_ms = 2_400,
        }),
    );
}

test "a cached share below the noise floor is not shown" {
    // Cache breakpoints have granularity. A few hundred tokens either way is
    // that granularity, not a result — the rule `pi` arrived at first.
    var buffer: [256]u8 = undefined;
    const rendered = try render(&buffer, .{
        .usage = .{ .input_tokens = 24, .output_tokens = 10, .cache_read_tokens = 900 },
        .model_id = "m",
        .elapsed_ms = 100,
    });
    try testing.expect(std.mem.indexOf(u8, rendered, "cached") == null);
}

test "a provider that does not report caching is not reported as missing it" {
    // Zero cached tokens from Ollama means "does not report"; zero from
    // Anthropic means "missed". `Usage` has no third state by design, so the
    // caller says which and this file refuses to draw the conclusion.
    var buffer: [256]u8 = undefined;
    const rendered = try render(&buffer, .{
        .usage = .{ .input_tokens = 24, .output_tokens = 10, .cache_read_tokens = 50_000 },
        .model_id = "llama3.1",
        .reports_cache = false,
        .elapsed_ms = 100,
    });
    try testing.expect(std.mem.indexOf(u8, rendered, "cached") == null);
}

test "an unpriced model renders tokens and omits the cost" {
    // No guessing. A number that might be wrong by an order of magnitude is
    // worse than no number.
    var buffer: [256]u8 = undefined;
    const rendered = try render(&buffer, .{
        .usage = .{ .input_tokens = 24, .output_tokens = 317 },
        .model_id = "llama3.1",
        .priced = false,
        .elapsed_ms = 2_400,
    });

    try testing.expect(std.mem.indexOf(u8, rendered, "$") == null);
    try testing.expectEqualStrings("24 in, 317 out, 2.4 s, llama3.1", rendered);
}

test "a real cost under a cent is not rendered as zero" {
    // $0.00 for a real cost reads as free, and the point of the line is that it
    // is not.
    var buffer: [256]u8 = undefined;
    const rendered = try render(&buffer, .{
        .usage = .{ .input_tokens = 10, .output_tokens = 4 },
        .model_id = "m",
        .priced = true,
        .cost = 0.0007,
        .elapsed_ms = 300,
    });
    try testing.expect(std.mem.indexOf(u8, rendered, "$0.0007") != null);
}

test "a cost too small to write is said to be too small rather than rounded away" {
    var buffer: [256]u8 = undefined;
    const rendered = try render(&buffer, .{
        .usage = .{ .input_tokens = 1 },
        .model_id = "m",
        .priced = true,
        .cost = 0.000_002,
        .elapsed_ms = 10,
    });
    try testing.expect(std.mem.indexOf(u8, rendered, "<$0.0001") != null);
}

test "a genuinely free turn is zero rather than an approximation of zero" {
    var buffer: [256]u8 = undefined;
    const rendered = try render(&buffer, .{
        .usage = .{},
        .model_id = "m",
        .priced = true,
        .cost = 0,
        .elapsed_ms = 10,
    });
    try testing.expect(std.mem.indexOf(u8, rendered, "$0,") != null);
}

test "elapsed is milliseconds under a second and seconds above it" {
    var buffer: [256]u8 = undefined;

    const fast = try render(&buffer, .{ .usage = .{}, .model_id = "m", .elapsed_ms = 412 });
    try testing.expect(std.mem.indexOf(u8, fast, "412 ms") != null);

    var second: [256]u8 = undefined;
    const slow = try render(&second, .{ .usage = .{}, .model_id = "m", .elapsed_ms = 2_450 });
    try testing.expect(std.mem.indexOf(u8, slow, "2.5 s") != null);
}

test "a long turn is minutes and seconds rather than a large number of seconds" {
    var buffer: [256]u8 = undefined;
    const rendered = try render(&buffer, .{ .usage = .{}, .model_id = "m", .elapsed_ms = 185_000 });
    try testing.expect(std.mem.indexOf(u8, rendered, "3m05s") != null);
}

test "the line fits a narrow terminal in the ordinary case" {
    // Not a hard constraint — the renderer wraps — but a line that always wraps
    // is a line nobody reads, and this is the case that has to fit.
    var buffer: [256]u8 = undefined;
    const rendered = try render(&buffer, .{
        .usage = .{ .input_tokens = 1_240, .output_tokens = 317, .cache_read_tokens = 12_000 },
        .model_id = "claude-sonnet-4-5",
        .priced = true,
        .cost = 0.0125,
        .elapsed_ms = 2_400,
    });
    try testing.expect(rendered.len <= 80);
}
