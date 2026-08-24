# DR-003: The kitty keyboard protocol, and what happens without it

**Status:** accepted
**Date:** 2026-08-24
**Phase:** 1–2

## Context

Two things a shell needs are impossible in the legacy terminal input encoding.

**Shift+Enter.** The obvious chord for "newline without submitting". In the
legacy encoding both Enter and Shift+Enter arrive as the single byte `0x0D`.
The terminal does not send the modifier, so no amount of cleverness in the
decoder can recover it.

**An unambiguous Escape.** A lone `ESC` byte is both the Escape key and the
first byte of every arrow key, function key and CSI sequence. Telling them
apart means waiting to see whether more bytes follow, which makes pressing
Escape feel slow and makes a slow link look like a keypress.

The kitty keyboard protocol solves both by reporting keys as CSI-u sequences
carrying an explicit modifier field. kitty, ghostty, wezterm, foot and recent
alacritty implement it. Windows Terminal does not, and neither does tmux
without configuration.

## Options

**Ignore it.** One code path. Shift+Enter is unavailable everywhere and Escape
is always ambiguous, in 2026, in terminals that have supported better for
years.

**Require it.** Clean decoder, and tug refuses to run in a terminal a large
number of people use.

**Probe, and degrade with a stated fallback.** Two code paths, and the
difference is visible to the user rather than mysterious.

## Decision

Probe with `CSI ? u` and push the progressive-enhancement flags when the
terminal answers. Flags 1 (disambiguate escape codes) and 2 (report event
types) only — deliberately not flag 8, "report all keys as escape codes",
because tug wants text to stay text.

The fallbacks are stated rather than implied:

- **Newline is `shift+enter` where the protocol is active and `alt+enter`
  where it is not.** `/keys` displays which one is live, annotated with the
  reason: `newline: alt+enter — kitty protocol unavailable`. The docs say the
  same thing. A user on Windows Terminal should learn this from tug, not from
  pressing Shift+Enter and watching their message send.
- **Escape disambiguation only exists in the fallback path.** With the protocol
  active, Escape arrives as `CSI 27 u` and there is nothing to disambiguate.
  Without it, a lone `ESC` waits **30 ms** for a continuation before it is
  taken to be the Escape key.

30 ms is a compromise between two failure modes rather than a measurement of
any terminal. Shorter, and a function key's bytes arriving in two reads over a
slow ssh link decode as Escape followed by garbage. Longer, and pressing Escape
feels laggy — the threshold where a keypress stops feeling instant is around
50 ms, so the budget has to sit under it.

The probe itself carries a **50 ms** timeout and treats silence as "not
supported". Probing happens after the first paint, so the startup budget of
10 ms is unaffected by a terminal that never answers.

Every push is matched by a pop on every exit path. Leaving the flags pushed
means the *next* program in that terminal receives key events in a protocol it
does not speak, having never been consulted. That is the worst thing tug could
do to a terminal, and `Stack.popAll` exists to make it impossible.

## Consequences

Makes easy: a shift+enter that actually works, and instant Escape, on terminals
people have already chosen.

Makes hard: two input paths, which is two things to test. The corpus tests
exist for exactly that, and every decoder test that involves Escape runs in
both modes.

Revisit if: Windows Terminal implements the protocol, at which point the
fallback becomes vestigial rather than load-bearing — but it stays, because ssh
into an old box is forever.
