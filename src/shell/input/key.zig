//! What a keypress is, once the bytes stop mattering.
//!
//! The decoder's whole job is turning terminal-specific byte soup into these,
//! so that everything above it — the editor, the keymap, `/keys` — reasons
//! about `ctrl+shift+p` rather than about `\x1b[80;6u`. Two terminals that
//! encode the same chord differently produce the same `KeyEvent` here, which is
//! the point.

const std = @import("std");

/// Four modifiers, in the order the CSI-u and xterm encodings use them, so the
/// bit arithmetic in the decoder is a shift rather than a lookup.
pub const Mods = packed struct(u4) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,

    pub const none: Mods = .{};

    /// Decodes an xterm/CSI-u modifier parameter, which is the bitmask plus
    /// one. A zero parameter means the terminal sent the field but meant no
    /// modifiers, which is not the same as sending no field, and both arrive
    /// here as `none`.
    pub fn fromParam(param: u32) Mods {
        if (param == 0) return .none;
        const bits = param - 1;
        return .{
            .shift = bits & 0b0001 != 0,
            .alt = bits & 0b0010 != 0,
            .ctrl = bits & 0b0100 != 0,
            .super = bits & 0b1000 != 0,
        };
    }

    pub fn eql(self: Mods, other: Mods) bool {
        return @as(u4, @bitCast(self)) == @as(u4, @bitCast(other));
    }

    pub fn any(self: Mods) bool {
        return @as(u4, @bitCast(self)) != 0;
    }
};

pub const Key = union(enum) {
    /// A printable character. Always the *unmodified* codepoint: ctrl+a is
    /// `.{ .char = 'a' }` with `ctrl` set, never 0x01, so a keymap can be
    /// written the way a human says it out loud.
    char: u21,
    enter,
    tab,
    backspace,
    escape,
    delete,
    insert,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    /// Function keys, 1-based. F1 is `.{ .f = 1 }`.
    f: u5,

    pub fn eql(self: Key, other: Key) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .char => |c| c == other.char,
            .f => |n| n == other.f,
            else => true,
        };
    }
};

pub const KeyEvent = struct {
    key: Key,
    mods: Mods = .none,

    pub fn eql(self: KeyEvent, other: KeyEvent) bool {
        return self.key.eql(other.key) and self.mods.eql(other.mods);
    }

    /// The canonical chord spelling: `ctrl+shift+p`, `alt+enter`, `f5`.
    ///
    /// Modifier order is fixed rather than alphabetical so that a chord has
    /// exactly one spelling, which is what lets `/keys` detect a conflict
    /// between two config layers by comparing strings.
    pub fn writeChord(self: KeyEvent, out: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.mods.ctrl) try out.writeAll("ctrl+");
        if (self.mods.alt) try out.writeAll("alt+");
        if (self.mods.shift) try out.writeAll("shift+");
        if (self.mods.super) try out.writeAll("super+");

        switch (self.key) {
            .char => |c| {
                var buffer: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(c, &buffer) catch {
                    return out.writeAll("?");
                };
                try out.writeAll(buffer[0..len]);
            },
            .f => |n| try out.print("f{d}", .{n}),
            inline else => |_, tag| try out.writeAll(@tagName(tag)),
        }
    }
};

/// Text pasted through bracketed paste.
///
/// The bytes are borrowed from the decoder and stay valid only until the next
/// call into it. A consumer that needs to keep them copies them; nothing in the
/// input path allocates.
pub const PasteEvent = struct {
    bytes: []const u8,
};

pub const InputEvent = union(enum) {
    key: KeyEvent,
    paste: PasteEvent,
};

const testing = std.testing;

test "modifier parameters decode to the xterm bitmask" {
    try testing.expect(Mods.fromParam(1).eql(.none));
    try testing.expect(Mods.fromParam(2).eql(.{ .shift = true }));
    try testing.expect(Mods.fromParam(3).eql(.{ .alt = true }));
    try testing.expect(Mods.fromParam(5).eql(.{ .ctrl = true }));
    try testing.expect(Mods.fromParam(6).eql(.{ .ctrl = true, .shift = true }));
    try testing.expect(Mods.fromParam(8).eql(.{ .ctrl = true, .alt = true, .shift = true }));
}

test "a zero modifier parameter means no modifiers" {
    try testing.expect(Mods.fromParam(0).eql(.none));
}

test "chords have exactly one spelling" {
    const cases = [_]struct { event: KeyEvent, chord: []const u8 }{
        .{ .event = .{ .key = .{ .char = 'p' }, .mods = .{ .ctrl = true, .shift = true } }, .chord = "ctrl+shift+p" },
        .{ .event = .{ .key = .enter, .mods = .{ .alt = true } }, .chord = "alt+enter" },
        .{ .event = .{ .key = .{ .f = 5 } }, .chord = "f5" },
        .{ .event = .{ .key = .{ .char = 'a' } }, .chord = "a" },
        .{ .event = .{ .key = .page_up }, .chord = "page_up" },
        .{ .event = .{ .key = .{ .char = 'é' } }, .chord = "é" },
    };

    for (cases) |case| {
        var buffer: [32]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try case.event.writeChord(&writer);
        try testing.expectEqualStrings(case.chord, writer.buffered());
    }
}

test "key equality distinguishes payloads" {
    try testing.expect(Key.eql(.{ .char = 'a' }, .{ .char = 'a' }));
    try testing.expect(!Key.eql(.{ .char = 'a' }, .{ .char = 'b' }));
    try testing.expect(!Key.eql(.{ .f = 1 }, .{ .f = 2 }));
    try testing.expect(Key.eql(.enter, .enter));
    try testing.expect(!Key.eql(.enter, .tab));
}
