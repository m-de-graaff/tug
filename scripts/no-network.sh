#!/bin/sh
# The network confinement tripwire (DR-016).
#
# v0.1 forbade network code outright. v0.2 needs it, so the gate narrows instead
# of dying: sockets and TLS live under src/providers/transport and nowhere else,
# which is what makes the Phase 3 Transport seam a mechanical fact rather than a
# review convention.
#
# The match is textual, so a comment mentioning std.net in the wrong directory
# trips it too. That is deliberate — such a comment is usually a plan.
#
# usage: no-network.sh [directory]
set -eu

root=${1:-src}
# std.Io.net is where sockets actually live in Zig 0.16 — std.net and
# std.posix.socket, which the v0.1 gate greps for, no longer exist. Both stay in
# the pattern anyway: they cost nothing and they catch a copied-in snippet
# written against an older std before the compiler does.
pattern='std\.http|std\.Io\.net|std\.net|std\.posix\.socket|std\.crypto\.tls'
allowed='^src/providers/transport'

hits=$(grep -rnE "$pattern" "$root" | grep -vE "$allowed" || true)

if [ -n "$hits" ]; then
    echo "$hits" >&2
    echo "" >&2
    echo "no-network: sockets and TLS belong under src/providers/transport (DR-016)." >&2
    echo "The matches above are outside it and fail the build." >&2
    exit 1
fi

echo "no-network: confined ($root)"
