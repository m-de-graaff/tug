//! One scene, both built-in themes, all three colour tiers.
//!
//! Six snapshots of the same script, which is what makes them readable as a
//! set: the diff between `theme-dark-truecolor` and `theme-dark-ansi256` is
//! nothing but the encoding of the colours, and the diff between either and
//! `theme-dark-none` is nothing but colour becoming attribute. If a change ever
//! makes those three disagree about *what* is styled rather than *how*, the
//! three files stop lining up and somebody has to say why.
//!
//! `theme-dark-none.txt` and `theme-light-none.txt` are byte-identical to each
//! other, and a test asserts it: at the `none` tier a theme has nothing left to
//! say. That assertion is the accessibility rule stated as a byte string —
//! every distinction in the scene is drawn by an attribute, so taking the
//! colour away loses none of them.

const std = @import("std");
const testing = std.testing;

const Counting = @import("../render/counting_writer.zig").Counting;
const registry = @import("registry.zig");
const renderer_mod = @import("../render/renderer.zig");
const transcript = @import("../render/transcript.zig");

const Renderer = renderer_mod.Renderer;

/// Every kind of styled text the renderer can produce, in one scene: a user
/// block, a heading, prose with inline emphasis and inline code, both list
/// markers, a fenced block, a notice, and a draft at the bottom. Wide enough
/// that nothing wraps by accident and narrow enough to read in a diff.
const scene_cols: u16 = 40;
const scene_rows: u16 = 24;

fn caps(tier: renderer_mod.ColorTier) renderer_mod.Capabilities {
    return .{
        .color = tier,
        .kitty_keyboard = false,
        .synchronized_output = false,
        .bracketed_paste = true,
        .size = .{ .cols = scene_cols, .rows = scene_rows },
    };
}

fn paintInto(
    bytes: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    renderer: *Renderer,
) !void {
    var buffer: [16 * 1024]u8 = undefined;
    var sink: [16 * 1024]u8 = undefined;
    var counting: Counting = .init(&buffer, &sink);
    _ = try renderer.paint(&counting.writer);
    try counting.writer.flush();
    // Every golden is also a one-write-per-frame assertion, for free.
    try testing.expect(counting.writes <= 1);
    try bytes.appendSlice(gpa, counting.bytes());
}

fn scene(name: []const u8, theme_name: []const u8, tier: renderer_mod.ColorTier) !void {
    const gpa = testing.allocator;

    var loaded = registry.resolve(gpa, testing.io, theme_name, null, .default);
    defer loaded.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), loaded.result.notes().len);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);

    var renderer: Renderer = .init(gpa, caps(tier), caps(tier).size);
    defer renderer.deinit();
    renderer.setTheme(loaded.result.theme);

    try renderer.beginBlock(.user);
    try renderer.feed("summarise this file\n");
    try renderer.endBlock();

    try renderer.beginBlock(.assistant);
    try renderer.feed("# Findings\n\nIt is **mostly** fine, but `parse` is slow.\n\n");
    try renderer.feed("- one\n- two\n\n```zig\nconst x = 1;\n```\n\nDone.\n");
    try renderer.endBlock();

    try renderer.beginBlock(.notice);
    try renderer.feed("no provider configured\n");
    try renderer.endBlock();

    renderer.setPrompt(.{ .text = "and now?", .cursor = 8 });

    try paintInto(&bytes, gpa, &renderer);
    return transcript.expectGolden(gpa, name, bytes.items);
}

test "golden: dark at truecolor" {
    try scene("theme-dark-truecolor", "dark", .truecolor);
}

test "golden: dark at ansi256" {
    try scene("theme-dark-ansi256", "dark", .ansi256);
}

test "golden: dark with no colour" {
    try scene("theme-dark-none", "dark", .none);
}

test "golden: light at truecolor" {
    try scene("theme-light-truecolor", "light", .truecolor);
}

test "golden: light at ansi256" {
    try scene("theme-light-ansi256", "light", .ansi256);
}

test "golden: light with no colour" {
    try scene("theme-light-none", "light", .none);
}

test "at the none tier the two themes are the same bytes" {
    // The accessibility rule as a byte string: every distinction in the scene
    // is drawn by an attribute, so a theme has nothing left to say once the
    // colour is gone — and a change that makes one of them say something is a
    // change that put meaning in a colour.
    const gpa = testing.allocator;
    const dark = try readGoldenFile(gpa, "theme-dark-none");
    defer gpa.free(dark);
    const light = try readGoldenFile(gpa, "theme-light-none");
    defer gpa.free(light);
    try testing.expectEqualStrings(dark, light);
}

fn readGoldenFile(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "testdata/golden/{s}.txt", .{name});
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(1 << 20));
}

test "golden: a live theme switch repaints the tail and not the scrollback" {
    // `/theme` in Phase 10 is three lines that call `setTheme`. What it can and
    // cannot do is visible here: the second frame paints its tail in the new
    // colours, and it does not go back over the rows the first frame committed.
    // That is the same append-only rule as everything else in the renderer, and
    // it is honest behaviour rather than a limitation with an apology attached.
    const gpa = testing.allocator;

    var dark = registry.resolve(gpa, testing.io, "dark", null, .default);
    defer dark.deinit(gpa);
    var light = registry.resolve(gpa, testing.io, "light", null, .default);
    defer light.deinit(gpa);

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);

    var renderer: Renderer = .init(gpa, caps(.truecolor), caps(.truecolor).size);
    defer renderer.deinit();
    renderer.setTheme(dark.result.theme);

    try renderer.beginBlock(.notice);
    try renderer.feed("before the switch\n");
    try renderer.endBlock();
    renderer.setPrompt(.{ .text = "typing", .cursor = 6 });
    try paintInto(&bytes, gpa, &renderer);

    renderer.setTheme(light.result.theme);
    try renderer.beginBlock(.notice);
    try renderer.feed("after the switch\n");
    try renderer.endBlock();
    try paintInto(&bytes, gpa, &renderer);

    return transcript.expectGolden(gpa, "theme-switch", bytes.items);
}
