//! The event catalog.
//!
//! These names are stable-intent from v0.1: plugins and `--json` consumers will
//! match on them, so they are chosen once and then left alone. The *payloads*
//! stay unstable until the v0.10 freeze.
//!
//! The catalog lives in `tugproto` rather than in the bus itself because it
//! crosses boundaries — the bus is one consumer of it, not its owner.

const std = @import("std");

pub const Event = enum {
    session_start,
    input_submit,
    request_start,
    stream_delta,
    stream_end,
    tool_request,
    tool_decision,
    tool_result,
    turn_end,
    err,
    shutdown,

    /// The wire name. Identical to the tag name, which the test below enforces
    /// so the two can never drift.
    pub fn name(self: Event) []const u8 {
        return @tagName(self);
    }

    /// Parses a wire name back into a tag. Returns null for anything unknown,
    /// because an unrecognized event from a newer peer is a thing to ignore,
    /// not a thing to crash on.
    pub fn parse(text: []const u8) ?Event {
        return std.meta.stringToEnum(Event, text);
    }
};

/// The catalog with its payloads.
///
/// Tagged by `Event`, so the compiler enforces one arm per catalog name and the
/// two can never drift. The names are stable-intent from v0.1; these payloads
/// are not, and stay unstable until the v0.10 freeze.
///
/// **Slices borrow.** The publisher owns the bytes and they are valid only for
/// the duration of the `publish` call. A subscriber that needs them afterwards
/// copies them; this is what keeps the bus free of an allocator.
pub const Payload = union(Event) {
    session_start: void,
    input_submit: struct { text: []const u8 },
    request_start: void,
    stream_delta: struct { text: []const u8 },
    stream_end: void,
    tool_request: void,
    tool_decision: void,
    tool_result: void,
    turn_end: void,
    err: struct { message: []const u8 },
    shutdown: void,

    pub fn event(self: Payload) Event {
        return std.meta.activeTag(self);
    }
};

test "every payload arm reports its own event" {
    inline for (@typeInfo(Event).@"enum".fields) |field| {
        const tag: Event = @enumFromInt(field.value);
        const payload: Payload = switch (tag) {
            .input_submit => .{ .input_submit = .{ .text = "hi" } },
            .stream_delta => .{ .stream_delta = .{ .text = "hi" } },
            .err => .{ .err = .{ .message = "boom" } },
            inline else => |t| @unionInit(Payload, @tagName(t), {}),
        };
        try std.testing.expectEqual(tag, payload.event());
    }
}

test "every event name matches its tag" {
    inline for (@typeInfo(Event).@"enum".fields) |field| {
        const tag: Event = @enumFromInt(field.value);
        try std.testing.expectEqualStrings(field.name, tag.name());
    }
}

test "parse round-trips every event" {
    inline for (@typeInfo(Event).@"enum".fields) |field| {
        const tag: Event = @enumFromInt(field.value);
        try std.testing.expectEqual(tag, Event.parse(tag.name()).?);
    }
}

test "parse rejects an unknown name" {
    try std.testing.expectEqual(@as(?Event, null), Event.parse("tool_call_delta"));
}
