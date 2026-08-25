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

/// The longest chord tug will read. `ctrl+alt+shift+super+page_down` is 30
/// bytes, so this is the grammar's own ceiling plus room for one multi-byte
/// character — not a guess, and not a buffer anything writes into.
pub const max_chord_bytes: usize = 32;

/// The `KeyEvent` a chord spells, or null when the text is not a chord.
///
/// The exact inverse of `writeChord` over every chord `writeChord` can produce,
/// which is the property `every chord writeChord can spell, parseChord reads
/// back` asserts. Two things it accepts that `writeChord` never emits: the
/// modifiers in any order, because a person typing a config file should not
/// have to remember tug's order; and `space`, because `" " = "submit"` is a
/// legal TOML key that nobody can see in a diff.
///
/// Null is the only failure. There is no error set here for the same reason
/// there is none in the config stack: a typo in a keybind is a warning and a
/// default, never a shell that will not open.
pub fn parseChord(text: []const u8) ?KeyEvent {
    if (text.len == 0 or text.len > max_chord_bytes) return null;

    var mods: Mods = .none;
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '+')) |plus| {
        // A '+' in the last position is the key itself: `ctrl++` is ctrl and
        // the plus key. Without this, plus is the one character nobody can bind.
        if (plus + 1 == rest.len) break;

        const name = rest[0..plus];
        if (std.mem.eql(u8, name, "ctrl")) {
            mods.ctrl = true;
        } else if (std.mem.eql(u8, name, "alt")) {
            mods.alt = true;
        } else if (std.mem.eql(u8, name, "shift")) {
            mods.shift = true;
        } else if (std.mem.eql(u8, name, "super")) {
            mods.super = true;
        } else return null;

        rest = rest[plus + 1 ..];
    }

    return .{ .key = parseKey(rest) orelse return null, .mods = mods };
}

/// One key name: a tag name, `space`, `fN`, or a single codepoint.
fn parseKey(name: []const u8) ?Key {
    if (name.len == 0) return null;

    const named = [_]struct { text: []const u8, key: Key }{
        .{ .text = "enter", .key = .enter },
        .{ .text = "tab", .key = .tab },
        .{ .text = "backspace", .key = .backspace },
        .{ .text = "escape", .key = .escape },
        .{ .text = "delete", .key = .delete },
        .{ .text = "insert", .key = .insert },
        .{ .text = "up", .key = .up },
        .{ .text = "down", .key = .down },
        .{ .text = "left", .key = .left },
        .{ .text = "right", .key = .right },
        .{ .text = "home", .key = .home },
        .{ .text = "end", .key = .end },
        .{ .text = "page_up", .key = .page_up },
        .{ .text = "page_down", .key = .page_down },
        // The one alias. See `parseChord`'s comment.
        .{ .text = "space", .key = .{ .char = ' ' } },
    };
    for (named) |entry| {
        if (std.mem.eql(u8, name, entry.text)) return entry.key;
    }

    // `f` plus a number. `parseInt` into a u5 refuses 32 and above by
    // overflowing, which is the range check written once rather than twice.
    if (name[0] == 'f' and name.len >= 2) {
        if (std.fmt.parseInt(u5, name[1..], 10)) |number| {
            if (number >= 1) return .{ .f = number };
            return null;
        } else |_| {}
    }

    // Exactly one codepoint, which is what a character key is. Two codepoints
    // is not a key with a long name, it is a mistake — `abc` should be refused
    // rather than becoming `a`.
    const len = std.unicode.utf8ByteSequenceLength(name[0]) catch return null;
    if (len != name.len) return null;
    return .{ .char = std.unicode.utf8Decode(name) catch return null };
}

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

test "a chord parses back into the event that spells it" {
    const cases = [_]struct { text: []const u8, event: KeyEvent }{
        .{ .text = "a", .event = .{ .key = .{ .char = 'a' } } },
        .{ .text = "enter", .event = .{ .key = .enter } },
        .{ .text = "f5", .event = .{ .key = .{ .f = 5 } } },
        .{ .text = "f12", .event = .{ .key = .{ .f = 12 } } },
        .{ .text = "page_up", .event = .{ .key = .page_up } },
        .{ .text = "ctrl+j", .event = .{ .key = .{ .char = 'j' }, .mods = .{ .ctrl = true } } },
        .{ .text = "alt+enter", .event = .{ .key = .enter, .mods = .{ .alt = true } } },
        .{
            .text = "ctrl+shift+p",
            .event = .{ .key = .{ .char = 'p' }, .mods = .{ .ctrl = true, .shift = true } },
        },
        .{
            .text = "ctrl+alt+shift+super+f1",
            .event = .{
                .key = .{ .f = 1 },
                .mods = .{ .ctrl = true, .alt = true, .shift = true, .super = true },
            },
        },
        .{ .text = "é", .event = .{ .key = .{ .char = 'é' } } },
    };

    for (cases) |case| {
        const parsed = parseChord(case.text) orelse {
            std.debug.print("\nfailed to parse: {s}\n", .{case.text});
            return error.TestUnexpectedResult;
        };
        try testing.expect(parsed.eql(case.event));
    }
}

test "modifiers are order-insensitive and the spelling is not" {
    const canonical: KeyEvent = .{
        .key = .{ .char = 'p' },
        .mods = .{ .ctrl = true, .alt = true, .shift = true },
    };
    // Every order names the same chord.
    for ([_][]const u8{
        "ctrl+alt+shift+p",
        "shift+alt+ctrl+p",
        "alt+ctrl+shift+p",
    }) |text| {
        try testing.expect(parseChord(text).?.eql(canonical));
    }

    // But it writes back in exactly one of them, which is what lets two config
    // layers be compared by chord rather than by string.
    var buffer: [32]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try canonical.writeChord(&writer);
    try testing.expectEqualStrings("ctrl+alt+shift+p", writer.buffered());
}

test "every chord writeChord can spell, parseChord reads back" {
    // The property, over every key the decoder can produce. `f` starts at 1
    // because `.{ .f = 0 }` is representable and never decoded.
    const keys = [_]Key{
        .enter,
        .tab,
        .backspace,
        .escape,
        .delete,
        .insert,
        .up,
        .down,
        .left,
        .right,
        .home,
        .end,
        .page_up,
        .page_down,
        .{ .char = 'a' },
        .{ .char = 'Z' },
        .{ .char = '0' },
        .{ .char = ' ' },
        .{ .char = '+' },
        .{ .char = 'é' },
        .{ .f = 1 },
        .{ .f = 9 },
        .{ .f = 31 },
    };

    for (keys) |k| {
        // All sixteen modifier combinations.
        var bits: u4 = 0;
        while (true) : (bits += 1) {
            const event: KeyEvent = .{ .key = k, .mods = @bitCast(bits) };

            var buffer: [max_chord_bytes]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buffer);
            try event.writeChord(&writer);
            const text = writer.buffered();

            const parsed = parseChord(text) orelse {
                std.debug.print("\nnot parseable: '{s}'\n", .{text});
                return error.TestUnexpectedResult;
            };
            testing.expect(parsed.eql(event)) catch |err| {
                std.debug.print("\nround trip changed: '{s}'\n", .{text});
                return err;
            };

            if (bits == 0b1111) break;
        }
    }
}

test "space has a name because a space is not readable in a config file" {
    try testing.expect(parseChord("space").?.eql(.{ .key = .{ .char = ' ' } }));
    try testing.expect(parseChord("ctrl+space").?.eql(
        .{ .key = .{ .char = ' ' }, .mods = .{ .ctrl = true } },
    ));
    // The literal is accepted too; only the alias is unwritable.
    try testing.expect(parseChord(" ").?.eql(.{ .key = .{ .char = ' ' } }));
}

test "a trailing plus is a key, not a separator" {
    try testing.expect(parseChord("+").?.eql(.{ .key = .{ .char = '+' } }));
    try testing.expect(parseChord("ctrl++").?.eql(
        .{ .key = .{ .char = '+' }, .mods = .{ .ctrl = true } },
    ));
}

test "everything that is not a chord is null rather than a guess" {
    const refused = [_][]const u8{
        "", // nothing
        "ctrl+", // a modifier with no key
        "ctrl", // a modifier alone
        "hyper+a", // not a modifier tug has
        "ctrl+alt", // still no key
        "f0", // function keys are one-based
        "f32", // and stop at 31
        "f999", // overflow, not a wrap
        "fo", // an f that is not a function key
        "ctrl+j+k", // two keys
        "PageUp", // the spelling writeChord does not use
        "ctrl j", // the separator is +
        "abc", // more than one codepoint
        "\xff\xfe", // not UTF-8
        "ctrl+ctrl+ctrl+ctrl+ctrl+ctrl+ctrl+ctrl+a", // longer than the cap
    };
    for (refused) |text| {
        testing.expectEqual(@as(?KeyEvent, null), parseChord(text)) catch |err| {
            std.debug.print("\naccepted something that is not a chord: '{s}'\n", .{text});
            return err;
        };
    }
}
