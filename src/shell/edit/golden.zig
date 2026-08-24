//! Golden transcripts of scripted editing sessions.
//!
//! A key script and a fixed width in, ANSI bytes out. The failure these guard
//! against is a prompt that looks right and leaves the cursor one cell or one
//! row out — which no assertion about a buffer's contents would ever catch, and
//! which compounds into a corrupted screen over a few frames.
//!
//! Every transcript ends in a cursor move, and the cursor move is the
//! assertion. A diff that changes only the trailing `\e[nF\e[nC` is a
//! cursor-parking change and `DR-011` is what to re-read before accepting it.
//!
//! **Regenerating one:** the test prints the actual transcript to stderr on a
//! mismatch, framed by `--- golden <name> ---` markers. Read it, satisfy
//! yourself the change is intended, and paste it into the file. There is
//! deliberately no `--update` flag.

const std = @import("std");
const testing = std.testing;

const actions = @import("actions.zig");
const editor_mod = @import("editor.zig");
const key_mod = @import("../input/key.zig");
const renderer_mod = @import("../render/renderer.zig");
const transcript = @import("../render/transcript.zig");
const Counting = @import("../render/counting_writer.zig").Counting;

const Editor = editor_mod.Editor;
const KeyEvent = key_mod.KeyEvent;
const Renderer = renderer_mod.Renderer;

const plain_caps: renderer_mod.Capabilities = .{
    .color = .none,
    .kitty_keyboard = true,
    .synchronized_output = false,
    .bracketed_paste = true,
    .size = .{ .cols = 24, .rows = 8 },
};

const Step = union(enum) {
    /// One chord, through `defaultAction` like every real keypress.
    key: KeyEvent,
    /// Typed literally, one character key per byte.
    text: []const u8,
    /// A paste: inserted whole, never routed through the keymap.
    paste: []const u8,
    resize: renderer_mod.Size,
    paint,
};

/// Drives a script and compares the frames against `testdata/golden/<name>.txt`.
///
/// Session-level outcomes — submit, quit, history — are dropped. This harness
/// is about what the *editor and the prompt* do; the session's own decisions
/// have their own tests in `repl.zig`, and none of them changes a byte on
/// screen that these could check.
fn golden(name: []const u8, caps: renderer_mod.Capabilities, script: []const Step) !void {
    const gpa = testing.allocator;

    var transcript_bytes: std.ArrayList(u8) = .empty;
    defer transcript_bytes.deinit(gpa);

    var renderer: Renderer = .init(gpa, caps, caps.size);
    defer renderer.deinit();

    var editor: Editor = .init(gpa);
    defer editor.deinit();

    for (script) |step| switch (step) {
        .key => |event| {
            const action = actions.defaultAction(event, caps.kitty_keyboard) orelse continue;
            _ = try actions.applyEdit(&editor, action);
        },
        .text => |bytes| for (bytes) |byte| {
            try editor.insertCodepoint(byte);
        },
        .paste => |bytes| try editor.insert(bytes),
        .resize => |size| renderer.setSize(size),
        .paint => {
            renderer.setPrompt(.{ .text = editor.items(), .cursor = editor.cursor });

            var buffer: [16 * 1024]u8 = undefined;
            var sink: [16 * 1024]u8 = undefined;
            var counting: Counting = .init(&buffer, &sink);
            _ = try renderer.paint(&counting.writer);
            try counting.writer.flush();
            // Every golden is also a one-write-per-frame assertion, for free.
            try testing.expect(counting.writes <= 1);
            try transcript_bytes.appendSlice(gpa, counting.bytes());
        },
    };

    return transcript.expectGolden(gpa, name, transcript_bytes.items);
}

const shift_enter: KeyEvent = .{ .key = .enter, .mods = .{ .shift = true } };

/// `ctrl('a')` reads better in a script than the struct literal does, and the
/// scripts are the part of this file a human has to check against a transcript.
const ctrl = struct {
    fn f(c: u21) KeyEvent {
        return .{ .key = .{ .char = c }, .mods = .{ .ctrl = true } };
    }
}.f;

test "golden: an empty prompt, painted twice" {
    // The second frame is the one that proves the rewind: it must move back
    // zero rows, because the cursor is already on the tail's only row.
    try golden("editor-empty", plain_caps, &.{ .paint, .paint });
}

test "golden: typing, then moving the cursor back into the middle" {
    try golden("editor-typing", plain_caps, &.{
        .{ .text = "hello world" },
        .paint,
        .{ .key = ctrl('a') },
        .paint,
        .{ .key = .{ .key = .right } },
        .{ .key = .{ .key = .right } },
        .paint,
    });
}

test "golden: a multiline draft built with shift+enter" {
    try golden("editor-multiline", plain_caps, &.{
        .{ .text = "first" },
        .{ .key = shift_enter },
        .{ .text = "second" },
        .paint,
        .{ .key = .{ .key = .up } },
        .paint,
    });
}

test "golden: a draft longer than the terminal is wide" {
    try golden("editor-wrap", plain_caps, &.{
        .{ .text = "the quick brown fox jumps over it" },
        .paint,
        .{ .resize = .{ .cols = 14, .rows = 8 } },
        .paint,
    });
}

test "golden: the three kills and a yank" {
    try golden("editor-kills", plain_caps, &.{
        .{ .text = "alpha beta gamma" },
        .{ .key = ctrl('w') },
        .paint,
        .{ .key = ctrl('u') },
        .paint,
        .{ .key = ctrl('y') },
        .paint,
    });
}

test "golden: a pasted draft taller than the screen" {
    try golden("editor-window", plain_caps, &.{
        // Eight lines into a six-row tail: the window has to move.
        .{ .paste = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight" },
        .paint,
        .{ .key = ctrl('a') },
        .{ .key = .{ .key = .up } },
        .{ .key = .{ .key = .up } },
        .paint,
    });
}
