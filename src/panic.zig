//! The panic handler.
//!
//! A panic in a program that has put the terminal into raw mode leaves the user
//! with a shell that does not echo, does not line-edit, and does not respond to
//! Ctrl+C — the message explaining what went wrong is unreadable in the
//! terminal it broke. So the terminal is restored *before* anything is printed.
//!
//! The restore itself lives in `tugshell`, which is where the saved terminal
//! state lives; it is idempotent and does nothing when raw mode was never
//! entered, so this handler can call it unconditionally.
//!
//! Nothing here phones home, writes a report file, or unwinds. It restores,
//! prints to stderr, and traps.

const builtin = @import("builtin");
const std = @import("std");

const shell = @import("tugshell");

fn onPanic(message: []const u8, first_trace_address: ?usize) noreturn {
    @branchHint(.cold);
    _ = first_trace_address;

    shell.backend.restoreForPanic();

    var buffer: [256]u8 = undefined;
    const stderr = &std.debug.lockStderr(&buffer).file_writer.interface;
    stderr.writeAll("tug panic: ") catch {};
    stderr.writeAll(message) catch {};
    stderr.writeAll("\n") catch {};
    stderr.flush() catch {};

    @trap();
}

/// Install as `pub const panic` in the root source file.
///
/// Debug builds keep the full handler and its symbolized stack trace, which is
/// worth the size while developing. Release builds get the terse one: a
/// stripped binary has no symbols to walk, and carrying a debug info reader in
/// order to discover that is pure cost.
pub const handler = if (builtin.mode == .Debug)
    std.debug.FullPanic(std.debug.defaultPanic)
else
    std.debug.FullPanic(onPanic);
