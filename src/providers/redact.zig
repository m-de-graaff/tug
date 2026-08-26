//! Scrubbing key-shaped strings out of anything about to be shown to a human.
//!
//! Some APIs echo request metadata back in an error body, and an error body is
//! the one thing in this version that goes straight from a provider to a user's
//! screen and their scrollback. `providers.canary` plants a fake key through
//! every auth path and the tests grep every output surface for it; this is the
//! function that makes those tests pass rather than a promise that they will.
//!
//! Deliberately shape-based rather than value-based. Redacting only the key tug
//! sent would miss the key from the *other* provider, the one in a stale config,
//! and the one a user pasted into a prompt by accident.

const std = @import("std");

/// The prefixes every provider tug speaks to uses for an API key.
///
/// A short list on purpose: this runs over error messages, and matching too
/// eagerly turns a useful sentence into a row of ellipses. New providers add
/// their prefix here, and the canary test is what notices if one is missing.
const key_prefixes = [_][]const u8{ "sk-", "sk_", "api-", "xai-", "gsk_" };

/// How many characters after a prefix make it a key rather than a word.
///
/// Real keys are far longer; twenty is short enough to catch a truncated one and
/// long enough that "sk-" in a sentence about a key is left alone.
const min_key_len = 20;

fn isKeyByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_';
}

/// Copies `text` into `out`, replacing anything key-shaped with `<redacted>`.
///
/// Returns a slice of `out`. Truncates rather than failing: a message too long
/// for the buffer is still worth showing, and this runs on the path where the
/// alternative is showing nothing at all.
pub fn keys(text: []const u8, out: []u8) []const u8 {
    @setRuntimeSafety(true);

    const marker = "<redacted>";
    var written: usize = 0;
    var i: usize = 0;

    while (i < text.len) {
        if (keyLengthAt(text, i)) |len| {
            if (written + marker.len > out.len) break;
            @memcpy(out[written..][0..marker.len], marker);
            written += marker.len;
            i += len;
            continue;
        }

        if (written == out.len) break;
        out[written] = text[i];
        written += 1;
        i += 1;
    }

    return out[0..written];
}

/// The length of the key-shaped run starting at `i`, or null.
fn keyLengthAt(text: []const u8, i: usize) ?usize {
    // A key starts at a boundary. Without this, the "sk_" inside a word would
    // match and the word would vanish.
    if (i > 0 and isKeyByte(text[i - 1])) return null;

    for (key_prefixes) |prefix| {
        if (!std.mem.startsWith(u8, text[i..], prefix)) continue;

        var end = i + prefix.len;
        while (end < text.len and isKeyByte(text[end])) end += 1;

        if (end - i - prefix.len >= min_key_len) return end - i;
    }
    return null;
}

const testing = std.testing;
const canary = @import("canary.zig");

test "the canary does not survive" {
    var buffer: [256]u8 = undefined;
    const scrubbed = keys("invalid key " ++ canary.key ++ ", check the env var", &buffer);

    try testing.expect(!canary.contains(scrubbed));
    try testing.expectEqualStrings("invalid key <redacted>, check the env var", scrubbed);
}

test "a bearer header is scrubbed too" {
    var buffer: [256]u8 = undefined;
    const scrubbed = keys("Authorization: Bearer " ++ canary.key, &buffer);
    try testing.expect(!canary.contains(scrubbed));
}

test "an ordinary sentence about keys is left alone" {
    // The failure mode on the other side: a redactor eager enough to eat the
    // message is a redactor that makes an actionable error unactionable.
    var buffer: [256]u8 = undefined;
    const text = "set ANTHROPIC_API_KEY; keys start with sk- and are long";
    try testing.expectEqualStrings(text, keys(text, &buffer));
}

test "a truncated key is still a key" {
    var buffer: [256]u8 = undefined;
    const scrubbed = keys("sk-ant-api03-aaaaaaaaaaaaaaaaaaaaaa", &buffer);
    try testing.expectEqualStrings("<redacted>", scrubbed);
}

test "a key inside a word is not a match" {
    var buffer: [256]u8 = undefined;
    const text = "wsk-aaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try testing.expectEqualStrings(text, keys(text, &buffer));
}

test "a message longer than the buffer is truncated, not refused" {
    var buffer: [8]u8 = undefined;
    try testing.expectEqualStrings("abcdefgh", keys("abcdefghijkl", &buffer));
}

test "a key that would not fit as a marker ends the copy" {
    var buffer: [6]u8 = undefined;
    const scrubbed = keys("hi " ++ canary.key, &buffer);
    try testing.expect(!canary.contains(scrubbed));
    try testing.expectEqualStrings("hi ", scrubbed);
}
