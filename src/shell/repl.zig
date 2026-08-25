//! The session: a prompt, a turn, and the loop callbacks that join them.
//!
//! Note what this file does *not* do, because it is the claim Phases 3 to 5
//! were making and this is where it gets tested. It never touches the queue. It
//! never asks the provider for anything. It never decides when to paint. It
//! reacts to input, reacts to payloads, and draws — three callbacks hanging off
//! machinery that has no idea an editor exists.
//!
//! It also contains **no `KeyEvent` comparisons**. Every key becomes an
//! `Action` — by way of the `Keymap` the session was handed, which `input/
//! keymap.zig` resolved from the default table and the user's config — and this
//! file switches on the name. That is the indirection Phase 8 rebinds, and the
//! mechanical check is a grep: `key.eql` and `mods.ctrl` appear nowhere below.
//!
//! **The turn.** One provider thread per submission, joined at `turn_end`,
//! rather than one per process. `stop` is set before every join so a thread
//! parked on backpressure notices, which is what makes ctrl+c land in the
//! middle of a firehose rather than at the end of one.
//!
//! **Leftovers.** An interrupted turn leaves events in the queue that the loop
//! will still drain. They are dropped rather than rendered, because a delta
//! that arrives after "interrupted" belongs to a turn that is over. The state
//! flag is the whole of that mechanism.

const std = @import("std");

const core = @import("tugcore");
const proto = @import("tugproto");

const actions = @import("edit/actions.zig");
const backend = @import("term/backend.zig");
const block_writer = @import("render/block_writer.zig");
const cadence_mod = @import("provider/cadence.zig");
const caps_mod = @import("term/caps.zig");
const command = @import("command.zig");
const config_mod = @import("config/load.zig");
const decoder_mod = @import("input/decoder.zig");
const editor_mod = @import("edit/editor.zig");
const history_mod = @import("edit/history.zig");
const key_mod = @import("input/key.zig");
const keymap_mod = @import("input/keymap.zig");
const theme_mod = @import("theme/registry.zig");
const loop_mod = @import("loop/loop.zig");
const modes = @import("term/modes.zig");
const probe_mod = @import("term/probe.zig");
const queue_mod = @import("loop/queue.zig");
const renderer_mod = @import("render/renderer.zig");
const transcript = @import("render/transcript.zig");
const runner_mod = @import("provider/runner.zig");
const waiting = @import("loop/wait.zig");

const Counting = @import("render/counting_writer.zig").Counting;
const Editor = editor_mod.Editor;
const History = history_mod.History;
const KeyEvent = key_mod.KeyEvent;
const Renderer = renderer_mod.Renderer;

/// What answers a submission. Null everywhere means a shell with no model
/// behind it, which is a supported configuration and the roadmap's "zero
/// network calls with no provider configured" made literal.
pub const Provider = struct {
    mock: core.mock.Config,
    cadence: cadence_mod.Preset,
};

pub const Session = struct {
    pub const State = enum { idle, streaming };

    io: std.Io,
    terminal: *backend.Backend,
    screen: *std.Io.Writer,
    renderer: *Renderer,
    editor: *Editor,
    history: *History,
    queue: *queue_mod.Queue,
    waker: *waiting.Waker,
    bus: *core.Bus,

    /// For `/theme`, which resolves a theme file at runtime. The only
    /// allocation this session makes on its own.
    gpa: std.mem.Allocator,

    /// The resolved settings, for `/config`. Borrowed from `run`'s frame; a
    /// config is read once and never re-read, which is why a borrow is enough.
    config: *const core.config.Config,
    /// Indexed by layer, exactly as `Config.writeNotes` takes it.
    origins: [5][]const u8,
    /// The live theme and the bytes its warnings borrow. A pointer to the
    /// frame's, not a copy, because `/theme` replaces it and the frame's
    /// `defer` is what frees whichever one is live at the end.
    theme: *theme_mod.Loaded,
    /// Where user themes live, or null when nothing in the environment names a
    /// directory.
    theme_dir: ?[]const u8 = null,

    /// Decides what every chord means, including which one is `newline`
    /// (`DR-003`). Resolved from the default table and every config layer;
    /// borrowed from `run`'s frame, or from a test's.
    keymap: *const keymap_mod.Keymap,
    provider: ?Provider,

    state: State = .idle,
    /// Which turn this is. Seeds the mock, so a conversation is not the same
    /// paragraph three times over while staying deterministic per seed.
    turn: u64 = 0,
    /// Held as fields rather than locals because the provider thread borrows
    /// all three for as long as it runs.
    mock: core.mock.Mock = undefined,
    cadence: cadence_mod.Cadence = undefined,
    runner: runner_mod.Runner = undefined,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    /// Set by the bus at `turn_end`, acted on at the next paint. The bus
    /// handler cannot join a thread: it is called from inside the drain, and
    /// the drain is inside the loop the thread is racing.
    finished: bool = false,
    /// A ctrl+c on an empty draft arms the exit; the next one takes it.
    quit_armed: bool = false,
    quitting: bool = false,
    /// A subscriber cannot fail, so a failure is stored and re-raised at the
    /// next render. Same shape as Phase 5's `MockSession`, for the same reason.
    failed: ?anyerror = null,

    // --- loop and bus callbacks --------------------------------------------

    pub fn onInput(context: ?*anyopaque, event: key_mod.InputEvent) loop_mod.Flow {
        const self: *Session = @ptrCast(@alignCast(context.?));
        self.apply(event) catch |err| {
            self.failed = err;
            return .stop;
        };
        return if (self.quitting) .stop else .keep_going;
    }

    pub fn onRender(context: ?*anyopaque) anyerror!void {
        const self: *Session = @ptrCast(@alignCast(context.?));
        if (self.failed) |err| return err;

        // The join happens here rather than in the bus handler, and before the
        // prompt is installed, so the frame that shows the prompt back is the
        // same frame that ends the turn.
        if (self.finished) self.endTurn();

        // Asked for every frame rather than tracked: a resize wakes the loop
        // and carries no payload, so one ioctl a frame is cheaper than the
        // bookkeeping that would avoid it.
        self.renderer.setSize(self.terminal.size());
        self.renderer.setPrompt(if (self.state == .idle)
            .{ .text = self.editor.items(), .cursor = self.editor.cursor }
        else
            null);

        _ = try self.renderer.paint(self.screen);
        try self.screen.flush();
    }

    pub fn onEvent(context: ?*anyopaque, payload: proto.Payload) void {
        const self: *Session = @ptrCast(@alignCast(context.?));
        self.applyEvent(payload) catch |err| {
            self.failed = err;
        };
    }

    fn applyEvent(self: *Session, payload: proto.Payload) !void {
        // Anything that arrives while the session is not streaming belongs to a
        // turn that has already ended — an interrupt leaves a queue behind.
        if (self.state != .streaming) return;

        switch (payload) {
            .request_start => try self.renderer.beginBlock(.assistant),
            .stream_delta => |delta| try self.renderer.feed(delta.text),
            .err => |failure| {
                // A notice block, which commits the partial assistant block
                // above it: whatever the provider managed to say stays on
                // screen and the reason it stopped goes underneath.
                try self.renderer.beginBlock(.notice);
                try self.renderer.feed(failure.message);
                try self.renderer.feed("\n");
            },
            .stream_end => try self.renderer.endBlock(),
            .turn_end => self.finished = true,
            else => {},
        }
    }

    // --- input -------------------------------------------------------------

    fn apply(self: *Session, event: key_mod.InputEvent) !void {
        switch (event) {
            .key => |key_event| try self.applyKey(key_event),
            .paste => |paste| {
                // Nothing to type into mid-stream, and a paste is not an
                // interrupt.
                if (self.state != .idle) return;
                self.afterEdit();
                try self.editor.insert(paste.bytes);
            },
        }
    }

    fn applyKey(self: *Session, event: KeyEvent) !void {
        const action = self.keymap.lookup(event) orelse {
            try self.typeLiteral(event);
            return;
        };

        try self.applyAction(action);
    }

    /// Runs one named action. The only entry point below `applyKey` that
    /// mentions an `Action`, which is what makes "adding an action touches the
    /// registry and one handler" a fact about this file rather than a hope.
    fn applyAction(self: *Session, action: actions.Action) !void {
        if (self.state == .streaming) {
            // Two chords matter mid-stream. Everything else would be editing a
            // draft that is not on screen.
            switch (action) {
                .interrupt => try self.interruptTurn(),
                // `endTurn` first: leaving with a provider thread still pushing
                // onto a queue whose frame is about to go is the one failure
                // worse than a broken terminal, and it is the same ordering
                // `run`'s defer relies on.
                .quit => {
                    self.endTurn();
                    self.quitting = true;
                },
                else => {},
            }
            return;
        }

        switch (try actions.applyEdit(self.editor, action)) {
            .handled => if (mutates(action)) self.afterEdit() else {
                self.quit_armed = false;
            },
            .submit => try self.submit(),
            .interrupt => try self.interruptDraft(),
            .quit => self.quitting = true,
            .end_of_input => try self.endOfInput(),
            .clear_screen => try self.renderer.clearScreen(self.screen),
            .complete => try self.completeCommand(),
            .history_prev => try self.recall(.previous),
            .history_next => try self.recall(.next),
        }
    }

    /// An unbound chord that is nevertheless a character the user meant to
    /// type.
    ///
    /// Whether it is one is `actions.literalCodepoint`'s decision, not this
    /// file's: the session does not look at a `KeyEvent`, and that is the
    /// property Phase 8 rebinds against.
    fn typeLiteral(self: *Session, event: KeyEvent) !void {
        if (self.state != .idle) return;
        const codepoint = actions.literalCodepoint(event) orelse return;
        self.afterEdit();
        try self.editor.insertCodepoint(codepoint);
    }

    /// Which actions change the draft's bytes.
    ///
    /// Movement does not, which is why arrowing around a recalled entry keeps
    /// browsing while typing into it does not.
    fn mutates(action: actions.Action) bool {
        return switch (action) {
            .newline,
            .delete_back,
            .delete_forward,
            .kill_word_back,
            .kill_to_line_start,
            .kill_to_line_end,
            .yank,
            => true,
            else => false,
        };
    }

    /// Common bookkeeping after anything that changes the draft.
    ///
    /// ponytail: an edit ends the browse outright, so the edited text becomes
    /// the draft and `up` starts again from the newest entry. bash keeps a
    /// per-entry edit instead; that is a second buffer per entry for a feature
    /// nobody has asked for.
    fn afterEdit(self: *Session) void {
        self.history.reset();
        self.quit_armed = false;
    }

    // --- the turn ----------------------------------------------------------

    fn submit(self: *Session) !void {
        const text = self.editor.items();
        // Whitespace is not a message. The draft is left alone rather than
        // cleared: nothing was sent, so nothing was consumed.
        if (std.mem.trim(u8, text, " \t\n").len == 0) return;

        self.history.append(text);

        // The echo goes in before the draft is cleared. `feed` copies, so the
        // borrow ends with this call.
        try self.renderer.beginBlock(.user);
        try self.renderer.feed(text);
        try self.renderer.feed("\n");
        try self.renderer.endBlock();

        // A command is answered here and never published. Nothing outside this
        // shell asked for it, and a provider handed `/quit` would be a provider
        // asked a question about a terminal it is not running in.
        //
        // `text` borrows the editor, so the command runs before the clear.
        switch (command.parse(text)) {
            .run => |found| {
                try self.runCommand(found.id, found.rest);
                self.editor.clear();
                self.quit_armed = false;
                return;
            },
            .unknown => |missed| {
                try self.unknownCommand(missed.word, missed.suggestion);
                self.editor.clear();
                self.quit_armed = false;
                return;
            },
            .prompt => {},
        }

        self.bus.publish(.{ .input_submit = .{ .text = text } });

        self.editor.clear();
        self.quit_armed = false;

        const provider = self.provider orelse {
            try self.notice("no provider configured - start tug with --provider mock");
            return;
        };
        try self.startTurn(provider);
    }

    fn startTurn(self: *Session, provider: Provider) !void {
        var config = provider.mock;
        config.seed = provider.mock.seed +% self.turn;
        self.turn += 1;

        self.mock = .init(config);
        self.cadence = .init(config.seed, provider.cadence, config.fault, config.stall_ms);
        self.stop.store(false, .release);

        self.runner = .{
            .io = self.io,
            .provider = self.mock.provider(),
            .cadence = &self.cadence,
            .queue = self.queue,
            .waker = self.waker,
            .stop = &self.stop,
        };
        self.thread = try self.runner.spawn();
        self.state = .streaming;
    }

    /// Stops the provider thread and returns to the prompt.
    ///
    /// The flag goes up before the join, which is what lets a thread parked on
    /// backpressure notice while it is parked rather than only between events.
    /// A firehose interrupted at the prompt would otherwise take as long to
    /// stop as it takes to finish.
    pub fn endTurn(self: *Session) void {
        if (self.thread) |thread| {
            self.stop.store(true, .release);
            thread.join();
            self.thread = null;
        }
        self.state = .idle;
        self.finished = false;
    }

    fn interruptTurn(self: *Session) !void {
        self.endTurn();
        try self.notice("interrupted");
    }

    fn interruptDraft(self: *Session) !void {
        if (!self.editor.isEmpty()) {
            self.editor.clear();
            self.afterEdit();
            return;
        }
        if (self.quit_armed) {
            self.quitting = true;
            return;
        }
        self.quit_armed = true;
        try self.notice("press ctrl+c again to exit");
    }

    fn endOfInput(self: *Session) !void {
        if (self.editor.isEmpty()) {
            self.quitting = true;
            return;
        }
        self.editor.deleteForward();
        self.afterEdit();
    }

    fn recall(self: *Session, direction: enum { previous, next }) !void {
        const text = switch (direction) {
            .previous => self.history.prev(self.editor.items()),
            .next => self.history.next(),
        } orelse return;
        try self.editor.setText(text);
        self.quit_armed = false;
    }

    /// One line from tug itself, committed to scrollback.
    fn notice(self: *Session, message: []const u8) !void {
        try self.renderer.beginBlock(.notice);
        try self.renderer.feed(message);
        try self.renderer.feed("\n");
        try self.renderer.endBlock();
    }

    // --- commands ----------------------------------------------------------

    /// Tab: finish the command name at the head of the draft.
    ///
    /// First token only. Argument completion is out of v0.1's scope, and a tab
    /// anywhere else does what it did before this phase, which is nothing.
    fn completeCommand(self: *Session) !void {
        const text = self.editor.items();
        if (text.len < 2 or text[0] != '/') return;
        if (std.mem.indexOfAny(u8, text, " \t\n") != null) return;

        const full = command.complete(text[1..]) orelse return;

        // The trailing space is the point of completing a name: `/theme` takes
        // an argument, and a cursor parked against the `e` would have to be
        // moved before one could be typed.
        var buffer: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buffer, "/{s} ", .{full}) catch return;
        try self.editor.setText(line);
        self.afterEdit();
    }

    /// Runs one command. The only place in this file that mentions a
    /// `command.Id`, which is what makes "a new command is a table row and a
    /// switch arm" a fact about this file rather than a hope.
    fn runCommand(self: *Session, id: command.Id, rest: []const u8) !void {
        // The one command with nothing to print. Everything below opens a
        // block, and a block with nothing in it is a blank row in scrollback.
        if (id == .quit) {
            self.quitting = true;
            return;
        }

        try self.renderer.beginBlock(.notice);
        // A batching buffer, not a limit: `BlockWriter` drains when it fills,
        // so a `/keys` table with 160 bindings streams through this same 1 KiB.
        var buffer: [1024]u8 = undefined;
        var block: block_writer.BlockWriter = .init(self.renderer, &buffer);
        const out = &block.writer;

        switch (id) {
            .quit => unreachable,
            .help => try command.writeHelp(out),
            .config => {
                try self.config.write(out);
                try self.writeWarnings(out);
            },
            .keys => try self.keymap.write(out),
            .theme => try self.switchTheme(out, rest),
        }

        try block.finish();
        try self.renderer.endBlock();
    }

    /// `/theme` with a name switches; without one, it lists.
    ///
    /// ponytail: the list is the built-ins plus the live theme when it is
    /// neither. Reading the themes directory would need `std.Io.Dir` iteration,
    /// which nothing in tug does yet and which would put a readdir on a path
    /// that has no IO at all today. Add it when somebody has more than one file
    /// in there and cannot remember what they called them.
    fn switchTheme(self: *Session, out: *std.Io.Writer, name: []const u8) !void {
        if (name.len == 0) {
            const live = self.config.theme.value;
            try out.writeAll("theme                where\n");
            var listed = false;
            for (theme_mod.builtin_names) |builtin_name| {
                const is_live = std.mem.eql(u8, builtin_name, live);
                if (is_live) listed = true;
                try writeThemeRow(out, builtin_name, "built-in", is_live);
            }
            if (!listed) try writeThemeRow(out, live, self.theme.origin, true);
            return;
        }

        // `.flag` because a command outranks every file, which is what the top
        // layer means. It reaches nothing but the note's own layer field, which
        // a theme's `writeNotes` does not read — a theme is one file, not a
        // stack — so it is a label rather than a decision.
        const loaded = theme_mod.resolve(self.gpa, self.io, name, self.theme_dir, .flag);

        // The `Theme` is values and not slices (`core.theme`), so the bytes the
        // old one was parsed from are free the moment the renderer holds the
        // new colours.
        self.renderer.setTheme(loaded.result.theme);
        self.theme.deinit(self.gpa);
        self.theme.* = loaded;

        try out.print("theme: {s}\n", .{name});
        try self.theme.result.writeNotes(out, self.theme.origin);
    }

    fn writeThemeRow(
        out: *std.Io.Writer,
        name: []const u8,
        where: []const u8,
        live: bool,
    ) std.Io.Writer.Error!void {
        try out.writeAll("  ");
        try out.writeAll(name);
        var index = name.len + 2;
        while (index < 20) : (index += 1) try out.writeAll(" ");
        try out.writeAll(" ");
        try out.writeAll(where);
        if (live) try out.writeAll("  (live)");
        try out.writeAll("\n");
    }

    fn unknownCommand(self: *Session, word: []const u8, suggestion: []const u8) !void {
        try self.renderer.beginBlock(.notice);
        var buffer: [256]u8 = undefined;
        var block: block_writer.BlockWriter = .init(self.renderer, &buffer);
        const out = &block.writer;

        if (word.len == 0) {
            // A bare slash. There is no word to be close to, so the sentence
            // points at the screen that lists them.
            try out.writeAll("type /help for the commands\n");
        } else {
            try out.print("no such command ('/{s}')", .{word});
            if (suggestion.len > 0) try out.print("; did you mean '/{s}'?", .{suggestion});
            try out.writeAll("\n");
        }

        try block.finish();
        try self.renderer.endBlock();
    }

    /// The three warning lists, in the order `--debug-config` prints them.
    ///
    /// One screen, one list, one shape — which is the rule `DR-013` set when
    /// there were two of these and `DR-007` re-checked when there were three.
    fn writeWarnings(self: *const Session, out: *std.Io.Writer) !void {
        if (!self.hasWarnings()) return;
        try out.writeAll("\n");
        try self.config.writeNotes(out, self.origins);
        try self.keymap.writeProblems(out, self.origins);
        try self.theme.result.writeNotes(out, self.theme.origin);
    }

    pub fn warningCount(self: *const Session) usize {
        return self.config.notes().len +
            self.keymap.problems().len +
            self.theme.result.notes().len;
    }

    pub fn hasWarnings(self: *const Session) bool {
        return self.warningCount() > 0;
    }

    /// One line, once, and only when there is something behind it.
    ///
    /// The three lists are on `/config`. Printing them here would open a shell
    /// with seven rows of scrollback about a comma, and a person who has just
    /// typed a chord that did nothing needs to know there is an explanation
    /// more than they need the explanation itself (`DR-014`).
    pub fn warnAtStartup(self: *Session) !void {
        const count = self.warningCount();
        if (count == 0) return;

        var buffer: [96]u8 = undefined;
        const line = std.fmt.bufPrint(
            &buffer,
            "{d} warning{s} in your configuration - run /config to see {s}",
            .{
                count,
                if (count == 1) "" else "s",
                if (count == 1) "it" else "them",
            },
        ) catch "there are problems in your configuration - run /config";
        try self.notice(line);
    }
};

/// Everything `main.zig` has already read from the environment.
pub const Setup = struct {
    env: caps_mod.Env,
    /// Borrowed for the whole call. Null means no persistent history.
    history_path: ?[]const u8,
    provider: ?Provider,
    /// Where user themes live, or null when nothing in the environment names a
    /// directory. Beside `config` because it comes from the same `Location`.
    theme_dir: ?[]const u8 = null,
    /// Where the config files are and what the environment says about them.
    /// Read after the first paint — see `run`.
    config: config_mod.Sources = .{},
    /// When set, `run` stamps it the instant the first frame reaches the
    /// terminal and returns without entering the loop. This is the cold-start
    /// budget's only measurement point: everything above the stamp is startup,
    /// and everything below it is a shell already on screen.
    first_paint: ?*std.Io.Clock.Timestamp = null,
};

/// Opens the shell and does not return until the user leaves it.
///
/// Startup order is load-bearing. The prompt is painted **before** the
/// capability probe, because the probe is allowed 50 ms of silence and the
/// cold-start budget is 10 ms. `DR-003` states it: probing happens after the
/// first paint. What that costs is one frame drawn without the probe's answers,
/// which affects synchronized output and nothing a user can see.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    setup: Setup,
) !void {
    var terminal = backend.open() catch |err| switch (err) {
        error.NotATerminal => {
            try out.writeAll("not a terminal: there is nothing to edit in\n");
            return out.flush();
        },
        else => return err,
    };

    try terminal.enterRaw();
    defer terminal.restore();

    // Sized so a whole frame fits without an intermediate flush, which is the
    // one-write-per-frame invariant as it reaches a real terminal.
    var frame_buffer: [256 * 1024]u8 = undefined;
    var terminal_writer = terminal.writer(io, &frame_buffer);
    const screen = &terminal_writer.interface;

    var stack: modes.Stack = .{};
    defer stack.popAll(screen);

    var renderer: Renderer = .init(
        gpa,
        // No probe has run. Colour and size come from the environment and one
        // ioctl, both free; the two probed capabilities default to absent,
        // which is the safe direction to be wrong in.
        caps_mod.detect(setup.env, .{}, terminal.size()),
        terminal.size(),
    );
    defer renderer.deinit();

    var editor: Editor = .init(gpa);
    defer editor.deinit();

    var history: History = .init(gpa, io, setup.history_path);
    defer history.deinit();

    // The first paint. Everything below this line happens with a prompt already
    // on screen — painted with `Theme.fallback`, the terminal's own colours,
    // because no config has been read yet. That is the same trade the probe
    // makes twenty lines below and it is deliberate: the cold-start budget is
    // 10 ms, and what lands in scrollback from this frame is one empty prompt
    // row. Do not move the config load above it.
    renderer.setPrompt(.{ .text = "", .cursor = 0 });
    _ = try renderer.paint(screen);
    try screen.flush();

    // The cold-start budget's far end. Returning here is safe because every
    // resource above this line is released by a `defer` and nothing below it
    // has been reached — there is nothing else to undo.
    if (setup.first_paint) |slot| {
        slot.* = .now(io, .awake);
        return;
    }

    // After the first paint, for the reason the probe is: the cold-start budget
    // is 10 ms and two file reads are not free. Nothing above this line reads a
    // setting, which is what makes the ordering safe rather than merely fast.
    var loaded = config_mod.load(gpa, io, setup.config);
    defer loaded.deinit(gpa);

    // The two settings v0.1 has a consumer for. The theme and the keymap are
    // carried with their provenance and read by Phases 9 and 8; the notes are
    // read by Phase 10's `/config`, and `--debug-config` prints all three today.
    //
    // The history has not opened its file at this point — it opens on the first
    // press of `up` — which is what makes clearing the path here the same thing
    // as never having had one.
    if (!loaded.config.history_enabled.value) history.path = null;
    history.max_entries = loaded.config.history_max_entries.value;

    // Resolved here rather than after the probe, because the *name* does not
    // depend on the terminal — only the tier it is painted at does, and the
    // renderer reads that from `caps` at the moment it writes each escape.
    //
    // Its warnings reach the screen through `/config`, along with the config's
    // and the keymap's � one list, one shape, one place to look (`DR-014`).
    var theme = theme_mod.resolve(
        gpa,
        io,
        loaded.config.theme.value,
        setup.theme_dir,
        loaded.config.theme.source,
    );
    defer theme.deinit(gpa);
    renderer.setTheme(theme.result.theme);

    var probe_buffer: [probe_mod.buffer_bytes]u8 = undefined;
    const probed = probe_mod.run(io, &terminal, &probe_buffer);
    const detected = caps_mod.detect(setup.env, probed.probe, terminal.size());
    renderer.setCaps(detected);
    if (detected.bracketed_paste) try stack.push(screen, .bracketed_paste);
    if (detected.kitty_keyboard) try stack.push(screen, .kitty_keyboard);

    var scratch: [4096]u8 = undefined;
    var decoder: decoder_mod.Decoder = .init(&scratch);
    decoder.setKittyActive(detected.kitty_keyboard);

    // After the probe, because which chord means `newline` depends on its
    // answer, and after the config load, because that is where the rebinds come
    // from. The frame owns it; the session borrows it for the life of the loop.
    //
    // Its warnings reach the screen through `/config` (`DR-014`), and the line
    // below the loop's first paint says how many there are to go and look at.
    var keymap: keymap_mod.Keymap = .build(&loaded.config, detected.kitty_keyboard);

    // Anything typed while the terminal was deciding whether to answer. On a
    // terminal that answers neither query the probe window is the full 50 ms,
    // and dropping what arrived in it means dropping the first keystroke of
    // every session.
    if (probed.leftover.len > 0) decoder.feed(probed.leftover);

    var waker: waiting.Waker = try .init();
    defer waker.deinit();
    terminal.setWakeHandle(waker.writeHandle());

    var bus: core.Bus = .{};
    var queue: queue_mod.Queue = .{};
    var scheduler: core.Scheduler = .{};

    var session: Session = .{
        .io = io,
        .gpa = gpa,
        .terminal = &terminal,
        .screen = screen,
        .renderer = &renderer,
        .editor = &editor,
        .history = &history,
        .queue = &queue,
        .waker = &waker,
        .bus = &bus,
        .keymap = &keymap,
        .config = &loaded.config,
        .origins = loaded.origins,
        .theme = &theme,
        .theme_dir = setup.theme_dir,
        .provider = setup.provider,
    };
    try bus.subscribe(.{ .context = &session, .handler = Session.onEvent });

    // The three warning lists have existed since Phases 7 to 9 with nowhere to
    // appear but `--debug-config`. This is the line that closes that, and
    // `/config` is where the detail is.
    try session.warnAtStartup();

    // Ahead of every return below, including the error ones. A thread still
    // pushing onto a queue whose stack frame is gone is the one failure worse
    // than a broken terminal.
    defer session.endTurn();

    var loop: loop_mod.Loop = .{
        .io = io,
        .terminal = &terminal,
        .waker = &waker,
        .queue = &queue,
        .bus = &bus,
        .decoder = &decoder,
        .scheduler = &scheduler,
        .handlers = .{
            .context = &session,
            .onInput = Session.onInput,
            .onRender = Session.onRender,
        },
    };
    try loop.run();

    // Take the prompt down on the way out: it is the one part of the tail that
    // is not a record of anything, and leaving it in scrollback would be a `>`
    // that survives the process.
    session.endTurn();
    renderer.setPrompt(null);
    _ = try renderer.paint(screen);
    try screen.writeAll("\r\n");
    try screen.flush();
}

const testing = std.testing;

/// A session with everything a terminal would have supplied stubbed out.
/// Enough to exercise every decision the session makes on its own.
const Harness = struct {
    renderer: Renderer,
    editor: Editor,
    history: History,
    /// A value rather than a local, so a test can rebind it after `init` and
    /// the session � which holds a pointer to this field � sees the change.
    keymap: keymap_mod.Keymap = undefined,
    /// Same reason: `/config` reads this, and a test sets it up first.
    config: core.config.Config = .{},
    loaded_theme: theme_mod.Loaded = undefined,
    bus: core.Bus = .{},
    session: Session = undefined,

    const origins: [5][]const u8 = .{
        "<defaults>",
        "<none>",
        ".tug/config.toml",
        "<environment>",
        "<flags>",
    };

    fn init(self: *Harness) void {
        const caps: renderer_mod.Capabilities = .{
            .color = .none,
            .kitty_keyboard = true,
            .synchronized_output = false,
            .bracketed_paste = true,
            .size = .{ .cols = 96, .rows = 200 },
        };
        self.renderer = .init(testing.allocator, caps, caps.size);
        self.editor = .init(testing.allocator);
        self.history = .init(testing.allocator, undefined, null);
        self.keymap = .defaults(true);
        self.config = .{};
        self.loaded_theme = theme_mod.resolve(testing.allocator, testing.io, "dark", null, .default);
        self.bus = .{};
        self.session = .{
            .io = testing.io,
            .gpa = testing.allocator,
            .terminal = undefined,
            .screen = undefined,
            .renderer = &self.renderer,
            .editor = &self.editor,
            .history = &self.history,
            .queue = undefined,
            .waker = undefined,
            .bus = &self.bus,
            .keymap = &self.keymap,
            .config = &self.config,
            .origins = origins,
            .theme = &self.loaded_theme,
            .theme_dir = null,
            .provider = null,
        };
    }

    fn deinit(self: *Harness) void {
        self.loaded_theme.deinit(testing.allocator);
        self.history.deinit();
        self.editor.deinit();
        self.renderer.deinit();
    }

    fn press(self: *Harness, event: KeyEvent) !void {
        try self.session.applyKey(event);
    }

    fn typeText(self: *Harness, text: []const u8) !void {
        for (text) |byte| try self.press(.{ .key = .{ .char = byte } });
    }

    /// Whether one paint contains every one of `needles`.
    ///
    /// A command's output is a notice block, so the only place to look for it
    /// is the frame � which is also the assertion that it went through the
    /// renderer rather than around it.
    ///
    /// **Call this once per test.** Painting commits rows to scrollback, so a
    /// second call looks at a frame the first one emptied. Pass every needle to
    /// one call rather than making one call per needle.
    fn painted(self: *Harness, needles: []const []const u8) bool {
        var buffer: [128 * 1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        _ = self.renderer.paint(&writer) catch return false;
        const frame = writer.buffered();
        for (needles) |needle| {
            if (std.mem.indexOf(u8, frame, needle) == null) return false;
        }
        return true;
    }
};

test "typing goes into the draft and enter clears it" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    try harness.typeText("hello");
    try testing.expectEqualStrings("hello", harness.editor.items());

    try harness.press(.{ .key = .enter });
    // Submitted: the draft is empty and the history has it.
    try testing.expectEqualStrings("", harness.editor.items());
    try testing.expectEqual(@as(usize, 1), harness.history.count());
}

test "shift+enter inserts a line break and does not submit" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    try harness.typeText("one");
    try harness.press(.{ .key = .enter, .mods = .{ .shift = true } });
    try harness.typeText("two");
    try testing.expectEqualStrings("one\ntwo", harness.editor.items());
    try testing.expectEqual(@as(usize, 0), harness.history.count());
}

test "a whitespace-only draft is not a submission" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    try harness.typeText("   ");
    try harness.press(.{ .key = .enter });
    try testing.expectEqual(@as(usize, 0), harness.history.count());
    // The draft is left alone: nothing was sent, so nothing was consumed.
    try testing.expectEqualStrings("   ", harness.editor.items());
}

test "a paste is inserted whole and its newlines do not submit" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    try harness.session.apply(.{ .paste = .{ .bytes = "first\nsecond\n" } });
    try testing.expectEqualStrings("first\nsecond\n", harness.editor.items());
    try testing.expectEqual(@as(usize, 0), harness.history.count());
}

test "ctrl+c clears a draft, then arms, then quits" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    const ctrl_c: KeyEvent = .{ .key = .{ .char = 'c' }, .mods = .{ .ctrl = true } };

    try harness.typeText("half a message");
    try harness.press(ctrl_c);
    try testing.expectEqualStrings("", harness.editor.items());
    try testing.expect(!harness.session.quitting);

    // Empty now: the first press arms and the second takes it.
    try harness.press(ctrl_c);
    try testing.expect(!harness.session.quitting);
    try testing.expect(harness.session.quit_armed);
    try harness.press(ctrl_c);
    try testing.expect(harness.session.quitting);
}

test "typing disarms a pending quit" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    const ctrl_c: KeyEvent = .{ .key = .{ .char = 'c' }, .mods = .{ .ctrl = true } };
    try harness.press(ctrl_c);
    try testing.expect(harness.session.quit_armed);

    try harness.typeText("x");
    try testing.expect(!harness.session.quit_armed);
    try harness.press(ctrl_c);
    // That was a draft-clear, not the second half of a quit.
    try testing.expect(!harness.session.quitting);
}

test "ctrl+d deletes forward with a draft and quits without one" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    const ctrl_d: KeyEvent = .{ .key = .{ .char = 'd' }, .mods = .{ .ctrl = true } };

    try harness.typeText("abc");
    harness.editor.moveLineStart();
    try harness.press(ctrl_d);
    try testing.expectEqualStrings("bc", harness.editor.items());
    try testing.expect(!harness.session.quitting);

    harness.editor.clear();
    try harness.press(ctrl_d);
    try testing.expect(harness.session.quitting);
}

test "up recalls and down restores the draft that was stashed" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    try harness.typeText("first message");
    try harness.press(.{ .key = .enter });
    try harness.typeText("second message");
    try harness.press(.{ .key = .enter });

    try harness.typeText("in progress");
    try harness.press(.{ .key = .up });
    try testing.expectEqualStrings("second message", harness.editor.items());
    try harness.press(.{ .key = .up });
    try testing.expectEqualStrings("first message", harness.editor.items());

    try harness.press(.{ .key = .down });
    try testing.expectEqualStrings("second message", harness.editor.items());
    try harness.press(.{ .key = .down });
    try testing.expectEqualStrings("in progress", harness.editor.items());
}

test "up inside a multiline draft moves the cursor before it recalls" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    try harness.typeText("older");
    try harness.press(.{ .key = .enter });

    try harness.typeText("top");
    try harness.press(.{ .key = .enter, .mods = .{ .shift = true } });
    try harness.typeText("bottom");

    // On the second line: up is a cursor move.
    try harness.press(.{ .key = .up });
    try testing.expectEqualStrings("top\nbottom", harness.editor.items());
    try testing.expectEqual(@as(usize, 3), harness.editor.cursor);

    // On the first line now: up recalls.
    try harness.press(.{ .key = .up });
    try testing.expectEqualStrings("older", harness.editor.items());
}

test "editing a recalled entry ends the browse" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    try harness.typeText("remembered");
    try harness.press(.{ .key = .enter });
    try harness.typeText("draft");

    try harness.press(.{ .key = .up });
    try testing.expectEqualStrings("remembered", harness.editor.items());

    try harness.typeText("!");
    try testing.expectEqualStrings("remembered!", harness.editor.items());

    // The browse is over, so up stashes the edited text and starts again from
    // the newest entry rather than continuing backwards.
    try harness.press(.{ .key = .up });
    try testing.expectEqualStrings("remembered", harness.editor.items());
    try harness.press(.{ .key = .down });
    try testing.expectEqualStrings("remembered!", harness.editor.items());
}

test "an unbound chord is ignored rather than typed" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    try harness.press(.{ .key = .{ .f = 5 } });
    try harness.press(.{ .key = .page_up });
    try harness.press(.{ .key = .tab });
    try harness.press(.{ .key = .{ .char = 'q' }, .mods = .{ .super = true } });
    try testing.expectEqualStrings("", harness.editor.items());
}

test "a submission with no provider says so instead of hanging" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    try harness.typeText("anyone there");
    try harness.press(.{ .key = .enter });

    // Still idle, so the prompt comes straight back.
    try testing.expectEqual(Session.State.idle, harness.session.state);
    try testing.expectEqual(@as(?std.Thread, null), harness.session.thread);
}

test "the emacs kills and yank reach the editor through the action layer" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    try harness.typeText("alpha beta");
    try harness.press(.{ .key = .{ .char = 'w' }, .mods = .{ .ctrl = true } });
    try testing.expectEqualStrings("alpha ", harness.editor.items());
    try harness.press(.{ .key = .{ .char = 'y' }, .mods = .{ .ctrl = true } });
    try testing.expectEqualStrings("alpha beta", harness.editor.items());

    try harness.press(.{ .key = .{ .char = 'a' }, .mods = .{ .ctrl = true } });
    try testing.expectEqual(@as(usize, 0), harness.editor.cursor);
    try harness.press(.{ .key = .{ .char = 'k' }, .mods = .{ .ctrl = true } });
    try testing.expectEqualStrings("", harness.editor.items());
}

test "the quit action leaves, whatever is in the draft" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    try harness.typeText("mid sentence");
    try harness.session.applyAction(.quit);
    try testing.expect(harness.session.quitting);
}

test "the session dispatches through the keymap it was given, not through a table" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    // Rebind `ctrl+j` to newline, the way a project config would.
    var config: core.config.Config = .{};
    config.apply(.project, "[keys]\n\"ctrl+j\" = \"newline\"\n");
    harness.keymap = .build(&config, true);

    try harness.typeText("one");
    try harness.press(.{ .key = .{ .char = 'j' }, .mods = .{ .ctrl = true } });
    try harness.typeText("two");
    try testing.expectEqualStrings("one\ntwo", harness.editor.items());
    try testing.expectEqual(@as(usize, 0), harness.history.count());
}

test "a rebound chord stops meaning what it used to" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    var config: core.config.Config = .{};
    config.apply(.project, "[keys]\n\"ctrl+y\" = \"quit\"\n");
    harness.keymap = .build(&config, true);

    try harness.typeText("alpha beta");
    try harness.press(.{ .key = .{ .char = 'w' }, .mods = .{ .ctrl = true } });
    try testing.expectEqualStrings("alpha ", harness.editor.items());

    // ctrl+y was yank. It is not any more.
    try harness.press(.{ .key = .{ .char = 'y' }, .mods = .{ .ctrl = true } });
    try testing.expectEqualStrings("alpha ", harness.editor.items());
    try testing.expect(harness.session.quitting);
}

test "a leftover delta from an interrupted turn is dropped" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    // Idle, which is what an interrupt leaves behind: the payload is ignored
    // rather than opening a block the prompt would then sit inside.
    Session.onEvent(&harness.session, .{ .stream_delta = .{ .text = "late" } });
    try testing.expectEqual(@as(?anyerror, null), harness.session.failed);

    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    _ = try harness.renderer.paint(&writer);
    try testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOf(u8, writer.buffered(), "late"),
    );
}

// --- commands ---------------------------------------------------------------

test "a command is answered here and never reaches the bus" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    var seen: usize = 0;
    try harness.bus.subscribe(.{ .context = &seen, .handler = countSubmits });

    try harness.typeText("/help");
    try harness.press(.{ .key = .enter });

    // In history and echoed like anything else the user typed...
    try testing.expectEqual(@as(usize, 1), harness.history.count());
    try testing.expectEqualStrings("", harness.editor.items());
    // ...and not published, because nothing outside this shell asked for it.
    try testing.expectEqual(@as(usize, 0), seen);
}

fn countSubmits(context: ?*anyopaque, payload: proto.Payload) void {
    const seen: *usize = @ptrCast(@alignCast(context.?));
    if (payload == .input_submit) seen.* += 1;
}

test "a prompt still reaches the bus" {
    // The other half of the claim above: the router did not swallow everything.
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    var seen: usize = 0;
    try harness.bus.subscribe(.{ .context = &seen, .handler = countSubmits });

    try harness.typeText("what is a tugboat");
    try harness.press(.{ .key = .enter });
    try testing.expectEqual(@as(usize, 1), seen);
}

test "a line that starts with a path is a prompt, not a command" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    var seen: usize = 0;
    try harness.bus.subscribe(.{ .context = &seen, .handler = countSubmits });

    try harness.typeText("/etc/hosts is wrong");
    try harness.press(.{ .key = .enter });
    try testing.expectEqual(@as(usize, 1), seen);
}

test "/quit leaves" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    try harness.typeText("/quit");
    try harness.press(.{ .key = .enter });
    try testing.expect(harness.session.quitting);
}

test "an unknown command suggests the near miss and does not quit" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    try harness.typeText("/thme");
    try harness.press(.{ .key = .enter });
    try testing.expect(!harness.session.quitting);
    try testing.expect(harness.painted(&.{ "no such command", "thme", "theme" }));
}

test "a bare slash points at help rather than suggesting nothing" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    try harness.typeText("/");
    try harness.press(.{ .key = .enter });
    try testing.expect(harness.painted(&.{"/help"}));
}

test "/theme switches the live theme and says which one" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    try testing.expectEqualStrings("<built-in dark>", harness.loaded_theme.origin);
    try harness.typeText("/theme light");
    try harness.press(.{ .key = .enter });

    try testing.expectEqualStrings("<built-in light>", harness.loaded_theme.origin);
    // The renderer holds the new colours, not just the registry.
    try testing.expectEqual(
        harness.loaded_theme.result.theme.color(.user_block),
        harness.renderer.theme.color(.user_block),
    );
}

test "/theme with an unknown name warns and keeps the shell open" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    try harness.typeText("/theme nope");
    try harness.press(.{ .key = .enter });
    try testing.expect(!harness.session.quitting);
    try testing.expect(harness.painted(&.{ "no such theme", "nope" }));
    // Fell back to the dark built-in rather than to nothing.
    try testing.expectEqualStrings("<built-in dark>", harness.loaded_theme.origin);
}

test "/theme with no argument lists what there is and marks the live one" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    try harness.typeText("/theme");
    try harness.press(.{ .key = .enter });
    try testing.expect(harness.painted(&.{ "dark", "light", "(live)" }));
}

test "/config prints the provenance column and every warning list" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    // One warning of each kind, so the assertion is about all three lists
    // rather than about whichever one happens to be first.
    harness.config.apply(.project, "theme = \"nope\"\nnosuch = 1\n[keys]\n\"ctrl+@@\" = \"newline\"\n");
    harness.keymap = .build(&harness.config, true);
    // The theme's own list. `init` resolved `dark`; this is what `run` would
    // have resolved from the config above, which is the theme whose name is
    // wrong.
    harness.loaded_theme.deinit(testing.allocator);
    harness.loaded_theme = theme_mod.resolve(
        testing.allocator,
        testing.io,
        harness.config.theme.value,
        null,
        harness.config.theme.source,
    );

    try harness.typeText("/config");
    try harness.press(.{ .key = .enter });

    // One call, not three: the renderer is append-only, so the first paint
    // commits these rows to scrollback and a second would look at a frame that
    // no longer holds them.
    try testing.expect(harness.painted(&.{
        "setting",
        "theme",
        "project",
        "no such setting",
        "not a key chord",
        "no such theme",
    }));
}

test "/keys prints the live bindings, including a rebind" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    harness.config.apply(.project, "[keys]\n\"ctrl+j\" = \"newline\"\n");
    harness.keymap = .build(&harness.config, true);

    try harness.typeText("/keys");
    try harness.press(.{ .key = .enter });

    try testing.expect(harness.painted(&.{ "chord", "action", "ctrl+j", "newline", "project" }));
}

test "tab completes a command name and leaves room for its argument" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    try harness.typeText("/the");
    try harness.press(.{ .key = .tab });
    try testing.expectEqualStrings("/theme ", harness.editor.items());
    try testing.expectEqual(@as(usize, 7), harness.editor.cursor);
}

test "tab does nothing to a draft that is not a command" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    try harness.typeText("hello");
    try harness.press(.{ .key = .tab });
    try testing.expectEqualStrings("hello", harness.editor.items());

    // Past the first token is out of scope: no argument completion in v0.1.
    harness.editor.clear();
    try harness.typeText("/theme li");
    try harness.press(.{ .key = .tab });
    try testing.expectEqualStrings("/theme li", harness.editor.items());

    // An ambiguous prefix completes to nothing rather than to a guess.
    harness.editor.clear();
    try harness.typeText("/");
    try harness.press(.{ .key = .tab });
    try testing.expectEqualStrings("/", harness.editor.items());
}

test "a command mid-stream is ignored, like every other chord that is not an interrupt" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    harness.session.state = .streaming;
    try harness.session.applyAction(.complete);
    try harness.session.applyAction(.submit);
    harness.session.state = .idle;
    try testing.expect(!harness.session.quitting);
}

test "a clean config says nothing at startup" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    try testing.expect(!harness.session.hasWarnings());
    try testing.expectEqual(@as(usize, 0), harness.session.warningCount());
}

test "the startup line counts every list and points at the screen with the detail" {
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    // One from the config, one from the keymap.
    harness.config.apply(.project, "nosuch = 1\n[keys]\n\"ctrl+@@\" = \"newline\"\n");
    harness.keymap = .build(&harness.config, true);
    try testing.expectEqual(@as(usize, 2), harness.session.warningCount());

    try harness.session.warnAtStartup();
    try testing.expect(harness.painted(&.{ "2 warnings", "/config" }));
}

test "one warning is not two" {
    // The singular exists because a shell that opens with `1 warnings` is a
    // shell nobody trusts about anything else either.
    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    harness.config.apply(.project, "nosuch = 1\n");
    try testing.expectEqual(@as(usize, 1), harness.session.warningCount());

    try harness.session.warnAtStartup();
    try testing.expect(harness.painted(&.{"1 warning in your configuration"}));
}

// --- command goldens --------------------------------------------------------

/// Types `line`, submits it, and returns the frame that came out.
///
/// One paint, at 96 columns and 200 rows, so the whole of a `/keys` table is in
/// the tail rather than half of it in scrollback.
///
/// 96 rather than 80 because `/keys`'s longest row — the `shift+enter` binding
/// with its protocol annotation — is 84 columns and wraps below that. It wraps
/// on a real 80-column terminal too, correctly; a golden of a wrapped row is
/// simply a worse record of what the command said.
///
/// 200 rows rather than a realistic height for the same reason: a golden of a
/// scrollback stream is a golden of where the terminal happened to be, and this
/// phase is pinning what the commands say, not where the renderer put it.
fn commandGolden(name: []const u8, line: []const u8, setup: ?[]const u8) !void {
    const gpa = testing.allocator;

    var harness: Harness = undefined;
    harness.init();
    defer harness.deinit();

    if (setup) |source| {
        harness.config.apply(.project, source);
        harness.keymap = .build(&harness.config, true);
        harness.loaded_theme.deinit(gpa);
        harness.loaded_theme = theme_mod.resolve(
            gpa,
            testing.io,
            harness.config.theme.value,
            null,
            harness.config.theme.source,
        );
    }

    try harness.typeText(line);
    try harness.press(.{ .key = .enter });

    var buffer: [128 * 1024]u8 = undefined;
    var sink: [128 * 1024]u8 = undefined;
    var counting: Counting = .init(&buffer, &sink);
    _ = try harness.renderer.paint(&counting.writer);
    try counting.writer.flush();
    // Every golden is also a one-write-per-frame assertion, for free.
    try testing.expect(counting.writes <= 1);

    return transcript.expectGolden(gpa, name, counting.bytes());
}

test "golden: /help" {
    try commandGolden("command-help", "/help", null);
}

test "golden: /keys, with a rebind and a displaced default" {
    // A config binding on top of a default, so the golden pins the `from`
    // column rather than the happy path alone.
    try commandGolden("command-keys", "/keys",
        \\[keys]
        \\"ctrl+j" = "newline"
        \\"ctrl+g" = "quit"
        \\
    );
}

test "golden: /config, with one warning of each kind" {
    try commandGolden("command-config", "/config",
        \\theme = "nope"
        \\nosuch = 1
        \\[keys]
        \\"ctrl+@@" = "newline"
        \\
    );
}

test "golden: /theme, listing what there is" {
    try commandGolden("command-theme", "/theme", null);
}

test "golden: /quit says nothing and leaves" {
    // The one command with no output. The golden is the echo and nothing
    // after it, and it is worth pinning precisely because "prints nothing" is
    // the easiest thing to break into "prints a blank row".
    try commandGolden("command-quit", "/quit", null);
}
