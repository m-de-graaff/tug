//! The Windows console backend. Tier-2 — see `DR-009`.
//!
//! The roadmap promises only that tug compiles on Windows until v0.9. This goes
//! one step further and makes it run, because the project is developed on
//! Windows and a binary the author cannot start is a binary nobody dogfoods.
//! What it does not do is promise correctness: Windows is not in the terminal
//! certification matrix, and the kitty keyboard protocol is assumed absent, so
//! the newline chord here is alt+enter.
//!
//! The shape mirrors `posix.zig` exactly, including the global restore state,
//! for the same reason: the panic handler has no instance to reach for.
//!
//! Two POSIX facilities have no counterpart and are handled by absence rather
//! than by emulation. There is no `SIGWINCH`, so resize is discovered by
//! re-reading the console buffer info on the loop's existing wake. There are no
//! signal handlers worth installing, so `SetConsoleCtrlHandler` restores the
//! console on Ctrl+C and Ctrl+Break and then lets the default handler run.

const std = @import("std");
const windows = std.os.windows;

const backend = @import("backend.zig");

const Size = backend.Size;

pub const Handle = windows.HANDLE;
pub const OpenError = error{Unexpected};
pub const RawError = error{Unexpected};

// Zig's std has no console-mode bindings, so the handful tug needs are declared
// here rather than pulled in as a dependency. They are stable Win32 API and
// have not changed since the VT sequences arrived in Windows 10.

const STD_INPUT_HANDLE: windows.DWORD = @bitCast(@as(i32, -10));
const STD_OUTPUT_HANDLE: windows.DWORD = @bitCast(@as(i32, -11));

const ENABLE_PROCESSED_INPUT: windows.DWORD = 0x0001;
const ENABLE_LINE_INPUT: windows.DWORD = 0x0002;
const ENABLE_ECHO_INPUT: windows.DWORD = 0x0004;
const ENABLE_VIRTUAL_TERMINAL_INPUT: windows.DWORD = 0x0200;
const ENABLE_PROCESSED_OUTPUT: windows.DWORD = 0x0001;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: windows.DWORD = 0x0004;
const DISABLE_NEWLINE_AUTO_RETURN: windows.DWORD = 0x0008;

const SMALL_RECT = extern struct {
    Left: windows.SHORT,
    Top: windows.SHORT,
    Right: windows.SHORT,
    Bottom: windows.SHORT,
};

const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: windows.COORD,
    dwCursorPosition: windows.COORD,
    wAttributes: windows.WORD,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: windows.COORD,
};

const HandlerRoutine = *const fn (windows.DWORD) callconv(.winapi) c_int;

extern "kernel32" fn GetStdHandle(nStdHandle: windows.DWORD) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn GetConsoleMode(handle: windows.HANDLE, mode: *windows.DWORD) callconv(.winapi) c_int;
extern "kernel32" fn SetConsoleMode(handle: windows.HANDLE, mode: windows.DWORD) callconv(.winapi) c_int;
extern "kernel32" fn GetConsoleScreenBufferInfo(handle: windows.HANDLE, info: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) c_int;
extern "kernel32" fn SetConsoleCtrlHandler(handler: ?HandlerRoutine, add: c_int) callconv(.winapi) c_int;
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) windows.UINT;
extern "kernel32" fn GetConsoleCP() callconv(.winapi) windows.UINT;
extern "kernel32" fn SetConsoleOutputCP(code_page: windows.UINT) callconv(.winapi) c_int;
extern "kernel32" fn SetConsoleCP(code_page: windows.UINT) callconv(.winapi) c_int;

const CP_UTF8: windows.UINT = 65001;

var saved_input_mode: windows.DWORD = 0;
var saved_output_mode: windows.DWORD = 0;
var saved_input_handle: ?windows.HANDLE = null;
var saved_output_handle: ?windows.HANDLE = null;
var saved_valid: std.atomic.Value(bool) = .init(false);

var saved_output_cp: windows.UINT = 0;
var saved_input_cp: windows.UINT = 0;
var saved_cp_valid: std.atomic.Value(bool) = .init(false);

/// Tells the console that tug's bytes are UTF-8.
///
/// Without this the console decodes output with the machine's OEM code page —
/// 850 on a Dutch install — and every non-ASCII byte tug writes comes out as
/// mojibake: the em dash in the usage text arrives as `ΓÇö`. The input code
/// page matters for the same reason in reverse, since a typed non-ASCII
/// character reaches the decoder as raw bytes.
///
/// Called before anything is written rather than from `enterRaw`, because
/// `--help` and `--version` print without ever opening the terminal.
pub fn useUtf8() void {
    const output_cp = GetConsoleOutputCP();
    const input_cp = GetConsoleCP();
    if (output_cp == 0 or input_cp == 0) return;

    saved_output_cp = output_cp;
    saved_input_cp = input_cp;
    saved_cp_valid.store(true, .release);

    _ = SetConsoleOutputCP(CP_UTF8);
    _ = SetConsoleCP(CP_UTF8);
}

/// Puts the code pages back. A code page outlives the process that changed it,
/// so leaving 65001 behind would change how every later command in that console
/// window decodes its own output. Idempotent, for the same reasons `restore` is.
pub fn restoreUtf8() void {
    if (!saved_cp_valid.swap(false, .acq_rel)) return;
    _ = SetConsoleOutputCP(saved_output_cp);
    _ = SetConsoleCP(saved_input_cp);
}

pub const Impl = struct {
    input: windows.HANDLE,
    output: windows.HANDLE,

    pub fn enterRaw(self: *Impl) RawError!void {
        var input_mode: windows.DWORD = 0;
        var output_mode: windows.DWORD = 0;
        if (GetConsoleMode(self.input, &input_mode) == 0) return error.Unexpected;
        if (GetConsoleMode(self.output, &output_mode) == 0) return error.Unexpected;

        saved_input_mode = input_mode;
        saved_output_mode = output_mode;
        saved_input_handle = self.input;
        saved_output_handle = self.output;
        saved_valid.store(true, .release);

        _ = SetConsoleCtrlHandler(onConsoleCtrl, 1);

        // Line input, echo and processed input are the console's own
        // line editor and Ctrl+C handling. All three are tug's job.
        var raw_input = input_mode;
        raw_input &= ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT | ENABLE_PROCESSED_INPUT);
        // With VT input on, the console delivers the same escape sequences the
        // POSIX decoder already understands, so there is one decoder rather
        // than two.
        raw_input |= ENABLE_VIRTUAL_TERMINAL_INPUT;

        // DISABLE_NEWLINE_AUTO_RETURN is the counterpart of turning OPOST off:
        // the renderer emits exact bytes and counts exact rows, so the console
        // must not insert carriage returns of its own.
        const raw_output = output_mode |
            ENABLE_PROCESSED_OUTPUT |
            ENABLE_VIRTUAL_TERMINAL_PROCESSING |
            DISABLE_NEWLINE_AUTO_RETURN;

        if (SetConsoleMode(self.input, raw_input) == 0) return error.Unexpected;
        if (SetConsoleMode(self.output, raw_output) == 0) return error.Unexpected;
    }

    pub fn restore(self: *Impl) void {
        _ = self;
        restoreGlobal();
    }

    pub fn size(self: *Impl) Size {
        var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (GetConsoleScreenBufferInfo(self.output, &info) == 0) return .fallback;

        // The window rectangle, not the buffer: the buffer is usually taller
        // than the visible area, and wrapping to the buffer height would put
        // the tail somewhere the user cannot see.
        const cols = info.srWindow.Right - info.srWindow.Left + 1;
        const rows = info.srWindow.Bottom - info.srWindow.Top + 1;
        if (cols <= 0 or rows <= 0) return .fallback;
        return .{ .cols = @intCast(cols), .rows = @intCast(rows) };
    }

    pub fn setWakeHandle(self: *Impl, handle_value: Handle) void {
        _ = self;
        _ = handle_value;
        // No SIGWINCH to forward. Resize is discovered by comparing `size()`
        // against the last known one when the loop wakes for any other reason.
    }

    pub fn handle(self: *Impl) Handle {
        return self.input;
    }

    pub fn writer(self: *Impl, io: std.Io, buffer: []u8) std.Io.File.Writer {
        return .init(.{ .handle = self.output, .flags = .{ .nonblocking = false } }, io, buffer);
    }

    pub fn reader(self: *Impl, io: std.Io, buffer: []u8) std.Io.File.Reader {
        return .init(.{ .handle = self.input, .flags = .{ .nonblocking = false } }, io, buffer);
    }
};

pub fn open() (error{NotATerminal} || OpenError)!Impl {
    const input = GetStdHandle(STD_INPUT_HANDLE);
    const output = GetStdHandle(STD_OUTPUT_HANDLE);
    if (input == windows.INVALID_HANDLE_VALUE) return error.NotATerminal;
    if (output == windows.INVALID_HANDLE_VALUE) return error.NotATerminal;

    // GetConsoleMode succeeds only on a real console handle, which makes it the
    // isatty of this platform.
    var mode: windows.DWORD = 0;
    if (GetConsoleMode(input, &mode) == 0) return error.NotATerminal;

    return .{ .input = input, .output = output };
}

pub fn restoreGlobal() void {
    // Unconditional: the code page is set before raw mode is ever entered, so a
    // panic on the `--help` path has one to put back and no console mode to.
    restoreUtf8();

    if (!saved_valid.swap(false, .acq_rel)) return;

    if (saved_input_handle) |handle| _ = SetConsoleMode(handle, saved_input_mode);
    if (saved_output_handle) |handle| _ = SetConsoleMode(handle, saved_output_mode);
}

fn onConsoleCtrl(control_type: windows.DWORD) callconv(.winapi) c_int {
    _ = control_type;
    restoreGlobal();
    // FALSE: run the next handler, which is the default one that terminates
    // the process. Returning TRUE here would make tug unkillable by Ctrl+C
    // from outside, which is the same mistake as swallowing SIGTERM on POSIX.
    return 0;
}

test "restore is idempotent when nothing was saved" {
    saved_cp_valid.store(false, .release);
    saved_valid.store(false, .release);
    restoreGlobal();
    restoreGlobal();
}
