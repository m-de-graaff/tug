# DR-023: Keep `std.crypto.tls`, or ship a vendored engine behind a build flag

**Status:** proposed — **this record closes in Phase 10, not here**
**Date:** 2026-08-25 (opened)
**Phase:** 3 (opened), 10 (closed)

## Context

tug's default build has zero C dependencies, and TLS is the one place that claim
is under real pressure. The standard library's TLS is **1.3 only**. Every major
provider serves 1.3, so the claim holds for the endpoints tug is built for; the
risk is everything in between — a corporate middlebox terminating at 1.2, an old
reverse proxy in front of a self-hosted vLLM, a captive network.

`.artifacts/ROADMAP.md` § v0.2 makes the verdict an exit criterion in as many
words: *std-TLS verdict written down (keep, or flag in vendored engine)*. This
record is that verdict, and it is opened here rather than in Phase 10 so the
evidence has somewhere to accumulate while it is being gathered.

## The question

Keep `std.crypto.tls` as the only TLS engine, or add a build flag that swaps in a
vendored one for people whose network refuses 1.3.

## Criteria

1. Does every preset endpoint complete a 1.3 handshake, from a normal machine, on
   a normal network? Anthropic, one hosted OpenAI-compatible service, and — for
   completeness rather than for TLS — local Ollama over plaintext loopback.
2. Did anything in the smoke matrix fail in a way a vendored engine would have
   fixed? A 1.2-only middlebox is that failure; a DNS problem is not.
3. What does the flag cost if it ships? Binary size against the 2 MiB ceiling, a
   C dependency in a build that currently has none, and a second code path
   through the one part of the system where a bug is a disclosure.

The bar for adding the flag is deliberately high, and it is evidence rather than
imagination: *someone could have a 1.2-only proxy* is not a finding.

## Evidence

Filled in from `docs/endpoint-smoke.md`, which is the manual pre-tag checklist.
A row here is a handshake somebody actually performed on a dated day.

| Endpoint | Date | TLS version | Handshake | Notes |
|---|---|---|---|---|

## Decision

**Not yet made.** This record cannot be closed from a developer's machine: it
needs three dated endpoint rows, and two of them arrive with Phase 10's smoke
checklist. Closing it early would mean writing a verdict from imagination and
then finding the evidence to match, which is the failure mode a decision record
exists to prevent.

What is decided now, and is not the verdict: the engine is reached only through
`src/providers/transport/http.zig` (`DR-016`, `DR-017`), so swapping it is a
change to one file rather than a change to the provider stack. That is what makes
deferring the verdict cheap enough to defer.

## Consequences

If the verdict is *keep*: the zero-C-dependency claim survives into v1.0, and
users behind a 1.2-only middlebox are told plainly, in the docs, that tug will
not work there. That is a real cost paid deliberately.

If the verdict is *flag*: the default build is unchanged and unflagged, the
vendored engine is opt-in at build time, and the size budget absorbs it or the
flag does not ship.

What would reopen this after v1.0: `std.crypto.tls` growing 1.2 support (which
removes the question), or a provider tug supports moving to something the
standard library cannot speak.
