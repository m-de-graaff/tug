#!/bin/sh
# Gates the two budgets a parked shell has to hold: 10 MiB resident and no CPU
# at all.
#
# `--debug-keys` is the idle build — it opens a terminal, decodes keys, and sits
# in `poll` with no provider, no config file and no history. A loop that starts
# busy-waiting accrues ticks here, and that regression is invisible to every
# other gate in this repo.
#
# VmHWM rather than VmRSS because the budget is a ceiling, and a peak that has
# since been paged out is still a peak that happened.
#
# Requires Linux: /proc is where both numbers live. Skips itself elsewhere
# rather than pretending to pass.
#
# usage: idle-budget.sh <binary>
set -eu

binary=$1
rss_budget_kb=10240
park_seconds=5

if ! command -v script >/dev/null 2>&1; then
    echo "idle-budget: no script(1); skipping" >&2
    exit 0
fi
if [ ! -r /proc/self/status ]; then
    echo "idle-budget: no /proc; skipping" >&2
    exit 0
fi

state=$(mktemp -d)
capture=$(mktemp)
trap 'rm -rf "$state" "$capture"' EXIT

# A fifo held open, so the shell has a stdin that never closes and never speaks.
# Without it `script` sees EOF at once and the process leaves before it parks.
mkfifo "$state/stdin"
TERM=xterm-256color script -qec \
    "env XDG_STATE_HOME=$state $binary --debug-keys" /dev/null \
    <"$state/stdin" >"$capture" 2>&1 &
harness=$!
exec 9>"$state/stdin"

# `script` may fork the binary or exec it, and which one decides whether the
# shell is the harness pid or a child of it. Try the child first and fall back
# to the harness itself rather than assuming either.
pid=""
waited=0
while [ "$waited" -lt 50 ]; do
    pid=$(pgrep -P "$harness" -x tug 2>/dev/null || true)
    [ -n "$pid" ] && break
    if grep -qs '^Name:[[:space:]]*tug$' "/proc/$harness/status"; then
        pid=$harness
        break
    fi
    sleep 0.1
    waited=$((waited + 1))
done

if [ -z "$pid" ]; then
    echo "idle-budget: the shell never started" >&2
    cat -v "$capture" >&2
    exec 9>&-
    exit 2
fi

sleep "$park_seconds"

if [ ! -r "/proc/$pid/status" ]; then
    echo "idle-budget: the shell did not survive its park" >&2
    cat -v "$capture" >&2
    exec 9>&-
    exit 2
fi

rss_kb=$(awk '/^VmHWM:/ { print $2 }' "/proc/$pid/status")
ticks=$(awk '{ print $14 + $15 }' "/proc/$pid/stat")

# Ctrl+C twice: `--debug-keys` echoes decoded events until it is interrupted,
# and the second press is what ends it.
printf '\003\003' >&9
exec 9>&-
wait "$harness" || {
    echo "idle-budget: the shell did not exit cleanly" >&2
    cat -v "$capture" >&2
    exit 1
}

printf 'idle: %s KiB peak (budget %s KiB), %s CPU ticks over %ss (budget 0)\n' \
    "$rss_kb" "$rss_budget_kb" "$ticks" "$park_seconds"

status=0
if [ "$rss_kb" -gt "$rss_budget_kb" ]; then
    echo "idle-budget: over the RSS budget" >&2
    status=1
fi
if [ "$ticks" -ne 0 ]; then
    echo "idle-budget: the shell used CPU while idle" >&2
    status=1
fi
exit "$status"
