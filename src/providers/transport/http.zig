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
/// A megabyte is a very long conversation — roughly 250k tokens of text, past
/// every context window this version knows about. A request larger than this
/// fails rather than truncating: a silently shortened prompt means the model
/// answers a question nobody asked.
///
/// This is a limit, not a buffer. It used to be `body_storage: [max_body_bytes]u8`
/// inline in `Http`, which made the struct 1.07 MiB — larger than the 1 MiB main
/// thread stack `build.zig` asks for, so `tug dev stream` overflowed the stack
/// before it opened a socket. Every test missed it because a test binary gets an
/// 8 MiB stack. `sizeOf` is now asserted below.
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

    /// The request body, copied because `sendBodyComplete` wants a mutable
    /// slice, and heap-allocated because a request-sized buffer has no business
    /// being part of a stack-allocated struct.
    body_copy: []u8 = &.{},
    transfer_buffer: [16 * 1024]u8 = undefined,
    redirect_buffer: [1024]u8 = undefined,

    /// Set from any thread by `cancel`. Checked between reads, and backed by a
    /// socket shutdown so a thread already parked in one wakes too (`DR-018`).
    canceled: std.atomic.Value(bool) = .init(false),
    /// Set by the watchdog when it shuts the socket down for a stall, so the
    /// reader can tell `Timeout` from `Canceled` once it wakes. "The model
    /// stopped talking" and "you pressed Esc" must not render the same.
    stalled: std.atomic.Value(bool) = .init(false),
    /// Milliseconds on the monotonic clock at the last byte read. The reader
    /// writes it; the watchdog reads it.
    last_byte_ms: std.atomic.Value(i64) = .init(0),
    watchdog: ?std.Thread = null,
    /// A u32 rather than a bool so the watchdog can wait on it: it parks on a
    /// futex with a tick-length timeout instead of sleeping the tick out, which
    /// is what keeps `close` from having to wait a quarter second for a thread
    /// that has nothing left to do. `DR-018` puts a 100 ms bound on the whole
    /// teardown, and a 250 ms sleep would blow it on its own.
    watchdog_stop: std.atomic.Value(u32) = .init(0),

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

    /// Ends the stream early, from any thread. Idempotent, and safe when no
    /// request is in flight — the frontend does not get to know whether the
    /// provider thread has reached its first read yet.
    pub fn cancel(self: *Http) void {
        self.canceled.store(true, .release);
        self.shutdownSocket();
    }

    /// Wakes a thread parked in a read without retiring the descriptor.
    ///
    /// `shutdown` rather than `close`: closing hands the fd back to the OS while
    /// the client's connection pool still believes it owns it, and the next
    /// connection may be handed the same number. `DR-018` has the rest.
    fn shutdownSocket(self: *Http) void {
        const req = self.request orelse return;
        const connection = req.connection orelse return;
        connection.stream_reader.stream.shutdown(self.io, .both) catch {};
    }

    /// Monotonic milliseconds. The absolute value is meaningless — the clock
    /// counts from an unspecified point — and only the difference between two
    /// of these is ever read, which is the whole reason it is the awake clock
    /// and not the wall clock.
    fn nowMs(io: std.Io) i64 {
        const timestamp: std.Io.Clock.Timestamp = .now(io, .awake);
        return timestamp.raw.toMilliseconds();
    }

    /// ponytail: one thread per active stream, waking four times a second. tug
    /// has one active stream, so this costs one thread and four wakeups per
    /// second. A single shared watchdog over a list of deadlines is the upgrade
    /// the day parallel streams exist.
    fn watch(self: *Http) void {
        const tick_ms = 250;
        while (self.watchdog_stop.load(.acquire) == 0) {
            self.io.futexWaitTimeout(u32, &self.watchdog_stop.raw, 0, .{ .duration = .{
                .raw = .fromMilliseconds(tick_ms),
                .clock = .awake,
            } }) catch return;
            if (self.watchdog_stop.load(.acquire) != 0) return;

            const idle = nowMs(self.io) - self.last_byte_ms.load(.acquire);
            if (idle < self.options.read_ms) continue;

            self.stalled.store(true, .release);
            self.shutdownSocket();
            return;
        }
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

        if (request.body.len > max_body_bytes) return error.OutOfMemory;

        if (self.options.debug_wire) |out| writeWire(request, out) catch {};

        if (self.client == null) self.client = .{ .allocator = self.gpa, .io = self.io };
        const client = &self.client.?;

        var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = uri.getHost(&host_buffer) catch return error.Refused;

        // Connecting explicitly rather than letting `request` do it is what
        // gives the connect timeout a life of its own — and the pool is keyed on
        // host and port, so a second turn to the same endpoint finds this
        // connection rather than handshaking again.
        //
        // It also skips the certificate-bundle scan that `request` performs, and
        // the TLS path unwraps `client.now` unconditionally. Bypassing one and
        // not the other panicked on the first live HTTPS request — plain HTTP to
        // loopback was fine, which is exactly why the tests missed it.
        try ensureCertBundle(client, protocol);
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

        // Freed by `close`, which every caller reaches through `defer`.
        self.gpa.free(self.body_copy);
        self.body_copy = self.gpa.alloc(u8, request.body.len) catch return error.OutOfMemory;
        @memcpy(self.body_copy, request.body);
        req.sendBodyComplete(self.body_copy) catch return error.Closed;

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

        // The clock starts at the head, not at the first body byte: a provider
        // that sends a head and then nothing is exactly the stall this detects.
        self.last_byte_ms.store(nowMs(self.io), .release);
        self.watchdog_stop.store(0, .release);
        self.watchdog = std.Thread.spawn(.{}, watch, .{self}) catch null;

        return out;
    }

    /// Loads the system certificate bundle, as `std.http.Client.request` would.
    ///
    /// Mirrored rather than avoided: the standard library's own connect path
    /// checks `client.now != null` before rescanning, which is what makes a
    /// caller populating it ahead of time the supported arrangement rather than
    /// a trick. Doing it here means the scan still happens on first use and not
    /// at startup, which is what `DR-017`'s laziness rule asks for.
    fn ensureCertBundle(client: *std.http.Client, protocol: std.http.Client.Protocol) seam.Error!void {
        if (protocol != .tls) return;

        const io = client.io;
        {
            client.ca_bundle_lock.lockShared(io) catch return error.Canceled;
            defer client.ca_bundle_lock.unlockShared(io);
            if (client.now != null) return;
        }

        var bundle: std.crypto.Certificate.Bundle = .empty;
        defer bundle.deinit(client.allocator);

        const now = std.Io.Clock.real.now(io);
        bundle.rescan(client.allocator, io, now) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return error.Tls,
        };

        client.ca_bundle_lock.lock(io) catch return error.Canceled;
        defer client.ca_bundle_lock.unlock(io);
        client.now = now;
        std.mem.swap(std.crypto.Certificate.Bundle, &client.ca_bundle, &bundle);
    }

    fn readErased(context: ?*anyopaque, buffer: []u8) seam.Error!usize {
        const self: *Http = @ptrCast(@alignCast(context.?));
        const body = self.body orelse return 0;

        // Deliberately not `readSliceShort`, and deliberately not `readVec`.
        //
        // `readSliceShort` is short only at end of stream: it loops until the
        // caller's buffer is full, so the first token of a response would
        // appear once 4 KiB of deltas had piled up behind it, or never.
        //
        // `readVec` does one underlying read, but it fills the body reader's
        // own buffer first and reports only what landed in the caller's — which
        // for a small chunked event is zero, with the bytes sitting in the
        // reader where the caller cannot see them.
        //
        // What streaming actually wants: hand back whatever is buffered, and
        // block for more only when there is nothing.
        while (true) {
            if (self.canceled.load(.acquire)) return error.Canceled;

            const available = body.buffered();
            if (available.len > 0) {
                const take = @min(available.len, buffer.len);
                @memcpy(buffer[0..take], available[0..take]);
                body.toss(take);
                self.last_byte_ms.store(nowMs(self.io), .release);
                return take;
            }

            body.fillMore() catch |err| switch (err) {
                error.EndOfStream => return 0,
                // The read failed; which failure it was is the flags' job to
                // say. A shutdown from another thread and a server hanging up
                // look identical from in here, and they read very differently
                // to a user.
                error.ReadFailed => {
                    if (self.canceled.load(.acquire)) return error.Canceled;
                    if (self.stalled.load(.acquire)) return error.Timeout;
                    return error.Closed;
                },
            };
        }
    }

    fn closeErasedSelf(self: *Http) void {
        // Idempotent, and safe after an error: `defer t.close()` is the only
        // cleanup pattern the seam gives its callers.
        self.watchdog_stop.store(1, .release);
        self.io.futexWake(u32, &self.watchdog_stop.raw, 1);
        if (self.watchdog) |thread| thread.join();
        self.watchdog = null;

        self.body = null;
        if (self.request) |*req| req.deinit();
        self.request = null;
        self.head_used = 0;

        self.gpa.free(self.body_copy);
        self.body_copy = &.{};
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

test "the client fits on a thread's stack" {
    // `build.zig` gives the main thread 1 MiB, and this type used to be 1.07 MiB
    // because the request body was an inline array. `tug dev stream` overflowed
    // the stack before it opened a socket, and every test missed it: a test
    // binary gets an 8 MiB stack, so the only build that could fail was the one
    // nobody ran under test.
    //
    // 64 KiB is far more headroom than the transfer buffer needs and far less
    // than anything that would blow a stack.
    try testing.expect(@sizeOf(Http) <= 64 * 1024);
}

test "a body larger than one request is not carried between requests" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var client: Http = .init(testing.allocator, threaded.io(), .{});
    defer client.deinit();

    // Nothing allocated before a send, and nothing left over after a close.
    try testing.expectEqual(@as(usize, 0), client.body_copy.len);
    const t = client.transport();
    t.close();
    try testing.expectEqual(@as(usize, 0), client.body_copy.len);
}

test "a TLS request loads the certificate bundle before it connects" {
    // The regression test for the panic the first live HTTPS request hit:
    // `connectTcpOptions` skips the scan `request` does, and std's TLS path
    // unwraps `client.now` with no check. Reads the filesystem and no socket, so
    // it runs inside the network-denied namespace like everything else.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    var client: Http = .init(testing.allocator, threaded.io(), .{});
    defer client.deinit();
    client.client = .{ .allocator = testing.allocator, .io = threaded.io() };

    try Http.ensureCertBundle(&client.client.?, .tls);
    try testing.expect(client.client.?.now != null);

    // And it is idempotent: a second turn must not rescan.
    const first = client.client.?.now.?;
    try Http.ensureCertBundle(&client.client.?, .tls);
    try testing.expectEqual(first.nanoseconds, client.client.?.now.?.nanoseconds);
}

test "a plaintext request does not load a certificate bundle" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var client: Http = .init(testing.allocator, threaded.io(), .{});
    defer client.deinit();
    client.client = .{ .allocator = testing.allocator, .io = threaded.io() };

    try Http.ensureCertBundle(&client.client.?, .plain);
    try testing.expect(client.client.?.now == null);
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

// --- the loopback server the cancellation tests need ---------------------
//
// A fixture cannot block, and blocking is the entire subject of `DR-018`. So
// these tests need a real socket — which is why `scripts/offline.sh` brings
// loopback up inside its network-denied namespace rather than denying every
// interface. A test server is network code and lives where network code lives.

const TestServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    port: u16,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    /// How many connections were accepted. The connection-reuse test is the
    /// only thing that reads it, and it is the only way to observe pooling.
    accepted: std.atomic.Value(usize) = .init(0),
    /// Answer this many requests before going quiet.
    responses: usize = 1,
    /// After the head and the first event, say nothing more instead of ending
    /// the response. This is the stall, reproducibly.
    go_silent: bool = true,

    const event = "event: chunk\ndata: hello\n\n";

    fn start(io: std.Io, options: struct { responses: usize = 1, go_silent: bool = true }) !*TestServer {
        const self = try testing.allocator.create(TestServer);
        errdefer testing.allocator.destroy(self);

        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        const server = try address.listen(io, .{ .reuse_address = true });
        self.* = .{
            .io = io,
            .server = server,
            .port = server.socket.address.getPort(),
            .responses = options.responses,
            .go_silent = options.go_silent,
        };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    /// Accepts exactly one connection and answers `responses` requests on it.
    ///
    /// One accept, not one per response, and that is the point: keep-alive
    /// means the second request arrives on the first connection, so a server
    /// that accepted twice would be measuring nothing. It also means this
    /// thread never parks in a second `accept` that nothing will ever satisfy,
    /// which is what a `deinit` has to be able to join.
    ///
    /// Built on `std.http.Server` rather than by hand. The first version of
    /// this wrote the status line and the chunked framing itself and spent an
    /// afternoon failing for reasons that had nothing to do with `DR-018`; a
    /// test server whose own framing is under suspicion tests nothing.
    fn serve(self: *TestServer) void {
        var stream = self.server.accept(self.io) catch return;
        defer stream.close(self.io);
        _ = self.accepted.fetchAdd(1, .monotonic);

        var read_buffer: [4096]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        var write_buffer: [4096]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);

        var http_server = std.http.Server.init(&reader.interface, &writer.interface);

        var served: usize = 0;
        while (served < self.responses and !self.stop.load(.acquire)) : (served += 1) {
            var request = http_server.receiveHead() catch return;

            var body_buffer: [1024]u8 = undefined;
            var body = request.respondStreaming(&body_buffer, .{ .respond_options = .{
                .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }},
            } }) catch return;

            body.writer.writeAll(event) catch return;
            // Two flushes, and both are load-bearing. `BodyWriter.flush` only
            // flushes the protocol output; the bytes the caller wrote are
            // sitting in the BodyWriter's own buffer until `body.writer.flush`
            // turns them into a chunk. Skip the first and the event never
            // leaves the process — and every test here then measures a stall it
            // caused itself.
            body.writer.flush() catch return;
            body.flush() catch return;

            if (self.go_silent) break;
            body.end() catch return;
        }

        // Hold the connection open, saying nothing, until the test is done with
        // it. For `go_silent` this *is* the stall — a provider that is alive and
        // not talking. For the others it keeps the pooled connection valid.
        while (!self.stop.load(.acquire)) {
            self.io.sleep(.fromMilliseconds(10), .awake) catch return;
        }
    }

    fn url(self: *TestServer, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}/v1/messages", .{self.port}) catch unreachable;
    }

    fn deinit(self: *TestServer) void {
        self.stop.store(true, .release);

        // Wake a thread parked in `accept`. It is parked there whenever the
        // test failed before connecting, and closing the listening socket from
        // another thread is not guaranteed to return it — a connection is. A
        // test that fails should fail, not hang.
        if (self.accepted.load(.acquire) == 0) {
            const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(self.port) };
            if (address.connect(self.io, .{ .mode = .stream })) |stream| {
                stream.close(self.io);
            } else |_| {}
        }

        if (self.thread) |thread| thread.join();
        self.server.deinit(self.io);
        testing.allocator.destroy(self);
    }
};

/// Drains a whole turn, recording how far it got before whatever ended it.
fn drain(client: *Http, url: []const u8, out: *DrainResult) seam.Error!void {
    const t = client.transport();
    defer t.close();

    _ = t.send(.{ .url = url }) catch |err| {
        out.send_failed = true;
        return err;
    };

    var buffer: [256]u8 = undefined;
    while (true) {
        const n = try t.read(&buffer);
        out.reads += 1;
        if (n == 0) {
            out.ended_clean = true;
            return;
        }
    }
}

const DrainResult = struct {
    err: ?seam.Error = null,
    elapsed_ms: i64 = 0,
    /// Which half failed, and how far it got. A test that only knows the error
    /// cannot tell "the request never left" from "the read woke wrong", and
    /// those have nothing to do with each other.
    send_failed: bool = false,
    reads: usize = 0,
    ended_clean: bool = false,
};

fn drainTimed(client: *Http, url: []const u8, out: *DrainResult) void {
    const started = Http.nowMs(client.io);
    drain(client, url, out) catch |err| {
        out.err = err;
    };
    out.elapsed_ms = Http.nowMs(client.io) - started;
}

test "cancel wakes a blocked read within the bound" {
    // A real `Threaded`, not `init_single_threaded`: three threads are in
    // flight here — the reader, the server and the watchdog — and the
    // single-threaded instance is documented for a program that has one.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const server = try TestServer.start(io, .{});
    defer server.deinit();

    var url_buffer: [64]u8 = undefined;
    const url = server.url(&url_buffer);

    var client: Http = .init(testing.allocator, io, .{});
    defer client.deinit();

    var result: DrainResult = .{};
    const reader = try std.Thread.spawn(.{}, drainTimed, .{ &client, url, &result });

    // Let it get all the way into the blocked read, which is the only state
    // where cancelling is interesting.
    try io.sleep(.fromMilliseconds(50), .awake);
    const canceled_at = Http.nowMs(io);
    client.cancel();
    reader.join();
    const latency = Http.nowMs(io) - canceled_at;

    // In order, so the first failure says what actually went wrong rather than
    // only that the error was not the expected one.
    try testing.expect(!result.send_failed);
    try testing.expect(!result.ended_clean);
    try testing.expect(result.reads >= 1);
    try testing.expect(result.elapsed_ms >= 40);
    try testing.expectEqual(seam.Error.Canceled, result.err.?);
    // DR-018's number, and the reason the shutdown is there at all.
    try testing.expect(latency <= 100);
}

test "a stall becomes a timeout rather than a hang" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const server = try TestServer.start(io, .{});
    defer server.deinit();

    var url_buffer: [64]u8 = undefined;
    const url = server.url(&url_buffer);

    // Short enough that the test is quick, long enough that the 250 ms watchdog
    // tick is not the thing being measured.
    var client: Http = .init(testing.allocator, io, .{ .read_ms = 400 });
    defer client.deinit();

    var result: DrainResult = .{};
    drainTimed(&client, url, &result);

    try testing.expect(!result.send_failed);
    try testing.expectEqual(seam.Error.Timeout, result.err.?);
    try testing.expect(result.reads >= 1);
    try testing.expect(result.elapsed_ms >= 400);
    // A tick of slack on each side; a stall that took two seconds to notice
    // would pass a bare lower-bound assertion and still be a bug.
    try testing.expect(result.elapsed_ms <= 1_200);
}

test "a second turn to the same endpoint reuses the connection" {
    // Connection reuse is not a micro-optimization here: a fresh TLS handshake
    // per turn is tens of milliseconds against a 3 ms first-token budget. The
    // std client pools for us — this test exists to notice if a change to
    // close() ever stops it, because nothing else would.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const server = try TestServer.start(io, .{ .responses = 2, .go_silent = false });
    defer server.deinit();

    var url_buffer: [64]u8 = undefined;
    const url = server.url(&url_buffer);

    // A read timeout, so that a regression which stops reusing the connection
    // fails on a stall instead of hanging: the second connection would complete
    // at the TCP level and then wait for a server that is no longer accepting.
    var client: Http = .init(testing.allocator, io, .{ .read_ms = 1_000 });
    defer client.deinit();

    var first: DrainResult = .{};
    var second: DrainResult = .{};
    try drain(&client, url, &first);
    try drain(&client, url, &second);

    // This is also what pins closeErasedSelf to request.deinit() rather than a
    // close: deinit releases the connection to the pool, a close retires it.
    // Getting that backwards passes every other test in this file.
    try testing.expectEqual(@as(usize, 1), server.accepted.load(.acquire));
}
