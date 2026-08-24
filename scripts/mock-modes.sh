#!/bin/sh
# Every fault mode, through a real pty, in the real binary.
#
# The goldens in `src/shell/provider/golden.zig` already pin the bytes the
# renderer produces, and they do it in process where they are stable on every
# platform. What they cannot check is whether the flags reach the code, whether
# the process exits on its own, and whether `Loop.run` — whose body no portable
# unit test can drive, since it needs a terminal — survives each mode. That is
# this script.
#
# It asserts *defined behaviour*, not byte-exact transcripts. A pty capture
# depends on TERM, the window size and the capability probe's timing, and a
# byte-exact assertion over that is a flaky test wearing a golden's clothes.
#
# `--once` is what makes each mode end on its own: without it `--provider mock`
# opens a shell, and a shell waits for a keypress rather than exiting.
#
# Requires a POSIX system with a pty. Skips itself elsewhere rather than
# pretending to pass.
#
# usage: mock-modes.sh <binary>
set -eu

binary=${1:-zig-out/bin/tug}

if ! command -v script >/dev/null 2>&1; then
    echo "mock-modes: no script(1); skipping" >&2
    exit 0
fi

capture=$(mktemp)
first=$(mktemp)
trap 'rm -f "$capture" "$first"' EXIT

# One run of the binary under a pty, into $capture. A mode that hangs is a
# failure, not something to wait out: the whole claim is that every fault ends.
run() {
    label=$1
    shift
    if ! timeout 60 script -qec "$binary --provider mock --once --mock-seed 1 $*" /dev/null \
        >"$capture" 2>&1; then
        printf 'mock-modes: %s did not exit cleanly\n' "$label" >&2
        exit 1
    fi
}

# --- every mode exits on its own ---------------------------------------------

for fault in none stall=50 midstream_error oversized_chunk split_utf8 instant empty; do
    run "$fault" "--mock-fault $fault"
    printf 'mock-modes: %s ok (%s bytes)\n' "$fault" "$(wc -c <"$capture" | tr -d ' ')"
done

# --- midstream_error says so -------------------------------------------------

run midstream_error "--mock-fault midstream_error"
if ! grep -q "hung up mid-stream" "$capture"; then
    echo "mock-modes: midstream_error did not print its notice" >&2
    exit 1
fi
echo "mock-modes: midstream_error notice ok"

# --- empty says nothing ------------------------------------------------------
#
# "bollard pull" is in the mock's first corpus sentence, so its absence is the
# absence of a response rather than the absence of one particular unit.

run empty "--mock-fault empty"
if grep -qi "bollard pull" "$capture"; then
    echo "mock-modes: empty streamed a response" >&2
    exit 1
fi
echo "mock-modes: empty ok"

# --- the same seed is the same bytes -----------------------------------------

run determinism "--mock-fault instant"
cp "$capture" "$first"
run determinism "--mock-fault instant"
if ! cmp -s "$first" "$capture"; then
    echo "mock-modes: the same seed produced different output" >&2
    exit 1
fi
echo "mock-modes: deterministic across runs"

# --- the firehose holds the frame budget -------------------------------------
#
# A timed window rather than a run to completion, and deliberately so: the
# firehose is megabytes, a pty moves it at whatever rate the reader on the far
# end can take, and how long the whole response needs says more about the pty
# than about tug. Measured here it ranges over an order of magnitude between
# runs. So the window is fixed, the kill at the end of it is the expected
# outcome, and what is measured is frames per second inside it.
#
# Frames are counted by their erase: every paint emits exactly one ED 0, and
# `[0J` appears in no other sequence the renderer writes. Counting the escape in
# the capture rather than instrumenting the binary keeps this a black-box check.
#
# The budget is the roadmap's 125 frames a second plus a quarter. The failure it
# guards against is a renderer painting per delta, which is out by orders of
# magnitude rather than by a quarter — and, once, a loop whose drain chased a
# producer faster than itself and painted a single frame in eight seconds.

window=10
frame_budget=$((window * 156))

# `timeout` returns 124 when it does the killing, which is the expected result
# here. Any other non-zero status is the binary falling over.
timeout "$window" script -qec \
    "$binary --provider mock --once --mock-seed 1 --mock-fault firehose" /dev/null \
    >"$capture" 2>&1 || [ $? -eq 124 ] || {
    echo "mock-modes: firehose exited badly" >&2
    exit 1
}

frames=$(grep -ao '\[0J' "$capture" | wc -l | tr -d ' ')
bytes=$(wc -c <"$capture" | tr -d ' ')

printf 'mock-modes: firehose painted %s frames and %s bytes in %ss (budget %s frames)\n' \
    "$frames" "$bytes" "$window" "$frame_budget"

# A firehose that produced almost nothing would pass the frame budget by not
# painting, which is the bug rather than the fix.
if [ "$bytes" -lt 65536 ]; then
    echo "mock-modes: the firehose barely streamed; the loop is not keeping up" >&2
    exit 1
fi
if [ "$frames" -gt "$frame_budget" ]; then
    echo "mock-modes: the firehose outran the frame budget" >&2
    exit 1
fi

echo "mock-modes: every fault mode behaves"
