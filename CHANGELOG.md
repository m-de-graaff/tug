# Changelog

Every entry names what changed and what it costs. Budget changes and toolchain
bumps are changelog events by policy, never silent.

## Unreleased — v0.1 «Hull»

### Milestone 1 «Raw echo» — Phases 0 to 2

**Phase 0, bedrock.** The module graph — `tugproto`, `tugcore`, `tugshell` and
the executable — exists before the code that fills it, and the build enforces
the direction of its imports. Every budget gate runs from this commit: binary
size, `--version` latency, the `wasm32-freestanding` compile of `tugcore`, and
a grep that fails the build on any network import. Each was broken on purpose
and observed failing before being trusted.

**Phase 1, terminal substrate.** Raw mode with `ISIG` off, so Ctrl+C means what
tug decides rather than unconditional death. Capability detection as a pure
function of the environment and probe answers, so the decision logic is
testable without a terminal. Restore reachable from four overlapping callers
and safe in all of them. A tier-2 Windows console backend behind the same
interface (`DR-009`).

**Phase 2, input decoding.** A pure state machine from bytes to `KeyEvent` and
`PasteEvent`: legacy CSI and SS3, Alt-as-ESC-prefix, kitty CSI-u, UTF-8 split
across reads, and unknown sequences swallowed under a length cap. Paste content
is stripped of ESC and C0 before it becomes an event, because a pasted escape
sequence that gets echoed back is a terminal-injection vector.

**Fixed after the fact.** `tug --caps` hung forever on a terminal that answered
neither capability probe. The probe wrote both queries and then blocked in a
read that a silent terminal never satisfies; the 50 ms timeout was printed in
the output and enforced nowhere. Every probe read is now gated on a `poll` with
that deadline, and the budget is spent once across both queries rather than once
per query.

### Milestone 2 «It streams» — Phases 3 and 4

**Phase 3, loop and event bus.** One blocking loop: wait, decode input, drain
the cross-thread queue, publish, render if dirty. It blocks in exactly one
place, and the timeout it waits with is the CPU budget — with nothing dirty and
no half-decoded sequence in hand there is no deadline at all, so an idle tug
consumes nothing. Measured: zero CPU ticks over five seconds parked, at 256 KiB
resident.

A typed event bus in `tugcore`, tagged by the event catalog so the compiler
enforces one payload per name. It has no locks and no allocator, which one
invariant buys: the bus runs on the loop thread only. Anything off that thread
pushes onto a bounded queue in `tugshell` that the loop drains and republishes.

Wakeups are a self-pipe, coalesced so at most one byte is ever outstanding —
which is what makes the write inside the `SIGWINCH` handler unable to block
(`DR-002`). Windows uses an auto-reset event for the same job and is still
tier-2.

The render scheduler caps painting at roughly 125 frames per second no matter
how fast events arrive, and paints immediately on the events that are endings —
a stream finishing, a turn boundary, a resize — because lag at the end of a
response is the kind a reader notices.

Cost: 2,432 bytes of binary, taking it to 118,712 of the 500 KiB budget.

**Also closed.** `scripts/exit-paths.sh` had never been run — it needs a POSIX
pty and tug is developed on Windows. It now runs green against both the Debug
and the shipping build: normal exit, `SIGTERM`, `SIGHUP` and `SIGINT` all give
the terminal back. Part of why it had never run is that `core.autocrlf` checked
it out with CRLF, which `sh` rejects on the `set -eu` line; `.gitattributes` now
pins shell and Zig sources to LF in the working tree.

**Phase 4, the renderer.** Markdown streamed into normal scrollback, without
ever rewriting it. The screen has two regions and they never mix: committed
scrollback is printed once and belongs to the terminal from that moment on, and
the active tail is bounded to fit on screen, erased and repainted every frame.
The rows a repaint moves the cursor back over are counted by the same function
that emitted them — called once with a null writer to measure and once with the
real one to draw — because two functions would drift, and drift here erases a
line of your scrollback permanently.

A frame is composed in one buffer and flushed once. That, rather than the
terminal's synchronized-output support, is the flicker-free claim; the DECSET
2026 guards are an optimization on top of it where `DR-004`'s probe says they
are available. A counting writer in the tests makes the one-write rule
something the build checks rather than something the code intends.

Markdown-lite, line-local by design: headings, both list kinds, fences, and
`**bold**`, `*italic*` and `` `code` `` inside a single line. An unmatched
marker stays the characters it is, so a stray asterisk can never style the rest
of a response. Widths are measured per codepoint against East Asian and
zero-width tables (`DR-005`), which is what lets the wrap know its own row count
exactly; grapheme clusters wait for v0.9. One dim row says a response is still
streaming and disappears when it commits (`DR-008`).

Six golden transcripts under `testdata/golden/` pin down what the bytes look
like, and a property test over 400 randomized scripts pins down the arithmetic
under them. `tug --debug-render` streams a hardcoded burst through the whole
thing at about a thousand deltas a second.

Two of this phase's own tests found bugs worth naming. Control characters in a
text delta used to reach the terminal, which makes a stray `ESC` — or U+009B,
its eight-bit form — an escape-sequence injection from whatever the provider
sent, the same attack paste content is already stripped of. And a line that
outgrew the screen before its newline arrived could not be committed, leaving a
tail the cursor-up could no longer reach the top of.

A review pass over the finished branch found eight more, two of them in the row
count itself. A resize made the count a lie in both directions — the terminal
re-wraps the hard lines already on screen, so moving back over the recorded
number either strands rows or erases committed scrollback — and the fix is to
abandon the old tail rather than guess: it becomes scrollback, and the new tail
is drawn below it. The status hint was written unwrapped and counted as one row,
so any terminal narrower than it orphaned a fragment per frame; it is now cut to
what fits.

Cost: 13,848 bytes, taking the binary to 132,560 of the 500 KiB budget. Tests
go from 76 to 140.

**Phase 5, the mock provider.** A seeded generator in `tugcore` and a cadence
engine in `tugshell`, either side of the interface v0.2's real providers will
satisfy. A provider is a blocking iterator of `StreamEvent` and nothing else —
an erased context and one function pointer, the same shape the bus already uses
for subscribers. The mock is its first tenant; the seam is the deliverable.

The generator is deterministic to the byte: the same seed produces the same
response on every platform and in every optimize mode, because the only source
of variety is a Xoshiro256 draw over a fixed corpus. It decides *what* is said.
The cadence engine, one layer out where the clock lives, decides how fast it
arrives and where it is cut — the part a real provider will get from the network
instead.

Seven named fault modes: `stall`, `midstream_error`, `oversized_chunk`,
`split_utf8`, `instant`, `firehose` and `empty`. Two are honoured in the core
and the rest in the cadence engine, because a fault about timing or chunk
boundaries cannot be expressed by a module with no clock. Each has a golden
transcript, driven by the real mock through the real cadence into the real
renderer.

Nothing in the loop or the renderer changed to make this work, which is the
claim Phases 3 and 4 were making and this is the first thing to test it. What
did change is the cross-thread queue: a queued payload's slice was borrowed, and
the producer's buffer is reused for the next chunk long before the loop drains
it. Slots now own their bytes — `push` copies in, `pop` copies out, 512 bytes a
slot and 64 slots (`DR-010`). A payload larger than a slot is refused rather
than truncated, and splitting one costs nothing, because a delta cut in two is
two deltas.

**Two liveness bugs, both latent since Phase 3, both found by the firehose.**
Each showed the same way: one frame painted and then a process that looked hung.
The waker lost wakeups — `drain` cleared its pending flag before the read, so a
byte written in that window was collected by that read while the flag stayed
set, after which every `wake` was suppressed as redundant and the loop sat in
`poll` forever. And the queue drain never returned: looping until `pop` comes
back empty is a livelock against any producer that refills the ring mid-drain,
and a loop that never leaves its drain never reaches the paint the frame budget
is expressed in. Ten seconds of firehose on a pty went from 8 KB and zero
repaints to 2.4 MB and seventy.

Both fixes have a test that fails without them. Neither bug is reachable
without a producer faster than the terminal, which is precisely what the fault
mode exists to be.

The frame budget itself now has a number rather than an assertion: half a second
of a real provider thread pushing as fast as the queue will take it paints 37
times in Debug and 34 in ReleaseSafe, against a ceiling of 66. Painting on every
drain instead gives 85, so the test discriminates rather than merely passing.
`scripts/mock-modes.sh` runs each mode through a real pty in CI — the only gate
that exercises `Loop.run`'s own body, which no portable unit test can drive.

`--debug-render` is gone. It was documented in Phase 4 as the last hardcoded
client before this phase replaced it; `--provider mock` is the replacement, with
`--mock-seed`, `--mock-cadence` and `--mock-fault` beside it.

Cost: 7,032 bytes, taking the binary to 139,592 of the 500 KiB budget. Tests go
from 140 to 184.

### Milestone 3 «It edits» — Phase 6

**Phase 6, the editor.** `tug` opens a prompt instead of printing its usage. The
draft is a byte buffer with a codepoint cursor and one kill slot; the emacs set,
multiline editing, and history navigation all reach it through a layer of named
actions rather than through key comparisons, which is the seam Phase 8 rebinds.
`repl.zig` contains no `KeyEvent` comparison outside its tests, and that is a
grep rather than a claim.

`--provider mock` answers every submission, one provider thread per turn, joined
when the turn ends. That is the milestone demo: type, submit, watch a response
stream into scrollback, get the prompt back underneath it.

**The renderer learned where the cursor is** (`DR-011`). A frame records how far
above its parking row it left the caret, and the next frame's rewind is short by
exactly that much. The prompt is hard-wrapped at the column where the rest of
the tail wraps at spaces — word wrap moves the character under your cursor to
another row while you are typing the word in front of it — and a draft taller
than the tail is windowed on the cursor rather than truncated. With no prompt on
screen the offset is zero and every Phase 4 and Phase 5 golden still matches
byte for byte, which is how the change was kept to its own path.

**History** is one entry per line in the XDG state directory, with backslash and
newline escaped so a multiline draft stays one line in the file (`DR-012`).
Appends are a length plus a positional write, because this standard library has
no append mode and no seek. Nothing is read until the first press of `up`.
Every filesystem error is swallowed: a shell that refused to start because
`$HOME` was read-only would be the worse bug.

**`--provider mock` changed meaning**, and it is the only breaking change in the
phase. It used to stream one turn and exit; it now opens a shell. `--once` is
the one-turn path, and it is what `scripts/mock-modes.sh` runs on.

**Fixed after the fact.** Two defects that needed an editor to be visible at
all. `enterRaw` used `TCSAFLUSH`, which discards input that has arrived and not
been read — everything typed between the process starting and raw mode engaging
was thrown away by the terminal driver. And the capability probe swallowed
whatever it read that was not a reply, which on a terminal that answers neither
query is a 50 ms window with a keystroke in it. Both were found by driving the
real binary through a pty, and neither was reachable from a unit test.

**Corrected while building it.** The vertical goal column is sticky: recomputing
it from the cursor on every press makes the caret drift left through short
lines, permanently.

`scripts/editor-session.sh` drives a real session through a pty in CI —
keystrokes, two turns, an interrupt, and a history file read back by a second
process. The in-process goldens under `src/shell/edit/golden.zig` pin the bytes;
the script pins the behaviour they cannot see.

Cost: 15,992 bytes, taking the binary to 155,584 — 30 % of the 500 KiB budget.
Tests go from 185 to 261.

### Not yet

The editor, config, keymaps, themes and commands — Phases 6
to 11. `tug` with no arguments prints its usage rather than pretending to be a
shell. And no terminal emulator has yet watched the renderer stream: the
no-flicker eyeball test in kitty and alacritty is Phase 4's stated exit
criterion and is still open.

### Toolchain

Pinned to Zig 0.16.0 (`DR-001`). Link-time optimization is off: it saved 512
bytes and fails to link on the COFF target.
