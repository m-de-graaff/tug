//! Comparing frames against a checked-in transcript.
//!
//! Extracted from the renderer's goldens when the provider's goldens needed the
//! same three things: escape the control bytes so a human can read a diff, find
//! the file under `testdata/golden/`, and print the actual on a mismatch so it
//! can be reviewed and pasted in.
//!
//! There is deliberately still no `--update` flag. A golden that can be
//! refreshed without being read is a golden that records whatever the code did
//! last, which is the opposite of the point.
//!
//! Test-only: nothing outside a test block imports this.

const std = @import("std");
const testing = std.testing;

/// Rewrites a frame so a human can review it in a diff: ESC becomes `\e`, CR
/// becomes `\r`, and LF stays a real newline so the file has real lines.
fn escape(out: *std.ArrayList(u8), gpa: std.mem.Allocator, bytes: []const u8) !void {
    for (bytes) |byte| switch (byte) {
        0x1b => try out.appendSlice(gpa, "\\e"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        else => try out.append(gpa, byte),
    };
}

/// The goldens are read at run time rather than embedded, because `@embedFile`
/// cannot reach outside a module's own directory and `testdata/` is shared with
/// the rest of the repo. `zig build test` runs its binaries from the build root,
/// which is what makes this relative path work.
fn readGolden(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "testdata/golden/{s}.txt", .{name});

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
}

/// Compares `bytes` against `testdata/golden/<name>.txt`.
///
/// On a mismatch the actual transcript goes to stderr framed by
/// `--- golden <name> ---` markers. Read it, satisfy yourself the change is
/// intended, and paste it into the file.
pub fn expectGolden(gpa: std.mem.Allocator, name: []const u8, bytes: []const u8) !void {
    const expected = try readGolden(gpa, name);
    defer gpa.free(expected);

    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(gpa);
    try escape(&actual, gpa, bytes);

    const trimmed = std.mem.trimEnd(u8, actual.items, "\n");
    if (std.mem.eql(u8, std.mem.trimEnd(u8, expected, "\n"), trimmed)) return;

    std.debug.print(
        "\n--- golden {s} ---\n{s}\n--- end golden {s} ---\n",
        .{ name, trimmed, name },
    );
    return error.GoldenMismatch;
}

test "a matching transcript passes and a differing one does not" {
    // `plain` is one of the renderer's own goldens, so this is also a check
    // that the path resolution still works from the build root.
    const expected = try readGolden(testing.allocator, "plain");
    defer testing.allocator.free(expected);

    // Round-trip: unescape what the file holds, and the escaper must put it
    // back byte for byte.
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(testing.allocator);
    var index: usize = 0;
    while (index < expected.len) : (index += 1) {
        if (expected[index] == '\\' and index + 1 < expected.len) {
            switch (expected[index + 1]) {
                'e' => {
                    try raw.append(testing.allocator, 0x1b);
                    index += 1;
                    continue;
                },
                'r' => {
                    try raw.append(testing.allocator, '\r');
                    index += 1;
                    continue;
                },
                else => {},
            }
        }
        try raw.append(testing.allocator, expected[index]);
    }

    try expectGolden(testing.allocator, "plain", raw.items);

    // The other half, and the reason a mismatch report appears on stderr during
    // a *passing* run: without it, a comparator that always returned success
    // would make every golden in the repo vacuous and nothing would say so.
    try testing.expectError(
        error.GoldenMismatch,
        expectGolden(testing.allocator, "plain", "(this mismatch is deliberate)"),
    );
}
