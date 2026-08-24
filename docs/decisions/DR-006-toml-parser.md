# DR-006: A TOML subset tug owns, not a TOML parser tug vendors

**Status:** accepted
**Date:** 2026-08-25
**Phase:** 7

## Context

Configuration is TOML. That part was settled in the roadmap and is not what this
record decides: TOML was chosen over ZON because themes and keymaps are meant to
be shared between people who have never seen Zig, and over JSON because a config
file wants comments. What this record decides is *where the parser comes from*.

The roadmap set the acceptance bar in advance:

> Evaluate current candidates (e.g. `zig-toml`, `tomlz`) against the pinned
> compiler. Acceptance bar: parses the config corpus · zero leaks under
> `std.testing.allocator` · size delta ≤ 50 KiB · error messages carry line/col.
> Fallback, chosen without sentiment: an in-house TOML *subset* parser (~500
> lines: tables, strings, ints, bools, arrays — everything a keymap and a theme
> need, nothing more). Whichever way it goes, **vendor it** — no network fetches
> at build time.

That last clause is the one that reframes the question. Vendoring is required
either way, so this is not a choice between a dependency and no dependency. It
is a choice about which body of code this repository maintains against a pinned
compiler for the rest of v0.x.

The second thing that shapes it is where the parser has to live. Config parsing
is pure — bytes in, values out — so it belongs in `tugcore`, which compiles for
`wasm32-freestanding` on every CI run, and it sits directly beside a stack of
components that all pass strings by borrowing: the environment map in
`main.zig`, the capability detector, the history path resolver. None of them
owns a string. None of them has a `deinit`.

## Options

**`sam701/zig-toml`.** Maintains branches for zig-master, 0.16 and 0.15, which is
the strongest thing any candidate has going for it — a pinned-compiler story that
actually exists. Targets TOML **1.1**: integers in four bases, floats, dates,
times, time offsets, arrays of tables. Parses through an allocator into a typed
struct. Its README's "Error Handling" section is marked TODO; the error surface
it does document is `error.UnknownField` plus a `parser.error_info` for unknown
field names. No line or column.

**`mattyhall/tomlz`.** Aims at Zig master and the latest tagged release. Passes
321 of the 334 cases in the TOML test suite, the gaps being datetimes and two
lexer cases. Lists "good error messages" as a project goal. Parses through an
allocator into a dynamic `Value` tree. No documented line or column either.

**An in-house subset.** The grammar tug's config actually uses: comments, table
headers, bare and quoted keys, strings, decimal integers, booleans. Roughly 330
lines including its own recovery.

## Decision

The in-house subset — `src/core/config/toml.zig`.

**Neither candidate was benchmarked head to head, and this record does not
pretend otherwise.** Both were assessed on their documented surface. That is
enough, because the bar item that decided it is not one a benchmark would have
moved:

**Line and column.** The phase's whole error posture is "parse errors report
file, line, col; a bad value warns and falls back". Neither candidate promises a
position, one has its error handling marked TODO, and retrofitting positions into
somebody else's lexer is a fork wearing a dependency's clothes.

**Ownership.** Both candidates build an allocated value tree. That makes the
config's strings owned copies with a lifetime and a `deinit`, in a module whose
every other borrowed-string boundary hands out slices of a buffer the frontend
owns. Adopting one would have meant either living with two ownership models in
`tugcore` or copying every value out of the tree on the way through — which is
most of the work the tree was supposed to save.

**Surface.** Both implement TOML in full, or near enough: floats, datetimes,
offsets, hex and octal integers, arrays of tables. tug's config has no key that
is a float, a date, or an array. Vendoring means owning that code — every line
of it, against a compiler pin that moves — to serve four value types.

### The size number

The bar was a delta of 50 KiB. The `ReleaseSmall` static Linux binary went from
**155,584 B** at the start of Phase 7 to **173,088 B** at its end, a delta of
**17,504 B**, or 34% of the bar — and that is for the scanner, the schema, the
five-layer merge, the diagnostics and the resolved report together. The whole
config stack, not just the parser. Both numbers come from `zig build size`.

Size is recorded because the bar named it. It is not what decided this, and a
candidate that had come in smaller would still have lost on the two points above.

### What the subset refuses

Each refusal is a **named warning** at a line and a column, never a silent
ignore. That is the whole mitigation: someone who writes TOML tug does not
understand is told which line and what to write instead.

- Floats, dates, times, offsets, non-decimal integers
- Arrays, inline tables, arrays of tables
- Dotted keys (`a.b = 1`) — use a `[table]` header
- Escape sequences in basic strings — use a literal string in single quotes

**Arrays are a deliberate departure from the roadmap's own sketch of the
fallback**, which lists them. No key in v0.1 — not a theme slot, not a keymap
entry — is an array, and an array is the one item on that list that is a
structure rather than a scalar: it costs an iterator type and a borrow story
rather than fifteen lines. A parser feature with no consumer has no test that can
fail, which is the same argument that admitted integers and booleans, both of
which `[history]` does consume.

**Escapes are refused rather than decoded** for a reason worth stating on its
own, because it is what keeps the whole file allocation-free. Every string the
scanner yields is a slice of the source; a decoded escape has nowhere to live but
a scratch buffer, and a scratch buffer the caller must copy out of before the
next call is a footgun traded for a feature nothing needs. A literal string —
`'C:\tug'` — covers the one case anybody reaches for.

## Consequences

**Easy:** the scanner has no error set, no allocator and no state beyond an index
and a line counter, so the layer above it cannot fail either. A config file full
of nonsense produces a `Config` of defaults and a list of warnings, which is the
"a typo in a keybind must never brick the shell" requirement made structural
rather than careful. `tugcore` stays freestanding without an exception. There is
no third-party code to re-vendor when the compiler pin moves.

**Hard:** tug's config is not TOML. It is a subset, and a person who knows TOML
can write something valid that tug refuses. The refusals are named and positioned
precisely because that will happen, and the documentation says "a subset" rather
than "TOML" wherever it can be read as a promise.

**Forecloses:** nothing structural. The scanner is one file behind a pull API;
a future release that needs full TOML can swap it for a vendored parser and
adapt `Config.apply`, which is the only caller.

**The revisit trigger** is the first config key whose value is genuinely an array
or genuinely needs an escape — a themes search path, a list of allowed tools, a
prompt template with a tab in it. Not "when someone reports that tug is not
TOML-compliant": tug's config is not a conformance target, and saying so here is
cheaper than saying it in an issue thread later.
