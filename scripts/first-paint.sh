#!/bin/sh
# Gates cold start against its 10 ms budget.
#
# The binary times itself — from main's first clock read to the flush of the
# first frame — because the alternative is timing `script -qec "tug …"` from
# outside and subtracting a fork and an exec by guesswork. What this excludes is
# process spawn and dynamic loading, which the 2 ms `--version` gate covers from
# the other side.
#
# The number is not at the start of its line: the frame it reports on parks the
# cursor inside the tail, so the report follows the escape sequence that put it
# there. Hence the unanchored match below — an anchored one silently collects
# nothing, and this script would then fail on the sample count rather than on
# the budget, which is a confusing way to be right.
#
# Eleven runs, median gated: a cold page cache or a scheduler hiccup on a shared
# CI runner is not a regression in tug.
#
# usage: first-paint.sh <binary>
set -eu

binary=$1
budget_us=10000
runs=11

if ! command -v script >/dev/null 2>&1; then
    echo "first-paint: no script(1); skipping" >&2
    exit 0
fi

samples=$(mktemp)
trap 'rm -f "$samples"' EXIT

i=0
while [ "$i" -lt "$runs" ]; do
    TERM=xterm-256color script -qec "$binary --debug-first-paint" /dev/null \
        | sed -n 's/.*first paint: \([0-9][0-9]*\) us.*/\1/p' >>"$samples"
    i=$((i + 1))
done

count=$(wc -l <"$samples" | tr -d ' ')
if [ "$count" -ne "$runs" ]; then
    echo "first-paint: expected $runs samples, got $count" >&2
    exit 2
fi

median=$(sort -n "$samples" | sed -n "$(((runs + 1) / 2))p")

printf 'first paint: %s us median of %s (budget %s us)\n' "$median" "$runs" "$budget_us"

if [ "$median" -gt "$budget_us" ]; then
    echo "first-paint: over budget" >&2
    exit 1
fi
