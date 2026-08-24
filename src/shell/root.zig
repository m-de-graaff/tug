//! tugshell — the terminal frontend.
//!
//! Everything that knows what a terminal is lives here: raw mode, capability
//! detection, the mode stack, input decoding, and later the renderer, the
//! editor, keymaps and themes.
//!
//! The split from `tugcore` is not stylistic. Core holds logic that a browser
//! tab could run; shell holds the parts that need a tty, a signal, or a file
//! descriptor. When something looks like it belongs in both, it belongs in
//! core with the IO injected.

const std = @import("std");

pub const core = @import("tugcore");
pub const proto = @import("tugproto");

test {
    std.testing.refAllDecls(@This());
}
