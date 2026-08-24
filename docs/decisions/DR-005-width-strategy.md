# DR-005: Measuring width in codepoints, not grapheme clusters

**Status:** accepted
**Date:** 2026-08-24
**Phase:** 4

## Context

The renderer wraps text itself. That is not a stylistic preference — it is what
lets it know the active tail's physical row count exactly, which is the number
it moves the cursor back over at the start of every repaint. If the width
function disagrees with the terminal by a single cell on a single line, the row
count is wrong, and a repaint that moves up one row too many erases a line of
the user's scrollback. Permanently: scrollback is the one region tug never
rewrites, so there is nothing to redraw it from.

Width is therefore not a cosmetic concern. It is the correctness input to the
one piece of arithmetic in this program that must never be wrong.

The hard part is that "how wide is this text" has no single answer. A terminal
draws grapheme clusters, allocates cells per cluster, and disagrees with other
terminals about how many cells an emoji gets. Unicode's East Asian Width
property answers a related but different question. Every option below is an
approximation of what some specific terminal will do.

## Options

**Byte length.** Free, and wrong for every user who types a non-ASCII
character. A single accented letter puts the row count out.

**Codepoint-level tables, `wcwidth`-style.** A few hundred bytes of sorted
ranges: zero for combining marks and joiners, two for East Asian Wide and
Fullwidth, one for everything else. Correct for CJK, correct for combining
marks, and wrong for emoji sequences joined with U+200D — a family emoji is one
glyph in the terminal and four codepoints here.

**Grapheme-cluster segmentation.** Vendor `zg`, segment properly, and get emoji
right. Costs a dependency, a table an order of magnitude larger, and a
segmentation pass on every wrap — against a 500 KiB binary budget, on a release
whose exit criteria mention neither emoji nor Unicode certification.

## Decision

Codepoint-level tables, with two deliberate coarsenings.

The emoji blocks are treated as uniformly wide rather than enumerated codepoint
by codepoint, and the zero-width table covers combining marks by block rather
than exhaustively. Both trade exactness for about 1.5 KiB of rodata and a table
a person can read.

The coarsening is defensible because terminals themselves disagree about emoji
width — there is no single correct answer to match. The block approximation
matches what the terminals in the v0.1 matrix do, and the failure it produces is
bounded: a ZWJ sequence measures as its parts, so the line wraps early and looks
short. It never produces corrupted scrollback, because the renderer's own count
stays self-consistent with what the renderer emitted. That distinction — wrong
about the terminal versus inconsistent with itself — is the whole reason this is
acceptable at v0.1.

## Consequences

**Easy:** wrapping, the row count, and the property test that guards it are all
pure functions of a table lookup. No allocation, no state, no dependency, and
`tugcore` stays freestanding because none of this is in it.

**Hard:** a family emoji, a flag, or a skin-tone modifier sequence renders
narrower than tug thinks. Anyone who needs that today is on the wrong release.

**Forecloses:** nothing. `codepointWidth` is a leaf function with two callers.

**The revisit trigger** is the v0.9 Unicode certification, which vendors `zg`
for grapheme-aware width. When it lands, this becomes the ASCII fast path in
front of it and the tables go away. If emoji width is reported as a bug before
then, the answer is "v0.9", not a patch to the table — a table maintained by
bug report is a table nobody can reason about.
