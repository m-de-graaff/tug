//! tug's configuration: what the keys are, what the layers are, and which layer
//! set each value.
//!
//! **Provenance is the feature.** A resolved value that cannot say where it came
//! from turns "why is my theme wrong" into a search of four files. Every scalar
//! here carries the layer that last wrote it, and `/config` in Phase 10 prints
//! that column.
//!
//! **Nothing here fails.** There is no error set and no allocator. A file that is
//! nonsense produces a `Config` full of defaults and a list of notes; a value of
//! the wrong type keeps the value that was already there and adds a note. The
//! rule from the spec is that a typo in a keybind must never brick the shell,
//! and the way to guarantee that is for the failure path not to exist.
//!
//! **The keymap is collected, not merged.** Scalars are last-layer-wins; `[keys]`
//! entries accumulate with their layer and line attached, because Phase 8's
//! conflict warning has to name both sides and cannot do that from a map that
//! already dropped one.
//!
//! The capacities below are fixed for the same reason there is no error set: a
//! growable list would need an allocator, an allocator would need a failure
//! path, and the failure path in a config loader is exactly the code nobody
//! tests. The ceilings are commented where they are declared.

const std = @import("std");
const testing = std.testing;

const toml = @import("toml.zig");

/// The layering order from the roadmap, lowest first. The order of this enum is
/// load-bearing: `write` prints in it, `writeNotes` indexes an array by it, and
/// Phase 8 compares by it.
pub const Layer = enum {
    default,
    user,
    project,
    env,
    flag,
};

/// A value and the layer that last set it.
pub fn Resolved(comptime T: type) type {
    return struct {
        value: T,
        source: Layer = .default,

        const Self = @This();

        fn set(self: *Self, value: T, layer: Layer) void {
            self.value = value;
            self.source = layer;
        }
    };
}

/// ponytail: 128 keymap entries across every layer. A keymap that large is a
/// different feature — per-mode maps, which v0.1 refuses by name — and this cap
/// is what makes the whole config allocation-free. Overflow is a
/// `too_many_bindings` note, never a silent drop.
pub const max_bindings = 128;

/// ponytail: 32 warnings. Past that the config is not a config with a typo in
/// it, it is the wrong file, and 32 lines is already more than anybody reads.
/// The last slot is spent on `notes_truncated` so the screen says so.
pub const max_notes = 32;

/// The default theme name. Phase 9 resolves it against the theme registry; here
/// it is a string with a provenance, and that is the whole of its meaning.
pub const default_theme = "dark";

/// An unparsed keymap entry. Both strings borrow the source; Phase 8 parses the
/// chord and resolves the action name.
pub const Binding = struct {
    chord: []const u8,
    action: []const u8,
    layer: Layer,
    at: toml.Position,
};

/// One thing that was wrong with a config file, in a shape `/config` can print.
pub const Note = struct {
    kind: Kind,
    layer: Layer,
    at: toml.Position,
    /// The offending key, table or value. Borrows the source; "" when the
    /// problem is not about a name.
    text: []const u8 = "",

    /// The scanner's refusals and the schema's, flattened into one enum so that
    /// every consumer switches once. The mapping from `toml.Problem` is an
    /// explicit switch rather than a shared numbering, because two enums that
    /// must agree by integer value agree right up until somebody reorders one.
    pub const Kind = enum {
        expected_key,
        expected_equals,
        expected_value,
        unterminated_string,
        unterminated_table,
        escape_unsupported,
        bad_integer,
        trailing_text,
        dotted_key_unsupported,
        array_unsupported,
        inline_table_unsupported,
        array_of_tables_unsupported,
        unknown_table,
        unknown_key,
        wrong_type,
        bad_color,
        unknown_theme,
        duplicate_key,
        too_many_bindings,
        notes_truncated,
        file_unreadable,
    };

    pub fn message(kind: Kind) []const u8 {
        return switch (kind) {
            .expected_key => "expected a key",
            .expected_equals => "expected '=' after the key",
            .expected_value => "expected a string, integer or boolean",
            .unterminated_string => "a string was not closed before the end of the line",
            .unterminated_table => "a table header was not closed with ']'",
            .escape_unsupported => "escape sequences are not supported; use a literal string in single quotes",
            .bad_integer => "an integer that does not fit in 64 bits",
            .trailing_text => "unexpected text after the value",
            .dotted_key_unsupported => "dotted keys are not supported; use a [table] header",
            .array_unsupported => "arrays are not supported",
            .inline_table_unsupported => "inline tables are not supported; use a [table] header",
            .array_of_tables_unsupported => "arrays of tables are not supported",
            .unknown_table => "no such section",
            .unknown_key => "no such setting",
            .wrong_type => "the value is not the type this setting takes",
            .bad_color => "not a colour; use '#rrggbb', '#rgb' or 'default'",
            .unknown_theme => "no such theme",
            .duplicate_key => "set twice in the same file; the last one wins",
            .too_many_bindings => "too many key bindings; the rest were ignored",
            .notes_truncated => "further problems were not reported",
            .file_unreadable => "the file exists but could not be read",
        };
    }

    /// One line, in the shape every compiler has used since cc: a location, a
    /// severity, and a sentence.
    pub fn write(
        self: Note,
        out: *std.Io.Writer,
        origin: []const u8,
    ) std.Io.Writer.Error!void {
        try out.print("{s}:{d}:{d}: warning: {s}", .{
            origin,
            self.at.line,
            self.at.column,
            message(self.kind),
        });
        if (self.text.len > 0) try out.print(" ('{s}')", .{self.text});
        try out.writeAll("\n");
    }
};

/// The environment mapping, and the whole of the documented rule: **scalar keys
/// only**. `[keys]` has no environment form because a table of chords has no
/// scalar spelling, and inventing one — `TUG_KEYS_CTRL_J` — would be a second
/// syntax to specify, parse and explain.
pub const EnvKey = struct {
    variable: []const u8,
    /// The dotted name `setScalar` takes.
    key: []const u8,
};

pub const env_keys: []const EnvKey = &.{
    .{ .variable = "TUG_THEME", .key = "theme" },
    .{ .variable = "TUG_HISTORY", .key = "history.enabled" },
    .{ .variable = "TUG_HISTORY_MAX", .key = "history.max_entries" },
    .{ .variable = "TUG_PROVIDER", .key = "provider.preset" },
    .{ .variable = "TUG_MODEL", .key = "provider.model" },
    // Deliberately absent: a `TUG_KEY`. A key belongs in the preset's own
    // variable, where every provider's own documentation already puts it, and a
    // second spelling is a second place to leak one from (`DR-024`).
};

pub const Config = struct {
    theme: Resolved([]const u8) = .{ .value = default_theme },
    history_enabled: Resolved(bool) = .{ .value = true },
    history_max_entries: Resolved(u32) = .{ .value = 1000 },

    provider_preset: Resolved([]const u8) = .{ .value = "" },
    provider_model: Resolved([]const u8) = .{ .value = "" },
    /// A key written into a config file, which the documentation discourages
    /// and this schema still supports: a user who has decided to do it will do
    /// it with or without tug's blessing, and the alternative is a key exported
    /// in a shell profile, which is not better.
    ///
    /// **Never printed.** `/config` shows `<set>` or `<unset>` and the layer,
    /// and there is a canary test on exactly that surface.
    provider_key: Resolved([]const u8) = .{ .value = "" },
    /// `key_cmd = "pass show anthropic"`. Run once, cached for the process.
    /// `DR-024` is why this exists and why a keychain integration does not.
    provider_key_cmd: Resolved([]const u8) = .{ .value = "" },
    /// The read timeout, which is also the stall detector's threshold.
    provider_timeout_ms: Resolved(u32) = .{ .value = 60_000 },
    /// Plaintext to a non-loopback host. Off, and a per-endpoint decision the
    /// day endpoints are configurable one at a time.
    provider_insecure: Resolved(bool) = .{ .value = false },

    binding_storage: [max_bindings]Binding = undefined,
    binding_count: usize = 0,

    note_storage: [max_notes]Note = undefined,
    note_count: usize = 0,

    pub fn bindings(self: *const Config) []const Binding {
        return self.binding_storage[0..self.binding_count];
    }

    pub fn notes(self: *const Config) []const Note {
        return self.note_storage[0..self.note_count];
    }

    /// Which scalar keys this layer has already set, so that a key set twice in
    /// one file is a duplicate and the same key in two files is layering.
    const Seen = struct {
        theme: bool = false,
        history_enabled: bool = false,
        history_max_entries: bool = false,
        provider_preset: bool = false,
        provider_model: bool = false,
        provider_key: bool = false,
        provider_key_cmd: bool = false,
        provider_timeout_ms: bool = false,
        provider_insecure: bool = false,
    };

    /// Applies one file's worth of TOML as one layer.
    ///
    /// `source` is borrowed by every string this stores, so it must outlive the
    /// `Config`. `src/shell/config/load.zig` is what owns it.
    pub fn apply(self: *Config, layer: Layer, source: []const u8) void {
        var scanner: toml.Scanner = .init(source);
        var seen: Seen = .{};

        while (scanner.next()) |item| switch (item) {
            .problem => |problem| self.note(.{
                .kind = fromProblem(problem.kind),
                .layer = layer,
                .at = problem.at,
            }),
            .pair => |pair| self.applyPair(layer, pair, &seen),
        };
    }

    fn fromProblem(problem: toml.Problem) Note.Kind {
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

    fn applyPair(self: *Config, layer: Layer, pair: toml.Pair, seen: *Seen) void {
        const eql = std.mem.eql;

        if (eql(u8, pair.table, "keys")) {
            if (pair.value != .string) return self.wrongType(layer, pair);
            if (self.binding_count == max_bindings) {
                // Once. A file with three hundred bindings would otherwise spend
                // every note slot saying the same thing.
                for (self.notes()) |existing| {
                    if (existing.kind == .too_many_bindings) return;
                }
                return self.note(.{
                    .kind = .too_many_bindings,
                    .layer = layer,
                    .at = pair.at,
                    .text = pair.key,
                });
            }
            self.binding_storage[self.binding_count] = .{
                .chord = pair.key,
                .action = pair.value.string,
                .layer = layer,
                .at = pair.at,
            };
            self.binding_count += 1;
            return;
        }

        if (eql(u8, pair.table, "")) {
            if (eql(u8, pair.key, "theme")) {
                if (pair.value != .string) return self.wrongType(layer, pair);
                self.duplicate(layer, pair, &seen.theme);
                self.theme.set(pair.value.string, layer);
                return;
            }
            return self.unknown(.unknown_key, layer, pair.at, pair.key);
        }

        if (eql(u8, pair.table, "history")) {
            if (eql(u8, pair.key, "enabled")) {
                if (pair.value != .boolean) return self.wrongType(layer, pair);
                self.duplicate(layer, pair, &seen.history_enabled);
                self.history_enabled.set(pair.value.boolean, layer);
                return;
            }
            if (eql(u8, pair.key, "max_entries")) {
                if (pair.value != .integer) return self.wrongType(layer, pair);
                const count = pair.value.integer;
                // Out of range is the same class of mistake as the wrong type,
                // and gets the same message: the value is not what this setting
                // takes. Wrapping it into a u32 would be the only worse answer.
                if (count < 0 or count > std.math.maxInt(u32)) {
                    return self.wrongType(layer, pair);
                }
                self.duplicate(layer, pair, &seen.history_max_entries);
                self.history_max_entries.set(@intCast(count), layer);
                return;
            }
            return self.unknown(.unknown_key, layer, pair.at, pair.key);
        }

        if (eql(u8, pair.table, "provider")) {
            if (eql(u8, pair.key, "preset")) {
                if (pair.value != .string) return self.wrongType(layer, pair);
                self.duplicate(layer, pair, &seen.provider_preset);
                self.provider_preset.set(pair.value.string, layer);
                return;
            }
            if (eql(u8, pair.key, "model")) {
                if (pair.value != .string) return self.wrongType(layer, pair);
                self.duplicate(layer, pair, &seen.provider_model);
                self.provider_model.set(pair.value.string, layer);
                return;
            }
            if (eql(u8, pair.key, "key")) {
                if (pair.value != .string) return self.wrongType(layer, pair);
                self.duplicate(layer, pair, &seen.provider_key);
                self.provider_key.set(pair.value.string, layer);
                return;
            }
            if (eql(u8, pair.key, "key_cmd")) {
                if (pair.value != .string) return self.wrongType(layer, pair);
                self.duplicate(layer, pair, &seen.provider_key_cmd);
                self.provider_key_cmd.set(pair.value.string, layer);
                return;
            }
            if (eql(u8, pair.key, "timeout_ms")) {
                if (pair.value != .integer) return self.wrongType(layer, pair);
                const ms = pair.value.integer;
                if (ms < 0 or ms > std.math.maxInt(u32)) return self.wrongType(layer, pair);
                self.duplicate(layer, pair, &seen.provider_timeout_ms);
                self.provider_timeout_ms.set(@intCast(ms), layer);
                return;
            }
            if (eql(u8, pair.key, "insecure")) {
                if (pair.value != .boolean) return self.wrongType(layer, pair);
                self.duplicate(layer, pair, &seen.provider_insecure);
                self.provider_insecure.set(pair.value.boolean, layer);
                return;
            }
            return self.unknown(.unknown_key, layer, pair.at, pair.key);
        }

        self.unknown(.unknown_table, layer, pair.at, pair.table);
    }

    /// Sets one scalar key by its dotted name, from a source that has no types —
    /// the environment and the command line, where everything is text.
    ///
    /// The same warnings apply: an unparseable value is a note and the previous
    /// value stands. `TUG_HISTORY=yes` should not be the reason a shell fails to
    /// open, and it should also not silently mean `false`.
    pub fn setScalar(
        self: *Config,
        layer: Layer,
        key: []const u8,
        text: []const u8,
    ) void {
        const eql = std.mem.eql;
        // There is no file and no line. Zero rather than one, so that a reader
        // who sees `<environment>:0:0` knows the position is not a position
        // rather than looking for line 1 of something.
        const at: toml.Position = .{ .line = 0, .column = 0 };

        if (eql(u8, key, "theme")) {
            self.theme.set(text, layer);
            return;
        }
        if (eql(u8, key, "history.enabled")) {
            const value = parseBool(text) orelse
                return self.note(.{ .kind = .wrong_type, .layer = layer, .at = at, .text = key });
            self.history_enabled.set(value, layer);
            return;
        }
        if (eql(u8, key, "history.max_entries")) {
            const value = std.fmt.parseInt(u32, text, 10) catch
                return self.note(.{ .kind = .wrong_type, .layer = layer, .at = at, .text = key });
            self.history_max_entries.set(value, layer);
            return;
        }
        if (eql(u8, key, "provider.preset")) {
            self.provider_preset.set(text, layer);
            return;
        }
        if (eql(u8, key, "provider.model")) {
            self.provider_model.set(text, layer);
            return;
        }
        if (eql(u8, key, "provider.timeout_ms")) {
            const value = std.fmt.parseInt(u32, text, 10) catch
                return self.note(.{ .kind = .wrong_type, .layer = layer, .at = at, .text = key });
            self.provider_timeout_ms.set(value, layer);
            return;
        }
        self.note(.{ .kind = .unknown_key, .layer = layer, .at = at, .text = key });
    }

    /// `true`/`false` as TOML spells them, plus the two spellings every shell
    /// user will try first. Nothing else — `TUG_HISTORY=maybe` is a warning.
    fn parseBool(text: []const u8) ?bool {
        if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "1")) return true;
        if (std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "0")) return false;
        return null;
    }

    fn duplicate(self: *Config, layer: Layer, pair: toml.Pair, flag: *bool) void {
        if (flag.*) {
            self.note(.{
                .kind = .duplicate_key,
                .layer = layer,
                .at = pair.at,
                .text = pair.key,
            });
        }
        flag.* = true;
    }

    fn wrongType(self: *Config, layer: Layer, pair: toml.Pair) void {
        self.note(.{
            .kind = .wrong_type,
            .layer = layer,
            .at = pair.at,
            .text = pair.key,
        });
    }

    fn unknown(
        self: *Config,
        kind: Note.Kind,
        layer: Layer,
        at: toml.Position,
        text: []const u8,
    ) void {
        self.note(.{ .kind = kind, .layer = layer, .at = at, .text = text });
    }

    /// Records a note, or — in the last slot — records that there were more.
    pub fn note(self: *Config, entry: Note) void {
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

    // --- the report --------------------------------------------------------

    /// The column the value starts in, and the column `from` starts in. Both are
    /// minimums, not maximums: a value wider than its column pushes the next one
    /// right rather than being cut, because a truncated value on the one screen
    /// whose job is telling you your value would be a bug with a tidy left edge.
    const setting_column = 21;
    const value_column = 21;

    fn pad(out: *std.Io.Writer, written: usize, want: usize) std.Io.Writer.Error!void {
        var index = written;
        while (index < want) : (index += 1) try out.writeAll(" ");
        try out.writeAll(" ");
    }

    fn row(
        out: *std.Io.Writer,
        setting: []const u8,
        value: []const u8,
        from: Layer,
    ) std.Io.Writer.Error!void {
        try out.writeAll(setting);
        try pad(out, setting.len, setting_column - 1);
        try out.writeAll(value);
        try pad(out, value.len, value_column - 1);
        try out.print("{t}\n", .{from});
    }

    /// The `/config` screen: every resolved setting, its value, and the layer
    /// that set it. Phase 10 renders this into a notice block; `--debug-config`
    /// prints it directly.
    pub fn write(self: *const Config, out: *std.Io.Writer) std.Io.Writer.Error!void {
        try out.writeAll("setting              value                from\n");

        try row(out, "theme", self.theme.value, self.theme.source);

        try row(
            out,
            "history.enabled",
            if (self.history_enabled.value) "true" else "false",
            self.history_enabled.source,
        );

        var number: [16]u8 = undefined;
        try row(
            out,
            "history.max_entries",
            std.fmt.bufPrint(&number, "{d}", .{self.history_max_entries.value}) catch "?",
            self.history_max_entries.source,
        );

        try row(out, "provider.preset", self.provider_preset.value, self.provider_preset.source);
        try row(out, "provider.model", self.provider_model.value, self.provider_model.source);

        // Never the value. `/config` is the surface most likely to be pasted
        // into an issue, and there is a canary test on this line.
        try row(
            out,
            "provider.key",
            if (self.provider_key.value.len == 0) "<unset>" else "<set>",
            self.provider_key.source,
        );
        // The command is not a secret. It is the instruction for fetching one,
        // and hiding it would make a misconfigured key_cmd undiagnosable.
        try row(out, "provider.key_cmd", self.provider_key_cmd.value, self.provider_key_cmd.source);

        var timeout: [16]u8 = undefined;
        try row(
            out,
            "provider.timeout_ms",
            std.fmt.bufPrint(&timeout, "{d}", .{self.provider_timeout_ms.value}) catch "?",
            self.provider_timeout_ms.source,
        );
        try row(
            out,
            "provider.insecure",
            if (self.provider_insecure.value) "true" else "false",
            self.provider_insecure.source,
        );

        // Bindings come last and in the order they were collected, which is
        // layer order. Phase 8 adds the conflict marking; the data is here now.
        for (self.bindings()) |binding| {
            var name: [64]u8 = undefined;
            const setting = std.fmt.bufPrint(&name, "keys.\"{s}\"", .{binding.chord}) catch
                "keys.\"...\"";
            try row(out, setting, binding.action, binding.layer);
        }
    }

    /// Every warning, one per line, each naming the file it came from.
    ///
    /// `origins` is indexed by layer, so a note can say `.tug/config.toml:4:1`
    /// rather than `line 4` — which file it was is the half a person needs.
    pub fn writeNotes(
        self: *const Config,
        out: *std.Io.Writer,
        origins: [5][]const u8,
    ) std.Io.Writer.Error!void {
        for (self.notes()) |entry| {
            try entry.write(out, origins[@intFromEnum(entry.layer)]);
        }
    }
};

test "the defaults are the defaults, and they say so" {
    const config: Config = .{};
    try testing.expectEqualStrings("dark", config.theme.value);
    try testing.expectEqual(Layer.default, config.theme.source);
    try testing.expectEqual(true, config.history_enabled.value);
    try testing.expectEqual(@as(u32, 1000), config.history_max_entries.value);
    try testing.expectEqual(@as(usize, 0), config.bindings().len);
    try testing.expectEqual(@as(usize, 0), config.notes().len);
}

test "a later layer wins and stamps itself" {
    var config: Config = .{};
    config.apply(.user, "theme = \"light\"\n");
    try testing.expectEqualStrings("light", config.theme.value);
    try testing.expectEqual(Layer.user, config.theme.source);

    config.apply(.project, "theme = \"tokyo\"\n");
    try testing.expectEqualStrings("tokyo", config.theme.value);
    try testing.expectEqual(Layer.project, config.theme.source);

    // A layer that does not mention a key does not touch its provenance.
    config.apply(.project, "[history]\nenabled = false\n");
    try testing.expectEqualStrings("tokyo", config.theme.value);
    try testing.expectEqual(Layer.project, config.theme.source);
    try testing.expectEqual(false, config.history_enabled.value);
}

test "every scalar key round-trips through its table" {
    var config: Config = .{};
    config.apply(.user,
        \\theme = "light"
        \\[history]
        \\enabled = false
        \\max_entries = 250
        \\
    );
    try testing.expectEqualStrings("light", config.theme.value);
    try testing.expectEqual(false, config.history_enabled.value);
    try testing.expectEqual(@as(u32, 250), config.history_max_entries.value);
    try testing.expectEqual(@as(usize, 0), config.notes().len);
}

test "keymap entries accumulate across layers with their provenance" {
    var config: Config = .{};
    config.apply(.user, "[keys]\n\"ctrl+j\" = \"newline\"\n");
    config.apply(.project, "[keys]\n\"ctrl+j\" = \"submit\"\n\"f5\" = \"clear_screen\"\n");

    const entries = config.bindings();
    try testing.expectEqual(@as(usize, 3), entries.len);

    try testing.expectEqualStrings("ctrl+j", entries[0].chord);
    try testing.expectEqualStrings("newline", entries[0].action);
    try testing.expectEqual(Layer.user, entries[0].layer);
    try testing.expectEqual(@as(u32, 2), entries[0].at.line);

    // The project layer's ctrl+j is kept rather than overwriting the user's:
    // Phase 8 needs both to name both sides of the conflict.
    try testing.expectEqualStrings("ctrl+j", entries[1].chord);
    try testing.expectEqual(Layer.project, entries[1].layer);
    try testing.expectEqualStrings("f5", entries[2].chord);
}

test "the environment layer sets scalars by their dotted name" {
    var config: Config = .{};
    config.setScalar(.env, "theme", "light");
    config.setScalar(.env, "history.max_entries", "12");
    config.setScalar(.env, "history.enabled", "false");

    try testing.expectEqualStrings("light", config.theme.value);
    try testing.expectEqual(Layer.env, config.theme.source);
    try testing.expectEqual(@as(u32, 12), config.history_max_entries.value);
    try testing.expectEqual(false, config.history_enabled.value);
}

test "the environment table names one variable per scalar key" {
    // Every entry must name a key `setScalar` accepts, or the mapping is a
    // variable nobody can set. This is the check that keeps the two in step.
    for (env_keys) |entry| {
        try testing.expect(std.mem.startsWith(u8, entry.variable, "TUG_"));
        var config: Config = .{};
        config.setScalar(.env, entry.key, "1");
        // "1" is a valid integer and a valid bool and an odd theme name, so
        // assert only that the key was recognised.
        for (config.notes()) |note| {
            try testing.expect(note.kind != .unknown_key);
        }
    }
}

test "a flag beats the environment" {
    var config: Config = .{};
    config.setScalar(.env, "theme", "light");
    config.setScalar(.flag, "theme", "mono");
    try testing.expectEqualStrings("mono", config.theme.value);
    try testing.expectEqual(Layer.flag, config.theme.source);
}

test "a bad value warns and keeps what was there" {
    var config: Config = .{};
    config.apply(.user, "[history]\nmax_entries = \"lots\"\n");

    try testing.expectEqual(@as(u32, 1000), config.history_max_entries.value);
    try testing.expectEqual(Layer.default, config.history_max_entries.source);
    try testing.expectEqual(@as(usize, 1), config.notes().len);
    try testing.expectEqual(Note.Kind.wrong_type, config.notes()[0].kind);
    try testing.expectEqual(Layer.user, config.notes()[0].layer);
    try testing.expectEqual(@as(u32, 2), config.notes()[0].at.line);
    try testing.expectEqualStrings("max_entries", config.notes()[0].text);
}

test "an out-of-range integer is a wrong type, not a wrapped one" {
    var config: Config = .{};
    config.apply(.user, "[history]\nmax_entries = -1\n");
    try testing.expectEqual(@as(u32, 1000), config.history_max_entries.value);
    try testing.expectEqual(Note.Kind.wrong_type, config.notes()[0].kind);
}

test "unknown keys and tables warn, are ignored, and do not stop the file" {
    var config: Config = .{};
    config.apply(.project,
        \\colour = "purple"
        \\[historie]
        \\enabled = false
        \\[history]
        \\enabled = false
        \\
    );
    try testing.expectEqual(false, config.history_enabled.value);

    const found = config.notes();
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqual(Note.Kind.unknown_key, found[0].kind);
    try testing.expectEqualStrings("colour", found[0].text);
    try testing.expectEqual(Note.Kind.unknown_table, found[1].kind);
    try testing.expectEqualStrings("historie", found[1].text);
}

test "a key set twice in one layer warns once and the last one wins" {
    var config: Config = .{};
    config.apply(.user, "theme = \"a\"\ntheme = \"b\"\n");
    try testing.expectEqualStrings("b", config.theme.value);
    try testing.expectEqual(@as(usize, 1), config.notes().len);
    try testing.expectEqual(Note.Kind.duplicate_key, config.notes()[0].kind);

    // The same key in a *different* layer is layering, not duplication.
    config.apply(.project, "theme = \"c\"\n");
    try testing.expectEqual(@as(usize, 1), config.notes().len);
}

test "a syntax problem becomes a note carrying the scanner's position" {
    var config: Config = .{};
    config.apply(.user, "theme = \"dark\ntheme = \"light\"\n");
    try testing.expectEqual(Note.Kind.unterminated_string, config.notes()[0].kind);
    try testing.expectEqual(@as(u32, 1), config.notes()[0].at.line);
    try testing.expectEqual(@as(u32, 9), config.notes()[0].at.column);
}

test "every note kind has a message" {
    // A note whose message is empty is a warning that says nothing, which is
    // worse than no warning at all because it costs a line of the screen.
    inline for (@typeInfo(Note.Kind).@"enum".fields) |field| {
        const kind: Note.Kind = @enumFromInt(field.value);
        try testing.expect(Note.message(kind).len > 0);
    }
}

test "the caps hold and say so rather than dropping quietly" {
    var config: Config = .{};

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(testing.allocator);
    try buffer.appendSlice(testing.allocator, "[keys]\n");

    var index: usize = 0;
    while (index < max_bindings + 8) : (index += 1) {
        var line: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "\"f{d}\" = \"submit\"\n", .{index});
        try buffer.appendSlice(testing.allocator, text);
    }
    config.apply(.user, buffer.items);

    try testing.expectEqual(@as(usize, max_bindings), config.bindings().len);
    var saw_overflow = false;
    for (config.notes()) |entry| {
        if (entry.kind == .too_many_bindings) saw_overflow = true;
    }
    try testing.expect(saw_overflow);
}

// The `/config` screen, in the layering Phase 10 will render. This expectation
// is this phase's "provenance golden": a byte-exact record of a resolved config
// and where every value came from. It is inline rather than a file under
// `testdata/golden/` because the golden helper lives in `tugshell` and this
// module may not import it — see the plan's Task 3 for the whole argument.
test "the resolved report names every value's layer" {
    var config: Config = .{};
    config.apply(.user,
        \\theme = "light"
        \\[history]
        \\max_entries = 250
        \\
    );
    config.apply(.project, "[keys]\n\"ctrl+j\" = \"newline\"\n");
    config.setScalar(.env, "history.enabled", "false");

    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try config.write(&writer);

    try testing.expectEqualStrings(
        \\setting              value                from
        \\theme                light                user
        \\history.enabled      false                env
        \\history.max_entries  250                  user
        \\provider.preset                           default
        \\provider.model                            default
        \\provider.key         <unset>              default
        \\provider.key_cmd                          default
        \\provider.timeout_ms  60000                default
        \\provider.insecure    false                default
        \\keys."ctrl+j"        newline              project
        \\
    , writer.buffered());
}

test "the resolved report never prints the key" {
    // `/config` is the surface most likely to be pasted into an issue. The
    // canary is planted through the config layer here rather than through an
    // auth path, because this is the output surface, and a redaction that only
    // holds for one input is not a redaction.
    var config: Config = .{};
    config.apply(.user, "[provider]\nkey = \"sk-tug-canary-0000000000000000000000000000\"\n");
    try testing.expectEqualStrings("sk-tug-canary-0000000000000000000000000000", config.provider_key.value);

    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try config.write(&writer);

    const printed = writer.buffered();
    try testing.expect(std.mem.indexOf(u8, printed, "sk-tug-canary") == null);
    // And it still says that a key is set, and which layer set it — an absence
    // that cannot be distinguished from a misconfiguration is not a redaction,
    // it is a missing feature.
    try testing.expect(std.mem.indexOf(u8, printed, "provider.key         <set>") != null);
    try testing.expect(std.mem.indexOf(u8, printed, "user") != null);
}

test "a key_cmd is printed, because it is not the secret" {
    // Hiding the instruction for fetching a key would make a misconfigured
    // key_cmd undiagnosable, and the command line is not the thing worth hiding.
    var config: Config = .{};
    config.apply(.user, "[provider]\nkey_cmd = \"pass show anthropic\"\n");

    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try config.write(&writer);

    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "pass show anthropic") != null);
}

test "an untouched config reports every default as a default" {
    const config: Config = .{};
    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try config.write(&writer);

    try testing.expectEqualStrings(
        \\setting              value                from
        \\theme                dark                 default
        \\history.enabled      true                 default
        \\history.max_entries  1000                 default
        \\provider.preset                           default
        \\provider.model                            default
        \\provider.key         <unset>              default
        \\provider.key_cmd                          default
        \\provider.timeout_ms  60000                default
        \\provider.insecure    false                default
        \\
    , writer.buffered());
}

test "a value too wide for its column pushes the next one instead of being cut" {
    var config: Config = .{};
    config.apply(.user, "theme = \"a-theme-name-that-is-far-too-long-for-the-column\"\n");

    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try config.write(&writer);

    // The column is a minimum, not a maximum. A truncated value in the one
    // screen that exists to tell you what your value is would be a bug with a
    // tidy left edge.
    try testing.expectEqualStrings(
        \\setting              value                from
        \\theme                a-theme-name-that-is-far-too-long-for-the-column user
        \\history.enabled      true                 default
        \\history.max_entries  1000                 default
        \\provider.preset                           default
        \\provider.model                            default
        \\provider.key         <unset>              default
        \\provider.key_cmd                          default
        \\provider.timeout_ms  60000                default
        \\provider.insecure    false                default
        \\
    , writer.buffered());
}

// The malformed corpus. Each case is a whole file, and the assertion is on the
// notes it produces *and* on the settings that survived it — because "warn,
// ignore, continue" is three claims and the third is the one that matters.
test "the malformed corpus warns, ignores, and continues" {
    const cases = [_]struct {
        name: []const u8,
        source: []const u8,
        want: []const Note.Kind,
        /// What `theme` must be afterwards. The default proves nothing landed;
        /// a value proves the file kept going past the damage.
        theme: []const u8,
    }{
        .{
            .name = "garbage bytes",
            .source = "\x00\x01\xff\xfe binary nonsense \x7f\n",
            // One line of rubbish is one problem: a key made of bytes that are
            // not key bytes, so there is no key.
            .want = &.{.expected_key},
            .theme = default_theme,
        },
        .{
            .name = "an empty file",
            .source = "",
            .want = &.{},
            .theme = default_theme,
        },
        .{
            .name = "only comments and blank lines",
            .source = "# nothing here\n\n   \n# nor here\n",
            .want = &.{},
            .theme = default_theme,
        },
        .{
            .name = "wrong types on every scalar",
            .source =
            \\theme = 12
            \\[history]
            \\enabled = "no"
            \\max_entries = true
            \\
            ,
            .want = &.{ .wrong_type, .wrong_type, .wrong_type },
            .theme = default_theme,
        },
        .{
            .name = "unknown keys around a good one",
            .source =
            \\colour = "purple"
            \\theme = "light"
            \\fontsize = 12
            \\
            ,
            .want = &.{ .unknown_key, .unknown_key },
            .theme = "light",
        },
        .{
            .name = "an unclosed string does not swallow the rest of the file",
            .source =
            \\name = "unclosed
            \\theme = "light"
            \\
            ,
            .want = &.{.unterminated_string},
            .theme = "light",
        },
        .{
            .name = "TOML this subset refuses, one of each",
            .source =
            \\hosts = ["a", "b"]
            \\point = { x = 1 }
            \\a.b = 1
            \\escaped = "one\ttwo"
            \\theme = "light"
            \\
            ,
            .want = &.{
                .array_unsupported,
                .inline_table_unsupported,
                .dotted_key_unsupported,
                .escape_unsupported,
            },
            .theme = "light",
        },
        .{
            .name = "duplicate keys in one file",
            .source = "theme = \"a\"\ntheme = \"light\"\n",
            .want = &.{.duplicate_key},
            .theme = "light",
        },
        .{
            .name = "a section header that is not a section",
            .source = "[[servers]]\nname = \"x\"\ntheme = \"light\"\n",
            // The `[[` is refused, so `name` is still at the top level, where
            // there is no such key.
            .want = &.{ .array_of_tables_unsupported, .unknown_key },
            .theme = "light",
        },
    };

    for (cases) |case| {
        var config: Config = .{};
        config.apply(.user, case.source);

        testing.expectEqual(case.want.len, config.notes().len) catch |err| {
            std.debug.print("\ncorpus case: {s}\n", .{case.name});
            for (config.notes()) |got| std.debug.print("  {t}\n", .{got.kind});
            return err;
        };
        for (case.want, config.notes()) |want, got| {
            testing.expectEqual(want, got.kind) catch |err| {
                std.debug.print("\ncorpus case: {s}\n", .{case.name});
                return err;
            };
        }
        try testing.expectEqualStrings(case.theme, config.theme.value);
    }
}

test "notes render with the file they came from" {
    var config: Config = .{};
    config.apply(.project, "colour = \"purple\"\n");
    config.setScalar(.env, "history.enabled", "maybe");

    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try config.writeNotes(&writer, .{
        "<defaults>",
        "/home/x/.config/tug/config.toml",
        ".tug/config.toml",
        "<environment>",
        "<flags>",
    });

    try testing.expectEqualStrings(
        \\.tug/config.toml:1:1: warning: no such setting ('colour')
        \\<environment>:0:0: warning: the value is not the type this setting takes ('history.enabled')
        \\
    , writer.buffered());
}
