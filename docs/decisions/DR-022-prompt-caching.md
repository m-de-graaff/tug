# DR-022: Two cache markers, always, with no knobs

**Status:** accepted
**Date:** 2026-08-26
**Phase:** 4 (v0.2)

## Context

`.artifacts/ROADMAP.md` § v0.2 says it in four words — *prompt caching automatic;
no knobs* — and the context-efficiency workstream explains why it is in the
roadmap at all: every token tug injects is a cost someone pays, and the harness's
own overhead is a number it is expected to publish.

Anthropic's prompt cache is a prefix cache. A `cache_control` marker on a content
block means "everything up to and including here is cacheable"; a later request
whose prefix is byte-identical up to that point reads those tokens instead of
paying for them, at roughly a tenth of the price. The markers cost nothing to
send and there are at most four per request.

So the question is not whether to cache. It is where the markers go, and whether
the user gets to move them.

## Options

**No markers.** Simplest, and it silently declines a tenfold price reduction on
the largest stable part of every request. `tugproto.Usage` already separates
`cache_read_tokens` from `input_tokens` and `Model.price` already carries four
numbers — the vocabulary was built in Phase 1 for exactly this, and shipping
without markers would leave those fields permanently zero.

**Markers, configurable.** A `cache = "system" | "turn" | "both" | "off"` key,
or a count, or a TTL. This is the option that looks generous and is not: the
configuration surface for cache placement is a configuration surface for getting
cache placement wrong, and getting it wrong is invisible — a misplaced marker
does not fail, it just quietly stops saving money. It also invites support
questions nobody can answer without a request dump.

**Two markers, fixed.** One on the last block of the system prompt, one on the
last content block of the last *user* message.

## Decision

Two markers, fixed, no configuration.

**The system prompt** is the longest stable prefix in any session. It changes
when the harness changes and not otherwise, which is exactly the shape a prefix
cache rewards.

**The last user turn** is the boundary that makes turn *N+1* a cache hit on turn
*N*'s entire conversation. Putting the second marker on the last *message* rather
than the last *user message* would put it on an assistant turn whenever the
conversation ends with one, and every subsequent hit would then be one turn
stale — the cheapest possible mistake to make and the hardest to notice, because
the thing that breaks is a number nobody is looking at.

The degenerate case is deliberate: a single-turn conversation's only user message
is also its last, so it gets a marker like any other. A builder that walked
backwards looking for "the previous user turn" would place nothing at all there,
which is the first request of every session.

**No knobs**, and the honest alternative to knobs is a number. `cache_read_tokens`
and `cache_creation_tokens` are separate fields in `Usage` and separate lines in
the price table because a user should be able to *see* the cache working rather
than be asked to tune it. Phase 6's usage line is where they see it.

**Two of four.** The API accepts at most four markers. Spending two leaves room
for v0.3's tool schemas — which are static, large, and the next obvious thing to
cache — without reopening this decision.

## OpenAI-compatible servers get nothing

Not an oversight and not a lesser effort: there is no request-side marker to
send. OpenAI's caching is automatic and server-side, and the other five servers
behind the `openai-compat` implementation each do something different or nothing
at all. So the builder sends no marker, reads
`usage.prompt_tokens_details.cached_tokens` when a server supplies it, and
reports zero when it does not.

Zero rather than absent, and the difference matters: `Usage` has no "unknown"
and inventing one would put a third state into a struct that crosses every
boundary in the system, for six servers' worth of inconsistency. A zero
cache-read on a server that does not report caching is wrong in the same
direction as a zero cost on an unknown model, and it is wrong quietly rather
than loudly, which is the trade being made.

## Consequences

Easy: the cache is on for everyone, on the first request, with no documentation
to read. The savings show up in a line the user already sees.

Hard: a user who wants the markers elsewhere has no way to move them, and the
answer is that they should file an issue describing the case rather than reach
for a config key. That is a deliberate cost.

What would make this wrong: Anthropic changing the cache from a prefix cache to
something else, or the four-marker limit becoming a limit tug bumps into — the
first tool-schema marker in v0.3 makes it three, and a fourth would mean this
record is spending a budget it does not have.
