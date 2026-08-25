//! Finding a theme by name, and owning the bytes its warnings borrow.
//!
//! The two built-ins are `@embedFile`d and go through `core.theme.parse` — the
//! same function, on the same TOML subset, as any file a user writes. They are
//! fixtures, not special cases, which is what makes "a hand-written user theme
//! loads by name" a property of the parser rather than a second code path.
//!
//! **Built-ins first, then the user directory.** A user who wants to edit the
//! dark theme copies it to another name. The alternative rule — your file
//! shadows ours — turns "why did my colours change" into a question about which
//! of two files tug preferred, and there is no answer to that which fits in a
//! sentence.
//!
//! **Nothing here fails.** A missing themes directory is the normal case. A
//! name that is not a theme is one warning and the dark built-in. The rule
//! Phase 7 wrote down holds: no configuration mistake is worth refusing to
//! start over.

const std = @import("std");
const testing = std.testing;

const core = @import("tugcore");
const config_load = @import("../config/load.zig");

/// The most theme tug will read from one file. Past this it is not a theme.
const read_limit: usize = 1 << 20;

const dark_source = @embedFile("dark.toml");
const light_source = @embedFile("light.toml");

pub const builtin_names: []const []const u8 = &.{ "dark", "light" };

/// The one a broken or unknown name falls back to. Named rather than inlined
/// because two places refer to it, and it is the same string
/// `core.config.default_theme` holds in the other module.
pub const fallback_name: []const u8 = "dark";

fn builtinSource(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "dark")) return dark_source;
    if (std.mem.eql(u8, name, "light")) return light_source;
    return null;
}

/// A resolved theme, the bytes its notes borrow, and where those bytes came
/// from. `origin` is what `Result.writeNotes` prints in the location column,
/// and it is a path for a user theme and `<built-in dark>` for a built-in —
/// because "the file to open" is the only thing a warning's location is for.
pub const Loaded = struct {
    result: core.theme.Result,
    /// Owned when a user theme was read; null for a built-in, whose source is
    /// static.
    bytes: ?[]u8 = null,
    /// Owned when `origin_owned`; a static string otherwise.
    origin: []const u8,
    origin_owned: bool = false,

    pub fn deinit(self: *Loaded, gpa: std.mem.Allocator) void {
        if (self.bytes) |bytes| gpa.free(bytes);
        if (self.origin_owned) gpa.free(@constCast(self.origin));
        self.* = undefined;
    }
};

/// A theme name is one path component, and that is the whole of the rule.
///
/// The name comes from a config file, and a config file is not a trust boundary
/// tug controls: `theme = "../../../etc/ssh/sshd_config"` must be *not a theme
/// name* rather than an open() of that path. Rejecting separators and the two
/// directory entries is enough, and it is enough precisely because the name is
/// only ever joined to one directory.
fn isSimpleName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |byte| {
        if (byte == '/' or byte == '\\' or byte == 0) return false;
    }
    return true;
}

/// The theme called `name`, from the built-ins or from `dir`.
///
/// `layer` is stamped on every note only so a caller printing these beside a
/// config's notes has both fields populated. A theme is one file, not a stack.
pub fn resolve(
    gpa: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    dir: ?[]const u8,
    layer: core.config.Layer,
) Loaded {
    if (builtinSource(name)) |source| {
        return .{
            .result = core.theme.parse(source, layer),
            .origin = if (std.mem.eql(u8, name, "dark"))
                "<built-in dark>"
            else
                "<built-in light>",
        };
    }

    if (isSimpleName(name)) {
        if (dir) |base| {
            if (readUser(gpa, io, base, name, layer)) |found| return found;
        }
    }

    return unknown(gpa, io, name, layer);
}

/// `<dir>/<name>.toml`, or null when there is no such file.
///
/// An allocation failure here is treated as "no such theme" rather than
/// propagated: this function is on the path that must not have an error set,
/// and a machine that cannot allocate a path is not a machine that will get a
/// better answer from a different theme.
fn readUser(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    name: []const u8,
    layer: core.config.Layer,
) ?Loaded {
    const separator: []const u8 = if (std.mem.indexOfScalar(u8, dir, '\\') != null) "\\" else "/";
    const path = std.fmt.allocPrint(gpa, "{s}{s}{s}.toml", .{ dir, separator, name }) catch
        return null;

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(read_limit)) catch {
        // Missing is the normal case and silent; unreadable falls through to
        // the same place, because the warning the caller gets — "no such
        // theme", naming the name — is the sentence that helps either way.
        gpa.free(path);
        return null;
    };

    return .{
        .result = core.theme.parse(bytes, layer),
        .bytes = bytes,
        .origin = path,
        .origin_owned = true,
    };
}

/// The dark built-in, plus one warning naming what was asked for.
fn unknown(
    gpa: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    layer: core.config.Layer,
) Loaded {
    var loaded = resolve(gpa, io, fallback_name, null, layer);
    loaded.result.note(.{
        .kind = .unknown_theme,
        .layer = layer,
        // There is no file and no line: the name came from a config value, and
        // that value's own position belongs to the config's note, not this one.
        .at = .{ .line = 0, .column = 0 },
        .text = name,
    });
    return loaded;
}

test "both built-ins parse without a single note" {
    for (builtin_names) |name| {
        var loaded = resolve(testing.allocator, testing.io, name, null, .default);
        defer loaded.deinit(testing.allocator);
        // A built-in that warns is a built-in with a typo in it, and it would
        // warn on every startup for every user.
        try testing.expectEqual(@as(usize, 0), loaded.result.notes().len);
    }
}

test "a built-in is resolved without touching the filesystem" {
    var loaded = resolve(testing.allocator, testing.io, "dark", "/definitely/not/here", .default);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(?[]u8, null), loaded.bytes);
    try testing.expectEqualStrings("<built-in dark>", loaded.origin);
    try testing.expectEqual(
        core.theme.Rgb{ .r = 0x4e, .g = 0xc9, .b = 0xb0 },
        loaded.result.theme.color(.accent).rgb,
    );
}

test "the two built-ins differ only where they must" {
    var dark = resolve(testing.allocator, testing.io, "dark", null, .default);
    defer dark.deinit(testing.allocator);
    var light = resolve(testing.allocator, testing.io, "light", null, .default);
    defer light.deinit(testing.allocator);

    // Prose is the terminal's own colour in both: tug does not know what your
    // background is and does not pretend to.
    try testing.expectEqual(core.theme.Color.default, dark.result.theme.color(.fg));
    try testing.expectEqual(core.theme.Color.default, light.result.theme.color(.fg));
    try testing.expectEqual(core.theme.Color.default, dark.result.theme.color(.assistant_block));
    try testing.expectEqual(core.theme.Color.default, light.result.theme.color(.assistant_block));

    // And they diverge on every slot that has to be legible against one.
    for ([_]core.theme.Slot{ .dim, .accent, .user_block, .notice, .@"error", .prompt }) |slot| {
        try testing.expect(!std.meta.eql(
            dark.result.theme.color(slot),
            light.result.theme.color(slot),
        ));
    }
    try testing.expect(!std.meta.eql(dark.result.theme.code_bg, light.result.theme.code_bg));
}

test "every built-in colour clears WCAG AA, as written and as quantized" {
    // The accessibility bar with a number on it, enforced in CI rather than in
    // a style guide. `reference` is the background the palette is designed
    // against; tug never paints it, which is exactly why it lives here and not
    // in the theme file — a key only a test reads would be a key that lies.
    const cases = [_]struct { name: []const u8, reference: core.theme.Rgb }{
        .{ .name = "dark", .reference = .{ .r = 0x1e, .g = 0x1e, .b = 0x1e } },
        .{ .name = "light", .reference = .{ .r = 0xf5, .g = 0xf5, .b = 0xf5 } },
    };

    for (cases) |case| {
        var loaded = resolve(testing.allocator, testing.io, case.name, null, .default);
        defer loaded.deinit(testing.allocator);
        const theme = loaded.result.theme;

        // Code is drawn on `code_bg`, everything else on the reference. Both
        // are checked, because a colour legible on one is not automatically
        // legible on the other.
        const backgrounds = [_]core.theme.Rgb{
            case.reference,
            switch (theme.code_bg) {
                .default => case.reference,
                .rgb => |rgb| rgb,
            },
        };

        for (std.enums.values(core.theme.Slot)) |slot| {
            const colour = switch (theme.color(slot)) {
                // Nothing to measure: it is the user's own foreground, already
                // legible against their own background by construction.
                .default => continue,
                .rgb => |rgb| rgb,
            };
            for (backgrounds) |background| {
                try expectAA(case.name, @tagName(slot), colour, background, false);
                // The colour an ansi256 terminal actually paints is not the one
                // in the file. Check that one too, or the gate only covers the
                // terminals that need it least.
                try expectAA(
                    case.name,
                    @tagName(slot),
                    dequantize(core.theme.quantize(colour)),
                    dequantize(core.theme.quantize(background)),
                    true,
                );
            }
        }
    }
}

/// Fails with the theme, the slot, the tier and the ratio, because a bare
/// `expect(false)` on a contrast gate tells you a palette is wrong and not
/// which colour or by how much.
fn expectAA(
    theme_name: []const u8,
    slot_name: []const u8,
    foreground: core.theme.Rgb,
    background: core.theme.Rgb,
    quantized: bool,
) !void {
    const ratio = core.theme.contrast(foreground, background);
    if (ratio >= 4.5) return;
    std.debug.print(
        "\n{s}.{s} {s}: #{x:0>2}{x:0>2}{x:0>2} on #{x:0>2}{x:0>2}{x:0>2} is {d:.2}:1, below 4.5:1\n",
        .{
            theme_name,
            slot_name,
            if (quantized) "(ansi256)" else "(truecolor)",
            foreground.r,
            foreground.g,
            foreground.b,
            background.r,
            background.g,
            background.b,
            ratio,
        },
    );
    return error.ContrastBelowAA;
}

/// The RGB an xterm-256 index actually paints. The inverse of `quantize`, and
/// only a test needs it — the renderer emits the index and lets the terminal
/// look it up.
fn dequantize(index: u8) core.theme.Rgb {
    if (index >= 232) {
        const level: u8 = @intCast(8 + (@as(u16, index) - 232) * 10);
        return .{ .r = level, .g = level, .b = level };
    }
    const levels = [6]u8{ 0, 95, 135, 175, 215, 255 };
    const offset: u16 = @as(u16, index) - 16;
    return .{
        .r = levels[offset / 36],
        .g = levels[(offset % 36) / 6],
        .b = levels[offset % 6],
    };
}

test "quantize and dequantize agree on the cube corners" {
    // Guards the test helper itself: a broken `dequantize` would make the
    // contrast gate above measure the wrong colours and pass anyway.
    try testing.expectEqual(core.theme.Rgb{ .r = 0, .g = 0, .b = 0 }, dequantize(16));
    try testing.expectEqual(core.theme.Rgb{ .r = 255, .g = 255, .b = 255 }, dequantize(231));
    try testing.expectEqual(core.theme.Rgb{ .r = 0x80, .g = 0x80, .b = 0x80 }, dequantize(244));
    try testing.expectEqual(core.theme.Rgb{ .r = 255, .g = 0, .b = 0 }, dequantize(196));
}

test "an unknown name falls back to dark and says so" {
    var loaded = resolve(testing.allocator, testing.io, "drak", null, .project);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), loaded.result.notes().len);
    try testing.expectEqual(core.config.Note.Kind.unknown_theme, loaded.result.notes()[0].kind);
    try testing.expectEqualStrings("drak", loaded.result.notes()[0].text);
    // And it is still a usable shell: the fallback is a real theme, not the
    // colourless one.
    try testing.expectEqual(
        core.theme.Rgb{ .r = 0x4e, .g = 0xc9, .b = 0xb0 },
        loaded.result.theme.color(.accent).rgb,
    );
}

/// The path a file in `tmp` has *relative to the working directory*, which is
/// what the resolver joins against. The same construction `config/load.zig`
/// uses and for the same reason: there is no `realpath` on `Io.Dir` in 0.16.
fn tmpDirPath(gpa: std.mem.Allocator, tmp: *const std.testing.TmpDir) ![]u8 {
    return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
}

test "a user theme is found by name in the themes directory" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "mine.toml", .data = "accent = \"#123456\"\n" });

    const dir = try tmpDirPath(gpa, &tmp);
    defer gpa.free(dir);

    var loaded = resolve(gpa, io, "mine", dir, .user);
    defer loaded.deinit(gpa);

    try testing.expectEqual(@as(usize, 0), loaded.result.notes().len);
    try testing.expectEqual(
        core.theme.Rgb{ .r = 0x12, .g = 0x34, .b = 0x56 },
        loaded.result.theme.color(.accent).rgb,
    );
    // Slots the file did not mention are the terminal's, not dark's: a user
    // theme is a theme, not a patch over a built-in.
    try testing.expectEqual(core.theme.Color.default, loaded.result.theme.color(.notice));
}

test "a built-in name wins over a file of the same name" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "dark.toml", .data = "accent = \"#000000\"\n" });

    const dir = try tmpDirPath(gpa, &tmp);
    defer gpa.free(dir);

    var loaded = resolve(gpa, io, "dark", dir, .user);
    defer loaded.deinit(gpa);

    // "Built-ins first, then user dir" from the spec. A user who wants to edit
    // the dark theme copies it to another name, which is a rule that fits in a
    // sentence — unlike "your file shadows ours unless it is broken".
    try testing.expectEqual(
        core.theme.Rgb{ .r = 0x4e, .g = 0xc9, .b = 0xb0 },
        loaded.result.theme.color(.accent).rgb,
    );
}

test "a name that would escape the themes directory resolves to nothing" {
    // A theme name comes from a config file, and a config file is not a trust
    // boundary tug controls. `theme = "../../../etc/passwd"` must not become an
    // open() of that path — it is simply not a theme name.
    for ([_][]const u8{ "../x", "a/b", "a\\b", "", ".", ".." }) |name| {
        var loaded = resolve(testing.allocator, testing.io, name, "/tmp", .project);
        defer loaded.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), loaded.result.notes().len);
        try testing.expectEqual(
            core.config.Note.Kind.unknown_theme,
            loaded.result.notes()[0].kind,
        );
    }
}

test "a broken user theme is a warning and a shell that still opens" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "broken.toml", .data = "accent = \"puce\"\n" });

    const dir = try tmpDirPath(gpa, &tmp);
    defer gpa.free(dir);

    var loaded = resolve(gpa, io, "broken", dir, .user);
    defer loaded.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), loaded.result.notes().len);
    try testing.expectEqual(core.config.Note.Kind.bad_color, loaded.result.notes()[0].kind);
    // The origin is the path, so the warning points at the file somebody has to
    // open.
    try testing.expect(std.mem.endsWith(u8, loaded.origin, "broken.toml"));
}

test "the themes directory sits beside the config file" {
    const gpa = testing.allocator;

    const xdg = try config_load.themesDir(gpa, .{ .xdg_config_home = "/x/config" }, false);
    defer gpa.free(xdg.?);
    try testing.expectEqualStrings("/x/config/tug/themes", xdg.?);

    const home = try config_load.themesDir(gpa, .{ .home = "/home/x" }, false);
    defer gpa.free(home.?);
    try testing.expectEqualStrings("/home/x/.config/tug/themes", home.?);

    const roaming = try config_load.themesDir(
        gpa,
        .{ .app_data = "C:\\Users\\x\\AppData\\Roaming" },
        true,
    );
    defer gpa.free(roaming.?);
    try testing.expectEqualStrings("C:\\Users\\x\\AppData\\Roaming\\tug\\themes", roaming.?);

    try testing.expectEqual(@as(?[]u8, null), try config_load.themesDir(gpa, .{}, false));
}
