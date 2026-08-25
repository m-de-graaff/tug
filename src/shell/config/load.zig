//! Finding the config files, reading them, and owning the bytes the resolved
//! `Config` borrows.
//!
//! Everything above this file is a pure function of bytes — that split is what
//! the `wasm32-freestanding` job enforces, and it is why the schema lives in
//! `tugcore` and this does not.
//!
//! **Nothing here fails.** A file that is missing is the normal case and not even
//! a warning. A file that exists and cannot be read is one note and a shell that
//! opens anyway. No configuration mistake is worth refusing to start over, and
//! the way to guarantee that is for the return type not to have an error in it.
//!
//! **Read once, at startup, after the first paint.** `repl.run` calls this after
//! the prompt is on screen, for the same reason the capability probe happens
//! there (`DR-003`): the cold-start budget is 10 ms and a file read is not free.
//! Live reload is explicitly not v0.1.

const std = @import("std");
const testing = std.testing;

const core = @import("tugcore");

/// The most config tug will read from one file. Past this it is not a config.
const read_limit: usize = 1 << 20;

/// The project-layer path, relative to the working directory. There is no upward
/// search for a project root: tug's project layer is "the directory you ran it
/// in", which is a rule that fits in a sentence and never surprises anybody
/// about which file won.
pub const project_path: []const u8 = ".tug/config.toml";

/// The environment variables the user-layer path is built from. A struct rather
/// than three arguments so resolution is table-testable without an environment,
/// exactly as `history.Location` is.
pub const Location = struct {
    xdg_config_home: ?[]const u8 = null,
    home: ?[]const u8 = null,
    /// `%APPDATA%` — roaming, because a config is a preference and preferences
    /// follow the user. History uses `%LOCALAPPDATA%` because it is state.
    app_data: ?[]const u8 = null,
};

/// Where the user config lives, or null when nothing in the environment names a
/// directory to look in.
///
/// `windows` is a parameter rather than a `builtin` check so both branches are
/// tested on both platforms. The caller passes `builtin.os.tag == .windows`.
pub fn userPath(
    gpa: std.mem.Allocator,
    where: Location,
    windows: bool,
) std.mem.Allocator.Error!?[]u8 {
    if (windows) {
        const base = where.app_data orelse return null;
        return try std.fmt.allocPrint(gpa, "{s}\\tug\\config.toml", .{base});
    }
    if (where.xdg_config_home) |base| {
        return try std.fmt.allocPrint(gpa, "{s}/tug/config.toml", .{base});
    }
    if (where.home) |base| {
        return try std.fmt.allocPrint(gpa, "{s}/.config/tug/config.toml", .{base});
    }
    return null;
}

/// Where user themes live, or null when nothing in the environment names a
/// directory to look in.
///
/// Beside the config file rather than under a data directory: a theme is a
/// preference, and preferences live with the preferences. On Windows that means
/// roaming `%APPDATA%`, for the reason `Location.app_data` gives.
pub fn themesDir(
    gpa: std.mem.Allocator,
    where: Location,
    windows: bool,
) std.mem.Allocator.Error!?[]u8 {
    if (windows) {
        const base = where.app_data orelse return null;
        return try std.fmt.allocPrint(gpa, "{s}\\tug\\themes", .{base});
    }
    if (where.xdg_config_home) |base| {
        return try std.fmt.allocPrint(gpa, "{s}/tug/themes", .{base});
    }
    if (where.home) |base| {
        return try std.fmt.allocPrint(gpa, "{s}/.config/tug/themes", .{base});
    }
    return null;
}

/// Everything the load needs that only `main` can find out. The environment
/// values are indexed by `core.config.env_keys`, in that table's order.
pub const Sources = struct {
    user_path: ?[]const u8 = null,
    project_path: []const u8 = default_project_path,
    env: [core.config.env_keys.len]?[]const u8 = @splat(null),
    /// `--theme <name>`, and the first value any command-line flag writes into
    /// the config. The `flag` layer has existed since Phase 7 with nothing but
    /// a unit test above the environment; this is what puts something there.
    theme_flag: ?[]const u8 = null,

    const default_project_path = project_path;
};

/// A resolved config and the bytes it borrows from.
pub const Loaded = struct {
    config: core.config.Config,
    user_bytes: ?[]u8,
    project_bytes: ?[]u8,
    /// Indexed by layer, for `Config.writeNotes`.
    origins: [5][]const u8,

    pub fn deinit(self: *Loaded, gpa: std.mem.Allocator) void {
        if (self.user_bytes) |bytes| gpa.free(bytes);
        if (self.project_bytes) |bytes| gpa.free(bytes);
        self.* = undefined;
    }
};

/// Reads both files and merges every layer, in order.
pub fn load(gpa: std.mem.Allocator, io: std.Io, sources: Sources) Loaded {
    var loaded: Loaded = .{
        .config = .{},
        .user_bytes = null,
        .project_bytes = null,
        .origins = .{
            "<defaults>",
            sources.user_path orelse "<none>",
            sources.project_path,
            "<environment>",
            "<flags>",
        },
    };

    if (sources.user_path) |path| {
        loaded.user_bytes = read(gpa, io, path, &loaded.config, .user);
    }
    if (loaded.user_bytes) |bytes| loaded.config.apply(.user, bytes);

    loaded.project_bytes = read(gpa, io, sources.project_path, &loaded.config, .project);
    if (loaded.project_bytes) |bytes| loaded.config.apply(.project, bytes);

    for (core.config.env_keys, sources.env) |entry, value| {
        if (value) |text| loaded.config.setScalar(.env, entry.key, text);
    }

    if (sources.theme_flag) |name| loaded.config.setScalar(.flag, "theme", name);

    return loaded;
}

/// The bytes of one config file, or null when there are none to be had.
///
/// The distinction that matters is between a file that is not there — which is
/// what almost every tug user has, and is silent — and a file that is there and
/// will not open, which is worth one line on screen. `FileNotFound` is the only
/// error that means the former.
fn read(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    config: *core.config.Config,
    layer: core.config.Layer,
) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(read_limit)) catch |err| {
        if (err != error.FileNotFound) {
            config.note(.{
                .kind = .file_unreadable,
                .layer = layer,
                .at = .{ .line = 0, .column = 0 },
            });
        }
        return null;
    };
}

test "the user config path follows XDG, then HOME, then nothing" {
    const gpa = testing.allocator;

    const xdg = try userPath(gpa, .{ .xdg_config_home = "/x/config" }, false);
    defer gpa.free(xdg.?);
    try testing.expectEqualStrings("/x/config/tug/config.toml", xdg.?);

    const home = try userPath(gpa, .{ .home = "/home/x" }, false);
    defer gpa.free(home.?);
    try testing.expectEqualStrings("/home/x/.config/tug/config.toml", home.?);

    // XDG wins when both are set, which is what the spec's layering names.
    const both = try userPath(gpa, .{
        .xdg_config_home = "/x/config",
        .home = "/home/x",
    }, false);
    defer gpa.free(both.?);
    try testing.expectEqualStrings("/x/config/tug/config.toml", both.?);

    try testing.expectEqual(@as(?[]u8, null), try userPath(gpa, .{}, false));
}

test "the user config path on Windows is APPDATA" {
    const gpa = testing.allocator;

    const roaming = try userPath(gpa, .{ .app_data = "C:\\Users\\x\\AppData\\Roaming" }, true);
    defer gpa.free(roaming.?);
    try testing.expectEqualStrings("C:\\Users\\x\\AppData\\Roaming\\tug\\config.toml", roaming.?);

    // HOME may well be set under a POSIX-ish shell on Windows; the platform
    // decides, not the environment, exactly as `history.resolvePath` does.
    try testing.expectEqual(@as(?[]u8, null), try userPath(gpa, .{ .home = "/home/x" }, true));
}

test "a missing file is not a note" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init_single_threaded;

    var loaded = load(gpa, threaded.io(), .{
        .user_path = "definitely/not/here/config.toml",
        .project_path = "definitely/not/here/either.toml",
        .env = @splat(null),
    });
    defer loaded.deinit(gpa);

    // A config file nobody wrote is the normal case, not a problem.
    try testing.expectEqual(@as(usize, 0), loaded.config.notes().len);
    try testing.expectEqualStrings("dark", loaded.config.theme.value);
    try testing.expectEqual(core.config.Layer.default, loaded.config.theme.source);
}

test "the environment layer is applied in table order" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init_single_threaded;

    var env: [core.config.env_keys.len]?[]const u8 = @splat(null);
    for (core.config.env_keys, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.variable, "TUG_THEME")) env[index] = "mono";
    }

    var loaded = load(gpa, threaded.io(), .{
        .user_path = null,
        .project_path = "definitely/not/here.toml",
        .env = env,
    });
    defer loaded.deinit(gpa);

    try testing.expectEqualStrings("mono", loaded.config.theme.value);
    try testing.expectEqual(core.config.Layer.env, loaded.config.theme.source);
}

/// The path a file in `tmp` has *relative to the working directory*, which is
/// what the loader resolves against.
///
/// `std.testing.tmpDir` puts its directory under `.zig-cache/tmp/`, and there is
/// no `realpath` on `Io.Dir` in 0.16 — so the path is composed from the pieces
/// rather than asked for. `zig build test` runs its binaries from the build
/// root, which is the same thing that makes the renderer's goldens resolvable.
fn tmpPath(
    gpa: std.mem.Allocator,
    tmp: *const std.testing.TmpDir,
    name: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/{s}", .{ &tmp.sub_path, name });
}

test "the flag layer sits above the environment" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init_single_threaded;

    var env: [core.config.env_keys.len]?[]const u8 = @splat(null);
    for (core.config.env_keys, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.variable, "TUG_THEME")) env[index] = "from-env";
    }

    var loaded = load(gpa, threaded.io(), .{
        .user_path = null,
        .project_path = "definitely/not/here.toml",
        .env = env,
        .theme_flag = "from-flag",
    });
    defer loaded.deinit(gpa);

    // Closes the Phase 7 carry-forward: until now the top of the layering was
    // exercised only by a unit test on `setScalar`, because nothing wrote to it.
    try testing.expectEqualStrings("from-flag", loaded.config.theme.value);
    try testing.expectEqual(core.config.Layer.flag, loaded.config.theme.source);
}

test "the project layer beats the user layer, and both are read" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "user.toml",
        .data = "theme = \"user\"\n[history]\nmax_entries = 7\n",
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "project.toml",
        .data = "theme = \"project\"\n",
    });

    const user = try tmpPath(gpa, &tmp, "user.toml");
    defer gpa.free(user);
    const project = try tmpPath(gpa, &tmp, "project.toml");
    defer gpa.free(project);

    var loaded = load(gpa, io, .{
        .user_path = user,
        .project_path = project,
        .env = @splat(null),
    });
    defer loaded.deinit(gpa);

    try testing.expectEqualStrings("project", loaded.config.theme.value);
    try testing.expectEqual(core.config.Layer.project, loaded.config.theme.source);

    // The user layer is still there underneath, which is the whole point of
    // layering rather than picking a file.
    try testing.expectEqual(@as(u32, 7), loaded.config.history_max_entries.value);
    try testing.expectEqual(core.config.Layer.user, loaded.config.history_max_entries.source);

    // And the origins name the files, so a note can point at one.
    try testing.expectEqualStrings(user, loaded.origins[@intFromEnum(core.config.Layer.user)]);
}

test "values borrow the file bytes and survive until deinit" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{
        .sub_path = "c.toml",
        .data = "theme = \"borrowed\"\n[keys]\n\"ctrl+j\" = \"newline\"\n",
    });
    const path = try tmpPath(gpa, &tmp, "c.toml");
    defer gpa.free(path);

    var loaded = load(gpa, io, .{
        .user_path = path,
        .project_path = "definitely/not/here.toml",
        .env = @splat(null),
    });
    defer loaded.deinit(gpa);

    // Under `std.testing.allocator` this is also the use-after-free check: the
    // bytes these slices point into are owned by `loaded`, and reading them here
    // proves they were not freed by the read that produced them.
    try testing.expectEqualStrings("borrowed", loaded.config.theme.value);
    try testing.expectEqualStrings("ctrl+j", loaded.config.bindings()[0].chord);
    try testing.expectEqualStrings("newline", loaded.config.bindings()[0].action);
}

test "a directory where a config file should be is a note, not a failure" {
    const gpa = testing.allocator;
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "config.toml");
    const path = try tmpPath(gpa, &tmp, "config.toml");
    defer gpa.free(path);

    var loaded = load(gpa, io, .{
        .user_path = path,
        .project_path = "definitely/not/here.toml",
        .env = @splat(null),
    });
    defer loaded.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), loaded.config.notes().len);
    try testing.expectEqual(
        core.config.Note.Kind.file_unreadable,
        loaded.config.notes()[0].kind,
    );
    try testing.expectEqualStrings("dark", loaded.config.theme.value);
}
