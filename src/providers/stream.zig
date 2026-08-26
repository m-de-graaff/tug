//! Transport bytes in, `StreamEvent`s out.
//!
//! The three layers of this version meet here and nowhere else: a `Transport`
//! supplies bytes, the Phase-2 `sse.Parser` frames them, and a `Mapper` — one
//! per API shape — turns a framed event into zero or more `StreamEvent`s. This
//! file knows nothing about either API, and both mappers know nothing about IO,
//! which is what makes the whole stack drivable from a directory of recordings.
//!
//! **Borrowing.** Every string in an emitted event points into the parser's
//! buffer or the mapper's own storage, and is valid until the next call to
//! `next`. That is the contract `tugcore.Provider` already documents, and it is
//! why the streaming path allocates nothing per delta.
//!
//! **The head is a fork in the road.** A 200 carries SSE; a 401 carries a JSON
//! error document; a proxy in the way carries HTML. Only the first is fed to the
//! framer. Feeding an error document to an SSE parser produces a decode error
//! about the framing of a message that was never a message, and the user is then
//! told their stream was malformed when in fact their key was.

const std = @import("std");

const core = @import("tugcore");
const proto = @import("tugproto");

const seam = @import("transport.zig");
const sse = @import("sse.zig");
const taxonomy = @import("taxonomy.zig");

/// Where a mapper puts what it produced.
///
/// Four slots because the largest real case is three: Anthropic's
/// `message_delta` carries a stop reason and a usage update, and an SSE `error`
/// event produces an error and a stop. A fixed array rather than a list because
/// a mapper wanting to emit an unbounded number of events for one SSE event
/// would be a mapper doing something else.
pub const Emit = struct {
    items: [4]proto.StreamEvent = undefined,
    len: usize = 0,

    /// ponytail: silently drops past four. A mapper cannot usefully report the
    /// overflow — it has no error channel by design — and the alternative,
    /// growing the array, is a heap allocation on the per-delta path to hold
    /// events no API sends. If a fifth is ever needed, the array gets bigger.
    pub fn push(self: *Emit, event: proto.StreamEvent) void {
        if (self.len == self.items.len) return;
        self.items[self.len] = event;
        self.len += 1;
    }
};

pub const Mapper = struct {
    context: ?*anyopaque = null,

    /// Turns one framed SSE event into zero or more stream events.
    ///
    /// Never fails. A mapper that cannot understand an event emits an `err`
    /// event, because that is the failure the renderer already knows how to
    /// draw — the same argument `tugcore.Provider` makes for having no error
    /// union.
    map: *const fn (context: ?*anyopaque, event: sse.ServerEvent, out: *Emit) void,

    /// Turns a non-200 response body into something a human can act on.
    ///
    /// `out` is scratch the caller owns; the returned slice points into it or
    /// into a string literal, and lives until the next call.
    errorMessage: *const fn (context: ?*anyopaque, status: u16, body: []const u8, out: []u8) []const u8,
};

/// The most of an error document that is read before giving up on it.
///
/// A provider answering an error with a megabyte is a provider trying to make
/// tug allocate; the useful sentence is always in the first few hundred bytes.
pub const max_error_body = 4096;

/// The longest error message handed to a frontend: the provider's sentence plus
/// tug's action hint. Anything past this loses the hint and keeps the sentence,
/// because what happened is worth more than what to do about it.
pub const max_message = 1024;

pub const Stream = struct {
    transport: seam.Transport,
    request: seam.Request,
    parser: *sse.Parser,
    mapper: Mapper,
    read_buffer: []u8,

    /// The preset's environment variable, so an `auth` failure can name the one
    /// a user actually has to set. Empty for a preset that needs no key.
    env_var: []const u8 = "",
    /// Seconds since the epoch, supplied by the frontend.
    ///
    /// A `Retry-After` may be an HTTP date, and turning one into a wait needs to
    /// know what time it is. Everything above the transport seam is a pure
    /// function of bytes (`DR-017`), so the clock is passed in rather than read
    /// — which is also what makes the date case reproducible in a fixture test.
    now_epoch_s: i64 = 0,

    state: State = .head,
    pending: Emit = .{},
    pending_index: usize = 0,

    error_body: [max_error_body]u8 = undefined,
    error_message: [512]u8 = undefined,
    hinted_message: [max_message]u8 = undefined,

    const State = enum { head, body, done };

    pub fn init(
        transport: seam.Transport,
        request: seam.Request,
        parser: *sse.Parser,
        mapper: Mapper,
        read_buffer: []u8,
    ) Stream {
        return .{
            .transport = transport,
            .request = request,
            .parser = parser,
            .mapper = mapper,
            .read_buffer = read_buffer,
        };
    }

    fn nextErased(context: ?*anyopaque) ?proto.StreamEvent {
        const self: *Stream = @ptrCast(@alignCast(context.?));
        return self.next();
    }

    pub fn provider(self: *Stream) core.Provider {
        return .{ .context = self, .next = nextErased };
    }

    pub fn next(self: *Stream) ?proto.StreamEvent {
        while (true) {
            // Anything the mapper produced last time comes out before any more
            // bytes are read. A mapper can emit three events for one framed
            // event, and the caller takes them one at a time.
            if (self.pending_index < self.pending.len) {
                defer self.pending_index += 1;
                return self.pending.items[self.pending_index];
            }
            self.pending = .{};
            self.pending_index = 0;

            switch (self.state) {
                .done => return null,
                .head => self.openStream(),
                .body => self.pump(),
            }

            // A step that produced nothing and reached the end has nothing left
            // to say; without this the loop would spin on `done`.
            if (self.pending.len == 0 and self.state == .done) return null;
        }
    }

    fn openStream(self: *Stream) void {
        const head = self.transport.send(self.request) catch |err| {
            self.fail(transportKind(err), transportMessage(err));
            return;
        };

        if (head.status == 200) {
            self.state = .body;
            return;
        }

        // Not a stream. Read the document, hand it to the mapper for a sentence,
        // and stop — the framer never sees a byte of it.
        const body = self.drainErrorBody();
        const message = self.mapper.errorMessage(
            self.mapper.context,
            head.status,
            body,
            &self.error_message,
        );

        const kind = taxonomy.fromStatus(head.status);
        self.pending.push(.{
            .err = .{
                .kind = kind,
                .message = self.withHint(kind, message),
                // Only ever present on a rate limit in practice, but the header is
                // legal on a 503 too and honouring it there costs nothing.
                .retry_after_ms = taxonomy.retryAfterMs(head.retry_after, self.now_epoch_s),
            },
        });
        self.state = .done;
    }

    /// Appends the taxonomy's action hint to the provider's own message.
    ///
    /// The provider's words first, because they know what went wrong; tug's
    /// after, because it knows what to do about it. An auth failure that does
    /// not name the variable to set is an error message that has made the user
    /// go and look up what tug already knew.
    fn withHint(self: *Stream, kind: proto.ErrKind, message: []const u8) []const u8 {
        var hint_buffer: [256]u8 = undefined;
        const advice = taxonomy.hint(kind, self.env_var, &hint_buffer);

        var writer: std.Io.Writer = .fixed(&self.hinted_message);
        writer.print("{s} - {s}", .{ message, advice }) catch {
            // No room for both. The provider's sentence is the one that survives:
            // it says what happened, and the hint only says what to do about it.
            return message;
        };
        return writer.buffered();
    }

    /// Reads an error document, bounded. Read failures are not reported: the
    /// status code is the story, and "the error body was truncated" is not
    /// something a user can act on.
    fn drainErrorBody(self: *Stream) []const u8 {
        var used: usize = 0;
        while (used < self.error_body.len) {
            const n = self.transport.read(self.error_body[used..]) catch break;
            if (n == 0) break;
            used += n;
        }
        return self.error_body[0..used];
    }

    fn pump(self: *Stream) void {
        // Whatever the last feed completed comes out first — a single read can
        // complete several events, and the parser hands them over one by one.
        if (self.parser.next()) |event| {
            self.mapper.map(self.mapper.context, event, &self.pending);
            return;
        }

        const n = self.transport.read(self.read_buffer) catch |err| {
            self.fail(transportKind(err), transportMessage(err));
            return;
        };

        if (n == 0) {
            // End of stream. A stream that ended without a stop event ended
            // early, and saying so is more use than silence — but a provider
            // that already sent one has said everything it was going to.
            self.state = .done;
            return;
        }

        self.parser.feed(self.read_buffer[0..n]) catch {
            self.fail(.decode, "the response was not valid server-sent events");
            return;
        };

        if (self.parser.next()) |event| {
            self.mapper.map(self.mapper.context, event, &self.pending);
        }
    }

    fn fail(self: *Stream, kind: proto.ErrKind, message: []const u8) void {
        self.pending.push(.{ .err = .{ .kind = kind, .message = message } });
        self.state = .done;
    }
};

/// Transport failures, in the vocabulary a user reads. `taxonomy.zig` owns the
/// mapping; this is the one call site.
fn transportKind(err: seam.Error) proto.ErrKind {
    return taxonomy.fromTransport(err);
}

fn transportMessage(err: seam.Error) []const u8 {
    return switch (err) {
        error.Connect => "could not reach the provider",
        error.Tls => "the TLS handshake failed",
        error.Timeout => "the provider stopped sending",
        error.Closed => "the connection closed mid-stream",
        error.Protocol => "the provider did not answer with HTTP tug can follow",
        error.Refused => "tug refused to make this request",
        error.Canceled => "canceled",
        error.OutOfMemory => "out of memory",
    };
}

const testing = std.testing;
const fixture = @import("fixture.zig");

/// A mapper that turns every event named "chunk" into a text delta of its data
/// and "done" into a stop. Enough to prove the glue; the real ones are next.
const Echo = struct {
    fn mapErased(context: ?*anyopaque, event: sse.ServerEvent, out: *Emit) void {
        _ = context;
        if (std.mem.eql(u8, event.event, "chunk")) out.push(.{ .text_delta = event.data });
        if (std.mem.eql(u8, event.event, "done")) out.push(.{ .stop = .{ .reason = .end_turn } });
    }

    fn errorMessageErased(context: ?*anyopaque, status: u16, body: []const u8, out: []u8) []const u8 {
        _ = context;
        _ = status;
        const take = @min(body.len, out.len);
        @memcpy(out[0..take], body[0..take]);
        return out[0..take];
    }

    fn mapper() Mapper {
        return .{ .context = null, .map = mapErased, .errorMessage = errorMessageErased };
    }
};

const Harness = struct {
    scratch: [sse.recommended_scratch]u8 = undefined,
    data: [sse.recommended_data]u8 = undefined,
    read_buffer: [64]u8 = undefined,
    parser: sse.Parser = undefined,
    stream: Stream = undefined,
    env_var: []const u8 = "",
    now_epoch_s: i64 = 0,

    fn open(self: *Harness, f: *fixture.Fixture) core.Provider {
        self.parser = .init(&self.scratch, &self.data);
        self.stream = .init(
            f.transport(),
            .{ .url = "https://example.invalid/v1/messages" },
            &self.parser,
            Echo.mapper(),
            &self.read_buffer,
        );
        self.stream.env_var = self.env_var;
        self.stream.now_epoch_s = self.now_epoch_s;
        return self.stream.provider();
    }
};

test "bytes from a transport arrive as stream events" {
    var f: fixture.Fixture = .{
        .head = .{ .status = 200, .content_type = "text/event-stream" },
        .body = "event: chunk\ndata: hello\n\n" ++
            "event: chunk\ndata:  world\n\n" ++
            "event: done\ndata: {}\n\n",
        // One byte at a time. If the glue only works when an event arrives
        // whole, this is the test that says so.
        .chunk = 1,
    };

    var harness: Harness = .{};
    const p = harness.open(&f);

    try testing.expectEqualStrings("hello", p.nextEvent().?.text_delta);
    try testing.expectEqualStrings(" world", p.nextEvent().?.text_delta);
    try testing.expectEqual(proto.StopReason.end_turn, p.nextEvent().?.stop.reason);
    try testing.expect(p.nextEvent() == null);
}

test "the same bytes at a different chunk size give the same events" {
    // The chunking-invariance rule, one layer up from the parser that already
    // has it: a read boundary must be invisible to everything above the seam.
    const body = "event: chunk\ndata: alpha\n\n" ++
        "event: chunk\ndata: beta\n\n" ++
        "event: done\ndata: {}\n\n";

    for ([_]usize{ 1, 3, 7, 64, 4096 }) |chunk| {
        var f: fixture.Fixture = .{
            .head = .{ .status = 200, .content_type = "text/event-stream" },
            .body = body,
            .chunk = chunk,
        };
        var harness: Harness = .{};
        const p = harness.open(&f);

        try testing.expectEqualStrings("alpha", p.nextEvent().?.text_delta);
        try testing.expectEqualStrings("beta", p.nextEvent().?.text_delta);
        try testing.expectEqual(proto.StopReason.end_turn, p.nextEvent().?.stop.reason);
        try testing.expect(p.nextEvent() == null);
    }
}

test "a transport error becomes an err event and then the end" {
    var f: fixture.Fixture = .{
        .head = .{ .status = 200, .content_type = "text/event-stream" },
        .body = "event: chunk\ndata: partial\n\nevent: chunk\ndata: never arrives\n\n",
        .chunk = 8,
        // 28 bytes is exactly the first event including its blank dispatch
        // line. Cutting one byte earlier would test something else entirely —
        // a stream that died before saying anything, which has no partial
        // output to preserve.
        .fail_after = 28,
    };

    var harness: Harness = .{};
    const p = harness.open(&f);

    // Everything that arrived before the cut is delivered first — partial
    // output is the user's — and only then the error.
    try testing.expectEqualStrings("partial", p.nextEvent().?.text_delta);

    const failure = p.nextEvent().?.err;
    try testing.expectEqual(proto.ErrKind.transport, failure.kind);
    try testing.expect(p.nextEvent() == null);
}

test "a non-200 head never reaches the SSE parser" {
    var f: fixture.Fixture = .{
        .head = .{ .status = 401, .content_type = "application/json" },
        .body = "{\"error\":{\"message\":\"invalid x-api-key\"}}",
        .chunk = 64,
    };

    var harness: Harness = .{};
    const p = harness.open(&f);

    const failure = p.nextEvent().?.err;
    try testing.expectEqual(proto.ErrKind.auth, failure.kind);
    try testing.expect(std.mem.indexOf(u8, failure.message, "invalid x-api-key") != null);
    try testing.expect(p.nextEvent() == null);
}

test "a 401 names the variable the user has to set" {
    // The M2 placeholder called every non-200 a server error and offered no
    // advice. This is the test that retires it.
    var f: fixture.Fixture = .{
        .head = .{ .status = 401, .content_type = "application/json" },
        .body = "{\"error\":{\"message\":\"invalid x-api-key\"}}",
        .chunk = 64,
    };

    var harness: Harness = .{};
    harness.env_var = "ANTHROPIC_API_KEY";
    const p = harness.open(&f);

    const failure = p.nextEvent().?.err;
    try testing.expectEqual(proto.ErrKind.auth, failure.kind);
    // The provider's words first, tug's advice after.
    try testing.expect(std.mem.indexOf(u8, failure.message, "invalid x-api-key") != null);
    try testing.expect(std.mem.indexOf(u8, failure.message, "export ANTHROPIC_API_KEY=") != null);
}

test "a 429 carries the wait the server asked for" {
    var f: fixture.Fixture = .{
        .head = .{ .status = 429, .content_type = "application/json", .retry_after = "30" },
        .body = "{\"error\":{\"message\":\"slow down\"}}",
        .chunk = 64,
    };

    var harness: Harness = .{};
    const p = harness.open(&f);

    const failure = p.nextEvent().?.err;
    try testing.expectEqual(proto.ErrKind.rate_limit, failure.kind);
    try testing.expectEqual(@as(?u32, 30_000), failure.retry_after_ms);
}

test "a 429 with no header carries no instruction" {
    // Which is the difference `DR-019` acts on: tug waits when told how long and
    // refuses to guess when it is not.
    var f: fixture.Fixture = .{
        .head = .{ .status = 429, .content_type = "application/json" },
        .body = "{\"error\":{\"message\":\"slow down\"}}",
        .chunk = 64,
    };

    var harness: Harness = .{};
    const p = harness.open(&f);

    const failure = p.nextEvent().?.err;
    try testing.expectEqual(proto.ErrKind.rate_limit, failure.kind);
    try testing.expect(failure.retry_after_ms == null);
}

test "a 500 is a server error and carries no instruction" {
    var f: fixture.Fixture = .{
        .head = .{ .status = 500, .content_type = "application/json" },
        .body = "{\"error\":{\"message\":\"Internal server error\"}}",
        .chunk = 64,
    };

    var harness: Harness = .{};
    const p = harness.open(&f);

    const failure = p.nextEvent().?.err;
    try testing.expectEqual(proto.ErrKind.server, failure.kind);
    try testing.expect(failure.retry_after_ms == null);
}

test "a retry-after given as a date needs the clock the frontend passed in" {
    var f: fixture.Fixture = .{
        .head = .{
            .status = 429,
            .content_type = "application/json",
            .retry_after = "Tue, 14 Nov 2023 22:14:20 GMT",
        },
        .body = "{\"error\":{\"message\":\"slow down\"}}",
        .chunk = 64,
    };

    var harness: Harness = .{};
    harness.now_epoch_s = 1_700_000_000; // 2023-11-14T22:13:20Z
    const p = harness.open(&f);

    try testing.expectEqual(@as(?u32, 60_000), p.nextEvent().?.err.retry_after_ms);
}

test "an enormous error body is bounded rather than buffered" {
    const huge = "x" ** (max_error_body * 2);
    var f: fixture.Fixture = .{
        .head = .{ .status = 500, .content_type = "text/html" },
        .body = huge,
        .chunk = 512,
    };

    var harness: Harness = .{};
    const p = harness.open(&f);

    const failure = p.nextEvent().?.err;
    try testing.expect(failure.message.len <= max_message);
    try testing.expect(p.nextEvent() == null);
}

test "a stream that ends without a stop event ends anyway" {
    var f: fixture.Fixture = .{
        .head = .{ .status = 200, .content_type = "text/event-stream" },
        .body = "event: chunk\ndata: cut short\n\n",
        .chunk = 16,
    };

    var harness: Harness = .{};
    const p = harness.open(&f);

    try testing.expectEqualStrings("cut short", p.nextEvent().?.text_delta);
    try testing.expect(p.nextEvent() == null);
    // And it keeps saying null, because a provider is an iterator that ends
    // once.
    try testing.expect(p.nextEvent() == null);
}
