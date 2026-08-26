//! The conversation a request is built from.
//!
//! Freestanding, and that is not incidental: v0.4's sessions are this type with
//! a file behind it, and `tugcore` is where something a browser tab could run
//! belongs. No allocator of its own — the caller hands it a byte buffer and a
//! turn array, exactly as the editor and the queue already work. `zig build
//! wasm-check` is the gate, and it is a real one here.
//!
//! **What a cancelled turn leaves behind** is the interesting rule and it is
//! stated in two other places for the same reason (`DR-018`, `DR-019`):
//! cancellation ends a stream, it does not unwind one. Partial text is committed
//! with a marker; only a turn that produced nothing at all is dropped.

const std = @import("std");

const proto = @import("tugproto");

pub const Role = proto.Role;

pub const Turn = struct {
    role: Role,
    /// A slice of the conversation's own byte buffer.
    text: []const u8,
    /// True when the human stopped this turn part-way. The marker travels with
    /// the turn rather than being spliced into its text, so that a later reader
    /// — v0.4's session loader, `/export` — can tell the difference between a
    /// model that stopped and a model that was stopped.
    canceled: bool = false,
    /// What the provider reported, when it reported anything. Null on a user
    /// turn and on a cancelled one.
    stop_reason: ?proto.StopReason = null,
    usage: proto.Usage = .{},
};

pub const Error = error{
    /// The byte buffer or the turn array is full. Deliberately not a truncation:
    /// silently dropping the middle of a prompt means the model answers a
    /// question nobody asked, which is the worst failure available here.
    Full,
};

pub const Conversation = struct {
    bytes: []u8,
    turn_storage: []Turn,

    used: usize = 0,
    count: usize = 0,

    /// Where the in-flight assistant turn's text starts, once one is open.
    /// Null between turns, which is also what `commit` and `cancel` assert on.
    open_at: ?usize = null,

    /// Request-shaped scratch, filled by `request` and valid until the next call
    /// to it. Held here rather than returned by value because a `proto.Request`
    /// borrows slices that have to live somewhere.
    content_storage: []proto.Content,
    message_storage: []proto.Message,

    pub fn init(
        bytes: []u8,
        turn_storage: []Turn,
        content_storage: []proto.Content,
        message_storage: []proto.Message,
    ) Conversation {
        std.debug.assert(content_storage.len >= turn_storage.len);
        std.debug.assert(message_storage.len >= turn_storage.len);
        return .{
            .bytes = bytes,
            .turn_storage = turn_storage,
            .content_storage = content_storage,
            .message_storage = message_storage,
        };
    }

    pub fn turns(self: *const Conversation) []const Turn {
        return self.turn_storage[0..self.count];
    }

    pub fn isStreaming(self: *const Conversation) bool {
        return self.open_at != null;
    }

    /// Appends a finished user turn.
    pub fn appendUser(self: *Conversation, text: []const u8) Error!void {
        std.debug.assert(self.open_at == null);
        const stored = try self.store(text);
        try self.push(.{ .role = .user, .text = stored });
    }

    /// Opens the assistant turn a stream will fill.
    pub fn beginAssistant(self: *Conversation) Error!void {
        std.debug.assert(self.open_at == null);
        if (self.count == self.turn_storage.len) return error.Full;
        self.open_at = self.used;
    }

    /// Appends one delta to the open turn.
    ///
    /// A full buffer ends the turn's growth rather than failing the stream: the
    /// text so far is real and the user is reading it. The caller learns from
    /// the error and can stop; what it must not do is discard what arrived.
    pub fn appendDelta(self: *Conversation, text: []const u8) Error!void {
        std.debug.assert(self.open_at != null);
        _ = try self.store(text);
    }

    /// Closes the open turn as the model finished it.
    pub fn commit(self: *Conversation, stop_reason: proto.StopReason, usage: proto.Usage) Error!void {
        const at = self.open_at orelse unreachable;
        self.open_at = null;
        try self.push(.{
            .role = .assistant,
            .text = self.bytes[at..self.used],
            .stop_reason = stop_reason,
            .usage = usage,
        });
    }

    /// Closes the open turn as the human stopped it.
    ///
    /// A turn that produced nothing is dropped rather than committed empty: an
    /// empty assistant turn in the history would be sent to the model on the
    /// next request, which is a message saying nothing, from an assistant, in
    /// the middle of a conversation.
    pub fn cancel(self: *Conversation, usage: proto.Usage) Error!void {
        const at = self.open_at orelse unreachable;
        self.open_at = null;

        const text = self.bytes[at..self.used];
        if (text.len == 0) return;

        try self.push(.{
            .role = .assistant,
            .text = text,
            .canceled = true,
            .usage = usage,
        });
    }

    /// The request for the next turn.
    ///
    /// Every committed turn, and never the in-flight one — a request built
    /// mid-stream would contain half of the answer it is asking for. Borrows the
    /// conversation's storage and is valid until the next call.
    pub fn request(self: *Conversation, model: []const u8, system: ?[]const u8) proto.Request {
        for (self.turns(), 0..) |turn, i| {
            self.content_storage[i] = .{ .text = turn.text };
            self.message_storage[i] = .{
                .role = turn.role,
                .content = self.content_storage[i .. i + 1],
            };
        }
        return .{
            .model = model,
            .messages = self.message_storage[0..self.count],
            .system = system,
        };
    }

    /// Every token this conversation has cost, across every turn.
    pub fn totalUsage(self: *const Conversation) proto.Usage {
        var total: proto.Usage = .{};
        for (self.turns()) |turn| {
            total.input_tokens +|= turn.usage.input_tokens;
            total.output_tokens +|= turn.usage.output_tokens;
            total.cache_read_tokens +|= turn.usage.cache_read_tokens;
            total.cache_creation_tokens +|= turn.usage.cache_creation_tokens;
        }
        return total;
    }

    fn store(self: *Conversation, text: []const u8) Error![]const u8 {
        if (self.used + text.len > self.bytes.len) return error.Full;
        const at = self.used;
        @memcpy(self.bytes[at..][0..text.len], text);
        self.used += text.len;
        return self.bytes[at..self.used];
    }

    fn push(self: *Conversation, turn: Turn) Error!void {
        if (self.count == self.turn_storage.len) return error.Full;
        self.turn_storage[self.count] = turn;
        self.count += 1;
    }
};

const testing = std.testing;

/// Storage for a test conversation, sized once.
fn Fixture(comptime turns: usize, comptime bytes: usize) type {
    return struct {
        bytes: [bytes]u8 = undefined,
        turns: [turns]Turn = undefined,
        content: [turns]proto.Content = undefined,
        messages: [turns]proto.Message = undefined,

        const Self = @This();

        fn conversation(self: *Self) Conversation {
            return .init(&self.bytes, &self.turns, &self.content, &self.messages);
        }
    };
}

test "a round trip: user, assistant, user" {
    var storage: Fixture(8, 1024) = .{};
    var conversation = storage.conversation();

    try conversation.appendUser("what is a bollard");
    try conversation.beginAssistant();
    try conversation.appendDelta("a fixed");
    try conversation.appendDelta(" post");
    try conversation.commit(.end_turn, .{ .input_tokens = 12, .output_tokens = 4 });
    try conversation.appendUser("and a bollard pull");

    const turns = conversation.turns();
    try testing.expectEqual(@as(usize, 3), turns.len);
    try testing.expectEqualStrings("what is a bollard", turns[0].text);
    try testing.expectEqual(Role.assistant, turns[1].role);
    try testing.expectEqualStrings("a fixed post", turns[1].text);
    try testing.expectEqual(proto.StopReason.end_turn, turns[1].stop_reason.?);
    try testing.expectEqualStrings("and a bollard pull", turns[2].text);
}

test "the request carries every committed turn and never the in-flight one" {
    // A request built mid-stream would contain half of the answer it is asking
    // for.
    var storage: Fixture(8, 1024) = .{};
    var conversation = storage.conversation();

    try conversation.appendUser("first");
    try conversation.beginAssistant();
    try conversation.appendDelta("partial");

    const request = conversation.request("claude-sonnet-4-5", "be terse");
    try testing.expectEqual(@as(usize, 1), request.messages.len);
    try testing.expectEqualStrings("first", request.messages[0].content[0].text);
    try testing.expectEqualStrings("be terse", request.system.?);
    try testing.expectEqualStrings("claude-sonnet-4-5", request.model);
}

test "cancelling mid-turn commits the partial text with a marker" {
    // `DR-018`'s rule, enforced where the history is kept: cancellation ends a
    // stream, it does not unwind one.
    var storage: Fixture(8, 1024) = .{};
    var conversation = storage.conversation();

    try conversation.appendUser("why is a tugboat rated in bollard pull");
    try conversation.beginAssistant();
    try conversation.appendDelta("A tugboat is");
    try conversation.cancel(.{ .input_tokens = 9, .output_tokens = 3 });

    const turns = conversation.turns();
    try testing.expectEqual(@as(usize, 2), turns.len);
    try testing.expect(turns[1].canceled);
    try testing.expectEqualStrings("A tugboat is", turns[1].text);
    // No stop reason: the provider never gave one, and inventing `end_turn`
    // would make a stopped answer indistinguishable from a finished one.
    try testing.expect(turns[1].stop_reason == null);
    // Usage so far is kept. The tokens were spent whether or not the answer
    // arrived.
    try testing.expectEqual(@as(u32, 9), turns[1].usage.input_tokens);
}

test "cancelling before any delta drops the turn rather than committing an empty one" {
    // An empty assistant turn would be sent to the model on the next request:
    // a message saying nothing, from an assistant, mid-conversation.
    var storage: Fixture(8, 1024) = .{};
    var conversation = storage.conversation();

    try conversation.appendUser("hello");
    try conversation.beginAssistant();
    try conversation.cancel(.{});

    try testing.expectEqual(@as(usize, 1), conversation.turns().len);
    try testing.expect(!conversation.isStreaming());
}

test "a cancelled turn is still history the next request carries" {
    var storage: Fixture(8, 1024) = .{};
    var conversation = storage.conversation();

    try conversation.appendUser("first");
    try conversation.beginAssistant();
    try conversation.appendDelta("partial");
    try conversation.cancel(.{});
    try conversation.appendUser("carry on");

    const request = conversation.request("m", null);
    try testing.expectEqual(@as(usize, 3), request.messages.len);
    try testing.expectEqualStrings("partial", request.messages[1].content[0].text);
}

test "a model switch mid-conversation keeps the history" {
    // Deliberate: the point of switching is to ask the same conversation of a
    // different model.
    var storage: Fixture(8, 1024) = .{};
    var conversation = storage.conversation();

    try conversation.appendUser("first");
    try conversation.beginAssistant();
    try conversation.appendDelta("answer");
    try conversation.commit(.end_turn, .{});

    const before = conversation.request("claude-sonnet-4-5", null);
    try testing.expectEqual(@as(usize, 2), before.messages.len);

    const after = conversation.request("llama3.1", null);
    try testing.expectEqualStrings("llama3.1", after.model);
    try testing.expectEqual(@as(usize, 2), after.messages.len);
    try testing.expectEqualStrings("first", after.messages[0].content[0].text);
}

test "a conversation past its byte buffer refuses rather than truncating" {
    // Silently dropping the middle of a prompt means the model answers a
    // question nobody asked.
    var storage: Fixture(8, 16) = .{};
    var conversation = storage.conversation();

    try conversation.appendUser("0123456789");
    try testing.expectError(error.Full, conversation.appendUser("0123456789"));
    // And the refusal left the conversation usable.
    try testing.expectEqual(@as(usize, 1), conversation.turns().len);
}

test "a conversation past its turn array refuses rather than overwriting" {
    var storage: Fixture(2, 1024) = .{};
    var conversation = storage.conversation();

    try conversation.appendUser("one");
    try conversation.appendUser("two");
    try testing.expectError(error.Full, conversation.appendUser("three"));
}

test "a delta that does not fit ends the growth and keeps what arrived" {
    var storage: Fixture(8, 24) = .{};
    var conversation = storage.conversation();

    try conversation.beginAssistant();
    try conversation.appendDelta("0123456789");
    try testing.expectError(error.Full, conversation.appendDelta("0123456789 and more"));

    // The caller stops; what it must not do is throw away the text the user has
    // already read.
    try conversation.commit(.end_turn, .{});
    try testing.expectEqualStrings("0123456789", conversation.turns()[0].text);
}

test "usage accumulates across turns" {
    var storage: Fixture(8, 1024) = .{};
    var conversation = storage.conversation();

    try conversation.beginAssistant();
    try conversation.appendDelta("a");
    try conversation.commit(.end_turn, .{ .input_tokens = 10, .output_tokens = 2, .cache_read_tokens = 100 });
    try conversation.beginAssistant();
    try conversation.appendDelta("b");
    try conversation.commit(.end_turn, .{ .input_tokens = 20, .output_tokens = 3, .cache_read_tokens = 200 });

    const total = conversation.totalUsage();
    try testing.expectEqual(@as(u32, 30), total.input_tokens);
    try testing.expectEqual(@as(u32, 5), total.output_tokens);
    try testing.expectEqual(@as(u32, 300), total.cache_read_tokens);
}

test "usage saturates rather than wrapping" {
    // A wrapped total would render a cost line that is wrong by billions, and
    // it would look like a plausible number.
    var storage: Fixture(4, 64) = .{};
    var conversation = storage.conversation();

    for (0..2) |_| {
        try conversation.beginAssistant();
        try conversation.appendDelta("x");
        try conversation.commit(.end_turn, .{ .output_tokens = std.math.maxInt(u32) });
    }

    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), conversation.totalUsage().output_tokens);
}

test "an empty conversation asks a question with no history" {
    var storage: Fixture(4, 64) = .{};
    var conversation = storage.conversation();

    const request = conversation.request("m", null);
    try testing.expectEqual(@as(usize, 0), request.messages.len);
    try testing.expect(request.system == null);
}
