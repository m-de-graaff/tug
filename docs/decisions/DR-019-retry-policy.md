# DR-019: What gets retried, and the line retries never cross

**Status:** accepted
**Date:** 2026-08-26
**Phase:** 5 (v0.2)

## Context

Providers fail. A connection resets, a load balancer returns 503 for four
seconds, a rate limit lands mid-conversation. Most of those are transient, and a
harness that hands every one of them straight to the user as an error is a
harness people learn to resubmit into rather than trust.

`.artifacts/ROADMAP.md` § v0.2 puts it in five words — *jittered backoff,
idempotent retries only* — and `.artifacts/v0.2.md` § Phase 5 spells out the
classes. This record is why those classes and not others, and what "idempotent"
means for something that streams.

The hard part is not the backoff curve. It is that a *stream* has already
delivered output by the time most failures happen, and retrying it means
deciding what to do with what the user has already read.

## Options

**Retry everything transient.** Simple and wrong on two classes. A wrong API key
is wrong on the fourth attempt too, and four attempts is how an account with
aggressive lockout gets locked. Bytes that failed to decode will not decode later
— a retry loop over a parser bug is a parser bug that also costs money.

**Retry nothing.** Honest, and it makes every provider blip the user's problem.
The 503 that would have cleared in two seconds becomes a resubmit, and the
resubmit pays for the whole prompt again.

**Retry by class, and only before the first content byte.** The classes come from
the taxonomy that already exists. The line comes from what a stream is.

## Decision

### The classes

| Kind | Retried | Why |
|---|---|---|
| `transport` | yes | A reset connection is the canonical transient failure |
| `server` | yes | 5xx is the provider saying "not now"; 4xx-that-is-not-auth lands here too and is discussed below |
| `rate_limit` **with** `Retry-After` | yes | The provider said exactly when. Waiting is doing what it asked |
| `rate_limit` **without** `Retry-After` | no | A 429 with no instruction is a provider declining to say when, and guessing is how a client becomes part of the incident |
| `auth` | never | A wrong key is wrong every time, and retrying it is how an account gets locked |
| `decode` | never | Bytes that did not mean what they claimed will not mean it later |

The `server` row is the loose one, and deliberately so: `taxonomy.fromStatus`
puts a 400 and a 404 there too, and those are not transient. Retrying them costs
three requests that fail identically and then reports the same message. That is
an acceptable price for a mapping with no judgement calls in it — and the
alternative, a second status classification just for retryability, is the second
taxonomy this project has already decided not to have.

### The stream idempotency line

**A request that has yielded zero content events may be retried. After the first
`text_delta`, never.**

This is the rule the whole record exists for. When a stream dies at the fortieth
token, there are exactly three things a harness can do:

1. **Retry and discard.** The user watched forty tokens appear and then vanish.
2. **Retry and splice.** Two model responses, joined at an arbitrary point,
   presented as one. This is the worst option and it is the tempting one, because
   it looks seamless — which is precisely the problem. Nobody can see it
   happened, including the person who later quotes the result.
3. **Stop, and keep what arrived.** The user has forty tokens and an error
   saying the stream ended early. They can resubmit if they want to.

tug does the third. Partial output is the user's, not the retrier's.

`Esc` cancellation draws the same line for the same reason (`DR-018`), which is
why it is stated once and pointed at twice.

### Backoff

Full jitter: `random(0, min(cap, base * 2^attempt))`. Not equal jitter and not
none. The failure this exists to prevent is every tug on a team retrying in
lockstep after one provider blip, and of the standard variants full jitter
flattens that best.

A server-supplied `Retry-After` **wins outright**, even past the cap. The cap
bounds tug's guessing, not the provider's instruction; backing off less than you
were told is how a client gets rate-limited again one second later.

### Two budgets

`max_attempts` stops a pathological loop. `max_elapsed_ms` is the one a human
notices: a harness that spends ninety seconds retrying silently has hung,
whatever its attempt counter says. Both are checked, and the elapsed one is
checked *before* sleeping so the budget bounds the wait rather than being
discovered after it.

### The clock is injected

The engine sleeps and reads a clock, and neither belongs to it. Two function
pointers — `nowMs` and `sleepMs` — mean the elapsed-budget test runs instantly
instead of taking four real seconds, and `sleepMs` returns `false` when the wait
was interrupted, which is how `Esc` aborts a retry wait without the engine
knowing what `Esc` is.

## Consequences

Easy: a provider blip becomes a dim notice and a slightly slower answer. The
notice says what it is waiting for and how long, so a user watching a four-second
pause knows it is not a hang.

Hard: a 400 is retried three times before it is reported. Acceptable, and the
alternative was a second classification of every status code.

Foreclosed: resuming a broken stream. Doing it properly needs the provider to
support continuing from a token offset, and none of them do.

What would make this wrong: a provider offering resumable streams, which turns
the idempotency line from a rule into a limitation. Revisit then, and not before
— the "splice two responses" version is not what resumable means.
