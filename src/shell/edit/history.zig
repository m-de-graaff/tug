//! The prompt history: a file of past submissions, and a cursor into it.
//!
//! Three things make this more than an array of strings.
//!
//! **It is lazy.** Nothing here is read until the first time it is needed, and
//! the first time it is needed is the first press of `up` — which is strictly
//! later than the "after first paint" the spec asks for, and for the same
//! reason: the 10 ms cold-start budget has no room for a file read nobody has
//! asked for. A session that never presses `up` never opens the file at all.
//!
//! **It stashes the draft.** Navigating away from a half-typed message and back
//! again must return the half-typed message. The stash is what makes `up` safe
//! to press.
//!
//! **It never fails loudly.** A history file that cannot be read, written or
//! created costs the user their history and nothing else. `write_failed`
//! records it so Phase 10's `/config` can say so; there is no path from here to
//! a shell that refuses to start.
//!
//! The file format and its location are `DR-012`.

const std = @import("std");

/// The cap, from the spec. Reached, the oldest entries are dropped and the file
/// is rewritten — "truncate from the front", which is the only truncation that
/// keeps what a person is likely to want.
pub const max_entries: usize = 1000;

/// The most history tug will read. A file larger than this has been corrupted
/// or appended to by something else, and the right response is an empty history
/// rather than an allocation nobody budgeted for.
const read_limit: usize = 4 * 1024 * 1024;

/// The environment variables the path is built from. A struct rather than three
/// arguments so the resolution is table-testable without an environment.
pub const Location = struct {
    xdg_state_home: ?[]const u8 = null,
    home: ?[]const u8 = null,
    local_app_data: ?[]const u8 = null,
};

/// Where the history file lives, or null when nothing in the environment names
/// a directory to put it in.
///
/// `windows` is a parameter rather than a `builtin` check so both branches are
/// tested on both platforms. The caller passes `builtin.os.tag == .windows`.
pub fn resolvePath(
    gpa: std.mem.Allocator,
    where: Location,
    windows: bool,
) std.mem.Allocator.Error!?[]u8 {
    if (windows) {
        const base = where.local_app_data orelse return null;
        return try std.fmt.allocPrint(gpa, "{s}\\tug\\history", .{base});
    }
    if (where.xdg_state_home) |base| {
        return try std.fmt.allocPrint(gpa, "{s}/tug/history", .{base});
    }
    if (where.home) |base| {
        return try std.fmt.allocPrint(gpa, "{s}/.local/state/tug/history", .{base});
    }
    return null;
}

/// Appends `text` as one file line's worth of bytes — the newline itself is the
/// writer's business, because an entry never contains one.
pub fn encodeInto(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    text: []const u8,
) std.mem.Allocator.Error!void {
    for (text) |byte| switch (byte) {
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        // A CR in an entry would make the file's line structure depend on the
        // platform that wrote it. The decoder strips them from pastes and the
        // editor never inserts one, so this is belt and braces.
        '\r' => {},
        else => try out.append(gpa, byte),
    };
}

pub fn decodeInto(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    line: []const u8,
) std.mem.Allocator.Error!void {
    var at: usize = 0;
    while (at < line.len) : (at += 1) {
        if (line[at] != '\\' or at + 1 >= line.len) {
            try out.append(gpa, line[at]);
            continue;
        }
        at += 1;
        switch (line[at]) {
            'n' => try out.append(gpa, '\n'),
            '\\' => try out.append(gpa, '\\'),
            // An escape nothing wrote. Keep both bytes rather than guessing: a
            // history file is not a trust boundary, but it is not a place to
            // lose a character either.
            else => {
                try out.append(gpa, '\\');
                try out.append(gpa, line[at]);
            },
        }
    }
}

pub const History = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Borrowed and outlives this struct. Null means this session has no
    /// persistent history — every method still works, in memory.
    path: ?[]const u8,

    /// Oldest first, so an append is a push and the cap is a shift.
    entries: std.ArrayList([]u8) = .empty,
    loaded: bool = false,
    /// Set once something could not be written. Nothing reads it yet; Phase
    /// 10's `/config` is its consumer.
    write_failed: bool = false,

    /// The entry being shown, or null while the draft is the draft.
    browsing: ?usize = null,
    /// What was in the editor when browsing began.
    stash: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, path: ?[]const u8) History {
        return .{ .gpa = gpa, .io = io, .path = path };
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |entry| self.gpa.free(entry);
        self.entries.deinit(self.gpa);
        self.stash.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn count(self: *const History) usize {
        return self.entries.items.len;
    }

    /// Reads the file, once, the first time anything needs it.
    ///
    /// Every failure here is silent and leaves an empty history: a file that is
    /// missing, unreadable, or larger than `read_limit`. None of those is a
    /// reason to refuse a shell.
    pub fn ensureLoaded(self: *History) void {
        if (self.loaded) return;
        self.loaded = true;

        const path = self.path orelse return;
        const bytes = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.gpa,
            .limited(read_limit),
        ) catch return;
        defer self.gpa.free(bytes);

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var decoded: std.ArrayList(u8) = .empty;
            decodeInto(&decoded, self.gpa, line) catch {
                decoded.deinit(self.gpa);
                return;
            };
            const owned = decoded.toOwnedSlice(self.gpa) catch {
                decoded.deinit(self.gpa);
                return;
            };
            self.entries.append(self.gpa, owned) catch {
                self.gpa.free(owned);
                return;
            };
        }

        // A file that has grown past the cap — an older tug, or a hand edit — is
        // trimmed here rather than left to grow.
        if (self.entries.items.len > max_entries) {
            self.trim();
            self.rewrite();
        }
    }

    /// Records a submission: in memory always, on disk when there is a path.
    pub fn append(self: *History, text: []const u8) void {
        self.ensureLoaded();
        self.reset();

        if (text.len == 0) return;
        if (self.entries.items.len > 0) {
            const last = self.entries.items[self.entries.items.len - 1];
            if (std.mem.eql(u8, last, text)) return;
        }

        const owned = self.gpa.dupe(u8, text) catch {
            self.write_failed = true;
            return;
        };
        self.entries.append(self.gpa, owned) catch {
            self.gpa.free(owned);
            self.write_failed = true;
            return;
        };

        if (self.entries.items.len > max_entries) {
            self.trim();
            // The cap needs the file rewritten anyway, so the append rides
            // along inside it rather than happening twice.
            self.rewrite();
            return;
        }
        self.appendLine(text);
    }

    /// The previous entry, stashing the draft on the way in. Null means there
    /// is nowhere further back to go.
    pub fn prev(self: *History, draft: []const u8) ?[]const u8 {
        self.ensureLoaded();
        if (self.entries.items.len == 0) return null;

        if (self.browsing) |index| {
            if (index == 0) return null;
            self.browsing = index - 1;
        } else {
            self.stash.clearRetainingCapacity();
            self.stash.appendSlice(self.gpa, draft) catch {};
            self.browsing = self.entries.items.len - 1;
        }
        return self.entries.items[self.browsing.?];
    }

    /// The next entry, or the stashed draft once past the newest one. Null
    /// means the draft is already what is on screen.
    pub fn next(self: *History) ?[]const u8 {
        const index = self.browsing orelse return null;
        if (index + 1 < self.entries.items.len) {
            self.browsing = index + 1;
            return self.entries.items[index + 1];
        }
        self.browsing = null;
        return self.stash.items;
    }

    /// Ends a browse without restoring anything. Called on submit and on any
    /// edit that is not navigation.
    pub fn reset(self: *History) void {
        self.browsing = null;
        self.stash.clearRetainingCapacity();
    }

    /// Drops from the front until the cap is met.
    fn trim(self: *History) void {
        if (self.entries.items.len <= max_entries) return;
        const over = self.entries.items.len - max_entries;
        for (self.entries.items[0..over]) |entry| self.gpa.free(entry);
        std.mem.copyForwards([]u8, self.entries.items, self.entries.items[over..]);
        self.entries.items.len -= over;
    }

    /// One entry onto the end of the file.
    ///
    /// There is no append mode and no seek in this standard library, so the
    /// append is a length followed by a positional write at that offset. Two
    /// tugs writing at once can interleave; the loser of that race loses one
    /// entry, which is the correct amount of machinery to spend on a shell
    /// history.
    ///
    /// ponytail: no file lock. Add one if sessions start sharing a history and
    /// anyone notices.
    fn appendLine(self: *History, text: []const u8) void {
        const path = self.path orelse return;
        const dir: std.Io.Dir = .cwd();

        if (parentOf(path)) |parent| {
            dir.createDirPath(self.io, parent) catch {
                self.write_failed = true;
                return;
            };
        }

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.gpa);
        encodeInto(&line, self.gpa, text) catch {
            self.write_failed = true;
            return;
        };
        line.append(self.gpa, '\n') catch {
            self.write_failed = true;
            return;
        };

        var file = dir.createFile(self.io, path, .{ .truncate = false }) catch {
            self.write_failed = true;
            return;
        };
        defer file.close(self.io);

        const end = file.length(self.io) catch {
            self.write_failed = true;
            return;
        };
        file.writePositionalAll(self.io, line.items, end) catch {
            self.write_failed = true;
        };
    }

    /// Replaces the file with what is in memory. Used when the cap bites, which
    /// is the one case an append cannot express.
    fn rewrite(self: *History) void {
        const path = self.path orelse return;
        const dir: std.Io.Dir = .cwd();

        if (parentOf(path)) |parent| {
            dir.createDirPath(self.io, parent) catch {
                self.write_failed = true;
                return;
            };
        }

        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(self.gpa);
        for (self.entries.items) |entry| {
            encodeInto(&buffer, self.gpa, entry) catch {
                self.write_failed = true;
                return;
            };
            buffer.append(self.gpa, '\n') catch {
                self.write_failed = true;
                return;
            };
        }

        dir.writeFile(self.io, .{ .sub_path = path, .data = buffer.items }) catch {
            self.write_failed = true;
        };
    }
};

/// The directory part of a path, under either separator, or null when there is
/// none to create.
fn parentOf(path: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const backslash = std.mem.lastIndexOfScalar(u8, path, '\\');
    const at = if (slash) |s| (if (backslash) |b| @max(s, b) else s) else backslash;
    const cut = at orelse return null;
    if (cut == 0) return null;
    return path[0..cut];
}

const testing = std.testing;

/// Builds an `Io` the way the golden harness does, since these tests touch real
/// files and `std.Io.Threaded` is the only implementation `tugshell` has.
fn testIo(threaded: *std.Io.Threaded) std.Io {
    threaded.* = .init_single_threaded;
    return threaded.io();
}

/// A path under `testing.tmpDir`'s directory, joined with the platform's own
/// separator.
///
/// Native rather than `/`, because that is what `resolvePath` produces and
/// therefore what the code under test actually receives. Hardcoding `/` made
/// this fail on Windows — and, worse, made two of the tests below pass for the
/// wrong reason, since a path no directory was ever created for fails to read
/// and fails to write exactly as an absent one does.
fn tmpPath(buffer: []u8, tmp: *const testing.TmpDir, tail: []const u8) ![]const u8 {
    const sep = std.fs.path.sep_str;
    return std.fmt.bufPrint(
        buffer,
        ".zig-cache" ++ sep ++ "tmp" ++ sep ++ "{s}" ++ sep ++ "{s}",
        .{ tmp.sub_path, tail },
    );
}

test "the POSIX path prefers XDG_STATE_HOME and falls back to HOME" {
    const gpa = testing.allocator;

    const explicit = (try resolvePath(gpa, .{ .xdg_state_home = "/var/state" }, false)).?;
    defer gpa.free(explicit);
    try testing.expectEqualStrings("/var/state/tug/history", explicit);

    const implied = (try resolvePath(gpa, .{ .home = "/home/ada" }, false)).?;
    defer gpa.free(implied);
    try testing.expectEqualStrings("/home/ada/.local/state/tug/history", implied);

    // XDG wins when both are set.
    const both = (try resolvePath(gpa, .{
        .xdg_state_home = "/var/state",
        .home = "/home/ada",
    }, false)).?;
    defer gpa.free(both);
    try testing.expectEqualStrings("/var/state/tug/history", both);

    // Nothing to build a path from is not an error; it is a session without
    // persistent history.
    try testing.expectEqual(@as(?[]u8, null), try resolvePath(gpa, .{}, false));
}

test "the Windows path uses LOCALAPPDATA and backslashes" {
    const gpa = testing.allocator;

    const path = (try resolvePath(
        gpa,
        .{ .local_app_data = "C:\\Users\\ada\\AppData\\Local" },
        true,
    )).?;
    defer gpa.free(path);
    try testing.expectEqualStrings("C:\\Users\\ada\\AppData\\Local\\tug\\history", path);

    // XDG and HOME are ignored there: an XDG path on Windows is a POSIX habit,
    // not a Windows convention.
    try testing.expectEqual(
        @as(?[]u8, null),
        try resolvePath(gpa, .{ .xdg_state_home = "/var/state", .home = "/home/ada" }, true),
    );
}

test "a multiline entry survives the escape round trip" {
    const gpa = testing.allocator;

    const cases = [_][]const u8{
        "plain",
        "two\nlines",
        "a backslash \\ and a newline \n",
        "\\n is not a newline",
        "",
    };

    for (cases) |text| {
        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(gpa);
        try encodeInto(&encoded, gpa, text);
        // The whole point: one entry is one line in the file.
        try testing.expectEqual(
            @as(?usize, null),
            std.mem.indexOfScalar(u8, encoded.items, '\n'),
        );

        var decoded: std.ArrayList(u8) = .empty;
        defer decoded.deinit(gpa);
        try decodeInto(&decoded, gpa, encoded.items);
        try testing.expectEqualStrings(text, decoded.items);
    }
}

test "a trailing backslash decodes to a backslash rather than eating the end" {
    const gpa = testing.allocator;
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(gpa);
    try decodeInto(&decoded, gpa, "trailing \\");
    try testing.expectEqualStrings("trailing \\", decoded.items);
}

test "navigation walks back, walks forward, and restores the draft" {
    var history: History = .init(testing.allocator, undefined, null);
    defer history.deinit();

    history.append("first");
    history.append("second");
    history.append("third");
    try testing.expectEqual(@as(usize, 3), history.count());

    try testing.expectEqualStrings("third", history.prev("draft").?);
    try testing.expectEqualStrings("second", history.prev("draft").?);
    try testing.expectEqualStrings("first", history.prev("draft").?);
    // The oldest entry is the end of the road, and pressing on stays there.
    try testing.expectEqual(@as(?[]const u8, null), history.prev("draft"));

    try testing.expectEqualStrings("second", history.next().?);
    try testing.expectEqualStrings("third", history.next().?);
    // Past the newest entry is the draft that was stashed on the way in.
    try testing.expectEqualStrings("draft", history.next().?);
    try testing.expectEqual(@as(?[]const u8, null), history.next());
}

test "an empty history has nothing to navigate to" {
    var history: History = .init(testing.allocator, undefined, null);
    defer history.deinit();

    try testing.expectEqual(@as(?[]const u8, null), history.prev("draft"));
    try testing.expectEqual(@as(?[]const u8, null), history.next());
}

test "consecutive duplicates collapse and non-consecutive ones do not" {
    var history: History = .init(testing.allocator, undefined, null);
    defer history.deinit();

    history.append("same");
    history.append("same");
    try testing.expectEqual(@as(usize, 1), history.count());

    history.append("other");
    history.append("same");
    try testing.expectEqual(@as(usize, 3), history.count());
}

test "the cap drops the oldest entries rather than refusing new ones" {
    var history: History = .init(testing.allocator, undefined, null);
    defer history.deinit();

    var buffer: [16]u8 = undefined;
    for (0..max_entries + 5) |index| {
        history.append(try std.fmt.bufPrint(&buffer, "entry {d}", .{index}));
    }
    try testing.expectEqual(max_entries, history.count());

    // The newest is still reachable and the oldest is gone.
    try testing.expectEqualStrings("entry 1004", history.prev("").?);
    try testing.expectEqualStrings("entry 5", history.entries.items[0]);
}

test "submitting while browsing starts the next navigation from the newest" {
    var history: History = .init(testing.allocator, undefined, null);
    defer history.deinit();

    history.append("one");
    history.append("two");
    _ = history.prev("draft");
    _ = history.prev("draft");

    // A submit ends the browse; the stashed draft goes with it.
    history.append("three");
    try testing.expectEqualStrings("three", history.prev("fresh").?);
}

test "entries survive a restart, multiline ones included" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [128]u8 = undefined;
    const sep = std.fs.path.sep_str;
    const path = try tmpPath(&path_buffer, &tmp, "state" ++ sep ++ "tug" ++ sep ++ "history");

    {
        var history: History = .init(gpa, io, path);
        defer history.deinit();
        history.ensureLoaded();
        history.append("single line");
        history.append("first\nsecond");
        try testing.expect(!history.write_failed);
    }

    // The file is really on disk, not just in the second History's memory.
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4096));
    defer gpa.free(raw);
    try testing.expect(std.mem.indexOf(u8, raw, "first\\nsecond") != null);

    var reopened: History = .init(gpa, io, path);
    defer reopened.deinit();
    reopened.ensureLoaded();

    try testing.expectEqual(@as(usize, 2), reopened.count());
    try testing.expectEqualStrings("first\nsecond", reopened.prev("").?);
    try testing.expectEqualStrings("single line", reopened.prev("").?);
}

test "a missing file is an empty history, not a failure" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [128]u8 = undefined;
    const path = try tmpPath(&path_buffer, &tmp, "never-written");

    var history: History = .init(gpa, io, path);
    defer history.deinit();
    history.ensureLoaded();

    try testing.expectEqual(@as(usize, 0), history.count());
    try testing.expect(!history.write_failed);
}

test "a path that cannot be written records the failure and keeps going" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = undefined;
    const io = testIo(&threaded);

    // A path whose parent is a file rather than a directory: creating the
    // directory has to fail, and the shell has to survive it.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "blocker", .data = "not a directory" });

    var path_buffer: [128]u8 = undefined;
    const sep = std.fs.path.sep_str;
    const path = try tmpPath(&path_buffer, &tmp, "blocker" ++ sep ++ "tug" ++ sep ++ "history");

    var history: History = .init(gpa, io, path);
    defer history.deinit();
    history.ensureLoaded();
    history.append("this goes nowhere");

    try testing.expect(history.write_failed);
    // In memory it is still there, so the session behaves normally.
    try testing.expectEqual(@as(usize, 1), history.count());
}
