//! The POSIX terminal backend. Tier-1: this is the one that is certified.
//!
//! Two things here are load-bearing and easy to get subtly wrong.
//!
//! **`ISIG` is off.** Ctrl+C arrives as the byte `0x03` rather than as
//! `SIGINT`, so interrupt means what tug decides it means — cancel the current
//! turn, and only quit on a second press with an empty draft. Handing that to
//! the kernel would make it unconditional process death.
//!
//! **Restore has four callers and they can overlap.** Normal exit, a panic, a
//! signal from outside, and any of those arriving twice. The saved termios and
//! the "did we restore yet" flag are therefore process-global and touched
//! through atomics: a signal handler may not take a lock, and a panic inside
//! the restore path must not deadlock against itself.

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;

const backend = @import("backend.zig");

const Size = backend.Size;

pub const Handle = posix.fd_t;
pub const OpenError = error{Unexpected};
pub const RawError = posix.TermiosGetError || posix.TermiosSetError;

/// The terminal state to put back, and whether it still needs putting back.
///
/// Global rather than owned by `Impl` because the signal and panic handlers
/// have no way to reach an instance — they run with whatever the process has,
/// which is this.
var saved_termios: posix.termios = undefined;
var saved_valid: std.atomic.Value(bool) = .init(false);
var terminal_fd: std.atomic.Value(posix.fd_t) = .init(-1);
var wake_handle: std.atomic.Value(posix.fd_t) = .init(-1);

pub const Impl = struct {
    fd: posix.fd_t,

    pub fn enterRaw(self: *Impl) RawError!void {
        const original = try posix.tcgetattr(self.fd);

        saved_termios = original;
        terminal_fd.store(self.fd, .release);
        saved_valid.store(true, .release);

        installSignalHandlers();

        var raw = original;

        // ISIG off: Ctrl+C, Ctrl+Z and Ctrl+\ become bytes we decode rather
        // than signals the kernel acts on.
        raw.lflag.ISIG = false;
        // ICANON off: bytes arrive as they are typed instead of a line at a
        // time.
        raw.lflag.ICANON = false;
        // ECHO off: the renderer draws the input, so the terminal must not.
        raw.lflag.ECHO = false;
        // IEXTEN off: no Ctrl+V literal-next handling behind our back.
        raw.lflag.IEXTEN = false;

        // IXON off: Ctrl+S and Ctrl+Q are chords, not flow control.
        raw.iflag.IXON = false;
        // ICRNL off: Enter must stay 0x0D so it is distinguishable from Ctrl+J.
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.BRKINT = false;

        // OPOST off: the renderer emits exact bytes and counts exact rows;
        // post-processing that silently turns \n into \r\n would break the row
        // accounting the tail repaint depends on.
        raw.oflag.OPOST = false;

        // VMIN=1, VTIME=0: a read blocks until at least one byte is available
        // and then returns immediately. The loop does its waiting in poll, not
        // in read.
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;

        try posix.tcsetattr(self.fd, .FLUSH, raw);
    }

    pub fn restore(self: *Impl) void {
        _ = self;
        restoreGlobal();
    }

    pub fn size(self: *Impl) Size {
        var window: posix.winsize = undefined;
        const result = posix.system.ioctl(self.fd, posix.T.IOCGWINSZ, @intFromPtr(&window));
        if (posix.errno(result) != .SUCCESS) return .fallback;
        if (window.col == 0 or window.row == 0) return .fallback;
        return .{ .cols = window.col, .rows = window.row };
    }

    pub fn setWakeHandle(self: *Impl, handle_value: Handle) void {
        _ = self;
        wake_handle.store(handle_value, .release);
    }

    pub fn handle(self: *Impl) Handle {
        return self.fd;
    }

    pub fn writer(self: *Impl, io: std.Io, buffer: []u8) std.Io.File.Writer {
        return .init(.{ .handle = self.fd, .flags = .{ .nonblocking = false } }, io, buffer);
    }

    pub fn reader(self: *Impl, io: std.Io, buffer: []u8) std.Io.File.Reader {
        return .init(.{ .handle = self.fd, .flags = .{ .nonblocking = false } }, io, buffer);
    }
};

pub fn open() (error{NotATerminal} || OpenError)!Impl {
    const fd = posix.STDIN_FILENO;

    // `tcgetattr` succeeding is the isatty test, and it is the same call raw
    // mode makes first, so this costs nothing extra. It can also fail for
    // reasons that are not "this is a pipe" — a closed controlling terminal,
    // an IO error on the line — which is why `Unexpected` is a real outcome
    // here rather than a placeholder.
    _ = posix.tcgetattr(fd) catch |err| switch (err) {
        error.NotATerminal => return error.NotATerminal,
        else => return error.Unexpected,
    };

    return .{ .fd = fd };
}

/// Nothing to do: a POSIX terminal has no code page to set, it has UTF-8.
pub fn useUtf8() void {}

pub fn restoreUtf8() void {}

/// Puts the terminal back. Safe to call from a signal handler, from a panic,
/// and more than once — which is exactly the set of ways it gets called.
pub fn restoreGlobal() void {
    // Claim the restore. Whoever swaps `true` out does the work; everyone else
    // returns immediately, so a panic during a signal-triggered restore does
    // not recurse.
    if (!saved_valid.swap(false, .acq_rel)) return;

    const fd = terminal_fd.load(.acquire);
    if (fd < 0) return;

    posix.tcsetattr(fd, .FLUSH, saved_termios) catch {};
}

fn onFatalSignal(sig: posix.SIG) callconv(.c) void {
    restoreGlobal();

    // Restore the default disposition and re-raise, so the process dies of what
    // actually killed it and the parent shell sees the right status. Swallowing
    // the signal here would make tug unkillable by ordinary means.
    var default_action: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(sig, &default_action, null);
    posix.raise(sig) catch {};
}

fn onWindowChange(sig: posix.SIG) callconv(.c) void {
    _ = sig;

    // The only async-signal-safe thing a resize handler may do: write one byte
    // to the wake pipe and get out. Re-wrapping the tail happens on the loop
    // thread, where allocation and IO are allowed.
    const fd = wake_handle.load(.acquire);
    if (fd < 0) return;

    const byte: [1]u8 = .{0};
    _ = posix.system.write(fd, &byte, 1);
}

fn installSignalHandlers() void {
    var fatal: posix.Sigaction = .{
        .handler = .{ .handler = onFatalSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    for ([_]posix.SIG{ .TERM, .HUP, .INT, .QUIT }) |sig| {
        posix.sigaction(sig, &fatal, null);
    }

    var winch: posix.Sigaction = .{
        .handler = .{ .handler = onWindowChange },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(.WINCH, &winch, null);
}

test "restore is idempotent when nothing was saved" {
    // The interesting property is that this does not crash and does not touch
    // a file descriptor it does not own.
    saved_valid.store(false, .release);
    restoreGlobal();
    restoreGlobal();
}

test "the fallback size is usable rather than zero" {
    try std.testing.expect(Size.fallback.cols > 0);
    try std.testing.expect(Size.fallback.rows > 0);
}
