//! A transport that replays a recording.
//!
//! This file has no socket in it, and its location is the proof: the
//! confinement grep (`DR-016`) permits network code under
//! `src/providers/transport`, and this is not there. The offline half of the
//! stack cannot acquire a network without moving a file, which is the kind of
//! change a reviewer notices.
//!
//! A recording is two files: `<case>.head` holds the status line and headers
//! verbatim, `<case>.sse` holds the body verbatim. `parseHead` turns the first
//! into a `seam.Head`; the second needs no parsing, because replaying it
//! is the point.
//!
//! The interesting knob is `chunk`. A stack that only frames correctly when a
//! whole SSE event arrives in one read is a stack with a bug the network will
//! find on someone else's machine, so the tests here hand it one byte at a time
//! and at prime-numbered sizes that never land on an event boundary.

const std = @import("std");

/// Imported as `seam` rather than `transport` because `Fixture.transport()` is
/// the method that hands one out, and Zig will not have both names in scope.
const seam = @import("transport.zig");

pub const ParseError = error{NotHttp};

/// Parses a recorded status line and headers.
///
/// Deliberately not the standard library's own response-head parser: that one
/// lives behind the confinement rule (`DR-016`), and importing it here would put
/// network code in a file whose whole argument is that it has none — the gate
/// greps for the import name textually, and it is right to. Three fields is not
/// much parser.
pub fn parseHead(bytes: []const u8) ParseError!seam.Head {
    // Recorded bytes are untrusted input like any other: a fixture can be
    // hand-edited, and Phase 9's recorder writes whatever the wire said.
    @setRuntimeSafety(true);

    var lines = std.mem.splitSequence(u8, bytes, "\r\n");
    const status_line = lines.first();

    // "HTTP/1.1 200" is twelve bytes, and the status is the three at the end of
    // them. Anything shorter cannot be a status line at all.
    if (!std.mem.startsWith(u8, status_line, "HTTP/1.")) return error.NotHttp;
    if (status_line.len < 12 or status_line[8] != ' ') return error.NotHttp;
    const status = std.fmt.parseInt(u16, status_line[9..12], 10) catch return error.NotHttp;

    var head: seam.Head = .{ .status = status };
    while (lines.next()) |line| {
        // The blank line ends the head. Anything after it is body, and a
        // `.head` file should not have any.
        if (line.len == 0) break;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");

        // Servers send Content-Type, content-type and CONTENT-TYPE, and HTTP
        // says all three are the same header.
        if (std.ascii.eqlIgnoreCase(name, "content-type")) head.content_type = value;
        if (std.ascii.eqlIgnoreCase(name, "retry-after")) head.retry_after = value;
    }
    return head;
}

pub const Fixture = struct {
    head: seam.Head,
    body: []const u8,
    /// Bytes per `read`, as a cap rather than a promise.
    chunk: usize = 64,
    /// Cut the stream after this many body bytes, with `error.Closed` — a
    /// pulled cable, reproducibly.
    fail_after: ?usize = null,
    /// Set by `send`. Tests assert on the bytes that went out; the request
    /// builders' goldens are what make that assertion worth making.
    captured_request: ?seam.Request = null,

    offset: usize = 0,

    fn sendErased(context: ?*anyopaque, request: seam.Request) seam.Error!seam.Head {
        const self: *Fixture = @ptrCast(@alignCast(context.?));
        self.captured_request = request;
        return self.head;
    }

    fn readErased(context: ?*anyopaque, buffer: []u8) seam.Error!usize {
        const self: *Fixture = @ptrCast(@alignCast(context.?));

        if (self.fail_after) |cut| {
            if (self.offset >= cut) return error.Closed;
        }

        const remaining = self.body.len - self.offset;
        if (remaining == 0) return 0;

        var take = @min(@min(remaining, buffer.len), self.chunk);
        // Everything up to the cut is delivered before the error is: partial
        // output is the user's, and a fixture that swallowed it would be
        // testing the opposite of what the stack promises.
        if (self.fail_after) |cut| take = @min(take, cut - self.offset);

        @memcpy(buffer[0..take], self.body[self.offset..][0..take]);
        self.offset += take;
        return take;
    }

    fn closeErased(context: ?*anyopaque) void {
        _ = context;
    }

    const vtable: seam.Transport.VTable = .{
        .send = sendErased,
        .read = readErased,
        .close = closeErased,
    };

    pub fn transport(self: *Fixture) seam.Transport {
        return .{ .context = self, .vtable = &vtable };
    }
};

const testing = std.testing;

const clean_head = @embedFile("clean-turn.head");

test "a head parses its status and content type" {
    const head = try parseHead(
        "HTTP/1.1 200 OK\r\n" ++
            "content-type: text/event-stream; charset=utf-8\r\n" ++
            "cache-control: no-cache\r\n" ++
            "\r\n",
    );

    try testing.expectEqual(@as(u16, 200), head.status);
    try testing.expectEqualStrings("text/event-stream; charset=utf-8", head.content_type);
    try testing.expectEqualStrings("", head.retry_after);
}

test "header names are matched without regard to case" {
    const head = try parseHead(
        "HTTP/1.1 429 Too Many Requests\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Retry-After: 30\r\n" ++
            "\r\n",
    );

    try testing.expectEqual(@as(u16, 429), head.status);
    try testing.expectEqualStrings("application/json", head.content_type);
    try testing.expectEqualStrings("30", head.retry_after);
}

test "a head that is not HTTP is a parse error, not a guess" {
    try testing.expectError(error.NotHttp, parseHead("<html>502 Bad Gateway</html>\r\n\r\n"));
    try testing.expectError(error.NotHttp, parseHead("HTTP/1.1 2x0 OK\r\n\r\n"));
    try testing.expectError(error.NotHttp, parseHead(""));
    try testing.expectError(error.NotHttp, parseHead("HTTP/1.1"));
}

test "the recorded head on disk parses" {
    // The fixture and the parser have to agree, and the way that stops being
    // true is someone hand-editing a .head file into LF.
    const head = try parseHead(clean_head);
    try testing.expectEqual(@as(u16, 200), head.status);
    try testing.expectEqualStrings("text/event-stream; charset=utf-8", head.content_type);
}

test "the fixture transport replays a recorded response in chunks" {
    var f: Fixture = .{
        .head = try parseHead(clean_head),
        .body = "data: one\n\ndata: two\n\n",
        .chunk = 7,
    };
    const t = f.transport();
    defer t.close();

    const head = try t.send(.{ .url = "https://api.anthropic.com/v1/messages" });
    try testing.expectEqual(@as(u16, 200), head.status);

    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(testing.allocator);
    var buffer: [64]u8 = undefined;
    while (true) {
        const n = try t.read(&buffer);
        if (n == 0) break;
        // The chunk size is a cap, not a promise of exactly that many bytes.
        try testing.expect(n <= 7);
        try seen.appendSlice(testing.allocator, buffer[0..n]);
    }

    try testing.expectEqualStrings("data: one\n\ndata: two\n\n", seen.items);
}

test "a read never exceeds the caller's buffer, whatever the chunk says" {
    var f: Fixture = .{
        .head = .{ .status = 200 },
        .body = "0123456789",
        .chunk = 1024,
    };
    const t = f.transport();
    defer t.close();
    _ = try t.send(.{ .url = "https://example.invalid/" });

    var buffer: [3]u8 = undefined;
    try testing.expectEqual(@as(usize, 3), try t.read(&buffer));
}

test "a fixture can cut the stream where a network would have" {
    var f: Fixture = .{
        .head = .{ .status = 200, .content_type = "text/event-stream" },
        .body = "data: one\n\ndata: two\n\n",
        .chunk = 4,
        .fail_after = 6,
    };
    const t = f.transport();
    defer t.close();

    _ = try t.send(.{ .url = "https://example.invalid/" });

    var buffer: [64]u8 = undefined;
    var delivered: usize = 0;
    while (true) {
        const n = t.read(&buffer) catch |err| {
            try testing.expectEqual(seam.Error.Closed, err);
            break;
        };
        if (n == 0) return error.EndedCleanlyWhenItShouldNotHave;
        delivered += n;
    }

    // Everything up to the cut is the user's; the error arrives after it.
    try testing.expectEqual(@as(usize, 6), delivered);
}

test "the fixture keeps the request so a test can assert on the bytes sent" {
    var f: Fixture = .{ .head = .{ .status = 200 }, .body = "" };
    const t = f.transport();
    defer t.close();

    _ = try t.send(.{
        .url = "https://api.anthropic.com/v1/messages",
        .headers = &.{.{ .name = "x-api-key", .value = "k" }},
        .body = "{\"model\":\"x\"}",
    });

    try testing.expectEqualStrings("{\"model\":\"x\"}", f.captured_request.?.body);
    try testing.expectEqualStrings("x-api-key", f.captured_request.?.headers[0].name);
}

test "an empty body ends immediately rather than looping" {
    var f: Fixture = .{ .head = .{ .status = 204 }, .body = "" };
    const t = f.transport();
    defer t.close();

    _ = try t.send(.{ .url = "https://example.invalid/" });
    var buffer: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try t.read(&buffer));
    // And it keeps saying zero, because end of stream is not a one-shot event.
    try testing.expectEqual(@as(usize, 0), try t.read(&buffer));
}
