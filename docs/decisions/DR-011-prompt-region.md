# DR-011: The prompt is a second wrapper, and the cursor parks inside the tail

**Status:** accepted
**Date:** 2026-08-24
**Phase:** 6

## Context

There is exactly one region of the screen a prompt can live in. Committed
scrollback is never touched again — that is the doctrine the whole renderer
rests on — so anything that has to change as the user types has to be in the
active tail. That much is settled by `DR-008`, which put the status hint there
for the same reason.

The prompt differs from the hint in the two ways that matter. It is taller than
one row, and it grows and shrinks while the user edits. And the cursor has to
end up *inside* it, where the caret belongs, rather than below it.

That second point collides with the invariant every frame since Phase 4 has
rested on. A frame ends by emitting `\r\n` after its last row, so the cursor
parks at column 0 of a fresh row below the tail, and the next frame moves back
exactly `tail_rows` rows to find the tail's top. Leave the cursor somewhere
else and that arithmetic is wrong.

## Options

**The editor writes its own rows and tells the renderer how many.** Rejected.
The row count and the bytes would then be produced by two different pieces of
code, which is precisely the drift the renderer's measure-then-draw discipline
exists to prevent — it calls one function twice, once with a null writer, so the
count and the output cannot disagree. Two functions would drift, and drift here
means erasing a line of the user's scrollback permanently.

**Route the draft through `Renderer.wrap`.** One wrapper, no duplication.
Rejected on the argument below.

**A second, simpler wrapper the renderer owns.** Chosen.

## Decision, part one: the prompt hard-wraps at the column

`wrap` breaks at the last space that fits. That is right for prose and wrong for
a draft: the word under your cursor jumps to the next row as you type the space
in front of it, and the cursor jumps with it. Text moving under a caret that is
not moving is the most disorienting thing an editor can do.

`wrap` also defers emission into a word buffer that is not flushed until the
word ends, so the column at a given byte offset is not known while the word is
still accumulating. Recovering the cursor cell would mean reaching into wrapper
internals that exist for a different purpose.

Every line editor in common use — `readline`, `zsh`'s ZLE, every terminal's own
soft wrap — breaks at the column. Breaking at the column also makes the cursor
cell a running total, which is a variable rather than an inference.

The cost is that a long word in a draft is split mid-word on screen. That is
what `readline` does, and nobody has ever filed a bug about it.

## Decision, part two: the cursor parks inside the tail, and the rewind is short by that much

Each frame records `cursor_up` — how many rows above the parking row it left the
cursor — and the next frame's cursor-previous-line is `tail_rows - cursor_up`
rather than `tail_rows`. With no prompt, `cursor_up` is zero and the arithmetic
is byte-for-byte what Phase 4 shipped; the goldens from that phase are the proof.

The two failure modes this replaces are both worse than they sound. A frame that
still assumed the parking row would move one row too few every time, leaving an
orphaned row on screen that compounds frame after frame. Or, if the tail ever
shrank, it would overshoot into committed scrollback — where `\x1b[0J` erases
lines tug has promised never to touch, and there is no way to redraw them.

A resize is the one case where the tail is abandoned rather than erased, because
a reflowed tail has a row count tug cannot know. The cursor is inside that tail,
so the frame steps *down* to the parking row first with `\x1b[{n}E` before
drawing the new one below. Without that step the new frame would be drawn over
the middle of the old prompt.

The cursor move is emitted inside the synchronized-output window, so a terminal
that honours `2026` never shows the caret at the parking row on its way past.

## Decision, part three: a draft taller than the tail is windowed, not truncated

One paste is enough to exceed the screen, and a tail taller than the screen is
one the cursor-up at the start of the next frame cannot reach the top of. So the
row cap is hard, and what is emitted is the window that contains the cursor —
ending on the cursor's row unless that would scroll past the end of the draft.

Rows scrolled off are still in the buffer. They are not on screen, which is what
every editor does with a document longer than its window.

## Consequences

**Easy:** the caret is where a human expects it; each region's row count is
owned by exactly one function; the no-prompt path is unchanged, so every Phase 4
and Phase 5 golden still matches without being touched.

**Hard:** two wrappers now live in `tugshell`, and someone will eventually try to
merge them. The merge is wrong for the reason in part one, and this record is
the answer to give them.

**Revisit if** Phase 9's themes need styled spans inside the draft. That is the
one thing the hard wrapper cannot do and `wrap` can, and it is the only argument
that should reopen this.
