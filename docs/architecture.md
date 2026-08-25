# How tug is built

Three things carry the weight in v0.1: a loop that sleeps, a tail that is
repainted, and a block that is committed once. Everything else hangs off them.

## The module graph

```
  tugproto ──▶ tugcore ──▶ tugshell ──▶ tug
  the wire    sans-IO      terminal      the
  vocabulary  logic        frontend      executable
```

Each module may import only the ones to its left. The boundary is enforced by
the build graph rather than by convention.

`tugcore` is **freestanding**: no filesystem, no sockets, no threads, no clock.
`zig build wasm-check` compiles it for `wasm32-freestanding` on every push, so
reaching for `std.fs` there fails CI — years before anyone actually runs the
core in a browser. That job is the whole reason the sans-IO discipline survives
contact with a deadline.

The executable is thin on purpose. It parses arguments, wires the modules
together, and hands control to the frontend. What makes `libtug` and
`tugcore.wasm` possible later without a rewrite is that nothing interesting
lives in `main.zig`.

## The loop

```
        ┌──────────────────────────────────────────────┐
        │                                              │
        ▼                                              │
   poll({ stdin, wake })  ◀── timeout: next render deadline
        │                       (or none at all, when nothing is dirty)
        ▼
   decode input  ──▶ KeyEvent / PasteEvent
        │
        ▼
   drain the queue  ──▶ bounded at capacity, never "until empty"
        │
        ▼
   publish on the bus  ──▶ session_start … stream_delta … turn_end
        │
        ▼
   paint, if dirty and the frame budget allows ──────────┘
```

One blocking `poll`, one wakeup mechanism, one deadline. Nothing else.

**Idle is zero CPU**, and it is structural rather than tuned: when nothing is
dirty the scheduler returns *no* timeout, so the process sits in `poll`
indefinitely. Two writers can wake it — the provider thread and the `SIGWINCH`
handler — and both go through a self-pipe (`DR-002` explains why not `eventfd`),
coalesced behind an atomic so at most one byte is ever in flight and the signal
handler's write can never block.

**The frame budget is ~8 ms**, so at most about 125 paints a second at any input
rate, with an immediate flush at `stream_end` and turn boundaries so endings
never feel laggy. Half a second of a real provider thread pushing as hard as the
queue will take paints 37 times in Debug against a ceiling of 66; painting on
every drain instead gives 85.

**Two liveness bugs lived here until a firehose found them**, and both are worth
knowing because neither is reachable from a unit test. The waker cleared its
pending flag *before* the read, so a byte written in that window was collected by
that read while the flag stayed set, after which every wake was suppressed as
redundant. And the queue drain looped until `pop` came back empty, which against
a producer that refills the ring mid-drain never returns at all — and a loop that
cannot leave its drain never reaches the paint the frame budget is expressed in.
Bounding the drain at the ring's capacity is the fix, and it is why the arrow
above says what it says.

## The tail

```
  ┌─ committed scrollback ────────────────────────┐
  │  printed once. belongs to the terminal now.   │  never touched again
  │  the terminal owns its wrapping, its          │
  │  selection, its scroll position.              │
  └───────────────────────────────────────────────┘
  ┌─ active tail ─────────────────────────────────┐
  │  the streaming block, the status hint,        │  erased and repainted
  │  and the prompt.                              │  every frame
  └───────────────────────────────────────────────┘
```

A repaint is: cursor to column 0, up N rows, erase below, write the frame — all
of it inside synchronized-output guards where the terminal supports them
(`DR-004`).

**One `write()` per frame.** The frame is composed in a buffer and flushed once.
A counting writer in the tests enforces it, and this invariant *is* the
flicker-free claim — with or without terminal support for synchronization.

**N is counted by the function that emits the rows.** The same code runs twice:
once against a null writer to measure, once against the real one to draw. Two
functions would drift, and drift here eats a line of the user's scrollback
permanently. The renderer wraps to the terminal's width itself rather than
letting the terminal do it, which is what makes the count knowable at all.

**A resize abandons the old tail** rather than repainting over it. The rows
already on screen are hard lines that the terminal re-wraps itself, so the
recorded count no longer describes them — and the terminal breaks rows at the
column while tug breaks them at spaces, so the two disagree about how tall the
same text is. Moving back over the old count would either strand rows or
overshoot into committed scrollback and erase it. The old tail is left where it
stands and becomes scrollback. The cost is the tail appearing twice across a
resize, once at each width.

## The block model

```
   user ──submit──▶ [user block]      ──commit──▶ scrollback
                          │
                    request_start
                          ▼
                    [assistant block] ──stream_delta──▶ grows in the tail
                          │
                      stream_end
                          ▼
                       commit ────────────────────▶ scrollback

   /help, a warning, an interruption ──▶ [notice block] ──▶ scrollback
```

Three kinds: `user`, `assistant`, `notice`. A block finalizes, renders into
scrollback in its final form, and leaves the tail. **Scrollback is append-only**,
exactly like the session files it foreshadows in v0.4 — and it is why a theme
switch does not recolour what is already on screen.

Markdown is parsed **incrementally and line-by-line**: complete lines are
classified (headings, list items, fence open and close) and the trailing
incomplete line is held back from *inline* parsing only. Block classification is
a prefix scan and never needs the newline — a streamed bullet that shows a
literal `- ` until its line ends is the bug that taught us the difference.

Command output is a `notice` block fed through the ordinary renderer, by way of
a 25-line `std.Io.Writer` adapter, so `/config` and `/keys` reuse the same report
writers `--debug-config` prints and nothing is `printf`'d around the pipeline
(`DR-014`).

## Where the numbers come from

Every budget the README states is a CI job, and each one is a script in
`scripts/` you can run by hand.

| Budget | Gate |
|---|---|
| Binary ≤ 500 KiB, and ≤ the ratchet | `scripts/size-gate.sh`, twice |
| `--version` ≤ 2 ms | `scripts/bench-version.sh`, hyperfine |
| Cold start ≤ 10 ms | `scripts/first-paint.sh` — the binary times itself, see `DR-015` |
| Idle ≤ 10 MiB, 0 % CPU | `scripts/idle-budget.sh`, `/proc` on a parked shell |
| Leak-free over 1,000 interactions | `scripts/soak-session.sh`, Debug + DebugAllocator + tmux |
| Zero network code | `scripts/no-network.sh`, a grep that stays a grep |
| Terminals degrade rather than hang | `scripts/terminal-matrix.sh` |
| `tugcore` is freestanding | `zig build wasm-check` |
| CI wall ≤ 5 min | the `wall-clock` job, which fails the run |
