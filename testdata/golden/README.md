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

These are read at run time by `src/shell/render/transcript.zig`, from a path
relative to the build root — `zig build test` runs its binaries there. Two
suites write them: `src/shell/render/golden.zig` drives the renderer from a
hand-written event script, and `src/shell/provider/golden.zig` drives it from
the mock provider through the cadence engine, one `mock-*.txt` per fault mode.

Two of the `mock-*` files look wrong at a glance and are not:

- **`mock-empty.txt` is empty.** That is the fault: a response with no text in
  it paints nothing at all. An empty file here means the assertion held, not
  that nobody generated it.
- **`mock-oversized-chunk.txt` is several hundred lines.** Its fault sends a
  single 8 KiB delta, which is a few hundred physical rows at 40 columns, and
  all of them commit to scrollback in one frame. It is painted once rather than
  every four chunks precisely to keep it to that; painting through it produced a
  thousand lines, and a golden nobody reads is not a test.

To regenerate one, change the renderer, run `zig build test`, and copy the
transcript the failing test prints between its `--- golden <name> ---` markers.
Read it before you paste it: an off-by-one in a repaint looks exactly like a
correct repaint until it eats a line of somebody's scrollback.

There is no `--update` flag on purpose. A golden that can be refreshed without
being read records whatever the code did last, which is the opposite of a test.
