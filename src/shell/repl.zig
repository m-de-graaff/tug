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
const cadence_mod = @import("provider/cadence.zig");
const caps_mod = @import("term/caps.zig");
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
const runner_mod = @import("provider/runner.zig");
const waiting = @import("loop/wait.zig");

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
            .complete => {},
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
    // Its warnings are not printed, for the reason the keymap's are not: there
    // is nowhere to put them until Phase 10's `/config` renders a notice block,
    // and a shell that opened with three lines of scrollback about a colour
    // would be worse than one quietly using the built-in. `--debug-config` is
    // where they are visible today.
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
    // Its warnings are not printed. There is nowhere to put them until Phase
    // 10's `/config` renders a notice block, and a shell that opens with four
    // lines of scrollback about a keymap would be worse than one that is
    // quietly using the defaults. `--debug-config` is where they are visible
    // today.
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
        .terminal = &terminal,
        .screen = screen,
        .renderer = &renderer,
        .editor = &editor,
        .history = &history,
        .queue = &queue,
        .waker = &waker,
        .bus = &bus,
        .keymap = &keymap,
        .provider = setup.provider,
    };
    try bus.subscribe(.{ .context = &session, .handler = Session.onEvent });

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
    /// the session — which holds a pointer to this field — sees the change.
    keymap: keymap_mod.Keymap = undefined,
    bus: core.Bus = .{},
    session: Session = undefined,

    fn init(self: *Harness) void {
        const caps: renderer_mod.Capabilities = .{
            .color = .none,
            .kitty_keyboard = true,
            .synchronized_output = false,
            .bracketed_paste = true,
            .size = .{ .cols = 40, .rows = 12 },
        };
        self.renderer = .init(testing.allocator, caps, caps.size);
        self.editor = .init(testing.allocator);
        self.history = .init(testing.allocator, undefined, null);
        self.keymap = .defaults(true);
        self.bus = .{};
        self.session = .{
            .io = undefined,
            .terminal = undefined,
            .screen = undefined,
            .renderer = &self.renderer,
            .editor = &self.editor,
            .history = &self.history,
            .queue = undefined,
            .waker = undefined,
            .bus = &self.bus,
            .keymap = &self.keymap,
            .provider = null,
        };
    }

    fn deinit(self: *Harness) void {
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
