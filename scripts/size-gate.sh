#!/bin/sh
# Fails when the binary exceeds its budget.
#
# The roadmap's rule is that budgets may tighten but never silently loosen, so
# this script is deliberately dumb: it takes the number from the caller and has
# no opinion of its own. Raising the budget means editing build.zig, which shows
# up in a diff and needs a justification.
#
# usage: size-gate.sh <binary> <budget-bytes>
set -eu

binary=$1
budget=$2

if [ ! -f "$binary" ]; then
    echo "size-gate: no such file: $binary" >&2
    exit 2
fi

size=$(wc -c < "$binary" | tr -d ' ')
percent=$((size * 100 / budget))

printf 'size: %s bytes (%s%% of the %s byte budget)\n' "$size" "$percent" "$budget"

if [ "$size" -gt "$budget" ]; then
    printf 'size-gate: over budget by %s bytes\n' "$((size - budget))" >&2
    exit 1
fi
