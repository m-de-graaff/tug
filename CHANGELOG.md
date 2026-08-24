# Changelog

Every entry names what changed and what it costs. Budget changes and toolchain
bumps are changelog events by policy, never silent.

## Unreleased — v0.1 «Hull»

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

### Not yet

The loop, the renderer, the editor, config, keymaps, themes and commands —
Phases 3 to 11. `tug` with no arguments prints its usage rather than pretending
to be a shell.

### Toolchain

Pinned to Zig 0.16.0 (`DR-001`). Link-time optimization is off: it saved 512
bytes and fails to link on the COFF target.
