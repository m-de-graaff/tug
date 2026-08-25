//! A fake API key, planted so that finding it is a failed build.
//!
//! Every auth path in v0.2 gets tested with this value, and every output surface
//! — logs, error messages, `--json`, `/config`, `--debug-wire`, panic reports,
//! checked-in fixtures — gets checked for it. A key that appears where it should
//! not is not a subtle bug to be found at v0.9; it is a red build today.
//!
//! The value is deliberately not valid for any provider and deliberately says
//! canary in the middle, so whoever finds it in a log knows immediately what
//! they are looking at rather than starting a key rotation.
//!
//! Two halves, and both are needed: this constant is the runtime half, asserted
//! in Zig against captured output. `scripts/canary-grep.sh` is the checked-in
//! half, and hunts the same string plus the shapes real keys take.

const std = @import("std");

/// The planted key. Tests inject exactly this; `scripts/canary-grep.sh` hunts
/// exactly this. Changing it means changing both.
pub const key = "sk-tug-canary-0000000000000000000000000000";

/// True when `haystack` leaks the key. For tests that capture an output surface
/// and assert the key is not in it.
pub fn contains(haystack: []const u8) bool {
    return std.mem.indexOf(u8, haystack, key) != null;
}

test "the canary finds itself in a header" {
    try std.testing.expect(contains("Authorization: Bearer " ++ key));
}

test "the canary finds itself mid-sentence" {
    // Error messages are the surface most likely to interpolate a key by
    // accident, and they rarely put it at a boundary.
    try std.testing.expect(contains("auth failed for key " ++ key ++ ", check the env var"));
}

test "an unrelated key-shaped string is clean" {
    try std.testing.expect(!contains("Authorization: Bearer sk-ant-api03-real-looking"));
}

test "a truncated canary is not a match" {
    // A redactor that prints the first eight characters is doing its job; only
    // the whole key is a leak.
    try std.testing.expect(!contains("key sk-tug-c… (redacted)"));
}
