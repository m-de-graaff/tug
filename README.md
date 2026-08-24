# tug

A tiny, instant, embeddable AI harness. One static binary, no runtime, no
telemetry.

A tugboat's power is rated in *bollard pull* — a small vessel, absurdly
overpowered, guiding something a thousand times its mass. That is the product.
tug ships a shell, a loop, two providers, four tools and a plugin socket.
Everything else is a plugin, and the core is not an app at all: it is a
freestanding library with no IO opinions, no globals and an injected allocator.
The CLI is merely its first frontend.

> **Status: pre-alpha.** v0.1 «Hull» is under construction. It has no network
> code and talks to no models yet, by design — the shell is being built and
> perfected offline first. See [the roadmap](#roadmap).

## Build

Requires **Zig 0.16.0** exactly. Use a toolchain manager (`mise`, `zigup`)
rather than a system package; the pin and the upgrade policy are recorded in
[DR-001](docs/decisions/DR-001-toolchain-pin.md).

```sh
zig build                  # ReleaseSmall, the shipping configuration
zig build run -- --help
zig build test             # unit tests, Debug
zig build size             # binary size against its budget
zig build wasm-check       # tugcore must compile for wasm32-freestanding
zig build bench            # the --version fast path against its 2 ms budget
```

## Layout

| Path | What lives there |
|---|---|
| `src/proto/` | `tugproto` — the wire vocabulary. Stream events, the event catalog. Depends on nothing. |
| `src/core/` | `tugcore` — sans-IO logic. No filesystem, no sockets, no threads, no clock. |
| `src/shell/` | `tugshell` — the terminal frontend: raw mode, capabilities, input decoding. |
| `src/main.zig` | The executable. Argument parsing and wiring, and little else. |
| `scripts/` | The budget gates, callable from CI and by hand. |
| `docs/decisions/` | Decision records. Every non-obvious choice has one. |
| `docs/plans/` | Implementation plans, one per milestone. |

Each module may import only the ones above it in that table. The boundary is
enforced by the build graph rather than by convention, and `zig build
wasm-check` is what keeps `tugcore` honest: reaching for `std.fs` there fails
CI, years before anyone actually runs the core in a browser.

## Budgets

These are CI gates, not aspirations. They may tighten; they never silently
loosen.

| Metric | Budget |
|---|---|
| Binary size (ReleaseSmall, stripped, static Linux x86_64) | ≤ 500 KiB |
| Cold start to interactive prompt | ≤ 10 ms |
| `tug --version` | ≤ 2 ms |
| Idle RSS | ≤ 10 MiB |
| Network calls with no provider configured | 0, ever |
| CI wall clock | ≤ 5 min |

## Roadmap

`v0.1` shell · `v0.2` providers · `v0.3` tools and trust · `v0.4` sessions ·
`v0.5` the plugin socket · `v0.6` the wasm tier · `v0.7` ecosystem bridges ·
`v0.8` distribution and embedding · `v0.9` hardening · `v0.10` freeze ·
`v1.0` the contract.

## Licence

MIT OR Apache-2.0, at your option.
