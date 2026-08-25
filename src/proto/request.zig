//! What tug asks a model for.
//!
//! One shape, two very different APIs downstream: the Anthropic Messages API and
//! the OpenAI chat-completions shape both fall out of this through a pure
//! builder in Phase 4. Anything one API supports and the other does not stays
//! out of this type and lives in the builder — otherwise it becomes a lie in the
//! shared vocabulary, a field half the providers quietly ignore.
//!
//! `Content` is a tagged union with exactly one variant today. That is
//! deliberate: v0.7 adds images, and a union that already exists grows a variant
//! without changing the shape of every function that takes one.
//!
//! Everything here borrows. A request is built inside a per-request arena from a
//! conversation that outlives it, so nothing in this file owns memory or frees
//! any.

const std = @import("std");

pub const Role = enum { user, assistant };

/// One piece of a message's content.
///
/// The system prompt is deliberately not a `Role` — Anthropic takes it as a
/// top-level field and OpenAI as a message, and modelling it as a role would
/// force one of the two builders to unpick it again.
pub const Content = union(enum) {
    text: []const u8,
};

pub const Message = struct {
    role: Role,
    content: []const Content,
};

pub const Request = struct {
    model: []const u8,
    messages: []const Message,
    system: ?[]const u8 = null,
    /// Both APIs want a cap and Anthropic rejects a request without one. 4096 is
    /// large enough for a normal answer and small enough that a runaway costs
    /// cents rather than dollars. Config overrides it (Phase 6).
    max_tokens: u32 = 4096,
    /// Absent means "the provider's default", which is not the same as any
    /// particular number — which is why this is optional rather than defaulted.
    temperature: ?f32 = null,
};

test "a request defaults to something a provider will accept" {
    const messages = [_]Message{
        .{ .role = .user, .content = &.{.{ .text = "ship it" }} },
    };
    const request: Request = .{ .model = "claude-sonnet-4-5", .messages = &messages };

    try std.testing.expectEqual(@as(u32, 4096), request.max_tokens);
    try std.testing.expect(request.system == null);
    try std.testing.expect(request.temperature == null);
}

test "content is a tagged union so v0.7 can add an image without a reshape" {
    const content: Content = .{ .text = "hello" };
    try std.testing.expectEqualStrings("hello", content.text);
}

test "a multi-turn conversation is a flat message list" {
    const messages = [_]Message{
        .{ .role = .user, .content = &.{.{ .text = "what is a bollard" }} },
        .{ .role = .assistant, .content = &.{.{ .text = "a fixed post" }} },
        .{ .role = .user, .content = &.{.{ .text = "and a bollard pull" }} },
    };
    const request: Request = .{
        .model = "claude-sonnet-4-5",
        .messages = &messages,
        .system = "be terse",
    };

    try std.testing.expectEqual(@as(usize, 3), request.messages.len);
    try std.testing.expectEqual(Role.assistant, request.messages[1].role);
    try std.testing.expectEqualStrings("be terse", request.system.?);
}
