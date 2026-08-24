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

Two of this phase's own tests found bugs worth naming. Control bytes in a text
delta used to reach the terminal, which makes a raw `ESC` from a provider an
escape-sequence injection — the same attack paste content is already stripped
of. And a line that outgrew the screen before its newline arrived could not be
committed, leaving a tail the cursor-up could no longer reach the top of.

Cost: 13,280 bytes, taking the binary to 131,992 of the 500 KiB budget. Tests
go from 76 to 134.

### Not yet

The mock provider, the editor, config, keymaps, themes and commands — Phases 5
to 11. `tug` with no arguments prints its usage rather than pretending to be a
shell. And no terminal emulator has yet watched the renderer stream: the
no-flicker eyeball test in kitty and alacritty is Phase 4's stated exit
criterion and is still open.

### Toolchain

Pinned to Zig 0.16.0 (`DR-001`). Link-time optimization is off: it saved 512
bytes and fails to link on the COFF target.
