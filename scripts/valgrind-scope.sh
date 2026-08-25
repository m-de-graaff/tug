#!/bin/sh
# Memcheck over what v0.2 can currently run end to end.
#
# The scope is deliberately narrow and deliberately temporary: today it is one
# scripted mock turn, because that is the only complete path through the binary
# that exists before providers land. Phase 10 points it at the SSE parser, the
# provider mappers and the transport tests.
#
# What matters now is that the job exists, the runner has valgrind, and a leak
# turns it red — the alternative is discovering in Phase 10 that none of those
# were ever true.
#
# Through a pty, for the same reason `mock-modes.sh` is: without a terminal the
# binary prints "not a terminal: nothing to render into" and exits, and memcheck
# over a process that did nothing is a gate that proves nothing.
#
# Build the binary in ReleaseSafe. A Debug build carries the DebugAllocator,
# which catches leaks first and for different reasons; running both is the point,
# running valgrind against Debug is not.
#
# usage: valgrind-scope.sh <binary>
set -eu

binary=${1:?usage: valgrind-scope.sh <binary>}

if ! command -v valgrind >/dev/null 2>&1; then
    echo "valgrind-scope: valgrind not found." >&2
    exit 2
fi

if ! command -v script >/dev/null 2>&1; then
    echo "valgrind-scope: no script(1); skipping" >&2
    exit 0
fi

# --error-exitcode makes a finding an exit status rather than a line in a wall of
# output nobody reads. Only definite losses fail: "still reachable" at exit is
# what an arena that outlives main looks like, and tug has those on purpose.
valgrind_command="valgrind \
    --error-exitcode=99 \
    --errors-for-leak-kinds=definite \
    --leak-check=full \
    --track-origins=yes \
    $binary --provider mock --once --mock-seed 1 --mock-cadence instant"

# `|| status=$?` rather than `if !`: inside an `if !` the status is the negation's
# and always zero, which would report every failure as exit 0.
status=0
timeout 300 script -qec "$valgrind_command" /dev/null || status=$?

if [ "$status" -ne 0 ]; then
    echo "" >&2
    echo "valgrind-scope: memcheck failed (exit $status) — see the report above." >&2
    exit "$status"
fi

echo "valgrind-scope: clean ($binary)"
