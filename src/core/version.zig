//! The version string, baked at build time.
//!
//! Read by the `--version` fast path, which must not allocate, open a file, or
//! consult config — the 2 ms budget is measured against exactly that path.

const build_options = @import("build_options");

/// Semantic version of this build, e.g. "0.1.0-dev".
pub const string: []const u8 = build_options.version;

test "version is not empty" {
    try @import("std").testing.expect(string.len > 0);
}
