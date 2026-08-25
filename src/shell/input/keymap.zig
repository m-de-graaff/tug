//! One live keymap, resolved from the default table and every config layer.
//!
//! Phase 6 built the seam — a table of chords, an `Action` enum, and a session
//! that switches on the name. Phase 7 built the layer that feeds it:
//! `Config.bindings()`, deliberately *collected* rather than merged, so every
//! layer's entries arrive with the layer and the line still attached. This file
//! is the only thing between them, and it has four rules:
//!
//! 1. A config chord that lands on a **default** replaces it, silently.
//!    Overriding a default is the feature; a warning here would fire for
//!    everyone who customised anything, and a warning everyone learns to ignore
//!    hides the real one.
//! 2. A config chord that lands on **another config chord** is a conflict. The
//!    warning names both actions and both layers; the later entry wins, and
//!    since `Config.bindings()` is in layer order, later means higher.
//! 3. An unparseable chord is a warning quoting the string. Nothing binds.
//! 4. An unresolvable action name is a warning quoting the string, with the
//!    nearest real action when one is close enough.
//!
//! **Its warnings are not `config.Note`s**, and `DR-013` is the argument. The
//! short version: `tugcore` has no `KeyEvent` and cannot acquire one — it
//! compiles for `wasm32-freestanding` — so a note kind only `tugshell` can
//! produce is a kind in the wrong module; and a conflict has to name two
//! actions and two layers where `Note` has one of each.
//!
//! **No allocator and no error set**, for the reason Phase 7 stated and this
//! phase exists to honour: a typo in a keybind must never brick the shell. A
//! config file made entirely of nonsense yields the default keymap and a screen
//! of warnings.

const std = @import("std");
const testing = std.testing;

const core = @import("tugcore");

const actions = @import("../edit/actions.zig");
const key_mod = @import("key.zig");

const Action = actions.Action;
const Availability = actions.Availability;
const KeyEvent = key_mod.KeyEvent;
const Layer = core.config.Layer;
const Position = core.toml.Position;

/// ponytail: 160 live bindings — 24 defaults plus the config stack's own 128,
/// with headroom. Both caps are fixed for the same reason: a growable table
/// needs an allocator, an allocator needs a failure path, and the failure path
/// in a keymap loader is the code nobody tests. Overflow is a warning, never a
/// silent drop.
pub const max_entries: usize = 160;

/// ponytail: 16 keymap warnings. Past that the `[keys]` table is not a keymap
/// with a typo in it, and the config's own note cap (32) will have spoken too.
pub const max_problems: usize = 16;

/// Every action name a config file may write, which is every tag name. Built at
/// comptime from the enum so it cannot drift from it.
pub const action_names: []const []const u8 = names: {
    const fields = @typeInfo(Action).@"enum".fields;
    var list: [fields.len][]const u8 = undefined;
    for (fields, 0..) |field, index| list[index] = field.name;
    const frozen = list;
    break :names &frozen;
};

/// One live binding.
pub const Entry = struct {
    chord: KeyEvent,
    action: Action,
    /// Only meaningful for defaults, and only so `write` can annotate the row
    /// that exists because of `DR-003`. A config binding is always `.always`.
    when: Availability = .always,
    /// The layer that bound it, or null when it is a default.
    layer: ?Layer = null,
    at: Position = .{ .line = 0, .column = 0 },
};

/// One thing wrong with the `[keys]` table.
pub const Problem = struct {
    kind: Kind,
    /// The layer of the entry the problem is about — the *winner*, for a
    /// conflict.
    layer: Layer,
    at: Position,
    /// The chord or action name, quoted in the message. Borrows the config
    /// source, which the caller owns.
    text: []const u8,
    /// The nearest real action name, or "" when nothing was close.
    suggestion: []const u8 = "",
    /// The action the winning entry binds. Only set for `chord_conflict`.
    winner: ?Action = null,
    /// What that conflict displaced.
    shadowed: ?struct { action: Action, layer: Layer } = null,

    pub const Kind = enum {
        bad_chord,
        unknown_action,
        chord_conflict,
        too_many_bindings,
    };

    /// One line, in the shape `config.Note.write` uses, so a screen printing
    /// both reads as one list rather than as two.
    ///
    /// The conflict message is built here rather than from a `message(kind)`
    /// table because it interpolates four values. The other three have nothing
    /// to interpolate but the quoted text.
    pub fn write(
        self: Problem,
        out: *std.Io.Writer,
        origin: []const u8,
    ) std.Io.Writer.Error!void {
        try out.print("{s}:{d}:{d}: warning: ", .{ origin, self.at.line, self.at.column });

        switch (self.kind) {
            .bad_chord => try out.print("not a key chord ('{s}')", .{self.text}),
            .unknown_action => {
                try out.print("no such action ('{s}')", .{self.text});
                if (self.suggestion.len > 0) {
                    try out.print("; did you mean '{s}'?", .{self.suggestion});
                }
            },
            .chord_conflict => {
                const lost = self.shadowed.?;
                try out.print(
                    "'{s}' is bound to {t} here and to {t} in the {t} layer; the last one wins",
                    .{ self.text, self.winner.?, lost.action, lost.layer },
                );
            },
            .too_many_bindings => try out.print(
                "too many key bindings; the rest were ignored ('{s}')",
                .{self.text},
            ),
        }
        try out.writeAll("\n");
    }
};

pub const Keymap = struct {
    entry_storage: [max_entries]Entry = undefined,
    entry_count: usize = 0,

    problem_storage: [max_problems]Problem = undefined,
    problem_count: usize = 0,

    pub fn entries(self: *const Keymap) []const Entry {
        return self.entry_storage[0..self.entry_count];
    }

    pub fn problems(self: *const Keymap) []const Problem {
        return self.problem_storage[0..self.problem_count];
    }

    /// The Phase 6 table, with only the rows live under this protocol.
    ///
    /// `DR-003`: `shift+enter` does not exist in the legacy encoding, so the
    /// dead half of that pair is never seeded. A config file that binds it
    /// anyway gets an entry that cannot fire and no warning — the file is not
    /// wrong, the terminal is.
    pub fn defaults(kitty: bool) Keymap {
        var self: Keymap = .{};
        for (actions.bindings) |binding| {
            const live = switch (binding.when) {
                .always => true,
                .kitty => kitty,
                .legacy => !kitty,
            };
            if (!live) continue;
            self.append(.{
                .chord = binding.chord,
                .action = binding.action,
                .when = binding.when,
            }, "");
        }
        return self;
    }

    /// The defaults, with every config layer applied over them in order.
    pub fn build(config: *const core.config.Config, kitty: bool) Keymap {
        var self: Keymap = .defaults(kitty);

        for (config.bindings()) |binding| {
            const chord = key_mod.parseChord(binding.chord) orelse {
                self.problem(.{
                    .kind = .bad_chord,
                    .layer = binding.layer,
                    .at = binding.at,
                    .text = binding.chord,
                });
                continue;
            };

            const action = std.meta.stringToEnum(Action, binding.action) orelse {
                self.problem(.{
                    .kind = .unknown_action,
                    .layer = binding.layer,
                    .at = binding.at,
                    .text = binding.action,
                    .suggestion = core.nearest.nearest(action_names, binding.action) orelse "",
                });
                continue;
            };

            const entry: Entry = .{
                .chord = chord,
                .action = action,
                .layer = binding.layer,
                .at = binding.at,
            };

            if (self.find(chord)) |index| {
                const existing = self.entry_storage[index];
                // Rule 1 and rule 2, and the whole difference between them is
                // whether the thing being displaced came from a file.
                if (existing.layer) |lost_layer| {
                    self.problem(.{
                        .kind = .chord_conflict,
                        .layer = binding.layer,
                        .at = binding.at,
                        .text = binding.chord,
                        .winner = action,
                        .shadowed = .{ .action = existing.action, .layer = lost_layer },
                    });
                }
                self.entry_storage[index] = entry;
                continue;
            }

            self.append(entry, binding.chord);
        }

        return self;
    }

    /// The action a chord means, or null when it means nothing.
    ///
    /// ponytail: a linear scan of at most 160 rows, once per keypress. A map
    /// would need an allocator and a hash of a tagged union to save something
    /// nobody can perceive. If a keymap ever grows enough for this to matter,
    /// what arrived is per-mode maps, and they need a different structure
    /// anyway.
    pub fn lookup(self: *const Keymap, event: KeyEvent) ?Action {
        for (self.entries()) |entry| {
            if (entry.chord.eql(event)) return entry.action;
        }
        return null;
    }

    fn find(self: *const Keymap, chord: KeyEvent) ?usize {
        for (self.entries(), 0..) |entry, index| {
            if (entry.chord.eql(chord)) return index;
        }
        return null;
    }

    /// Appends, or records that it could not. `text` names the chord for the
    /// overflow warning and is "" for a default, which cannot overflow.
    fn append(self: *Keymap, entry: Entry, text: []const u8) void {
        if (self.entry_count == max_entries) {
            if (entry.layer) |layer| {
                // Once. A file with three hundred bindings would otherwise
                // spend every warning slot saying the same thing.
                for (self.problems()) |existing| {
                    if (existing.kind == .too_many_bindings) return;
                }
                self.problem(.{
                    .kind = .too_many_bindings,
                    .layer = layer,
                    .at = entry.at,
                    .text = text,
                });
            }
            return;
        }
        self.entry_storage[self.entry_count] = entry;
        self.entry_count += 1;
    }

    fn problem(self: *Keymap, entry: Problem) void {
        if (self.problem_count == max_problems) return;
        self.problem_storage[self.problem_count] = entry;
        self.problem_count += 1;
    }

    // --- the report ---------------------------------------------------------

    /// The columns `Config.write` uses, for the same reason: a screen printing
    /// both should have one left edge.
    const chord_column = 21;
    const action_column = 21;

    fn pad(out: *std.Io.Writer, written: usize, want: usize) std.Io.Writer.Error!void {
        var index = written;
        while (index < want) : (index += 1) try out.writeAll(" ");
        try out.writeAll(" ");
    }

    /// The `/keys` screen: live bindings grouped by category, each annotated
    /// with the layer that set it and — for the one pair `DR-003` created —
    /// with the protocol it depends on.
    ///
    /// Rows keep the order they were resolved in, which is the default table's
    /// order followed by the config's. That is deliberate: a person reading the
    /// screen sees their own bindings at the bottom of the group they belong
    /// to, rather than sorted into a list they have to search.
    pub fn write(self: *const Keymap, out: *std.Io.Writer) std.Io.Writer.Error!void {
        try out.writeAll("chord                action               from\n");

        inline for (@typeInfo(actions.Category).@"enum".fields) |field| {
            const group: actions.Category = @enumFromInt(field.value);
            var printed_header = false;

            for (self.entries()) |entry| {
                if (actions.category(entry.action) != group) continue;
                if (!printed_header) {
                    try out.print("{t}\n", .{group});
                    printed_header = true;
                }
                try writeRow(out, entry);
            }
        }

        try self.writeUnbound(out);
    }

    fn writeRow(out: *std.Io.Writer, entry: Entry) std.Io.Writer.Error!void {
        var chord_buffer: [key_mod.max_chord_bytes]u8 = undefined;
        var chord_writer: std.Io.Writer = .fixed(&chord_buffer);
        entry.chord.writeChord(&chord_writer) catch {};
        const chord = chord_writer.buffered();

        // The row is indented by two, and the column is measured from the left
        // edge the way `Config.write`'s is — hence the `+ 2`.
        try out.writeAll("  ");
        try out.writeAll(chord);
        try pad(out, chord.len + 2, chord_column - 1);

        const name = @tagName(entry.action);
        try out.writeAll(name);
        try pad(out, name.len, action_column - 1);

        if (entry.layer) |layer| {
            try out.print("{t}", .{layer});
        } else {
            try out.writeAll("default");
        }

        switch (entry.when) {
            .always => {},
            .kitty => try out.writeAll(" (kitty keyboard protocol only)"),
            .legacy => try out.writeAll(" (without the kitty keyboard protocol)"),
        }
        try out.writeAll("\n");
    }

    /// The actions no chord reaches.
    ///
    /// Without this the registry is invisible: `quit` ships with no default
    /// binding, and a list of live bindings alone would never mention that it
    /// exists to be bound. One comma-separated line, because it is a short list
    /// and a column for it would be four-fifths whitespace.
    fn writeUnbound(self: *const Keymap, out: *std.Io.Writer) std.Io.Writer.Error!void {
        var any = false;
        inline for (@typeInfo(Action).@"enum".fields) |field| {
            const action: Action = @enumFromInt(field.value);
            var bound = false;
            for (self.entries()) |entry| {
                if (entry.action == action) bound = true;
            }
            if (!bound) {
                if (!any) {
                    try out.writeAll("unbound\n  ");
                    any = true;
                } else {
                    try out.writeAll(", ");
                }
                try out.writeAll(field.name);
            }
        }
        if (any) try out.writeAll("\n");
    }

    /// Every keymap warning, one per line, each naming the file it came from.
    /// `origins` is indexed by layer, exactly as `Config.writeNotes` takes it.
    pub fn writeProblems(
        self: *const Keymap,
        out: *std.Io.Writer,
        origins: [5][]const u8,
    ) std.Io.Writer.Error!void {
        for (self.problems()) |entry| {
            try entry.write(out, origins[@intFromEnum(entry.layer)]);
        }
    }
};

/// The chords the availability rule and the spec's example are about, named
/// once so a test reads as a claim rather than as a struct literal.
const shift_enter: KeyEvent = .{ .key = .enter, .mods = .{ .shift = true } };
const alt_enter: KeyEvent = .{ .key = .enter, .mods = .{ .alt = true } };
const ctrl_j: KeyEvent = .{ .key = .{ .char = 'j' }, .mods = .{ .ctrl = true } };

test "the defaults are the Phase 6 table, and the protocol picks the newline chord" {
    const kitty: Keymap = .defaults(true);
    try testing.expectEqual(Action.submit, kitty.lookup(.{ .key = .enter }).?);
    try testing.expectEqual(Action.newline, kitty.lookup(shift_enter).?);
    try testing.expectEqual(@as(?Action, null), kitty.lookup(alt_enter));

    const legacy: Keymap = .defaults(false);
    try testing.expectEqual(Action.submit, legacy.lookup(.{ .key = .enter }).?);
    try testing.expectEqual(Action.newline, legacy.lookup(alt_enter).?);
    try testing.expectEqual(@as(?Action, null), legacy.lookup(shift_enter));

    // No config, no problems.
    try testing.expectEqual(@as(usize, 0), kitty.problems().len);
}

test "the emacs set is bound exactly as the spec lists it" {
    // Moved here from `actions.zig` when `defaultAction` was deleted: the
    // resolved keymap is what dispatch actually asks, so it is what the
    // assertion should be about.
    const cases = [_]struct { event: KeyEvent, action: Action }{
        .{ .event = .{ .key = .{ .char = 'a' }, .mods = .{ .ctrl = true } }, .action = .move_line_start },
        .{ .event = .{ .key = .{ .char = 'e' }, .mods = .{ .ctrl = true } }, .action = .move_line_end },
        .{ .event = .{ .key = .home }, .action = .move_line_start },
        .{ .event = .{ .key = .end }, .action = .move_line_end },
        .{ .event = .{ .key = .{ .char = 'b' }, .mods = .{ .alt = true } }, .action = .move_word_left },
        .{ .event = .{ .key = .{ .char = 'f' }, .mods = .{ .alt = true } }, .action = .move_word_right },
        .{ .event = .{ .key = .{ .char = 'w' }, .mods = .{ .ctrl = true } }, .action = .kill_word_back },
        .{ .event = .{ .key = .{ .char = 'u' }, .mods = .{ .ctrl = true } }, .action = .kill_to_line_start },
        .{ .event = .{ .key = .{ .char = 'k' }, .mods = .{ .ctrl = true } }, .action = .kill_to_line_end },
        .{ .event = .{ .key = .{ .char = 'y' }, .mods = .{ .ctrl = true } }, .action = .yank },
        .{ .event = .{ .key = .{ .char = 'l' }, .mods = .{ .ctrl = true } }, .action = .clear_screen },
        .{ .event = .{ .key = .{ .char = 'c' }, .mods = .{ .ctrl = true } }, .action = .interrupt },
        .{ .event = .{ .key = .{ .char = 'd' }, .mods = .{ .ctrl = true } }, .action = .end_of_input },
        .{ .event = .{ .key = .up }, .action = .move_up },
        .{ .event = .{ .key = .down }, .action = .move_down },
        .{ .event = .{ .key = .left }, .action = .move_left },
        .{ .event = .{ .key = .right }, .action = .move_right },
        .{ .event = .{ .key = .backspace }, .action = .delete_back },
        .{ .event = .{ .key = .delete }, .action = .delete_forward },
    };
    for ([_]bool{ true, false }) |kitty| {
        const map: Keymap = .defaults(kitty);
        for (cases) |case| {
            try testing.expectEqual(case.action, map.lookup(case.event).?);
        }
    }
}

test "an unbound chord is null rather than a guess" {
    const map: Keymap = .defaults(true);
    try testing.expectEqual(@as(?Action, null), map.lookup(.{ .key = .{ .f = 5 } }));
    try testing.expectEqual(
        @as(?Action, null),
        map.lookup(.{ .key = .{ .char = 'q' }, .mods = .{ .super = true } }),
    );
}

test "a project config binds a chord the defaults left free" {
    // The spec's own example, and the pty check in miniature.
    var config: core.config.Config = .{};
    config.apply(.project, "[keys]\n\"ctrl+j\" = \"newline\"\n");

    const map: Keymap = .build(&config, false);
    try testing.expectEqual(Action.newline, map.lookup(ctrl_j).?);
    // And the fallback it did not replace is still there.
    try testing.expectEqual(Action.newline, map.lookup(alt_enter).?);
    try testing.expectEqual(@as(usize, 0), map.problems().len);
}

test "a config chord that lands on a default replaces it, without a warning" {
    var config: core.config.Config = .{};
    config.apply(.user, "[keys]\n\"ctrl+k\" = \"quit\"\n");

    const map: Keymap = .build(&config, true);
    const ctrl_k: KeyEvent = .{ .key = .{ .char = 'k' }, .mods = .{ .ctrl = true } };
    try testing.expectEqual(Action.quit, map.lookup(ctrl_k).?);

    // Overriding a default is the feature, not a mistake.
    try testing.expectEqual(@as(usize, 0), map.problems().len);

    // And the action it displaced had no other chord, so it is now unbound —
    // which is what the user asked for.
    for (map.entries()) |entry| {
        try testing.expect(entry.action != .kill_to_line_end);
    }
}

test "the same chord in two layers is a conflict naming both, and the later wins" {
    var config: core.config.Config = .{};
    config.apply(.user, "[keys]\n\"f5\" = \"submit\"\n");
    config.apply(.project, "[keys]\n\"f5\" = \"quit\"\n");

    const map: Keymap = .build(&config, true);
    try testing.expectEqual(Action.quit, map.lookup(.{ .key = .{ .f = 5 } }).?);

    try testing.expectEqual(@as(usize, 1), map.problems().len);
    const problem = map.problems()[0];
    try testing.expectEqual(Problem.Kind.chord_conflict, problem.kind);
    try testing.expectEqualStrings("f5", problem.text);
    // The winner's layer and position.
    try testing.expectEqual(core.config.Layer.project, problem.layer);
    try testing.expectEqual(@as(u32, 2), problem.at.line);
    try testing.expectEqual(Action.quit, problem.winner.?);
    // The loser, by action and layer.
    try testing.expectEqual(Action.submit, problem.shadowed.?.action);
    try testing.expectEqual(core.config.Layer.user, problem.shadowed.?.layer);
}

test "the same chord twice in one layer is the same conflict" {
    var config: core.config.Config = .{};
    config.apply(.project, "[keys]\n\"f5\" = \"submit\"\n\"f5\" = \"quit\"\n");

    const map: Keymap = .build(&config, true);
    try testing.expectEqual(Action.quit, map.lookup(.{ .key = .{ .f = 5 } }).?);
    try testing.expectEqual(@as(usize, 1), map.problems().len);
    try testing.expectEqual(Problem.Kind.chord_conflict, map.problems()[0].kind);
    try testing.expectEqual(core.config.Layer.project, map.problems()[0].shadowed.?.layer);
}

test "an unparseable chord is a warning quoting the string, and binds nothing" {
    var config: core.config.Config = .{};
    config.apply(.user, "[keys]\n\"ctrl+nope\" = \"submit\"\n\"ctrl+j\" = \"newline\"\n");

    const map: Keymap = .build(&config, true);
    try testing.expectEqual(@as(usize, 1), map.problems().len);
    try testing.expectEqual(Problem.Kind.bad_chord, map.problems()[0].kind);
    try testing.expectEqualStrings("ctrl+nope", map.problems()[0].text);
    try testing.expectEqual(@as(u32, 2), map.problems()[0].at.line);

    // One bad entry costs one entry: the next line still bound.
    try testing.expectEqual(Action.newline, map.lookup(ctrl_j).?);
}

test "an unknown action name suggests the nearest one" {
    var config: core.config.Config = .{};
    config.apply(.project, "[keys]\n\"ctrl+j\" = \"newlin\"\n\"f5\" = \"frobnicate\"\n");

    const map: Keymap = .build(&config, true);
    try testing.expectEqual(@as(usize, 2), map.problems().len);

    try testing.expectEqual(Problem.Kind.unknown_action, map.problems()[0].kind);
    try testing.expectEqualStrings("newlin", map.problems()[0].text);
    try testing.expectEqualStrings("newline", map.problems()[0].suggestion);

    // Nothing is close to `frobnicate`, so nothing is suggested.
    try testing.expectEqual(Problem.Kind.unknown_action, map.problems()[1].kind);
    try testing.expectEqualStrings("", map.problems()[1].suggestion);

    // Neither bound.
    try testing.expectEqual(@as(?Action, null), map.lookup(ctrl_j));
}

test "every action name a config can write is a name the enum has" {
    // The config's vocabulary is `@tagName`, so it cannot drift — but the check
    // is what says so out loud, and it is what fails if `action_names` is ever
    // hand-written.
    inline for (@typeInfo(Action).@"enum".fields) |field| {
        const action: Action = @enumFromInt(field.value);
        try testing.expectEqual(action, std.meta.stringToEnum(Action, @tagName(action)).?);
    }
    try testing.expectEqual(
        @as(usize, @typeInfo(Action).@"enum".fields.len),
        action_names.len,
    );
}

test "the table holds and says so rather than dropping quietly" {
    var config: core.config.Config = .{};

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(testing.allocator);
    try buffer.appendSlice(testing.allocator, "[keys]\n");

    // Every function key under several modifier combinations, which is more
    // distinct chords than the table has room for once the defaults are in it.
    for ([_][]const u8{ "ctrl+alt+shift+", "ctrl+alt+", "ctrl+shift+", "alt+shift+", "super+" }) |prefix| {
        var index: u6 = 1;
        while (index < 32) : (index += 1) {
            var line: [64]u8 = undefined;
            const text = try std.fmt.bufPrint(
                &line,
                "\"{s}f{d}\" = \"yank\"\n",
                .{ prefix, index },
            );
            try buffer.appendSlice(testing.allocator, text);
        }
    }
    config.apply(.user, buffer.items);

    const map: Keymap = .build(&config, true);
    try testing.expect(map.entries().len <= max_entries);

    // The config layer's own cap (128) is hit before this one, so the assertion
    // is that the pair of them hold together rather than which one spoke.
    var complained = false;
    for (map.problems()) |problem| {
        if (problem.kind == .too_many_bindings) complained = true;
    }
    try testing.expect(complained or config.notes().len > 0);
}

// --- the `/keys` screen -----------------------------------------------------

test "the live keymap prints grouped, annotated, and with its origin" {
    var config: core.config.Config = .{};
    config.apply(.project, "[keys]\n\"ctrl+j\" = \"newline\"\n");

    const map: Keymap = .build(&config, false);

    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try map.write(&writer);

    try testing.expectEqualStrings(
        \\chord                action               from
        \\session
        \\  enter              submit               default
        \\  ctrl+c             interrupt            default
        \\  ctrl+d             end_of_input         default
        \\  ctrl+l             clear_screen         default
        \\movement
        \\  left               move_left            default
        \\  right              move_right           default
        \\  ctrl+b             move_left            default
        \\  ctrl+f             move_right           default
        \\  alt+b              move_word_left       default
        \\  alt+f              move_word_right      default
        \\  ctrl+a             move_line_start      default
        \\  ctrl+e             move_line_end        default
        \\  home               move_line_start      default
        \\  end                move_line_end        default
        \\  up                 move_up              default
        \\  down               move_down            default
        \\editing
        \\  alt+enter          newline              default (without the kitty keyboard protocol)
        \\  tab                complete             default
        \\  backspace          delete_back          default
        \\  ctrl+backspace     delete_back          default
        \\  delete             delete_forward       default
        \\  ctrl+w             kill_word_back       default
        \\  ctrl+u             kill_to_line_start   default
        \\  ctrl+k             kill_to_line_end     default
        \\  ctrl+y             yank                 default
        \\  ctrl+j             newline              project
        \\unbound
        \\  quit, history_prev, history_next
        \\
    , writer.buffered());
}

test "the same scene under the kitty protocol swaps one row" {
    var config: core.config.Config = .{};
    config.apply(.project, "[keys]\n\"ctrl+j\" = \"newline\"\n");

    const map: Keymap = .build(&config, true);

    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try map.write(&writer);

    // The one difference between the tiers, asserted as a difference rather
    // than as a second whole-screen copy that would have to be edited twice.
    try testing.expect(std.mem.indexOf(
        u8,
        writer.buffered(),
        "  shift+enter        newline              default (kitty keyboard protocol only)\n",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "alt+enter") == null);
}

test "the warnings name the file, the layers, and both actions" {
    var config: core.config.Config = .{};
    config.apply(.user, "[keys]\n\"f5\" = \"submit\"\n");
    config.apply(.project,
        \\[keys]
        \\"f5" = "quit"
        \\"ctrl+nope" = "yank"
        \\"ctrl+g" = "newlin"
        \\"ctrl+h" = "frobnicate"
        \\
    );

    const map: Keymap = .build(&config, true);

    var buffer: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try map.writeProblems(&writer, .{
        "<defaults>",
        "/home/x/.config/tug/config.toml",
        ".tug/config.toml",
        "<environment>",
        "<flags>",
    });

    try testing.expectEqualStrings(
        \\.tug/config.toml:2:1: warning: 'f5' is bound to quit here and to submit in the user layer; the last one wins
        \\.tug/config.toml:3:1: warning: not a key chord ('ctrl+nope')
        \\.tug/config.toml:4:1: warning: no such action ('newlin'); did you mean 'newline'?
        \\.tug/config.toml:5:1: warning: no such action ('frobnicate')
        \\
    , writer.buffered());
}

test "a keymap with nothing wrong writes no warnings at all" {
    const map: Keymap = .defaults(true);
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try map.writeProblems(&writer, @splat("<none>"));
    try testing.expectEqualStrings("", writer.buffered());
}
