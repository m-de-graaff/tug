# Key sequence corpus

Recorded byte streams from real terminals, replayed as table tests against the
decoder. A corpus entry is the only evidence that tug decodes a chord correctly
in a terminal nobody has in front of them right now.

## Capturing

Run the debug mode in the terminal being recorded and press the chords in the
list below, in order:

```sh
tug --debug-keys --raw > testdata/keys/<terminal>.txt
```

One file per terminal, named after `TERM` or the emulator: `kitty.txt`,
`alacritty.txt`, `wezterm.txt`, `ghostty.txt`, `tmux.txt`.

## The chord list

Recorded in this order so a diff between two terminals lines up:

1. `a`, `Z`, `é`, `中`, an emoji
2. `enter`, `tab`, `backspace`, `escape`
3. `up`, `down`, `left`, `right`
4. `home`, `end`, `page_up`, `page_down`, `delete`, `insert`
5. `ctrl+a`, `ctrl+c`, `ctrl+k`, `ctrl+u`, `ctrl+w`
6. `alt+b`, `alt+f`
7. `shift+enter`, `alt+enter`
8. `ctrl+shift+p`, `shift+up`, `ctrl+right`
9. `f1` through `f12`
10. A paste containing a newline, a tab, and an escape sequence

## Status

The matrix terminals are captured during Phase 11, which is where the
certification pass lives. The names are reserved here so the test table has a
stable shape and a missing terminal is visibly missing rather than silently
absent.

| Terminal | Captured |
|---|---|
| kitty | no |
| alacritty | no |
| wezterm | no |
| ghostty | no |
| tmux | no |
