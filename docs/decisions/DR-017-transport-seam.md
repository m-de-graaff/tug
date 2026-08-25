# DR-017: The transport seam is three functions wide

**Status:** accepted
**Date:** 2026-08-25
**Phase:** 3 (v0.2)

## Context

v0.2's exit criteria contain a sentence that constrains the whole version's
architecture: *CI fully offline — recorded SSE fixtures replay byte-for-byte.*
Not "mostly offline", not "offline except the integration tests". Every claim
this version makes about real API behaviour has to be provable from a directory
of recorded bytes on a machine with no route off it.

That is only achievable if the code that talks to a socket is a small,
substitutable thing and everything else is a pure function of bytes. The provider
stack is four layers — build a request, send it, frame the response, map the
frames to `StreamEvent`s — and three of those four have no business knowing what
a socket is. The question this record answers is where the line goes and what
shape it takes.

`DR-016` already narrowed the network tripwire from prohibition to confinement:
`std.http`, `std.Io.net` and `std.crypto.tls` may appear only under
`src/providers/transport`. That gate is mechanical but it is only half the
answer. It says where network code may live; it does not say what the rest of the
stack talks to instead.

There is a second pressure, discovered while reading `std.http.Client` rather
than assumed in advance. A provider response is not uniformly SSE. A 200 carries
`text/event-stream`; a 401 carries a JSON error document; a proxy in the way
carries an HTML page. The SSE parser must never see the second or third of those
— it would frame them successfully and produce a decode error about entirely the
wrong thing, and the user would be told their stream was malformed when in fact
their key was.

## Options

**A `Reader` in, a `Reader` out.** The idiomatic Zig answer: a transport hands
back a `std.Io.Reader` and everything above consumes it. Cheapest to write and it
composes with the standard library for free. It fails on the second pressure
above: the status code has no place to travel. It would have to ride
out-of-band — a field the caller reads after the fact, or an error union with a
variant per status class — and out-of-band is also where cancellation and stall
detection want to live. One escape hatch is a design; three is an admission the
type was wrong.

**A full `Provider` interface at the socket.** Push the seam up: the fake is a
whole provider, not a whole transport. Fixtures would then be `StreamEvent`
sequences rather than bytes. Rejected because it moves the framing and the
mappers *above* the seam, which is to say outside what the offline suite tests.
The bugs this version will actually have are in framing and mapping — the SSE
parser has a fuzz target for exactly that reason — and a fake that starts after
them tests the layer least likely to be wrong.

**Three functions: `send`, `read`, `close`.** `send` takes a whole request and
blocks until the response head is available. `read` fills a caller's buffer and
returns 0 only at end of stream. `close` releases everything and is safe to call
twice.

## Decision

Three functions.

The head arriving before the body is the whole argument. `send` returning a
`Head` — status, content type, raw `Retry-After` — lets the layer above branch
before a single body byte reaches the framer, which is what keeps a 401's JSON
out of the SSE parser and a captive portal's HTML out of both. The same return
gives Phase 5 the status code it needs to build the error taxonomy, and the raw
`Retry-After` string rather than a parsed duration, because parsing it means
knowing about both the seconds form and the HTTP-date form and the transport
layer should not.

`read` filling a caller's buffer rather than returning a slice keeps ownership
where it already is everywhere else in this codebase: the caller owns the bytes,
the producer borrows nothing. The SSE parser (Phase 2) is built on exactly that
contract, and a second ownership idiom for the same data would be a second thing
to get wrong.

Two implementations, and their *locations* are part of the decision:

- `src/providers/transport/http.zig` — `std.http.Client` over `std.crypto.tls`.
  Inside `DR-016`'s allowance, and the only file that spends it.
- `src/providers/fixture.zig` — replays recorded bytes. **Outside** the
  allowance, deliberately. The confinement grep therefore proves mechanically
  that the offline path contains no network code. Putting it under `transport/`
  would cost nothing today and delete that proof; a reviewer would have to take
  it on faith instead of on a gate.

What this forbids, above the seam: no `Io`, no clock, no socket, no allocator
that was not passed in. A mapper that needs the wall clock is a mapper that
cannot be fixture-tested, and fixture-testability is the entire reason this
version's CI can claim what it claims.

## Proxies

`std.http.Client.initDefaultProxies` reads `http_proxy` / `https_proxy` from an
environment map and is wired through as std passthrough — tug forms no opinion,
adds no configuration, and does not attempt to improve on it. `.artifacts/v0.2.md`
asked for exactly this, or a documented deferral, and no heroics either way.

One limitation is documented rather than solved: **the plaintext policy does not
see through a proxy.** tug refuses `http://` to a non-loopback host, but an
`https://` URL routed through an `http_proxy` is a plaintext hop tug does not
inspect. A partial check here would be worse than none, because it would read
like a guarantee. The sentence is the answer until someone brings a real proxy
deployment and a real requirement.

## Consequences

Easy: CI drives the entire provider stack from `testdata/fixtures/` with no
network, at any chunk size, including chunk sizes no network would produce.
Cancellation and stall detection have an obvious home (`DR-018`). Phase 9's
recorder writes files this seam already consumes. v0.5's provider plugins get a
seam that already exists.

Hard: every transport implementation now owes three functions instead of one, and
`close` has to be genuinely idempotent because `defer t.close()` after an error
is the only cleanup pattern callers are given.

Foreclosed: HTTP/2 server push, request pipelining, and any response body that
must be read before its head — none of which any chat API does, and all of which
are in the version's scope guard already.

What would make this wrong: a provider whose stream requires reading the body to
learn the status — a 200 carrying an error object in its first SSE event. That
exists in the wild (some compat servers do it), and it does not invalidate this
seam: the mapper sees that event and emits an `err`, which is the layer that
should decide. Revisit only if a provider requires *writing* more request bytes
after the head arrives — a bidirectional stream — at which point `send` splitting
into `open` and `write` is the amendment.
