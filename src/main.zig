const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;

const tug = @import("tug");

/// The default panic handler symbolizes the stack, which pulls a debug info
/// reader and the DWARF/PDB parsing that goes with it into the binary. Release
/// builds get a handler that prints the message and aborts instead, which is
/// all the information a stripped binary could give anyway.
pub const panic = if (builtin.mode == .Debug)
    std.debug.FullPanic(std.debug.defaultPanic)
else
    std.debug.simple_panic;

/// This program does no networking. Saying so keeps the socket, DNS and TLS
/// code out of the binary rather than relying on dead code elimination to find
/// all of it, which is worth about 85 KB here.
pub const std_options: std.Options = .{
    .networking = false,
    .http_disable_tls = true,
};

/// Taking `Init.Minimal` rather than the full `std.process.Init` means the
/// runtime does not build a general purpose allocator, a process-wide arena, an
/// environment map or a thread pool before `main` is entered. Nothing here
/// needs them, and each one costs both code and committed pages.
pub fn main(init: std.process.Init.Minimal) !void {
    // A single-threaded `Io` with no allocator behind it.
    //
    // ponytail: this instance cannot allocate, so any `Io` call that needs to
    // (spawning a process, most of `Io.Dir` traversal) will fail rather than
    // work. Swap in `Io.Threaded.init(gpa, .{})` if the program grows into
    // those, and take the thread pool with it.
    var threaded: Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    // Windows hands arguments over as one command line that has to be split
    // into an owned slice, so this needs an allocator. A stack buffer avoids
    // pulling a real allocator implementation in.
    //
    // ponytail: 16 KB caps the total argument length; past that this returns
    // `error.OutOfMemory`. Windows itself allows roughly twice that.
    var args_buffer: [16 * 1024]u8 = undefined;
    var args_allocator: std.heap.FixedBufferAllocator = .init(&args_buffer);
    const args = try init.args.toSlice(args_allocator.allocator());

    // One buffered writer for everything the program has to say. Going through
    // `std.log` or `std.debug.print` instead would pull a second, separately
    // formatted output path into the binary.
    var stdout_buffer: [512]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    try tug.printAnotherMessage(stdout);
    for (args) |arg| {
        try stdout.print("arg: {s}\n", .{arg});
    }

    try stdout.flush(); // Don't forget to flush!
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    try std.testing.fuzz({}, testOne, .{});
}

fn testOne(context: void, smith: *std.testing.Smith) !void {
    _ = context;
    // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!

    const gpa = std.testing.allocator;
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    while (!smith.eos()) switch (smith.value(enum { add_data, dup_data })) {
        .add_data => {
            const slice = try list.addManyAsSlice(gpa, smith.value(u4));
            smith.bytes(slice);
        },
        .dup_data => {
            if (list.items.len == 0) continue;
            if (list.items.len > std.math.maxInt(u32)) return error.SkipZigTest;
            const len = smith.valueRangeAtMost(u32, 1, @min(32, list.items.len));
            const off = smith.valueRangeAtMost(u32, 0, @intCast(list.items.len - len));
            try list.appendSlice(gpa, list.items[off..][0..len]);
            try std.testing.expectEqualSlices(
                u8,
                list.items[off..][0..len],
                list.items[list.items.len - len ..],
            );
        },
    };
}
