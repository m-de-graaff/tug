//! Named actions, and the default table a chord is resolved against.
//!
//! This file is the seam Phase 8 rebound. Nothing above it may look at a
//! `KeyEvent` and decide what to do: `input/keymap.zig` resolves this table and
//! every config layer into one live `Keymap`, the session asks that for a name,
//! and then dispatches on the name. The mechanical check is that `repl.zig`
//! contains no `key.eql` and no `.mods.ctrl` — if it does, the indirection is
//! decorative and vi mode will cost a rewrite instead of a table.
//!
//! Two actions carry a fallback rather than a fixed chord, and `DR-003` is why:
//! `shift+enter` does not exist in the legacy terminal encoding, so `newline`
//! is bound to `alt+enter` where the kitty protocol is unavailable. The
//! `Availability` field is what lets `/keys` say which one is live in Phase 10
//! rather than leaving the user to discover it by watching a half-written
//! message send itself.
//!
//! `applyEdit` performs every action that only touches the draft and *returns*
//! every action that needs the session — the history, the screen, the process.
//! That split is what lets the goldens in `golden.zig` drive the whole binding
//! set without a terminal, a history file or a provider.

const std = @import("std");

const editor_mod = @import("editor.zig");
const key_mod = @import("../input/key.zig");

const Editor = editor_mod.Editor;
const Key = key_mod.Key;
const KeyEvent = key_mod.KeyEvent;
const Mods = key_mod.Mods;

pub const Action = enum {
    submit,
    newline,
    interrupt,
    /// Leave, unconditionally. `end_of_input` is the graded version — quit on
    /// an empty draft, delete forward otherwise — and this is the one somebody
    /// binds to a function key when they want a door rather than a habit.
    quit,
    end_of_input,
    clear_screen,
    /// Finish the command name at the head of the draft. Named rather than
    /// wired to a key inside the editor because the editor cannot see the
    /// command table, and because a person who wants completion on a different
    /// chord should get it from a config file like everything else.
    complete,
    move_left,
    move_right,
    move_word_left,
    move_word_right,
    move_line_start,
    move_line_end,
    move_up,
    move_down,
    delete_back,
    delete_forward,
    kill_word_back,
    kill_to_line_start,
    kill_to_line_end,
    yank,
    history_prev,
    history_next,
};

/// When a binding is live. `kitty` and `legacy` are the two halves of the
/// `DR-003` fallback and are mutually exclusive by construction.
pub const Availability = enum { always, kitty, legacy };

pub const Binding = struct {
    chord: KeyEvent,
    action: Action,
    when: Availability = .always,
};

/// The default keymap — the seed `keymap.Keymap.defaults` reads and a config
/// file layers over. A table rather than a switch precisely so that resolver
/// and `/keys` can both consume it without it having to be rewritten first.
pub const bindings: []const Binding = &.{
    .{ .chord = .{ .key = .enter }, .action = .submit },
    .{ .chord = .{ .key = .enter, .mods = .{ .shift = true } }, .action = .newline, .when = .kitty },
    .{ .chord = .{ .key = .enter, .mods = .{ .alt = true } }, .action = .newline, .when = .legacy },

    .{ .chord = .{ .key = .{ .char = 'c' }, .mods = .{ .ctrl = true } }, .action = .interrupt },
    .{ .chord = .{ .key = .{ .char = 'd' }, .mods = .{ .ctrl = true } }, .action = .end_of_input },
    .{ .chord = .{ .key = .{ .char = 'l' }, .mods = .{ .ctrl = true } }, .action = .clear_screen },
    .{ .chord = .{ .key = .tab }, .action = .complete },

    .{ .chord = .{ .key = .left }, .action = .move_left },
    .{ .chord = .{ .key = .right }, .action = .move_right },
    .{ .chord = .{ .key = .{ .char = 'b' }, .mods = .{ .ctrl = true } }, .action = .move_left },
    .{ .chord = .{ .key = .{ .char = 'f' }, .mods = .{ .ctrl = true } }, .action = .move_right },
    .{ .chord = .{ .key = .{ .char = 'b' }, .mods = .{ .alt = true } }, .action = .move_word_left },
    .{ .chord = .{ .key = .{ .char = 'f' }, .mods = .{ .alt = true } }, .action = .move_word_right },
    .{ .chord = .{ .key = .{ .char = 'a' }, .mods = .{ .ctrl = true } }, .action = .move_line_start },
    .{ .chord = .{ .key = .{ .char = 'e' }, .mods = .{ .ctrl = true } }, .action = .move_line_end },
    .{ .chord = .{ .key = .home }, .action = .move_line_start },
    .{ .chord = .{ .key = .end }, .action = .move_line_end },
    .{ .chord = .{ .key = .up }, .action = .move_up },
    .{ .chord = .{ .key = .down }, .action = .move_down },

    .{ .chord = .{ .key = .backspace }, .action = .delete_back },
    .{ .chord = .{ .key = .backspace, .mods = .{ .ctrl = true } }, .action = .delete_back },
    .{ .chord = .{ .key = .delete }, .action = .delete_forward },
    .{ .chord = .{ .key = .{ .char = 'w' }, .mods = .{ .ctrl = true } }, .action = .kill_word_back },
    .{ .chord = .{ .key = .{ .char = 'u' }, .mods = .{ .ctrl = true } }, .action = .kill_to_line_start },
    .{ .chord = .{ .key = .{ .char = 'k' }, .mods = .{ .ctrl = true } }, .action = .kill_to_line_end },
    .{ .chord = .{ .key = .{ .char = 'y' }, .mods = .{ .ctrl = true } }, .action = .yank },
};

/// What `applyEdit` could not do on its own.
///
/// Everything that touches only the draft is `handled`. Everything that needs
/// the history, the screen or the process comes back by name for the session to
/// deal with.
pub const Outcome = enum {
    handled,
    submit,
    interrupt,
    quit,
    end_of_input,
    clear_screen,
    complete,
    history_prev,
    history_next,
};

/// Runs one action against the draft.
///
/// `move_up` and `move_down` fall through to history navigation when the cursor
/// is already on the first or last line — that is the spec's "history when on
/// first/last line", and it lives here rather than in the binding table because
/// the binding table cannot see the cursor. `history_prev` and `history_next`
/// are the *explicit* form and never move a cursor, so Phase 8 can bind them to
/// their own chords and get history navigation unconditionally.
pub fn applyEdit(editor: *Editor, action: Action) std.mem.Allocator.Error!Outcome {
    switch (action) {
        .submit => return .submit,
        .interrupt => return .interrupt,
        .quit => return .quit,
        .end_of_input => return .end_of_input,
        .clear_screen => return .clear_screen,
        .complete => return .complete,
        .history_prev => return .history_prev,
        .history_next => return .history_next,

        .newline => try editor.insert("\n"),
        .move_left => editor.moveLeft(),
        .move_right => editor.moveRight(),
        .move_word_left => editor.moveWordLeft(),
        .move_word_right => editor.moveWordRight(),
        .move_line_start => editor.moveLineStart(),
        .move_line_end => editor.moveLineEnd(),
        .move_up => if (editor.moveUp() == .at_edge) return .history_prev,
        .move_down => if (editor.moveDown() == .at_edge) return .history_next,
        .delete_back => editor.deleteBack(),
        .delete_forward => editor.deleteForward(),
        .kill_word_back => try editor.killWordBack(),
        .kill_to_line_start => try editor.killToLineStart(),
        .kill_to_line_end => try editor.killToLineEnd(),
        .yank => try editor.yank(),
    }
    return .handled;
}

/// The character an *unbound* chord types, if it types one.
///
/// Lives here rather than in the session because it is the same kind of
/// decision as the binding table: what a keypress means. A chord carrying ctrl,
/// alt or super and no binding is a command tug does not have, and inserting
/// its letter would be worse than ignoring it — `ctrl+p` in a shell that has
/// not bound it should do nothing, not type a `p`. Shift is not in that list
/// because shift is how capitals are typed.
pub fn literalCodepoint(event: KeyEvent) ?u21 {
    if (event.mods.ctrl or event.mods.alt or event.mods.super) return null;
    return switch (event.key) {
        .char => |codepoint| codepoint,
        else => null,
    };
}

/// One line per action, for `--help` now and `/keys` in Phase 10.
pub fn help(action: Action) []const u8 {
    return switch (action) {
        .submit => "send the draft",
        .newline => "insert a line break without sending",
        .interrupt => "clear the draft, or stop a running response",
        .quit => "leave tug",
        .end_of_input => "delete forward, or quit on an empty draft",
        .clear_screen => "clear the screen and repaint",
        .complete => "complete the command name at the start of the draft",
        .move_left => "move back one character",
        .move_right => "move forward one character",
        .move_word_left => "move back one word",
        .move_word_right => "move forward one word",
        .move_line_start => "move to the start of the line",
        .move_line_end => "move to the end of the line",
        .move_up => "move up a line, or recall the previous entry",
        .move_down => "move down a line, or recall the next entry",
        .delete_back => "delete the character behind the cursor",
        .delete_forward => "delete the character under the cursor",
        .kill_word_back => "cut the word behind the cursor",
        .kill_to_line_start => "cut to the start of the line",
        .kill_to_line_end => "cut to the end of the line",
        .yank => "paste the last cut",
        .history_prev => "recall the previous entry",
        .history_next => "recall the next entry",
    };
}

/// What `/keys` groups by.
///
/// Four groups, because four is what fits on a screen without a scrollbar and
/// because the fifth would be a judgement call rather than a fact: `yank` is
/// editing, `history_prev` is history, and nothing in the list is ambiguous
/// between them.
pub const Category = enum { session, movement, editing, history };

/// `move_up` and `move_down` are movement even though they fall through to
/// history at the edges of the draft, because the chord is a cursor key and
/// that is what somebody reading the list is looking for. Their help strings
/// already say both things.
pub fn category(action: Action) Category {
    return switch (action) {
        .submit, .interrupt, .quit, .end_of_input, .clear_screen => .session,

        .move_left,
        .move_right,
        .move_word_left,
        .move_word_right,
        .move_line_start,
        .move_line_end,
        .move_up,
        .move_down,
        => .movement,

        .newline,
        .complete,
        .delete_back,
        .delete_forward,
        .kill_word_back,
        .kill_to_line_start,
        .kill_to_line_end,
        .yank,
        => .editing,

        .history_prev, .history_next => .history,
    };
}

const testing = std.testing;

test "an unbound chord types its character only when it carries no command modifier" {
    try testing.expectEqual(@as(?u21, 'a'), literalCodepoint(.{ .key = .{ .char = 'a' } }));
    // Shift is how a capital is typed, so it is not a command modifier.
    try testing.expectEqual(
        @as(?u21, 'A'),
        literalCodepoint(.{ .key = .{ .char = 'A' }, .mods = .{ .shift = true } }),
    );
    try testing.expectEqual(
        @as(?u21, null),
        literalCodepoint(.{ .key = .{ .char = 'p' }, .mods = .{ .ctrl = true } }),
    );
    try testing.expectEqual(
        @as(?u21, null),
        literalCodepoint(.{ .key = .{ .char = 'p' }, .mods = .{ .alt = true } }),
    );
    try testing.expectEqual(
        @as(?u21, null),
        literalCodepoint(.{ .key = .{ .char = 'p' }, .mods = .{ .super = true } }),
    );
    // A named key is not a character however it arrives.
    try testing.expectEqual(@as(?u21, null), literalCodepoint(.{ .key = .tab }));
    try testing.expectEqual(@as(?u21, null), literalCodepoint(.{ .key = .{ .f = 5 } }));
}

test "every action has a help string" {
    // A help string that is empty is a line of `/keys` that says nothing, which
    // costs a row of the screen to communicate less than blank space would.
    //
    // The table's own self-consistency — every chord resolving back to its own
    // action under the availability it claims — moved to `input/keymap.zig`
    // when `defaultAction` was deleted, because the resolved keymap is what
    // dispatch actually asks.
    inline for (@typeInfo(Action).@"enum".fields) |field| {
        const action: Action = @enumFromInt(field.value);
        try testing.expect(help(action).len > 0);
    }
}

test "edits are applied and session actions are handed back" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();

    try editor.insert("alpha beta");
    try testing.expectEqual(Outcome.handled, try applyEdit(&editor, .kill_word_back));
    try testing.expectEqualStrings("alpha ", editor.items());

    try testing.expectEqual(Outcome.handled, try applyEdit(&editor, .newline));
    try testing.expectEqualStrings("alpha \n", editor.items());

    try testing.expectEqual(Outcome.submit, try applyEdit(&editor, .submit));
    // Submitting does not clear the draft: the session does that, after it has
    // read the text and written it to history.
    try testing.expectEqualStrings("alpha \n", editor.items());

    try testing.expectEqual(Outcome.clear_screen, try applyEdit(&editor, .clear_screen));
    try testing.expectEqual(Outcome.interrupt, try applyEdit(&editor, .interrupt));
    try testing.expectEqual(Outcome.end_of_input, try applyEdit(&editor, .end_of_input));
}

test "up and down fall through to history at the edges of the draft" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();

    // Single-line draft: both edges are immediate.
    try editor.insert("one line");
    try testing.expectEqual(Outcome.history_prev, try applyEdit(&editor, .move_up));
    try testing.expectEqual(Outcome.history_next, try applyEdit(&editor, .move_down));

    // Multiline: the middle moves, the edges fall through.
    try editor.setText("first\nsecond");
    try testing.expectEqual(Outcome.handled, try applyEdit(&editor, .move_up));
    try testing.expectEqual(Outcome.history_prev, try applyEdit(&editor, .move_up));
    try testing.expectEqual(Outcome.handled, try applyEdit(&editor, .move_down));
    try testing.expectEqual(Outcome.history_next, try applyEdit(&editor, .move_down));
}

test "quit is an action, and it does not touch the draft" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();

    try editor.insert("half a message");
    try testing.expectEqual(Outcome.quit, try applyEdit(&editor, .quit));
    // Leaving is not clearing. The session decides what to do with the draft;
    // the action layer does not throw it away on the way out.
    try testing.expectEqualStrings("half a message", editor.items());
}

test "every action has a category" {
    // A category is what `/keys` groups by. An action that has none would be
    // an action that cannot appear on the screen listing the actions.
    inline for (@typeInfo(Action).@"enum".fields) |field| {
        const action: Action = @enumFromInt(field.value);
        _ = category(action);
    }
    try testing.expectEqual(Category.session, category(.quit));
    try testing.expectEqual(Category.session, category(.submit));
    try testing.expectEqual(Category.movement, category(.move_word_left));
    try testing.expectEqual(Category.editing, category(.kill_to_line_end));
    try testing.expectEqual(Category.history, category(.history_prev));
}

test "an explicit history action never moves the cursor" {
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();

    try editor.setText("first\nsecond");
    editor.setCursor(0);
    try testing.expectEqual(Outcome.history_prev, try applyEdit(&editor, .history_prev));
    try testing.expectEqual(@as(usize, 0), editor.cursor);
    try testing.expectEqual(Outcome.history_next, try applyEdit(&editor, .history_next));
    try testing.expectEqual(@as(usize, 0), editor.cursor);
}

test "tab is bound to complete, and complete is the editor's business to hand back" {
    // The binding table is the registry, so the assertion is about the table
    // rather than about a switch somewhere downstream.
    var found = false;
    for (bindings) |binding| {
        if (binding.action != .complete) continue;
        try testing.expectEqual(Key.tab, binding.chord.key);
        try testing.expectEqual(Mods{}, binding.chord.mods);
        try testing.expectEqual(Availability.always, binding.when);
        found = true;
    }
    try testing.expect(found);

    // `complete` needs the command table, which the editor cannot see, so it
    // comes back by name the way `submit` and `clear_screen` do.
    var editor: Editor = .init(testing.allocator);
    defer editor.deinit();
    try editor.insert("/hel");
    try testing.expectEqual(Outcome.complete, try applyEdit(&editor, .complete));
    // And it did not touch the draft on the way out.
    try testing.expectEqualStrings("/hel", editor.items());
}

test "every action has a help line and a category" {
    // The two tables `--help` and `/keys` read. An action missing from either
    // is an action that is invisible on the screen that exists to list it.
    inline for (@typeInfo(Action).@"enum".fields) |field| {
        const action: Action = @enumFromInt(field.value);
        try testing.expect(help(action).len > 0);
        _ = category(action);
    }
}
