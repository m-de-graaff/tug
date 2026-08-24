//! Waiting, and being woken.
//!
//! Two facilities, one file, because they are two halves of the same thing: the
//! loop blocks in `wait` until something happens, and `Waker` is how anything
//! that is not the terminal makes something happen.
//!
//! `wait` has two callers and that is the point. The capability probe waits up
//! to 50 ms for a terminal that may answer neither query; the loop waits until
//! the next render deadline. Both used to be a blocking read, and one of them
//! hung.
//!
//! The waker coalesces: `wake` writes a byte only when no byte is already
//! outstanding. At most one byte is ever in the pipe, so the pipe can never
//! fill, so the write inside the `SIGWINCH` handler can never block — which is
//! the property that makes it legal to call from a signal handler at all.

const builtin = @import("builtin");
const std = @import("std");

pub const Handle = @import("../term/backend.zig").Handle;

const is_windows = builtin.os.tag == .windows;

pub const Error = error{Unexpected};

/// Which handle became readable. Both false means the timeout expired with
/// nothing ready, which is a normal outcome and not an error: it is how the
/// probe learns that a terminal supports nothing, and how the loop learns that
/// a render deadline arrived quietly.
pub const Ready = struct {
    input: bool = false,
    wake: bool = false,
};

/// Blocks until `input` or `wake` is readable, or until `timeout_ms` elapses.
///
/// A null timeout blocks indefinitely. That is not a convenience — it is the
/// idle-CPU budget: with nothing dirty and no input, tug sits in this call
/// consuming nothing at all.
pub fn wait(input: Handle, wake: ?Handle, timeout_ms: ?u32) Error!Ready {
    return if (is_windows)
        waitWindows(input, wake, timeout_ms)
    else
        waitPosix(input, wake, timeout_ms);
}

/// Milliseconds on a monotonic clock, for deadlines.
///
/// `.awake` rather than `.real`: a deadline computed against a wall clock is
/// wrong every time NTP steps the system time, and "wrong" here means either a
/// frame that never paints or a probe that gives up before it asked.
pub fn nowMs(io: std.Io) u64 {
    const milliseconds = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    return @intCast(@max(0, milliseconds));
}

/// The loop's doorbell.
///
/// `wake` is async-signal-safe and may be called from any thread. Everything
/// else runs on the loop thread.
pub const Waker = struct {
    inner: if (is_windows) WindowsWaker else PosixWaker,

    pub fn init() Error!Waker {
        return .{ .inner = try .init() };
    }

    pub fn deinit(self: *Waker) void {
        self.inner.deinit();
    }

    /// The handle to hand `wait` as its `wake` argument.
    pub fn readHandle(self: *const Waker) Handle {
        return self.inner.readHandle();
    }

    /// The handle to hand `Backend.setWakeHandle`. On POSIX the `SIGWINCH`
    /// handler writes one byte here; on Windows it is the same event object,
    /// since there is no signal to forward.
    pub fn writeHandle(self: *const Waker) Handle {
        return self.inner.writeHandle();
    }

    pub fn wake(self: *Waker) void {
        self.inner.wake();
    }

    /// Clears the pending signal. Called by the loop before it inspects
    /// whatever the wake was about, so a wake racing this drain is queued
    /// again rather than lost.
    pub fn drain(self: *Waker) void {
        self.inner.drain();
    }
};

// --- POSIX -----------------------------------------------------------------

const posix = std.posix;

fn waitPosix(input: Handle, wake: ?Handle, timeout_ms: ?u32) Error!Ready {
    var fds: [2]posix.pollfd = .{
        .{ .fd = input, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = wake orelse -1, .events = posix.POLL.IN, .revents = 0 },
    };
    const count: usize = if (wake == null) 1 else 2;

    // `posix.poll` retries EINTR itself, so a signal arriving mid-wait is not
    // returned here. That is harmless rather than a lost wakeup: the handler
    // has already written to the wake pipe, so the retried poll comes back
    // immediately with the wake end readable.
    const timeout: i32 = if (timeout_ms) |ms| @intCast(@min(ms, std.math.maxInt(i32))) else -1;
    const ready_count = posix.poll(fds[0..count], timeout) catch return error.Unexpected;
    if (ready_count == 0) return .{};

    // HUP and ERR count as readable. A terminal that goes away has to wake the
    // loop so it can read the zero-length result and exit, rather than block
    // on a descriptor nothing will ever write to again.
    const readable = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR;
    return .{
        .input = fds[0].revents & readable != 0,
        .wake = count == 2 and fds[1].revents & readable != 0,
    };
}

const PosixWaker = struct {
    read_fd: posix.fd_t,
    write_fd: posix.fd_t,
    pending: std.atomic.Value(bool) = .init(false),

    fn init() Error!PosixWaker {
        var fds: [2]posix.fd_t = undefined;

        // `pipe`, not `pipe2`: macOS is tier-1 and has no `pipe2`, and the
        // coalescing flag removes the reason to want O_NONBLOCK.
        const result = posix.system.pipe(&fds);
        if (posix.errno(result) != .SUCCESS) return error.Unexpected;

        return .{ .read_fd = fds[0], .write_fd = fds[1] };
    }

    fn deinit(self: *PosixWaker) void {
        _ = posix.system.close(self.read_fd);
        _ = posix.system.close(self.write_fd);
    }

    fn readHandle(self: *const PosixWaker) posix.fd_t {
        return self.read_fd;
    }

    fn writeHandle(self: *const PosixWaker) posix.fd_t {
        return self.write_fd;
    }

    fn wake(self: *PosixWaker) void {
        // A byte is already outstanding: the loop has not looked yet, so a
        // second one would tell it nothing the first does not.
        if (self.pending.swap(true, .acq_rel)) return;

        const byte: [1]u8 = .{0};
        _ = posix.system.write(self.write_fd, &byte, 1);
    }

    fn drain(self: *PosixWaker) void {
        // Cleared before the read, not after. A wake landing in between writes
        // a byte this read may or may not collect — and if it does not, the
        // byte stays in the pipe and the next wait returns for it.
        self.pending.store(false, .release);

        var scratch: [16]u8 = undefined;
        _ = posix.read(self.read_fd, &scratch) catch {};
    }
};

// --- Windows ---------------------------------------------------------------

const windows = std.os.windows;

const WAIT_OBJECT_0: windows.DWORD = 0;
const WAIT_TIMEOUT: windows.DWORD = 0x102;
const WAIT_FAILED: windows.DWORD = 0xFFFFFFFF;
const INFINITE: windows.DWORD = 0xFFFFFFFF;

extern "kernel32" fn CreateEventW(
    attributes: ?*anyopaque,
    manual_reset: windows.BOOL,
    initial_state: windows.BOOL,
    name: ?[*:0]const u16,
) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn SetEvent(event: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn ResetEvent(event: windows.HANDLE) callconv(.winapi) windows.BOOL;
extern "kernel32" fn WaitForMultipleObjects(
    count: windows.DWORD,
    handles: [*]const windows.HANDLE,
    wait_all: windows.BOOL,
    milliseconds: windows.DWORD,
) callconv(.winapi) windows.DWORD;

fn waitWindows(input: Handle, wake: ?Handle, timeout_ms: ?u32) Error!Ready {
    var handles: [2]windows.HANDLE = undefined;
    handles[0] = input;
    var count: windows.DWORD = 1;
    if (wake) |handle| {
        handles[1] = handle;
        count = 2;
    }

    const timeout: windows.DWORD = if (timeout_ms) |ms| ms else INFINITE;
    // `.FALSE`, not 0: windows.BOOL is an enum in Zig 0.16, not a c_int.
    const result = WaitForMultipleObjects(count, &handles, .FALSE, timeout);

    if (result == WAIT_TIMEOUT) return .{};
    if (result == WAIT_FAILED) return error.Unexpected;
    if (result >= WAIT_OBJECT_0 + count) return error.Unexpected;

    // Only the first signalled handle is reported, which is all the loop needs:
    // it comes straight back round and waits again.
    return switch (result - WAIT_OBJECT_0) {
        0 => .{ .input = true },
        else => .{ .wake = true },
    };
}

const WindowsWaker = struct {
    event: windows.HANDLE,

    fn init() Error!WindowsWaker {
        // Manual reset, initially unsignalled.
        //
        // An auto-reset event would look like the natural fit — the wait
        // consumes the signal and `SetEvent` coalesces for free — but it makes
        // `drain` a no-op, and then `drain` means two different things on the
        // two platforms. The loop calls `wait` and then `drain`, so under
        // auto-reset the wait consumes the signal the drain was supposed to
        // clear, and any test that drains without waiting first sees a waker
        // that will not go quiet.
        //
        // Manual reset plus an explicit `ResetEvent` gives both platforms one
        // contract: `wake` arms, `drain` disarms, `wait` reports.
        const event = CreateEventW(null, windows.BOOL.TRUE, .FALSE, null) orelse
            return error.Unexpected;
        return .{ .event = event };
    }

    fn deinit(self: *WindowsWaker) void {
        windows.CloseHandle(self.event);
    }

    fn readHandle(self: *const WindowsWaker) windows.HANDLE {
        return self.event;
    }

    fn writeHandle(self: *const WindowsWaker) windows.HANDLE {
        return self.event;
    }

    fn wake(self: *WindowsWaker) void {
        _ = SetEvent(self.event);
    }

    fn drain(self: *WindowsWaker) void {
        // `SetEvent` on an already-signalled manual-reset event is a no-op, so
        // the coalescing the POSIX side gets from its atomic flag is free here.
        _ = ResetEvent(self.event);
    }
};

const testing = std.testing;

test "a waker with nothing pending times out" {
    var waker: Waker = try .init();
    defer waker.deinit();

    const ready = try wait(waker.readHandle(), null, 0);
    try testing.expect(!ready.input);
    try testing.expect(!ready.wake);
}

test "waking makes the handle readable and draining clears it" {
    var waker: Waker = try .init();
    defer waker.deinit();

    waker.wake();
    const woken = try wait(waker.readHandle(), null, 100);
    try testing.expect(woken.input);

    waker.drain();
    const drained = try wait(waker.readHandle(), null, 0);
    try testing.expect(!drained.input);
}

test "repeated wakes coalesce into one pending signal" {
    var waker: Waker = try .init();
    defer waker.deinit();

    for (0..1000) |_| waker.wake();
    waker.drain();

    // One drain clears a thousand wakes, which is what keeps the pipe from ever
    // filling and the signal handler's write from ever blocking.
    const ready = try wait(waker.readHandle(), null, 0);
    try testing.expect(!ready.input);
}

test "the second handle is reported separately from the first" {
    var input: Waker = try .init();
    defer input.deinit();
    var woken: Waker = try .init();
    defer woken.deinit();

    woken.wake();
    const ready = try wait(input.readHandle(), woken.readHandle(), 100);
    try testing.expect(!ready.input);
    try testing.expect(ready.wake);
}

test "waking from another thread reaches the waiter" {
    var waker: Waker = try .init();
    defer waker.deinit();

    const Ringer = struct {
        fn run(target: *Waker) void {
            target.wake();
        }
    };
    const thread = try std.Thread.spawn(.{}, Ringer.run, .{&waker});
    thread.join();

    const ready = try wait(waker.readHandle(), null, 1000);
    try testing.expect(ready.input);
}
