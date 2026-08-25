# tug

A tiny, instant, embeddable AI harness. One static binary, no runtime, no
telemetry.

A tugboat's power is rated in *bollard pull* — a small vessel, absurdly
overpowered, guiding something a thousand times its mass. That is the product.
tug ships a shell, a loop, two providers, four tools and a plugin socket.
Everything else is a plugin, and the core is not an app at all: it is a
freestanding library with no IO opinions, no globals and an injected allocator.
The CLI is merely its first frontend.

> **Status: pre-alpha.** v0.1 «Hull» is the shell, and only the shell. It has
> **no network code at all** — the mock provider is the only provider, and real
> models arrive in v0.2. The terminal UX is being built and perfected offline
> first, on purpose. Tier-1 is POSIX; Windows compiles and its tests pass, and
> nothing more is promised until v0.9.

## Sixty seconds

Requires **Zig 0.16.0** exactly. Use a toolchain manager (`mise`, `zigup`)
rather than a system package; the pin and the upgrade policy are recorded in
[DR-001](docs/decisions/DR-001-toolchain-pin.md).

```sh
git clone https://github.com/m-de-graaff/tug
cd tug
zig build                            # ReleaseSmall, the shipping configuration
./zig-out/bin/tug --provider mock
```

Then, in the shell that opens:

- **Type something and press enter.** The mock streams markdown back into your
  scrollback — headings, lists, fenced code — at a deliberately awkward cadence.
  Resize the window while it runs.
- **`/help`** lists the five commands, rendered from the registry, so it cannot
  describe a command that does not exist.
- **`/theme light`** switches the colours live. **`/keys`** shows what every
  chord does. **`/config`** shows every setting, its value, and which layer set
  it.
- **`ctrl+c`** clears the draft, or stops a response. **`ctrl+d`** on an empty
  draft leaves.

Two flags worth knowing. `--mock-fault firehose` streams megabytes with no
delay, which is the flicker test; `--mock-fault midstream_error` fails halfway,
which is the one everyone forgets to handle.

## Make it yours

```toml
# ./.tug/config.toml
theme = "light"

[keys]
"ctrl+j" = "newline"
"ctrl+g" = "quit"

[history]
max_entries = 5000
```

Layered: defaults, then `~/.config/tug/config.toml`, then `./.tug/config.toml`,
then `TUG_*`, then flags. `/config` prints which layer won. A typo warns and is
ignored — it can never stop a shell from opening.

Full reference: **[docs/configuration.md](docs/configuration.md)** — every
setting, every action, every theme slot.

## Documentation

| | |
|---|---|
| [docs/configuration.md](docs/configuration.md) | Settings, keybinds, themes |
| [docs/architecture.md](docs/architecture.md) | The loop, the tail, the block model |
| [docs/terminal-matrix.md](docs/terminal-matrix.md) | What has been run where, and what has not |
| [docs/decisions/](docs/decisions/) | Every non-obvious choice, with its rejected alternatives |

## Budgets

CI gates, not aspirations. They may tighten; they never silently loosen — and
loosening one requires a written justification in the changelog.

| Metric | Measured | Budget |
|---|---|---|
| Binary (ReleaseSmall, stripped, static Linux x86_64) | 196,984 B | ≤ 500 KiB, and ≤ 211 KiB ratchet |
| Cold start to interactive prompt | 0.33 ms | ≤ 10 ms |
| `tug --version` | 0.52 ms | ≤ 2 ms |
| Idle RSS, shell parked | 384 KiB | ≤ 10 MiB |
| Idle CPU, shell parked | 0 ticks / 5 s | 0 % |
| Leaked bytes over 1,000 interactions | 0 | 0 |
| Network calls with no provider configured | 0 | 0, ever |
| CI wall clock | ~90 s | ≤ 5 min |

Every row is a script in `scripts/` you can run yourself.
[DR-015](docs/decisions/DR-015-budget-measurement.md) records where each number
is measured and why there rather than somewhere else.

## Building and testing

```sh
zig build                  # ReleaseSmall, the shipping configuration
zig build run -- --help
zig build test             # unit tests, Debug, leak-checked by construction
zig build size             # binary size against its ceiling and its ratchet
zig build wasm-check       # tugcore must compile for wasm32-freestanding
zig build bench            # the --version fast path against its 2 ms budget
zig build fuzz             # the input decoder's fuzz target; add -- --fuzz to run it
```

The pty gates need a POSIX system and skip themselves elsewhere rather than
pretending to pass:

```sh
sh scripts/mock-modes.sh      zig-out/bin/tug   # every fault mode behaves
sh scripts/editor-session.sh  zig-out/bin/tug   # the editor, through a real terminal
sh scripts/command-session.sh zig-out/bin/tug   # a slash reaches a handler
sh scripts/theme-session.sh   zig-out/bin/tug   # a theme reaches the renderer
sh scripts/terminal-matrix.sh zig-out/bin/tug   # terminals degrade rather than hang
sh scripts/first-paint.sh     zig-out/bin/tug   # cold start
sh scripts/idle-budget.sh     zig-out/bin/tug   # idle RSS and CPU

zig build -Doptimize=Debug
sh scripts/soak-session.sh    zig-out/bin/tug   # 1,000 interactions, leak-free
```

## Layout

| Path | What lives there |
|---|---|
| `src/proto/` | `tugproto` — the wire vocabulary. Stream events, the event catalog. Depends on nothing. |
| `src/core/` | `tugcore` — sans-IO logic. No filesystem, no sockets, no threads, no clock. |
| `src/shell/` | `tugshell` — the terminal frontend: raw mode, input decoding, the renderer, the editor. |
| `src/main.zig` | The executable. Argument parsing and wiring, and little else. |
| `scripts/` | The budget gates, callable from CI and by hand. |
| `docs/decisions/` | Decision records. Every non-obvious choice has one. |
| `docs/plans/` | Implementation plans, one per milestone. |

Each module may import only the ones above it in that table, enforced by the
build graph rather than by convention.

## Roadmap

`v0.1` shell · `v0.2` providers · `v0.3` tools and trust · `v0.4` sessions ·
`v0.5` the plugin socket · `v0.6` the wasm tier · `v0.7` ecosystem bridges ·
`v0.8` distribution and embedding · `v0.9` hardening · `v0.10` freeze ·
`v1.0` the contract.

## Licence

MIT OR Apache-2.0, at your option.
