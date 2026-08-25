# DR-015: Where each budget is measured, and by what

**Status:** accepted
**Date:** 2026-08-25
**Phase:** 11

## Context

The roadmap states nine budgets and says they are "enforced by CI, not
intentions". By the end of Phase 10, five of them were: binary size,
`--version` latency, zero network code, the freestanding compile, and the CI
wall clock. Four were not, because until Phase 6 gave the shell a prompt there
was nothing to measure them against — cold start, idle RSS, idle CPU, and
leak-freedom over a long session. Two of those four had been measured once, by
hand, on a Linux pty, and recorded in the phase TODO with a note saying so.

Phase 0's own standard is that a gate which has never fired is a decoration.
Phase 11 is where that bill comes due for all four, and each one raised the same
question in a different shape: *what, exactly, is being measured, and from
where?*

## Options

### Cold start

**A. `hyperfine` around a pty.** The phase checklist's own proposal: the shell
emits an invisible marker on becoming interactive, and a harness timestamps it.
`hyperfine` cannot drive a pty by itself, so it would time
`script -qec "tug …" /dev/null`. That puts `script`'s fork and exec inside the
measurement — a millisecond or more against a ten-millisecond budget — with no
honest way to subtract it. It also needs a marker sequence, a parser for it, and
a rule for what the marker does in a normal session.

**B. The binary times itself.** `main` reads the monotonic clock at its first
opportunity; `repl.run` stamps a second timestamp the instant the first frame
has been flushed; the difference is printed and the process exits. No marker, no
parser, no subtraction. What it excludes is `exec` and dynamic loading.

### The allocator under the leak gate

**A. A build option.** `-Dleak-check=true` selects `DebugAllocator`. Explicit,
but it is a knob for a thing that has exactly one correct setting per build
mode, and a knob that is always set one way is a knob somebody will eventually
set the other way by accident.

**B. Keyed to the build mode.** Debug gets `DebugAllocator` and reports a leak
as a nonzero exit; every release mode keeps `smp_allocator` and pays nothing.
No flag, no way to build the wrong combination.

### The size budget

**A. Tighten the ceiling to measured + 10 %.** One number, as the checklist
says. It loses the roadmap's 500 KiB, which is a published promise about v0.1
rather than an observation about it.

**B. Keep both.** The ceiling stays where the roadmap put it; a second, tighter
number records what v0.1 actually costs.

## Decision

**B in all three.**

**The binary times its own cold start.** The interval measured is exactly the
one the budget names — process start to a prompt on screen — and it is measured
by the only party that can see both ends of it. The number it produces is
0.33 ms against a 10 ms budget, so the millisecond `script` would have added is
not a rounding error in it; it is three times the whole measurement. The
exclusion is covered from the other side: `--version` is gated at 0.52 ms by
`hyperfine` on the same static binary, which bounds process spawn and loading
together.

**Debug swaps the allocator.** The roadmap's leak criterion is a
1,000-interaction session under `DebugAllocator`, and a gate needs something to
fail on. A leak becomes a line on stderr and exit 1, which
`scripts/soak-session.sh` reads. `src/main.zig` had carried a comment naming
this task since Phase 6.

**The size budget is a ceiling and a ratchet.** 500 KiB is what v0.1 promised;
211 KiB — the measured 196,984 B plus ten per cent, floored to a whole KiB — is
what v0.1 costs. `scripts/size-gate.sh` is unchanged and still takes its number
from the caller, so both are checked by the same eight lines that have no
opinion of their own.

## Consequences

Four budgets that could only be asserted are now printed by a job on every push,
and each of the four gates was watched to fail on purpose before it was
trusted — a lowered budget for cold start and size, an inverted comparison for
idle, and a deliberate 32-byte leak in `repl.run` for the soak.

`--debug-first-paint` is a fifth hidden debug flag, in the shape of `--caps`,
`--debug-keys` and `--debug-config`. It costs one optional pointer on
`repl.Setup` and an early `return` after the first flush, which is safe because
every resource above that line is released by a `defer`.

The ratchet will be the first thing v0.2 trips over, which is its purpose. A
legitimate increase means editing `size_ratchet_bytes` in `build.zig` and the
matching number in the CI job — two places on purpose, because the second one is
what makes a reviewer look at the first.

**Revisit triggers.** The cold-start measurement becomes wrong the day tug links
anything dynamically, because the loader time it excludes stops being
negligible; at that point A's subtraction problem is worth solving properly.
The allocator decision becomes wrong if a leak ever turns out to be reachable
only in a release build — a `ReleaseSafe` soak would be the answer, not a flag.
And the two size numbers should collapse back into one if the ratchet ever
exceeds the ceiling, which would mean v0.1's promise had been abandoned rather
than kept.

## Rejected, and why

**A CI fuzzing job.** `zig build test --fuzz` starts a server and runs until
interrupted, which a five-minute wall cannot hold. The fuzz *target* is wired up
and its seed corpus replays on every ordinary `zig build test`, which is the
smoke this phase asked for; the roadmap puts the real job in v0.2.

**Scripting the four terminal emulators.** They cannot be scripted — a pty is
not a terminal emulator, and the thing being checked is whether a screen looks
right. `scripts/terminal-matrix.sh` gates every row a pty, a `TERM` value and
`tmux` can produce, and `docs/terminal-matrix.md` records the other four as
unrecorded with the commands that would fill them in. An empty row that says so
is worth more than a green check that means nothing.
