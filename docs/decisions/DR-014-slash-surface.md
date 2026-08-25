# DR-014: The slash surface — what a leading `/` means, and where the warnings finally land

**Status:** accepted
**Date:** 2026-08-25
**Phase:** 10

## Context

Phases 6 to 9 built a shell that edits, streams, rebinds and recolours, and left
almost none of it reachable from inside itself. `Renderer.setTheme` worked with
no caller. `Keymap.write` produced a `/keys` screen no command rendered.
`Config.write` produced a provenance table only a debug flag printed. And three
separate warning lists — the config's, the keymap's, the theme's — accumulated
across three phases with nowhere to appear but `--debug-config`, a flag a user
has no reason to know exists.

The carried-forward list says this plainly, three times. Item 25: "a person who
mistypes a chord and never runs the debug flag sees their binding not work and
gets no explanation." Item 31 is the same sentence with the count raised to
three. Item 30: "`/theme` is a mechanism with no caller."

So Phase 10 is not really "add five commands". It is the phase where the shell
becomes able to answer questions about itself, and three decisions had to be
made to get there: how a line becomes a command, where a command's output goes,
and what happens to the warnings.

## How a line becomes a command

**A line whose first non-space byte is `/` is a command — unless the first token
contains a `/` of its own.**

The prefix itself was never in doubt; every tool in this category uses it and a
different one would have to be taught. The tension is entirely in the second
half of the rule.

**No escape at all — every leading slash is a command.** Rejected. A person
typing `/etc/hosts is wrong, can you look at it` gets `no such command
('/etc')`, and their sentence is gone. Paths beginning with `/` are the single
most common thing a developer types that starts with a slash and is not a
command, and a harness for developers that eats them is a harness with a
practical joke in it.

**A character class on the name — `[a-z][a-z0-9_-]*` or similar.** Rejected,
because it does not actually solve the case it looks like it solves. `/etc` is a
perfectly good match for that class; what makes `/etc/hosts` not a command is
the *second* slash, which a class on the name never sees. A class would also
have to be specified, documented, and re-litigated the first time somebody wants
a command with a dot in it. It buys nothing the slash check does not.

**Requiring the command to be the whole line.** Rejected outright: `/theme
light` is the argument-taking form the phase spec names, and a rule that
forbids it forbids half the surface.

**One `/` in the first token means it is not a command.** Chosen. It is one
`indexOfScalar`, it costs nothing, and it is a rule that fits in a sentence a
user can hold: *tug's commands do not have slashes in their names, so a word
that does is a path.* The residual surprise — `/2026-08-25 was the day` reports
an unknown command — is a line a person will retype once, and there is no rule
that removes it without also removing `/theme light`.

The suggestion on a miss is `core.nearest`, the Phase-8 edit-distance helper,
handed the same command-name list `/help` prints. A bare `/` has no word to be
close to, so it prints the sentence that points at `/help` rather than a
suggestion it does not have.

## Where a command's output goes

**A `notice` block, written through a `std.Io.Writer` adapter that feeds the
renderer.**

The alternative worth naming is not "print it directly" — the phase spec forbids
that by name, and for good reason: a `printf` around the pipeline is a frame the
renderer did not compose and cannot account for in its row arithmetic. The real
question is how the three existing report writers reach a block.

`Config.write`, `Keymap.write` and `Theme.write` all take a `*std.Io.Writer`.
`Renderer.feed` takes bytes. Something has to bridge them.

**A fixed stack buffer, written once and fed once.** Rejected on a number.
`Keymap.write` against a config using the full `max_bindings` of 128 — plus the
24 defaults — is roughly 11 KiB. A buffer sized for that is an 11 KiB stack
frame inside a loop callback, and a buffer sized for anything less is a silent
truncation the day somebody raises `max_entries`. `std.Io.Writer.fixed` reports
overflow as `error.WriteFailed`, which at the call site is indistinguishable
from a broken terminal.

**Reimplementing the three writers against `Renderer.feed`.** Rejected. It is
three functions duplicated, and three chances for `/config` and
`--debug-config` to disagree about what tug read — which is precisely the
disagreement a person would consult both screens to resolve.

**A `BlockWriter` adapter.** Chosen, at twenty-five lines in
`src/shell/render/block_writer.zig`. Its buffer is a batching choice rather than
a limit: it drains into `feed` whenever it fills, so a 1 KiB caller buffer
streams an 11 KiB table. The one wrinkle it has to handle is that `feed` can
fail to allocate and `std.Io.Writer.Error` is `error{WriteFailed}`, which cannot
carry that — so the real error is stashed on the struct and re-raised by
`finish`. Without that, a machine out of memory would tell the user its terminal
was broken. It is the same shape `Session.failed` uses, for the same reason.

## Where the three warning lists live

**All three in full on `/config`, and one counted line at startup.**

This is the decision items 25, 26 and 31 were waiting for, and it is two
decisions wearing one hat: which screen holds the detail, and whether anything
is said unprompted.

On the screen:

**One list per screen — config notes on `/config`, keymap problems on `/keys`,
theme notes on `/theme`.** Rejected. It is tidier and it is worse. A person who
knows *which* subsystem is wrong did not need to be told; the person who needs
this is the one whose config "isn't working", and giving them three screens to
check is giving them a search rather than an answer.

**All three on `/config`.** Chosen. They are all answers to "what did tug make
of what I configured", they already share one output shape and one `origins`
array indexed by layer, and `--debug-config` has printed exactly this sequence
since Phase 9 — so the screen and the flag agree by construction rather than by
maintenance.

At startup:

**Print all three lists into scrollback.** Rejected. A config with a stray comma
and two mistyped chords opens the shell with seven rows about it, every session,
forever. That is the warning people learn to scroll past, which `DR-013` already
rejected in the narrower case of per-chord conflict warnings.

**Say nothing; leave it to `/config`.** Rejected, because it is what Phases 7 to
9 did and it is why three carried-forward items exist. A person whose binding
silently does nothing has no reason to suspect there is a screen to go and look
at.

**One line, once, only when there is something behind it.** Chosen: `2 warnings
in your configuration - run /config to see them`. It costs one row of scrollback
to the people who have a problem and nothing at all to the people who do not,
and it converts "my binding doesn't work" from a mystery into a lookup. The
singular is spelled separately because a shell that opens by saying `1 warnings`
is a shell nobody trusts about anything else either.

### The `Diagnostic` trigger, checked a second time

`DR-013` named a third warning list as the point at which a shared `Diagnostic`
interface would be paying for itself. `DR-007` checked that when the third list
appeared and found it did not fire, because a theme file's problems turned out
to be a config file's problems plus one new kind.

Checked again here, now that something actually renders all three in one place,
and the answer is the same. `writeWarnings` is six lines calling three writers
that already agree on their output shape. An interface with three
implementations that already agree costs a type, three conformances and a
vtable, and saves nothing. The trigger to revisit is a fourth list whose shape
is genuinely different — one without a layer, or one that needs more than a line.

## Consequences

Easy now: adding a command. The registry is a table and the handlers are a
switch, and the `/demo` probe run in this phase says the cost in a number — two
source files, three insertions, one deletion, nothing under `render/` or
`loop/`. The roadmap's *a new slash command requires zero renderer/loop changes*
is on record rather than asserted.

Also easy: a screen that reads a subsystem. Anything with a `write(out)` method
is one arm away from being a command.

Made hard, deliberately:

- **Arguments beyond a trimmed string.** `Parsed.run.rest` is the whole
  argument, unsplit. A command that wants two arguments splits it itself. The
  moment two commands want the same splitting is the moment to put it in the
  registry, and not before.
- **Completion past the first token.** `complete` answers about command names
  only, and it refuses an ambiguous prefix rather than completing to the longest
  common one — no two of the five names share a first letter, so the code would
  have no input.
- **A command that is not on `/help`.** There is nowhere to register one. That
  is the point.

What would make this wrong: a command whose output is not text. A `/model`
picker or a `/tree` browser wants to take the screen, and this design has one
sink — an append-only notice block — with no notion of a mode that owns input.
That is a v0.5 problem and it will need a decision of its own; nothing here
forecloses it, because a mode would sit beside the router rather than inside it.

The other trigger is scale: five commands fit in a linear scan and a flat table.
Fifty do not, and the day plugins register commands (v0.5, per the roadmap) the
table becomes a registry with insertion, and `complete` and `parse` become
lookups. The shapes here are chosen so that change is a change of container
rather than of interface.
