//! Debug-build-only subcommands.
//!
//! `tug dev sse-dump` is the M1 demo and a permanent debugging tool: when a
//! provider misbehaves, the first question is always whether the bytes framed
//! the way the parser thinks they did, and this answers it without a debugger.
//!
//! `tug dev stream` is the M2 demo: a real request to a real endpoint, streamed.
//! It exists because Phase 7 is where the shell gets a real spine, and a
//! milestone whose only proof was "the tests pass" would be a milestone nobody
//! had watched work.
//!
//! Not reachable from a release build. These read stdin and write stdout with no
//! terminal setup at all, which also makes them the first thing in tug shaped
//! like Phase 8's pipe frontend — no termios, no probes, no protocol modes, and
//! model text on stdout with every diagnostic on stderr.

const std = @import("std");

const core = @import("tugcore");
const proto = @import("tugproto");
const providers = @import("tugproviders");

const sse = providers.sse;

/// The `decode` slot in the Phase 8 exit-code taxonomy (`DR-020`). Spending it
/// here costs nothing and gives the taxonomy one caller before it is written
/// down.
pub const decode_exit_code: u8 = 7;

/// The rest of that taxonomy, as far as this version can tell the classes apart.
///
/// Phase 5 owns the mapping from HTTP status to `ErrKind`, so today everything
/// that is not a transport failure or a decode failure arrives as `server`.
/// These constants exist so Phase 8 finds them already spent rather than
/// choosing numbers twice.
pub const auth_exit_code: u8 = 3;
pub const rate_limit_exit_code: u8 = 4;
pub const server_exit_code: u8 = 5;
pub const transport_exit_code: u8 = 6;

fn exitCode(kind: proto.ErrKind) u8 {
    return switch (kind) {
        .auth => auth_exit_code,
        .rate_limit => rate_limit_exit_code,
        .server => server_exit_code,
        .transport => transport_exit_code,
        .decode => decode_exit_code,
    };
}

/// How much is read from stdin at a time. Small on purpose: a dump that only
/// framed correctly because it saw the whole stream at once would be a dump that
/// hides exactly the bug this tool exists to find.
const chunk_size = 4096;

/// One line per event: the event name, the byte length of the data, then the
/// data with its newlines escaped so one event stays one line.
///
/// Length before content because the first question about a delta is usually how
/// big it is, and the second is what is in it.
fn writeEvent(event: sse.ServerEvent, out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.print("event={s} len={d} data=", .{
        // The SSE default when a stream names no event. Printed rather than left
        // blank so a dump reads the same as the specification does.
        if (event.event.len == 0) "message" else event.event,
        event.data.len,
    });

    for (event.data) |byte| switch (byte) {
        '\n' => try out.writeAll("\\n"),
        '\r' => try out.writeAll("\\r"),
        else => try out.writeByte(byte),
    };

    try out.writeByte('\n');
}

/// Raw SSE bytes on stdin, decoded events on stdout. Returns the process exit
/// code: 0 at end of stream, `decode_exit_code` if the stream could not be
/// followed.
pub fn sseDump(io: std.Io, out: *std.Io.Writer) !u8 {
    var read_buffer: [chunk_size]u8 = undefined;
    var stdin: std.Io.File.Reader = .init(.stdin(), io, &read_buffer);

    var scratch: [sse.recommended_scratch]u8 = undefined;
    var data: [sse.recommended_data]u8 = undefined;
    var parser: sse.Parser = .init(&scratch, &data);

    var chunk: [chunk_size]u8 = undefined;
    while (true) {
        // A short read is how end of stream arrives here: `readSliceShort`
        // returns what it got rather than erroring, so zero means the pipe
        // closed.
        const read = try stdin.interface.readSliceShort(&chunk);
        if (read == 0) break;

        parser.feed(chunk[0..read]) catch break;
        while (parser.next()) |event| try writeEvent(event, out);
    }

    // Drain whatever the last feed completed, then report why it stopped if it
    // stopped for a reason. A parser that simply ran out of bytes has no
    // failure, and end of stream is not one.
    while (parser.next()) |event| try writeEvent(event, out);
    try out.flush();

    if (parser.failed()) |failure| {
        var stderr_buffer: [256]u8 = undefined;
        var stderr_file: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
        try stderr_file.interface.print("sse-dump: decode error: {s}\n", .{@errorName(failure)});
        try stderr_file.interface.flush();
        return decode_exit_code;
    }

    return 0;
}

// --- dev stream -----------------------------------------------------------

/// Said once per turn, however many fragments arrive.
///
/// v0.2 parses tool calls and does not execute them, exactly as scoped. A
/// frontend that said so once per fragment would say it five times for one call,
/// which is how a scoped-out feature turns into a bug report. Phase 7 renders
/// this same sentence as a notice block and reads it from here rather than
/// writing a second copy.
pub const tools_notice = "this model requested tools; tug executes tools starting v0.3";

pub const StreamOptions = struct {
    preset: []const u8 = "anthropic",
    /// Empty means the preset has no default and the user has to say. There is
    /// no model registry until Phase 6, and guessing a model name would produce
    /// a 404 that reads like tug's fault.
    model: []const u8 = "",
    prompt: []const u8 = "",
    system: ?[]const u8 = null,
    /// Resolved by the caller from the preset's environment variable. Phase 5
    /// replaces this single source with the flag → env → config → `key_cmd`
    /// chain; today it is one variable and the docs say so.
    key: []const u8 = "",
    /// ndjson `StreamEvent`s on stdout instead of model text — the Phase-1
    /// encoding, which is what Phase 8's `--json` will print.
    json: bool = false,
    debug_wire: bool = false,
};

/// The environment variable a preset's key comes from, or empty.
///
/// Exists so the executable can read one variable without importing the whole
/// provider layer to learn its name — `src/main.zig` sees `tugshell` and
/// `tugcore` and nothing below them, which is the module graph working.
pub fn envVarFor(preset: []const u8) []const u8 {
    const entry = providers.preset.find(preset) orelse return "";
    return entry.env_var;
}

/// The pieces a turn needs, sized once and owned by the caller's stack frame.
///
/// A struct rather than locals because `Stream` borrows every one of them for
/// its whole life, and a function returning a `Stream` built from its own locals
/// would be returning pointers into a dead frame.
const Turn = struct {
    scratch: [sse.recommended_scratch]u8 = undefined,
    data: [sse.recommended_data]u8 = undefined,
    read_buffer: [4096]u8 = undefined,
    body: [64 * 1024]u8 = undefined,
    url: [512]u8 = undefined,
    parser: sse.Parser = undefined,
};

/// One real turn against one real endpoint.
///
/// Returns the process exit code. Model text goes to `out`; every notice, every
/// error and the usage line go to stderr — the stream separation Phase 8 makes a
/// documented contract starts being true here.
pub fn stream(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    options: StreamOptions,
) !u8 {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const notices = &stderr_file.interface;

    const entry = providers.preset.find(options.preset) orelse {
        try notices.print("tug: no preset named '{s}'. known presets:", .{options.preset});
        for (providers.preset.table) |known| try notices.print(" {s}", .{known.name});
        try notices.writeAll("\n");
        try notices.flush();
        return 2;
    };

    if (options.model.len == 0) {
        try notices.writeAll("tug: --model is required (there is no model registry until v0.2's Phase 6)\n");
        try notices.flush();
        return 2;
    }

    if (entry.auth != .none and options.key.len == 0) {
        // A missing key is a copy-pasteable fix, not a complaint.
        try notices.print(
            "tug: no API key for {s}. set it and try again:\n\n    export {s}=...\n\n",
            .{ entry.name, entry.env_var },
        );
        try notices.flush();
        return auth_exit_code;
    }

    var turn: Turn = .{};

    const message_content = [_]proto.Content{.{ .text = options.prompt }};
    const messages = [_]proto.Message{.{ .role = .user, .content = &message_content }};
    const request: proto.Request = .{
        .model = options.model,
        .messages = &messages,
        .system = options.system,
    };

    var body_writer: std.Io.Writer = .fixed(&turn.body);
    switch (entry.shape) {
        .anthropic => try providers.anthropic.buildRequest(request, &body_writer),
        .openai => try providers.openai.buildRequest(request, &body_writer),
    }

    var headers: [4]providers.transport.Header = undefined;
    var header_count: usize = 0;
    headers[header_count] = .{ .name = "content-type", .value = "application/json" };
    header_count += 1;
    var bearer_buffer: [512]u8 = undefined;
    switch (entry.auth) {
        .none => {},
        .x_api_key => {
            headers[header_count] = .{ .name = "x-api-key", .value = options.key };
            header_count += 1;
            headers[header_count] = .{
                .name = "anthropic-version",
                .value = providers.anthropic.version_header,
            };
            header_count += 1;
        },
        .bearer => {
            const value = try std.fmt.bufPrint(&bearer_buffer, "Bearer {s}", .{options.key});
            headers[header_count] = .{ .name = "authorization", .value = value };
            header_count += 1;
        },
    }

    var client: providers.http.Http = .init(gpa, io, .{
        .debug_wire = if (options.debug_wire) notices else null,
    });
    defer client.deinit();

    var anthropic_state: providers.anthropic_map.Anthropic = .init(gpa);
    defer anthropic_state.deinit();
    var openai_state: providers.openai.OpenAi = .init(gpa);
    defer openai_state.deinit();

    turn.parser = .init(&turn.scratch, &turn.data);

    var turn_stream: providers.stream.Stream = .init(
        client.transport(),
        .{
            .url = providers.preset.url(entry, &turn.url),
            .headers = headers[0..header_count],
            .body = body_writer.buffered(),
        },
        &turn.parser,
        switch (entry.shape) {
            .anthropic => anthropic_state.mapper(),
            .openai => openai_state.mapper(),
        },
        &turn.read_buffer,
    );
    const transport = client.transport();
    defer transport.close();

    return drain(&turn_stream, out, notices, options.json);
}

/// Pulls a whole turn, writing text to `out` and everything else to `notices`.
///
/// Split out from `stream` so the offline tests can drive it with a fixture
/// transport: everything above the seam is pure, and this is the last function
/// that is.
pub fn drain(
    turn_stream: *providers.stream.Stream,
    out: *std.Io.Writer,
    notices: *std.Io.Writer,
    json: bool,
) !u8 {
    var said_tools = false;
    var last_usage: ?proto.Usage = null;
    var code: u8 = 0;

    const p = turn_stream.provider();
    while (p.nextEvent()) |event| {
        if (json) {
            // The Phase-1 encoding, byte for byte. Two producers of the same
            // bytes is how they drift, so there is one.
            try proto.ndjson.writeEvent(event, out);
            switch (event) {
                .err => |failure| code = exitCode(failure.kind),
                else => {},
            }
            continue;
        }

        switch (event) {
            .text_delta => |text| try out.writeAll(text),
            .tool_call_delta => {
                if (said_tools) continue;
                said_tools = true;
                try notices.print("\n{s}\n", .{tools_notice});
            },
            .usage => |usage| last_usage = usage,
            .stop => {},
            .err => |failure| {
                code = exitCode(failure.kind);
                try notices.print("\ntug: {s}\n", .{failure.message});
            },
        }
    }

    try out.flush();

    if (!json) {
        if (last_usage) |usage| {
            try notices.print(
                "\n{d} in, {d} out, {d} cached\n",
                .{ usage.input_tokens, usage.output_tokens, usage.cache_read_tokens },
            );
        }
    }
    try notices.flush();

    return code;
}

const testing = std.testing;

test "an event renders as one line with its newlines escaped" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeEvent(.{
        .event = "content_block_delta",
        .data = "line one\nline two",
        .id = "",
    }, &writer);

    try testing.expectEqualStrings(
        "event=content_block_delta len=17 data=line one\\nline two\n",
        writer.buffered(),
    );
}

test "an unnamed event prints the specification's default name" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeEvent(.{ .event = "", .data = "hi", .id = "" }, &writer);

    try testing.expectEqualStrings("event=message len=2 data=hi\n", writer.buffered());
}

test "every error kind has its own exit code" {
    // Phase 8 freezes these. Two kinds sharing a number would make a script's
    // `if [ $? -eq 6 ]` mean two different things.
    var seen: [8]bool = @splat(false);
    for ([_]proto.ErrKind{ .auth, .rate_limit, .server, .transport, .decode }) |kind| {
        const code = exitCode(kind);
        try testing.expect(!seen[code]);
        seen[code] = true;
    }
}

const clean_head = @embedFile("clean-turn.head");
const clean_body = @embedFile("clean-turn.sse");
const tool_head = @embedFile("tool-call-turn.head");
const tool_body = @embedFile("tool-call-turn.sse");

const Replay = struct {
    fixture: providers.fixture.Fixture,
    mapper_state: providers.anthropic_map.Anthropic,
    turn: Turn = .{},
    stream: providers.stream.Stream = undefined,

    fn init(gpa: std.mem.Allocator, head: []const u8, body: []const u8) !Replay {
        return .{
            .fixture = .{
                .head = try providers.fixture.parseHead(head),
                .body = body,
                .chunk = 17,
            },
            .mapper_state = .init(gpa),
        };
    }

    fn open(self: *Replay) *providers.stream.Stream {
        self.turn.parser = .init(&self.turn.scratch, &self.turn.data);
        self.stream = .init(
            self.fixture.transport(),
            .{ .url = "https://api.anthropic.com/v1/messages" },
            &self.turn.parser,
            self.mapper_state.mapper(),
            &self.turn.read_buffer,
        );
        return &self.stream;
    }

    fn deinit(self: *Replay) void {
        self.mapper_state.deinit();
    }
};

test "dev stream prints model text on stdout and nothing else" {
    // stdout carries the answer; every notice goes to stderr. Phase 8 makes that
    // a documented contract — this is where it starts being true.
    var replay = try Replay.init(testing.allocator, clean_head, clean_body);
    defer replay.deinit();

    var stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr.deinit();

    const code = try drain(replay.open(), &stdout.writer, &stderr.writer, false);

    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings(
        "A tugboat is rated in bollard pull: the force it can exert on a line.",
        stdout.written(),
    );
    // The usage line is a diagnostic, and `tug -p … | wc -c` has to measure the
    // answer rather than the answer plus tug's opinions about it.
    try testing.expect(std.mem.indexOf(u8, stderr.written(), "24 in") != null);
}

test "a model that asks for a tool gets one notice, not one per fragment" {
    // The Phase-4 scope line: tool_call_delta is parsed and not executed. This
    // fixture streams five argument fragments for one call.
    var replay = try Replay.init(testing.allocator, tool_head, tool_body);
    defer replay.deinit();

    var stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr.deinit();

    _ = try drain(replay.open(), &stdout.writer, &stderr.writer, false);

    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, stderr.written(), i, tools_notice)) |at| : (i = at + 1) count += 1;
    try testing.expectEqual(@as(usize, 1), count);

    // And the stream was not cut short by the notice: the usage line from the
    // end of the turn is there.
    try testing.expect(std.mem.indexOf(u8, stderr.written(), "42 out") != null);
}

test "--json puts the wire vocabulary on stdout and keeps text off it" {
    var replay = try Replay.init(testing.allocator, clean_head, clean_body);
    defer replay.deinit();

    var stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr.deinit();

    _ = try drain(replay.open(), &stdout.writer, &stderr.writer, true);

    // The same bytes the replay proof compares against, and the same bytes
    // Phase 8's --json will print.
    try testing.expect(std.mem.startsWith(u8, stdout.written(), "{\"type\":\"usage\""));
    try testing.expect(std.mem.indexOf(u8, stdout.written(), "\"type\":\"stop\"") != null);
    try testing.expectEqual(@as(usize, 0), stderr.written().len);
}

test "a failed turn exits with the code for its error kind" {
    var f: providers.fixture.Fixture = .{
        .head = .{ .status = 401, .content_type = "application/json" },
        .body = "{\"type\":\"error\",\"error\":{\"message\":\"invalid x-api-key\"}}",
        .chunk = 8,
    };
    var mapper_state: providers.anthropic_map.Anthropic = .init(testing.allocator);
    defer mapper_state.deinit();

    var turn: Turn = .{};
    turn.parser = .init(&turn.scratch, &turn.data);
    var s: providers.stream.Stream = .init(
        f.transport(),
        .{ .url = "https://api.anthropic.com/v1/messages" },
        &turn.parser,
        mapper_state.mapper(),
        &turn.read_buffer,
    );

    var stdout: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stderr.deinit();

    const code = try drain(&s, &stdout.writer, &stderr.writer, false);

    // A 401 is an `auth` failure since the taxonomy landed, and `auth` is the
    // one class the retry engine will never retry — so this exit code is also
    // the signal a script needs to stop rather than loop.
    try testing.expectEqual(auth_exit_code, code);
    try testing.expect(std.mem.indexOf(u8, stderr.written(), "invalid x-api-key") != null);
    try testing.expectEqual(@as(usize, 0), stdout.written().len);
}
