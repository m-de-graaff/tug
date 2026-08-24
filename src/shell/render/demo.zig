//! The burst `--debug-render` streams, until Phase 5's mock provider replaces
//! it with something seeded, deterministic and fault-injecting.
//!
//! Markdown-rich on purpose: headings, both list kinds, a fence, inline
//! markers, CJK and an emoji, so one run down the screen touches every width
//! path and every line classification the renderer has.

/// Streamed in small chunks so codepoints split across chunk boundaries and the
/// wrapper has to hold words back — the two things a single `feed` of the whole
/// document would never exercise.
pub const script =
    \\# Bollard pull
    \\
    \\A tugboat's power is rated in **bollard pull** — a tiny vessel, absurdly
    \\overpowered, guiding something a thousand times its mass. That is the
    \\product, and it is why the binary is measured in kilobytes rather than in
    \\megabytes.
    \\
    \\- One static binary, no runtime, no telemetry
    \\- A shell, a loop, two providers, four tools, and a plugin socket
    \\- Everything else is a plugin
    \\
    \\1. Wrap to the terminal's width, and know the row count exactly
    \\2. Repaint the tail, never the scrollback
    \\3. One `write` per frame
    \\
    \\```zig
    \\pub fn main() !void {
    \\    // **not bold** inside a fence
    \\    std.debug.print("ship it\n", .{});
    \\}
    \\```
    \\
    \\日本語のテキストも折り返します。 🚢 And back to *ASCII* again, with a
    \\paragraph long enough to wrap more than once at any sensible width.
    \\
;

/// Bytes per chunk. Seven is prime and smaller than every multi-byte codepoint
/// boundary in the script lines up with, which is the point: it splits them.
pub const chunk_bytes: usize = 7;

/// Chunks fed per frame. Eight at 125 frames a second is about a thousand
/// deltas a second — a firehose by any provider's standard, and what the
/// no-flicker eyeball test wants to be looking at.
pub const chunks_per_frame: usize = 8;
