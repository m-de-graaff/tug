# DR-013: How a chord in a config file becomes a live binding

**Status:** accepted
**Date:** 2026-08-25
**Phase:** 8

## Context

Phase 6 left a table of `(chord, action, availability)` and a session that
switches on the action name. Phase 7 left `Config.bindings()` — every `[keys]`
entry from every layer, deliberately *collected* rather than merged, each
carrying the layer and the line that produced it. Phase 8 is the piece between
them, and the questions it has to answer are all questions about disagreement:

- What happens when a config file binds a chord the defaults already use?
- What happens when two config layers bind the same chord?
- What happens when a chord will not parse, or names an action that does not
  exist?
- Where do the resulting warnings live, given that the config's own warning
  type is in a module that has never heard of a keypress?

None of these is hard on its own. Getting them collectively wrong produces
either a shell that refuses to open over a typo — which the phase spec forbids
by name — or a shell that silently does something other than what the file says.

## Where the warnings live

**In `config.Note`, alongside the parse and schema warnings.** Rejected on two
counts, and the first is structural.

`tugcore` has no `KeyEvent` and cannot acquire one. It compiles for
`wasm32-freestanding` on every CI run, and a chord is a terminal concept:
whether `ctrl+nope` is a chord is a question only `tugshell` can answer. A
`Note.Kind` of `bad_chord` would therefore be a kind that only one module can
ever produce, sitting in the module that cannot evaluate it — and the next
person to add a note kind would reasonably conclude that this is where such
things go.

The second count is narrower and would have been enough on its own. The
conflict warning has to name *two* actions and *two* layers. `Note` has one of
each. Widening it means changing a type that five call sites already use in
service of one caller, and the widened fields would be null in every existing
use.

**In `tugshell`, in a `Problem` type of its own.** Chosen. It sits next to the
only code that can produce one, it carries exactly the fields a keymap warning
needs, and `tugcore` gains nothing but one export (`nearest`) from the whole
phase.

The cost is real and is stated rather than hidden: there are now two warning
lists. `--debug-config` prints the config's and then the keymap's, and Phase
10's `/config` and `/keys` will each render one. Both use the same
`path:line:col: warning: sentence` shape and the same `origins` array indexed by
layer, so a screen showing both reads as one list. If a third list ever appears,
that is the signal to reconsider — one shared `Diagnostic` interface would then
be paying for itself.

## Overriding a default is silent; overriding a config entry is not

**Warn on every chord that displaces something.** Rejected. Overriding a default
is the entire feature — it is what "keybinds are a config feature" means — and a
warning that fires for everyone who customised anything is a warning people
learn to scroll past. That is worse than no warning at all, because it also
hides the one that matters.

**Warn on nothing.** Rejected. Two files binding the same chord is exactly the
case where a person cannot tell which one won by reading either of them, and
provenance was built in Phase 7 specifically so that this warning could name
both sides.

**Warn only when the displaced entry came from a file.** Chosen. The rule is one
sentence and the implementation is one `if`: the entry being replaced carries an
optional layer, and whether it is null is the whole distinction.

This makes the *same chord twice in one file* and *the same chord in two files*
produce the same warning, which is correct — both are a person having said two
things — and the message names the layers, so the two read differently without
the code distinguishing them.

## Last one wins, rather than refusing to start

Codex, which has the closest comparable feature, treats a conflicting keymap as
a configuration error and refuses to run. tug cannot, and the reason is written
into the Phase 7 spec it inherited: *a typo in a keybind must never brick the
shell*. A conflict between a user file and a project file is not even a typo —
it is what layering is for.

So the later entry wins. `Config.bindings()` arrives in layer order, which means
"the last one wins" and "the highest layer wins" are the same sentence, and the
determinism is what makes the permissiveness safe. An unparseable chord or an
unknown action binds nothing and costs exactly one binding; the rest of the file
is applied normally, which is the same posture the TOML scanner takes towards a
line it cannot read (`DR-006`).

## Consequences

- There is no error set anywhere in the keymap stack, and no allocator. The
  table is 160 fixed entries and the warning list is 16, both capped for the
  reason `Config`'s are: a growable list needs an allocator, an allocator needs
  a failure path, and the failure path in a config loader is the code nobody
  tests. Overflow is a warning.
- `lookup` is a linear scan, at most 160 comparisons per keypress. A map would
  need an allocator and a hash of a tagged union to save something no human can
  perceive. The scan is commented as the thing that changes if per-mode maps
  ever arrive — and those need a different structure anyway.
- `actions.defaultAction` is deleted rather than kept beside the resolver. Two
  lookups over the same table agree until somebody edits one, and the resolved
  keymap is what dispatch actually asks.
- Under the legacy encoding the `shift+enter` row is never seeded (`DR-003`), so
  a config file binding it produces an entry that can never fire — with no
  warning. The file is not wrong; the terminal is, and it may not be tomorrow.
- **There is no unbind syntax.** `"ctrl+j" = ""` and `= "none"` are both an
  unknown action and both produce a warning. Nothing in v0.1 asks for
  unbinding.

## Revisit trigger

The first request for an unbind syntax. It is the one addition that makes the
conflict rule ambiguous: unbinding a chord and rebinding it become the same
operation with different arguments, and "a config chord that lands on a default
replaces it silently" stops being obviously right when the replacement is
*nothing*. Decide the semantics before the syntax.

A second trigger, weaker: a third warning list. Two adjacent lists in one shape
is a mild cost; three is a shared interface that should have existed.
