//! Debug-build-only subcommands.
//!
//! `tug dev sse-dump` is the M1 demo and a permanent debugging tool: when a
//! provider misbehaves, the first question is always whether the bytes framed
//! the way the parser thinks they did, and this answers it without a debugger.
//!
//! Not reachable from a release build. These read stdin and write stdout with no
//! terminal setup at all, which also makes them the first thing in tug shaped
//! like Phase 8's pipe frontend — no termios, no probes, no protocol modes.

const std = @import("std");

const sse = @import("tugproviders").sse;

/// The `decode` slot in the Phase 8 exit-code taxonomy (`DR-020`). Spending it
/// here costs nothing and gives the taxonomy one caller before it is written
/// down.
pub const decode_exit_code: u8 = 7;

/// How much is read from stdin at a time. Small on purpose: a dump that only
/// framed correctly because it saw the whole stream at once would be a dump that
/// hides exactly the bug this tool exists to find.
const chunk_size = 4096;

/// One line per event: the event name, the byte length of the data, then the
/// data with its newlines escaped so one event stays one line.
///
/// Length before content because the first question about a delta is usually how
/// big it is, and the second is what is in it.
fn writeEvent(event: sse.ServerEvent, out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.print("event={s} len={d} data=", .{
        // The SSE default when a stream names no event. Printed rather than left
        // blank so a dump reads the same as the specification does.
        if (event.event.len == 0) "message" else event.event,
        event.data.len,
    });

    for (event.data) |byte| switch (byte) {
        '\n' => try out.writeAll("\\n"),
        '\r' => try out.writeAll("\\r"),
        else => try out.writeByte(byte),
    };

    try out.writeByte('\n');
}

/// Raw SSE bytes on stdin, decoded events on stdout. Returns the process exit
/// code: 0 at end of stream, `decode_exit_code` if the stream could not be
/// followed.
pub fn sseDump(io: std.Io, out: *std.Io.Writer) !u8 {
    var read_buffer: [chunk_size]u8 = undefined;
    var stdin: std.Io.File.Reader = .init(.stdin(), io, &read_buffer);

    var scratch: [sse.recommended_scratch]u8 = undefined;
    var data: [sse.recommended_data]u8 = undefined;
    var parser: sse.Parser = .init(&scratch, &data);

    var chunk: [chunk_size]u8 = undefined;
    while (true) {
        // A short read is how end of stream arrives here: `readSliceShort`
        // returns what it got rather than erroring, so zero means the pipe
        // closed.
        const read = try stdin.interface.readSliceShort(&chunk);
        if (read == 0) break;

        parser.feed(chunk[0..read]) catch break;
        while (parser.next()) |event| try writeEvent(event, out);
    }

    // Drain whatever the last feed completed, then report why it stopped if it
    // stopped for a reason. A parser that simply ran out of bytes has no
    // failure, and end of stream is not one.
    while (parser.next()) |event| try writeEvent(event, out);
    try out.flush();

    if (parser.failed()) |failure| {
        var stderr_buffer: [256]u8 = undefined;
        var stderr_file: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
        try stderr_file.interface.print("sse-dump: decode error: {s}\n", .{@errorName(failure)});
        try stderr_file.interface.flush();
        return decode_exit_code;
    }

    return 0;
}

const testing = std.testing;

test "an event renders as one line with its newlines escaped" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeEvent(.{
        .event = "content_block_delta",
        .data = "line one\nline two",
        .id = "",
    }, &writer);

    try testing.expectEqualStrings(
        "event=content_block_delta len=17 data=line one\\nline two\n",
        writer.buffered(),
    );
}

test "an unnamed event prints the specification's default name" {
    var buffer: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writeEvent(.{ .event = "", .data = "hi", .id = "" }, &writer);

    try testing.expectEqualStrings("event=message len=2 data=hi\n", writer.buffered());
}
