# DR-002: Waking the loop with a self-pipe

**Status:** accepted
**Date:** 2026-08-24
**Phase:** 3

## Context

The loop blocks in one place. It waits on the terminal until either input
arrives or a render deadline falls due, and it must consume nothing while it
waits — the roadmap's idle budget is 0 % CPU and 10 MiB RSS, and a loop that
polls on a timer to check whether anything happened fails the first of those on
principle rather than by a margin.

Two things that are not the terminal need to interrupt that wait. The `SIGWINCH`
handler, which learns about a resize and may do almost nothing about it — a
signal handler may not allocate, may not lock, and may not call back into the
runtime. And, from Phase 5, a provider thread that has produced a `StreamEvent`
and pushed it onto the cross-thread queue.

Both need a way to say "look again" that a single `poll` can wait on alongside
the terminal.

## Options

**`eventfd`.** One descriptor instead of two, an 8-byte counter instead of a
byte stream, and the kernel does the coalescing. It is also Linux-only. macOS is
tier-1 in the roadmap's terminal matrix, so this would mean writing the portable
version anyway and maintaining both.

**A kqueue user event (`EVFILT_USER`).** The macOS-native answer, and equally
one-platform. Choosing this and `eventfd` together means two mechanisms, two
sets of edge cases, and a `poll` on Linux against a `kevent` on macOS — the loop
itself would fork.

**A condition variable.** Not an option: `poll` cannot wait on one, so the
terminal would need its own thread feeding a queue, which is a thread and a
queue added to avoid a pipe.

**A self-pipe.** Two descriptors, POSIX since forever, and a `write` of one byte
is on every platform's list of async-signal-safe functions.

## Decision

A self-pipe, created with `pipe` rather than `pipe2`, and coalesced in userspace.

`pipe2` would let the descriptors be created non-blocking and close-on-exec in
one call, but macOS does not have it, and the coalescing below removes the
reason to want `O_NONBLOCK` in the first place.

**Coalescing is the load-bearing part.** `Waker` holds an atomic flag. `wake`
swaps it to true and writes a byte only if it was false; `drain` clears it
before reading. At most one byte is ever outstanding, so a 64 KiB pipe buffer
cannot fill, so the `write` inside the signal handler cannot block. Without the
flag, a provider thread emitting a byte per chunk while the loop is busy
rendering would eventually fill the pipe, and the first thing to discover it
would be a signal handler blocking inside a `write` — a hang with no stack worth
reading.

**The flag is cleared before the read, not after.** A wake racing the drain
either writes a byte the read collects, or writes one that stays in the pipe and
returns from the next wait. Clearing afterwards would drop a wake that arrived
between the read and the clear, and a lost wake here is a frame that never
paints or an event that sits in the queue until the next keystroke.

**Windows uses an auto-reset event.** It has neither `eventfd` nor a self-pipe
that `WaitForMultipleObjects` can wait on alongside a console input handle.
`CreateEventW` plus `SetEvent` is the same shape, and the auto-reset semantics
mean the wait itself consumes the signal, so `drain` there is a no-op. Windows is
tier-2 (`DR-009`) and this is not certified.

## Consequences

Makes easy: one `wait` call on every platform tug targets, with the terminal and
the doorbell as two handles. The `SIGWINCH` handler stays three lines and stays
async-signal-safe. Phase 5's provider thread gets a wakeup that already exists.

Makes hard: nothing yet. Two descriptors per process rather than one is not a
resource worth counting, and the extra `read` per wake is one syscall against a
render that is about to write to a terminal.

Revisit if: the waker ever needs to carry *what* happened rather than just
*that* something did. It does not today — a resize is discovered by asking the
terminal its size, and queued events carry their own payloads — and building a
channel here rather than in the queue would put two queues in the loop.
