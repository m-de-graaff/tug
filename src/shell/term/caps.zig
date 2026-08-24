//! What this terminal can actually do.
//!
//! Detection is a pure function of the environment and the answers to a few
//! probes, both passed in. That split matters: probing needs a tty, but
//! *deciding* does not, so the decision is table-testable on any machine
//! including CI, and the part that needs a terminal stays in the backend.
//!
//! The bias throughout is toward assuming less. An unanswered probe means
//! "unsupported", never "wait longer" — the 10 ms startup budget makes hanging
//! on a probe a bug rather than a degradation.

const std = @import("std");

pub const Size = @import("backend.zig").Size;

/// How much colour the renderer may use.
///
/// There is no 16-colour tier. 256 is the floor below truecolor: every terminal
/// in the matrix has had it for a decade, and carrying a fourth quantization
/// path for terminals nobody runs is cost without a user.
pub const ColorTier = enum {
    /// Monochrome. Bold and dim only. A first-class tier with its own golden
    /// test, not a degraded afterthought — `NO_COLOR` users are users.
    none,
    ansi256,
    truecolor,
};

/// The environment variables detection reads. Passed in rather than read here,
/// so the decision logic never touches the process environment.
pub const Env = struct {
    /// True when `NO_COLOR` is present in the environment with any value at
    /// all, including empty — that is what the convention specifies.
    no_color: bool = false,
    colorterm: ?[]const u8 = null,
    term: ?[]const u8 = null,
    /// Set inside a multiplexer. Recorded because tmux passes some sequences
    /// through and swallows others, which matters for the probes.
    tmux: bool = false,
};

/// The answers to the runtime probes, gathered by the backend before this runs.
/// Every field defaults to false because an unanswered probe is an unsupported
/// feature.
pub const Probe = struct {
    kitty_keyboard: bool = false,
    synchronized_output: bool = false,
};

pub const Capabilities = struct {
    color: ColorTier,
    /// The kitty keyboard protocol. This is what makes shift+enter a distinct
    /// chord; without it the terminal cannot tell it from a plain enter, and
    /// the editor falls back to alt+enter.
    kitty_keyboard: bool,
    /// DECSET 2026. Lets a repaint arrive as one atomic update.
    synchronized_output: bool,
    /// DECSET 2004. Assumed present: every terminal in the matrix has
    /// supported it for years, and a terminal that ignores the sequence simply
    /// never sends the markers, which the decoder already handles.
    bracketed_paste: bool,
    size: Size,

    pub fn write(self: Capabilities, out: *std.Io.Writer) std.Io.Writer.Error!void {
        try out.print("color               {t}\n", .{self.color});
        try out.print("kitty keyboard      {}\n", .{self.kitty_keyboard});
        try out.print("synchronized output {}\n", .{self.synchronized_output});
        try out.print("bracketed paste     {}\n", .{self.bracketed_paste});
        try out.print("size                {d}x{d}\n", .{ self.size.cols, self.size.rows });
    }
};

pub fn detect(env: Env, probe: Probe, size: Size) Capabilities {
    return .{
        .color = detectColor(env),
        .kitty_keyboard = probe.kitty_keyboard,
        .synchronized_output = probe.synchronized_output,
        .bracketed_paste = !isDumb(env.term),
        .size = size,
    };
}

fn detectColor(env: Env) ColorTier {
    // https://no-color.org: presence is the signal, value is irrelevant. It
    // wins over everything, including an explicit COLORTERM, because the user
    // asking for no colour is more specific than the terminal advertising it.
    if (env.no_color) return .none;

    const term = env.term orelse return .none;
    if (isDumb(term)) return .none;

    if (env.colorterm) |colorterm| {
        if (std.mem.eql(u8, colorterm, "truecolor") or std.mem.eql(u8, colorterm, "24bit")) {
            return .truecolor;
        }
    }

    // Terminals that are truecolor but do not always export COLORTERM.
    if (std.mem.indexOf(u8, term, "direct") != null) return .truecolor;
    if (std.mem.eql(u8, term, "xterm-kitty")) return .truecolor;
    if (std.mem.eql(u8, term, "wezterm")) return .truecolor;
    if (std.mem.eql(u8, term, "alacritty")) return .truecolor;

    if (std.mem.indexOf(u8, term, "256color") != null) return .ansi256;

    // A terminal that says nothing useful gets the floor. Guessing high paints
    // garbage; guessing low paints something readable.
    return .ansi256;
}

fn isDumb(term: ?[]const u8) bool {
    const value = term orelse return true;
    return value.len == 0 or std.mem.eql(u8, value, "dumb");
}

const testing = std.testing;
const test_size: Size = .{ .cols = 80, .rows = 24 };

test "NO_COLOR wins over COLORTERM" {
    const caps = detect(
        .{ .no_color = true, .colorterm = "truecolor", .term = "xterm-256color" },
        .{},
        test_size,
    );
    try testing.expectEqual(ColorTier.none, caps.color);
}

test "COLORTERM=truecolor selects truecolor" {
    const caps = detect(.{ .colorterm = "truecolor", .term = "xterm-256color" }, .{}, test_size);
    try testing.expectEqual(ColorTier.truecolor, caps.color);
}

test "COLORTERM=24bit selects truecolor" {
    const caps = detect(.{ .colorterm = "24bit", .term = "xterm-256color" }, .{}, test_size);
    try testing.expectEqual(ColorTier.truecolor, caps.color);
}

test "256color in TERM without COLORTERM selects ansi256" {
    const caps = detect(.{ .term = "xterm-256color" }, .{}, test_size);
    try testing.expectEqual(ColorTier.ansi256, caps.color);
}

test "known truecolor terminals do not need COLORTERM" {
    for ([_][]const u8{ "xterm-kitty", "wezterm", "alacritty", "xterm-direct" }) |term| {
        const caps = detect(.{ .term = term }, .{}, test_size);
        try testing.expectEqual(ColorTier.truecolor, caps.color);
    }
}

test "TERM=dumb gets no colour and no bracketed paste" {
    const caps = detect(.{ .term = "dumb", .colorterm = "truecolor" }, .{}, test_size);
    try testing.expectEqual(ColorTier.none, caps.color);
    try testing.expect(!caps.bracketed_paste);
}

test "a missing TERM is treated as dumb" {
    const caps = detect(.{}, .{}, test_size);
    try testing.expectEqual(ColorTier.none, caps.color);
}

test "an unknown TERM degrades to the floor rather than guessing high" {
    const caps = detect(.{ .term = "screen" }, .{}, test_size);
    try testing.expectEqual(ColorTier.ansi256, caps.color);
}

test "an unanswered probe means unsupported" {
    const caps = detect(.{ .term = "xterm-256color" }, .{}, test_size);
    try testing.expect(!caps.kitty_keyboard);
    try testing.expect(!caps.synchronized_output);
}

test "probe answers are carried through" {
    const caps = detect(
        .{ .term = "xterm-kitty" },
        .{ .kitty_keyboard = true, .synchronized_output = true },
        test_size,
    );
    try testing.expect(caps.kitty_keyboard);
    try testing.expect(caps.synchronized_output);
}

test "capabilities render as a readable report" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const caps = detect(.{ .term = "xterm-kitty" }, .{ .kitty_keyboard = true }, test_size);
    try caps.write(&writer);

    const report = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, report, "truecolor") != null);
    try testing.expect(std.mem.indexOf(u8, report, "80x24") != null);
}
