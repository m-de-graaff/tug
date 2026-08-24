# DR-004: Probing synchronized output, and caching the answer

**Status:** accepted
**Date:** 2026-08-24
**Phase:** 1

## Context

The renderer repaints its tail by moving the cursor up N rows, erasing, and
drawing again. On a terminal that renders each of those steps as it arrives,
the user sees the erase — a flicker at whatever rate the stream is arriving.

DECSET 2026, synchronized output, tells the terminal to buffer everything
between the set and the reset and present it as one atomic update. Where it is
supported, the flicker is structurally impossible rather than merely unlikely.

Support is uneven: kitty, wezterm, ghostty, foot and recent alacritty have it,
and tmux passes it through only in recent versions. There is no way to know
except to ask.

## Options

**Assume unsupported.** Never emit the guards. Costs the feature everywhere,
including on the terminals most likely to be used.

**Assume supported.** Emit the guards unconditionally. A terminal that does not
recognize `CSI ? 2026 h` ignores it, so this is *nearly* free — but "nearly" is
doing work, because a terminal that mis-parses it prints garbage into the
user's scrollback, and scrollback is the one thing tug never rewrites.

**Probe with `DECRQM` and cache.**

## Decision

Probe once at startup with `CSI ? 2026 $p` and cache the verdict for the
lifetime of the process.

The reply is `CSI ? 2026 ; <state> $y`. State 0 means the terminal does not
recognize the mode and state 4 means it is permanently reset; 1, 2 and 3 all
mean it knows what the mode is. Silence means unsupported.

The probe shares its 50 ms timeout with the kitty probe — both queries are
written together and one read window covers both replies, so a terminal that
supports neither costs one timeout rather than two.

**Cached, not re-probed.** The alternative is asking again after a resize or a
`/theme`, and there is no scenario where a terminal gains or loses DECSET 2026
inside one session. Re-probing would spend a timeout to confirm what is already
known.

**The flicker-free claim does not depend on this.** The renderer's real
guarantee is one `write()` per frame, enforced by a counting writer in the
golden tests. Synchronized output makes a well-behaved repaint atomic; it does
not rescue a badly composed one. Treating 2026 as the fix would mean shipping a
renderer that flickers on every terminal without it.

## Consequences

Makes easy: atomic repaints where they are available, at the cost of one
startup probe shared with another.

Makes hard: nothing structural. The guards are emitted or not around code that
is already correct either way.

Revisit if: a terminal turns up that answers the kitty probe and the 2026 probe
in the opposite order, which would break the single shared read window. The fix
is two windows and one more timeout; the code is written so that is a local
change.
