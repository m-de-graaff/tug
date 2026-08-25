//! The ndjson encoding of a stream event.
//!
//! One line per event, `\n`-terminated, no pretty printing, keys in a fixed
//! order. These exact bytes are what `tug -p --json` prints (Phase 8) and what a
//! plugin sends over stdio (v0.5), which is why the encoding lives here in the
//! wire vocabulary rather than in either consumer. Two producers of the same
//! bytes is how they drift.
//!
//! The shape is flat and tagged — `{"type":"text_delta","text":"hi"}` — rather
//! than Zig's natural `{"text_delta":"hi"}`, because every consumer that is not
//! Zig switches on a field, and a discriminant that changes the whole object's
//! shape is hostile to `jq`.
//!
//! Field order is part of the format: the goldens compare bytes.
//!
//! One name differs between the two sides. The Zig variant is `err`, because
//! `error` is a keyword; the wire says `"error"`, because that is what every
//! other language reads. `writeEvent` and `fromWire` are the only two places
//! that know, and they sit in this file.

const std = @import("std");

const stream = @import("stream.zig");

pub const StreamEvent = stream.StreamEvent;

/// The flat form.
///
/// Every field optional so one struct covers every variant — which is what lets
/// `std.json` parse a line before anyone knows which variant it is. Turning that
/// into a `StreamEvent` is `fromWire`'s job, and it is where a missing field
/// becomes an error rather than a default.
pub const Wire = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
    input_tokens: ?u32 = null,
    output_tokens: ?u32 = null,
    cache_read_tokens: ?u32 = null,
    cache_creation_tokens: ?u32 = null,
    reason: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    message: ?[]const u8 = null,
    retry_after_ms: ?u32 = null,
};

/// Writes one event and its terminating newline.
///
/// Allocates nothing: the caller's writer is the only buffer, which keeps this
/// usable on the streaming path where every event passes through.
pub fn writeEvent(event: StreamEvent, out: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (event) {
        .text_delta => |text| {
            try out.writeAll("{\"type\":\"text_delta\",\"text\":");
            try std.json.Stringify.encodeJsonString(text, .{}, out);
            try out.writeAll("}\n");
        },
        .tool_call_delta => |call| {
            try out.writeAll("{\"type\":\"tool_call_delta\",\"id\":");
            try std.json.Stringify.encodeJsonString(call.id, .{}, out);
            try out.writeAll(",\"name\":");
            try std.json.Stringify.encodeJsonString(call.name, .{}, out);
            try out.writeAll(",\"arguments\":");
            try std.json.Stringify.encodeJsonString(call.arguments, .{}, out);
            try out.writeAll("}\n");
        },
        .usage => |usage| try out.print(
            "{{\"type\":\"usage\",\"input_tokens\":{d},\"output_tokens\":{d}," ++
                "\"cache_read_tokens\":{d},\"cache_creation_tokens\":{d}}}\n",
            .{
                usage.input_tokens,
                usage.output_tokens,
                usage.cache_read_tokens,
                usage.cache_creation_tokens,
            },
        ),
        .stop => |stop| try out.print(
            "{{\"type\":\"stop\",\"reason\":\"{s}\"}}\n",
            .{@tagName(stop.reason)},
        ),
        .err => |err| {
            try out.print("{{\"type\":\"error\",\"kind\":\"{s}\",\"message\":", .{@tagName(err.kind)});
            try std.json.Stringify.encodeJsonString(err.message, .{}, out);
            // Omitted rather than null when the provider said nothing: `jq`
            // treats a missing key and a null key differently, and "no
            // instruction" is the more useful of the two to read as missing.
            if (err.retry_after_ms) |ms| try out.print(",\"retry_after_ms\":{d}", .{ms});
            try out.writeAll("}\n");
        },
    }
}

pub const DecodeError = error{
    UnknownEventType,
    UnknownStopReason,
    UnknownErrorKind,
    MissingField,
};

/// Parses one line into the flat form. The caller owns the result and frees it
/// with `deinit`; every slice in it borrows from that allocation, not from
/// `line`.
pub fn parseEvent(gpa: std.mem.Allocator, line: []const u8) !std.json.Parsed(Wire) {
    return std.json.parseFromSlice(Wire, gpa, line, .{ .ignore_unknown_fields = true });
}

/// Turns the flat form into an event.
///
/// Unknown type, stop reason or error kind is an error rather than a default: a
/// consumer that silently mapped an unrecognized stop reason to `end_turn` would
/// report a refusal as a finished answer.
pub fn fromWire(wire: Wire) DecodeError!StreamEvent {
    if (std.mem.eql(u8, wire.type, "text_delta")) {
        return .{ .text_delta = wire.text orelse return error.MissingField };
    }
    if (std.mem.eql(u8, wire.type, "tool_call_delta")) {
        return .{ .tool_call_delta = .{
            .id = wire.id orelse return error.MissingField,
            .name = wire.name orelse "",
            .arguments = wire.arguments orelse "",
        } };
    }
    if (std.mem.eql(u8, wire.type, "usage")) {
        return .{ .usage = .{
            .input_tokens = wire.input_tokens orelse 0,
            .output_tokens = wire.output_tokens orelse 0,
            .cache_read_tokens = wire.cache_read_tokens orelse 0,
            .cache_creation_tokens = wire.cache_creation_tokens orelse 0,
        } };
    }
    if (std.mem.eql(u8, wire.type, "stop")) {
        const name = wire.reason orelse return error.MissingField;
        const reason = std.meta.stringToEnum(stream.StopReason, name) orelse
            return error.UnknownStopReason;
        return .{ .stop = .{ .reason = reason } };
    }
    if (std.mem.eql(u8, wire.type, "error")) {
        const name = wire.kind orelse return error.MissingField;
        const kind = std.meta.stringToEnum(stream.ErrKind, name) orelse
            return error.UnknownErrorKind;
        return .{ .err = .{
            .kind = kind,
            .message = wire.message orelse "",
            .retry_after_ms = wire.retry_after_ms,
        } };
    }
    return error.UnknownEventType;
}

const testing = std.testing;

test "every variant encodes to one line" {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeEvent(.{ .text_delta = "hi" }, &writer);
    try testing.expectEqualStrings(
        "{\"type\":\"text_delta\",\"text\":\"hi\"}\n",
        writer.buffered(),
    );
}

test "a delta with a quote and a newline stays one line" {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeEvent(.{ .text_delta = "say \"hi\"\nthen stop" }, &writer);

    const written = writer.buffered();
    // Exactly one newline, and it is the last byte: the payload's newline is
    // escaped, which is the whole reason ndjson works as a stream format.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "\n"));
    try testing.expectEqual(written.len - 1, std.mem.indexOfScalar(u8, written, '\n').?);
}

test "a rate limit without a retry-after omits the key" {
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeEvent(.{ .err = .{ .kind = .rate_limit, .message = "slow down" } }, &writer);
    try testing.expectEqualStrings(
        "{\"type\":\"error\",\"kind\":\"rate_limit\",\"message\":\"slow down\"}\n",
        writer.buffered(),
    );
}

test "round trip is lossless for every variant" {
    const cases = [_]StreamEvent{
        .{ .text_delta = "hello" },
        .{ .text_delta = "say \"hi\"\nthen stop" },
        .{ .tool_call_delta = .{ .id = "toolu_01", .name = "read", .arguments = "{\"p\":1}" } },
        .{ .tool_call_delta = .{ .id = "toolu_01" } },
        .{ .usage = .{
            .input_tokens = 1,
            .output_tokens = 2,
            .cache_read_tokens = 3,
            .cache_creation_tokens = 4,
        } },
        .{ .stop = .{ .reason = .tool_use } },
        .{ .stop = .{ .reason = .refusal } },
        .{ .err = .{ .kind = .rate_limit, .message = "slow down", .retry_after_ms = 1_800 } },
        .{ .err = .{ .kind = .decode, .message = "unterminated SSE field" } },
    };

    for (cases) |event| {
        var buffer: [512]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try writeEvent(event, &writer);

        const line = std.mem.trimEnd(u8, writer.buffered(), "\n");
        var parsed = try parseEvent(testing.allocator, line);
        defer parsed.deinit();

        var second: [512]u8 = undefined;
        var second_writer: std.Io.Writer = .fixed(&second);
        try writeEvent(try fromWire(parsed.value), &second_writer);

        try testing.expectEqualStrings(writer.buffered(), second_writer.buffered());
    }
}

test "an unknown type is a decode error, not a silent drop" {
    var parsed = try parseEvent(testing.allocator, "{\"type\":\"telepathy\"}");
    defer parsed.deinit();
    try testing.expectError(error.UnknownEventType, fromWire(parsed.value));
}

test "an unknown stop reason is an error rather than an end of turn" {
    var parsed = try parseEvent(testing.allocator, "{\"type\":\"stop\",\"reason\":\"vibes\"}");
    defer parsed.deinit();
    try testing.expectError(error.UnknownStopReason, fromWire(parsed.value));
}

test "a text delta with no text is a missing field" {
    var parsed = try parseEvent(testing.allocator, "{\"type\":\"text_delta\"}");
    defer parsed.deinit();
    try testing.expectError(error.MissingField, fromWire(parsed.value));
}

/// Every variant, in a fixed order, as one ndjson document.
///
/// Shared by the golden test below and by whoever needs a known-good sample.
/// Phase 8's `--json` goldens compare against the same bytes rather than a
/// second list that would drift from this one.
const golden_cases = [_]StreamEvent{
    .{ .text_delta = "hello" },
    .{ .text_delta = "say \"hi\"\nthen stop" },
    .{ .tool_call_delta = .{ .id = "toolu_01", .name = "read", .arguments = "{\"path\":\"/tmp/x\"}" } },
    .{ .tool_call_delta = .{ .id = "toolu_01", .arguments = ",\"limit\":10}" } },
    .{ .usage = .{ .input_tokens = 12, .output_tokens = 40, .cache_read_tokens = 1200 } },
    .{ .stop = .{ .reason = .end_turn } },
    .{ .stop = .{ .reason = .tool_use } },
    .{ .err = .{ .kind = .rate_limit, .message = "slow down", .retry_after_ms = 1800 } },
    .{ .err = .{ .kind = .decode, .message = "unterminated SSE field" } },
};

test "the encoding matches its golden, byte for byte" {
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    for (golden_cases) |event| try writeEvent(event, &writer);

    // Read at run time rather than embedded: `@embedFile` cannot reach outside
    // the module's own directory, and `testdata/` is shared with the rest of the
    // repo. `zig build test` runs its binaries from the build root — the same
    // arrangement `src/shell/render/transcript.zig` relies on.
    //
    // Freestanding is unaffected: `zig build wasm-check` builds an object, and
    // test blocks are not part of one.
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const expected = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "testdata/golden/ndjson-events.txt",
        testing.allocator,
        .limited(1 << 16),
    );
    defer testing.allocator.free(expected);

    try testing.expectEqualStrings(expected, writer.buffered());
}

test "unknown keys are ignored so a newer producer stays readable" {
    var parsed = try parseEvent(
        testing.allocator,
        "{\"type\":\"text_delta\",\"text\":\"hi\",\"thinking_signature\":\"abc\"}",
    );
    defer parsed.deinit();

    const event = try fromWire(parsed.value);
    try testing.expectEqualStrings("hi", event.text_delta);
}
