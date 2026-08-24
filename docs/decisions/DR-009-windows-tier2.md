# DR-009: A running Windows backend, still tier-2

**Status:** accepted
**Date:** 2026-08-24
**Phase:** 1

## Context

The roadmap places Windows at tier-2 until v0.9 and states the obligation
precisely: it must compile. Terminal certification, the matrix pass, and the
`bash` tool's POSIX-shell requirement are all explicitly deferred.

Meanwhile v0.1's terminal substrate is POSIX to the bone — `termios`,
`ioctl(TIOCGWINSZ)`, `SIGWINCH`, `sigaction`. None of it exists on Windows, and
tug is being developed on Windows. Taken literally, "must compile" means the
author cannot start the program they are writing, and the dogfood gate arrives
in v0.3.

## Options

**Compile-only, with the backend stubbed.** `open()` returns
`error.NotATerminal` on Windows and the shell never starts. Honest about the
tier, cheapest to write, and it makes the development machine useless for
anything past `--version`.

**Full Windows parity now.** Certify Windows Terminal, add it to the matrix,
promise the behaviour. This is v0.9 work pulled four versions forward, and it
buys certification nobody asked for at the cost of every phase after this one
carrying two supported platforms instead of one.

**A working backend without a promise.** Implement the console-mode equivalent
of the POSIX one behind the same interface. It runs, it is not certified, and
it stays out of the matrix.

## Decision

The third. `src/shell/term/windows.zig` implements the same `Impl` surface as
`src/shell/term/posix.zig` using `SetConsoleMode` with
`ENABLE_VIRTUAL_TERMINAL_INPUT`, so the console delivers the same escape
sequences the POSIX decoder already parses and there is one decoder rather than
two.

What tier-2 means concretely, so nobody has to infer it:

- Windows compiles and its unit tests pass in CI. That is the promise.
- It is **not** in the terminal certification matrix. No golden test, no
  firehose eyeball test, no flicker guarantee.
- The kitty keyboard protocol is assumed **absent**. Windows Terminal does not
  implement it, so `shift+enter` is indistinguishable from `enter` and the
  newline chord is `alt+enter`. `/keys` shows which one is live.
- There is no `SIGWINCH`. Resize is discovered by comparing the console buffer
  info against the last known size when the loop wakes for any other reason,
  which means a resize with no other input pending is noticed late rather than
  immediately.
- Zig's std ships no console-mode bindings at 0.16, so the five functions tug
  needs are declared as externs in the backend. They are stable Win32 API.

## Consequences

Makes easy: developing tug on Windows, and a genuine head start on the v0.9
tier-1 decision — the backend will already exist and will have been exercised
daily.

Makes hard: nothing in the POSIX path, which is untouched. The real cost is a
second code path that can rot silently, which is what the `windows-compile` CI
job exists to prevent.

Revisit at **v0.9**, where the roadmap already schedules the Windows tier-1
decision along with the `bash`-tool POSIX-shell requirement. If this backend has
been in daily use by then, that decision gets to be made from evidence rather
than from a plan.
