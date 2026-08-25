//! Stream events — the vocabulary a provider speaks.
//!
//! Every boundary in tug carries these: a provider thread emits them, the
//! renderer consumes them, `--json` prints them, and a plugin sends them over
//! the wire. There is one definition and this is it.
//!
//! v0.2 adds `tool_call_delta`. Adding a variant is a wire-format change, so it
//! happens at a version boundary and gets a changelog entry, never quietly.

const std = @import("std");

/// Token counts for one request. Estimates are acceptable; v0.1 has no provider
/// to produce real ones.
pub const Usage = struct {
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,
    /// Input tokens served from the provider's prompt cache. Priced far below
    /// fresh input, which is why they are counted apart rather than folded in.
    cache_read_tokens: u32 = 0,
    /// Input tokens written into the cache by this request. Priced above fresh
    /// input, and paid once so that later turns pay `cache_read_tokens` instead.
    cache_creation_tokens: u32 = 0,
};

pub const StopReason = enum {
    /// The model finished on its own.
    end_turn,
    /// The response hit the output token limit.
    max_tokens,
    /// The model stopped in order to call a tool. v0.2 reports this and stops;
    /// v0.3 is where the model gets hands.
    tool_use,
    /// The provider declined to answer. Mapped conservatively — only when the
    /// API says so in as many words, never inferred from the content.
    refusal,
    /// The human interrupted.
    interrupted,
    /// The stream ended because of an error; an `err` event carries the detail.
    err,
};

/// One fragment of a model's request to call a tool.
///
/// Deltas, not a finished call: both API shapes stream the argument JSON in
/// pieces, and buffering it into a whole here would mean this type could not
/// describe what actually arrives. `arguments` is a fragment of a JSON document
/// and is not itself valid JSON. `name` is empty on continuation fragments;
/// `id` is what says which call a fragment belongs to.
///
/// Borrowed for the lifetime of the event, like `text_delta` — the producer owns
/// the bytes until the consumer returns.
pub const ToolCallDelta = struct {
    id: []const u8,
    name: []const u8 = "",
    arguments: []const u8 = "",
};

pub const Stop = struct {
    reason: StopReason,
};

/// The error taxonomy is deliberately small and deliberately actionable: each
/// variant maps to something a user can do about it.
pub const ErrKind = enum {
    /// Credentials are missing, wrong, or expired.
    auth,
    /// The provider asked us to slow down.
    rate_limit,
    /// The provider failed on its own side.
    server,
    /// The bytes never arrived, or stopped arriving.
    transport,
    /// The bytes arrived and did not mean what they claimed to.
    decode,
};

pub const Err = struct {
    kind: ErrKind,
    /// Borrowed for the lifetime of the event. Producers own the storage.
    message: []const u8,
    /// How long the provider asked us to wait, when it said so. Only
    /// `rate_limit` and some `server` responses carry one; null means "no
    /// instruction", which is not the same as zero and is why this is optional.
    retry_after_ms: ?u32 = null,
};

/// One event in a response stream.
///
/// `text_delta` carries a borrowed slice rather than owned memory: the producer
/// owns the bytes until the consumer returns, which keeps the whole streaming
/// path allocation-free.
pub const StreamEvent = union(enum) {
    text_delta: []const u8,
    tool_call_delta: ToolCallDelta,
    usage: Usage,
    stop: Stop,
    err: Err,
};

test "a text delta borrows its bytes" {
    const source = "hello";
    const event: StreamEvent = .{ .text_delta = source };
    try std.testing.expectEqualStrings(source, event.text_delta);
}

test "stop reasons are distinct" {
    try std.testing.expect(StopReason.end_turn != StopReason.interrupted);
}

test "a tool call delta carries an id and a JSON fragment" {
    const event: StreamEvent = .{ .tool_call_delta = .{
        .id = "toolu_01",
        .name = "read",
        .arguments = "{\"path\":\"/tm",
    } };
    try std.testing.expectEqualStrings("toolu_01", event.tool_call_delta.id);
    try std.testing.expectEqualStrings("{\"path\":\"/tm", event.tool_call_delta.arguments);
}

test "a continuation fragment carries only an id and more argument bytes" {
    const event: StreamEvent = .{ .tool_call_delta = .{ .id = "toolu_01", .arguments = "p\":1}" } };
    try std.testing.expectEqualStrings("", event.tool_call_delta.name);
}

test "usage separates cached input from fresh input" {
    const usage: Usage = .{
        .input_tokens = 12,
        .output_tokens = 40,
        .cache_read_tokens = 1_200,
        .cache_creation_tokens = 0,
    };
    // Cached tokens are counted apart because they are priced apart; folding
    // them into input_tokens would make the cost line wrong in exactly the
    // version that turns caching on.
    try std.testing.expectEqual(@as(u32, 12), usage.input_tokens);
    try std.testing.expectEqual(@as(u32, 1_200), usage.cache_read_tokens);
}

test "a rate limit carries the wait the server asked for" {
    const event: StreamEvent = .{ .err = .{
        .kind = .rate_limit,
        .message = "rate limited",
        .retry_after_ms = 1_800,
    } };
    try std.testing.expectEqual(@as(?u32, 1_800), event.err.retry_after_ms);
}

test "no retry-after means no instruction, not zero" {
    const event: StreamEvent = .{ .err = .{ .kind = .server, .message = "bad gateway" } };
    try std.testing.expect(event.err.retry_after_ms == null);
}

test "a tool-use stop is not an end-of-turn stop" {
    try std.testing.expect(StopReason.tool_use != StopReason.end_turn);
    try std.testing.expect(StopReason.refusal != StopReason.err);
}
