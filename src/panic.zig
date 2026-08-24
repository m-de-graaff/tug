//! The panic handler.
//!
//! A panic in a program that has put the terminal into raw mode leaves the user
//! with a shell that does not echo, does not line-edit, and does not respond to
//! Ctrl+C — the message explaining what went wrong is unreadable in the
//! terminal it broke. So the terminal is restored *before* anything is printed.
//!
//! `restore` is installed by the terminal backend once raw mode is entered and
//! cleared when it is given back. It stays null until then, which is why the
//! hook exists from the first commit and its implementation arrives with the
//! backend.
//!
//! Nothing here phones home, writes a report file, or unwinds. It restores,
//! prints to stderr, and traps.

const builtin = @import("builtin");
const std = @import("std");

/// Must be async-signal-safe and safe to call twice — a panic inside the
/// restore path is exactly the case where it will be called twice.
pub var restore: ?*const fn () void = null;

fn onPanic(message: []const u8, first_trace_address: ?usize) noreturn {
    @branchHint(.cold);
    _ = first_trace_address;

    if (restore) |restore_fn| restore_fn();

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
