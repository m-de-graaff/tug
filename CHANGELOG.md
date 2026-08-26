# Changelog

Every entry names what changed and what it costs. Budget changes and toolchain
bumps are changelog events by policy, never silent.

## Unreleased — v0.2 «Halyard»

### Changed

**The binary-size ceiling moves from 500 KiB to 2 MiB**, the v0.2 number in the
roadmap. v0.1's ceiling was the cost of a shell that could not talk to anything;
this version adds TLS, an HTTP client and two providers. The v0.1 ratchet — the
measured size plus ten per cent, 211 KiB — is suspended for the version rather
than nudged upward commit by commit, and is re-derived from the measured size at
the v0.2 tag. Until then the 2 MiB ceiling is the only live size gate.

**The zero-network grep becomes a confinement grep** (`DR-016`). `std.http`,
`std.Io.net` and `std.crypto.tls` are permitted under `src/providers/transport`
and fail the build anywhere else, so the transport seam is enforced
mechanically rather than by review. The claim narrows from "tug has no network
code" to "tug's network code is reachable from exactly one directory" — the
second being the one that can still be true in a version with providers in it.

Two of the four patterns the v0.1 gate watched for, `std.net` and
`std.posix.socket`, do not exist in Zig 0.16 at all; sockets live under
`std.Io.net`. They stay in the pattern to catch snippets written against an
older std, but a green gate had been proving less than it appeared to.

### Added

**Failures are five words a user can act on.** 401 and 403 name the variable to
export; 429 carries the wait the provider asked for, in either form the standard
allows; a redirect or unparseable headers are `decode` rather than `transport`,
because telling someone to check their network sends them after a problem that
is not there. One file maps everything, because a taxonomy applied in two places
is two taxonomies.

**Retries, and the line they never cross** (`DR-019`). `transport` and `server`
retry with jittered backoff; a 429 retries only when it says how long, because
guessing is how a client becomes part of the incident; `auth` and `decode` never.
And a request that has produced output is never retried: you keep what arrived
and an error saying it ended early, rather than two model responses spliced
together and presented as one.

**Four places a key can come from** (`DR-024`): `--key`, the preset's environment
variable, `provider.key`, and `provider.key_cmd = "pass show anthropic"` — run
once and held for the process, so a secret can stay in whatever you already
trust. A failing command shows its own stderr with anything key-shaped scrubbed
out. `/config` prints `<set>` or `<unset>` and never the key; there is a test on
that surface.

**Two providers, streamed.** The Anthropic Messages API and the OpenAI
chat-completions shape — the second covering Ollama, OpenRouter, Groq, vLLM and
LM Studio from one implementation. Each is a pure request builder and a pure
mapper, so the entire path from request bytes to `StreamEvent`s runs in CI from
recorded responses with no socket anywhere.

Prompt caching is on and has no knobs (`DR-022`). Tool calls are parsed and not
executed, with one notice per turn saying so — v0.3 is where the model gets
hands.

**`tug dev stream`** (debug builds only) streams one real turn from one real
endpoint. Model text on stdout, every diagnostic on stderr, `--json` for ndjson
`StreamEvent`s — the same bytes Phase 8's `--json` will print. It is also the
first thing in tug shaped like the pipe frontend: no termios, no probes, no
protocol modes.

**The replay proof.** `zig build replay` runs every recorded response through the
whole provider stack and compares the emitted ndjson byte for byte, at five chunk
sizes down to one byte at a time. The roadmap's exit criterion, as a job name
rather than a sentence.

Binary size at the end of M2: **220,832 B**, against the 2 MiB ceiling. Lower
than it will be: `tug dev stream` is the only caller of the transport and it is
debug-only, so the release binary still discards TLS as dead code. The number
that the v0.2 ratchet is derived from is the one measured at the tag, after
Phase 7 puts a provider in the shell.

**A stream can be stopped.** `Esc` and a read timeout are the same physical
problem — a thread parked in a read that something outside it has decided should
end — so they get one mechanism: an atomic flag plus `shutdown(2)` on the socket,
with a watchdog pulling the same lever when no byte has arrived for the read
timeout. Cancel to thread-join is bounded at 100 ms and tested against a real
loopback server. `DR-018` has the argument, including why `Io`'s own
cancellation is the right answer for a program tug is not.

**The provider layer can open a socket.** `std.http.Client` over the standard
library's TLS 1.3, confined to `src/providers/transport` by `DR-016` and reached
only through the three-function seam of `DR-017`. Four policies ride with it, and
each is a refusal: no redirects — an API does not redirect, and following one
would send a key to whoever asked; no plaintext to a non-loopback host without an
explicit per-endpoint `insecure = true`; no compressed response encodings, which
would arrive correctly framed and in the wrong shape; and nothing constructed at
all before the first request, so the 10 ms prompt budget survives a configured
provider.

`--debug-wire` dumps a request with every header value redacted except a short
allow-list. Inverted from the usual arrangement on purpose: an auth header added
in some later version is redacted the day it is added rather than the day someone
remembers.

**A fixture transport** (`src/providers/fixture.zig`) replays a recorded response
through the same seam, at any chunk size, including the one-byte-at-a-time sizes
no real network produces. It lives outside the confinement grep's allowance, so
the gate proves mechanically that the offline path has no network in it.

**An incremental SSE parser** (`tugproviders`), v0.2's untrusted input decoder,
built like the terminal's: caller-owned buffers, `feed` then `next`, partial
input is not an error, nothing grows, and a returned event borrows until the next
call. Framing only — what a payload means belongs to the provider mappers, which
is what lets one parser serve two very different APIs. 147 lines of code against
the roadmap's promised ~150, with a fuzz target and a chunking-invariance
property that feeds every corpus entry at twenty random splittings and requires
identical events.

**`tug dev sse-dump`** (debug builds only): raw bytes on stdin, decoded events on
stdout. The milestone's demo and a permanent debugging tool.

**Stream events grew what v0.2 will see on the wire**: `tool_call_delta` for the
argument JSON both API shapes stream in pieces, cache-read and cache-creation
token counts kept apart from fresh input because they are priced apart,
`tool_use` and `refusal` stop reasons, and the retry-after a rate limit carries.
Requests, messages and model descriptors became types, and prices became data —
an unknown model renders tokens without a cost rather than guessing.

**One ndjson encoding of a stream event**, flat and tagged, golden-tested byte for
byte. The same bytes `--json` will print and plugins will speak, defined once so
the two cannot drift.

**Every test job runs inside a network namespace with no interfaces**
(`scripts/offline.sh`). A grep constrains what is written; the namespace
constrains what runs. A test that opens a socket fails rather than flaking.

**A canary key and the grep that hunts it** (`scripts/canary-grep.sh`), plus a
fixture layout whose sidecar attests what was checked. The gate exists before the
auth code it guards, because one added after the first leak arrives late.

**A nightly workflow** for deep fuzzing and a full-session memcheck, so the PR
pipeline keeps its five-minute wall.

## v0.1.0 «Hull» — 2026-08-25

### Milestone 1 «Raw echo» — Phases 0 to 2

**Phase 0, bedrock.** The module graph — `tugproto`, `tugcore`, `tugshell` and
the executable — exists before the code that fills it, and the build enforces
the direction of its imports. Every budget gate runs from this commit: binary
size, `--version` latency, the `wasm32-freestanding` compile of `tugcore`, and
a grep that fails the build on any network import. Each was broken on purpose
and observed failing before being trusted.

**Phase 1, terminal substrate.** Raw mode with `ISIG` off, so Ctrl+C means what
tug decides rather than unconditional death. Capability detection as a pure
function of the environment and probe answers, so the decision logic is
testable without a terminal. Restore reachable from four overlapping callers
and safe in all of them. A tier-2 Windows console backend behind the same
interface (`DR-009`).

**Phase 2, input decoding.** A pure state machine from bytes to `KeyEvent` and
`PasteEvent`: legacy CSI and SS3, Alt-as-ESC-prefix, kitty CSI-u, UTF-8 split
across reads, and unknown sequences swallowed under a length cap. Paste content
is stripped of ESC and C0 before it becomes an event, because a pasted escape
sequence that gets echoed back is a terminal-injection vector.

**Fixed after the fact.** `tug --caps` hung forever on a terminal that answered
neither capability probe. The probe wrote both queries and then blocked in a
read that a silent terminal never satisfies; the 50 ms timeout was printed in
the output and enforced nowhere. Every probe read is now gated on a `poll` with
that deadline, and the budget is spent once across both queries rather than once
per query.

### Milestone 2 «It streams» — Phases 3 and 4

**Phase 3, loop and event bus.** One blocking loop: wait, decode input, drain
the cross-thread queue, publish, render if dirty. It blocks in exactly one
place, and the timeout it waits with is the CPU budget — with nothing dirty and
no half-decoded sequence in hand there is no deadline at all, so an idle tug
consumes nothing. Measured: zero CPU ticks over five seconds parked, at 256 KiB
resident.

A typed event bus in `tugcore`, tagged by the event catalog so the compiler
enforces one payload per name. It has no locks and no allocator, which one
invariant buys: the bus runs on the loop thread only. Anything off that thread
pushes onto a bounded queue in `tugshell` that the loop drains and republishes.

Wakeups are a self-pipe, coalesced so at most one byte is ever outstanding —
which is what makes the write inside the `SIGWINCH` handler unable to block
(`DR-002`). Windows uses an auto-reset event for the same job and is still
tier-2.

The render scheduler caps painting at roughly 125 frames per second no matter
how fast events arrive, and paints immediately on the events that are endings —
a stream finishing, a turn boundary, a resize — because lag at the end of a
response is the kind a reader notices.

Cost: 2,432 bytes of binary, taking it to 118,712 of the 500 KiB budget.

**Also closed.** `scripts/exit-paths.sh` had never been run — it needs a POSIX
pty and tug is developed on Windows. It now runs green against both the Debug
and the shipping build: normal exit, `SIGTERM`, `SIGHUP` and `SIGINT` all give
the terminal back. Part of why it had never run is that `core.autocrlf` checked
it out with CRLF, which `sh` rejects on the `set -eu` line; `.gitattributes` now
pins shell and Zig sources to LF in the working tree.

**Phase 4, the renderer.** Markdown streamed into normal scrollback, without
ever rewriting it. The screen has two regions and they never mix: committed
scrollback is printed once and belongs to the terminal from that moment on, and
the active tail is bounded to fit on screen, erased and repainted every frame.
The rows a repaint moves the cursor back over are counted by the same function
that emitted them — called once with a null writer to measure and once with the
real one to draw — because two functions would drift, and drift here erases a
line of your scrollback permanently.

A frame is composed in one buffer and flushed once. That, rather than the
terminal's synchronized-output support, is the flicker-free claim; the DECSET
2026 guards are an optimization on top of it where `DR-004`'s probe says they
are available. A counting writer in the tests makes the one-write rule
something the build checks rather than something the code intends.

Markdown-lite, line-local by design: headings, both list kinds, fences, and
`**bold**`, `*italic*` and `` `code` `` inside a single line. An unmatched
marker stays the characters it is, so a stray asterisk can never style the rest
of a response. Widths are measured per codepoint against East Asian and
zero-width tables (`DR-005`), which is what lets the wrap know its own row count
exactly; grapheme clusters wait for v0.9. One dim row says a response is still
streaming and disappears when it commits (`DR-008`).

Six golden transcripts under `testdata/golden/` pin down what the bytes look
like, and a property test over 400 randomized scripts pins down the arithmetic
under them. `tug --debug-render` streams a hardcoded burst through the whole
thing at about a thousand deltas a second.

Two of this phase's own tests found bugs worth naming. Control characters in a
text delta used to reach the terminal, which makes a stray `ESC` — or U+009B,
its eight-bit form — an escape-sequence injection from whatever the provider
sent, the same attack paste content is already stripped of. And a line that
outgrew the screen before its newline arrived could not be committed, leaving a
tail the cursor-up could no longer reach the top of.

A review pass over the finished branch found eight more, two of them in the row
count itself. A resize made the count a lie in both directions — the terminal
re-wraps the hard lines already on screen, so moving back over the recorded
number either strands rows or erases committed scrollback — and the fix is to
abandon the old tail rather than guess: it becomes scrollback, and the new tail
is drawn below it. The status hint was written unwrapped and counted as one row,
so any terminal narrower than it orphaned a fragment per frame; it is now cut to
what fits.

Cost: 13,848 bytes, taking the binary to 132,560 of the 500 KiB budget. Tests
go from 76 to 140.

**Phase 5, the mock provider.** A seeded generator in `tugcore` and a cadence
engine in `tugshell`, either side of the interface v0.2's real providers will
satisfy. A provider is a blocking iterator of `StreamEvent` and nothing else —
an erased context and one function pointer, the same shape the bus already uses
for subscribers. The mock is its first tenant; the seam is the deliverable.

The generator is deterministic to the byte: the same seed produces the same
response on every platform and in every optimize mode, because the only source
of variety is a Xoshiro256 draw over a fixed corpus. It decides *what* is said.
The cadence engine, one layer out where the clock lives, decides how fast it
arrives and where it is cut — the part a real provider will get from the network
instead.

Seven named fault modes: `stall`, `midstream_error`, `oversized_chunk`,
`split_utf8`, `instant`, `firehose` and `empty`. Two are honoured in the core
and the rest in the cadence engine, because a fault about timing or chunk
boundaries cannot be expressed by a module with no clock. Each has a golden
transcript, driven by the real mock through the real cadence into the real
renderer.

Nothing in the loop or the renderer changed to make this work, which is the
claim Phases 3 and 4 were making and this is the first thing to test it. What
did change is the cross-thread queue: a queued payload's slice was borrowed, and
the producer's buffer is reused for the next chunk long before the loop drains
it. Slots now own their bytes — `push` copies in, `pop` copies out, 512 bytes a
slot and 64 slots (`DR-010`). A payload larger than a slot is refused rather
than truncated, and splitting one costs nothing, because a delta cut in two is
two deltas.

**Two liveness bugs, both latent since Phase 3, both found by the firehose.**
Each showed the same way: one frame painted and then a process that looked hung.
The waker lost wakeups — `drain` cleared its pending flag before the read, so a
byte written in that window was collected by that read while the flag stayed
set, after which every `wake` was suppressed as redundant and the loop sat in
`poll` forever. And the queue drain never returned: looping until `pop` comes
back empty is a livelock against any producer that refills the ring mid-drain,
and a loop that never leaves its drain never reaches the paint the frame budget
is expressed in. Ten seconds of firehose on a pty went from 8 KB and zero
repaints to 2.4 MB and seventy.

Both fixes have a test that fails without them. Neither bug is reachable
without a producer faster than the terminal, which is precisely what the fault
mode exists to be.

The frame budget itself now has a number rather than an assertion: half a second
of a real provider thread pushing as fast as the queue will take it paints 37
times in Debug and 34 in ReleaseSafe, against a ceiling of 66. Painting on every
drain instead gives 85, so the test discriminates rather than merely passing.
`scripts/mock-modes.sh` runs each mode through a real pty in CI — the only gate
that exercises `Loop.run`'s own body, which no portable unit test can drive.

`--debug-render` is gone. It was documented in Phase 4 as the last hardcoded
client before this phase replaced it; `--provider mock` is the replacement, with
`--mock-seed`, `--mock-cadence` and `--mock-fault` beside it.

Cost: 7,032 bytes, taking the binary to 139,592 of the 500 KiB budget. Tests go
from 140 to 184.

### Milestone 3 «It edits» — Phase 6

**Phase 6, the editor.** `tug` opens a prompt instead of printing its usage. The
draft is a byte buffer with a codepoint cursor and one kill slot; the emacs set,
multiline editing, and history navigation all reach it through a layer of named
actions rather than through key comparisons, which is the seam Phase 8 rebinds.
`repl.zig` contains no `KeyEvent` comparison outside its tests, and that is a
grep rather than a claim.

`--provider mock` answers every submission, one provider thread per turn, joined
when the turn ends. That is the milestone demo: type, submit, watch a response
stream into scrollback, get the prompt back underneath it.

**The renderer learned where the cursor is** (`DR-011`). A frame records how far
above its parking row it left the caret, and the next frame's rewind is short by
exactly that much. The prompt is hard-wrapped at the column where the rest of
the tail wraps at spaces — word wrap moves the character under your cursor to
another row while you are typing the word in front of it — and a draft taller
than the tail is windowed on the cursor rather than truncated. With no prompt on
screen the offset is zero and every Phase 4 and Phase 5 golden still matches
byte for byte, which is how the change was kept to its own path.

**History** is one entry per line in the XDG state directory, with backslash and
newline escaped so a multiline draft stays one line in the file (`DR-012`).
A submission rewrites the file: the first version appended with a positional
write, which failed on Windows, and the cap is 1,000 short lines once per
submission rather than per keystroke, so the append was optimising against a
bound that is already small (`DR-012`). Nothing is read until the first `up`.
Every filesystem error is swallowed: a shell that refused to start because
`$HOME` was read-only would be the worse bug.

**`--provider mock` changed meaning**, and it is the only breaking change in the
phase. It used to stream one turn and exit; it now opens a shell. `--once` is
the one-turn path, and it is what `scripts/mock-modes.sh` runs on.

**Fixed after the fact.** Two defects that needed an editor to be visible at
all. `enterRaw` used `TCSAFLUSH`, which discards input that has arrived and not
been read — everything typed between the process starting and raw mode engaging
was thrown away by the terminal driver. And the capability probe swallowed
whatever it read that was not a reply, which on a terminal that answers neither
query is a 50 ms window with a keystroke in it. Both were found by driving the
real binary through a pty, and neither was reachable from a unit test.

**Corrected while building it.** The vertical goal column is sticky: recomputing
it from the cursor on every press makes the caret drift left through short
lines, permanently.

`scripts/editor-session.sh` drives a real session through a pty in CI —
keystrokes, two turns, an interrupt, and a history file read back by a second
process. The in-process goldens under `src/shell/edit/golden.zig` pin the bytes;
the script pins the behaviour they cannot see.

Cost: 15,992 bytes, taking the binary to 155,584 — 30 % of the 500 KiB budget.
Tests go from 185 to 261.

### Milestone 4 «It's yours» — Phases 7 to 10

**Phase 7, config foundation.** Configuration layers: defaults, then
`~/.config/tug/config.toml`, then `./.tug/config.toml`, then `TUG_*`, then
flags. Every resolved value remembers which layer set it, and `--debug-config`
prints that column — which is Phase 10's `/config` arriving early through a
debug flag, the way `--caps` did for the terminal matrix.

**tug's config is a TOML subset, not TOML** (`DR-006`). Both vendorable
candidates parse into an allocated value tree and neither documents a line and
column in its errors, which is the one thing this phase exists to provide; and
vendoring was required either way, so the choice was only ever about which body
of code this repo maintains against a pinned compiler. What it maintains is 330
lines. Refused, each by name and with a position: floats, dates, arrays, inline
tables, arrays of tables, dotted keys, and escape sequences. The last of those
is a design rather than an omission — every string the scanner yields is a slice
of the source, which is what keeps it allocation-free, and a decoded escape
would need a buffer with an owner.

**Nothing in the stack has an error set.** Not the scanner, not the merge, not
the loader. A config file full of nonsense produces a config of defaults and a
list of warnings; a value of the wrong type keeps the value that was already
there. The spec asks that a typo in a keybind never brick the shell, and the way
to guarantee that is for the failure path not to exist. The capacities are fixed
for the same reason: a growable list needs an allocator, an allocator needs a
failure path, and the failure path in a config loader is the code nobody tests.

The config is read after the first paint, for the reason the capability probe
is: the cold-start budget is 10 ms and two file reads are not free.

Two settings ship with it that no phase asked for — `[history] enabled` and
`[history] max_entries` — because `theme` and `[keys]` have no consumer until
Phases 8 and 9, and a parser nothing reads is a parser nothing tests. They are
also what let `scripts/editor-session.sh` check the thing `--debug-config`
cannot: that the shell uses what the loader loaded.

Cost: 17,504 bytes, taking the binary to 173,088 — 33 % of the 500 KiB budget,
and 34 % of `DR-006`'s own 50 KiB bar for the whole config stack. Tests go from
261 to 296.

**Phase 8, actions and keymaps.** `"ctrl+j" = "newline"` in a config file now
rebinds the shell. A chord parses back into the `KeyEvent` that spells it —
`parseChord` is the exact inverse of the `writeChord` that has been on
`KeyEvent` since Phase 2, and the property test crosses every key the decoder
can produce with all sixteen modifier combinations. Modifiers are accepted in
any order; `space` has a name because `" " = "submit"` is a legal TOML key that
nobody can see in a diff.

**Four resolution rules, and `DR-013` argues each** (`src/shell/input/keymap.zig`).
A config chord that lands on a default replaces it *silently*, because
overriding a default is the feature and a warning that fires for everyone who
customised anything hides the one that matters. A config chord that lands on
another config chord is a conflict: the warning names both actions and both
layers, and the later entry wins — which, since Phase 7 collects bindings in
layer order rather than merging them, is the same sentence as the higher layer
winning. An unparseable chord and an unknown action each cost exactly one
binding; the unknown action gets a nearest-match suggestion, thresholded so that
nothing close enough means nothing suggested.

**The keymap's warnings are not config notes.** `tugcore` has no `KeyEvent` and
cannot acquire one while it still compiles for `wasm32-freestanding`, so a note
kind only `tugshell` can produce would sit in the module that cannot evaluate
it — and a conflict names two actions and two layers where a `Note` has one of
each. The cost is two adjacent warning lists in one format, and `DR-013` records
a third list as the trigger to reconsider.

**`quit` is a new action and ships with no chord.** `end_of_input` quits on an
empty draft and deletes forward otherwise, which is ctrl+d's bash behaviour and
not what somebody binding `"f10" = "quit"` means. Adding it was also the phase's
exit-criterion probe, executed rather than asserted: two files, no renderer, no
loop, no decoder, twelve lines for the action itself. `/keys` lists unbound
actions so an action with no chord stays discoverable.

`actions.defaultAction` is deleted. Two lookups over the same table agree right
up until somebody edits one, and the resolved keymap is what dispatch asks. The
editor goldens route through a default `Keymap` and still match byte for byte,
which is the check that the seed is the table that was there before.

`--debug-config` grows a second half: the live keymap grouped by category, each
row naming the layer that set it, then both warning lists. It resolves with the
kitty protocol off, because no terminal has been opened — the honest answer for
a flag reporting what was read rather than what is live in a window.

Cost: 9,792 bytes, taking the binary to 182,880 — 35 % of the 500 KiB budget.
Tests go from 296 to 325.

**Phase 9, themes.** `theme = "light"` in a config file now changes what the
shell looks like. The renderer stopped naming attributes and started naming
**meanings**: `md.Style` carries a slot — `notice`, `user_block`, `accent`,
`code_bg` and five more — and only a theme says what a slot's colour is
(`DR-007`). It is still exactly one byte, which every style comparison in the
wrapper depends on: eight foreground slots fit a `u3`, and `code_bg` is a
background and rides as a flag.

**`default` is a colour, and it is the idea the phase turns on.** Not black and
not unset — the terminal's own foreground, rendering as no bytes at all. Three
things are that one mechanism: a theme declining to repaint your prose, the
theme a renderer holds before any config has been read, and the whole `NO_COLOR`
tier. So a plain paragraph still costs zero escape bytes per row, and all
twenty-one goldens written before this phase are byte-identical after it.

**Every slot that carries meaning names what it degrades to** when there is no
colour — `notice` and inline code to dim, the user's echoed words to bold. That
is WCAG's "no meaning carried by colour alone" made mechanical, and it is
checked twice: the existing goldens are all rendered at the `none` tier and must
not move, and `theme-dark-none.txt` must be byte-identical to
`theme-light-none.txt`, because at that tier a theme has nothing left to say.

**Contrast is a test with a number, not a paragraph.** Every coloured slot in
both built-ins clears 4.5:1 against its reference background and against
`code_bg`, as written *and* after 256-colour quantization — the quantized check
being the one that matters, since the colour an `ansi256` terminal paints is not
the colour in the file. The tightest pair in the set is light `notice` on
`code_bg` at 4.50:1, and `registry.zig` is what tells you if you move it.

**The two built-ins differ only where they must.** Both leave `fg` and
`assistant_block` to the terminal, so they are identical for the model's prose;
they diverge on the six slots that have to be legible against a background of
known lightness, and on `code_bg`, the one background tug paints and therefore
the one place it has to know which way round the screen is. Both are
`@embedFile`d and go through the same parser as any file a user writes, which is
what makes "a hand-written theme loads by name" a property of the parser rather
than a second code path. User themes live beside the config, in
`~/.config/tug/themes/*.toml`; built-in names win, so editing `dark` means
copying it to another name.

**A theme's warnings are config notes**, and `DR-013`'s trigger was checked and
did not fire. A theme file's problems turn out to be a config file's problems —
a scanner refusal, an unknown key, a wrong type, a duplicate — plus `bad_color`,
which fits the existing shape unchanged. Two kinds joined the enum and nothing
else moved. `DR-007` restates the trigger as something sharper than "a third
list": a warning list needing a field `Note` does not have.

**`--theme <name>` is the first command-line flag that writes a config key**, so
Phase 7's `flag` layer finally has something above the environment other than a
unit test. `--debug-config` grows a third table — the resolved theme's slots —
and prints its warnings after the config's and the keymap's, which makes it the
only place a theme warning is visible until Phase 10, exactly where a keymap
warning lives today. It also stopped returning early from the argument loop, so
`--theme` written on either side of it survives.

**`/theme` the command is Phase 10's; its mechanism is here.** `setTheme` swaps
the theme and the next frame repaints the tail in it. Committed scrollback keeps
the colours it was printed in, and `theme-switch.txt` shows that as bytes: tug
does not move the cursor back over scrollback, so it cannot recolour it, so it
does not pretend to.

`scripts/theme-session.sh` drives six cases through a real pty and the real
binary and asserts the bytes a theme's colours spell — a file-named theme, the
other one so the first cannot pass by accident, `--theme` outranking the file, a
hand-written theme found by name, an unknown theme falling back rather than
failing, and `NO_COLOR` emitting no colour while keeping the attributes the
colours were carrying.

**Corrected while building it.** `isPlain` tested `@bitCast(style) == 0`, which
stopped being the same question as "did that style emit anything" the moment a
slot could be non-zero and still resolve to `default`. Every golden in the repo
moved at once, all by the same four bytes — which is exactly the failure the
byte-identical gate exists to produce, and it took one commit rather than
twenty-one regenerated files to find.

Cost: 8,608 bytes, taking the binary to 191,488 — 37 % of the 500 KiB budget.
Tests go from 325 to 375.

**Phase 10, commands.** Typing `/help` into tug now does something. A line whose
first non-space byte is `/` is routed to a command instead of a provider, and
the five commands of v0.1 expose everything the four phases before them built:
`/help` lists the registry, `/quit` leaves, `/config` prints the resolved
settings with the layer that set each one, `/theme` lists the themes or switches
the live one, and `/keys` prints the bindings that are actually in force.

The registry is a table and `/help` reads it, so an unregistered command cannot
appear in help — and a comptime check makes the converse true, so a command
cannot be added to the enum and left off the screen that lists it. Names come
from the enum's own tag names, so there is no second spelling to drift.

A path is not a command. `/etc/hosts is wrong` is a sentence somebody meant to
send, and a first token containing a slash of its own is submitted rather than
routed — one `indexOfScalar`, and a whole class of eaten prompt gone (`DR-014`).
A name that does not resolve gets the Phase-8 edit-distance suggestion:
`/thme` answers "did you mean '/theme'?". A bare `/` points at `/help`, because
there is no word for it to be close to.

Tab is an action now, called `complete`, bound in the default table like every
other chord — so somebody who wants completion on a different key rebinds it
from a config file. It finishes a unique command name and leaves a trailing
space for the argument; an ambiguous prefix completes to nothing rather than to
a guess.

Command output goes through the renderer as a `notice` block, not around it. A
twenty-five-line `std.Io.Writer` adapter drains into `Renderer.feed`, so
`Config.write`, `Keymap.write` and `Theme.write` — built in Phases 7, 8 and 9 —
are reused verbatim and `/config` and `--debug-config` cannot disagree about
what tug read. Its buffer batches rather than bounds: an 11 KiB `/keys` table
streams through a 1 KiB caller buffer. An allocator failure inside `feed` is
stashed and re-raised, because `error{WriteFailed}` cannot carry it and a
machine out of memory should not be told its terminal is broken.

**Three warning lists finally have a screen.** Since Phase 7 the config's
warnings, the keymap's and the theme's have been visible through
`--debug-config` and nowhere else, which meant a person who mistyped a chord saw
their binding not work and got no explanation. `/config` now renders all three,
in one list with one shape and one left edge — and a shell that has something to
warn about says so once at startup: `2 warnings in your configuration - run
/config to see them`. One row of scrollback for the people with a problem,
nothing for the people without. `DR-014` records why the alternative — printing
all three lists on every startup — is the warning people learn to scroll past.

**The `/demo` probe.** The roadmap's "a new slash command requires zero
renderer/loop changes" was executed rather than asserted: a throwaway `/demo`
command was added, its diff measured, and it was removed again. Two source
files, three insertions, one deletion — one row in the registry and one arm in
the handler switch. Nothing under `render/`, nothing under `loop/`, and neither
`--help` nor `/keys` needed editing to know about it.

`scripts/command-session.sh` runs seven cases through a pty against the real
binary: the registry listed, a near miss suggested, a path submitted rather than
routed, tab completing before the line runs, a theme switched mid-session, all
three warning lists on `/config` with the startup line counting them, and a
clean config opening silently. Watched to fail with the tab dropped from the
completion case.

Cost: 5,032 bytes, taking the binary to 196,520 — 38 % of the 500 KiB budget.
Tests go from 375 to 411.

### Milestone 5 «It's honest» — Phase 11

**Every budget the roadmap states is now a job that prints a number and fails
on it.** Four had never been measured by anything but a person on a good day.

**Cold start, 0.33 ms against 10 ms.** `--debug-first-paint` paints one frame,
reports the microseconds from `main`'s first clock read to that frame reaching
the terminal, and exits. The binary times itself rather than a harness timing
it, which is `DR-015`'s first decision: `hyperfine` would have to wrap
`script -qec`, whose own fork and exec is a millisecond or more against a
ten-millisecond budget, with no honest way to subtract it. What the
self-measurement excludes — process spawn and dynamic loading — is covered from
the other side by the 2 ms `--version` gate on a static binary.

**Idle, 384 KiB and no CPU at all.** `scripts/idle-budget.sh` parks
`--debug-keys` for five seconds and reads `VmHWM` and the tick counters out of
`/proc`. `VmHWM` rather than `VmRSS`, because the budget is a ceiling and a
peak that has since been paged out is still a peak that happened. A loop that
starts busy-waiting is invisible to every other gate in the repo.

**A thousand interactions, leak-free.** A Debug build swaps `smp_allocator` for
`DebugAllocator` and exits nonzero when the session leaked; release keeps
`smp_allocator` and pays nothing. `scripts/soak-session.sh` drives two hundred
rounds of five — typing, an edit, a submit, a command, a theme switch, a resize
— then every fault mode once, through tmux, because a resize needs something
outside the process that can change a pty's window size while it runs.

**That gate was wrong three times before it was right, and each way is worth
recording.** Its first draft collected the shell's output from fd 1, where there
is none — the shell paints through the terminal — so the file it grepped was
empty and every assertion over it passed. It reads fd 2 now, plus the pane's own
exit status, and counts the history file's entries, so a harness that drove
nothing cannot claim a thousand interactions. Its second draft sent `ctrl+c` on
a draft that a stream in flight had swallowed, which *arms* the exit rather than
clearing anything, so the following round took it and the session left around
round forty. And its third sent keys before `enterRaw`, while the tty still had
`ISIG` on, which made that `ctrl+c` a `SIGINT` to the whole process group; it
waits for the prompt to paint now.

**The size budget is a ratchet as well as a ceiling.** 500 KiB is what v0.1
promised and stays; 211 KiB — the measured 196,984 B plus ten per cent — is what
v0.1 costs. From v0.2 onward, growing past it is a diff and a changelog line
rather than a drift.

**The decoder has a fuzz target.** Eleven seed inputs, one per branch of the
state machine, asserting the three invariants the property test already asserted:
never panics, always terminates, never emits more events than it was given
bytes. Outside fuzz mode the runner replays the corpus, so it costs microseconds
on every `zig build test` — that is the CI smoke. `zig build fuzz -- --fuzz` is
the real session, and the roadmap puts a CI fuzzing job in v0.2, because a
fuzzer that runs until interrupted is not a shape a five-minute wall can hold.

**Terminals degrade rather than hang**, gated. Five rows a machine with no
terminal emulator can produce — a bare pty at each of the three colour tiers,
`TERM=dumb`, and inside tmux — assert Phase 1's probe-hygiene rule: on a
terminal that answers neither query, `--caps` finishes inside its 50 ms budget.
It used to hang forever, which is what makes this a gate rather than a
decoration.

**Documentation.** A README that gets from a clone to a streaming mock in sixty
seconds and prints the measured budgets beside their limits;
`docs/architecture.md` for the loop, the tail and the block model, each with a
diagram and the bug that shaped it; `docs/configuration.md` for every setting,
action, chord and theme slot; and `docs/terminal-matrix.md`.

**What the matrix says, and it is the honest part of this release.** Four of its
rows — kitty, alacritty, wezterm, ghostty — read `unrecorded`, because none of
them has ever run tug. tug is developed on Windows against a WSL toolchain and
none is installed there; CI runners have no terminal emulator either. The
document carries the three commands that fill a row in. That is the one v0.1
exit criterion no machine in this project's environment can close, and it has
been open since Phase 4.

**Fixed after the fact, and it was this phase's own doing.** `zig build run` on
Windows painted the prompt, accepted no input, and died a few seconds later with
exit code 253 — which is `STATUS_STACK_OVERFLOW` truncated to its low byte.
`repl.run` kept a 256 KiB frame buffer on the 1 MiB stack `build.zig` asks the
linker for. That fitted while the function had one caller; `--debug-first-paint`
gave it a second, and Windows commits stack lazily, so the prompt painted and
the guard page was hit on the way deeper. The buffer is one heap allocation now,
freed with the session.

Two more surfaced while confirming it. `open()` on Windows checked
`GetConsoleMode` on the input handle only, so a console stdin with a redirected
stdout — `tug > out.txt`, or any build runner that pipes — got past it and
failed inside `enterRaw` with a bare `error.Unexpected` instead of the intended
refusal. And `--debug-first-paint` printed a number computed from an undefined
timestamp when no paint had happened, because `run` returns early when there is
no terminal to open.

**The lesson is larger than the three fixes.** Every gate in this repository was
green while the binary a user runs was broken, because a CI runner has no
console and every pty script is POSIX. The Windows job now asserts the
redirected-stdout refusal, which catches one class of this and not the one that
bit; a Windows runner with a real console is v0.9's terminal-certification work.

### Not yet

Held over past v0.1, deliberately. `/theme` with no argument lists the built-ins
and the live theme, not the themes directory: reading it needs `std.Io.Dir`
iteration, which nothing in tug does yet. Completion refuses an ambiguous prefix instead of
completing to the longest common one, because no two of the five names collide
and the code would have no input. A command goes into the shared prompt history,
which is the scope guard's "no command history separate from input history" and
means a history file now holds lines nobody would want sent to a provider.
Switching a theme does not repaint committed scrollback, which is the
append-only rule rather than a limitation with an apology attached.

There is no unbind syntax, refused by name in `DR-013`. `error` is a theme slot
nothing paints, because v0.1 has no error block. A user theme's contrast is not
checked, because tug does not know what your background is; the built-ins' is,
because somebody chose theirs. `code_bg` does not extend to the row edge
(`DR-007`). And no terminal emulator has yet watched the renderer stream: the
no-flicker eyeball test in kitty and alacritty is Phase 4's stated exit
criterion and is still open.

### Toolchain

Pinned to Zig 0.16.0 (`DR-001`). Link-time optimization is off: it saved 512
bytes and fails to link on the COFF target.
