//! The `/` surface: what a leading slash means, and the five commands v0.1 has.
//!
//! This file knows nothing about a session, a renderer or a terminal. It turns
//! a line into a decision and a prefix into a name, and both are pure — which
//! is what lets the whole surface be unit-tested without a pty and what keeps
//! the handlers in `repl.zig` down to a switch.
//!
//! **The table is the registry, and `/help` reads it.** An unregistered command
//! cannot appear in help because there is nowhere else for help to read from;
//! the comptime block below makes the converse true as well, so a command
//! cannot be added to the enum and left out of the table.
//!
//! **A path is not a command.** The first token is checked for a `/` of its own
//! before it is looked up, so `/usr/share/x is missing` is submitted as the
//! sentence it is. `DR-014` records why that rule is here rather than a
//! character class.

const std = @import("std");
const testing = std.testing;

const core = @import("tugcore");

/// Every command v0.1 has. The tag name is the word after the slash, which is
/// why there is no `name` field to drift from it.
pub const Id = enum { help, quit, config, theme, keys, demo };

pub const Command = struct {
    id: Id,
    /// The argument spec `/help` prints after the name; "" when the command
    /// takes none.
    args: []const u8 = "",
    summary: []const u8,

    pub fn name(self: Command) []const u8 {
        return @tagName(self.id);
    }
};

pub const table: []const Command = &.{
    .{ .id = .help, .summary = "list the commands" },
    .{ .id = .quit, .summary = "leave tug" },
    .{ .id = .config, .summary = "the resolved settings, and where each came from" },
    .{ .id = .theme, .args = "[name]", .summary = "list the themes, or switch to one" },
    .{ .id = .keys, .summary = "the live key bindings" },
    .{ .id = .demo, .summary = "the probe from Phase 10; removed in the next commit" },
};

comptime {
    const fields = @typeInfo(Id).@"enum".fields;
    if (table.len != fields.len) {
        @compileError("every command in Id needs a row in `table`, and vice versa");
    }
    for (table, 0..) |entry, index| {
        if (@intFromEnum(entry.id) != index) {
            @compileError("`table` must be in `Id` order, so a row can be found by its tag");
        }
    }
}

/// Every command name, for `core.nearest`. Built from the table so a name
/// nobody can be corrected towards is a name that is not registered.
pub const names: []const []const u8 = built: {
    var list: [table.len][]const u8 = undefined;
    for (table, 0..) |entry, index| list[index] = entry.name();
    const frozen = list;
    break :built &frozen;
};

/// What a submitted line turns out to be.
pub const Parsed = union(enum) {
    /// Send it to the provider. Everything that is not a command is this.
    prompt,
    run: struct {
        id: Id,
        /// The argument text, trimmed. "" when there is none. Borrows `line`.
        rest: []const u8,
    },
    unknown: struct {
        /// The word after the slash. "" for a bare `/`. Borrows `line`.
        word: []const u8,
        /// The nearest registered name, or "" when nothing was close.
        suggestion: []const u8,
    },
};

const separators = " \t\n";

pub fn parse(line: []const u8) Parsed {
    const text = std.mem.trim(u8, line, separators);
    if (text.len == 0 or text[0] != '/') return .prompt;

    const body = text[1..];
    const end = std.mem.indexOfAny(u8, body, separators) orelse body.len;
    const word = body[0..end];

    // A path is not a command, and this is the whole of that rule.
    if (std.mem.indexOfScalar(u8, word, '/') != null) return .prompt;

    const rest = std.mem.trim(u8, body[end..], separators);

    for (table) |entry| {
        if (std.mem.eql(u8, entry.name(), word)) {
            return .{ .run = .{ .id = entry.id, .rest = rest } };
        }
    }

    return .{ .unknown = .{
        .word = word,
        .suggestion = core.nearest.nearest(names, word) orelse "",
    } };
}

/// The one command name `prefix` completes to, or null when nothing or more
/// than one does.
///
/// ponytail: a unique match or nothing. Completing an ambiguous prefix to the
/// longest common one is what a shell does; no two of the five names today
/// share a first letter, so it would be code with no input. Add it the version
/// two commands collide.
pub fn complete(prefix: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (table) |entry| {
        const candidate = entry.name();
        if (!std.mem.startsWith(u8, candidate, prefix)) continue;
        if (found != null) return null;
        found = candidate;
    }
    return found;
}

/// The column `Config.write`, `Keymap.write` and `Theme.write` all use, for the
/// reason they all use it: a person who runs two of these in a row should see
/// one left edge.
const command_column = 21;

/// The `/help` screen. Reads `table` and nothing else.
pub fn writeHelp(out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.writeAll("command              what it does\n");
    for (table) |entry| {
        var buffer: [40]u8 = undefined;
        const label = if (entry.args.len == 0)
            std.fmt.bufPrint(&buffer, "/{s}", .{entry.name()}) catch entry.name()
        else
            std.fmt.bufPrint(&buffer, "/{s} {s}", .{ entry.name(), entry.args }) catch entry.name();

        try out.writeAll("  ");
        try out.writeAll(label);
        // Indented by two and measured from the left edge, exactly as
        // `Keymap.writeRow` does it — hence the `+ 2`.
        var index = label.len + 2;
        while (index < command_column - 1) : (index += 1) try out.writeAll(" ");
        try out.writeAll(" ");
        try out.writeAll(entry.summary);
        try out.writeAll("\n");
    }
}

test "a line without a leading slash is a prompt" {
    try testing.expectEqual(Parsed.prompt, parse("hello there"));
    try testing.expectEqual(Parsed.prompt, parse(""));
    try testing.expectEqual(Parsed.prompt, parse("   "));
    // Leading whitespace is trimmed, so an indented command is still one.
    try testing.expectEqual(Id.help, parse("  /help  ").run.id);
}

test "a path is not a command" {
    // `/usr/share/x is missing` is a sentence somebody meant to send. Eating it
    // because of its first byte is the surprise this rule exists to prevent.
    try testing.expectEqual(Parsed.prompt, parse("/usr/share/x is missing"));
    try testing.expectEqual(Parsed.prompt, parse("/etc/hosts"));
}

test "every command in the table parses to its own id" {
    for (table) |entry| {
        var buffer: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&buffer, "/{s}", .{entry.name()});
        try testing.expectEqual(entry.id, parse(line).run.id);
    }
}

test "the argument is everything after the first token, trimmed" {
    const parsed = parse("/theme   solarized light  ");
    try testing.expectEqual(Id.theme, parsed.run.id);
    try testing.expectEqualStrings("solarized light", parsed.run.rest);

    // No argument is an empty argument, never a null to unwrap.
    try testing.expectEqualStrings("", parse("/theme").run.rest);
    try testing.expectEqualStrings("", parse("/theme   ").run.rest);
}

test "a near miss is suggested and a wild guess is not" {
    const near = parse("/thme").unknown;
    try testing.expectEqualStrings("thme", near.word);
    try testing.expectEqualStrings("theme", near.suggestion);

    const wild = parse("/xyzzy").unknown;
    try testing.expectEqualStrings("xyzzy", wild.word);
    try testing.expectEqualStrings("", wild.suggestion);
}

test "a bare slash is unknown with nothing to suggest" {
    // There is no word to be close to, so the caller prints the sentence that
    // points at `/help` rather than a suggestion it does not have.
    const parsed = parse("/").unknown;
    try testing.expectEqualStrings("", parsed.word);
    try testing.expectEqualStrings("", parsed.suggestion);
}

test "completion finishes a unique prefix and refuses an ambiguous one" {
    try testing.expectEqualStrings("help", complete("h").?);
    try testing.expectEqualStrings("theme", complete("the").?);
    // An exact name completes to itself rather than to null.
    try testing.expectEqualStrings("keys", complete("keys").?);
    // Every command matches, so there is no single answer.
    try testing.expectEqual(@as(?[]const u8, null), complete(""));
    try testing.expectEqual(@as(?[]const u8, null), complete("zzz"));
}

test "help names every command and cannot name one that is not registered" {
    var buffer: [2048]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try writeHelp(&writer);
    const text = writer.buffered();

    for (table) |entry| {
        var name_buffer: [32]u8 = undefined;
        const slashed = try std.fmt.bufPrint(&name_buffer, "/{s}", .{entry.name()});
        try testing.expect(std.mem.indexOf(u8, text, slashed) != null);
        try testing.expect(std.mem.indexOf(u8, text, entry.summary) != null);
    }
    // The argument spec is on the screen, not only in the parser.
    try testing.expect(std.mem.indexOf(u8, text, "/theme [name]") != null);
}

test "the names list is the table's names, in the table's order" {
    // `nearest` is handed this list, so a name missing from it is a command
    // nobody gets a suggestion for.
    try testing.expectEqual(table.len, names.len);
    for (table, names) |entry, name| {
        try testing.expectEqualStrings(entry.name(), name);
    }
}
