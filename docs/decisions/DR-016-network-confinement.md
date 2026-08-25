# DR-016: The network tripwire narrows instead of dying

**Status:** accepted
**Date:** 2026-08-25
**Phase:** 0 (v0.2)

## Context

v0.1's strongest claim was mechanical: the binary could not talk to the network,
because `scripts/no-network.sh` failed the build on `std.http`, `std.net`,
`std.posix.socket` or `std.crypto.tls` appearing anywhere under `src/`. The
Definition of Done recorded that the gate was never legitimately silenced. The
gate even said what would end it, in its own comment: *"If this is v0.2 provider
work, delete this gate in the commit that adds it."*

v0.2 is that work. All four patterns are about to be legitimate — and the
instruction the v0.1 author left behind turns out to be the wrong one. A gate
that dies on the first commit that needs it protected nothing at the moment it
mattered most. The version that introduces sockets is precisely the version where
"which code can open a socket?" stops being rhetorical.

There is a second pressure, and it is the load-bearing one. `DR-017` will split
the provider stack at a `Transport` interface: everything above the seam is pure
and drives from recorded bytes, everything below it is the one place that talks
to a socket. That split is the reason CI can prove real-API behaviour with no
network at all. A seam enforced only by review is a seam that leaks — one
`std.http.Client` in a mapper, added under time pressure, and the offline test
suite quietly stops testing the thing it claims to.

## Options

**Delete the gate, as its own comment instructs.** Cheapest, and what the v0.1
author expected. Costs the claim entirely: from v0.2 onward nothing mechanically
answers where network code lives, and the `DR-017` seam rests on everyone
remembering. The v0.1 Definition of Done line becomes true-but-retired, which is
a worse epitaph than false.

**Keep it and exempt files by name.** An allowlist of exact paths in the script.
Precise, and it churns: every new file under the transport gets a line, every
rename breaks the build for a reason unrelated to the rule. The allowlist grows
faster than the thing it describes.

**Narrow the gate to a directory prefix.** `std.http`, `std.net`,
`std.posix.socket` and `std.crypto.tls` are permitted under
`src/providers/transport` and forbidden everywhere else — including the rest of
`src/providers/`. One line of grep, no per-file maintenance.

**A build-system boundary instead of a grep.** The honest ideal: express it in
the module graph so a violation is a compile error. Zig has no mechanism for it —
`@import("std")` is available in every module and `std.http` is a field access on
the result. There is nothing to restrict.

## Decision

**The gate narrows to `src/providers/transport`.**

The four patterns are permitted under that prefix and fail the build anywhere
else. The script keeps its signature — `no-network.sh [directory]`, exit 1 with
the offending `path:line:` lines — so CI needs no change beyond the job's name.

The claim v0.1 made does not retire; it becomes more specific. "tug has no
network code" becomes "tug's network code is reachable from exactly one
directory, and CI fails if that stops being true." The second statement is the
one that is useful now that the first cannot be.

The grep stays textual, which means a *comment* mentioning `std.net` in the wrong
directory trips it. That is deliberate, not a rough edge: a comment about sockets
in a mapper is almost always a plan to write sockets in a mapper.

`tugcore`'s `wasm32-freestanding` job is unchanged and untouched by this. It
remains the second, independent guard — the core cannot import the provider layer
because the core has to compile for a target with no sockets at all. Two
mechanisms, different failure modes, neither derived from the other.

## Consequences

**Easy.** The `DR-017` transport seam is enforced by a gate rather than by
review. A mapper that reaches for a socket dies in CI with a message naming this
record. Anyone asking "what in tug can reach the network" gets a directory
listing for an answer.

**Hard.** Moving transport code requires editing the gate, which shows up in a
diff — that is the mechanism, not a cost to be optimised away. A future frontend
that legitimately wants a socket outside the provider layer (an MCP transport, a
plugin host over TCP) has to either live under this prefix or amend this record;
neither is free, and both are visible.

**Foreclosed.** Network code scattered by convenience. If tug ever grows a second
legitimate socket site, that is the trigger to revisit: at two prefixes the rule
is still a rule, at four it has become an allowlist and the option rejected above
wins on honesty.

This decision is wrong the day the grep starts being silenced with `# noqa`-style
escapes. There is no escape syntax on purpose.

## Related

- `scripts/no-network.sh` — the gate itself.
- `scripts/offline.sh` — the runtime half. The grep constrains what is written;
  the network namespace constrains what runs. Neither substitutes for the other.
- `DR-017` — the transport/interpreter split this exists to protect.
