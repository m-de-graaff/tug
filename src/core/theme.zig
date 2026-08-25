//! Themes: what a slot means, and what a theme says it looks like.
//!
//! Everything here is arithmetic on bytes. No allocator, no error set, no file
//! and no escape sequence — `src/shell/theme/registry.zig` finds the file and
//! `src/shell/render/renderer.zig` writes the escape. That split is the same
//! one Phase 7 drew between `config/schema.zig` and `config/load.zig`, and it
//! is what lets the whole of theming compile for `wasm32-freestanding`.

const std = @import("std");
const testing = std.testing;

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
