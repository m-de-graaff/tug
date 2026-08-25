//! Themes: what a slot means, and what a theme says it looks like.
//!
//! Everything here is arithmetic on bytes. No allocator, no error set, no file
//! and no escape sequence — `src/shell/theme/registry.zig` finds the file and
//! `src/shell/render/renderer.zig` writes the escape. That split is the same
//! one Phase 7 drew between `config/schema.zig` and `config/load.zig`, and it
//! is what lets the whole of theming compile for `wasm32-freestanding`.

const std = @import("std");
const testing = std.testing;

const config = @import("config/schema.zig");
const toml = @import("config/toml.zig");

pub const Rgb = struct { r: u8, g: u8, b: u8 };

/// A slot's colour, or the absence of one.
///
/// `default` is not "black" and not "unset" — it is *the terminal's own
/// foreground*, and it renders as no bytes at all. Three separate things in
/// this phase are the same mechanism seen from different sides: a slot a theme
/// deliberately leaves to the terminal, the `Theme.fallback` a renderer holds
/// before any config has been read, and the whole `none` colour tier. One code
/// path serves all three, which is why none of them is a special case.
pub const Color = union(enum) {
    default,
    rgb: Rgb,
};

/// `#rrggbb`, `#rgb`, or the literal word `default`. Null is "not a colour",
/// which the caller turns into a `bad_color` note — it is never an error.
pub fn parseColor(text: []const u8) ?Color {
    if (std.mem.eql(u8, text, "default")) return .default;
    if (text.len == 0 or text[0] != '#') return null;

    const digits = text[1..];
    const wide = switch (digits.len) {
        6 => true,
        3 => false,
        else => return null,
    };

    var channels: [3]u8 = undefined;
    for (&channels, 0..) |*value, index| {
        if (wide) {
            const hi = hexDigit(digits[index * 2]) orelse return null;
            const lo = hexDigit(digits[index * 2 + 1]) orelse return null;
            value.* = hi * 16 + lo;
        } else {
            // #08c is #0088cc: each nibble is doubled, so the short form names
            // a colour on the same scale rather than one sixteenth as bright.
            const nibble = hexDigit(digits[index]) orelse return null;
            value.* = nibble * 17;
        }
    }
    return .{ .rgb = .{ .r = channels[0], .g = channels[1], .b = channels[2] } };
}

fn hexDigit(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

/// The six levels the xterm 6×6×6 cube is built from. Not evenly spaced: the
/// gap from 0 to 95 is the one that makes a naive `v * 5 / 255` round wrong.
const cube_levels = [6]u8{ 0, 95, 135, 175, 215, 255 };

/// The nearest xterm-256 index to an RGB triple.
///
/// Two candidates are considered and the closer wins: the 6×6×6 colour cube
/// (indices 16–231) and the 24-step grey ramp (232–255). Considering only the
/// cube would quantize every near-grey onto the cube's six coarse levels, which
/// is visible as banding on exactly the muted colours a terminal theme is made
/// of. Distance is squared Euclidean in RGB — not perceptually uniform, and it
/// does not need to be: the contrast gate in the registry is what guarantees
/// the result is legible, and this only has to pick the closest of 256 stops.
///
/// ponytail: 6+24 candidate evaluations, not a 256-entry search. Both are O(1)
/// with a tiny constant and it runs once per slot per theme load, never per
/// frame — `styleBytes` gets the index already computed.
pub fn quantize(c: Rgb) u8 {
    var cube_index: u16 = 16;
    var cube_error: u32 = 0;
    const channels = [3]u8{ c.r, c.g, c.b };

    for (channels, 0..) |value, index| {
        var best: usize = 0;
        var best_error: u32 = std.math.maxInt(u32);
        for (cube_levels, 0..) |level, level_index| {
            const delta = squared(level, value);
            if (delta < best_error) {
                best_error = delta;
                best = level_index;
            }
        }
        cube_error += best_error;
        // 36·r + 6·g + b, accumulated as the loop walks r, g and b.
        cube_index += @as(u16, @intCast(best)) * switch (index) {
            0 => @as(u16, 36),
            1 => @as(u16, 6),
            else => @as(u16, 1),
        };
    }

    var ramp_best: usize = 0;
    var ramp_error: u32 = std.math.maxInt(u32);
    for (0..24) |step| {
        const level: u8 = @intCast(8 + step * 10);
        const delta = squared(level, c.r) + squared(level, c.g) + squared(level, c.b);
        if (delta < ramp_error) {
            ramp_error = delta;
            ramp_best = step;
        }
    }

    // Ties go to the cube: it is the larger, more hue-faithful half of the
    // palette, and a tie means the grey is exactly on a cube level anyway.
    if (ramp_error < cube_error) return @intCast(232 + ramp_best);
    return @intCast(cube_index);
}

fn squared(a: u8, b: u8) u32 {
    const delta = @as(i32, a) - @as(i32, b);
    return @intCast(delta * delta);
}

/// WCAG 2.1 relative luminance. The magic numbers are the specification's.
pub fn luminance(c: Rgb) f64 {
    return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

fn channel(value: u8) f64 {
    const v = @as(f64, @floatFromInt(value)) / 255.0;
    if (v <= 0.03928) return v / 12.92;
    return std.math.pow(f64, (v + 0.055) / 1.055, 2.4);
}

/// WCAG 2.1 contrast ratio, between 1.0 and 21.0. Symmetric in its arguments.
///
/// Used by one test — the built-in palettes' gate in the registry — and by
/// nothing at run time. It lives here rather than in that test because it is
/// arithmetic with a published reference to check it against, and a helper
/// buried in a test file is a helper nobody can check.
pub fn contrast(a: Rgb, b: Rgb) f64 {
    const la = luminance(a);
    const lb = luminance(b);
    const hi = @max(la, lb);
    const lo = @min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
}

// --- the schema ------------------------------------------------------------

/// What a piece of text *means*. The renderer knows these; only a theme knows
/// what colour any of them is.
///
/// `u3` on purpose: `md.Style` packs one of these into a byte alongside two
/// attribute bits and the code-background flag, and every style comparison in
/// the renderer is a single `@bitCast(u8)`. A ninth foreground slot would cost
/// that byte, so the ninth slot in the spec — `code_bg` — is a background and
/// reaches `Style` as a bool instead.
pub const Slot = enum(u3) {
    fg,
    dim,
    accent,
    user_block,
    assistant_block,
    notice,
    @"error",
    prompt,
};

pub const slot_count: usize = @typeInfo(Slot).@"enum".fields.len;

/// What a slot degrades to when there is no colour to be had — either because
/// the theme said `default` or because the terminal is at the `none` tier.
///
/// This table is the accessibility rule with a type: *no meaning carried by
/// colour alone*. Every slot that distinguishes one kind of text from another
/// names an attribute here, so a `NO_COLOR` user sees the same distinctions a
/// truecolor user does, drawn with bold and dim instead. The slots that name
/// `none` are the ones that are decoration — an accent on a heading that is
/// already bold, a prompt that is already behind a `>`.
pub const Attribute = enum { none, bold, dim };

pub fn fallbackAttribute(slot: Slot) Attribute {
    return switch (slot) {
        .dim, .notice => .dim,
        .user_block => .bold,
        .fg, .accent, .assistant_block, .@"error", .prompt => .none,
    };
}

/// The nine slots, resolved. Colours are values, not slices, so a `Theme`
/// outlives the bytes it was parsed from and the registry can free them.
pub const Theme = struct {
    foreground: [slot_count]Color = @splat(.default),
    /// The one background tug paints. Separate from `foreground` because
    /// `Slot` is the foreground enum and packing a background into it would
    /// cost the byte `md.Style` fits in.
    code_bg: Color = .default,

    /// Every slot left to the terminal. This is what a `Renderer` holds before
    /// any config has been read, and it renders byte-for-byte as Phase 8 did —
    /// which is what makes the twenty-one existing goldens this phase's
    /// regression net rather than twenty-one files to regenerate.
    pub const fallback: Theme = .{};

    pub fn color(self: Theme, slot: Slot) Color {
        return self.foreground[@intFromEnum(slot)];
    }

    fn set(self: *Theme, slot: Slot, value: Color) void {
        self.foreground[@intFromEnum(slot)] = value;
    }

    /// The `/theme` screen, and the table `--debug-config` prints today. One
    /// row per slot, in `Slot` order, with `code_bg` last where the spec lists
    /// it.
    pub fn write(self: Theme, out: *std.Io.Writer) std.Io.Writer.Error!void {
        try out.writeAll("slot                 colour\n");
        inline for (@typeInfo(Slot).@"enum".fields) |field| {
            const slot: Slot = @enumFromInt(field.value);
            try writeRow(out, field.name, self.color(slot));
        }
        try writeRow(out, "code_bg", self.code_bg);
    }

    /// The column `Config.write` and `Keymap.write` both use, for the reason
    /// they both use it: a screen printing more than one of these should have
    /// one left edge.
    const slot_column = 21;

    fn writeRow(
        out: *std.Io.Writer,
        name: []const u8,
        value: Color,
    ) std.Io.Writer.Error!void {
        try out.writeAll(name);
        var index = name.len;
        while (index < slot_column) : (index += 1) try out.writeAll(" ");
        try out.writeAll(" ");
        switch (value) {
            .default => try out.writeAll("default"),
            .rgb => |rgb| try out.print("#{x:0>2}{x:0>2}{x:0>2}", .{ rgb.r, rgb.g, rgb.b }),
        }
        try out.writeAll("\n");
    }
};

/// ponytail: 16 notes for one theme file. Past that it is not a theme with a
/// typo in it, and the config's own cap (32) is the precedent. The last slot is
/// spent on `notes_truncated` so the screen says there were more.
pub const max_notes: usize = 16;

/// A parsed theme and everything that was wrong with the file it came from.
///
/// The notes are `config.Note`s rather than a type of their own. `DR-013` named
/// a third warning list as the trigger for a shared `Diagnostic`; the trigger
/// was checked and did not fire, because a theme file's problems turn out to be
/// the same problems a config file has — a scanner refusal, an unknown key, a
/// wrong type, a duplicate — plus one that is genuinely new (`bad_color`) and
/// fits the existing shape without changing it. `DR-007` records the check.
///
/// What a theme does *not* have is a layer: it is one file, not a stack. So
/// `writeNotes` takes one origin rather than an array indexed by layer, and
/// `Note.write` — which has always taken an origin as a parameter — is
/// unchanged.
pub const Result = struct {
    theme: Theme = .fallback,
    note_storage: [max_notes]config.Note = undefined,
    note_count: usize = 0,

    pub fn notes(self: *const Result) []const config.Note {
        return self.note_storage[0..self.note_count];
    }

    pub fn writeNotes(
        self: *const Result,
        out: *std.Io.Writer,
        origin: []const u8,
    ) std.Io.Writer.Error!void {
        for (self.notes()) |entry| try entry.write(out, origin);
    }

    /// Records a note, or — in the last slot — records that there were more.
    /// The same saturation `Config.note` does, for the same reason.
    pub fn note(self: *Result, entry: config.Note) void {
        if (self.note_count == max_notes) return;
        if (self.note_count == max_notes - 1) {
            self.note_storage[self.note_count] = .{
                .kind = .notes_truncated,
                .layer = entry.layer,
                .at = entry.at,
            };
            self.note_count += 1;
            return;
        }
        self.note_storage[self.note_count] = entry;
        self.note_count += 1;
    }
};

/// One theme file's bytes, as a `Theme` and a list of complaints.
///
/// Nothing here fails, for the reason Phase 7 stated and this phase inherits: a
/// typo in a theme must never brick the shell. A file of nonsense yields
/// `Theme.fallback` — every slot left to the terminal — and a screen of
/// warnings.
///
/// `layer` is carried onto every note only so a caller printing theme notes
/// beside config notes has the same field populated on both. Nothing in a theme
/// file is layered.
pub fn parse(source: []const u8, layer: config.Layer) Result {
    var result: Result = .{};
    var scanner: toml.Scanner = .init(source);
    var seen: [slot_count + 1]bool = @splat(false);

    while (scanner.next()) |item| switch (item) {
        .problem => |problem| result.note(.{
            .kind = fromProblem(problem.kind),
            .layer = layer,
            .at = problem.at,
        }),
        .pair => |pair| applyPair(&result, layer, pair, &seen),
    };

    return result;
}

fn applyPair(
    result: *Result,
    layer: config.Layer,
    pair: toml.Pair,
    seen: *[slot_count + 1]bool,
) void {
    // Themes are flat. A section header is somebody's reasonable guess at the
    // shape and it deserves a sentence rather than silence.
    if (pair.table.len != 0) {
        return result.note(.{
            .kind = .unknown_table,
            .layer = layer,
            .at = pair.at,
            .text = pair.table,
        });
    }

    // Accepted and ignored: the registry resolves a theme by its file name, so
    // this key is a comment with quotes round it. Warning about it would fire
    // on every theme anybody copies from a built-in.
    if (std.mem.eql(u8, pair.key, "name")) return;

    const is_code_bg = std.mem.eql(u8, pair.key, "code_bg");
    const slot: ?Slot = if (is_code_bg) null else std.meta.stringToEnum(Slot, pair.key);

    if (!is_code_bg and slot == null) {
        return result.note(.{
            .kind = .unknown_key,
            .layer = layer,
            .at = pair.at,
            .text = pair.key,
        });
    }

    if (pair.value != .string) {
        return result.note(.{
            .kind = .wrong_type,
            .layer = layer,
            .at = pair.at,
            .text = pair.key,
        });
    }

    const index: usize = if (is_code_bg) slot_count else @intFromEnum(slot.?);
    if (seen[index]) {
        result.note(.{
            .kind = .duplicate_key,
            .layer = layer,
            .at = pair.at,
            .text = pair.key,
        });
    }
    seen[index] = true;

    const value = parseColor(pair.value.string) orelse {
        // The slot keeps whatever it had, which for a first mention is the
        // fallback. A theme with one unreadable colour is a theme with one slot
        // left to the terminal, not a theme that refuses to load.
        return result.note(.{
            .kind = .bad_color,
            .layer = layer,
            .at = pair.at,
            .text = pair.key,
        });
    };

    if (is_code_bg) {
        result.theme.code_bg = value;
    } else {
        result.theme.set(slot.?, value);
    }
}

/// The scanner's refusals, mapped into note kinds. An explicit switch rather
/// than a shared numbering, for the reason `config.Config.fromProblem` gives:
/// two enums that must agree by integer value agree right up until somebody
/// reorders one.
fn fromProblem(problem: toml.Problem) config.Note.Kind {
    return switch (problem) {
        .expected_key => .expected_key,
        .expected_equals => .expected_equals,
        .expected_value => .expected_value,
        .unterminated_string => .unterminated_string,
        .unterminated_table => .unterminated_table,
        .escape_unsupported => .escape_unsupported,
        .bad_integer => .bad_integer,
        .trailing_text => .trailing_text,
        .dotted_key_unsupported => .dotted_key_unsupported,
        .array_unsupported => .array_unsupported,
        .inline_table_unsupported => .inline_table_unsupported,
        .array_of_tables_unsupported => .array_of_tables_unsupported,
    };
}

test "a full theme file parses every slot" {
    const source =
        \\name = "example"
        \\fg = "default"
        \\dim = "#9a9a9a"
        \\accent = "#4ec9b0"
        \\user_block = "#9cdcfe"
        \\assistant_block = "default"
        \\notice = "#dcdcaa"
        \\error = "#f48771"
        \\prompt = "#4ec9b0"
        \\code_bg = "#2d2d2d"
        \\
    ;
    const result = parse(source, .user);
    try testing.expectEqual(@as(usize, 0), result.notes().len);
    try testing.expectEqual(Color.default, result.theme.color(.fg));
    try testing.expectEqual(Rgb{ .r = 0x4e, .g = 0xc9, .b = 0xb0 }, result.theme.color(.accent).rgb);
    try testing.expectEqual(Rgb{ .r = 0xf4, .g = 0x87, .b = 0x71 }, result.theme.color(.@"error").rgb);
    try testing.expectEqual(Rgb{ .r = 0x2d, .g = 0x2d, .b = 0x2d }, result.theme.code_bg.rgb);
}

test "a slot the file does not mention keeps the fallback" {
    const result = parse("accent = \"#4ec9b0\"\n", .user);
    try testing.expectEqual(@as(usize, 0), result.notes().len);
    try testing.expectEqual(Color.default, result.theme.color(.notice));
    try testing.expectEqual(Color.default, result.theme.code_bg);
}

test "a name that is not a slot is a warning" {
    const result = parse("acent = \"#4ec9b0\"\n", .user);
    try testing.expectEqual(@as(usize, 1), result.notes().len);
    try testing.expectEqual(config.Note.Kind.unknown_key, result.notes()[0].kind);
    try testing.expectEqualStrings("acent", result.notes()[0].text);

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try result.writeNotes(&writer, "theme.toml");
    try testing.expectEqualStrings(
        "theme.toml:1:1: warning: no such setting ('acent')\n",
        writer.buffered(),
    );
}

test "a value that is not a colour is a warning and the slot is untouched" {
    const result = parse("accent = \"puce\"\n", .user);
    try testing.expectEqual(@as(usize, 1), result.notes().len);
    try testing.expectEqual(config.Note.Kind.bad_color, result.notes()[0].kind);
    try testing.expectEqualStrings("accent", result.notes()[0].text);
    try testing.expectEqual(Color.default, result.theme.color(.accent));

    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try result.writeNotes(&writer, "theme.toml");
    try testing.expectEqualStrings(
        "theme.toml:1:1: warning: not a colour; use '#rrggbb', '#rgb' or 'default' ('accent')\n",
        writer.buffered(),
    );
}

test "a slot given a non-string is the wrong type, not a bad colour" {
    const result = parse("accent = 7\n", .user);
    try testing.expectEqual(@as(usize, 1), result.notes().len);
    try testing.expectEqual(config.Note.Kind.wrong_type, result.notes()[0].kind);
}

test "a slot set twice in one file is a duplicate and the last one wins" {
    const result = parse("accent = \"#111111\"\naccent = \"#222222\"\n", .user);
    try testing.expectEqual(@as(usize, 1), result.notes().len);
    try testing.expectEqual(config.Note.Kind.duplicate_key, result.notes()[0].kind);
    try testing.expectEqual(Rgb{ .r = 0x22, .g = 0x22, .b = 0x22 }, result.theme.color(.accent).rgb);
}

test "a table header in a theme file is a warning, not a section" {
    // Themes are flat. A `[colors]` header is somebody's reasonable guess and
    // it should say so rather than silently ignore everything under it.
    const result = parse("[colors]\naccent = \"#4ec9b0\"\n", .user);
    try testing.expect(result.notes().len >= 1);
    try testing.expectEqual(config.Note.Kind.unknown_table, result.notes()[0].kind);
    try testing.expectEqual(Color.default, result.theme.color(.accent));
}

test "name is accepted and ignored" {
    // The registry resolves a theme by its file name, so the key is a comment
    // with quotes round it. Accepting it costs one branch; warning about it
    // would fire on every theme anybody copies from the built-ins.
    const result = parse("name = \"whatever\"\n", .user);
    try testing.expectEqual(@as(usize, 0), result.notes().len);
}

test "a scanner problem becomes a note, and the rest of the file still parses" {
    const result = parse("accent = \n dim = \"#9a9a9a\"\n", .user);
    try testing.expect(result.notes().len >= 1);
    try testing.expectEqual(config.Note.Kind.expected_value, result.notes()[0].kind);
}

test "a file made entirely of nonsense yields the fallback theme" {
    const result = parse("\x00\xff{{{[[[\n=====\n", .user);
    try testing.expect(result.notes().len >= 1);
    for (std.enums.values(Slot)) |slot| {
        try testing.expectEqual(Color.default, result.theme.color(slot));
    }
}

test "note storage saturates rather than overflowing" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    for (0..max_notes * 4) |_| try source.appendSlice(testing.allocator, "nope = \"x\"\n");

    const result = parse(source.items, .user);
    try testing.expectEqual(max_notes, result.notes().len);
    try testing.expectEqual(
        config.Note.Kind.notes_truncated,
        result.notes()[max_notes - 1].kind,
    );
}

test "every slot's monochrome fallback preserves the distinction it draws" {
    // The accessibility rule made mechanical: a slot that carries meaning must
    // still carry it with the colour taken away. The three that do — a notice,
    // the user's own words, and code — each degrade to an attribute, and the
    // ones that are decoration degrade to nothing.
    try testing.expectEqual(Attribute.dim, fallbackAttribute(.notice));
    try testing.expectEqual(Attribute.dim, fallbackAttribute(.dim));
    try testing.expectEqual(Attribute.bold, fallbackAttribute(.user_block));
    try testing.expectEqual(Attribute.none, fallbackAttribute(.fg));
    try testing.expectEqual(Attribute.none, fallbackAttribute(.assistant_block));
    try testing.expectEqual(Attribute.none, fallbackAttribute(.accent));
    try testing.expectEqual(Attribute.none, fallbackAttribute(.prompt));
    try testing.expectEqual(Attribute.none, fallbackAttribute(.@"error"));
}

test "the theme table prints one row per slot" {
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const result = parse("accent = \"#4ec9b0\"\ncode_bg = \"#2d2d2d\"\n", .user);
    try result.theme.write(&writer);

    const report = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, report, "accent") != null);
    try testing.expect(std.mem.indexOf(u8, report, "#4ec9b0") != null);
    try testing.expect(std.mem.indexOf(u8, report, "code_bg") != null);
    // Every slot has a row, including the ones nothing set.
    try testing.expect(std.mem.indexOf(u8, report, "default") != null);
    try testing.expect(std.mem.indexOf(u8, report, "error") != null);
}

test "hex colours parse in both lengths and the literal default" {
    try testing.expectEqual(Color.default, parseColor("default").?);
    try testing.expectEqual(Rgb{ .r = 0x4e, .g = 0xc9, .b = 0xb0 }, parseColor("#4ec9b0").?.rgb);
    // The three-digit form doubles each nibble, which is what CSS does and what
    // anybody writing #fff expects.
    try testing.expectEqual(Rgb{ .r = 0xff, .g = 0xff, .b = 0xff }, parseColor("#fff").?.rgb);
    try testing.expectEqual(Rgb{ .r = 0x00, .g = 0x88, .b = 0xcc }, parseColor("#08c").?.rgb);
}

test "anything that is not a colour is not a colour" {
    for ([_][]const u8{
        "",       "#",       "#12",      "#12345", "#1234567",
        "4ec9b0", "#4ec9bg", "#4EC9B0 ", "red",
    }) |text| {
        try testing.expectEqual(@as(?Color, null), parseColor(text));
    }
}

test "uppercase hex is accepted" {
    try testing.expectEqual(Rgb{ .r = 0x4E, .g = 0xC9, .b = 0xB0 }, parseColor("#4EC9B0").?.rgb);
}

test "quantization hits the documented xterm-256 indices" {
    // The cube is 16 + 36r + 6g + b over the levels {0,95,135,175,215,255}; the
    // ramp is 232 + i over 8 + 10i. Every expectation below is one of those two
    // formulas evaluated by hand, which is what makes this a check rather than
    // a recording of whatever the code did.
    const cases = [_]struct { rgb: Rgb, want: u8 }{
        .{ .rgb = .{ .r = 0, .g = 0, .b = 0 }, .want = 16 },
        .{ .rgb = .{ .r = 255, .g = 255, .b = 255 }, .want = 231 },
        .{ .rgb = .{ .r = 255, .g = 0, .b = 0 }, .want = 196 },
        .{ .rgb = .{ .r = 0, .g = 255, .b = 0 }, .want = 46 },
        .{ .rgb = .{ .r = 0, .g = 0, .b = 255 }, .want = 21 },
        // A grey the ramp fits better than the cube does.
        .{ .rgb = .{ .r = 0x80, .g = 0x80, .b = 0x80 }, .want = 244 },
        // The palette entries this phase ships, so a change to the rounding
        // shows up here before it shows up in a golden.
        .{ .rgb = .{ .r = 0x4e, .g = 0xc9, .b = 0xb0 }, .want = 79 },
        .{ .rgb = .{ .r = 0x9c, .g = 0xdc, .b = 0xfe }, .want = 153 },
        .{ .rgb = .{ .r = 0x9a, .g = 0x9a, .b = 0x9a }, .want = 247 },
        .{ .rgb = .{ .r = 0x2d, .g = 0x2d, .b = 0x2d }, .want = 236 },
        .{ .rgb = .{ .r = 0x1d, .g = 0x4e, .b = 0xd8 }, .want = 26 },
        .{ .rgb = .{ .r = 0x85, .g = 0x4d, .b = 0x0e }, .want = 94 },
        .{ .rgb = .{ .r = 0x0d, .g = 0x65, .b = 0x60 }, .want = 23 },
        .{ .rgb = .{ .r = 0xb9, .g = 0x1c, .b = 0x1c }, .want = 124 },
        .{ .rgb = .{ .r = 0xe6, .g = 0xe6, .b = 0xe6 }, .want = 254 },
    };
    for (cases) |case| try testing.expectEqual(case.want, quantize(case.rgb));
}

test "the ramp wins only when it is actually closer" {
    // #5f5f5f is a cube level exactly, so it must not be pulled onto the ramp
    // even though the ramp has 8+10*9 = 98 and 8+10*8 = 88 nearby.
    try testing.expectEqual(@as(u8, 59), quantize(.{ .r = 0x5f, .g = 0x5f, .b = 0x5f }));
}

test "contrast matches the WCAG reference pairs" {
    const black: Rgb = .{ .r = 0, .g = 0, .b = 0 };
    const white: Rgb = .{ .r = 255, .g = 255, .b = 255 };
    try testing.expectApproxEqAbs(@as(f64, 21.0), contrast(black, white), 0.001);
    try testing.expectApproxEqAbs(@as(f64, 1.0), contrast(white, white), 0.001);
    // Order does not matter.
    try testing.expectApproxEqAbs(contrast(black, white), contrast(white, black), 0.001);
    // #767676 on white is the canonical "exactly AA" grey.
    const grey: Rgb = .{ .r = 0x76, .g = 0x76, .b = 0x76 };
    try testing.expect(contrast(grey, white) >= 4.5);
    try testing.expect(contrast(.{ .r = 0x77, .g = 0x77, .b = 0x77 }, white) < 4.5);
}
