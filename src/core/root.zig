//! tugcore — the sans-IO core.
//!
//! This module never writes to stdout, never opens a socket, never reads a
//! clock and never calls `exit`. It consumes events and emits events; the
//! frontend supplies every transport, terminal and time source it needs.
//!
//! That discipline is not aspirational. `zig build wasm-check` compiles this
//! module for `wasm32-freestanding` on every CI run, and importing `std.fs`,
//! `std.posix`, `std.Thread` or `std.time` here fails that job. The rule is
//! enforced by the toolchain rather than by memory.
//!
//! The payoff arrives in v0.8: the same module becomes `libtug` behind a C ABI,
//! a Zig package dependency, and `tugcore.wasm` running in a browser tab.

const std = @import("std");

pub const proto = @import("tugproto");
pub const version = @import("version.zig");

test {
    std.testing.refAllDecls(@This());
}
