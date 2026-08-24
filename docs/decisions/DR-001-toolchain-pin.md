# DR-001: Toolchain pin and upgrade policy

**Status:** accepted
**Date:** 2026-08-24
**Phase:** 0

## Context

Zig has no stable release. `std` moves between versions in ways that break
compiling code — `std.Io` was reshaped in 0.16, `refAllDeclsRecursive` was
removed, `ArrayList` lost its embedded allocator. A harness whose build breaks
when someone's toolchain manager updates in the background is a harness nobody
can rely on, and "works on the maintainer's machine" is the failure mode.

Against that: pinning too hard means carrying deprecated patterns for a long
time, and the whole point of building on Zig is cross-compilation and a small
static binary, both of which keep improving.

## Options

**Track `master`.** Newest features, best cross-compilation. Costs a build that
can break on any given morning for reasons unrelated to any commit, which is
unacceptable for a project whose CI gates are supposed to mean something.

**Pin an exact version, upgrade never.** Maximum stability. Costs the ability to
take fixes, and eventually the ability to build at all on new platforms.

**Pin an exact version, upgrade deliberately.** Stability between upgrades, and
each upgrade is a visible event with a diff and a changelog line.

## Decision

Pin **Zig 0.16.0** via `minimum_zig_version` in `build.zig.zon`.

Upgrades are a changelog event, never a surprise. Bumping the pin is its own
commit, touches `build.zig.zon` and `CHANGELOG.md`, and lands only with CI
green on every gate. The version is stated in the README so a contributor knows
what to install before the first error message tells them.

Contributors are expected to use a toolchain manager — `mise` or `zigup` — so
that the pinned version is a `mise install` rather than a manual download. The
build does not attempt to install a toolchain for anyone.

## Consequences

Makes easy: reproducible builds, CI gates that mean what they say, and a clear
answer to "which Zig?" that does not require reading the build script.

Makes hard: adopting a `std` improvement the day it lands. That is the trade
being bought.

Revisit when: Zig reaches 1.0, at which point the pin becomes a floor rather
than an exact version and this record is superseded.
