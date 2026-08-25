//! Server-sent events: bytes in, `ServerEvent`s out.
//!
//! This is v0.2's untrusted input decoder, and it is built like the other one
//! (`src/shell/input/decoder.zig`): a pure function of caller-owned buffers, no
//! IO, no allocation, no blocking. Everything that makes stream framing hard —
//! a read that splits a field name in half, a server that terminates lines with
//! bare CR, a keepalive comment every fifteen seconds — is a property this can
//! be tested for rather than a situation to reproduce by hand.
//!
//! Three rules, the same three the input decoder holds:
//!
//! **Partial input is not an error.** `next` returns null when the buffer holds
//! the beginning of something. Feed more and ask again. A field split across two
//! reads parses as one field.
//!
//! **Never buffer without limit.** A server that opens a line and never ends it
//! gets a `LineTooLong`, not a growing allocation. Both buffers belong to the
//! caller and neither grows.
//!
//! **Framing only.** What a `data:` payload *means* is the provider mapper's
//! job in Phase 4. This file has never heard of JSON, and that is what lets one
//! parser serve two very different APIs.
//!
//! A returned `ServerEvent` borrows from the parser's buffers and is valid until
//! the next `feed` or `next` call. Consumers map it immediately; nothing holds
//! one. That is what keeps the whole streaming path allocation-free.

const std = @import("std");

/// One dispatched event.
///
/// `event` is empty when the stream did not name one — the SSE default is the
/// name `message`, but naming it here would mean this type could not say
/// "the server said nothing", which the mappers care about.
pub const ServerEvent = struct {
    event: []const u8,
    data: []const u8,
    /// The last event id seen on the stream, which persists across events by
    /// specification. Empty until one arrives.
    id: []const u8,
    /// The server's reconnection hint, in milliseconds, when the event carried
    /// one. tug does not reconnect in v0.2; the field exists because dropping a
    /// field the wire carries is how a parser becomes lossy.
    retry: ?u32 = null,
};

pub const Error = error{
    /// A single line exceeded the scratch buffer. The stream is not framed the
    /// way it claims to be, or the server is misbehaving; either way this is a
    /// `decode` error to the taxonomy above.
    LineTooLong,
    /// The accumulated `data:` field for one event exceeded the data buffer.
    DataTooLong,
    /// An `event:` or `id:` value exceeded the parser's inline storage. Both are
    /// short by nature — `content_block_delta` is nineteen bytes.
    FieldTooLong,
};

/// How much scratch a real stream wants. One line, with room for a large JSON
/// payload on it: Anthropic's `message_start` carries the whole request echo.
pub const recommended_scratch = 64 * 1024;

/// How much data buffer a real stream wants. Multi-line `data:` fields are rare
/// in these APIs but legal everywhere.
pub const recommended_data = 64 * 1024;

/// Inline storage for `event:` and `id:` values. A cap rather than a caller
/// buffer because these are names, not payloads; overflow is an error rather
/// than a truncation, because a silently shortened event name would route to the
/// wrong mapper arm.
const name_capacity = 256;

pub const Parser = struct {
    /// Caller-owned. Holds bytes that have arrived and not yet been consumed
    /// into a line.
    scratch: []u8,
    /// Caller-owned. Accumulates the joined `data:` field of the event being
    /// built.
    data: []u8,

    len: usize = 0,
    /// How much of `scratch[0..len]` has already been turned into lines.
    pos: usize = 0,

    data_len: usize = 0,
    event_buf: [name_capacity]u8 = undefined,
    event_len: usize = 0,
    id_buf: [name_capacity]u8 = undefined,
    id_len: usize = 0,
    retry: ?u32 = null,

    /// True once the first byte has been examined, so the byte-order mark is
    /// skipped exactly once and a BOM inside a payload stays payload.
    started: bool = false,
    /// Set when the previous `next` returned an event, so its buffers are held
    /// intact for the caller and cleared only when the caller asks for more.
    dispatched: bool = false,

    pub fn init(scratch: []u8, data: []u8) Parser {
        return .{ .scratch = scratch, .data = data };
    }

    /// Copies `bytes` in. Fails only when a single unconsumed line does not fit.
    pub fn feed(self: *Parser, bytes: []const u8) Error!void {
        @setRuntimeSafety(true);

        self.compact();

        if (bytes.len > self.scratch.len - self.len) return error.LineTooLong;

        @memcpy(self.scratch[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    /// The next dispatched event, or null when the buffer holds no complete one.
    ///
    /// Null does not mean the stream ended — it means feed more bytes and ask
    /// again. The transport is what knows about end of stream.
    pub fn next(self: *Parser) ?ServerEvent {
        @setRuntimeSafety(true);

        if (self.dispatched) {
            // The previous event's slices were live until now. Reset what the
            // specification resets between events; `id` deliberately persists.
            self.dispatched = false;
            self.event_len = 0;
            self.data_len = 0;
            self.retry = null;
        }

        while (self.takeLine()) |line| {
            if (line.len == 0) {
                // A blank line dispatches — unless nothing accumulated, which is
                // what a bare `event: ping` is. The specification drops those,
                // and so does every consumer that would otherwise filter them.
                if (self.data_len == 0) {
                    self.event_len = 0;
                    self.retry = null;
                    continue;
                }

                self.dispatched = true;
                return .{
                    .event = self.event_buf[0..self.event_len],
                    .data = self.data[0..self.data_len],
                    .id = self.id_buf[0..self.id_len],
                    .retry = self.retry,
                };
            }

            self.field(line) catch {
                // An overlong name or payload is a stream tug cannot follow, and
                // `next` has no error union by design — the same shape the input
                // decoder uses. Phase 4 surfaces it as a `decode` event; here it
                // simply stops producing.
                return null;
            };
        }

        return null;
    }

    /// Moves consumed bytes out of the way so a long stream reuses the front of
    /// the buffer rather than running off the end of it.
    fn compact(self: *Parser) void {
        if (self.pos == 0) return;

        const rest = self.len - self.pos;
        std.mem.copyForwards(u8, self.scratch[0..rest], self.scratch[self.pos..self.len]);
        self.len = rest;
        self.pos = 0;
    }

    /// One line, without its terminator, or null when none is complete.
    ///
    /// All three terminators are valid SSE: LF, CRLF, and a bare CR. A trailing
    /// CR at the very end of what has arrived is held back rather than treated
    /// as a terminator, because the LF that would pair with it may be in the
    /// next chunk — the single case that makes chunk boundaries visible if it is
    /// got wrong.
    fn takeLine(self: *Parser) ?[]const u8 {
        @setRuntimeSafety(true);

        if (!self.started and self.len - self.pos >= 3) {
            self.started = true;
            if (std.mem.eql(u8, self.scratch[self.pos..][0..3], "\xEF\xBB\xBF")) self.pos += 3;
        }

        var index = self.pos;
        while (index < self.len) : (index += 1) {
            switch (self.scratch[index]) {
                '\n' => {
                    const line = self.scratch[self.pos..index];
                    self.pos = index + 1;
                    self.started = true;
                    return line;
                },
                '\r' => {
                    // The pairing LF may not have arrived yet.
                    if (index + 1 == self.len) return null;

                    const line = self.scratch[self.pos..index];
                    self.pos = index + 1;
                    if (self.scratch[self.pos] == '\n') self.pos += 1;
                    self.started = true;
                    return line;
                },
                else => {},
            }
        }

        // No terminator in what has arrived. If the buffer is full, it never
        // will be: the line is longer than the caller is willing to hold.
        return null;
    }

    /// One non-blank line: a comment, or a field and its value.
    fn field(self: *Parser, line: []const u8) Error!void {
        @setRuntimeSafety(true);

        // A line beginning with a colon is a comment. Servers send these as
        // keepalives; they are not events and must reset nothing.
        if (line[0] == ':') return;

        const colon = std.mem.indexOfScalar(u8, line, ':');
        const name = if (colon) |at| line[0..at] else line;
        var value = if (colon) |at| line[at + 1 ..] else line[0..0];

        // Exactly one leading space is part of the framing; a second is data.
        // mutated

        if (std.mem.eql(u8, name, "data")) {
            // Multi-line data joins with a newline — between the lines, never
            // before the first, or every payload gains a leading blank line.
            if (self.data_len > 0) {
                if (self.data_len + 1 > self.data.len) return error.DataTooLong;
                self.data[self.data_len] = '\n';
                self.data_len += 1;
            }
            if (self.data_len + value.len > self.data.len) return error.DataTooLong;
            @memcpy(self.data[self.data_len..][0..value.len], value);
            self.data_len += value.len;
            return;
        }

        if (std.mem.eql(u8, name, "event")) {
            if (value.len > self.event_buf.len) return error.FieldTooLong;
            @memcpy(self.event_buf[0..value.len], value);
            self.event_len = value.len;
            return;
        }

        if (std.mem.eql(u8, name, "id")) {
            // The specification ignores an id containing a NUL rather than
            // treating it as a terminator.
            if (std.mem.indexOfScalar(u8, value, 0) != null) return;
            if (value.len > self.id_buf.len) return error.FieldTooLong;
            @memcpy(self.id_buf[0..value.len], value);
            self.id_len = value.len;
            return;
        }

        if (std.mem.eql(u8, name, "retry")) {
            // Not a number is not an error: the specification says ignore, and a
            // reconnection hint tug does not act on is not worth failing over.
            self.retry = std.fmt.parseInt(u32, value, 10) catch null;
            return;
        }

        // Any other field name is ignored, which is what lets a server add one
        // without breaking every client.
    }
};

const testing = std.testing;

/// Duplicates each event's slices: a `ServerEvent` borrows from the parser's
/// buffers and is valid only until the next call.
fn collect(input: []const u8, into: *std.ArrayList(ServerEvent)) !void {
    var scratch: [4096]u8 = undefined;
    var data: [4096]u8 = undefined;
    var parser: Parser = .init(&scratch, &data);

    try parser.feed(input);
    while (parser.next()) |event| try into.append(testing.allocator, .{
        .event = try testing.allocator.dupe(u8, event.event),
        .data = try testing.allocator.dupe(u8, event.data),
        .id = try testing.allocator.dupe(u8, event.id),
        .retry = event.retry,
    });
}

fn freeAll(events: *std.ArrayList(ServerEvent)) void {
    for (events.items) |event| {
        testing.allocator.free(event.event);
        testing.allocator.free(event.data);
        testing.allocator.free(event.id);
    }
    events.deinit(testing.allocator);
}

test "a minimal event dispatches on the blank line" {
    var events: std.ArrayList(ServerEvent) = .empty;
    defer freeAll(&events);

    try collect("data: hello\n\n", &events);

    try testing.expectEqual(@as(usize, 1), events.items.len);
    try testing.expectEqualStrings("hello", events.items[0].data);
    try testing.expectEqualStrings("", events.items[0].event);
}

test "fields ride along with the event" {
    var events: std.ArrayList(ServerEvent) = .empty;
    defer freeAll(&events);

    try collect("event: content_block_delta\nid: 7\nretry: 2500\ndata: {}\n\n", &events);

    try testing.expectEqual(@as(usize, 1), events.items.len);
    try testing.expectEqualStrings("content_block_delta", events.items[0].event);
    try testing.expectEqualStrings("7", events.items[0].id);
    try testing.expectEqual(@as(?u32, 2500), events.items[0].retry);
    try testing.expectEqualStrings("{}", events.items[0].data);
}

test "an event with no data dispatches nothing" {
    var events: std.ArrayList(ServerEvent) = .empty;
    defer freeAll(&events);

    // Anthropic sends bare `event: ping` lines. Turning each one into an event
    // would make every consumer filter them.
    try collect("event: ping\n\n", &events);

    try testing.expectEqual(@as(usize, 0), events.items.len);
}

test "a ping between two events does not leak into the second" {
    var events: std.ArrayList(ServerEvent) = .empty;
    defer freeAll(&events);

    try collect("event: a\ndata: one\n\nevent: ping\n\ndata: two\n\n", &events);

    try testing.expectEqual(@as(usize, 2), events.items.len);
    try testing.expectEqualStrings("a", events.items[0].event);
    try testing.expectEqualStrings("", events.items[1].event);
    try testing.expectEqualStrings("two", events.items[1].data);
}

test "partial input is not an error" {
    var scratch: [4096]u8 = undefined;
    var data: [4096]u8 = undefined;
    var parser: Parser = .init(&scratch, &data);

    try parser.feed("data: hel");
    try testing.expect(parser.next() == null);

    try parser.feed("lo\n\n");
    try testing.expectEqualStrings("hello", parser.next().?.data);
    try testing.expect(parser.next() == null);
}

test "an absurd line is a decode error, not unbounded buffering" {
    var scratch: [128]u8 = undefined;
    var data: [128]u8 = undefined;
    var parser: Parser = .init(&scratch, &data);

    var flood: [256]u8 = undefined;
    @memset(&flood, 'x');

    try testing.expectError(error.LineTooLong, parser.feed(&flood));
}

test "a long stream reuses the front of the buffer" {
    var scratch: [64]u8 = undefined;
    var data: [64]u8 = undefined;
    var parser: Parser = .init(&scratch, &data);

    // Forty events through a buffer that holds one: without compaction this
    // overflows on the third.
    var count: usize = 0;
    for (0..40) |_| {
        try parser.feed("data: hello\n\n");
        while (parser.next()) |event| {
            try testing.expectEqualStrings("hello", event.data);
            count += 1;
        }
    }

    try testing.expectEqual(@as(usize, 40), count);
}
