//! Bytes in, `InputEvent`s out.
//!
//! This is the most classically buggy component in terminal software, so it is
//! built to be boring: a pure function of its buffer, no IO, no allocation, no
//! blocking. Everything that makes decoding hard — reads that split a sequence
//! in half, terminals that invent their own escapes, a paste containing an
//! escape sequence — is a property this can be tested for rather than a
//! situation that has to be reproduced by hand.
//!
//! Three rules hold everywhere:
//!
//! **Never panic, never hang, always make progress.** An input stream is
//! attacker-adjacent: it is whatever the terminal, the remote host, or a
//! pasted payload decided to send. Unknown sequences are swallowed to their
//! terminator under a length cap and dropped. Malformed UTF-8 becomes U+FFFD.
//! There is no input for which the right answer is to stop.
//!
//! **Partial input is not an error.** `next` returns null when the buffer holds
//! the beginning of something; the caller reads more and asks again. A
//! codepoint split across two reads decodes as one character.
//!
//! **Paste is untrusted.** Content between the bracketed-paste markers is
//! stripped of ESC and every C0 byte except tab and newline before it becomes
//! an event. Terminal escape sequences that arrive inside a paste and are
//! echoed back out are a well-known injection vector, and the place to stop
//! that is here, once, rather than in every consumer.

const std = @import("std");

const key_mod = @import("key.zig");

pub const Key = key_mod.Key;
pub const Mods = key_mod.Mods;
pub const KeyEvent = key_mod.KeyEvent;
pub const PasteEvent = key_mod.PasteEvent;
pub const InputEvent = key_mod.InputEvent;

/// Everything the decoder is allowed to do with a byte sequence it does not
/// recognize is bounded by this. A terminal that starts an escape sequence and
/// never terminates it cannot make the decoder buffer without limit.
pub const unknown_sequence_cap: usize = 64;

/// How long a lone ESC waits for a continuation before it is taken to mean the
/// Escape key.
///
/// Only relevant when the kitty keyboard protocol is inactive. With the
/// protocol on, Escape arrives as an unambiguous CSI-u sequence and no waiting
/// happens at all — which is one of the two reasons the protocol is worth
/// probing for (`DR-003`).
///
/// 30 ms is the usual compromise: long enough that a function key's bytes
/// arrive together even over ssh on a bad link, short enough that pressing
/// Escape does not feel laggy.
pub const escape_timeout_ms: u32 = 30;

pub const Decoder = struct {
    /// Caller-owned. Holds bytes that have arrived but not yet decoded, plus
    /// the accumulating content of a paste.
    scratch: []u8,
    len: usize = 0,
    /// True while the terminal is speaking the kitty keyboard protocol, which
    /// removes the lone-ESC ambiguity entirely.
    kitty_active: bool = false,
    /// Bytes discarded as unrecognized. Surfaced by `--debug-keys` and worth
    /// watching: a terminal that trips this constantly is a terminal whose
    /// sequences belong in the corpus.
    dropped_sequences: usize = 0,

    in_paste: bool = false,
    /// How much of `scratch` the accumulated paste content occupies. The paste
    /// grows at the front while undecoded bytes sit behind it.
    paste_len: usize = 0,
    /// A paste that was handed out last call and still occupies the front of
    /// the buffer. Events borrow `scratch`, so the bytes cannot be dropped
    /// until the caller comes back for the next event.
    delivered_paste_len: usize = 0,

    pub fn init(scratch: []u8) Decoder {
        std.debug.assert(scratch.len >= unknown_sequence_cap * 2);
        return .{ .scratch = scratch };
    }

    pub fn setKittyActive(self: *Decoder, active: bool) void {
        self.kitty_active = active;
    }

    /// Appends raw bytes. Silently drops what will not fit, because a decoder
    /// that fails on a full buffer gives the caller nothing useful to do and a
    /// terminal that overruns this is already misbehaving.
    pub fn feed(self: *Decoder, bytes: []const u8) void {
        const room = self.scratch.len - self.len;
        const take = @min(room, bytes.len);
        @memcpy(self.scratch[self.len..][0..take], bytes[0..take]);
        self.len += take;
    }

    pub fn pending(self: *const Decoder) usize {
        return self.len;
    }

    /// Decodes the next event, or null when the buffer is empty or holds only
    /// the start of a sequence.
    ///
    /// Returned slices borrow `scratch` and stay valid until the next call into
    /// the decoder.
    pub fn next(self: *Decoder) ?InputEvent {
        // Untrusted input in a ReleaseSmall binary. The roadmap's rule is that
        // every parser facing input the user did not write keeps its safety
        // checks, and this is the first one.
        @setRuntimeSafety(true);

        // Reclaim the paste handed out last call. This is the moment its
        // borrow expires, which is exactly what the doc comment promises.
        if (self.delivered_paste_len > 0) {
            self.consume(self.delivered_paste_len);
            self.delivered_paste_len = 0;
        }

        while (true) {
            if (self.len == 0) return null;

            if (self.in_paste) {
                if (self.continuePaste()) |event| return event;
                return null;
            }

            const result = self.decodeOne(self.scratch[0..self.len]);
            switch (result) {
                .incomplete => return null,
                .event => |decoded| {
                    self.consume(decoded.consumed);
                    return decoded.event;
                },
                .paste_start => |consumed| {
                    self.consume(consumed);
                    self.in_paste = true;
                    self.paste_len = 0;
                },
                .discard => |consumed| {
                    self.consume(consumed);
                    self.dropped_sequences += 1;
                },
            }
        }
    }

    /// Called when the caller's poll timed out with bytes still buffered.
    ///
    /// This is what resolves the lone-ESC ambiguity: silence for
    /// `escape_timeout_ms` means the ESC was the Escape key rather than the
    /// start of a sequence. Anything else still buffered at that point is a
    /// sequence the terminal abandoned, so it is dropped.
    pub fn flushPending(self: *Decoder) ?InputEvent {
        if (self.len == 0) return null;

        if (self.scratch[0] == 0x1b and !self.kitty_active) {
            if (self.len == 1) {
                self.consume(1);
                return .{ .key = .{ .key = .escape } };
            }
        }

        // A partial sequence that stopped arriving. Drop it rather than let it
        // poison the next real keypress.
        self.dropped_sequences += 1;
        self.len = 0;
        return null;
    }

    fn consume(self: *Decoder, count: usize) void {
        std.debug.assert(count <= self.len);
        std.mem.copyForwards(u8, self.scratch[0 .. self.len - count], self.scratch[count..self.len]);
        self.len -= count;
    }

    const Decoded = struct { event: InputEvent, consumed: usize };
    const Result = union(enum) {
        incomplete,
        event: Decoded,
        paste_start: usize,
        discard: usize,
    };

    fn decodeOne(self: *Decoder, bytes: []const u8) Result {
        const first = bytes[0];

        if (first == 0x1b) return self.decodeEscape(bytes);
        if (first < 0x20) return control(first);
        if (first == 0x7f) return keyEvent(.backspace, .none, 1);
        if (first < 0x80) return keyEvent(.{ .char = first }, .none, 1);

        return decodeUtf8(bytes);
    }

    fn decodeEscape(self: *Decoder, bytes: []const u8) Result {
        if (bytes.len == 1) return .incomplete;

        switch (bytes[1]) {
            '[' => return self.decodeCsi(bytes),
            'O' => return decodeSs3(bytes),
            0x1b => {
                // ESC ESC. The terminal is telling us about a real Escape
                // press followed by something else, or alt+Escape. Take the
                // first as Escape and let the second decode on its own.
                return keyEvent(.escape, .none, 1);
            },
            else => {
                // Alt as an ESC prefix: the legacy encoding of alt+<key>.
                const inner = self.decodeOne(bytes[1..]);
                return switch (inner) {
                    .event => |decoded| .{ .event = .{
                        .event = withAlt(decoded.event),
                        .consumed = decoded.consumed + 1,
                    } },
                    .incomplete => .incomplete,
                    .paste_start => |consumed| .{ .paste_start = consumed + 1 },
                    .discard => |consumed| .{ .discard = consumed + 1 },
                };
            },
        }
    }

    fn decodeCsi(self: *Decoder, bytes: []const u8) Result {
        _ = self;
        std.debug.assert(bytes[0] == 0x1b and bytes[1] == '[');

        // CSI is ESC [ <parameter bytes> <intermediate bytes> <final byte>.
        // Parameters are 0x30-0x3f, intermediates 0x20-0x2f, final 0x40-0x7e.
        var index: usize = 2;
        while (index < bytes.len and bytes[index] >= 0x30 and bytes[index] <= 0x3f) index += 1;
        const params_end = index;
        while (index < bytes.len and bytes[index] >= 0x20 and bytes[index] <= 0x2f) index += 1;

        if (index >= bytes.len) {
            // Still arriving — unless it has gone on so long that no real
            // sequence could still be forming.
            if (bytes.len > unknown_sequence_cap) return .{ .discard = bytes.len };
            return .incomplete;
        }

        const final = bytes[index];
        const consumed = index + 1;
        if (final < 0x40 or final > 0x7e) return .{ .discard = consumed };

        const params = bytes[2..params_end];

        // Bracketed paste markers come through as CSI 200~ and CSI 201~ and are
        // checked before anything else, because inside a paste every other
        // interpretation is wrong.
        if (final == '~' and std.mem.eql(u8, params, "200")) return .{ .paste_start = consumed };

        var iterator = ParamIterator{ .bytes = params };
        const first = iterator.next() orelse 0;
        const second = iterator.next() orelse 0;
        const mods: Mods = .fromParam(second);

        return switch (final) {
            'A' => keyEvent(.up, mods, consumed),
            'B' => keyEvent(.down, mods, consumed),
            'C' => keyEvent(.right, mods, consumed),
            'D' => keyEvent(.left, mods, consumed),
            'H' => keyEvent(.home, mods, consumed),
            'F' => keyEvent(.end, mods, consumed),
            'P' => keyEvent(.{ .f = 1 }, mods, consumed),
            'Q' => keyEvent(.{ .f = 2 }, mods, consumed),
            'R' => keyEvent(.{ .f = 3 }, mods, consumed),
            'S' => keyEvent(.{ .f = 4 }, mods, consumed),
            'u' => decodeCsiU(first, mods, consumed),
            '~' => decodeTilde(first, mods, consumed),
            // A valid CSI we have no meaning for — a cursor position report, a
            // device attribute reply, a mouse event we never asked for.
            else => .{ .discard = consumed },
        };
    }

    fn continuePaste(self: *Decoder) ?InputEvent {
        const end_marker = "\x1b[201~";

        const tail = self.scratch[self.paste_len..self.len];
        if (std.mem.indexOf(u8, tail, end_marker)) |offset| {
            const raw = tail[0..offset];
            const sanitized_len = sanitizeInto(self.scratch[self.paste_len..], raw);

            const total = self.paste_len + sanitized_len;
            const content = self.scratch[0..total];

            // Drop the marker and everything the paste covered, keeping
            // whatever arrived after it.
            const after = self.paste_len + offset + end_marker.len;
            const remaining = self.len - after;
            std.mem.copyForwards(u8, self.scratch[total..][0..remaining], self.scratch[after..self.len]);
            self.len = total + remaining;
            self.in_paste = false;
            self.paste_len = 0;
            self.delivered_paste_len = total;

            return .{ .paste = .{ .bytes = content } };
        }

        // No end marker yet. Sanitize what is certainly complete and keep the
        // tail that might contain a partial marker.
        const safe_len = if (tail.len > end_marker.len) tail.len - end_marker.len else 0;
        if (safe_len > 0) {
            const kept = sanitizeInto(self.scratch[self.paste_len..], tail[0..safe_len]);
            const leftover = tail.len - safe_len;
            std.mem.copyForwards(
                u8,
                self.scratch[self.paste_len + kept ..][0..leftover],
                self.scratch[self.paste_len + safe_len .. self.len],
            );
            self.paste_len += kept;
            self.len = self.paste_len + leftover;
        }
        return null;
    }
};

/// Copies `source` into `destination` keeping only what is safe to hand on.
///
/// ESC and the C0 controls are dropped; tab and newline survive because a
/// pasted code block is full of both. `source` and `destination` may overlap as
/// long as `destination` starts no later, which is how the paste is compacted
/// in place.
fn sanitizeInto(destination: []u8, source: []const u8) usize {
    var out: usize = 0;
    for (source) |byte| {
        const keep = switch (byte) {
            '\n', '\t' => true,
            // Everything else in C0 goes, carriage return included: a pasted
            // CRLF arrives as a plain newline rather than two line breaks.
            0x00...0x08, 0x0b...0x1f, 0x7f => false,
            else => true,
        };
        if (keep) {
            destination[out] = byte;
            out += 1;
        }
    }
    return out;
}

fn withAlt(event: InputEvent) InputEvent {
    return switch (event) {
        .key => |k| .{ .key = .{ .key = k.key, .mods = .{
            .shift = k.mods.shift,
            .alt = true,
            .ctrl = k.mods.ctrl,
            .super = k.mods.super,
        } } },
        .paste => event,
    };
}

fn keyEvent(k: Key, mods: Mods, consumed: usize) Decoder.Result {
    return .{ .event = .{ .event = .{ .key = .{ .key = k, .mods = mods } }, .consumed = consumed } };
}

fn control(byte: u8) Decoder.Result {
    return switch (byte) {
        // Named keys win over their control-character spelling: Enter is Enter,
        // not ctrl+m, because that is what the user pressed and what a keymap
        // will say.
        0x0d => keyEvent(.enter, .none, 1),
        0x09 => keyEvent(.tab, .none, 1),
        0x0a => keyEvent(.{ .char = 'j' }, .{ .ctrl = true }, 1),
        0x08 => keyEvent(.backspace, .{ .ctrl = true }, 1),
        0x00 => keyEvent(.{ .char = ' ' }, .{ .ctrl = true }, 1),
        // The rest of C0 is ctrl plus a letter, reported as the letter so a
        // keymap can be written the way it is spoken.
        0x01...0x07, 0x0b, 0x0c, 0x0e...0x1a => keyEvent(
            .{ .char = @as(u21, byte) + 'a' - 1 },
            .{ .ctrl = true },
            1,
        ),
        else => keyEvent(.{ .char = byte }, .{ .ctrl = true }, 1),
    };
}

fn decodeSs3(bytes: []const u8) Decoder.Result {
    if (bytes.len < 3) return .incomplete;
    return switch (bytes[2]) {
        'A' => keyEvent(.up, .none, 3),
        'B' => keyEvent(.down, .none, 3),
        'C' => keyEvent(.right, .none, 3),
        'D' => keyEvent(.left, .none, 3),
        'H' => keyEvent(.home, .none, 3),
        'F' => keyEvent(.end, .none, 3),
        'P' => keyEvent(.{ .f = 1 }, .none, 3),
        'Q' => keyEvent(.{ .f = 2 }, .none, 3),
        'R' => keyEvent(.{ .f = 3 }, .none, 3),
        'S' => keyEvent(.{ .f = 4 }, .none, 3),
        else => .{ .discard = 3 },
    };
}

/// CSI `<codepoint>` ; `<modifiers>` u — the kitty keyboard protocol.
///
/// This is where shift+enter comes from: the legacy encoding has no way to say
/// it, so a terminal without this protocol cannot distinguish it from Enter and
/// the editor falls back to alt+enter.
fn decodeCsiU(codepoint: u32, mods: Mods, consumed: usize) Decoder.Result {
    const k: Key = switch (codepoint) {
        13 => .enter,
        9 => .tab,
        27 => .escape,
        127, 8 => .backspace,
        else => blk: {
            if (codepoint > std.math.maxInt(u21)) return .{ .discard = consumed };
            const c: u21 = @intCast(codepoint);
            if (!std.unicode.utf8ValidCodepoint(c)) return .{ .discard = consumed };
            break :blk .{ .char = c };
        },
    };
    return keyEvent(k, mods, consumed);
}

fn decodeTilde(number: u32, mods: Mods, consumed: usize) Decoder.Result {
    const k: Key = switch (number) {
        1, 7 => .home,
        2 => .insert,
        3 => .delete,
        4, 8 => .end,
        5 => .page_up,
        6 => .page_down,
        11...15 => .{ .f = @intCast(number - 10) },
        // 16 is skipped by the historical encoding, and so is 22.
        17...21 => .{ .f = @intCast(number - 11) },
        23, 24 => .{ .f = @intCast(number - 12) },
        else => return .{ .discard = consumed },
    };
    return keyEvent(k, mods, consumed);
}

fn decodeUtf8(bytes: []const u8) Decoder.Result {
    const length = std.unicode.utf8ByteSequenceLength(bytes[0]) catch {
        // Not a valid leading byte. Emit the replacement character and move on
        // by exactly one, so a run of garbage produces a run of replacements
        // rather than swallowing the valid byte that follows it.
        return keyEvent(.{ .char = 0xfffd }, .none, 1);
    };

    // The rest of the codepoint has not arrived yet. This is the split-read
    // case, and it is normal rather than exceptional.
    if (bytes.len < length) return .incomplete;

    const codepoint = std.unicode.utf8Decode(bytes[0..length]) catch {
        return keyEvent(.{ .char = 0xfffd }, .none, length);
    };
    return keyEvent(.{ .char = codepoint }, .none, length);
}

/// Semicolon-separated CSI parameters. An empty parameter means "default",
/// which the callers treat as zero.
const ParamIterator = struct {
    bytes: []const u8,
    index: usize = 0,
    done: bool = false,

    fn next(self: *ParamIterator) ?u32 {
        if (self.done) return null;
        if (self.index >= self.bytes.len) {
            self.done = true;
            return null;
        }

        var value: u32 = 0;
        while (self.index < self.bytes.len) : (self.index += 1) {
            const byte = self.bytes[self.index];
            if (byte == ';') {
                self.index += 1;
                return value;
            }
            if (byte < '0' or byte > '9') {
                // A private-use or intermediate byte. Everything from here on
                // is not a parameter.
                self.done = true;
                return value;
            }
            // Saturate rather than overflow: a terminal sending a twenty-digit
            // parameter will not be understood anyway, and wrapping would turn
            // nonsense into a plausible-looking key.
            value = std.math.mul(u32, value, 10) catch std.math.maxInt(u32);
            value = std.math.add(u32, value, byte - '0') catch std.math.maxInt(u32);
        }
        self.done = true;
        return value;
    }
};

// --- tests ----------------------------------------------------------------

const testing = std.testing;

fn expectSingleKey(bytes: []const u8, key: Key, mods: Mods) !void {
    var scratch: [256]u8 = undefined;
    var decoder: Decoder = .init(&scratch);
    decoder.feed(bytes);

    const event = decoder.next() orelse return error.NoEvent;
    try testing.expect(event == .key);
    try testing.expect(event.key.key.eql(key));
    try testing.expect(event.key.mods.eql(mods));
    try testing.expectEqual(@as(?InputEvent, null), decoder.next());
}

/// The same input, delivered one byte per `feed`, must produce the same events.
/// This is the partial-sequence guarantee, and it is the property most likely
/// to break when the decoder is changed.
fn expectSingleKeyBytewise(bytes: []const u8, key: Key, mods: Mods) !void {
    var scratch: [256]u8 = undefined;
    var decoder: Decoder = .init(&scratch);

    var found: ?InputEvent = null;
    for (bytes) |byte| {
        decoder.feed(&[_]u8{byte});
        if (decoder.next()) |event| {
            try testing.expectEqual(@as(?InputEvent, null), found);
            found = event;
        }
    }

    const event = found orelse return error.NoEvent;
    try testing.expect(event == .key);
    try testing.expect(event.key.key.eql(key));
    try testing.expect(event.key.mods.eql(mods));
}

test "legacy sequences decode, whole and one byte at a time" {
    const cases = [_]struct { bytes: []const u8, key: Key, mods: Mods }{
        .{ .bytes = "a", .key = .{ .char = 'a' }, .mods = .none },
        .{ .bytes = "Z", .key = .{ .char = 'Z' }, .mods = .none },
        .{ .bytes = "\x03", .key = .{ .char = 'c' }, .mods = .{ .ctrl = true } },
        .{ .bytes = "\x01", .key = .{ .char = 'a' }, .mods = .{ .ctrl = true } },
        .{ .bytes = "\r", .key = .enter, .mods = .none },
        .{ .bytes = "\t", .key = .tab, .mods = .none },
        .{ .bytes = "\x7f", .key = .backspace, .mods = .none },
        .{ .bytes = "\x1b[A", .key = .up, .mods = .none },
        .{ .bytes = "\x1b[B", .key = .down, .mods = .none },
        .{ .bytes = "\x1b[C", .key = .right, .mods = .none },
        .{ .bytes = "\x1b[D", .key = .left, .mods = .none },
        .{ .bytes = "\x1bOA", .key = .up, .mods = .none },
        .{ .bytes = "\x1b[1;5A", .key = .up, .mods = .{ .ctrl = true } },
        .{ .bytes = "\x1b[1;2C", .key = .right, .mods = .{ .shift = true } },
        .{ .bytes = "\x1b[3~", .key = .delete, .mods = .none },
        .{ .bytes = "\x1b[5~", .key = .page_up, .mods = .none },
        .{ .bytes = "\x1b[6~", .key = .page_down, .mods = .none },
        .{ .bytes = "\x1b[2~", .key = .insert, .mods = .none },
        .{ .bytes = "\x1b[H", .key = .home, .mods = .none },
        .{ .bytes = "\x1b[F", .key = .end, .mods = .none },
        .{ .bytes = "\x1b[15~", .key = .{ .f = 5 }, .mods = .none },
        .{ .bytes = "\x1b[24~", .key = .{ .f = 12 }, .mods = .none },
        .{ .bytes = "\x1bOP", .key = .{ .f = 1 }, .mods = .none },
        .{ .bytes = "\x1bb", .key = .{ .char = 'b' }, .mods = .{ .alt = true } },
        .{ .bytes = "\x1bf", .key = .{ .char = 'f' }, .mods = .{ .alt = true } },
        .{ .bytes = "\xc3\xa9", .key = .{ .char = 'é' }, .mods = .none },
        .{ .bytes = "\xe4\xb8\xad", .key = .{ .char = '中' }, .mods = .none },
        .{ .bytes = "\xf0\x9f\x98\x80", .key = .{ .char = '😀' }, .mods = .none },
    };

    for (cases) |case| {
        try expectSingleKey(case.bytes, case.key, case.mods);
        try expectSingleKeyBytewise(case.bytes, case.key, case.mods);
    }
}

test "kitty csi-u decodes shift+enter, which legacy cannot express" {
    try expectSingleKey("\x1b[13;2u", .enter, .{ .shift = true });
    try expectSingleKey("\x1b[27u", .escape, .none);
    try expectSingleKey("\x1b[97;5u", .{ .char = 'a' }, .{ .ctrl = true });
    try expectSingleKey("\x1b[112;6u", .{ .char = 'p' }, .{ .ctrl = true, .shift = true });
}

test "paste content is sanitized" {
    var scratch: [256]u8 = undefined;
    var decoder: Decoder = .init(&scratch);

    // An escape sequence and a bell smuggled inside a paste. Echoing those back
    // is a terminal-injection vector, so they never leave the decoder.
    decoder.feed("\x1b[200~a\x1b[31m\x07b\nc\x1b[201~");

    const event = decoder.next() orelse return error.NoEvent;
    try testing.expect(event == .paste);
    try testing.expectEqualStrings("a[31mb\nc", event.paste.bytes);
}

test "paste survives arriving one byte at a time" {
    var scratch: [256]u8 = undefined;
    var decoder: Decoder = .init(&scratch);

    const input = "\x1b[200~hello\nworld\x1b[201~";
    var found: ?[]const u8 = null;
    for (input) |byte| {
        decoder.feed(&[_]u8{byte});
        if (decoder.next()) |event| {
            try testing.expect(event == .paste);
            found = event.paste.bytes;
        }
    }
    try testing.expectEqualStrings("hello\nworld", found orelse return error.NoEvent);
}

test "a keypress after a paste still decodes" {
    var scratch: [256]u8 = undefined;
    var decoder: Decoder = .init(&scratch);
    decoder.feed("\x1b[200~hi\x1b[201~a");

    const paste = decoder.next() orelse return error.NoEvent;
    try testing.expect(paste == .paste);
    try testing.expectEqualStrings("hi", paste.paste.bytes);

    const key = decoder.next() orelse return error.NoEvent;
    try testing.expect(key.key.key.eql(.{ .char = 'a' }));
}

test "a lone escape becomes Escape only after the timeout" {
    var scratch: [256]u8 = undefined;
    var decoder: Decoder = .init(&scratch);
    decoder.feed("\x1b");

    // Ambiguous while it might still be the start of a sequence.
    try testing.expectEqual(@as(?InputEvent, null), decoder.next());

    const event = decoder.flushPending() orelse return error.NoEvent;
    try testing.expect(event.key.key.eql(.escape));
}

test "an escape followed by a sequence is not the Escape key" {
    try expectSingleKey("\x1b[A", .up, .none);
}

test "an unknown sequence is dropped and decoding resumes" {
    var scratch: [256]u8 = undefined;
    var decoder: Decoder = .init(&scratch);

    // A device attributes reply nobody asked for, then a real keypress.
    decoder.feed("\x1b[?62;c" ++ "x");

    const event = decoder.next() orelse return error.NoEvent;
    try testing.expect(event.key.key.eql(.{ .char = 'x' }));
    try testing.expectEqual(@as(usize, 1), decoder.dropped_sequences);
}

test "a sequence that never terminates is capped rather than buffered forever" {
    var scratch: [512]u8 = undefined;
    var decoder: Decoder = .init(&scratch);

    var runaway: [unknown_sequence_cap * 2]u8 = undefined;
    runaway[0] = 0x1b;
    runaway[1] = '[';
    @memset(runaway[2..], '1');
    decoder.feed(&runaway);

    try testing.expectEqual(@as(?InputEvent, null), decoder.next());
    try testing.expect(decoder.dropped_sequences > 0);
    try testing.expectEqual(@as(usize, 0), decoder.pending());
}

test "malformed utf-8 becomes a replacement character without losing what follows" {
    var scratch: [256]u8 = undefined;
    var decoder: Decoder = .init(&scratch);
    decoder.feed("\xffa");

    const replacement = decoder.next() orelse return error.NoEvent;
    try testing.expect(replacement.key.key.eql(.{ .char = 0xfffd }));

    const letter = decoder.next() orelse return error.NoEvent;
    try testing.expect(letter.key.key.eql(.{ .char = 'a' }));
}

test "a truncated codepoint waits rather than corrupting" {
    var scratch: [256]u8 = undefined;
    var decoder: Decoder = .init(&scratch);
    decoder.feed("\xe4\xb8");
    try testing.expectEqual(@as(?InputEvent, null), decoder.next());

    decoder.feed("\xad");
    const event = decoder.next() orelse return error.NoEvent;
    try testing.expect(event.key.key.eql(.{ .char = '中' }));
}

test "a full buffer drops the overflow instead of failing" {
    var scratch: [unknown_sequence_cap * 2]u8 = undefined;
    var decoder: Decoder = .init(&scratch);

    var flood: [1024]u8 = undefined;
    @memset(&flood, 'a');
    decoder.feed(&flood);

    try testing.expectEqual(scratch.len, decoder.pending());
    const event = decoder.next() orelse return error.NoEvent;
    try testing.expect(event.key.key.eql(.{ .char = 'a' }));
}

test "the decoder always consumes its input and never loops" {
    // The property the fuzz target asserts, pinned as an ordinary test so it
    // runs on every CI build rather than only under the fuzzer.
    var seed: u64 = 0x9e3779b97f4a7c15;
    var random: std.Random.DefaultPrng = .init(seed);

    var round: usize = 0;
    while (round < 200) : (round += 1) {
        var input: [96]u8 = undefined;
        random.random().bytes(&input);

        var scratch: [512]u8 = undefined;
        var decoder: Decoder = .init(&scratch);
        decoder.feed(&input);

        var guard: usize = 0;
        while (decoder.next()) |_| {
            guard += 1;
            try testing.expect(guard <= input.len);
        }
        _ = decoder.flushPending();
        seed +%= 1;
    }
}

test "parameters parse, saturate, and default" {
    var one = ParamIterator{ .bytes = "1;5" };
    try testing.expectEqual(@as(?u32, 1), one.next());
    try testing.expectEqual(@as(?u32, 5), one.next());
    try testing.expectEqual(@as(?u32, null), one.next());

    var empty = ParamIterator{ .bytes = "" };
    try testing.expectEqual(@as(?u32, null), empty.next());

    var defaulted = ParamIterator{ .bytes = ";2" };
    try testing.expectEqual(@as(?u32, 0), defaulted.next());
    try testing.expectEqual(@as(?u32, 2), defaulted.next());

    var huge = ParamIterator{ .bytes = "99999999999999999999" };
    try testing.expectEqual(@as(?u32, std.math.maxInt(u32)), huge.next());
}

/// The three invariants the decoder has to hold against any byte string,
/// including ones no terminal would ever send: it never panics, it always
/// terminates, and it never emits more events than it was given bytes.
///
/// `@setRuntimeSafety(true)` is already on the decoder's own scope, so a bounds
/// or cast error in `ReleaseSmall` is a trap the fuzzer sees rather than
/// undefined behaviour it does not.
fn decodeOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var input: [256]u8 = undefined;
    const len = smith.slice(&input);

    var scratch: [512]u8 = undefined;
    var decoder: Decoder = .init(&scratch);
    decoder.feed(input[0..len]);

    var emitted: usize = 0;
    while (decoder.next()) |_| {
        emitted += 1;
        try testing.expect(emitted <= len);
    }
    _ = decoder.flushPending();
}

test "fuzz: the decoder survives arbitrary bytes" {
    // Outside fuzz mode the test runner replays this corpus once and then an
    // empty input, so the target costs microseconds on an ordinary
    // `zig build test` — which is the smoke Phase 11 asks for, at no
    // wall-clock cost. `zig build fuzz -- --fuzz` is the real session, and the
    // roadmap puts a CI fuzzing job in v0.2.
    try std.testing.fuzz({}, decodeOne, .{
        .corpus = &.{
            // Seeds, so a session starts from shapes that mean something rather
            // than from noise: every branch of the state machine, once.
            "\x1b[A", // legacy cursor up
            "\x1bOP", // SS3, F1
            "\x1b[13;5u", // kitty CSI-u, ctrl+enter
            "\x1b[200~pasted\x1b[201~", // bracketed paste
            "\x1b[200~\x1b[A\x00\x1b[201~", // a paste that has to be sanitized
            "\x1b", // the lone escape, and its deadline
            "\xe4\xb8\xad", // a multi-byte codepoint, whole
            "\xe4\xb8", // and truncated
            "\x1b[999999999999999999;1m", // a parameter that has to saturate
            "\x1b[", // an unterminated sequence
            "\x1b_a very long unknown sequence that has to be swallowed to its cap",
        },
    });
}
