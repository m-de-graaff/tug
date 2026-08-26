//! The OpenAI chat-completions shape — one implementation, six servers.
//!
//! OpenAI, Ollama, OpenRouter, Groq, vLLM and LM Studio all speak this, which is
//! the whole reason it earns a module: roughly ninety per cent of the ecosystem
//! for one mapper. What they do not agree on is everything at the edges, and
//! the edges are what this file is mostly about.
//!
//! Three things here that the Anthropic shape does not have, and each one
//! breaks a mapper written from the happy path alone:
//!
//! 1. **No event names.** Every chunk is an unnamed `data:` event, so there is
//!    nothing to dispatch on. The shape of the payload is the dispatch.
//! 2. **`data: [DONE]` is a sentinel, not JSON.** Handing it to a JSON parser
//!    produces a decode error on the last event of every successful stream.
//! 3. **The usage chunk has an empty `choices` array.** A mapper reading
//!    `choices[0]` unconditionally crashes on the one event carrying the numbers
//!    the usage line is made of.
//!
//! `@setRuntimeSafety(true)` on the decode paths, like every other untrusted
//! decoder in this stack.

const std = @import("std");

const proto = @import("tugproto");

const anthropic_map = @import("anthropic_map.zig");
const redact = @import("redact.zig");
const stream_mod = @import("stream.zig");
const sse = @import("sse.zig");

const Emit = stream_mod.Emit;
const Mapper = stream_mod.Mapper;

const number = anthropic_map.number;
const objectField = anthropic_map.objectField;
const statusOnly = anthropic_map.statusOnly;
const string = anthropic_map.string;

/// How many tool calls one turn may have in flight.
///
/// This shape keys argument fragments by an **array index**, not by the id — the
/// id arrives once, on the first fragment — so the mapper remembers ids exactly
/// as the Anthropic one does, for the same reason and by the same mechanism.
pub const max_tool_calls = 8;

/// The longest tool-call id kept.
pub const max_tool_id = 64;

/// Writes the request body.
///
/// Allocates nothing. Three differences from the Messages API, all of them the
/// reason `tugproto.Request` refuses to model either API's spelling: the system
/// prompt is a message rather than a field, content is a plain string rather
/// than a block array, and there are no cache-control markers because there is
/// nothing to send (`DR-022`).
pub fn buildRequest(request: proto.Request, out: *std.Io.Writer) std.Io.Writer.Error!void {
    var json: std.json.Stringify = .{ .writer = out };

    try json.beginObject();

    try json.objectField("model");
    try json.write(request.model);

    try json.objectField("messages");
    try json.beginArray();

    if (request.system) |system| {
        // A message with role "system", because that is where this shape puts
        // it. Anthropic takes it as a top-level field, and modelling it as a
        // role in the shared vocabulary would force this builder or the other
        // one to unpick it again.
        try json.beginObject();
        try json.objectField("role");
        try json.write("system");
        try json.objectField("content");
        try json.write(system);
        try json.endObject();
    }

    for (request.messages) |message| {
        try json.beginObject();
        try json.objectField("role");
        try json.write(@tagName(message.role));
        try json.objectField("content");
        try writeContent(&json, out, message.content);
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("max_tokens");
    try json.write(request.max_tokens);

    try json.objectField("stream");
    try json.write(true);

    // Ask for usage. Several compat servers ignore this, which is why the mapper
    // treats an absent usage chunk as a missing usage line rather than a broken
    // stream — `testdata/fixtures/openai/usage-absent` is that case, recorded.
    try json.objectField("stream_options");
    try json.beginObject();
    try json.objectField("include_usage");
    try json.write(true);
    try json.endObject();

    if (request.temperature) |temperature| {
        try json.objectField("temperature");
        try json.write(temperature);
    }

    try json.endObject();
    try out.flush();
}

/// Writes a message's content as one JSON string.
///
/// A plain string rather than the array-of-parts form the API also accepts:
/// support for the array form varies across the six servers behind this
/// implementation, and a string is what all of them read. Several blocks are
/// joined with a newline, which is what a reader would see anyway.
fn writeContent(
    json: *std.json.Stringify,
    out: *std.Io.Writer,
    content: []const proto.Content,
) std.Io.Writer.Error!void {
    try json.beginWriteRaw();
    defer json.endWriteRaw();

    try out.writeByte('"');
    for (content, 0..) |part, i| {
        if (i > 0) try std.json.Stringify.encodeJsonStringChars("\n", .{}, out);
        switch (part) {
            .text => |text| try std.json.Stringify.encodeJsonStringChars(text, .{}, out),
        }
    }
    try out.writeByte('"');
}

// --- the mapper -----------------------------------------------------------

/// The sentinel that ends one of these streams. Not JSON, and the reason this
/// name exists rather than a bare string literal in a condition.
pub const done_sentinel = "[DONE]";

pub const OpenAi = struct {
    arena: std.heap.ArenaAllocator,

    tool_ids: [max_tool_calls][max_tool_id]u8 = undefined,
    tool_id_lens: [max_tool_calls]usize = @splat(0),

    pub fn init(gpa: std.mem.Allocator) OpenAi {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *OpenAi) void {
        self.arena.deinit();
    }

    pub fn mapper(self: *OpenAi) Mapper {
        return .{
            .context = self,
            .map = mapErased,
            .errorMessage = errorMessageErased,
        };
    }

    fn mapErased(context: ?*anyopaque, event: sse.ServerEvent, out: *Emit) void {
        const self: *OpenAi = @ptrCast(@alignCast(context.?));
        self.map(event, out);
    }

    pub fn map(self: *OpenAi, event: sse.ServerEvent, out: *Emit) void {
        @setRuntimeSafety(true);

        _ = self.arena.reset(.retain_capacity);

        const data = std.mem.trim(u8, event.data, " \t\r");
        if (data.len == 0) return;

        // Trap two. This has to be checked before the parser sees it, on the
        // last event of every successful stream.
        if (std.mem.eql(u8, data, done_sentinel)) return;

        const parsed = std.json.parseFromSliceLeaky(
            std.json.Value,
            self.arena.allocator(),
            data,
            .{},
        ) catch {
            out.push(.{ .err = .{
                .kind = .decode,
                .message = "the provider sent a chunk that was not JSON",
            } });
            return;
        };

        const object = switch (parsed) {
            .object => |object| object,
            else => return,
        };

        // Some servers put an error object in a 200 stream rather than in a
        // status code. The head was fine; this is the body saying otherwise.
        if (objectField(object, "error")) |detail| {
            out.push(.{ .err = .{
                .kind = .server,
                .message = string(detail, "message") orelse "the provider reported an error",
            } });
            out.push(.{ .stop = .{ .reason = .err } });
            return;
        }

        // Usage first, and unconditionally: the chunk that carries it is the one
        // with no choices in it (trap three), so anything reading choices first
        // never gets here.
        if (objectField(object, "usage")) |usage| {
            out.push(.{ .usage = mapUsage(usage) });
        }

        self.choice(object, out);
    }

    fn choice(self: *OpenAi, object: std.json.ObjectMap, out: *Emit) void {
        const choices = switch (object.get("choices") orelse return) {
            .array => |array| array,
            else => return,
        };
        // Trap three. Empty is the normal shape of the final usage chunk, not an
        // error and not worth a notice.
        if (choices.items.len == 0) return;

        const choice_object = switch (choices.items[0]) {
            .object => |nested| nested,
            else => return,
        };

        if (objectField(choice_object, "delta")) |delta| {
            if (string(delta, "content")) |text| {
                // The opening chunk carries `"content":""` alongside the role.
                // An empty delta is not a delta.
                if (text.len > 0) out.push(.{ .text_delta = text });
            }
            self.toolCalls(delta, out);
        }

        if (string(choice_object, "finish_reason")) |reason| {
            out.push(.{ .stop = .{ .reason = stopReason(reason) } });
        }
    }

    fn toolCalls(self: *OpenAi, delta: std.json.ObjectMap, out: *Emit) void {
        const calls = switch (delta.get("tool_calls") orelse return) {
            .array => |array| array,
            else => return,
        };

        for (calls.items) |item| {
            const call = switch (item) {
                .object => |nested| nested,
                else => continue,
            };

            const index = toolIndex(call) orelse continue;

            // The id arrives once, on the first fragment for this index, and
            // every fragment after it carries only more argument bytes.
            if (string(call, "id")) |id| {
                const take = @min(id.len, max_tool_id);
                @memcpy(self.tool_ids[index][0..take], id[0..take]);
                self.tool_id_lens[index] = take;
            }

            const len = self.tool_id_lens[index];
            // A fragment for an index that never announced an id has no call to
            // belong to. Dropping it beats inventing one.
            if (len == 0) continue;

            const function = objectField(call, "function");
            out.push(.{ .tool_call_delta = .{
                .id = self.tool_ids[index][0..len],
                .name = if (function) |f| string(f, "name") orelse "" else "",
                .arguments = if (function) |f| string(f, "arguments") orelse "" else "",
            } });
        }
    }

    fn errorMessageErased(context: ?*anyopaque, status: u16, body: []const u8, out: []u8) []const u8 {
        const self: *OpenAi = @ptrCast(@alignCast(context.?));
        return errorMessage(self.arena.allocator(), status, body, out);
    }
};

/// Maps the usage object.
///
/// `cache_creation_tokens` stays zero: this shape has no equivalent, because
/// caching here is server-side and automatic (`DR-022`). Cached reads are
/// reported when a server supplies them and zero when it does not — `Usage` has
/// no "unknown" and inventing one would put a third state into a struct that
/// crosses every boundary in the system.
fn mapUsage(usage: std.json.ObjectMap) proto.Usage {
    var mapped: proto.Usage = .{
        .input_tokens = number(usage, "prompt_tokens"),
        .output_tokens = number(usage, "completion_tokens"),
    };

    if (objectField(usage, "prompt_tokens_details")) |details| {
        const cached = number(details, "cached_tokens");
        mapped.cache_read_tokens = cached;
        // The prompt count includes the cached tokens in this shape, and
        // `tugproto.Usage` counts them apart — subtracting is what keeps the
        // cost line from charging for the same tokens twice.
        mapped.input_tokens -|= cached;
    }

    return mapped;
}

/// Maps a finish reason, conservatively.
///
/// An unknown reason becomes `end_turn`, like the Anthropic mapper and for the
/// same argument: six servers invent their own, and a turn that finished for a
/// reason tug has not heard of did still finish.
pub fn stopReason(reason: []const u8) proto.StopReason {
    if (std.mem.eql(u8, reason, "stop")) return .end_turn;
    if (std.mem.eql(u8, reason, "length")) return .max_tokens;
    if (std.mem.eql(u8, reason, "tool_calls")) return .tool_use;
    if (std.mem.eql(u8, reason, "function_call")) return .tool_use;
    if (std.mem.eql(u8, reason, "content_filter")) return .refusal;
    return .end_turn;
}

/// The tool-call array index, bounds-checked. Absent means zero: a server
/// streaming a single tool call may omit it entirely.
fn toolIndex(call: std.json.ObjectMap) ?usize {
    const value = call.get("index") orelse return 0;
    const integer = switch (value) {
        .integer => |integer| integer,
        else => return null,
    };
    if (integer < 0 or integer >= max_tool_calls) return null;
    return @intCast(integer);
}

/// Turns an error document into a sentence, with anything key-shaped scrubbed.
///
/// The same shape as the Anthropic version because the documents are the same
/// shape: `{"error":{"message":...}}`. Shared rather than duplicated, so a fix
/// to one is a fix to both.
pub fn errorMessage(
    gpa: std.mem.Allocator,
    status: u16,
    body: []const u8,
    out: []u8,
) []const u8 {
    return anthropic_map.errorMessage(gpa, status, body, out);
}

const testing = std.testing;
const fixture = @import("fixture.zig");

const request_golden = @embedFile("request-openai.json");
const clean_head = @embedFile("openai-clean-turn.head");
const clean_body = @embedFile("openai-clean-turn.sse");
const clean_expected = @embedFile("openai-clean-turn.ndjson");
const absent_body = @embedFile("openai-usage-absent.sse");
const absent_expected = @embedFile("openai-usage-absent.ndjson");

fn buildInto(buffer: []u8, request: proto.Request) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    try buildRequest(request, &writer);
    return writer.buffered();
}

fn transcribe(gpa: std.mem.Allocator, body: []const u8, chunk: usize) ![]u8 {
    var f: fixture.Fixture = .{
        .head = try fixture.parseHead(clean_head),
        .body = body,
        .chunk = chunk,
    };

    var mapper_state: OpenAi = .init(gpa);
    defer mapper_state.deinit();

    var scratch: [sse.recommended_scratch]u8 = undefined;
    var data: [sse.recommended_data]u8 = undefined;
    var parser: sse.Parser = .init(&scratch, &data);
    var read_buffer: [128]u8 = undefined;

    var s: stream_mod.Stream = .init(
        f.transport(),
        .{ .url = "http://127.0.0.1:11434/v1/chat/completions" },
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

fn mapOne(mapper_state: *OpenAi, data: []const u8) Emit {
    var out: Emit = .{};
    mapper_state.map(.{ .event = "", .data = data, .id = "" }, &out);
    return out;
}

test "the request body is what a chat-completions server expects" {
    const messages = [_]proto.Message{
        .{ .role = .user, .content = &.{.{ .text = "what is a bollard" }} },
        .{ .role = .assistant, .content = &.{.{ .text = "a fixed post" }} },
        .{ .role = .user, .content = &.{.{ .text = "and a bollard pull" }} },
    };

    var buffer: [4096]u8 = undefined;
    const body = try buildInto(&buffer, .{
        .model = "llama3.1",
        .messages = &messages,
        .system = "be terse",
        .max_tokens = 1024,
    });

    try testing.expectEqualStrings(request_golden, body);
}

test "the system prompt is a message, not a field" {
    const messages = [_]proto.Message{
        .{ .role = .user, .content = &.{.{ .text = "hello" }} },
    };
    var buffer: [1024]u8 = undefined;
    const body = try buildInto(&buffer, .{ .model = "m", .messages = &messages, .system = "be terse" });

    try testing.expect(std.mem.indexOf(u8, body, "\"messages\":[{\"role\":\"system\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"be terse\"") != null);
}

test "no cache_control markers are sent" {
    // `DR-022`: caching here is server-side and automatic, and a marker would be
    // a field six different servers would each ignore differently.
    const messages = [_]proto.Message{
        .{ .role = .user, .content = &.{.{ .text = "hello" }} },
    };
    var buffer: [1024]u8 = undefined;
    const body = try buildInto(&buffer, .{ .model = "m", .messages = &messages, .system = "s" });

    try testing.expect(std.mem.indexOf(u8, body, "cache_control") == null);
}

test "usage is requested through stream options" {
    const messages = [_]proto.Message{.{ .role = .user, .content = &.{.{ .text = "hi" }} }};
    var buffer: [1024]u8 = undefined;
    const body = try buildInto(&buffer, .{ .model = "m", .messages = &messages });

    try testing.expect(std.mem.indexOf(u8, body, "\"stream_options\":{\"include_usage\":true}") != null);
}

test "several content blocks become one string, escaped" {
    const blocks = [_]proto.Content{ .{ .text = "say \"hi\"" }, .{ .text = "then stop" } };
    const messages = [_]proto.Message{.{ .role = .user, .content = &blocks }};

    var buffer: [1024]u8 = undefined;
    const body = try buildInto(&buffer, .{ .model = "m", .messages = &messages });

    try testing.expect(std.mem.indexOf(u8, body, "\"content\":\"say \\\"hi\\\"\\nthen stop\"") != null);
}

test "the clean turn maps to the events its ndjson says it does" {
    const got = try transcribe(testing.allocator, clean_body, 13);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(clean_expected, got);
}

test "the clean turn maps identically at every chunk size" {
    for ([_]usize{ 1, 2, 7, 64, 4096 }) |chunk| {
        const got = try transcribe(testing.allocator, clean_body, chunk);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(clean_expected, got);
    }
}

test "a missing usage chunk costs the usage line and nothing else" {
    // Several compat servers ignore stream_options. Absence degrades the usage
    // line; it never degrades the stream.
    const got = try transcribe(testing.allocator, absent_body, 11);
    defer testing.allocator.free(got);

    try testing.expectEqualStrings(absent_expected, got);
    try testing.expect(std.mem.indexOf(u8, got, "usage") == null);
    try testing.expect(std.mem.indexOf(u8, got, "\"stop\"") != null);
}

test "[DONE] ends the stream and is not parsed as JSON" {
    var mapper_state: OpenAi = .init(testing.allocator);
    defer mapper_state.deinit();

    // The trap: the last event of every successful stream. A decode error here
    // would put a red block under every completed answer.
    try testing.expectEqual(@as(usize, 0), mapOne(&mapper_state, "[DONE]").len);
    try testing.expectEqual(@as(usize, 0), mapOne(&mapper_state, " [DONE] ").len);
}

test "an empty choices array is not an error" {
    var mapper_state: OpenAi = .init(testing.allocator);
    defer mapper_state.deinit();

    const out = mapOne(&mapper_state,
        \\{"choices":[],"usage":{"prompt_tokens":18,"completion_tokens":4}}
    );

    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(@as(u32, 18), out.items[0].usage.input_tokens);
}

test "an empty content delta is not a delta" {
    var mapper_state: OpenAi = .init(testing.allocator);
    defer mapper_state.deinit();

    const out = mapOne(&mapper_state,
        \\{"choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}
    );
    try testing.expectEqual(@as(usize, 0), out.len);
}

test "cached tokens are counted apart from fresh input, not twice" {
    var mapper_state: OpenAi = .init(testing.allocator);
    defer mapper_state.deinit();

    const out = mapOne(&mapper_state,
        \\{"choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":10,"prompt_tokens_details":{"cached_tokens":800}}}
    );

    // 1000 reported, 800 of them cached: 200 fresh. Adding them would charge
    // fresh-input prices for tokens that cost a tenth of that.
    try testing.expectEqual(@as(u32, 200), out.items[0].usage.input_tokens);
    try testing.expectEqual(@as(u32, 800), out.items[0].usage.cache_read_tokens);
}

test "delta.tool_calls become fragments keyed by index, with the id remembered" {
    var mapper_state: OpenAi = .init(testing.allocator);
    defer mapper_state.deinit();

    const first = mapOne(&mapper_state,
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_01","type":"function","function":{"name":"read","arguments":""}}]}}]}
    );
    try testing.expectEqual(@as(usize, 1), first.len);
    try testing.expectEqualStrings("call_01", first.items[0].tool_call_delta.id);
    try testing.expectEqualStrings("read", first.items[0].tool_call_delta.name);

    const second = mapOne(&mapper_state,
        \\{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"path\":"}}]}}]}
    );
    // The id arrived once. Everything after it is keyed by the array index
    // alone, which is why the mapper keeps a table.
    try testing.expectEqualStrings("call_01", second.items[0].tool_call_delta.id);
    try testing.expectEqualStrings("{\"path\":", second.items[0].tool_call_delta.arguments);
}

test "a tool-call index outside the table is ignored rather than indexed" {
    var mapper_state: OpenAi = .init(testing.allocator);
    defer mapper_state.deinit();

    for ([_][]const u8{
        \\{"choices":[{"delta":{"tool_calls":[{"index":9999,"id":"x"}]}}]}
        ,
        \\{"choices":[{"delta":{"tool_calls":[{"index":-1,"id":"x"}]}}]}
        ,
    }) |data| {
        try testing.expectEqual(@as(usize, 0), mapOne(&mapper_state, data).len);
    }
}

test "finish reasons map, and an unknown one finishes rather than fails" {
    try testing.expectEqual(proto.StopReason.end_turn, stopReason("stop"));
    try testing.expectEqual(proto.StopReason.max_tokens, stopReason("length"));
    try testing.expectEqual(proto.StopReason.tool_use, stopReason("tool_calls"));
    try testing.expectEqual(proto.StopReason.refusal, stopReason("content_filter"));
    try testing.expectEqual(proto.StopReason.end_turn, stopReason("server_had_an_idea"));
}

test "an error object inside a 200 stream still ends the turn" {
    // Some compat servers answer 200 and then say no in the body.
    var mapper_state: OpenAi = .init(testing.allocator);
    defer mapper_state.deinit();

    const out = mapOne(&mapper_state,
        \\{"error":{"message":"model not loaded","type":"server_error"}}
    );
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expectEqualStrings("model not loaded", out.items[0].err.message);
    try testing.expectEqual(proto.StopReason.err, out.items[1].stop.reason);
}

test "a chunk that is not JSON is a decode error, not a crash" {
    var mapper_state: OpenAi = .init(testing.allocator);
    defer mapper_state.deinit();

    const out = mapOne(&mapper_state, "{not json");
    try testing.expectEqual(proto.ErrKind.decode, out.items[0].err.kind);
}

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var bytes: [1024]u8 = undefined;
    const input = bytes[0..smith.slice(&bytes)];

    var mapper_state: OpenAi = .init(testing.allocator);
    defer mapper_state.deinit();

    var out: Emit = .{};
    mapper_state.map(.{ .event = "", .data = input, .id = "" }, &out);

    var buffer: [256]u8 = undefined;
    _ = errorMessage(testing.allocator, 500, input, &buffer);
}

test "fuzz: the mapper survives any JSON payload" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        \\{"choices":[{"delta":{"content":"hi"}}]}
        ,
        \\{"choices":[]}
        ,
        \\{"choices":[{"delta":{"tool_calls":[{"index":99}]}}]}
        ,
        \\{"choices":"not an array"}
        ,
        \\{"usage":{"prompt_tokens":-1}}
        ,
        "[DONE]",
        "not json at all",
        "",
        "[]",
        "null",
    } });
}
