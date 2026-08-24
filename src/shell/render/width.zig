//! How many cells a codepoint occupies.
//!
//! v0.1 measures **codepoints, not grapheme clusters** (`DR-005`). A combining
//! mark is zero cells and its base is one, so `e` + U+0301 measures 1 — which
//! is what a terminal draws. What this cannot do is measure a ZWJ emoji
//! sequence as one glyph: it measures the parts. That is a known, bounded
//! error, and v0.9's grapheme certification is where it gets fixed.
//!
//! Both tables are sorted, non-overlapping, and searched by bisection. They are
//! deliberately coarse in two places, both recorded in `DR-005`: the emoji
//! blocks are treated as uniformly wide rather than enumerated codepoint by
//! codepoint, and the zero-width table covers combining marks by block rather
//! than exhaustively.

const std = @import("std");

/// Codepoints that occupy no cells: combining marks, joiners, directional
/// controls and variation selectors.
const zero_width = [_][2]u21{
    .{ 0x0300, 0x036f }, // combining diacritical marks
    .{ 0x0483, 0x0489 }, // cyrillic
    .{ 0x0591, 0x05bd }, // hebrew points
    .{ 0x05bf, 0x05bf },
    .{ 0x05c1, 0x05c2 },
    .{ 0x05c4, 0x05c5 },
    .{ 0x05c7, 0x05c7 },
    .{ 0x0610, 0x061a }, // arabic
    .{ 0x064b, 0x065f },
    .{ 0x0670, 0x0670 },
    .{ 0x06d6, 0x06dc },
    .{ 0x06df, 0x06e4 },
    .{ 0x06e7, 0x06e8 },
    .{ 0x06ea, 0x06ed },
    .{ 0x0711, 0x0711 }, // syriac
    .{ 0x0730, 0x074a },
    .{ 0x07a6, 0x07b0 }, // thaana
    .{ 0x07eb, 0x07f3 }, // nko
    .{ 0x0816, 0x082d }, // samaritan
    .{ 0x0859, 0x085b }, // mandaic
    .{ 0x08d3, 0x0903 }, // arabic extended through devanagari signs
    .{ 0x093a, 0x093c },
    .{ 0x0941, 0x0948 },
    .{ 0x094d, 0x094d },
    .{ 0x0951, 0x0957 },
    .{ 0x0962, 0x0963 },
    .{ 0x0981, 0x0981 }, // bengali
    .{ 0x09bc, 0x09bc },
    .{ 0x09c1, 0x09c4 },
    .{ 0x09cd, 0x09cd },
    .{ 0x09e2, 0x09e3 },
    .{ 0x0a01, 0x0a02 }, // gurmukhi
    .{ 0x0a3c, 0x0a3c },
    .{ 0x0a41, 0x0a51 },
    .{ 0x0a70, 0x0a71 },
    .{ 0x0a75, 0x0a75 },
    .{ 0x0a81, 0x0a82 }, // gujarati
    .{ 0x0abc, 0x0abc },
    .{ 0x0ac1, 0x0acd },
    .{ 0x0ae2, 0x0ae3 },
    .{ 0x0b01, 0x0b01 }, // oriya
    .{ 0x0b3c, 0x0b3f },
    .{ 0x0b41, 0x0b56 },
    .{ 0x0b62, 0x0b63 },
    .{ 0x0b82, 0x0b82 }, // tamil
    .{ 0x0bc0, 0x0bc0 },
    .{ 0x0bcd, 0x0bcd },
    .{ 0x0c00, 0x0c00 }, // telugu
    .{ 0x0c3e, 0x0c56 },
    .{ 0x0c62, 0x0c63 },
    .{ 0x0c81, 0x0c81 }, // kannada
    .{ 0x0cbc, 0x0cbf },
    .{ 0x0cc6, 0x0ccd },
    .{ 0x0ce2, 0x0ce3 },
    .{ 0x0d00, 0x0d01 }, // malayalam
    .{ 0x0d3b, 0x0d44 },
    .{ 0x0d4d, 0x0d4d },
    .{ 0x0d62, 0x0d63 },
    .{ 0x0dca, 0x0dd6 }, // sinhala
    .{ 0x0e31, 0x0e3a }, // thai
    .{ 0x0e47, 0x0e4e },
    .{ 0x0eb1, 0x0ebc }, // lao
    .{ 0x0ec8, 0x0ecd },
    .{ 0x0f18, 0x0f19 }, // tibetan
    .{ 0x0f35, 0x0f39 },
    .{ 0x0f71, 0x0f87 },
    .{ 0x0f8d, 0x0fbc },
    .{ 0x102d, 0x103e }, // myanmar
    .{ 0x1058, 0x1074 },
    .{ 0x1082, 0x108d },
    .{ 0x135d, 0x135f }, // ethiopic
    .{ 0x1712, 0x1714 }, // philippine
    .{ 0x1732, 0x1734 },
    .{ 0x1752, 0x1753 },
    .{ 0x1772, 0x1773 },
    .{ 0x17b4, 0x17d3 }, // khmer
    .{ 0x17dd, 0x17dd },
    .{ 0x180b, 0x180e }, // mongolian
    .{ 0x1920, 0x193b }, // limbu
    .{ 0x1ab0, 0x1aff }, // combining diacriticals extended
    .{ 0x1b00, 0x1b03 }, // balinese
    .{ 0x1b34, 0x1b42 },
    .{ 0x1b6b, 0x1b73 },
    .{ 0x1dc0, 0x1dff }, // combining diacriticals supplement
    .{ 0x200b, 0x200f }, // zero-width space through RLM, including ZWJ
    .{ 0x202a, 0x202e }, // bidi embedding controls
    .{ 0x2060, 0x206f }, // word joiner, invisible operators, deprecated format
    .{ 0x20d0, 0x20f0 }, // combining marks for symbols
    .{ 0x2cef, 0x2cf1 }, // coptic
    .{ 0x302a, 0x302d }, // ideographic tone marks
    .{ 0x3099, 0x309a }, // kana voicing marks
    .{ 0xfe00, 0xfe0f }, // variation selectors
    .{ 0xfe20, 0xfe2f }, // combining half marks
    .{ 0xfeff, 0xfeff }, // byte order mark
    .{ 0xfff9, 0xfffb }, // interlinear annotation
    .{ 0x1d167, 0x1d169 }, // musical
    .{ 0x1d173, 0x1d182 },
    .{ 0x1d185, 0x1d18b },
    .{ 0x1d1aa, 0x1d1ad },
    .{ 0xe0001, 0xe0001 }, // language tag
    .{ 0xe0020, 0xe007f }, // tag characters
    .{ 0xe0100, 0xe01ef }, // variation selectors supplement
};

/// Codepoints that occupy two cells: East Asian Wide and Fullwidth, plus the
/// emoji blocks.
const wide = [_][2]u21{
    .{ 0x1100, 0x115f }, // hangul jamo initial
    .{ 0x231a, 0x231b },
    .{ 0x2329, 0x232a },
    .{ 0x23e9, 0x23ec },
    .{ 0x23f0, 0x23f0 },
    .{ 0x23f3, 0x23f3 },
    .{ 0x25fd, 0x25fe },
    .{ 0x2614, 0x2615 },
    .{ 0x2648, 0x2653 },
    .{ 0x267f, 0x267f },
    .{ 0x2693, 0x2693 },
    .{ 0x26a1, 0x26a1 },
    .{ 0x26aa, 0x26ab },
    .{ 0x26bd, 0x26be },
    .{ 0x26c4, 0x26c5 },
    .{ 0x26ce, 0x26ce },
    .{ 0x26d4, 0x26d4 },
    .{ 0x26ea, 0x26ea },
    .{ 0x26f2, 0x26f3 },
    .{ 0x26f5, 0x26f5 },
    .{ 0x26fa, 0x26fa },
    .{ 0x26fd, 0x26fd },
    .{ 0x2705, 0x2705 },
    .{ 0x270a, 0x270b },
    .{ 0x2728, 0x2728 },
    .{ 0x274c, 0x274c },
    .{ 0x274e, 0x274e },
    .{ 0x2753, 0x2755 },
    .{ 0x2757, 0x2757 },
    .{ 0x2795, 0x2797 },
    .{ 0x27b0, 0x27b0 },
    .{ 0x27bf, 0x27bf },
    .{ 0x2b1b, 0x2b1c },
    .{ 0x2b50, 0x2b50 },
    .{ 0x2b55, 0x2b55 },
    .{ 0x2e80, 0x303e }, // CJK radicals through ideographic marks
    .{ 0x3041, 0x33ff }, // hiragana through CJK compatibility
    .{ 0x3400, 0x4dbf }, // CJK extension A
    .{ 0x4e00, 0x9fff }, // CJK unified ideographs
    .{ 0xa000, 0xa4cf }, // yi
    .{ 0xa960, 0xa97f }, // hangul jamo extended-A
    .{ 0xac00, 0xd7a3 }, // hangul syllables
    .{ 0xf900, 0xfaff }, // CJK compatibility ideographs
    .{ 0xfe10, 0xfe19 }, // vertical forms
    .{ 0xfe30, 0xfe6f }, // CJK compatibility forms
    .{ 0xff00, 0xff60 }, // fullwidth forms
    .{ 0xffe0, 0xffe6 }, // fullwidth signs
    .{ 0x16fe0, 0x16fe4 }, // tangut and nushu marks
    .{ 0x17000, 0x18cd5 }, // tangut, khitan
    .{ 0x1b000, 0x1b2fb }, // kana supplement, nushu
    .{ 0x1f004, 0x1f004 },
    .{ 0x1f0cf, 0x1f0cf },
    .{ 0x1f18e, 0x1f18e },
    .{ 0x1f191, 0x1f19a },
    .{ 0x1f200, 0x1f320 },
    .{ 0x1f32d, 0x1f335 },
    .{ 0x1f337, 0x1f37c },
    .{ 0x1f37e, 0x1f393 },
    .{ 0x1f3a0, 0x1f3ca },
    .{ 0x1f3cf, 0x1f3d3 },
    .{ 0x1f3e0, 0x1f3f0 },
    .{ 0x1f3f4, 0x1f3f4 },
    .{ 0x1f3f8, 0x1f43e },
    .{ 0x1f440, 0x1f440 },
    .{ 0x1f442, 0x1f4fc },
    .{ 0x1f4ff, 0x1f53d },
    .{ 0x1f54b, 0x1f54e },
    .{ 0x1f550, 0x1f567 },
    .{ 0x1f57a, 0x1f57a },
    .{ 0x1f595, 0x1f596 },
    .{ 0x1f5a4, 0x1f5a4 },
    .{ 0x1f5fb, 0x1f64f },
    .{ 0x1f680, 0x1f6c5 },
    .{ 0x1f6cc, 0x1f6cc },
    .{ 0x1f6d0, 0x1f6d2 },
    .{ 0x1f6d5, 0x1f6d7 },
    .{ 0x1f6eb, 0x1f6ec },
    .{ 0x1f6f4, 0x1f6fc },
    .{ 0x1f7e0, 0x1f7eb },
    .{ 0x1f90c, 0x1f93a },
    .{ 0x1f93c, 0x1f945 },
    .{ 0x1f947, 0x1f9ff },
    .{ 0x1fa70, 0x1fa74 },
    .{ 0x1fa78, 0x1fa7a },
    .{ 0x1fa80, 0x1fa86 },
    .{ 0x1fa90, 0x1faa8 },
    .{ 0x1fab0, 0x1fab6 },
    .{ 0x1fac0, 0x1fac2 },
    .{ 0x1fad0, 0x1fad6 },
    .{ 0x20000, 0x2fffd }, // CJK extension B and beyond
    .{ 0x30000, 0x3fffd },
};

fn inTable(table: []const [2]u21, cp: u21) bool {
    var low: usize = 0;
    var high: usize = table.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (cp < table[mid][0]) {
            high = mid;
        } else if (cp > table[mid][1]) {
            low = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

/// Display cells one codepoint occupies: 0, 1 or 2.
pub fn codepointWidth(cp: u21) u2 {
    // C0, DEL and C1. A terminal draws none of these, and the renderer never
    // emits one, but a text delta can carry one and the wrap arithmetic has to
    // agree with what actually lands on screen.
    if (cp < 0x20) return 0;
    if (cp >= 0x7f and cp < 0xa0) return 0;

    // The overwhelmingly common case, answered before either table is touched.
    if (cp < 0x0300) return 1;

    if (inTable(&zero_width, cp)) return 0;
    if (inTable(&wide, cp)) return 2;
    return 1;
}

/// Display cells a UTF-8 string occupies. Invalid bytes count as one cell each,
/// which is what they will render as (U+FFFD).
pub fn stringWidth(text: []const u8) usize {
    var total: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[index]) catch {
            // An invalid lead byte renders as one replacement character.
            // Advancing by one is what keeps a malformed stream from stalling
            // this loop.
            total += 1;
            index += 1;
            continue;
        };
        if (index + length > text.len) {
            total += 1;
            break;
        }
        const cp = std.unicode.utf8Decode(text[index..][0..length]) catch {
            total += 1;
            index += 1;
            continue;
        };
        total += codepointWidth(cp);
        index += length;
    }
    return total;
}

const testing = std.testing;

test "ascii is one cell" {
    try testing.expectEqual(@as(u2, 1), codepointWidth('a'));
    try testing.expectEqual(@as(u2, 1), codepointWidth(' '));
    try testing.expectEqual(@as(u2, 1), codepointWidth('~'));
}

test "control characters occupy nothing" {
    try testing.expectEqual(@as(u2, 0), codepointWidth(0));
    try testing.expectEqual(@as(u2, 0), codepointWidth('\n'));
    try testing.expectEqual(@as(u2, 0), codepointWidth(0x7f));
    try testing.expectEqual(@as(u2, 0), codepointWidth(0x9f));
}

test "combining marks and joiners occupy nothing" {
    try testing.expectEqual(@as(u2, 0), codepointWidth(0x0301));
    try testing.expectEqual(@as(u2, 0), codepointWidth(0x200d));
    try testing.expectEqual(@as(u2, 0), codepointWidth(0xfe0f));
}

test "east asian wide and fullwidth occupy two cells" {
    try testing.expectEqual(@as(u2, 2), codepointWidth(0x4e00));
    try testing.expectEqual(@as(u2, 2), codepointWidth(0x3042));
    try testing.expectEqual(@as(u2, 2), codepointWidth(0xac00));
    try testing.expectEqual(@as(u2, 2), codepointWidth(0xff21));
    try testing.expectEqual(@as(u2, 2), codepointWidth(0x1f600));
}

test "every wide range is wide at both of its ends" {
    for (wide) |range| {
        try testing.expectEqual(@as(u2, 2), codepointWidth(range[0]));
        try testing.expectEqual(@as(u2, 2), codepointWidth(range[1]));
    }
}

test "string width sums its codepoints" {
    try testing.expectEqual(@as(usize, 5), stringWidth("hello"));
    try testing.expectEqual(@as(usize, 4), stringWidth("日本"));
    try testing.expectEqual(@as(usize, 1), stringWidth("e\u{0301}"));
    try testing.expectEqual(@as(usize, 0), stringWidth(""));
}

test "invalid utf8 counts one cell per bad byte and never loops" {
    try testing.expectEqual(@as(usize, 1), stringWidth("\xff"));
    try testing.expectEqual(@as(usize, 2), stringWidth("\xff\xfe"));
    try testing.expectEqual(@as(usize, 1), stringWidth("\xe4\xb8"));
    try testing.expectEqual(@as(usize, 4), stringWidth("a\xffb\xfe"));
}

test "both tables are sorted and non-overlapping" {
    for ([_][]const [2]u21{ &zero_width, &wide }) |table| {
        for (table, 0..) |range, i| {
            try testing.expect(range[0] <= range[1]);
            if (i > 0) try testing.expect(table[i - 1][1] < range[0]);
        }
    }
}
