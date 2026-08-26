//! Failures, in the five words a user can act on.
//!
//! `tugproto.ErrKind` is deliberately small: `auth`, `rate_limit`, `server`,
//! `transport`, `decode`. This file is the only place anything is mapped onto
//! it, because a taxonomy applied in two places is two taxonomies.
//!
//! The mapping is the whole point of the version's error handling. A user who
//! sees "the provider answered 401" has to go and find out what tug already
//! knew; a user who sees the export line for the variable they forgot does not.
//!
//! `@setRuntimeSafety(true)` throughout. A `Retry-After` header is untrusted
//! input with arithmetic performed on it, which is the shape of every parser in
//! this codebase that has a fuzz target.

const std = @import("std");

const proto = @import("tugproto");

const seam = @import("transport.zig");

/// The longest wait tug will ever report. Roughly a day.
///
/// A `Retry-After` past this is a provider saying "not today", and clamping is
/// better than an overflow or a number so large it reads as a bug.
pub const max_retry_after_ms: u32 = 24 * 60 * 60 * 1000;

/// An HTTP status, in the taxonomy.
///
/// Exhaustive by construction: every path returns a variant, and the last one is
/// `server` rather than an `unreachable`, because a status nobody expected is a
/// provider having an unusual day, not a bug in tug.
pub fn fromStatus(status: u16) proto.ErrKind {
    return switch (status) {
        401, 403 => .auth,
        429 => .rate_limit,
        // A 4xx that is not auth and not rate limiting is the request's fault,
        // and the body says which. `server` is the honest bucket: tug did not
        // fail, and waiting will not help — which is exactly what the retry
        // classes in `DR-019` do with it.
        else => .server,
    };
}

/// A transport failure, in the taxonomy.
///
/// Everything the socket layer can distinguish is `transport` except the two
/// that are not really failures of transport at all: a refusal is tug declining
/// to make the call, and cancellation is the human.
pub fn fromTransport(err: seam.Error) proto.ErrKind {
    return switch (err) {
        error.Connect,
        error.Tls,
        error.Timeout,
        error.Closed,
        error.Canceled,
        error.Refused,
        error.OutOfMemory,
        => .transport,
        // Headers that do not parse, an unsupported transfer encoding, a
        // redirect: bytes arrived and did not mean what they claimed to, which
        // is the definition of `decode`.
        error.Protocol => .decode,
    };
}

/// `Retry-After`, in milliseconds, or null when there was no instruction.
///
/// Null and zero are different answers and the difference is load-bearing: null
/// means the provider said nothing, and `DR-019` does not retry a rate limit
/// that came with no instruction. Turning an unparseable header into zero would
/// turn a shrug into "immediately".
///
/// `now_epoch_s` is passed in rather than read, because everything above the
/// transport seam is a pure function of bytes and a clock would end that.
pub fn retryAfterMs(header: []const u8, now_epoch_s: i64) ?u32 {
    @setRuntimeSafety(true);

    const text = std.mem.trim(u8, header, " \t");
    if (text.len == 0) return null;

    // The delay-seconds form, which is what almost everything sends.
    if (std.fmt.parseInt(u32, text, 10)) |seconds| {
        if (seconds > max_retry_after_ms / 1000) return max_retry_after_ms;
        return seconds * 1000;
    } else |_| {}

    // The HTTP-date form. RFC 9110 requires a client to accept it, and providers
    // do send it. The two obsolete date formats are deliberately not implemented:
    // nothing sends them and each is a parser with its own bugs.
    const when = parseImfFixdate(text) orelse return null;
    if (when <= now_epoch_s) return 0;

    const wait = when - now_epoch_s;
    if (wait > max_retry_after_ms / 1000) return max_retry_after_ms;
    return @intCast(wait * 1000);
}

const month_names = [_][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

/// `Sun, 06 Nov 1994 08:49:37 GMT` — the one date format a client must accept.
fn parseImfFixdate(text: []const u8) ?i64 {
    @setRuntimeSafety(true);

    // Exactly 29 characters, and every position is fixed. A length check first
    // is what lets every index below be a constant.
    if (text.len != 29) return null;
    if (!std.mem.endsWith(u8, text, " GMT")) return null;
    if (text[3] != ',' or text[4] != ' ') return null;

    const day = std.fmt.parseInt(u8, text[5..7], 10) catch return null;
    const month = monthIndex(text[8..11]) orelse return null;
    const year = std.fmt.parseInt(u16, text[12..16], 10) catch return null;
    const hour = std.fmt.parseInt(u8, text[17..19], 10) catch return null;
    const minute = std.fmt.parseInt(u8, text[20..22], 10) catch return null;
    const second = std.fmt.parseInt(u8, text[23..25], 10) catch return null;

    if (day == 0 or day > 31 or hour > 23 or minute > 59 or second > 60) return null;

    const days = daysFromCivil(year, month + 1, day);
    return days * 86_400 +
        @as(i64, hour) * 3_600 +
        @as(i64, minute) * 60 +
        @as(i64, second);
}

fn monthIndex(name: []const u8) ?u8 {
    for (month_names, 0..) |candidate, i| {
        if (std.mem.eql(u8, candidate, name)) return @intCast(i);
    }
    return null;
}

/// Days since 1970-01-01, by Howard Hinnant's civil-from-days.
///
/// Written out rather than reached for in `std`, because the standard library's
/// calendar types are not available on every target `tugproto` compiles for and
/// this file sits one import away from those.
fn daysFromCivil(year_in: u16, month: u8, day: u8) i64 {
    const y: i64 = @as(i64, year_in) - @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const d: i64 = day;
    const doy = @divTrunc(153 * (m + (if (m > 2) @as(i64, -3) else 9)) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146_097 + doe - 719_468;
}

/// What to do about it, in one sentence.
///
/// The hint is the difference between an error and an error message. `env_var`
/// is the preset's, so the auth hint is copy-pasteable for the provider the user
/// actually asked for rather than for a provider tug guessed at.
pub fn hint(kind: proto.ErrKind, env_var: []const u8, out: []u8) []const u8 {
    return switch (kind) {
        .auth => if (env_var.len == 0)
            "check the credentials for this provider"
        else
            std.fmt.bufPrint(out, "set the key and try again:  export {s}=...", .{env_var}) catch
                "set the provider's API key and try again",
        .rate_limit => "the provider is rate limiting; tug waits when it says how long",
        .server => "the provider failed on its own side; the message above is theirs",
        .transport => "the bytes stopped arriving; check the network and resubmit",
        .decode => "the response was not what the API documents; this is worth reporting",
    };
}

const testing = std.testing;

test "the documented status mapping, exhaustively" {
    try testing.expectEqual(proto.ErrKind.auth, fromStatus(401));
    try testing.expectEqual(proto.ErrKind.auth, fromStatus(403));
    try testing.expectEqual(proto.ErrKind.rate_limit, fromStatus(429));
    try testing.expectEqual(proto.ErrKind.server, fromStatus(500));
    try testing.expectEqual(proto.ErrKind.server, fromStatus(503));
    // A 4xx that is neither auth nor rate limiting.
    try testing.expectEqual(proto.ErrKind.server, fromStatus(400));
    try testing.expectEqual(proto.ErrKind.server, fromStatus(404));
    // Unknown status, and never a panic.
    try testing.expectEqual(proto.ErrKind.server, fromStatus(299));
    try testing.expectEqual(proto.ErrKind.server, fromStatus(999));
    try testing.expectEqual(proto.ErrKind.server, fromStatus(0));
}

test "a protocol failure is a decode failure, not a transport one" {
    // A redirect, or headers that do not parse: the bytes arrived and did not
    // mean what they claimed. Calling that `transport` would tell a user to
    // check their network for a problem that is not in it.
    try testing.expectEqual(proto.ErrKind.decode, fromTransport(error.Protocol));
    try testing.expectEqual(proto.ErrKind.transport, fromTransport(error.Closed));
    try testing.expectEqual(proto.ErrKind.transport, fromTransport(error.Timeout));
    try testing.expectEqual(proto.ErrKind.transport, fromTransport(error.Tls));
}

test "retry-after parses the seconds form" {
    try testing.expectEqual(@as(?u32, 30_000), retryAfterMs("30", 0));
    try testing.expectEqual(@as(?u32, 0), retryAfterMs("0", 0));
    try testing.expectEqual(@as(?u32, 1_500_000), retryAfterMs("  1500  ", 0));
}

test "retry-after parses the HTTP-date form" {
    // A client that only understood seconds would ignore exactly the instruction
    // it was given.
    const epoch: i64 = 1_700_000_000; // 2023-11-14T22:13:20Z
    try testing.expectEqual(
        @as(?u32, 20_000),
        retryAfterMs("Tue, 14 Nov 2023 22:13:40 GMT", epoch),
    );
    try testing.expectEqual(
        @as(?u32, 60_000),
        retryAfterMs("Tue, 14 Nov 2023 22:14:20 GMT", epoch),
    );
}

test "a retry-after in the past is zero, not negative" {
    try testing.expectEqual(
        @as(?u32, 0),
        retryAfterMs("Tue, 14 Nov 2023 22:11:40 GMT", 1_700_000_000),
    );
}

test "an unparseable retry-after is absent, not zero" {
    // Absent means "no instruction"; zero means "immediately". A header tug
    // could not read must never become the second.
    try testing.expect(retryAfterMs("soon", 0) == null);
    try testing.expect(retryAfterMs("", 0) == null);
    try testing.expect(retryAfterMs("   ", 0) == null);
    try testing.expect(retryAfterMs("-5", 0) == null);
    try testing.expect(retryAfterMs("99999999999999999999", 0) == null);
    try testing.expect(retryAfterMs("Tue, 14 Xxx 2023 22:13:40 GMT", 0) == null);
    try testing.expect(retryAfterMs("Tue, 14 Nov 2023 22:13:40 UTC", 0) == null);
}

test "a wrong weekday does not discard an otherwise valid date" {
    // The weekday is redundant with the date and RFC 9110 says it must agree,
    // but a provider whose weekday is off by one has still told tug exactly when
    // to come back. Throwing that instruction away over a field carrying no
    // information is the worse of the two failures, so the parser ignores it.
    try testing.expectEqual(
        @as(?u32, 20_000),
        retryAfterMs("Xyz, 14 Nov 2023 22:13:40 GMT", 1_700_000_000),
    );
}

test "an absurd wait is clamped rather than overflowed" {
    try testing.expectEqual(@as(?u32, max_retry_after_ms), retryAfterMs("4000000", 0));
    try testing.expectEqual(
        @as(?u32, max_retry_after_ms),
        retryAfterMs("Sat, 01 Jan 2050 00:00:00 GMT", 1_700_000_000),
    );
}

test "the epoch itself is day zero" {
    // The calendar arithmetic, pinned at the one date everybody can check.
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(i64, 1), daysFromCivil(1970, 1, 2));
    try testing.expectEqual(@as(i64, -1), daysFromCivil(1969, 12, 31));
    // A leap day, which is where a hand-written calendar goes wrong.
    try testing.expectEqual(@as(i64, 11_016), daysFromCivil(2000, 2, 29));
}

test "an auth hint names the exact variable to set" {
    var buffer: [256]u8 = undefined;
    const message = hint(.auth, "ANTHROPIC_API_KEY", &buffer);
    try testing.expect(std.mem.indexOf(u8, message, "export ANTHROPIC_API_KEY=") != null);
}

test "an auth hint with no variable still says something useful" {
    // Ollama and LM Studio name none, and "export =..." would be worse than
    // saying nothing about variables at all.
    var buffer: [256]u8 = undefined;
    const message = hint(.auth, "", &buffer);
    try testing.expect(std.mem.indexOf(u8, message, "export") == null);
    try testing.expect(message.len > 0);
}

test "every kind has a hint, and none of them is empty" {
    var buffer: [256]u8 = undefined;
    for ([_]proto.ErrKind{ .auth, .rate_limit, .server, .transport, .decode }) |kind| {
        try testing.expect(hint(kind, "X_KEY", &buffer).len > 0);
    }
}

fn fuzzOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var bytes: [64]u8 = undefined;
    const header = bytes[0..smith.slice(&bytes)];

    // Two clocks: one at the epoch and one far from it, because the subtraction
    // is where a sign error lives.
    _ = retryAfterMs(header, 0);
    _ = retryAfterMs(header, 1_700_000_000);
    _ = retryAfterMs(header, std.math.maxInt(i32));
}

test "fuzz: retry-after survives arbitrary bytes" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        "30",
        "0",
        "-1",
        "99999999999999999999",
        "Sun, 06 Nov 1994 08:49:37 GMT",
        "Sun, 06 Nov 1994 08:49:37 GM",
        "Sun, 99 Nov 1994 99:99:99 GMT",
        "Sun, 06 Nov 0000 00:00:00 GMT",
        "",
        "   ",
        "\x00\x00\x00",
    } });
}
