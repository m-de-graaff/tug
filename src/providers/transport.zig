//! The transport seam — `DR-017`.
//!
//! Three functions: send a request, read the body until it says zero, close.
//! Two implementations. `transport/http.zig` opens a socket and is the only
//! file in the repository that may; `fixture.zig` replays recorded bytes and is
//! deliberately outside the confinement grep's allowance, so the gate itself
//! proves the offline path has no network in it.
//!
//! The head arriving before the body is the point of the shape. A 200 carries
//! `text/event-stream`; a 401 carries a JSON error document; a proxy in the way
//! carries HTML. Only the first of those may reach the SSE parser, and a seam
//! that returned only a reader would have nowhere to say which one arrived.
//!
//! Nothing here takes an allocator, an `Io`, or a clock. Everything above this
//! seam is a pure function of bytes, which is what lets CI drive the whole
//! provider stack from a directory of recordings.

const std = @import("std");

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// One request. Borrowed throughout: the caller builds it in a per-request
/// arena that outlives the response, so this type owns nothing and frees
/// nothing.
///
/// There is no method field. A harness that talks to two chat APIs makes
/// exactly one shape of call, and a field with one possible value is a field a
/// reader has to check for other values.
pub const Request = struct {
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
};

/// The response head, before any body byte is read.
///
/// Three fields, and each earns its place: `status` decides whether the body is
/// SSE or an error document, `content_type` catches a proxy's HTML error page
/// before it reaches the SSE parser, and `retry_after` is the raw header value
/// because Phase 5 parses both the seconds form and the HTTP-date form and this
/// layer should not know that either form exists.
pub const Head = struct {
    status: u16,
    content_type: []const u8 = "",
    retry_after: []const u8 = "",
};

/// What a transport can fail with.
///
/// Deliberately not the user-facing taxonomy: `tugproto.ErrKind` is five
/// variants a human can act on, and mapping onto it is Phase 5's job with the
/// status code in hand. These are the failures the transport itself can
/// actually distinguish.
pub const Error = error{
    /// The name did not resolve, or the connection was refused or reset.
    Connect,
    /// A TLS handshake or certificate failure.
    Tls,
    /// Connect, header or read timeout — including the stall detector.
    Timeout,
    /// The stream ended in the middle of something.
    Closed,
    /// The response was not HTTP tug can follow: a redirect, headers that do
    /// not parse, an unsupported transfer encoding.
    Protocol,
    /// tug refused to make the call: plaintext to a non-loopback host, or a URL
    /// scheme that is not http or https. A refusal is a decision, not a
    /// failure, and it reads differently in a log.
    Refused,
    /// The cancel token was set.
    Canceled,
    OutOfMemory,
};

pub const Transport = struct {
    context: ?*anyopaque = null,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Sends the whole request and blocks until the response head arrives.
        send: *const fn (context: ?*anyopaque, request: Request) Error!Head,
        /// Fills `buffer` with body bytes. Returns 0 at end of stream, and only
        /// at end of stream — a short read is a short read, not an ending.
        read: *const fn (context: ?*anyopaque, buffer: []u8) Error!usize,
        /// Releases everything the request holds. Safe to call twice, and safe
        /// to call after an error, which is what makes `defer t.close()` the
        /// only cleanup any caller needs.
        close: *const fn (context: ?*anyopaque) void,
    };

    pub fn send(self: Transport, request: Request) Error!Head {
        return self.vtable.send(self.context, request);
    }

    pub fn read(self: Transport, buffer: []u8) Error!usize {
        return self.vtable.read(self.context, buffer);
    }

    pub fn close(self: Transport) void {
        return self.vtable.close(self.context);
    }
};

const testing = std.testing;

/// A transport that answers one canned head and then no bytes at all. Enough to
/// prove the vtable dispatches; `fixture.zig` is the real one.
const Silent = struct {
    head: Head,
    closed: bool = false,

    fn sendErased(context: ?*anyopaque, request: Request) Error!Head {
        const self: *Silent = @ptrCast(@alignCast(context.?));
        // A transport is handed a whole request and reads it once.
        std.debug.assert(request.url.len > 0);
        return self.head;
    }

    fn readErased(context: ?*anyopaque, buffer: []u8) Error!usize {
        _ = context;
        _ = buffer;
        return 0;
    }

    fn closeErased(context: ?*anyopaque) void {
        const self: *Silent = @ptrCast(@alignCast(context.?));
        self.closed = true;
    }

    const vtable: Transport.VTable = .{
        .send = sendErased,
        .read = readErased,
        .close = closeErased,
    };

    fn transport(self: *Silent) Transport {
        return .{ .context = self, .vtable = &vtable };
    }
};

test "a transport hands back a head, then end of stream" {
    var silent: Silent = .{ .head = .{ .status = 200, .content_type = "text/event-stream" } };
    const t = silent.transport();

    const head = try t.send(.{ .url = "https://example.invalid/v1/messages" });
    try testing.expectEqual(@as(u16, 200), head.status);
    try testing.expectEqualStrings("text/event-stream", head.content_type);

    var buffer: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try t.read(&buffer));

    t.close();
    try testing.expect(silent.closed);
}

test "close is safe to call twice" {
    // `defer t.close()` after an error is the only cleanup pattern callers get,
    // so a double close has to be a no-op rather than a decision each caller
    // has to remember not to make.
    var silent: Silent = .{ .head = .{ .status = 200 } };
    const t = silent.transport();

    t.close();
    t.close();
    try testing.expect(silent.closed);
}

test "a request defaults to no headers and no body" {
    const request: Request = .{ .url = "http://127.0.0.1:11434/v1/chat/completions" };
    try testing.expectEqual(@as(usize, 0), request.headers.len);
    try testing.expectEqual(@as(usize, 0), request.body.len);
}

test "a head defaults its optional headers to empty, not to a sentinel" {
    // An absent Retry-After and a Retry-After of "0" are different
    // instructions, and Phase 5 has to be able to tell them apart.
    const head: Head = .{ .status = 500 };
    try testing.expectEqual(@as(usize, 0), head.retry_after.len);
    try testing.expectEqual(@as(usize, 0), head.content_type.len);
}
