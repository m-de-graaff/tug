#!/bin/sh
# Every row of the terminal matrix that a machine with no terminal emulator can
# fill in: a bare pty, the same pty inside tmux, a TERM that promises nothing,
# and NO_COLOR.
#
# What this asserts is degradation, not capability. A pty is not a terminal
# emulator and cannot answer the kitty or DECRQM probes, so the interesting
# claim is Phase 1's probe-hygiene item: an unanswered probe degrades to
# "unsupported" inside its budget and never hangs startup. It used to hang,
# which is carried item 1 and the reason this gate exists at all.
#
# The four emulator rows — kitty, alacritty, wezterm, ghostty — are not
# scriptable here and are recorded as unrecorded in docs/terminal-matrix.md.
#
# Every match below is unanchored on purpose: the first row of `--caps` output
# is preceded by the probe's own query bytes, which a pty echoes back onto the
# same line.
#
# usage: terminal-matrix.sh <binary>
set -eu

binary=$1

if ! command -v script >/dev/null 2>&1; then
    echo "terminal-matrix: no script(1); skipping" >&2
    exit 0
fi

capture=$(mktemp)
trap 'rm -f "$capture"' EXIT

fail() {
    printf 'terminal-matrix: %s\n' "$1" >&2
    printf -- '--- capture ---\n' >&2
    cat -v "$capture" >&2
    exit 1
}

# `--caps` must answer inside the probe budget on a terminal that answers
# neither query. Five seconds is two orders of magnitude of headroom over the
# 50 ms it is allowed, so a timeout here means a hang and not a slow runner.
caps() {
    if ! timeout 5 script -qec "env $1 $binary --caps" /dev/null >"$capture" 2>&1; then
        fail "--caps did not finish under: $1"
    fi
}

caps "TERM=xterm-256color COLORTERM=truecolor"
grep -q 'color  *truecolor' "$capture" || fail "COLORTERM=truecolor did not reach the colour tier"
grep -q 'kitty keyboard  *false' "$capture" || fail "an unanswered kitty probe was not reported unsupported"
grep -q 'synchronized output  *false' "$capture" || fail "an unanswered DECRQM was not reported unsupported"
echo 'terminal-matrix: bare pty, truecolor, both probes degrade'

caps "TERM=xterm-256color"
grep -q 'color  *ansi256' "$capture" || fail "TERM=xterm-256color did not give the 256 tier"
echo 'terminal-matrix: bare pty, 256 colours'

caps "TERM=dumb"
grep -q 'color  *none' "$capture" || fail "TERM=dumb did not give the monochrome tier"
grep -q 'bracketed paste  *false' "$capture" || fail "TERM=dumb claimed bracketed paste"
echo 'terminal-matrix: TERM=dumb answers rather than hanging'

# NO_COLOR wins over a terminal that says it can do sixteen million: the
# variable is a user's instruction, not a capability report.
caps "TERM=xterm-256color COLORTERM=truecolor NO_COLOR=1"
grep -q 'color  *none' "$capture" || fail "NO_COLOR did not reach the monochrome tier"
echo 'terminal-matrix: NO_COLOR is honoured'

# Inside tmux: the fifth row of the roadmap's matrix, and the only one of the
# five this machine can produce.
if command -v tmux >/dev/null 2>&1; then
    socket=$(mktemp -u)
    out=$(mktemp)
    command tmux -S "$socket" new-session -d -x 100 -y 30 \
        "env TERM=xterm-256color $binary --caps >$out 2>&1"
    waited=0
    while command tmux -S "$socket" has-session 2>/dev/null; do
        if [ "$waited" -ge 10 ]; then
            command tmux -S "$socket" kill-server 2>/dev/null || true
            cp "$out" "$capture"
            rm -f "$out"
            fail "--caps hung inside tmux"
        fi
        sleep 1
        waited=$((waited + 1))
    done
    cp "$out" "$capture"
    rm -f "$out"
    grep -q 'size  *100x30' "$capture" || fail "tmux's window size did not reach tug"
    echo 'terminal-matrix: inside tmux, window size reaches tug'
fi

echo 'terminal-matrix: every scriptable row is green'
