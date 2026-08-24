# DR-008: One dim row while a block streams

**Status:** accepted
**Date:** 2026-08-24
**Phase:** 4

## Context

While a response streams there is nothing else on screen that says tug is
alive. A model that thinks for eight seconds before its first token is
indistinguishable from a hung process, and a harness whose whole pitch is
"instant" cannot afford to look hung.

There is exactly one region where something like this can live. Committed
scrollback is never touched again, so anything written there is permanent —
which rules it out for a message that has to disappear. The active tail is
erased and repainted every frame anyway, so a row there costs nothing to
remove.

The pressure against it is the roadmap: statusline segments are a v0.7 feature
with a config schema and an extension point behind them. Anything shipped here
has to be small enough that v0.7 can delete it without an argument.

## Options

**Nothing.** Honest, and free. Wrong the first time a provider stalls, and the
mock's `stall(ms)` fault mode exists in Phase 5 precisely because that case is
worth rehearsing.

**A spinner.** Needs a timer, and a timer means waking the loop on a schedule
whether or not anything happened. That is the 0 % idle CPU budget — measured,
green, and hard-won in Phase 3 — spent on decoration.

**One dim line in the tail**, repainted with the frame that was going to be
repainted anyway, gone when the block commits.

## Decision

The third. One row reading `... streaming`, dim, at the bottom of the tail
while a block is open.

It costs no timer and no extra wakeups: it is drawn by the frame the scheduler
had already decided to paint, and it disappears through the same erase that
repaints everything else. The text is ASCII deliberately — a status line is the
last place to discover that a terminal disagrees with `DR-005` about a glyph's
width, and an ellipsis character would put the tail's row count at risk to save
two bytes.

## Consequences

**Easy:** the "is it alive" question has an answer with no machinery behind it.

**Hard:** the tail's usable height is `rows - 2` rather than `rows - 1`. That
matters only on terminals under about six rows, where the commit rule is
already doing most of the work.

**The revisit trigger** is v0.7, where statusline segments arrive. At that
point this hint is either their first segment or it is deleted; either is fine,
and the decision belongs to whoever designs the segment schema.

Until then it must not grow a second line, a colour, or a spinner. Each of
those is a statusline feature wearing a disguise, and the reason this record
exists is so that adding one is a decision someone has to make on purpose.
