# Terminal matrix — tug v0.1

What tug has been run against, and what each terminal turned out to support.
The roadmap's v0.1 exit criterion names five terminals; this table records what
each one actually did rather than what the code expects.

**Two tiers of evidence, and they are not interchangeable.** A scripted row is
checked by `scripts/terminal-matrix.sh` in CI on every push. An eyeball row is a
human looking at a screen — because the renderer's failure mode is a corrupted
screen rather than a wrong byte, and a pty transcript being right is not the
same as a screen looking right.

## Scripted — green in CI

Produced by `tug --caps` under `script(1)` and under `tmux`, on
`ubuntu-24.04`.

| Environment | kitty keyboard | Synchronized output | Bracketed paste | Colour tier |
|---|---|---|---|---|
| bare pty, `COLORTERM=truecolor` | unsupported | unsupported | yes | `truecolor` |
| bare pty, `TERM=xterm-256color` | unsupported | unsupported | yes | `ansi256` |
| `TERM=dumb` | unsupported | unsupported | no | `none` |
| `NO_COLOR=1` over `COLORTERM=truecolor` | unsupported | unsupported | yes | `none` |
| inside tmux, `TERM=xterm-256color` | unsupported | unsupported | yes | `ansi256` |

A pty is not a terminal emulator and answers neither probe, so every row above
reports both as unsupported. That is the point of these rows rather than a
disappointment in them: what they gate is Phase 1's probe-hygiene rule — an
unanswered probe degrades inside its 50 ms budget and never hangs startup.
`--caps` used to hang on exactly this, which is why the gate exists.

`NO_COLOR` beating `COLORTERM` is deliberate. The variable is a user's
instruction; the other is a capability report, and an instruction outranks a
report.

## Eyeball — unrecorded

**None of these four has ever run tug.** tug is developed on Windows against a
WSL toolchain and none of them is installed there; CI runners have no terminal
emulator. This is carried item 9 in the phase TODO, open since Phase 4, and it
is the one v0.1 exit criterion no machine in this project's environment can
close.

Run these three commands in each terminal and fill in the row. It is about two
minutes per terminal.

```sh
# 1 — what the terminal says it can do
tug --caps

# 2 — no flicker at a cadence no real provider will reach; resize mid-burst
tug --provider mock --mock-fault firehose

# 3 — the cursor. Type into it, submit, resize mid-response, watch where the
#     caret sits. DR-011 is the arithmetic; a corrupted screen is its failure.
tug --provider mock
```

| Terminal | kitty keyboard | Synchronized output | Colour tier | Flicker at firehose | Cursor after resize | Notes |
|---|---|---|---|---|---|---|
| kitty | unrecorded | unrecorded | unrecorded | unrecorded | unrecorded | |
| alacritty | unrecorded | unrecorded | unrecorded | unrecorded | unrecorded | |
| wezterm | unrecorded | unrecorded | unrecorded | unrecorded | unrecorded | |
| ghostty | unrecorded | unrecorded | unrecorded | unrecorded | unrecorded | |

`shift+enter` is the visible consequence of the first column: where the kitty
keyboard protocol is active it inserts a newline, and where it is not the
fallback is `alt+enter`. `/keys` prints which one is live, annotated, and
`DR-003` is the decision behind it. Every scripted row above runs without the
protocol, so `alt+enter` is the only one of the two that any machine here has
exercised.

The key corpus in `testdata/keys/` is empty for the same reason. Its README
holds the capture procedure and reserves the file names; `tug --debug-keys`
is what produces one.

## Known cosmetic issues

Each of these is documented rather than fixed, and each has a phase-TODO item
behind it.

- **`/keys` wraps on an 80-column terminal.** Its longest row is 84 columns —
  the `shift+enter` binding plus its `(kitty keyboard protocol only)`
  annotation. The renderer wraps it correctly; it is simply not pretty. Item 41.
- **A resize shows the tail twice, once at each width.** The rows already on
  screen are hard lines the terminal re-wraps itself, so the recorded row count
  no longer describes them. The old tail is left where it stands and becomes
  scrollback, which is the same append-only doctrine as everywhere else in the
  renderer. Phase 4.
- **A theme switch does not repaint committed scrollback.** Same rule. A user
  can now cause it from inside the shell with `/theme` rather than only across
  a restart, so it is behaviour somebody will see. Item 39.
- **`code_bg` does not extend to the row edge.** A shaded code line is as wide
  as its text, so its right edge is ragged. Padding to the terminal's width is
  where the row arithmetic breaks; `DR-007` names the upgrade path. Item 33.
