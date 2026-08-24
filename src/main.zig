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
const demo_script = @import("shell/render/demo.zig");

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
    \\debugging:
    \\  --caps           Print detected terminal capabilities and exit.
    \\  --debug-keys     Echo decoded key events until ctrl+c.
    \\  --debug-render   Stream a hardcoded markdown burst until ctrl+c.
    \\
;

const Command = enum { help, version, caps, debug_keys, debug_render, shell };

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

    switch (parseCommand(argv)) {
        .version => {
            try printVersion(stdout);
            return stdout.flush();
        },
        .help => {
            try stdout.writeAll(usage);
            return stdout.flush();
        },
        .caps => {
            try printCapabilities(io, stdout, init.environ, environment_allocator.allocator());
            return stdout.flush();
        },
        .debug_keys => return debugKeys(io, stdout, init.environ, environment_allocator.allocator()),
        .debug_render => return debugRender(io, stdout, init.environ, environment_allocator.allocator()),
        .shell => {
            // Phases 3 onward. Until the loop and the renderer exist there is
            // nothing to drop the user into, and pretending otherwise would be
            // worse than saying so.
            try stdout.writeAll(usage);
            return stdout.flush();
        },
    }
}

fn parseCommand(argv: []const [:0]const u8) Command {
    const args = argv[@min(1, argv.len)..];
    for (args) |arg| {
        if (eqlAny(arg, &.{ "--version", "-V" })) return .version;
        if (eqlAny(arg, &.{ "--help", "-h" })) return .help;
        if (eqlAny(arg, &.{"--caps"})) return .caps;
        if (eqlAny(arg, &.{"--debug-render"})) return .debug_render;
        if (eqlAny(arg, &.{"--debug-keys"})) return .debug_keys;
    }
    return .shell;
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

/// Reads the environment into the pure `caps.Env` the detector wants.
///
/// Only these four variables are consulted, and the detector never sees the
/// environment itself — that separation is what lets the decision logic be
/// table-tested on a machine with no terminal.
///
/// The map is built once and deliberately not deinitialized: the returned
/// `Env` borrows its strings, and `gpa` is a fixed buffer that outlives every
/// use of them. Freeing here would hand back dangling slices.
fn readEnv(environ: std.process.Environ, gpa: std.mem.Allocator) shell.caps.Env {
    var map = environ.createMap(gpa) catch return .{};
    return .{
        // Presence is the signal; the value is explicitly irrelevant.
        .no_color = map.get("NO_COLOR") != null,
        .colorterm = map.get("COLORTERM"),
        .term = map.get("TERM"),
        .tmux = map.get("TMUX") != null,
    };
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

    const probe = probeCapabilities(io, &terminal);
    const detected = shell.caps.detect(readEnv(environ, gpa), probe, terminal.size());
    try detected.write(out);
    try out.print("probe timeout      {d} ms\n", .{shell.modes.probe_timeout_ms});
}

/// Asks the terminal what it supports, and takes silence for an answer.
///
/// Every read is gated on `wait`, because a terminal that supports neither
/// protocol answers neither query and the descriptor is in raw mode with
/// `VMIN=1`: a read that is not gated never returns. The whole budget is spent
/// once rather than once per query, so a terminal that answers the first and
/// not the second costs one timeout rather than two.
fn probeCapabilities(io: std.Io, terminal: *shell.Backend) shell.caps.Probe {
    var write_buffer: [64]u8 = undefined;
    var terminal_writer = terminal.writer(io, &write_buffer);
    const out = &terminal_writer.interface;

    out.writeAll(shell.modes.kitty_query) catch return .{};
    out.writeAll(shell.modes.sync_output_query) catch return .{};
    out.flush() catch return .{};

    var read_buffer: [256]u8 = undefined;
    var terminal_reader = terminal.reader(io, &read_buffer);

    var reply_buffer: [256]u8 = undefined;
    var reply_len: usize = 0;
    const deadline = shell.waiting.nowMs(io) + shell.modes.probe_timeout_ms;

    while (reply_len < reply_buffer.len) {
        const now = shell.waiting.nowMs(io);
        if (now >= deadline) break;

        const remaining: u32 = @intCast(deadline - now);
        const ready = shell.waiting.wait(terminal.handle(), null, remaining) catch break;
        if (!ready.input) break;

        const chunk = terminal_reader.interface.peekGreedy(1) catch break;
        if (chunk.len == 0) break;

        const take = @min(chunk.len, reply_buffer.len - reply_len);
        @memcpy(reply_buffer[reply_len..][0..take], chunk[0..take]);
        reply_len += take;
        terminal_reader.interface.toss(chunk.len);

        if (probeRepliesComplete(reply_buffer[0..reply_len])) break;
    }

    const reply = reply_buffer[0..reply_len];
    return .{
        .kitty_keyboard = std.mem.indexOf(u8, reply, "\x1b[?") != null and
            shell.modes.kittyReplyMeansSupported(firstReply(reply)),
        .synchronized_output = std.mem.indexOf(u8, reply, "2026;") != null,
    };
}

/// True once both replies are present, so a terminal that answers promptly
/// costs a round trip rather than the whole 50 ms budget.
///
/// The kitty reply is `CSI ? <flags> u` and the synchronized-output reply is
/// `CSI ? 2026 ; <state> $y`, so `CSI ?` identifies neither of them on its own
/// — the `u` terminator and the mode number are what tell them apart.
///
/// This is only an early exit. Getting it wrong costs the rest of the 50 ms
/// budget; it can never produce a wrong verdict, because the verdict is read
/// from the accumulated bytes either way.
fn probeRepliesComplete(reply: []const u8) bool {
    return std.mem.indexOf(u8, reply, "2026;") != null and
        std.mem.indexOfScalar(u8, reply, 'u') != null;
}

/// The terminal may answer both probes in one read, so split at the second CSI.
fn firstReply(reply: []const u8) []const u8 {
    if (reply.len < 3) return reply;
    if (std.mem.indexOfPos(u8, reply, 1, "\x1b[")) |second| return reply[0..second];
    return reply;
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

    const probe = probeCapabilities(io, &terminal);
    const detected = shell.caps.detect(readEnv(environ, gpa), probe, terminal.size());

    if (detected.bracketed_paste) try stack.push(screen, .bracketed_paste);
    if (detected.kitty_keyboard) try stack.push(screen, .kitty_keyboard);

    try screen.writeAll("decoding keys; ctrl+c to stop\r\n");
    try screen.flush();

    var scratch: [4096]u8 = undefined;
    var decoder: shell.Decoder = .init(&scratch);
    decoder.setKittyActive(detected.kitty_keyboard);

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

/// Streams a hardcoded markdown burst through the renderer until ctrl+c.
///
/// The eyeball test for Phase 4, and the last hardcoded client before Phase 5
/// replaces the script with a real mock provider. Everything below the burst is
/// the Phase 3 loop unchanged: the demo hangs off `onRender` and pushes onto the
/// same queue a provider thread will, so what is being watched is the machinery
/// rather than a special path built to look good.
fn debugRender(
    io: std.Io,
    out: *std.Io.Writer,
    environ: std.process.Environ,
    gpa: std.mem.Allocator,
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

    const probe = probeCapabilities(io, &terminal);
    const detected = shell.caps.detect(readEnv(environ, gpa), probe, terminal.size());

    var waker: shell.Waker = try .init();
    defer waker.deinit();
    terminal.setWakeHandle(waker.writeHandle());

    var bus: shell.core.Bus = .{};
    var queue: shell.Queue = .{};
    var scheduler: shell.core.Scheduler = .{};

    var scratch: [4096]u8 = undefined;
    var decoder: shell.Decoder = .init(&scratch);

    // The renderer is the first thing in tug that allocates. A debug flag that
    // runs for a few seconds and exits does not need leak detection on top of
    // what the unit tests already do with `std.testing.allocator`.
    var renderer: shell.Renderer = .init(std.heap.smp_allocator, detected, terminal.size());
    defer renderer.deinit();
    try renderer.beginBlock(.assistant);

    var demo: RenderDemo = .{
        .io = io,
        .renderer = &renderer,
        .screen = screen,
        .terminal = &terminal,
        .queue = &queue,
        .waker = &waker,
    };

    // The first frame is owed before anything has happened.
    scheduler.markDirty();

    var loop: shell.Loop = .{
        .io = io,
        .terminal = &terminal,
        .waker = &waker,
        .queue = &queue,
        .bus = &bus,
        .decoder = &decoder,
        .scheduler = &scheduler,
        .handlers = .{
            .context = &demo,
            .onInput = RenderDemo.onInput,
            .onRender = RenderDemo.onRender,
        },
    };

    try loop.run();
    try screen.writeAll("\r\n");
    try screen.flush();
}

/// The `--debug-render` client.
///
/// Feeds a few chunks, paints, and then rings the waker with an event on the
/// queue so the loop comes back round. Going through the queue rather than
/// painting in a tight loop is what keeps the frame budget in play: a queued
/// delta marks the scheduler dirty rather than urgent, so the burst coalesces
/// to about 125 frames a second no matter how fast it is fed.
const RenderDemo = struct {
    io: std.Io,
    renderer: *shell.Renderer,
    screen: *std.Io.Writer,
    terminal: *shell.Backend,
    queue: *shell.Queue,
    waker: *shell.Waker,
    offset: usize = 0,
    finished: bool = false,

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
        const self: *RenderDemo = @ptrCast(@alignCast(context.?));

        // Asked for every frame rather than tracked. A resize wakes the loop and
        // carries no payload — `SIGWINCH` writes one byte and nothing else — so
        // one `ioctl` a frame is cheaper than the bookkeeping that would avoid
        // it, and it is the only shape Windows can follow.
        self.renderer.setSize(self.terminal.size());

        for (0..demo_script.chunks_per_frame) |_| {
            if (self.offset >= demo_script.script.len) break;
            const end = @min(self.offset + demo_script.chunk_bytes, demo_script.script.len);
            try self.renderer.feed(demo_script.script[self.offset..end]);
            self.offset = end;
        }
        if (self.offset >= demo_script.script.len and !self.finished) {
            try self.renderer.endBlock();
            self.finished = true;
        }

        _ = try self.renderer.paint(self.screen);
        try self.screen.flush();

        if (self.finished) return;

        // More to say. The queue and the waker are the same pair a provider
        // thread will use in Phase 5.
        self.queue.push(self.io, .{ .stream_delta = .{ .text = "" } }) catch {};
        self.waker.wake();
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
        .{ .args = &.{ "tug", "--debug-render" }, .want = .debug_render },
    };
    for (cases) |case| {
        try testing.expectEqual(case.want, parseCommand(case.args));
    }
}

test "the probe stops early only once both replies have arrived" {
    try testing.expect(!probeRepliesComplete(""));
    try testing.expect(!probeRepliesComplete("\x1b[?3u"));

    // The synchronized-output reply on its own also starts `CSI ?`, so a
    // marker that only looked for that would call this pair complete.
    try testing.expect(!probeRepliesComplete("\x1b[?2026;2$y"));

    try testing.expect(probeRepliesComplete("\x1b[?3u\x1b[?2026;2$y"));
    try testing.expect(probeRepliesComplete("\x1b[?2026;2$y\x1b[?3u"));
}

test "splitting a combined probe reply keeps the first response" {
    try testing.expectEqualStrings("\x1b[?3u", firstReply("\x1b[?3u\x1b[?2026;2$y"));
    try testing.expectEqualStrings("\x1b[?3u", firstReply("\x1b[?3u"));
    try testing.expectEqualStrings("", firstReply(""));
}
