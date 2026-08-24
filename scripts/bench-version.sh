#!/bin/sh
# Gates the --version fast path against its 2 ms budget.
#
# usage: bench-version.sh <binary>
set -eu

binary=$1
budget_ms=2

if ! command -v hyperfine >/dev/null 2>&1; then
    echo "bench-version: hyperfine not installed; skipping" >&2
    exit 0
fi

out=$(mktemp)
hyperfine --shell=none --warmup 20 --runs 200 --export-json "$out" "$binary --version"

mean_ms=$(awk -F'"mean":' 'NF>1 { split($2, a, ","); print a[1]; exit }' "$out" \
    | awk '{ printf "%.3f", $1 * 1000 }')
rm -f "$out"

printf 'version mean: %s ms (budget %s ms)\n' "$mean_ms" "$budget_ms"

awk -v m="$mean_ms" -v b="$budget_ms" 'BEGIN { exit (m > b) ? 1 : 0 }' || {
    echo "bench-version: over budget" >&2
    exit 1
}
