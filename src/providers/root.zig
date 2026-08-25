//! The provider layer: SSE framing, HTTP transport, and the mappers that turn
//! one API's bytes into `tugproto.StreamEvent`s.
//!
//! This is the only module allowed to touch a socket, and only under
//! `transport/` — see `DR-016` and `scripts/no-network.sh`. Everything above
//! that seam is pure, which is what lets CI drive the whole stack from recorded
//! bytes with no network at all.
//!
//! `tugcore` does not import this module and must not: the core compiles for
//! `wasm32-freestanding`, and nothing in here does.

const std = @import("std");

pub const canary = @import("canary.zig");
pub const sse = @import("sse.zig");
pub const transport = @import("transport.zig");

test {
    std.testing.refAllDecls(@This());
}
