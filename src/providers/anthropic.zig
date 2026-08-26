//! The Anthropic Messages API.
//!
//! Two pure halves and nothing else: `buildRequest` turns a `tugproto.Request`
//! into request bytes, and `Mapper` turns framed SSE events into
//! `tugproto.StreamEvent`s. Neither takes an `Io`, a clock, or a socket, which
//! is what lets the whole shape be tested from recorded bytes at any chunk size.
//!
//! `@setRuntimeSafety(true)` for the decoding half: this is the second
//! untrusted decoder in the stack after the SSE framer, and the ground rules put
//! every one of them under explicit safety checks in the shipped `ReleaseSmall`
//! binary. An index arriving from the wire is an index somebody else chose.

const std = @import("std");

const proto = @import("tugproto");

const stream_mod = @import("stream.zig");
const sse = @import("sse.zig");

const Emit = stream_mod.Emit;
const Mapper = stream_mod.Mapper;

/// The API version header. Anthropic dates its wire format, and sending a date
/// is how a client says which shape it was written against.
pub const version_header = "2023-06-01";

fn writeCacheControl(json: *std.json.Stringify) std.Io.Writer.Error!void {
    try json.objectField("cache_control");
    try json.beginObject();
    try json.objectField("type");
    try json.write("ephemeral");
    try json.endObject();
}

/// Writes the request body.
///
/// Allocates nothing: the caller supplies the writer, which is a fixed buffer in
/// tests and the request arena in production. Two `cache_control` markers go in,
/// on the system prompt and the last user turn, per `DR-022`.
pub fn buildRequest(request: proto.Request, out: *std.Io.Writer) std.Io.Writer.Error!void {
    // The last *user* turn, not the last turn. A conversation ending on an
    // assistant message would otherwise be marked there, and every later cache
    // hit would be one turn stale — see `DR-022`.
    var last_user: ?usize = null;
    for (request.messages, 0..) |message, i| {
        if (message.role == .user) last_user = i;
    }

    var json: std.json.Stringify = .{ .writer = out };

    try json.beginObject();

    try json.objectField("model");
    try json.write(request.model);

    try json.objectField("max_tokens");
    try json.write(request.max_tokens);

    try json.objectField("stream");
    try json.write(true);

    if (request.temperature) |temperature| {
        // Absent when absent. A defaulted temperature is a different request
        // from an omitted one, and only one of them means "yours".
        try json.objectField("temperature");
        try json.write(temperature);
    }

    if (request.system) |system| {
        // A bare string would be legal and shorter. The block form is what can
        // carry a cache_control marker, and `DR-022` puts one here.
        try json.objectField("system");
        try json.beginArray();
        try json.beginObject();
        try json.objectField("type");
        try json.write("text");
        try json.objectField("text");
        try json.write(system);
        try writeCacheControl(&json);
        try json.endObject();
        try json.endArray();
    }

    try json.objectField("messages");
    try json.beginArray();
    for (request.messages, 0..) |message, i| {
        try json.beginObject();
        try json.objectField("role");
        try json.write(@tagName(message.role));

        try json.objectField("content");
        try json.beginArray();
        for (message.content, 0..) |content, block| {
            const mark = last_user == i and block + 1 == message.content.len;
            switch (content) {
                .text => |text| {
                    try json.beginObject();
                    try json.objectField("type");
                    try json.write("text");
                    try json.objectField("text");
                    try json.write(text);
                    if (mark) try writeCacheControl(&json);
                    try json.endObject();
                },
            }
        }
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();

    try json.endObject();
    try out.flush();
}

const testing = std.testing;

const request_golden = @embedFile("request-anthropic.json");

fn buildInto(buffer: []u8, request: proto.Request) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try buildRequest(request, &writer);
    return writer.buffered();
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var found: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |at| : (i = at + 1) found += 1;
    return found;
}

test "the request body is what the Messages API expects" {
    const messages = [_]proto.Message{
        .{ .role = .user, .content = &.{.{ .text = "what is a bollard" }} },
        .{ .role = .assistant, .content = &.{.{ .text = "a fixed post" }} },
        .{ .role = .user, .content = &.{.{ .text = "and a bollard pull" }} },
    };

    var buffer: [4096]u8 = undefined;
    const body = try buildInto(&buffer, .{
        .model = "claude-sonnet-4-5",
        .messages = &messages,
        .system = "be terse",
        .max_tokens = 1024,
    });

    try testing.expectEqualStrings(request_golden, body);
}

test "the cache markers land on the system prompt and the last user turn" {
    // `DR-022`, asserted rather than described.
    const messages = [_]proto.Message{
        .{ .role = .user, .content = &.{.{ .text = "what is a bollard" }} },
        .{ .role = .assistant, .content = &.{.{ .text = "a fixed post" }} },
        .{ .role = .user, .content = &.{.{ .text = "and a bollard pull" }} },
    };

    var buffer: [4096]u8 = undefined;
    const body = try buildInto(&buffer, .{
        .model = "claude-sonnet-4-5",
        .messages = &messages,
        .system = "be terse",
    });

    try testing.expectEqual(@as(usize, 2), countOccurrences(body, "\"cache_control\""));
    try testing.expect(std.mem.indexOf(u8, body, "\"be terse\",\"cache_control\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"and a bollard pull\",\"cache_control\"") != null);
    // And emphatically not on the assistant turn between them.
    try testing.expect(std.mem.indexOf(u8, body, "\"a fixed post\",\"cache_control\"") == null);
}

test "a conversation ending on an assistant turn still marks the last user turn" {
    // The mistake `DR-022` exists to prevent: marking the last *message* would
    // put the marker here on the assistant turn, and every later hit would be
    // one turn stale.
    const messages = [_]proto.Message{
        .{ .role = .user, .content = &.{.{ .text = "ask" }} },
        .{ .role = .assistant, .content = &.{.{ .text = "answer" }} },
    };

    var buffer: [1024]u8 = undefined;
    const body = try buildInto(&buffer, .{ .model = "m", .messages = &messages });

    try testing.expectEqual(@as(usize, 1), countOccurrences(body, "\"cache_control\""));
    try testing.expect(std.mem.indexOf(u8, body, "\"ask\",\"cache_control\"") != null);
}

test "a single-turn conversation still gets both markers" {
    // The degenerate case, and the first request of every session: the only
    // user message is also the last one.
    const messages = [_]proto.Message{
        .{ .role = .user, .content = &.{.{ .text = "hello" }} },
    };

    var buffer: [1024]u8 = undefined;
    const body = try buildInto(&buffer, .{
        .model = "m",
        .messages = &messages,
        .system = "be terse",
    });

    try testing.expectEqual(@as(usize, 2), countOccurrences(body, "\"cache_control\""));
}

test "no system prompt means one marker, not a null one" {
    const messages = [_]proto.Message{
        .{ .role = .user, .content = &.{.{ .text = "hello" }} },
    };

    var buffer: [1024]u8 = undefined;
    const body = try buildInto(&buffer, .{ .model = "m", .messages = &messages });

    try testing.expectEqual(@as(usize, 1), countOccurrences(body, "\"cache_control\""));
    try testing.expect(std.mem.indexOf(u8, body, "\"system\"") == null);
}

test "only the last block of a multi-block turn is marked" {
    const blocks = [_]proto.Content{ .{ .text = "first" }, .{ .text = "second" } };
    const messages = [_]proto.Message{.{ .role = .user, .content = &blocks }};

    var buffer: [1024]u8 = undefined;
    const body = try buildInto(&buffer, .{ .model = "m", .messages = &messages });

    try testing.expectEqual(@as(usize, 1), countOccurrences(body, "\"cache_control\""));
    try testing.expect(std.mem.indexOf(u8, body, "\"second\",\"cache_control\"") != null);
}

test "temperature is absent when it is absent" {
    const messages = [_]proto.Message{
        .{ .role = .user, .content = &.{.{ .text = "hello" }} },
    };

    var buffer: [1024]u8 = undefined;
    const without = try buildInto(&buffer, .{ .model = "m", .messages = &messages });
    try testing.expect(std.mem.indexOf(u8, without, "temperature") == null);

    var second: [1024]u8 = undefined;
    const with = try buildInto(&second, .{ .model = "m", .messages = &messages, .temperature = 0.2 });
    try testing.expect(std.mem.indexOf(u8, with, "\"temperature\":0.2") != null);
}

test "a prompt with quotes and newlines in it is escaped, not truncated" {
    // The request body is JSON and the user types whatever they type.
    const messages = [_]proto.Message{
        .{ .role = .user, .content = &.{.{ .text = "say \"hi\"\nthen stop" }} },
    };

    var buffer: [1024]u8 = undefined;
    const body = try buildInto(&buffer, .{ .model = "m", .messages = &messages });

    try testing.expect(std.mem.indexOf(u8, body, "say \\\"hi\\\"\\nthen stop") != null);
}
