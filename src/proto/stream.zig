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
};

pub const StopReason = enum {
    /// The model finished on its own.
    end_turn,
    /// The response hit the output token limit.
    max_tokens,
    /// The human interrupted.
    interrupted,
    /// The stream ended because of an error; an `err` event carries the detail.
    err,
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
};

/// One event in a response stream.
///
/// `text_delta` carries a borrowed slice rather than owned memory: the producer
/// owns the bytes until the consumer returns, which keeps the whole streaming
/// path allocation-free.
pub const StreamEvent = union(enum) {
    text_delta: []const u8,
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
