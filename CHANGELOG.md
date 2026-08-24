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

### Milestone 2 «It streams» — Phase 3

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

### Not yet

The renderer, the mock provider, the editor, config, keymaps, themes and
commands — Phases 4 to 11. `tug` with no arguments prints its usage rather than
pretending to be a shell.

### Toolchain

Pinned to Zig 0.16.0 (`DR-001`). Link-time optimization is off: it saved 512
bytes and fails to link on the COFF target.
