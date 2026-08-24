//! tug — the executable.
//!
//! Thin by design: parse arguments, wire the modules, hand control to the
//! frontend. Everything interesting lives in `tugcore` and `tugshell`, which is
//! what makes `libtug` and `tugcore.wasm` possible later without a rewrite.
//!
//! Startup order matters and is load-bearing. `--version` answers before
//! anything else exists, because the 2 ms budget is measured against exactly
//! that path: no allocator, no config, no terminal, no history.

const builtin = @import("builtin");
const std = @import("std");

const core = @import("tugcore");
const shell = @import("tugshell");
const panic_handler = @import("panic.zig");

pub const panic = panic_handler.handler;

/// This program does no networking — in v0.1 by design and afterwards by
/// architecture, since network code lives behind the provider interface and
/// there is no provider yet. Declaring it keeps the socket, DNS and TLS code
/// out of the binary rather than trusting dead code elimination to find all of
/// it.
pub const std_options: std.Options = .{
    .networking = false,
    .http_disable_tls = true,
};

/// Caps the total length of the command line tug will parse. Arguments arrive
/// on Windows as one string that must be split into an owned slice, so this
/// needs an allocator; a stack buffer keeps a real allocator implementation out
/// of the startup path.
///
/// ponytail: past this, argument parsing fails with `error.OutOfMemory`.
/// Windows itself allows roughly twice as much.
const argv_buffer_size = 16 * 1024;

/// Room for the whole environment block, which is read once into a map so the
/// four variables tug cares about cost one pass rather than four.
///
/// ponytail: an environment larger than this degrades to no capability
/// detection at all — 256 colours, no kitty protocol — rather than failing.
const environment_buffer_size = 64 * 1024;

const usage =
    \\tug - Trims Unnecessary Gigabytes | Embeddable AI Harness.
    \\
    \\usage: tug [options]
    \\
    \\options:
    \\  -h, --help       Print this message and exit.
    \\  -V, --version    Print the version and exit.
    \\
    \\provider:
    \\  --provider mock    Answer each turn with a seeded mock response.
    \\  --once             Stream one turn and exit, instead of opening a shell.
    \\  --mock-seed N      Seed the mock (default 0). Same seed, same bytes.
    \\  --mock-cadence C   normal | instant | firehose
    \\  --mock-fault F     none | stall[=ms] | midstream_error | oversized_chunk
    \\                     | split_utf8 | instant | firehose | empty
    \\
    \\debugging:
    \\  --caps             Print detected terminal capabilities and exit.
    \\  --debug-keys       Echo decoded key events until ctrl+c.
    \\  --debug-config     Print the resolved config with provenance and exit.
    \\
;

const Command = enum { help, version, caps, debug_keys, debug_config, mock, shell };

/// Which provider answers a turn. An enum rather than a bool because v0.2 adds
/// two more and this is where they will land.
const Provider = enum { none, mock };

const Options = struct {
    command: Command = .shell,
    provider: Provider = .none,
    /// Stream one turn and exit, instead of opening the shell. The fault
    /// harness runs on this: every mode has to end on its own, and a shell that
    /// waits for a keypress never does.
    once: bool = false,
    mock: core.mock.Config = .{},
    cadence: shell.cadence.Preset = .normal,
};

pub fn main(init: std.process.Init.Minimal) !void {
    // Before any output, including the two paths that never open a terminal.
    shell.backend.useUtf8();
    defer shell.backend.restoreUtf8();

    var argv_buffer: [argv_buffer_size]u8 = undefined;
    var argv_allocator: std.heap.FixedBufferAllocator = .init(&argv_buffer);
    const argv = try init.args.toSlice(argv_allocator.allocator());

    // Separate from the argument buffer because the strings it hands out are
    // borrowed for as long as this function runs.
    var environment_buffer: [environment_buffer_size]u8 = undefined;
    var environment_allocator: std.heap.FixedBufferAllocator = .init(&environment_buffer);

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file.interface;

    const options = parseArgs(argv);
    switch (options.command) {
        .version => {
            try printVersion(stdout);
            return stdout.flush();
        },
        .help => {
            try printUsage(stdout);
            return stdout.flush();
        },
        .caps => {
            try printCapabilities(io, stdout, init.environ, environment_allocator.allocator());
            return stdout.flush();
        },
        .debug_keys => return debugKeys(io, stdout, init.environ, environment_allocator.allocator()),
        .debug_config => {
            try printConfig(io, stdout, init.environ, environment_allocator.allocator());
            return stdout.flush();
        },
        .mock => return runMock(
            io,
            stdout,
            init.environ,
            environment_allocator.allocator(),
            options,
        ),
        .shell => {
            const environment = readEnvironment(init.environ, environment_allocator.allocator());
            const history_path = try shell.history.resolvePath(
                environment_allocator.allocator(),
                environment.state,
                builtin.os.tag == .windows,
            );
            const config_path = try shell.config.userPath(
                environment_allocator.allocator(),
                environment.config,
                builtin.os.tag == .windows,
            );
            return shell.repl.run(
                // The shell is the first thing in tug that lives longer than a
                // turn, and the editor, the history and the renderer all
                // allocate. A general-purpose allocator is what a process that
                // may run for hours wants; Phase 11's DebugAllocator gate over a
                // 1,000-interaction session is what will police it.
                std.heap.smp_allocator,
                io,
                stdout,
                .{
                    .env = environment.caps,
                    .history_path = history_path,
                    .provider = switch (options.provider) {
                        .none => null,
                        .mock => .{ .mock = options.mock, .cadence = options.cadence },
                    },
                    .config = .{
                        .user_path = config_path,
                        .env = environment.config_env,
                    },
                },
            );
        },
    }
}

/// These are debug flags, so a bad value degrades to the default rather than
/// refusing to start: a typo in `--mock-fault` should not be the reason a shell
/// will not open. `--provider` is the only one that decides the command; the
/// rest configure it, and are ignored when no provider was asked for.
fn parseArgs(argv: []const [:0]const u8) Options {
    var options: Options = .{};
    var requested_cadence: shell.cadence.Preset = .normal;

    const args = argv[@min(1, argv.len)..];
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        const value: ?[]const u8 = if (index + 1 < args.len) args[index + 1] else null;

        if (eqlAny(arg, &.{ "--version", "-V" })) return .{ .command = .version };
        if (eqlAny(arg, &.{ "--help", "-h" })) return .{ .command = .help };
        if (eqlAny(arg, &.{"--caps"})) return .{ .command = .caps };
        if (eqlAny(arg, &.{"--debug-keys"})) return .{ .command = .debug_keys };
        if (eqlAny(arg, &.{"--debug-config"})) return .{ .command = .debug_config };

        if (eqlAny(arg, &.{"--once"})) {
            options.once = true;
        } else if (eqlAny(arg, &.{"--provider"})) {
            if (value) |name| {
                if (std.mem.eql(u8, name, "mock")) options.provider = .mock;
                index += 1;
            }
        } else if (eqlAny(arg, &.{"--mock-seed"})) {
            if (value) |text| {
                options.mock.seed = std.fmt.parseInt(u64, text, 10) catch options.mock.seed;
                index += 1;
            }
        } else if (eqlAny(arg, &.{"--mock-fault"})) {
            if (value) |text| {
                parseFault(text, &options.mock);
                index += 1;
            }
        } else if (eqlAny(arg, &.{"--mock-cadence"})) {
            if (value) |text| {
                requested_cadence = shell.cadence.Preset.parse(text) orelse requested_cadence;
                index += 1;
            }
        }
    }

    options.cadence = shell.cadence.presetFor(options.mock.fault, requested_cadence);
    // Decided last, because `--once` and `--provider` can arrive in either
    // order and neither means anything without the other.
    if (options.provider == .mock and options.once) options.command = .mock;
    return options;
}

/// `stall` alone means the default pause; `stall=250` names it. No other fault
/// takes a parameter, and one that did would be parsed here rather than by
/// growing a flag per fault.
fn parseFault(text: []const u8, config: *core.mock.Config) void {
    const split = std.mem.indexOfScalar(u8, text, '=');
    const name = if (split) |at| text[0..at] else text;
    config.fault = core.mock.Fault.parse(name) orelse return;
    if (split) |at| {
        config.stall_ms = std.fmt.parseInt(u32, text[at + 1 ..], 10) catch config.stall_ms;
    }
}

fn eqlAny(arg: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, arg, candidate)) return true;
    }
    return false;
}

/// Writes the version and nothing else. Kept separate from `main` so the test
/// below can prove it touches no allocator.
fn printVersion(out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.writeAll(core.version.string);
    try out.writeAll("\n");
}

/// Everything tug reads from the environment, read once.
const Environment = struct {
    caps: shell.caps.Env = .{},
    state: shell.history.Location = .{},
    config: shell.config.Location = .{},
    /// The `TUG_*` values, indexed by `core.config.env_keys`. Held by index
    /// rather than by name so the loader can apply them without knowing any
    /// variable's spelling — the table is the mapping and the only mapping.
    config_env: [core.config.env_keys.len]?[]const u8 = @splat(null),
};

/// Reads the environment into the pure values the detector, the history and the
/// config want.
///
/// One pass. The detector never sees the environment itself — that separation is
/// what lets the decision logic be table-tested on a machine with no terminal —
/// and the same is true of the history path and the config layer.
///
/// The map is built once and deliberately not deinitialized: the returned
/// values borrow its strings, and `gpa` is a fixed buffer that outlives every
/// use of them. Freeing here would hand back dangling slices.
fn readEnvironment(environ: std.process.Environ, gpa: std.mem.Allocator) Environment {
    var map = environ.createMap(gpa) catch return .{};
    var environment: Environment = .{
        .caps = .{
            // Presence is the signal; the value is explicitly irrelevant.
            .no_color = map.get("NO_COLOR") != null,
            .colorterm = map.get("COLORTERM"),
            .term = map.get("TERM"),
            .tmux = map.get("TMUX") != null,
        },
        .state = .{
            .xdg_state_home = map.get("XDG_STATE_HOME"),
            .home = map.get("HOME"),
            .local_app_data = map.get("LOCALAPPDATA"),
        },
        .config = .{
            .xdg_config_home = map.get("XDG_CONFIG_HOME"),
            .home = map.get("HOME"),
            .app_data = map.get("APPDATA"),
        },
    };

    for (core.config.env_keys, 0..) |entry, index| {
        environment.config_env[index] = map.get(entry.variable);
    }
    return environment;
}

/// The usage text plus the live keymap.
///
/// Generated from `actions.bindings` rather than written out, so a binding
/// added in Phase 8 cannot be missing from the help. Phase 10's `/keys` is the
/// richer version of this — grouped, with the config layer that set each one —
/// and it consumes the same table.
fn printUsage(out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.writeAll(usage);
    try out.writeAll("keys:\n");

    for (shell.actions.bindings) |binding| {
        var chord_buffer: [32]u8 = undefined;
        var chord_writer: std.Io.Writer = .fixed(&chord_buffer);
        binding.chord.writeChord(&chord_writer) catch {};
        const chord = chord_writer.buffered();

        try out.writeAll("  ");
        try out.writeAll(chord);
        // Padded by hand rather than with a width specifier, because a chord
        // can contain a multi-byte character and a byte-counted width would
        // misalign the column it exists to align.
        var pad = shell.width.stringWidth(chord);
        while (pad < 16) : (pad += 1) try out.writeAll(" ");

        try out.writeAll(shell.actions.help(binding.action));
        switch (binding.when) {
            .always => {},
            .kitty => try out.writeAll(" (kitty keyboard protocol only)"),
            .legacy => try out.writeAll(" (without the kitty keyboard protocol)"),
        }
        try out.writeAll("\n");
    }
}

/// The resolved config and every warning, printed without opening a terminal.
///
/// This is Phase 10's `/config` reading the same data through a debug flag, the
/// way `--caps` is Phase 11's terminal-matrix tool arriving early. It is also
/// the only caller of the report writers in v0.1, which is what keeps them from
/// being dead code the linker drops before anybody measures them.
fn printConfig(
    io: std.Io,
    out: *std.Io.Writer,
    environ: std.process.Environ,
    gpa: std.mem.Allocator,
) !void {
    const environment = readEnvironment(environ, gpa);
    const user_path = try shell.config.userPath(
        gpa,
        environment.config,
        builtin.os.tag == .windows,
    );

    var loaded = shell.config.load(gpa, io, .{
        .user_path = user_path,
        .env = environment.config_env,
    });
    defer loaded.deinit(gpa);

    try loaded.config.write(out);
    if (loaded.config.notes().len > 0) {
        try out.writeAll("\n");
        try loaded.config.writeNotes(out, loaded.origins);
    }
}

fn printCapabilities(
    io: std.Io,
    out: *std.Io.Writer,
    environ: std.process.Environ,
    gpa: std.mem.Allocator,
) !void {
    var terminal = shell.backend.open() catch |err| switch (err) {
        error.NotATerminal => {
            try out.writeAll("not a terminal: capabilities are undetectable\n");
            return;
        },
        else => return err,
    };

    // The probes need raw mode, since their replies would otherwise be eaten by
    // the line discipline. Restoring is unconditional and idempotent.
    try terminal.enterRaw();
    defer terminal.restore();

    // `--caps` prints and exits, so anything typed during the probe belongs to
    // whatever runs next, not to tug.
    var probe_buffer: [shell.probe.buffer_bytes]u8 = undefined;
    const probe = shell.probe.run(io, &terminal, &probe_buffer).probe;
    const detected = shell.caps.detect(readEnvironment(environ, gpa).caps, probe, terminal.size());
    try detected.write(out);
    try out.print("probe timeout      {d} ms\n", .{shell.modes.probe_timeout_ms});
}

/// Echoes decoded key events, one line each. The corpus-capture tool for the
/// terminal matrix, and the M1 demo.
fn debugKeys(
    io: std.Io,
    out: *std.Io.Writer,
    environ: std.process.Environ,
    gpa: std.mem.Allocator,
) !void {
    var terminal = shell.backend.open() catch |err| switch (err) {
        error.NotATerminal => {
            try out.writeAll("not a terminal: nothing to decode\n");
            return out.flush();
        },
        else => return err,
    };

    try terminal.enterRaw();
    defer terminal.restore();

    var write_buffer: [1024]u8 = undefined;
    var terminal_writer = terminal.writer(io, &write_buffer);
    const screen = &terminal_writer.interface;

    var stack: shell.modes.Stack = .{};
    defer stack.popAll(screen);

    var probe_buffer: [shell.probe.buffer_bytes]u8 = undefined;
    const probed = shell.probe.run(io, &terminal, &probe_buffer);
    const detected = shell.caps.detect(readEnvironment(environ, gpa).caps, probed.probe, terminal.size());

    if (detected.bracketed_paste) try stack.push(screen, .bracketed_paste);
    if (detected.kitty_keyboard) try stack.push(screen, .kitty_keyboard);

    try screen.writeAll("decoding keys; ctrl+c to stop\r\n");
    try screen.flush();

    var scratch: [4096]u8 = undefined;
    var decoder: shell.Decoder = .init(&scratch);
    decoder.setKittyActive(detected.kitty_keyboard);
    // The corpus-capture tool must not drop the keys it was opened to capture.
    if (probed.leftover.len > 0) decoder.feed(probed.leftover);

    // Everything below is the Phase 3 loop with a two-line client hanging off
    // it. That is the whole point of the phase: the echo is hardcoded, the
    // machinery under it is not, and Phase 4's renderer replaces `onRender`
    // without touching anything else.
    var waker: shell.Waker = try .init();
    defer waker.deinit();
    terminal.setWakeHandle(waker.writeHandle());

    var bus: shell.core.Bus = .{};
    var queue: shell.Queue = .{};
    var scheduler: shell.core.Scheduler = .{};

    var echo: KeyEcho = .{
        .screen = screen,
        .terminal = &terminal,
        .last_size = terminal.size(),
    };

    var loop: shell.Loop = .{
        .io = io,
        .terminal = &terminal,
        .waker = &waker,
        .queue = &queue,
        .bus = &bus,
        .decoder = &decoder,
        .scheduler = &scheduler,
        .handlers = .{
            .context = &echo,
            .onInput = KeyEcho.onInput,
            .onRender = KeyEcho.onRender,
        },
    };

    try loop.run();
    try screen.writeAll("\r\n");
    try screen.flush();
}

/// The `--debug-keys` client: one line per decoded event, and ctrl+c stops.
///
/// Writing happens in `onInput` and flushing in `onRender`, which is not an
/// accident — it is the same split the renderer will use, so the frame budget
/// coalesces a burst of keystrokes into one write rather than one per key.
const KeyEcho = struct {
    screen: *std.Io.Writer,
    terminal: *shell.Backend,
    last_size: shell.Size,
    failed: ?anyerror = null,

    fn onInput(context: ?*anyopaque, event: shell.InputEvent) shell.loop.Flow {
        const self: *KeyEcho = @ptrCast(@alignCast(context.?));

        switch (event) {
            .key => |key_event| {
                if (key_event.mods.ctrl and key_event.key.eql(.{ .char = 'c' })) return .stop;
                key_event.writeChord(self.screen) catch |err| {
                    self.failed = err;
                    return .stop;
                };
                self.screen.writeAll("\r\n") catch |err| {
                    self.failed = err;
                    return .stop;
                };
            },
            .paste => |paste| {
                self.screen.print("paste {d} bytes\r\n", .{paste.bytes.len}) catch |err| {
                    self.failed = err;
                    return .stop;
                };
            },
        }
        return .keep_going;
    }

    /// Reports a resize as well as flushing.
    ///
    /// The size is re-read here rather than carried on the wake, because the
    /// wake carries nothing: `SIGWINCH` writes one byte and the loop asks the
    /// terminal what happened. It is also the only Windows-compatible shape,
    /// since there is no `SIGWINCH` there to carry anything on. Printing it
    /// makes the phase's "wakes on resize" claim something you can watch rather
    /// than something the code asserts about itself.
    fn onRender(context: ?*anyopaque) anyerror!void {
        const self: *KeyEcho = @ptrCast(@alignCast(context.?));
        if (self.failed) |err| return err;

        const current = self.terminal.size();
        if (current.cols != self.last_size.cols or current.rows != self.last_size.rows) {
            try self.screen.print("resize {d}x{d}\r\n", .{ current.cols, current.rows });
            self.last_size = current;
        }

        try self.screen.flush();
    }
};

/// Streams one seeded mock response and exits.
///
/// The wiring the phase is really about. A provider thread pushes onto the
/// Phase-3 queue, the loop drains it onto the bus, a subscriber feeds the
/// Phase-4 renderer, and the loop paints when the scheduler says to. Nothing in
/// the loop knows a provider exists, and nothing in the provider knows a
/// terminal does — which is the claim Phases 3 and 4 were making, tested for
/// the first time here.
fn runMock(
    io: std.Io,
    out: *std.Io.Writer,
    environ: std.process.Environ,
    gpa: std.mem.Allocator,
    options: Options,
) !void {
    var terminal = shell.backend.open() catch |err| switch (err) {
        error.NotATerminal => {
            try out.writeAll("not a terminal: nothing to render into\n");
            return out.flush();
        },
        else => return err,
    };

    try terminal.enterRaw();
    defer terminal.restore();

    // Sized so a whole frame fits without an intermediate flush. That sizing is
    // the one-write-per-frame invariant as it reaches a real terminal; the
    // counting-writer test proves the renderer stays inside it.
    var frame_buffer: [256 * 1024]u8 = undefined;
    var terminal_writer = terminal.writer(io, &frame_buffer);
    const screen = &terminal_writer.interface;

    var stack: shell.modes.Stack = .{};
    defer stack.popAll(screen);

    // One turn and out: nobody is typing into this.
    var probe_buffer: [shell.probe.buffer_bytes]u8 = undefined;
    const probe = shell.probe.run(io, &terminal, &probe_buffer).probe;
    const detected = shell.caps.detect(readEnvironment(environ, gpa).caps, probe, terminal.size());

    var waker: shell.Waker = try .init();
    defer waker.deinit();
    terminal.setWakeHandle(waker.writeHandle());

    var bus: shell.core.Bus = .{};
    var queue: shell.Queue = .{};
    var scheduler: shell.core.Scheduler = .{};

    var scratch: [4096]u8 = undefined;
    var decoder: shell.Decoder = .init(&scratch);

    // The renderer is the first thing in tug that allocates. A one-turn process
    // does not need leak detection on top of what the unit tests already do
    // with `std.testing.allocator`.
    var renderer: shell.Renderer = .init(std.heap.smp_allocator, detected, terminal.size());
    defer renderer.deinit();

    var mock: core.mock.Mock = .init(options.mock);
    var cadence: shell.Cadence = .init(
        options.mock.seed,
        options.cadence,
        options.mock.fault,
        options.mock.stall_ms,
    );
    var stop: std.atomic.Value(bool) = .init(false);

    var provider_runner: shell.Runner = .{
        .io = io,
        .provider = mock.provider(),
        .cadence = &cadence,
        .queue = &queue,
        .waker = &waker,
        .stop = &stop,
    };

    var session: MockSession = .{
        .renderer = &renderer,
        .screen = screen,
        .terminal = &terminal,
    };
    try bus.subscribe(.{ .context = &session, .handler = MockSession.onEvent });

    const thread = try provider_runner.spawn();
    // Ahead of every return below, including the error ones. A thread still
    // pushing onto a queue whose stack frame is gone is the one failure worse
    // than a broken terminal. Setting the flag before joining is what lets a
    // firehose notice while it is parked on backpressure rather than only
    // between events.
    defer {
        stop.store(true, .release);
        thread.join();
    }

    var loop: shell.Loop = .{
        .io = io,
        .terminal = &terminal,
        .waker = &waker,
        .queue = &queue,
        .bus = &bus,
        .decoder = &decoder,
        .scheduler = &scheduler,
        .handlers = .{
            .context = &session,
            .onInput = MockSession.onInput,
            .onRender = MockSession.onRender,
        },
    };

    loop.run() catch |err| switch (err) {
        // Not a failure: it is the only way a one-turn session ends on its own.
        error.TurnFinished => {},
        else => return err,
    };
    try screen.writeAll("\r\n");
    try screen.flush();
}

/// The `--provider mock` client: a bus subscriber and two loop callbacks.
///
/// Note what it does *not* do. It never touches the queue, never asks the
/// provider for anything, and never decides when to paint. It reacts to
/// payloads and draws. That is the shape every future consumer has, and it is
/// why Phase 6's editor can hang off the same callbacks without the loop
/// changing.
const MockSession = struct {
    renderer: *shell.Renderer,
    screen: *std.Io.Writer,
    terminal: *shell.Backend,
    failed: ?anyerror = null,
    finished: bool = false,

    /// The bus hands back `void`, so a failure is stored and re-raised on the
    /// next render rather than swallowed. A subscriber that could return an
    /// error would mean making the bus generic over an error set for the
    /// benefit of one caller.
    fn onEvent(context: ?*anyopaque, payload: shell.proto.Payload) void {
        const self: *MockSession = @ptrCast(@alignCast(context.?));
        self.apply(payload) catch |err| {
            self.failed = err;
        };
    }

    fn apply(self: *MockSession, payload: shell.proto.Payload) !void {
        switch (payload) {
            .request_start => try self.renderer.beginBlock(.assistant),
            .stream_delta => |delta| try self.renderer.feed(delta.text),
            .err => |failure| {
                // A notice block, which commits the partial assistant block
                // above it: whatever the provider managed to say stays on
                // screen, and the reason it stopped goes underneath.
                try self.renderer.beginBlock(.notice);
                try self.renderer.feed(failure.message);
                try self.renderer.feed("\n");
            },
            .stream_end => try self.renderer.endBlock(),
            .turn_end => self.finished = true,
            else => {},
        }
    }

    fn onInput(context: ?*anyopaque, event: shell.InputEvent) shell.loop.Flow {
        _ = context;
        return switch (event) {
            .key => |key_event| if (key_event.mods.ctrl and key_event.key.eql(.{ .char = 'c' }))
                .stop
            else
                .keep_going,
            .paste => .keep_going,
        };
    }

    fn onRender(context: ?*anyopaque) anyerror!void {
        const self: *MockSession = @ptrCast(@alignCast(context.?));
        if (self.failed) |err| return err;

        // Asked for every frame rather than tracked. A resize wakes the loop
        // and carries no payload — `SIGWINCH` writes one byte and nothing else
        // — so one `ioctl` a frame is cheaper than the bookkeeping that would
        // avoid it, and it is the only shape Windows can follow.
        self.renderer.setSize(self.terminal.size());
        _ = try self.renderer.paint(self.screen);
        try self.screen.flush();

        // The turn is over and there is no editor yet to hand control to, so
        // the honest thing is to leave. Phase 6 replaces this with a prompt.
        if (self.finished) return error.TurnFinished;
    }
};

const testing = std.testing;

test "the version fast path writes the built version" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try printVersion(&writer);

    const written = writer.buffered();
    try testing.expect(std.mem.endsWith(u8, written, "\n"));
    try testing.expectEqualStrings(core.version.string, written[0 .. written.len - 1]);
}

test "eqlAny matches any candidate and rejects the rest" {
    try testing.expect(eqlAny("-V", &.{ "--version", "-V" }));
    try testing.expect(eqlAny("--version", &.{ "--version", "-V" }));
    try testing.expect(!eqlAny("--verbose", &.{ "--version", "-V" }));
}

test "commands are recognized and the default is the shell" {
    const cases = [_]struct { args: []const [:0]const u8, want: Command }{
        .{ .args = &.{"tug"}, .want = .shell },
        .{ .args = &.{ "tug", "--version" }, .want = .version },
        .{ .args = &.{ "tug", "-V" }, .want = .version },
        .{ .args = &.{ "tug", "--help" }, .want = .help },
        .{ .args = &.{ "tug", "--caps" }, .want = .caps },
        .{ .args = &.{ "tug", "--debug-keys" }, .want = .debug_keys },
        .{ .args = &.{ "tug", "--debug-config" }, .want = .debug_config },
        // A provider on its own opens the shell; the one-turn path is a flag.
        .{ .args = &.{ "tug", "--provider", "mock" }, .want = .shell },
        .{ .args = &.{ "tug", "--provider", "mock", "--once" }, .want = .mock },
    };
    for (cases) |case| {
        try testing.expectEqual(case.want, parseArgs(case.args).command);
    }
}

test "the provider is remembered whichever command it produced" {
    const shell_session = parseArgs(&.{ "tug", "--provider", "mock" });
    try testing.expectEqual(Command.shell, shell_session.command);
    try testing.expectEqual(Provider.mock, shell_session.provider);

    const one_turn = parseArgs(&.{ "tug", "--provider", "mock", "--once" });
    try testing.expectEqual(Command.mock, one_turn.command);
    try testing.expectEqual(Provider.mock, one_turn.provider);

    const bare = parseArgs(&.{"tug"});
    try testing.expectEqual(Provider.none, bare.provider);
}

test "once without a provider is still just a shell" {
    // There is nothing to do once when nothing answers.
    const options = parseArgs(&.{ "tug", "--once" });
    try testing.expectEqual(Command.shell, options.command);
    try testing.expectEqual(Provider.none, options.provider);
}

test "the flag order does not matter" {
    const before = parseArgs(&.{ "tug", "--once", "--provider", "mock", "--mock-seed", "7" });
    try testing.expectEqual(Command.mock, before.command);
    try testing.expectEqual(@as(u64, 7), before.mock.seed);
}

test "help lists every binding" {
    var buffer: [8 * 1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try printUsage(&writer);
    const text = writer.buffered();

    try testing.expect(std.mem.indexOf(u8, text, "ctrl+a") != null);
    try testing.expect(std.mem.indexOf(u8, text, "send the draft") != null);
    // The fallback is annotated rather than left to be discovered by watching a
    // half-written message send itself (`DR-003`).
    try testing.expect(std.mem.indexOf(u8, text, "alt+enter") != null);
    try testing.expect(std.mem.indexOf(u8, text, "kitty") != null);
}

test "the mock flags parse" {
    const cases = [_]struct {
        args: []const [:0]const u8,
        seed: u64 = 0,
        fault: core.mock.Fault = .none,
        cadence: shell.cadence.Preset = .normal,
    }{
        .{ .args = &.{ "tug", "--provider", "mock", "--once" } },
        .{ .args = &.{ "tug", "--provider", "mock", "--once", "--mock-seed", "42" }, .seed = 42 },
        .{
            .args = &.{ "tug", "--provider", "mock", "--once", "--mock-fault", "split_utf8" },
            .fault = .split_utf8,
        },
        .{
            .args = &.{ "tug", "--provider", "mock", "--once", "--mock-cadence", "instant" },
            .cadence = .instant,
        },
        // A fault with a timing opinion picks its own cadence.
        .{
            .args = &.{ "tug", "--provider", "mock", "--once", "--mock-fault", "firehose" },
            .fault = .firehose,
            .cadence = .firehose,
        },
    };
    for (cases) |case| {
        const options = parseArgs(case.args);
        try testing.expectEqual(Command.mock, options.command);
        try testing.expectEqual(case.seed, options.mock.seed);
        try testing.expectEqual(case.fault, options.mock.fault);
        try testing.expectEqual(case.cadence, options.cadence);
    }
}

test "stall takes an optional millisecond count" {
    const plain = parseArgs(&.{ "tug", "--provider", "mock", "--once", "--mock-fault", "stall" });
    try testing.expectEqual(core.mock.Fault.stall, plain.mock.fault);
    try testing.expectEqual(@as(u32, 1500), plain.mock.stall_ms);

    const explicit = parseArgs(&.{ "tug", "--provider", "mock", "--once", "--mock-fault", "stall=250" });
    try testing.expectEqual(core.mock.Fault.stall, explicit.mock.fault);
    try testing.expectEqual(@as(u32, 250), explicit.mock.stall_ms);
}

test "a bad flag value falls back rather than failing" {
    // A debug flag is not a trust boundary, and a typo in one should not stop
    // the shell from starting. An unparsable value keeps the default.
    const fault = parseArgs(&.{ "tug", "--provider", "mock", "--once", "--mock-fault", "explode" });
    try testing.expectEqual(core.mock.Fault.none, fault.mock.fault);
    const seed = parseArgs(&.{ "tug", "--provider", "mock", "--once", "--mock-seed", "abc" });
    try testing.expectEqual(@as(u64, 0), seed.mock.seed);
}

test "an unknown provider is not the mock" {
    const options = parseArgs(&.{ "tug", "--provider", "anthropic", "--once" });
    try testing.expectEqual(Command.shell, options.command);
    try testing.expectEqual(Provider.none, options.provider);
}
