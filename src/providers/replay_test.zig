//! The replay proof: every fixture, through the whole stack, byte for byte.
//!
//! `.artifacts/ROADMAP.md` § v0.2 states the exit criterion as *CI fully
//! offline: recorded SSE fixtures replay byte-for-byte*. This file is that
//! sentence as a test, and `zig build replay` is that sentence as a job name.
//!
//! Each case is four files sharing a stem: `.head` and `.sse` are what went in,
//! `.ndjson` is what has to come out, and `.toml` says where the bytes came
//! from. The assertion is on the ndjson because that is the vocabulary — the
//! same bytes `--json` prints in Phase 8 and a plugin speaks in v0.5 — so a
//! change to the wire format fails here first and loudly.
//!
//! Every case runs at five chunk sizes, including one byte at a time. A read
//! boundary must be invisible above the transport seam, and the sizes a network
//! actually produces are not the sizes that find that bug.

const std = @import("std");

const proto = @import("tugproto");

const anthropic_map = @import("anthropic_map.zig");
const fixture = @import("fixture.zig");
const openai = @import("openai.zig");
const sse = @import("sse.zig");
const stream_mod = @import("stream.zig");

const Shape = enum { anthropic, openai };

const Case = struct {
    name: []const u8,
    shape: Shape,
    head: []const u8,
    body: []const u8,
    expected: []const u8,
};

/// Grows in Phase 9, when `tug dev record` replaces these bodies with real
/// captures. The layout does not change when it does — that is what the layout
/// was designed for.
const corpus = [_]Case{
    .{
        .name = "anthropic/clean-turn",
        .shape = .anthropic,
        .head = @embedFile("clean-turn.head"),
        .body = @embedFile("clean-turn.sse"),
        .expected = @embedFile("clean-turn.ndjson"),
    },
    .{
        .name = "anthropic/error-401",
        .shape = .anthropic,
        .head = @embedFile("error-401.head"),
        .body = @embedFile("error-401.sse"),
        .expected = @embedFile("error-401.ndjson"),
    },
    .{
        .name = "openai/clean-turn",
        .shape = .openai,
        .head = @embedFile("openai-clean-turn.head"),
        .body = @embedFile("openai-clean-turn.sse"),
        .expected = @embedFile("openai-clean-turn.ndjson"),
    },
    .{
        .name = "openai/usage-absent",
        .shape = .openai,
        .head = @embedFile("openai-usage-absent.head"),
        .body = @embedFile("openai-usage-absent.sse"),
        .expected = @embedFile("openai-usage-absent.ndjson"),
    },
    .{
        .name = "openai/error-404-model",
        .shape = .openai,
        .head = @embedFile("openai-error-404-model.head"),
        .body = @embedFile("openai-error-404-model.sse"),
        .expected = @embedFile("openai-error-404-model.ndjson"),
    },
};

/// The chunk sizes every case is replayed at.
///
/// One byte at a time is the important one and the slowest; 4096 is larger than
/// any fixture, so it is the whole-response case. The primes in between land
/// read boundaries inside field names, inside JSON strings, and between the two
/// bytes of a CRLF.
const chunk_sizes = [_]usize{ 1, 3, 13, 512, 4096 };

fn replay(gpa: std.mem.Allocator, case: Case, chunk: usize) ![]u8 {
    var f: fixture.Fixture = .{
        .head = try fixture.parseHead(case.head),
        .body = case.body,
        .chunk = chunk,
    };

    var anthropic_state: anthropic_map.Anthropic = .init(gpa);
    defer anthropic_state.deinit();
    var openai_state: openai.OpenAi = .init(gpa);
    defer openai_state.deinit();

    const mapper = switch (case.shape) {
        .anthropic => anthropic_state.mapper(),
        .openai => openai_state.mapper(),
    };

    var scratch: [sse.recommended_scratch]u8 = undefined;
    var data: [sse.recommended_data]u8 = undefined;
    var parser: sse.Parser = .init(&scratch, &data);
    var read_buffer: [256]u8 = undefined;

    var s: stream_mod.Stream = .init(
        f.transport(),
        .{ .url = "https://example.invalid/v1/messages" },
        &parser,
        mapper,
        &read_buffer,
    );

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();

    const p = s.provider();
    while (p.nextEvent()) |event| try proto.ndjson.writeEvent(event, &out.writer);

    return out.toOwnedSlice();
}

const testing = std.testing;

test "replay: every fixture emits exactly the events its ndjson names" {
    for (corpus) |case| {
        const got = try replay(testing.allocator, case, 13);
        defer testing.allocator.free(got);

        testing.expectEqualStrings(case.expected, got) catch |err| {
            std.debug.print("replay: {s} did not match its ndjson\n", .{case.name});
            return err;
        };
    }
}

test "replay: a read boundary is invisible at every chunk size" {
    for (corpus) |case| {
        for (chunk_sizes) |chunk| {
            const got = try replay(testing.allocator, case, chunk);
            defer testing.allocator.free(got);

            testing.expectEqualStrings(case.expected, got) catch |err| {
                std.debug.print(
                    "replay: {s} differs when read {d} bytes at a time\n",
                    .{ case.name, chunk },
                );
                return err;
            };
        }
    }
}

test "replay: the corpus covers both shapes and both outcomes" {
    // A corpus that quietly lost its error cases would still pass every
    // assertion above. This is the test that notices.
    var anthropic_cases: usize = 0;
    var openai_cases: usize = 0;
    var error_cases: usize = 0;

    for (corpus) |case| {
        switch (case.shape) {
            .anthropic => anthropic_cases += 1,
            .openai => openai_cases += 1,
        }
        if (std.mem.indexOf(u8, case.expected, "\"error\"") != null) error_cases += 1;
    }

    try testing.expect(anthropic_cases >= 2);
    try testing.expect(openai_cases >= 3);
    try testing.expect(error_cases >= 2);
}
