//! tugshell — the terminal frontend.
//!
//! Everything that knows what a terminal is lives here: raw mode, capability
//! detection, the mode stack, input decoding, and later the renderer, the
//! editor, keymaps and themes.
//!
//! The split from `tugcore` is not stylistic. Core holds logic a browser tab
//! could run; shell holds the parts that need a tty, a signal, or a file
//! descriptor. When something looks like it belongs in both, it belongs in core
//! with the IO injected.

const std = @import("std");

pub const core = @import("tugcore");
pub const proto = @import("tugproto");

pub const backend = @import("term/backend.zig");
pub const caps = @import("term/caps.zig");
pub const modes = @import("term/modes.zig");
pub const key = @import("input/key.zig");
pub const decoder = @import("input/decoder.zig");
pub const waiting = @import("loop/wait.zig");
pub const queue = @import("loop/queue.zig");
pub const loop = @import("loop/loop.zig");
pub const width = @import("render/width.zig");
pub const markdown = @import("render/markdown.zig");

pub const Backend = backend.Backend;
pub const Size = backend.Size;
pub const Capabilities = caps.Capabilities;
pub const ColorTier = caps.ColorTier;
pub const Key = key.Key;
pub const Mods = key.Mods;
pub const KeyEvent = key.KeyEvent;
pub const PasteEvent = key.PasteEvent;
pub const InputEvent = key.InputEvent;
pub const Decoder = decoder.Decoder;
pub const Waker = waiting.Waker;
pub const Queue = queue.Queue;
pub const Loop = loop.Loop;

test {
    std.testing.refAllDecls(@This());
}
