#!/bin/sh
# The canary grep: nothing key-shaped may be checked in.
#
# Fixtures record the response side only, so no credential should ever reach
# `testdata/`. This is the gate that makes "should" mechanical, and it exists
# from Phase 0 — before there is any auth code to leak — because a gate added
# after the first leak is a gate that arrived late.
#
# The runtime half lives in Zig: `providers.canary.contains` is asserted against
# captured output surfaces. Neither half substitutes for the other; this one
# watches what is committed, that one watches what is printed.
#
# usage: canary-grep.sh [directory]
set -eu

root=${1:-testdata}

# The planted key, plus the shapes real keys take. Kept in sync by hand with
# src/providers/canary.zig — two places, both of which a reviewer reads. The
# generic sk- pattern is last and deliberately loose: a false positive here costs
# one conversation, a false negative costs a rotated key.
patterns='sk-tug-canary|sk-ant-[A-Za-z0-9_-]{16,}|sk-or-v1-[A-Za-z0-9]{16,}|gsk_[A-Za-z0-9]{16,}|sk-proj-[A-Za-z0-9_-]{16,}|sk-[A-Za-z0-9]{32,}'

hits=$(grep -rnE "$patterns" "$root" || true)

if [ -n "$hits" ]; then
    echo "$hits" >&2
    echo "" >&2
    echo "canary: key-shaped material is checked in under $root." >&2
    echo "Fixtures record the response side only; requests never reach disk." >&2
    exit 1
fi

echo "canary: clean ($root)"
