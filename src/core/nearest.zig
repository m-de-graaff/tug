//! "Did you mean" — one capped edit distance and the candidate that wins it.
//!
//! Two consumers: an unknown action name in a `[keys]` entry (Phase 8) and an
//! unknown slash command (Phase 10). Both are the same shape — a name that did
//! not resolve, a small fixed list of names that would have, and a person who
//! typed one letter wrong.
//!
//! No allocator and no error set, like everything else in `tugcore`. The two
//! rows are stack arrays of a fixed width, which is what `max_word` is for: it
//! is not a policy about how long a name may be, it is the width of the scratch
//! space, and a word past it is reported as "not close to anything" rather than
//! as an error nobody can act on.

const std = @import("std");
const testing = std.testing;

/// The longest word this compares, and the width of the scratch rows.
/// `kill_to_line_start` is 18 bytes; 32 is that with room to spare and still a
/// pair of arrays small enough to sit on a stack frame without a thought.
pub const max_word: usize = 32;

/// Levenshtein distance — insertions, deletions and substitutions, each one.
///
/// Either word longer than `max_word` returns `max_word + 1`, which is further
/// apart than any threshold accepts. That is the whole of the length handling:
/// no error, no truncation, just a number that means "no".
pub fn distance(a: []const u8, b: []const u8) usize {
    if (a.len > max_word or b.len > max_word) return max_word + 1;
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;

    // Two rows rather than the full matrix: row N depends only on row N-1.
    var previous: [max_word + 1]usize = undefined;
    var current: [max_word + 1]usize = undefined;

    for (previous[0 .. b.len + 1], 0..) |*cell, index| cell.* = index;

    for (a, 0..) |a_byte, a_index| {
        current[0] = a_index + 1;
        for (b, 0..) |b_byte, b_index| {
            const substitution = previous[b_index] + @intFromBool(a_byte != b_byte);
            const deletion = previous[b_index + 1] + 1;
            const insertion = current[b_index] + 1;
            current[b_index + 1] = @min(substitution, @min(deletion, insertion));
        }
        @memcpy(previous[0 .. b.len + 1], current[0 .. b.len + 1]);
    }

    return previous[b.len];
}

/// The candidate closest to `word`, or null when nothing is close enough.
///
/// The threshold is `max(1, len / 3)`: a nine-letter name may be three edits
/// off, a three-letter name one. Without it the nearest candidate is always
/// *some* candidate, and suggesting `yank` for `quit` is worse than silence —
/// it sends a person to read about a thing they did not mean.
///
/// Ties go to the earlier candidate, so the answer is a function of the list
/// the caller passed rather than of an iteration order.
pub fn nearest(candidates: []const []const u8, word: []const u8) ?[]const u8 {
    if (word.len == 0) return null;

    var best: ?[]const u8 = null;
    var best_distance: usize = std.math.maxInt(usize);

    for (candidates) |candidate| {
        const d = distance(candidate, word);
        if (d < best_distance) {
            best_distance = d;
            best = candidate;
        }
    }

    const threshold = @max(1, word.len / 3);
    if (best_distance > threshold) return null;
    return best;
}

test "distance counts the edits, in both directions" {
    try testing.expectEqual(@as(usize, 0), distance("newline", "newline"));
    try testing.expectEqual(@as(usize, 1), distance("newlin", "newline"));
    try testing.expectEqual(@as(usize, 1), distance("newline", "newlyne"));
    // A transposed pair costs two, not one: this is Levenshtein, not
    // Damerau-Levenshtein, and swapping two letters is the commonest typo
    // there is. `sumbit` is still within `submit`'s threshold, which is why
    // the extra operation is not worth the extra row of scratch space it
    // would need.
    try testing.expectEqual(@as(usize, 3), distance("nwelin", "newline"));
    try testing.expectEqual(@as(usize, 2), distance("sumbit", "submit"));
    try testing.expectEqual(@as(usize, 7), distance("", "newline"));
    try testing.expectEqual(@as(usize, 7), distance("newline", ""));
    try testing.expectEqual(@as(usize, 0), distance("", ""));

    // Symmetry, which is the property that makes argument order not matter at
    // the call site.
    try testing.expectEqual(distance("submit", "sumbit"), distance("sumbit", "submit"));
}

test "a word longer than the cap is not close to anything" {
    const long = "a" ** (max_word + 1);
    try testing.expect(distance(long, "a") > max_word);
    try testing.expectEqual(
        @as(?[]const u8, null),
        nearest(&.{ "submit", "newline" }, long),
    );
}

test "a near miss is suggested and a wild guess is not" {
    const candidates = [_][]const u8{ "submit", "newline", "interrupt", "quit", "yank" };

    try testing.expectEqualStrings("newline", nearest(&candidates, "newlin").?);
    try testing.expectEqualStrings("newline", nearest(&candidates, "new_line").?);
    try testing.expectEqualStrings("submit", nearest(&candidates, "sumbit").?);
    try testing.expectEqualStrings("quit", nearest(&candidates, "quiit").?);

    // Nothing within the threshold. Saying nothing beats sending someone to
    // read about an action they did not mean.
    try testing.expectEqual(@as(?[]const u8, null), nearest(&candidates, "xyzzy"));
    try testing.expectEqual(@as(?[]const u8, null), nearest(&candidates, "frobnicate"));
    try testing.expectEqual(@as(?[]const u8, null), nearest(&candidates, ""));
}

test "an exact match is its own suggestion" {
    // The caller never asks about a name that resolved, but a helper that
    // cannot answer this is a helper with a hole in it.
    try testing.expectEqualStrings("quit", nearest(&.{ "quit", "yank" }, "quit").?);
}

test "the first candidate wins a tie, so the answer is not the array's order" {
    // Both are one edit away. Ties resolve to the earlier candidate, which
    // makes the output a function of the candidate list rather than of an
    // iteration order somebody may change.
    try testing.expectEqualStrings("cat", nearest(&.{ "cat", "bat" }, "hat").?);
    try testing.expectEqualStrings("bat", nearest(&.{ "bat", "cat" }, "hat").?);
}

test "an empty candidate list has no answer" {
    try testing.expectEqual(@as(?[]const u8, null), nearest(&.{}, "submit"));
}
