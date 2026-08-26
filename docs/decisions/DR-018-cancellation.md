# DR-018: Cancel is a flag plus a socket shutdown, and a stall is a cancel nobody asked for

**Status:** accepted
**Date:** 2026-08-25
**Phase:** 3 (v0.2)

## Context

A streaming turn runs on its own thread, parked in a blocking read, and two
different things need to end it early.

The human presses `Esc`. That is the whole reason the shell has a loop thread
separate from the provider thread, and `.artifacts/v0.2.md` puts a number on it:
*cancel → thread joins promptly (test: ≤ 100 ms), no leaks, no orphaned fds*. A
harness where the stop key takes a second to work is a harness people stop
trusting mid-answer, which is exactly when they need it.

The connection stalls. A provider accepts the request, sends a head, and then
sends nothing — the TCP connection is alive and there is no error to report,
because nothing has failed yet. Left alone, the read blocks forever and the shell
looks hung. The version's own error taxonomy has a name for this
(`transport`, with the elapsed time) and the roadmap asks for the read timeout to
double as the detector.

Both are the same physical problem: a thread is parked inside a `read(2)` on a
file descriptor and something outside that thread has decided it should stop
being.

## Options

**A flag, checked between reads.** Cheapest, and it works for a stream that is
actively delivering bytes — the loop checks the flag every chunk. It does nothing
for the case that matters. A thread blocked in a read on a stalled connection
checks no flags; that is what blocked means. Cancelling a fast stream is not the
hard case, and a mechanism that only handles the easy one is a mechanism that
will be reported as a bug.

**`Io` cancellation.** Zig 0.16 has `Io.Cancelable`, `Io.async`, `Future.cancel`
and `Io.checkCancel`, and for a program built on `Io` concurrency they are the
right answer — the runtime already knows which operation a task is parked in.
tug is not that program. The roadmap chose thread-per-stream deliberately
(§ Runtime model: *blocking IO, thread-per-stream, no async*), the shell's `Io`
is `init_single_threaded`, and the threads are `std.Thread`s the frontend owns
and joins. Adopting `Io`'s concurrency model in order to cancel one blocking read
would be the tail wagging the dog, and it would couple tug to the part of the
compiler that is still settling — which is the churn the runtime decision was
made to avoid in the first place.

**Closing the socket.** Wakes the read immediately. It also hands the file
descriptor back to the OS while `std.http.Client`'s connection pool still
believes it owns it, and the next connection to open may be handed the same
number. That is a use-after-close with a race in it, and the class of bug it
produces — occasional traffic delivered to the wrong stream — is the worst kind
to debug.

**`shutdown(2)` on the socket.** Wakes the blocked read the same way, without
retiring the descriptor: the fd stays valid and owned, the read returns, and the
pool's bookkeeping stays true. Reachable in 0.16 as
`connection.stream_reader.stream.shutdown(io, .both)`.

## Decision

An atomic flag **and** `shutdown`, together, from `Http.cancel`:

```zig
pub fn cancel(self: *Http) void {
    self.canceled.store(true, .release);
    self.shutdownSocket();
}
```

Neither half is sufficient alone. The flag alone cannot wake a parked read. The
shutdown alone cannot be remembered — a shutdown that lands between two reads
produces a read failure the reader has no way to distinguish from a connection
the server closed, and "the model stopped talking" and "you pressed Esc" must not
render as the same thing. The flag is what makes the wakeup legible after the
fact.

The bound is **100 ms from `cancel()` to the provider thread returning**, tested
against a real loopback server that accepts, sends a head and one event, and then
goes deliberately silent.

**Stall detection reuses the same lever.** A read timeout is a cancellation
nobody asked for: a watchdog notices that no byte has arrived for `read_ms`,
sets a separate `stalled` flag, and calls the same `shutdownSocket`. The reader
distinguishes the two after waking — `canceled` → `Canceled`, `stalled` →
`Timeout` — and the taxonomy in Phase 5 turns the second into a `transport` error
carrying the elapsed time. One mechanism, two triggers, one thing to get right.

The watchdog is one thread per active stream, ticking four times a second.
tug has one active stream, so that is one thread and four wakeups per second, and
the `ponytail:` comment on it names the upgrade: a single shared watchdog over a
list of deadlines, the day parallel streams exist.

It parks on a futex with a tick-length timeout rather than sleeping the tick out,
and `close` wakes it. That is not an optimisation: the bound above is on the
*thread join*, and a watchdog sleeping out a 250 ms tick blows a 100 ms bound on
its own, while the read it was watching returned in single-digit milliseconds. A
cancellation that is instant and a teardown that is not are the same thing to
whoever is waiting for the prompt.

## What is not cancelled

Bytes that already arrived. A cancelled turn keeps its partial text and commits
it to the conversation with a cancelled marker — cancellation ends a stream, it
does not unwind one. That is the same line `DR-019` will draw for retries, and
drawing it once in two places is the point of writing it down here.

## Consequences

Easy: `Esc` and `Ctrl+C` become one call from the frontend. Stall detection costs
no new machinery. The offline fixture path needs none of this, because a fixture
never blocks — which is also why the tests for it are the only ones in the
provider layer that need a real socket, and why `scripts/offline.sh` brings up
loopback rather than denying it.

Hard: this reaches past `std.http.Client`'s intended surface into
`Connection.stream_reader.stream`. Both fields are public in 0.16.0 and the shape
is stable enough to depend on for one version, but it is a dependency on an
internal arrangement and it belongs on the list of things a toolchain bump checks.

## Two bugs this decision's tests found, which is why they exist

Neither is about cancellation. Both were in the read path, both would have shipped,
and both were found by writing a server that says one small thing and then goes
quiet — which is what a model streaming a token looks like.

1. **`readSliceShort` is not a streaming read.** It loops until the caller's
   buffer is full and returns short only at end of stream. With a 4 KiB buffer, a
   response's first token would have appeared once 4 KiB of deltas had piled up
   behind it. `readVec` was no better: it fills the body reader's own buffer
   first and reports only what reached the caller's, which for one small chunked
   event is zero. What streaming wants is neither — hand back whatever is
   buffered, and block for more only when there is nothing.

2. **`BodyWriter.flush` does not flush the BodyWriter.** It flushes the protocol
   output; the bytes the caller wrote sit in the BodyWriter's own buffer until
   `body.writer.flush()` turns them into a chunk. The test server looked correct,
   sent nothing, and every test then measured a stall it had caused itself.

The second is in test code and the first is in shipped code, and the reason both
were caught is the same: a fixture cannot hold a connection open and say nothing.
That is worth one real socket in the test suite.

## Not verified here

**No orphaned file descriptors.** `.artifacts/v0.2.md` asks for it and the
mechanism is chosen for it — `shutdown` rather than `close`, precisely so the
pool keeps owning the fd — but the check is `valgrind --track-fds=yes`, and
valgrind is not installed on the WSL toolchain this was developed against. The
leak half is covered mechanically by `std.testing.allocator`. Phase 10 points the
existing valgrind job at these tests, and that is where the fd claim becomes a
gate rather than an argument.

What would make this wrong: a `shutdown` that does not wake a read blocked inside
the TLS record layer — plausible if the implementation is sitting on a partial
frame. The fallback, should that turn up, is `Socket.receiveTimeout` with a short
tick and a flag check between ticks, which trades a syscall per tick for not
touching internals at all.
