//! The one file that opens a socket.
//!
//! `DR-016` confines `std.http` and `std.crypto.tls` to this directory, and
//! `DR-017` explains why the seam above it is three functions rather than a
//! reader. Everything here is mechanical: build a request, hand back the head,
//! copy body bytes into the caller's buffer.
//!
//! Four policies live here because they cannot live anywhere else — they are
//! about the connection, not about the conversation:
//!
//! 1. **No redirects.** An API does not redirect. A redirect is a captive
//!    portal, a proxy, or a misconfigured base URL, and following one would
//!    send an API key to whoever asked for it. `Protocol` is the error.
//! 2. **No plaintext off the machine.** `http://` is permitted to loopback,
//!    because Ollama and LM Studio serve it there and demanding TLS on
//!    127.0.0.1 would be theatre with a real usability cost. Anywhere else it
//!    is `Refused` unless the endpoint's config says `insecure = true`.
//! 3. **Identity encoding.** The std client advertises gzip and deflate by
//!    default. A compressed SSE stream frames correctly and arrives in the
//!    wrong shape, and decompressing buys nothing for a stream of small text
//!    deltas. Ask for identity and the question is closed.
//! 4. **Nothing happens until the first send.** The client, the certificate
//!    bundle scan and the connection are all first-use, because the roadmap's
//!    10 ms prompt budget is re-asserted in Phase 10 *with providers
//!    configured*.

const std = @import("std");

const canary = @import("../canary.zig");

/// Imported as `seam` because `Http.transport()` is the method that hands one
/// out, and Zig will not have both names in scope.
const seam = @import("../transport.zig");

pub const Options = struct {
    /// Distinct on purpose. A connect that hangs and a stream that stalls are
    /// different failures with different right answers, and a single timeout
    /// makes one of them unreportable.
    connect_ms: u32 = 10_000,
    header_ms: u32 = 30_000,
    /// Doubles as stall detection: this long with no byte is a `Timeout`
    /// carrying the elapsed time.
    read_ms: u32 = 60_000,
    /// Per-endpoint escape hatch for plaintext to a non-loopback host.
    allow_insecure: bool = false,
    /// Dumps the request and response head to this writer. Debug builds set it;
    /// a release build passes null and the code is dead.
    debug_wire: ?*std.Io.Writer = null,
};

/// The largest request body tug will send.
///
/// `sendBodyComplete` wants a mutable slice, so the body is copied into a
/// buffer this type owns. A megabyte is a very long conversation — roughly
/// 250k tokens of text, past every context window this version knows about.
///
/// ponytail: fixed cap, and a longer conversation fails with OutOfMemory rather
/// than truncating. Allocate from the caller's arena instead if v0.4's sessions
/// ever want to replay something larger.
pub const max_body_bytes = 1024 * 1024;

/// Header values that are safe to print in a wire dump.
///
/// Inverted from the usual "redact the sensitive ones", deliberately: an auth
/// header added in some later version is redacted by default rather than leaked
/// by omission. A dump is a debugging tool, and a debugging tool that leaks a
/// key is worse than no debugging tool.
const printable_headers = [_][]const u8{
    "content-type",
    "accept",
    "accept-encoding",
    "anthropic-version",
    "user-agent",
    "content-length",
};

fn headerIsPrintable(name: []const u8) bool {
    for (printable_headers) |allowed| {
        if (std.ascii.eqlIgnoreCase(name, allowed)) return true;
    }
    return false;
}

/// True when this URL's host is the local machine.
///
/// Whole-host comparison, never a prefix: `localhost.evil.example` and
/// `127.0.0.1.evil.example` are both perfectly ordinary registrable names that
/// somebody else controls, and a `startsWith` check would hand them plaintext.
pub fn isLoopback(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    var buffer: [256]u8 = undefined;
    const host = (uri.host orelse return false).toRaw(&buffer) catch return false;

    if (std.mem.eql(u8, host, "localhost")) return true;
    if (std.mem.eql(u8, host, "::1")) return true;
    if (std.mem.eql(u8, host, "[::1]")) return true;

    // The whole 127.0.0.0/8 block is loopback, not just 127.0.0.1.
    const addr = std.Io.net.IpAddress.parseLiteral(host) catch return false;
    return switch (addr) {
        .ip4 => |ip4| ip4.bytes[0] == 127,
        .ip6 => |ip6| ip6.isLoopBack(),
    };
}

pub const Http = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    options: Options,

    /// Null until the first send. See policy 4 above.
    client: ?std.http.Client = null,
    request: ?std.http.Client.Request = null,
    response: std.http.Client.Response = undefined,
    body: ?*std.Io.Reader = null,

    /// Copies of the two head strings the seam hands out. `Response.reader`
    /// invalidates the pointers into the head bytes — the standard library
    /// documents it in as many words — and returning slices into freed buffer
    /// would be a use-after-free that only shows up under load.
    head_storage: [512]u8 = undefined,
    head_used: usize = 0,

    body_storage: [max_body_bytes]u8 = undefined,
    transfer_buffer: [16 * 1024]u8 = undefined,
    redirect_buffer: [1024]u8 = undefined,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, options: Options) Http {
        return .{ .gpa = gpa, .io = io, .options = options };
    }

    pub fn deinit(self: *Http) void {
        self.closeErasedSelf();
        if (self.client) |*client| client.deinit();
        self.client = null;
    }

    /// Copies a string into the head storage so it survives `Response.reader`.
    fn keep(self: *Http, text: []const u8) []const u8 {
        const room = self.head_storage.len - self.head_used;
        const take = @min(text.len, room);
        const slot = self.head_storage[self.head_used..][0..take];
        @memcpy(slot, text[0..take]);
        self.head_used += take;
        return slot;
    }

    fn sendErased(context: ?*anyopaque, request: seam.Request) seam.Error!seam.Head {
        const self: *Http = @ptrCast(@alignCast(context.?));
        return self.send(request);
    }

    fn send(self: *Http, request: seam.Request) seam.Error!seam.Head {
        const uri = std.Uri.parse(request.url) catch return error.Refused;

        const protocol = std.http.Client.Protocol.fromUri(uri) orelse return error.Refused;
        if (protocol == .plain and !self.options.allow_insecure and !isLoopback(request.url)) {
            // Policy 2. Refused before a socket exists, which is the only place
            // a refusal is worth anything.
            return error.Refused;
        }

        if (request.body.len > self.body_storage.len) return error.OutOfMemory;

        if (self.options.debug_wire) |out| writeWire(request, out) catch {};

        if (self.client == null) self.client = .{ .allocator = self.gpa, .io = self.io };
        const client = &self.client.?;

        var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = uri.getHost(&host_buffer) catch return error.Refused;

        // Connecting explicitly rather than letting `request` do it is what
        // gives the connect timeout a life of its own — and the pool is keyed on
        // host and port, so a second turn to the same endpoint finds this
        // connection rather than handshaking again.
        const connection = client.connectTcpOptions(.{
            .host = host,
            // `Protocol.port()` is not public, so the two default ports are
            // written here. They have not moved since 1994.
            .port = uri.port orelse @as(u16, if (protocol == .tls) 443 else 80),
            .protocol = protocol,
            .timeout = .{ .duration = .{
                .raw = .fromMilliseconds(self.options.connect_ms),
                .clock = .awake,
            } },
        }) catch |err| return switch (err) {
            error.TlsInitializationFailed => error.Tls,
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            else => error.Connect,
        };

        // `seam.Header` and `std.http.Header` are the same two fields in the
        // same order, so `@ptrCast` would work today. The loop is a refusal to
        // bet on two structurally identical types in two files staying that way
        // when only one of them is ours.
        var extra: [8]std.http.Header = undefined;
        if (request.headers.len > extra.len) return error.Protocol;
        for (request.headers, 0..) |header, i| {
            extra[i] = .{ .name = header.name, .value = header.value };
        }

        self.request = client.request(.POST, uri, .{
            .connection = connection,
            .redirect_behavior = .not_allowed,
            .extra_headers = extra[0..request.headers.len],
            .keep_alive = true,
        }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.Canceled,
            error.UnsupportedUriScheme, error.UriMissingHost => error.Refused,
            error.CertificateBundleLoadFailure, error.TlsInitializationFailed => error.Tls,
            else => error.Connect,
        };
        const req = &self.request.?;

        req.transfer_encoding = .{ .content_length = request.body.len };
        // Policy 3.
        req.accept_encoding = @splat(false);
        req.accept_encoding[@intFromEnum(std.http.ContentEncoding.identity)] = true;

        @memcpy(self.body_storage[0..request.body.len], request.body);
        req.sendBodyComplete(self.body_storage[0..request.body.len]) catch return error.Closed;

        self.response = req.receiveHead(&self.redirect_buffer) catch |err| return switch (err) {
            error.Canceled => error.Canceled,
            error.OutOfMemory => error.OutOfMemory,
            // Policy 1: `.not_allowed` turns a redirect into the first two of
            // these. The rest are responses that are not HTTP tug can follow.
            error.TooManyHttpRedirects,
            error.RedirectRequiresResend,
            error.HttpRedirectLocationInvalid,
            error.HttpRedirectLocationMissing,
            error.HttpRedirectLocationOversize,
            error.HttpHeadersInvalid,
            error.HttpHeadersOversize,
            error.HttpContentEncodingUnsupported,
            error.HttpChunkInvalid,
            error.UnsupportedUriScheme,
            error.UriMissingHost,
            => error.Protocol,
            error.CertificateBundleLoadFailure, error.TlsInitializationFailed => error.Tls,
            error.Timeout => error.Timeout,
            error.ReadFailed,
            error.WriteFailed,
            error.HttpRequestTruncated,
            error.HttpChunkTruncated,
            error.HttpConnectionClosing,
            error.ConnectionResetByPeer,
            => error.Closed,
            else => error.Connect,
        };

        // Read every string out of the head before the reader invalidates them.
        const head = &self.response.head;
        var out: seam.Head = .{ .status = @intFromEnum(head.status) };
        if (head.content_type) |content_type| out.content_type = self.keep(content_type);
        var headers = head.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
                out.retry_after = self.keep(header.value);
            }
        }

        if (self.options.debug_wire) |wire| {
            wire.print("< HTTP {d} {s}\n", .{ out.status, out.content_type }) catch {};
            wire.flush() catch {};
        }

        self.body = self.response.reader(&self.transfer_buffer);
        return out;
    }

    fn readErased(context: ?*anyopaque, buffer: []u8) seam.Error!usize {
        const self: *Http = @ptrCast(@alignCast(context.?));
        const body = self.body orelse return 0;

        return body.readSliceShort(buffer) catch |err| switch (err) {
            error.ReadFailed => error.Closed,
        };
    }

    fn closeErasedSelf(self: *Http) void {
        // Idempotent, and safe after an error: `defer t.close()` is the only
        // cleanup pattern the seam gives its callers.
        self.body = null;
        if (self.request) |*req| req.deinit();
        self.request = null;
        self.head_used = 0;
    }

    fn closeErased(context: ?*anyopaque) void {
        const self: *Http = @ptrCast(@alignCast(context.?));
        self.closeErasedSelf();
    }

    const vtable: seam.Transport.VTable = .{
        .send = sendErased,
        .read = readErased,
        .close = closeErased,
    };

    pub fn transport(self: *Http) seam.Transport {
        return .{ .context = self, .vtable = &vtable };
    }
};

/// Dumps a request with every header value redacted except an allow-list.
///
/// Redaction is not a step in this function that somebody could forget: the
/// values it prints are the ones `headerIsPrintable` names, and everything else
/// is a byte count. A new auth header is redacted the day it is added.
pub fn writeWire(request: seam.Request, out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.print("> POST {s}\n", .{request.url});
    for (request.headers) |header| {
        if (headerIsPrintable(header.name)) {
            try out.print("> {s}: {s}\n", .{ header.name, header.value });
        } else {
            try out.print("> {s}: <redacted, {d} bytes>\n", .{ header.name, header.value.len });
        }
    }
    try out.print("> {d} bytes of body\n", .{request.body.len});
    try out.flush();
}

const testing = std.testing;

test "plaintext is fine for a loopback preset" {
    try testing.expect(isLoopback("http://127.0.0.1:11434/v1/chat/completions"));
    try testing.expect(isLoopback("http://localhost:1234/v1/chat/completions"));
    try testing.expect(isLoopback("http://[::1]:11434/v1/chat/completions"));
    // The rest of 127.0.0.0/8 is loopback too, and some people use it.
    try testing.expect(isLoopback("http://127.0.0.53:8080/v1/"));
}

test "plaintext to anywhere else is not" {
    try testing.expect(!isLoopback("http://api.openai.com/v1/chat/completions"));
    // The oldest trick in the book: a registrable name that merely starts with
    // the loopback one, controlled by somebody else entirely.
    try testing.expect(!isLoopback("http://localhost.evil.example/v1/"));
    try testing.expect(!isLoopback("http://127.0.0.1.evil.example/v1/"));
    try testing.expect(!isLoopback("not a url at all"));
}

test "a plaintext call to a non-loopback host is refused before a socket opens" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var client: Http = .init(testing.allocator, threaded.io(), .{});
    defer client.deinit();

    const t = client.transport();
    defer t.close();

    try testing.expectError(
        seam.Error.Refused,
        t.send(.{ .url = "http://api.openai.com/v1/chat/completions" }),
    );
    // And nothing was constructed on the way to refusing.
    try testing.expect(client.client == null);
}

test "a scheme that is not http or https is refused" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var client: Http = .init(testing.allocator, threaded.io(), .{});
    defer client.deinit();

    const t = client.transport();
    defer t.close();
    try testing.expectError(seam.Error.Refused, t.send(.{ .url = "file:///etc/passwd" }));
    try testing.expectError(seam.Error.Refused, t.send(.{ .url = "ftp://example.com/x" }));
}

test "a body larger than the cap fails rather than truncating" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var client: Http = .init(testing.allocator, threaded.io(), .{});
    defer client.deinit();

    const t = client.transport();
    defer t.close();

    const huge = try testing.allocator.alloc(u8, max_body_bytes + 1);
    defer testing.allocator.free(huge);
    @memset(huge, 'x');

    try testing.expectError(
        seam.Error.OutOfMemory,
        t.send(.{ .url = "http://127.0.0.1:11434/v1/chat/completions", .body = huge }),
    );
}

test "construction opens nothing" {
    // The instant-prompt budget is 10 ms with providers configured, and the way
    // to keep it is for the expensive parts — the certificate bundle scan, the
    // connection — to happen on first send and never at startup.
    var threaded: std.Io.Threaded = .init_single_threaded;
    var client: Http = .init(testing.allocator, threaded.io(), .{});
    defer client.deinit();

    try testing.expect(client.client == null);
    try testing.expect(client.request == null);
    try testing.expect(client.body == null);
}

test "reading before sending is end of stream, not a crash" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var client: Http = .init(testing.allocator, threaded.io(), .{});
    defer client.deinit();

    const t = client.transport();
    var buffer: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try t.read(&buffer));
    t.close();
    t.close();
}

test "debug-wire never prints a key, not even a header nobody listed" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try writeWire(.{
        .url = "https://api.anthropic.com/v1/messages",
        .headers = &.{
            .{ .name = "x-api-key", .value = canary.key },
            .{ .name = "authorization", .value = "Bearer " ++ canary.key },
            // The header that does not exist yet.
            .{ .name = "x-tug-future-auth", .value = canary.key },
            .{ .name = "content-type", .value = "application/json" },
        },
        .body = "{\"model\":\"claude-sonnet-4-5\"}",
    }, &out.writer);

    try testing.expect(!canary.contains(out.written()));
    // The names survive, because a wire dump with no header names is not a wire
    // dump.
    try testing.expect(std.mem.indexOf(u8, out.written(), "x-tug-future-auth") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "application/json") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "<redacted, 42 bytes>") != null);
}
