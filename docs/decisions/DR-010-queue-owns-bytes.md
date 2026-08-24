# DR-010: The cross-thread queue owns the bytes it carries

**Status:** accepted
**Date:** 2026-08-24
**Phase:** 5

## Context

`StreamEvent` and `Payload` both document their slices as borrowed: the producer
owns the storage, and it is valid for the duration of the call. That is the
right contract on the loop thread and it is why the whole rendering path is
allocation-free — the renderer copies into its own storage on `feed`, so nothing
upstream has to own anything.

It stops being right the moment the producer is a different thread. Phase 3
noted this and deferred it, in a `ponytail:` comment on `Queue.push` that named
Phase 5 as the phase that would decide, because Phase 3 had no producer to
decide against: the only cross-thread signal was a resize, which carries no
payload at all.

Phase 5 has one. The provider thread builds a chunk in the mock's buffer, pushes
it, and immediately reuses that buffer for the next chunk. Between the push and
the loop's drain there is a window of up to a frame — 8 ms, or considerably more
under backpressure — in which the queued payload points at bytes that have
already been overwritten. Nothing about this is theoretical; at firehose cadence
it is the common case rather than the race.

## Options

**An arena drained alongside the queue.** The producer allocates each payload's
bytes from an arena, and the loop resets it after publishing. It works, and it
puts an allocator in the hot path of every streamed chunk — plus a second
lifetime to reason about, since the reset has to happen after the last
subscriber has finished with the last payload and not a moment before.

**A byte pool behind the queue.** A ring of bytes parallel to the ring of
payloads, with the payload slices pointing into it. Cheaper than an arena, and
it needs the consumer to say when it is finished with a region, which is a
refcount or a high-water mark that the producer has to respect. Two rings with a
liveness relationship between them is more invariant than this problem is worth.

**Fixed-size slots that own their bytes.** Each slot carries the payload and a
byte array; `push` copies in and `pop` copies out. No allocator, no second
lifetime, and the only question left is what the fixed size should be.

## Decision

Fixed-size slots. `max_payload_bytes` is 512 and `capacity` is 64, so the queue
is 32 KiB of static footprint against a 10 MiB idle-RSS budget.

`pop` copies into a caller-supplied buffer rather than returning a slice into the
ring. That is not belt and braces: the slot is available to a producer the
instant `pop` returns, and at firehose rate it is refilled well before the caller
has published. The loop's buffer is a local in `drainQueue`, which gives it
exactly the publish-and-forget lifetime the bus already documents for a borrowed
slice.

512 bytes was chosen against the producer, not the consumer. The cadence engine's
largest ordinary chunk is 64 bytes, and a `comptime` assertion in `cadence.zig`
fails the build if that ever exceeds the slot — so an oversized chunk is a
message at compile time rather than a `PayloadTooLarge` in the middle of a
stream.

## Consequences

A payload larger than a slot is refused with `error.PayloadTooLarge` rather than
truncated. Splitting it is the producer's job and costs nothing: a text delta cut
in two is two text deltas, which is what the entire streaming path is made of.
`oversized_chunk` exists as a fault mode precisely to keep that path exercised —
an 8 KiB delta reaches the runner whole and leaves it as sixteen pushes.

The bound is also what makes a firehose apply backpressure instead of growing
memory. `error.Full` is not a failure to be recovered from; it is the queue
telling the producer the loop is behind, and the correct response is to ring the
waker and wait a millisecond.

Two memcpys per event, of at most 512 bytes each. At the frame budget's 125 Hz
with a full 64-slot drain that is 8,000 events a second, or about 4 MB/s of
memcpy in the worst case the design admits. That is not a number worth
optimizing against a terminal write.

Revisit if a payload arrives that cannot be split. Nothing in v0.1 has one, and
the tool-call events of v0.2 are structured rather than streamed, so they are
likelier to want a different queue than a bigger slot.
