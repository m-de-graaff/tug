//! The root of `zig build wasm-check`, and the reason it proves anything.
//!
//! `tugcore` compiling for `wasm32-freestanding` is one of v0.1's exit criteria
//! and the gate on v0.4's session substrate staying portable. It was an object
//! built from `src/core/root.zig` — and Zig analyses declarations lazily, so an
//! object with no entry point reaches almost nothing. Adding `std.Thread` to a
//! function nobody calls kept the job green, which was noticed in M3 by trying
//! it rather than by assuming.
//!
//! Forcing every declaration to be analysed is what makes the target real. The
//! job now fails on `std.fs`, `std.posix`, `std.Thread` or a clock appearing
//! anywhere in the module, reachable or not — which is what the criterion always
//! claimed.

const std = @import("std");

const core = @import("tugcore");

/// Zig 0.16's `std.testing` has `refAllDecls` and not a recursive one, and
/// `refAllDecls` stops at the top level — which for a module whose contents are
/// namespaces is almost no coverage at all.
///
/// Depth-bounded because a type can name itself. Four is deeper than this module
/// nests and shallow enough that a cycle cannot outrun it.
fn refAll(comptime T: type, comptime depth: u8) void {
    if (depth == 0) return;
    inline for (comptime std.meta.declarations(T)) |decl| {
        const value = @field(T, decl.name);
        if (@TypeOf(value) == type) {
            switch (@typeInfo(value)) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAll(value, depth - 1),
                else => {},
            }
        }
        _ = &value;
    }
}

comptime {
    refAll(core, 4);
}
