# Configuring tug

Everything a `config.toml` can say, what a chord can be bound to, and what a
theme can colour. One document, because a reader with a config file open does
not want three.

Nothing in this stack has a failure path. An unknown key warns and is ignored,
a bad chord warns and is dropped, an unknown theme falls back to the dark
built-in. A typo cannot stop a shell from opening — see [When you get it
wrong](#when-you-get-it-wrong) for where the warnings go.

## Where settings come from

Five layers, lowest first. A later layer overrides an earlier one, key by key.

| Layer | Where |
|---|---|
| `default` | Compiled in. |
| `user` | `~/.config/tug/config.toml`, or `$XDG_CONFIG_HOME/tug/config.toml`. On Windows, `%APPDATA%\tug\config.toml`. |
| `project` | `./.tug/config.toml`, relative to where tug was started. |
| `env` | `TUG_*` variables — see below. |
| `flag` | Command-line flags. `--theme` is the only one in v0.1. |

`/config` inside the shell prints every resolved value with the layer that set
it, and `tug --debug-config` prints the same table without opening a terminal.
The `from` column is the whole point: a setting you cannot explain is a setting
you cannot change with confidence.

**Config is read once, at startup, and never re-read.** Editing a file while a
shell is open does nothing; live reload is refused by name for v0.1. `/theme`
is the one thing that changes at runtime, and it goes through the theme registry
rather than through a config reload.

## Settings

```toml
theme = "dark"

[history]
enabled = true
max_entries = 1000
```

| Key | Type | Default | Environment |
|---|---|---|---|
| `theme` | string | `"dark"` | `TUG_THEME` |
| `history.enabled` | bool | `true` | `TUG_HISTORY` |
| `history.max_entries` | integer | `1000` | `TUG_HISTORY_MAX` |

`history.enabled = false` means the shell keeps a history for the session and
writes no file. `max_entries` truncates from the front, so the oldest entries
are the ones that go.

The environment carries **scalar keys only**, and the mapping above is the whole
of it. `[keys]` has no environment form on purpose: a table of chords is not
something a variable should be able to say.

## Keys

```toml
[keys]
"ctrl+j" = "newline"
"ctrl+g" = "quit"
```

A binding is a chord on the left and the name of an action on the right.

**Chord grammar.** Modifiers joined by `+`, then a key: `"ctrl+shift+p"`,
`"alt+enter"`, `"f5"`, `"ctrl+a"`. Modifier order does not matter —
`"shift+ctrl+p"` and `"ctrl+shift+p"` are the same chord and are stored the same
way. An unparseable chord is reported with the offending string quoted, and the
binding is dropped.

**Actions.** These are the names the right-hand side takes. The list is the
registry, and `/keys` prints it live with whatever chords are actually bound.

| Category | Action | Default chord | What it does |
|---|---|---|---|
| session | `submit` | `enter` | Send the draft |
| | `interrupt` | `ctrl+c` | Clear the draft, or stop a running response |
| | `end_of_input` | `ctrl+d` | Delete forward, or quit on an empty draft |
| | `clear_screen` | `ctrl+l` | Clear the screen and repaint |
| | `quit` | *unbound* | Leave, whatever the draft holds |
| movement | `move_left` | `left`, `ctrl+b` | Back one character |
| | `move_right` | `right`, `ctrl+f` | Forward one character |
| | `move_word_left` | `alt+b` | Back one word |
| | `move_word_right` | `alt+f` | Forward one word |
| | `move_line_start` | `ctrl+a`, `home` | Start of the line |
| | `move_line_end` | `ctrl+e`, `end` | End of the line |
| | `move_up` | `up` | Up a line, or recall the previous entry |
| | `move_down` | `down` | Down a line, or recall the next entry |
| | `history_prev` | *unbound* | Recall the previous entry, always |
| | `history_next` | *unbound* | Recall the next entry, always |
| editing | `newline` | `shift+enter` or `alt+enter` | Insert a line break without sending |
| | `complete` | `tab` | Complete the command name at the start of the draft |
| | `delete_back` | `backspace`, `ctrl+backspace` | Delete behind the cursor |
| | `delete_forward` | `delete` | Delete under the cursor |
| | `kill_word_back` | `ctrl+w` | Cut the word behind the cursor |
| | `kill_to_line_start` | `ctrl+u` | Cut to the start of the line |
| | `kill_to_line_end` | `ctrl+k` | Cut to the end of the line |
| | `yank` | `ctrl+y` | Paste the last cut |

Two of those need a sentence each.

**`newline` depends on the terminal.** Where the kitty keyboard protocol is
active it is `shift+enter`, which is what you want. Where it is not, no terminal
can tell `shift+enter` apart from `enter`, so the fallback is `alt+enter`.
`/keys` annotates whichever one is live, and `DR-003` records the decision.
`docs/terminal-matrix.md` says which terminals have been checked.

**`quit` ships bound to nothing.** Every obvious chord is taken or unsafe —
`ctrl+q` is flow control wherever `IXON` survives, and `ctrl+c` and `ctrl+d`
have graded behaviours worth keeping. An action with no chord is exactly what a
rebindable keymap is for. `/keys` lists it under `unbound` so it stays findable.

**Conflicts.** Two config layers binding the same chord to different actions is
a warning naming both actions and both layers; the later layer wins. A config
chord landing on a *default* is silent — that is the ordinary case of rebinding
something, not a mistake. `DR-013` argues the distinction. There is no unbind
syntax, refused by name in the same record as the one addition that would make
the conflict rule ambiguous.

**Unknown action names** get a nearest-match suggestion: `sumbit` is told about
`submit`.

## Themes

```toml
# ~/.config/tug/themes/solarized.toml
fg = "#839496"
dim = "#586e75"
accent = "#268bd2"
user_block = "#2aa198"
assistant_block = "default"
notice = "#b58900"
error = "#dc322f"
prompt = "#268bd2"
code_bg = "#073642"
```

```toml
# config.toml
theme = "solarized"
```

Nine **semantic slots**. The renderer knows what text *means*; only a theme says
what that looks like. `DR-007` is the schema.

| Slot | What it colours |
|---|---|
| `fg` | Ordinary text |
| `dim` | The status hint, and anything deliberately quiet |
| `accent` | Headings and emphasis |
| `user_block` | What you typed, once committed |
| `assistant_block` | What came back |
| `notice` | Command output, warnings, interruptions |
| `error` | Reserved — v0.1 has no error block, and the mock's mid-stream error surfaces as a notice |
| `prompt` | The prompt marker |
| `code_bg` | The background inside a fenced code block |

A value is `#rrggbb` or the literal `default`, which means "whatever the
terminal already uses". `default` is not a subtraction — it is how a theme
declines to have an opinion.

**Resolution.** `theme = "name"` checks the two built-ins — `dark` and `light` —
and then `~/.config/tug/themes/name.toml`. A theme name is **one path
component**: it may not contain a separator, because it comes from a config file
and a config file is not a trust boundary tug controls.

**Output tiers**, decided by what the terminal reports:

| Tier | When |
|---|---|
| `truecolor` | `COLORTERM=truecolor` |
| `ansi256` | A 256-colour `TERM`; colours are quantized to the 6×6×6 cube plus the gray ramp |
| `none` | `NO_COLOR` is set, or `TERM` promises nothing. Bold and dim only |

`NO_COLOR` beats `COLORTERM`: one is a user's instruction and the other is a
capability report.

`/theme` with no argument lists the built-ins and marks the live one. `/theme
name` switches immediately and repaints the tail. Committed scrollback keeps
its old colours, which is the same append-only rule as everything else in the
renderer.

## When you get it wrong

Warnings, never failures. Three lists — the config's, the keymap's and the
theme's — and all three are printed by `/config`. A shell that has anything to
warn about says so once at startup:

```
2 warnings in your configuration - run /config to see them
```

One row of scrollback for the people with a problem and none for the people
without. `DR-014` records why printing all three lists at startup was rejected.

Every warning carries a file, a line and a column:

```
/home/you/.config/tug/config.toml:3:1: warning: no such setting ('them')
```

Two limits of the TOML subset you will meet eventually, both deliberate and both
recorded in `DR-006`:

- **No arrays.** No key in v0.1 is one. A file that tries gets a named warning
  with a position rather than silence.
- **Escape sequences are refused, not decoded.** Every string the scanner yields
  is a slice of the source, and a decoded escape would need a buffer with an
  owner. A literal string is the escape hatch: `'C:\tug'`, in single quotes.

Columns count **bytes** from the start of the line, so a line with a multi-byte
character before the error reports a column no editor agrees with. Key names are
ASCII and values are short, so this is mostly reachable through a comment.
