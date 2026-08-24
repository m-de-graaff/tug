# Golden transcripts

Each file is one renderer test's whole output — every frame in its script,
concatenated — escaped so it can be read in a diff:

- `\e` is ESC (0x1b)
- `\r` is a carriage return
- a real newline is a real newline

The renderer emits `\r\n` between physical rows, so a row break shows up as a
trailing `\r` on the line. A line beginning `\r\e[NF\e[0J` is a repaint: move to
column 0, up `N` rows, erase to the end of the display. `N` is the previous
frame's tail row count, and checking that it is are what these files are for.

These are read at run time by `src/shell/render/golden.zig`, from a path
relative to the build root — `zig build test` runs its binaries there.

To regenerate one, change the renderer, run `zig build test`, and copy the
transcript the failing test prints between its `--- golden <name> ---` markers.
Read it before you paste it: an off-by-one in a repaint looks exactly like a
correct repaint until it eats a line of somebody's scrollback.

There is no `--update` flag on purpose. A golden that can be refreshed without
being read records whatever the code did last, which is the opposite of a test.
