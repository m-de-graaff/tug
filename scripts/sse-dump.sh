#!/bin/sh
# The M1 demo, as a gate.
#
# Raw recorded bytes in, decoded events out. If this stops printing what it
# printed yesterday, the parser changed behaviour — which is exactly the kind of
# change that should require someone to look at a diff and agree with it.
#
# Needs a Debug build: `dev sse-dump` is not reachable from a release binary.
#
# usage: sse-dump.sh <binary> <fixture> <expected>
set -eu

binary=${1:?usage: sse-dump.sh <binary> <fixture> <expected>}
fixture=${2:?usage: sse-dump.sh <binary> <fixture> <expected>}
expected=${3:?usage: sse-dump.sh <binary> <fixture> <expected>}

actual=$("$binary" dev sse-dump <"$fixture")

if [ "$actual" != "$(cat "$expected")" ]; then
    echo "sse-dump: output does not match $expected" >&2
    printf '%s\n' "$actual" | diff -u "$expected" - >&2 || true
    exit 1
fi

echo "sse-dump: matches $expected"
