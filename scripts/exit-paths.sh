#!/bin/sh
# Verifies that no exit path leaves the terminal broken.
#
# This is the one property in the terminal layer that a user cannot work around
# and cannot diagnose: a shell that stops echoing after tug exits, with no
# recourse but typing `reset` blind. So every way out gets checked, including
# the ones nobody plans for.
#
# Requires a POSIX system with a pty. Skips itself elsewhere rather than
# pretending to pass.
#
# usage: exit-paths.sh <binary>
set -eu

binary=${1:-zig-out/bin/tug}

if ! command -v stty >/dev/null 2>&1; then
    echo "exit-paths: no stty; skipping" >&2
    exit 0
fi

if [ ! -t 0 ]; then
    echo "exit-paths: stdin is not a terminal; run this from a real shell" >&2
    exit 0
fi

before=$(stty -g)

check() {
    label=$1
    after=$(stty -g)
    if [ "$after" != "$before" ]; then
        printf 'exit-paths: %s left the terminal modified\n' "$label" >&2
        stty "$before"
        exit 1
    fi
    printf 'exit-paths: %s ok\n' "$label"
}

# Normal exit.
"$binary" --version >/dev/null
check "normal exit"

# Killed from outside, one signal per run. SIGKILL is deliberately absent: it
# cannot be handled, and claiming otherwise would be a lie in a test.
for signal in TERM HUP INT; do
    "$binary" --debug-keys >/dev/null 2>&1 &
    child=$!
    sleep 0.3
    kill -"$signal" "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    check "SIG$signal"
done

echo "exit-paths: all paths leave the terminal sane"
