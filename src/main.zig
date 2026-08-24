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
const panic_handler = @import("panic.zig");

pub const panic = panic_handler.handler;

/// This program does no networking, in v0.1 by design and afterwards by
/// architecture — network code lives behind the provider interface, and there
/// is no provider yet. Declaring it keeps the socket, DNS and TLS code out of
/// the binary rather than trusting dead code elimination to find all of it.
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

const usage =
    \\tug — a tiny, instant, embeddable AI harness.
    \\
    \\usage: tug [options]
    \\
    \\options:
    \\  -h, --help       Print this message and exit.
    \\  -V, --version    Print the version and exit.
    \\
;

pub fn main(init: std.process.Init.Minimal) !void {
    var argv_buffer: [argv_buffer_size]u8 = undefined;
    var argv_allocator: std.heap.FixedBufferAllocator = .init(&argv_buffer);
    const argv = try init.args.toSlice(argv_allocator.allocator());

    var stdout_buffer: [1024]u8 = undefined;
    var threaded: std.Io.Threaded = .init_single_threaded;
    var stdout_file: std.Io.File.Writer = .init(.stdout(), threaded.io(), &stdout_buffer);
    const stdout = &stdout_file.interface;

    const args = argv[@min(1, argv.len)..];

    for (args) |arg| {
        if (eqlAny(arg, &.{ "--version", "-V" })) {
            try printVersion(stdout);
            return stdout.flush();
        }
        if (eqlAny(arg, &.{ "--help", "-h" })) {
            try stdout.writeAll(usage);
            return stdout.flush();
        }
    }

    // v0.1 Phase 0: nothing else is wired yet. The shell arrives in Phase 1.
    try stdout.writeAll(usage);
    try stdout.flush();
}

fn eqlAny(arg: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.mem.eql(u8, arg, candidate)) return true;
    }
    return false;
}

/// Writes the version and nothing else. Kept separate from `main` so the test
/// below can prove it never reaches an allocator.
fn printVersion(out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.writeAll(core.version.string);
    try out.writeAll("\n");
}

test "the version fast path writes the built version" {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try printVersion(&writer);

    const written = writer.buffered();
    try std.testing.expect(std.mem.endsWith(u8, written, "\n"));
    try std.testing.expectEqualStrings(core.version.string, written[0 .. written.len - 1]);
}

test "eqlAny matches any candidate and rejects the rest" {
    try std.testing.expect(eqlAny("-V", &.{ "--version", "-V" }));
    try std.testing.expect(eqlAny("--version", &.{ "--version", "-V" }));
    try std.testing.expect(!eqlAny("--verbose", &.{ "--version", "-V" }));
}
