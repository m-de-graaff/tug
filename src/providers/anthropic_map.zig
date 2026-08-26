//! The Anthropic Messages API, decoding half.
//!
//! Framed SSE events in, `tugproto.StreamEvent`s out. Pure: no `Io`, no clock,
//! no socket — which is what lets it be driven from recorded bytes at any chunk
//! size, including chunk sizes no network would produce.
//!
//! `@setRuntimeSafety(true)` on the decode paths. This is the second untrusted
//! decoder in the stack after the SSE framer, and the ground rules put every one
//! of them under explicit safety checks in the shipped `ReleaseSmall` binary. A
//! content-block index arriving from the wire is an index somebody else chose.

const std = @import("std");

const proto = @import("tugproto");

const redact = @import("redact.zig");
const stream_mod = @import("stream.zig");
const sse = @import("sse.zig");

const Emit = stream_mod.Emit;
const Mapper = stream_mod.Mapper;

/// How many content blocks a response may have open at once.
///
/// The API numbers blocks from zero and an ordinary answer uses one. Sixteen is
/// generous for a turn interleaving text with several tool calls, and the number
/// matters because the index arrives from the wire: bounds-checking a number
/// somebody else chose is the whole reason this is a fixed array.
pub const max_blocks = 16;

/// The longest tool-use id kept. Anthropic's run to about thirty characters.
pub const max_tool_id = 64;

const BlockKind = enum { none, text, tool_use };

pub const Anthropic = struct {
    arena: std.heap.ArenaAllocator,

    /// `content_block_delta` says which index, never which kind, so the kind has
    /// to be remembered from `content_block_start`.
    kinds: [max_blocks]BlockKind = @splat(.none),
    /// A continuation fragment carries no id in the API's bytes, and
    /// `tugproto.ToolCallDelta` requires one. Kept here so the emitted slice
    /// points at storage outliving the event it came from.
    tool_ids: [max_blocks][max_tool_id]u8 = undefined,
    tool_id_lens: [max_blocks]usize = @splat(0),

    /// `message_start` carries the input side of usage and `message_delta` the
    /// output side. A `usage` event should be whole rather than half, so the
    /// first half is kept until the second arrives.
    usage: proto.Usage = .{},

    pub fn init(gpa: std.mem.Allocator) Anthropic {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Anthropic) void {
        self.arena.deinit();
    }

    pub fn mapper(self: *Anthropic) Mapper {
        return .{
            .context = self,
            .map = mapErased,
            .errorMessage = errorMessageErased,
        };
    }

    fn mapErased(context: ?*anyopaque, event: sse.ServerEvent, out: *Emit) void {
        const self: *Anthropic = @ptrCast(@alignCast(context.?));
        self.map(event, out);
    }

    pub fn map(self: *Anthropic, event: sse.ServerEvent, out: *Emit) void {
        @setRuntimeSafety(true);

        // Everything the previous event produced has been consumed by now:
        // `Stream` drains what a mapper emitted before asking for more, which is
        // what makes one arena per event enough.
        _ = self.arena.reset(.retain_capacity);

        const kind = event.event;

        // Swallowed by name. A ping carries a data field and dispatches like any
        // other event; it means nothing and saying so costs a line.
        if (std.mem.eql(u8, kind, "ping")) return;
        if (event.data.len == 0) return;

        const parsed = std.json.parseFromSliceLeaky(
            std.json.Value,
            self.arena.allocator(),
            event.data,
            .{},
        ) catch {
            out.push(.{ .err = .{
                .kind = .decode,
                .message = "the provider sent an event that was not JSON",
            } });
            return;
        };

        const object = switch (parsed) {
            .object => |object| object,
            else => return,
        };

        // An unrecognised event type is ignored rather than fatal: Anthropic
        // adds event types, and a client that fell over on a new one would be a
        // client that breaks on a Tuesday for no reason the user can see.
        if (std.mem.eql(u8, kind, "message_start")) return self.messageStart(object, out);
        if (std.mem.eql(u8, kind, "content_block_start")) return self.blockStart(object, out);
        if (std.mem.eql(u8, kind, "content_block_delta")) return self.blockDelta(object, out);
        if (std.mem.eql(u8, kind, "message_delta")) return self.messageDelta(object, out);
        if (std.mem.eql(u8, kind, "error")) return errorEvent(object, out);
    }

    fn messageStart(self: *Anthropic, object: std.json.ObjectMap, out: *Emit) void {
        const message = objectField(object, "message") orelse return;
        const usage = objectField(message, "usage") orelse return;

        self.usage = .{
            .input_tokens = number(usage, "input_tokens"),
            .output_tokens = number(usage, "output_tokens"),
            .cache_read_tokens = number(usage, "cache_read_input_tokens"),
            .cache_creation_tokens = number(usage, "cache_creation_input_tokens"),
        };
        out.push(.{ .usage = self.usage });
    }

    fn blockStart(self: *Anthropic, object: std.json.ObjectMap, out: *Emit) void {
        const index = blockIndex(object) orelse return;
        const block = objectField(object, "content_block") orelse return;
        const block_type = string(block, "type") orelse return;

        if (std.mem.eql(u8, block_type, "text")) {
            self.kinds[index] = .text;
            return;
        }
        if (!std.mem.eql(u8, block_type, "tool_use")) {
            self.kinds[index] = .none;
            return;
        }

        self.kinds[index] = .tool_use;

        const id = string(block, "id") orelse "";
        const take = @min(id.len, max_tool_id);
        @memcpy(self.tool_ids[index][0..take], id[0..take]);
        self.tool_id_lens[index] = take;

        // The opening fragment: an id and a name, no arguments yet. Emitting it
        // rather than waiting is what lets a frontend say which tool was asked
        // for before a single argument byte has arrived.
        out.push(.{ .tool_call_delta = .{
            .id = self.tool_ids[index][0..take],
            .name = string(block, "name") orelse "",
        } });
    }

    fn blockDelta(self: *Anthropic, object: std.json.ObjectMap, out: *Emit) void {
        const index = blockIndex(object) orelse return;
        const delta = objectField(object, "delta") orelse return;
        const delta_type = string(delta, "type") orelse return;

        if (std.mem.eql(u8, delta_type, "text_delta")) {
            const text = string(delta, "text") orelse return;
            out.push(.{ .text_delta = text });
            return;
        }

        if (std.mem.eql(u8, delta_type, "input_json_delta")) {
            const fragment = string(delta, "partial_json") orelse return;
            const len = self.tool_id_lens[index];
            // A fragment for a block that never opened has no call to belong to.
            // Dropping it beats inventing an id.
            if (len == 0) return;
            out.push(.{ .tool_call_delta = .{
                .id = self.tool_ids[index][0..len],
                .arguments = fragment,
            } });
        }
    }

    fn messageDelta(self: *Anthropic, object: std.json.ObjectMap, out: *Emit) void {
        if (objectField(object, "usage")) |usage| {
            // Only the output side arrives here. The input side is whatever
            // `message_start` said, which is why it was kept.
            self.usage.output_tokens = number(usage, "output_tokens");
            out.push(.{ .usage = self.usage });
        }

        const delta = objectField(object, "delta") orelse return;
        const reason = string(delta, "stop_reason") orelse return;
        out.push(.{ .stop = .{ .reason = stopReason(reason) } });
    }

    fn errorMessageErased(context: ?*anyopaque, status: u16, body: []const u8, out: []u8) []const u8 {
        const self: *Anthropic = @ptrCast(@alignCast(context.?));
        return errorMessage(self.arena.allocator(), status, body, out);
    }
};

fn errorEvent(object: std.json.ObjectMap, out: *Emit) void {
    const detail = objectField(object, "error");
    const message = if (detail) |d|
        string(d, "message") orelse "the provider reported an error"
    else
        "the provider reported an error";

    // An SSE error event ends the turn: the API does not resume after one, and a
    // frontend still waiting would wait forever.
    out.push(.{ .err = .{ .kind = .server, .message = message } });
    out.push(.{ .stop = .{ .reason = .err } });
}

/// Turns an error document into a sentence, with anything key-shaped scrubbed.
///
/// Takes an allocator rather than using the mapper's, so it can be tested
/// without one. The OpenAI-compatible version has the same shape: both APIs nest
/// the human-readable string at `error.message` and differ only in what
/// surrounds it.
pub fn errorMessage(
    gpa: std.mem.Allocator,
    status: u16,
    body: []const u8,
    out: []u8,
) []const u8 {
    @setRuntimeSafety(true);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        body,
        .{},
    ) catch {
        // A captive portal, a load balancer's HTML, a proxy's plain text. What
        // the user needs is "the server did not send JSON", not a parse error
        // about a character at offset zero.
        return std.fmt.bufPrint(
            out,
            "the provider answered {d} with a body that was not JSON",
            .{status},
        ) catch "the provider answered with a body that was not JSON";
    };

    const object = switch (parsed) {
        .object => |object| object,
        else => return statusOnly(status, out),
    };
    const detail = objectField(object, "error") orelse return statusOnly(status, out);
    const message = string(detail, "message") orelse return statusOnly(status, out);

    // Some APIs echo request metadata back. A key riding in on an error body
    // must not ride back out into a log.
    return redact.keys(message, out);
}

pub fn statusOnly(status: u16, out: []u8) []const u8 {
    return std.fmt.bufPrint(out, "the provider answered {d}", .{status}) catch
        "the provider answered with an error";
}

/// Maps the API's stop reason onto the vocabulary, conservatively.
///
/// An unknown reason becomes `end_turn` rather than `err`: a turn that finished
/// for a reason this version has not heard of did still finish, and calling that
/// an error would draw a red block under a complete answer.
pub fn stopReason(reason: []const u8) proto.StopReason {
    if (std.mem.eql(u8, reason, "end_turn")) return .end_turn;
    if (std.mem.eql(u8, reason, "max_tokens")) return .max_tokens;
    if (std.mem.eql(u8, reason, "tool_use")) return .tool_use;
    if (std.mem.eql(u8, reason, "refusal")) return .refusal;
    if (std.mem.eql(u8, reason, "stop_sequence")) return .end_turn;
    return .end_turn;
}

pub fn objectField(object: std.json.ObjectMap, name: []const u8) ?std.json.ObjectMap {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .object => |nested| nested,
        else => null,
    };
}

pub fn string(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

/// A non-negative token count, or zero.
///
/// Zero rather than an error for a missing or malformed field: a usage line with
/// one number missing is worth more than no usage line, and a negative token
/// count is not a thing that exists.
pub fn number(object: std.json.ObjectMap, name: []const u8) u32 {
    const value = object.get(name) orelse return 0;
    return switch (value) {
        .integer => |integer| if (integer < 0) 0 else @intCast(@min(integer, std.math.maxInt(u32))),
        else => 0,
    };
}

/// The content-block index, bounds-checked against the array it will index.
///
/// The number comes from the wire. `null` for anything out of range, which the
/// callers turn into "ignore this event" — the alternative is a panic in a
/// release binary, triggered by a provider having a bad day.
fn blockIndex(object: std.json.ObjectMap) ?usize {
    const value = object.get("index") orelse return null;
    const integer = switch (value) {
        .integer => |integer| integer,
        else => return null,
    };
    if (integer < 0 or integer >= max_blocks) return null;
    return @intCast(integer);
}

const testing = std.testing;
const fixture = @import("fixture.zig");

const clean_head = @embedFile("clean-turn.head");
const clean_body = @embedFile("clean-turn.sse");
const clean_expected = @embedFile("clean-turn.ndjson");

/// Runs a body through the whole stack and returns the ndjson the events encode
/// to — the same bytes `--json` will print in Phase 8, which is what makes this
/// assertion worth making in the vocabulary rather than in a Zig struct dump.
fn transcribe(
    gpa: std.mem.Allocator,
    head: seam_head,
    body: []const u8,
    chunk: usize,
) ![]u8 {
    var f: fixture.Fixture = .{ .head = head, .body = body, .chunk = chunk };

    var mapper_state: Anthropic = .init(gpa);
    defer mapper_state.deinit();

    var scratch: [sse.recommended_scratch]u8 = undefined;
    var data: [sse.recommended_data]u8 = undefined;
    var parser: sse.Parser = .init(&scratch, &data);
    var read_buffer: [128]u8 = undefined;

    var s: stream_mod.Stream = .init(
        f.transport(),
        .{ .url = "https://api.anthropic.com/v1/messages" },
        &parser,
        mapper_state.mapper(),
        &read_buffer,
    );

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();

    const p = s.provider();
    while (p.nextEvent()) |event| try proto.ndjson.writeEvent(event, &out.writer);

    return out.toOwnedSlice();
}

const seam_head = @import("transport.zig").Head;

test "the clean turn maps to the events its ndjson says it does" {
    // 13 is prime, so no read boundary lands where an event boundary does.
    const got = try transcribe(testing.allocator, try fixture.parseHead(clean_head), clean_body, 13);
    defer testing.allocator.free(got);

    try testing.expectEqualStrings(clean_expected, got);
}

test "the clean turn maps identically at every chunk size" {
    // Chunking invariance over the whole stack, not only the framer.
    for ([_]usize{ 1, 2, 7, 64, 4096 }) |chunk| {
        const got = try transcribe(testing.allocator, try fixture.parseHead(clean_head), clean_body, chunk);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(clean_expected, got);
    }
}

test "a ping is swallowed" {
    var mapper_state: Anthropic = .init(testing.allocator);
    defer mapper_state.deinit();

    var out: Emit = .{};
    mapper_state.map(.{ .event = "ping", .data = "{\"type\":\"ping\"}", .id = "" }, &out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "an unknown event type is ignored rather than fatal" {
    var mapper_state: Anthropic = .init(testing.allocator);
    defer mapper_state.deinit();

    var out: Emit = .{};
    mapper_state.map(.{ .event = "message_reticulated", .data = "{\"type\":\"x\"}", .id = "" }, &out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "an event whose data is not JSON is a decode error, not a crash" {
    var mapper_state: Anthropic = .init(testing.allocator);
    defer mapper_state.deinit();

    var out: Emit = .{};
    mapper_state.map(.{ .event = "message_start", .data = "{not json", .id = "" }, &out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(proto.ErrKind.decode, out.items[0].err.kind);
}

test "a tool_use block becomes tool_call_delta fragments carrying the same id" {
    var mapper_state: Anthropic = .init(testing.allocator);
    defer mapper_state.deinit();

    var out: Emit = .{};
    mapper_state.map(.{
        .event = "content_block_start",
        .data =
        \\{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_01","name":"read"}}
        ,
        .id = "",
    }, &out);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("toolu_01", out.items[0].tool_call_delta.id);
    try testing.expectEqualStrings("read", out.items[0].tool_call_delta.name);

    var second: Emit = .{};
    mapper_state.map(.{
        .event = "content_block_delta",
        .data =
        \\{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}
        ,
        .id = "",
    }, &second);
    try testing.expectEqual(@as(usize, 1), second.len);
    // The continuation carries no id on the wire; the mapper is what remembers.
    try testing.expectEqualStrings("toolu_01", second.items[0].tool_call_delta.id);
    try testing.expectEqualStrings("{\"path\":", second.items[0].tool_call_delta.arguments);
    try testing.expectEqualStrings("", second.items[0].tool_call_delta.name);
}

test "a delta for a block index nobody opened does not crash" {
    var mapper_state: Anthropic = .init(testing.allocator);
    defer mapper_state.deinit();

    var out: Emit = .{};
    mapper_state.map(.{
        .event = "content_block_delta",
        .data =
        \\{"index":9,"delta":{"type":"input_json_delta","partial_json":"{}"}}
        ,
        .id = "",
    }, &out);
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "an index outside the array is ignored rather than indexed" {
    // The number comes from the wire, and this is the test that says a bad one
    // is a shrug rather than a panic in a release binary.
    var mapper_state: Anthropic = .init(testing.allocator);
    defer mapper_state.deinit();

    for ([_][]const u8{
        \\{"index":9999,"delta":{"type":"text_delta","text":"hi"}}
        ,
        \\{"index":-1,"delta":{"type":"text_delta","text":"hi"}}
        ,
        \\{"index":"zero","delta":{"type":"text_delta","text":"hi"}}
        ,
    }) |data| {
        var out: Emit = .{};
        mapper_state.map(.{ .event = "content_block_delta", .data = data, .id = "" }, &out);
        try testing.expectEqual(@as(usize, 0), out.len);
    }
}

test "an SSE error event becomes an err and a stop, in that order" {
    var mapper_state: Anthropic = .init(testing.allocator);
    defer mapper_state.deinit();

    var out: Emit = .{};
    mapper_state.map(.{
        .event = "error",
        .data =
        \\{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
        ,
        .id = "",
    }, &out);

    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("Overloaded", out.items[0].err.message);
    try testing.expectEqual(proto.StopReason.err, out.items[1].stop.reason);
}

test "usage arrives twice, and the second one is whole" {
    var mapper_state: Anthropic = .init(testing.allocator);
    defer mapper_state.deinit();

    var first: Emit = .{};
    mapper_state.map(.{
        .event = "message_start",
        .data =
        \\{"message":{"usage":{"input_tokens":24,"cache_read_input_tokens":1200,"cache_creation_input_tokens":0,"output_tokens":1}}}
        ,
        .id = "",
    }, &first);
    try testing.expectEqual(@as(u32, 24), first.items[0].usage.input_tokens);
    try testing.expectEqual(@as(u32, 1_200), first.items[0].usage.cache_read_tokens);

    var second: Emit = .{};
    mapper_state.map(.{
        .event = "message_delta",
        .data =
        \\{"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":31}}
        ,
        .id = "",
    }, &second);

    // The input side survives from message_start; a usage event with half the
    // numbers in it would make the cost line wrong.
    try testing.expectEqual(@as(u32, 24), second.items[0].usage.input_tokens);
    try testing.expectEqual(@as(u32, 31), second.items[0].usage.output_tokens);
    try testing.expectEqual(@as(u32, 1_200), second.items[0].usage.cache_read_tokens);
    try testing.expectEqual(proto.StopReason.end_turn, second.items[1].stop.reason);
}

test "stop reasons map, and an unknown one finishes rather than fails" {
    try testing.expectEqual(proto.StopReason.end_turn, stopReason("end_turn"));
    try testing.expectEqual(proto.StopReason.max_tokens, stopReason("max_tokens"));
    try testing.expectEqual(proto.StopReason.tool_use, stopReason("tool_use"));
    try testing.expectEqual(proto.StopReason.refusal, stopReason("refusal"));
    try testing.expectEqual(proto.StopReason.end_turn, stopReason("stop_sequence"));
    try testing.expectEqual(proto.StopReason.end_turn, stopReason("something_new"));
}

test "a 401 body says which credential was wrong, in the provider's words" {
    var buffer: [256]u8 = undefined;
    const message = errorMessage(
        testing.allocator,
        401,
        \\{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}
    ,
        &buffer,
    );

    try testing.expect(std.mem.indexOf(u8, message, "invalid x-api-key") != null);
    // And never the raw JSON.
    try testing.expect(std.mem.indexOf(u8, message, "{\"type\"") == null);
}

test "an HTML error page does not become a JSON parse failure" {
    var buffer: [256]u8 = undefined;
    const message = errorMessage(testing.allocator, 502, "<html><head><title>502</title>", &buffer);
    try testing.expect(std.mem.indexOf(u8, message, "not JSON") != null);
    try testing.expect(std.mem.indexOf(u8, message, "502") != null);
}

test "a JSON body with no message falls back to the status" {
    var buffer: [256]u8 = undefined;
    const message = errorMessage(testing.allocator, 500, "{\"nope\":true}", &buffer);
    try testing.expect(std.mem.indexOf(u8, message, "500") != null);
}

test "an enormous error body is truncated rather than buffered" {
    var buffer: [64]u8 = undefined;
    const huge = "{\"error\":{\"message\":\"" ++ ("x" ** 4096) ++ "\"}}";
    const message = errorMessage(testing.allocator, 500, huge, &buffer);
    try testing.expect(message.len <= buffer.len);
}

test "the canary never reaches an error message" {
    // Some APIs echo the request back. If a key ever rides in on an error body
    // it must not ride back out into a log.
    var buffer: [256]u8 = undefined;
    const canary = @import("canary.zig");
    const body = "{\"error\":{\"message\":\"invalid key " ++ canary.key ++ "\"}}";
    const message = errorMessage(testing.allocator, 401, body, &buffer);

    try testing.expect(!canary.contains(message));
    try testing.expect(std.mem.indexOf(u8, message, "invalid key") != null);
}

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var bytes: [1024]u8 = undefined;
    const input = bytes[0..smith.slice(&bytes)];

    var mapper_state: Anthropic = .init(testing.allocator);
    defer mapper_state.deinit();

    // Every event name the mapper dispatches on, so the fuzzer reaches every
    // branch rather than only the JSON parse.
    for ([_][]const u8{
        "message_start",
        "content_block_start",
        "content_block_delta",
        "message_delta",
        "error",
        "ping",
        "unknown",
    }) |name| {
        var out: Emit = .{};
        mapper_state.map(.{ .event = name, .data = input, .id = "" }, &out);
    }

    var buffer: [256]u8 = undefined;
    _ = errorMessage(testing.allocator, 500, input, &buffer);
}

test "fuzz: the mapper survives any JSON payload" {
    // Outside fuzz mode the runner replays this corpus once, so the target costs
    // microseconds on an ordinary `zig build test`. The seeds are the shapes
    // that would index an array or unwrap a null if the mapper trusted them.
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        \\{"type":"message_start","message":{"usage":{"input_tokens":1}}}
        ,
        \\{"index":99,"delta":{"type":"text_delta","text":"hi"}}
        ,
        \\{"index":-1,"delta":{}}
        ,
        \\{"content_block":{"type":"tool_use","id":"","name":null}}
        ,
        \\{"delta":{"stop_reason":123}}
        ,
        "not json at all",
        "",
        "[]",
        "null",
    } });
}
