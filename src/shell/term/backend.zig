//! The terminal, behind one interface.
//!
//! Two implementations sit under this: `posix.zig`, which is tier-1 and
//! complete, and `windows.zig`, which is tier-2 and exists so the binary can be
//! run on the machine it is developed on. The roadmap only promises that
//! Windows compiles until v0.9; the console backend is a convenience, not a
//! certification, and `DR-009` says so in more detail.
//!
//! Restoring the terminal is the one thing this layer must never get wrong. A
//! process that exits with the terminal still in raw mode leaves a shell that
//! does not echo and does not respond to Ctrl+C, and the user's only recourse
//! is `reset` typed blind. So `restore` is idempotent, async-signal-safe, and
//! reachable from four places: the normal exit path, the panic handler, the
//! signal handlers, and any of those happening twice.

const builtin = @import("builtin");
const std = @import("std");

const is_windows = builtin.os.tag == .windows;

const implementation = if (is_windows)
    @import("windows.zig")
else
    @import("posix.zig");

pub const Size = struct {
    cols: u16,
    rows: u16,

    /// What to assume when the terminal will not say. 80x24 is the historical
    /// default and wrapping to it is never catastrophic; wrapping to 0 is.
    pub const fallback: Size = .{ .cols = 80, .rows = 24 };
};

pub const Handle = implementation.Handle;

pub const OpenError = error{NotATerminal} || implementation.OpenError;
pub const RawError = implementation.RawError;

/// A terminal that has been opened but not necessarily taken over.
pub const Backend = struct {
    inner: implementation.Impl,

    /// Puts the terminal into raw mode and installs the restore paths.
    ///
    /// After this returns, `restore` is reachable from the panic handler and
    /// from the signal handlers, and calling it more than once is safe.
    pub fn enterRaw(self: *Backend) RawError!void {
        return self.inner.enterRaw();
    }

    /// Gives the terminal back. Idempotent: a second call does nothing.
    /// Safe to call from a signal handler and from a panic.
    pub fn restore(self: *Backend) void {
        self.inner.restore();
    }

    pub fn size(self: *Backend) Size {
        return self.inner.size();
    }

    /// The handle to wait on for input readability. On POSIX this is the
    /// terminal's file descriptor; on Windows it is the console input handle,
    /// which is not a descriptor at all — which is why the loop asks the
    /// backend rather than assuming fd 0.
    pub fn handle(self: *Backend) Handle {
        return self.inner.handle();
    }

    /// The fd a resize notification is written to. On POSIX the `SIGWINCH`
    /// handler writes one byte here and does nothing else, which is all an
    /// async-signal-safe handler is allowed to do. Windows has no equivalent
    /// signal, so the backend polls instead.
    pub fn setWakeHandle(self: *Backend, wake_handle: Handle) void {
        self.inner.setWakeHandle(wake_handle);
    }

    /// A writer onto the terminal. Everything the renderer emits goes through
    /// here, one flush per frame.
    pub fn writer(self: *Backend, io: std.Io, buffer: []u8) std.Io.File.Writer {
        return self.inner.writer(io, buffer);
    }

    pub fn reader(self: *Backend, io: std.Io, buffer: []u8) std.Io.File.Reader {
        return self.inner.reader(io, buffer);
    }
};

/// Puts the terminal back from a context that has no `Backend` to hand: the
/// panic handler and, on Windows, the console control handler.
///
/// Idempotent and async-signal-safe, because both of those callers can arrive
/// at any moment and can arrive twice. The executable's panic handler calls
/// this before it prints anything, so the message lands in a terminal that can
/// still display it.
pub fn restoreForPanic() void {
    implementation.restoreGlobal();
}

/// Opens the controlling terminal. Fails with `error.NotATerminal` when stdin
/// is a pipe, which is not an error condition — it is how print mode and
/// `tug -p` will detect that there is no shell to run.
pub fn open() OpenError!Backend {
    return .{ .inner = try implementation.open() };
}

test {
    std.testing.refAllDecls(@This());
}
