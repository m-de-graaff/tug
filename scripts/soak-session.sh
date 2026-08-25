#!/bin/sh
# The roadmap's leak gate: a thousand interactions, one Debug process, zero
# leaked bytes.
#
# The mix is the one the phase TODO names — typing, editing, submits, mock
# streams including the fault modes, resizes, theme switches, commands —
# because a leak lives in whichever path nobody drove. The faults are in the mix
# for the same reason: `midstream_error` commits a partial block and
# `oversized_chunk` grows the tail, and both are allocation paths a happy stream
# never takes.
#
# tmux rather than script(1): a resize needs something outside the process that
# can change the window size while it runs, and script(1) has no way to.
#
# The binary must be a Debug build — that is the one running DebugAllocator and
# exiting nonzero on a leak. A ReleaseSmall binary passes this vacuously, so the
# check below refuses one.
#
# usage: soak-session.sh <binary>
set -eu

binary=$1
interactions=1000

if ! command -v tmux >/dev/null 2>&1; then
    echo "soak-session: no tmux; skipping" >&2
    exit 0
fi

# tmux starts the pane in its own working directory, so a relative path would
# resolve against the wrong place.
case "$binary" in
    /*) ;;
    *) binary="$PWD/$binary" ;;
esac

state=$(mktemp -d)
config=$(mktemp -d)
capture="$state/capture"
socket="$state/tmux.sock"
trap 'command tmux -S "$socket" kill-server 2>/dev/null || true; rm -rf "$state" "$config"' EXIT

mkdir -p "$config/tug/themes"
: >"$capture"

tm() { command tmux -S "$socket" "$@"; }

fail() {
    printf 'soak-session: %s\n' "$1" >&2
    printf -- '--- capture (tail) ---\n' >&2
    tail -c 4096 "$capture" | cat -v >&2
    exit 1
}

# A ReleaseSmall build has no DebugAllocator behind it, so it cannot fail this
# gate for the reason the gate exists. A binary with a symbol table is the
# cheapest available proxy for "not stripped", and `zig build` strips every
# release mode.
if ! grep -q 'reportLeaks\|debug_allocator' "$binary" 2>/dev/null; then
    echo "soak-session: $binary looks stripped; build with -Doptimize=Debug" >&2
    exit 2
fi

# What runs in the pane, as a file rather than as a string: tmux parses its own
# argument list, and a `;` inside a command string is a separator to it before
# it is a separator to sh.
#
# stderr, not stdout: the shell paints through the terminal rather than through
# fd 1, so redirecting stdout collects nothing at all — which is exactly how
# this gate spent its first draft passing vacuously. fd 2 is where the
# DebugAllocator report and the leak line go, and the trailing `echo` is what
# turns the process's exit status into something the assertions below can see.
cat >"$state/pane.sh" <<PANE
#!/bin/sh
TERM=xterm-256color COLORTERM=truecolor \\
XDG_STATE_HOME=$state XDG_CONFIG_HOME=$config \\
    $binary --provider mock --mock-cadence instant 2>>$capture
echo "EXIT=\$?" >>$capture
PANE

tm new-session -d -x 100 -y 30 "sh $state/pane.sh"

# Wait for the prompt before sending anything. Until `enterRaw` runs, the tty is
# still in canonical mode with ISIG on, so the ctrl+c below would be a SIGINT to
# the whole process group rather than a keystroke — which kills the pane, the
# session and the server, and leaves an empty capture to explain it with.
#
# Polling for the prompt rather than sleeping: the wait is then as short as the
# machine allows and as long as a loaded CI runner needs.
waited=0
until tm capture-pane -p 2>/dev/null | grep -q '>'; do
    if [ "$waited" -ge 100 ]; then
        fail "the shell never painted a prompt"
    fi
    sleep 0.1
    waited=$((waited + 1))
done

# One interaction is one thing a user could do. Five per round, so the loop runs
# a fifth of the total.
rounds=$((interactions / 5))

round=0
while [ "$round" -lt "$rounds" ]; do
    # 1 — type, edit, submit. ctrl+w kills the word, so what is submitted is
    # shorter than what was typed: the buffer has been both grown and shrunk.
    tm send-keys -l "soak $round scratchword"
    tm send-keys C-w
    tm send-keys Enter

    # 2 — a multiline draft abandoned rather than sent, which is the path that
    # allocates and then throws the allocation away. alt+enter rather than
    # ctrl+j: the kitty protocol is unavailable inside tmux, so alt+enter is the
    # chord `newline` is actually bound to here, and ctrl+j is bound to nothing
    # at all unless a config file says otherwise.
    tm send-keys -l "first"
    tm send-keys M-Enter
    tm send-keys -l "second"
    # The `x` is load-bearing. ctrl+c on an empty draft *arms* the exit and the
    # next one takes it, so a round whose draft was swallowed by a stream in
    # flight would arm, and the round after it would quit — which is how this
    # script spent an afternoon ending somewhere around round forty. One
    # character guarantees there is a draft to clear instead.
    tm send-keys -l "x"
    tm send-keys C-c

    # 3 — a command, through the registry and the block writer.
    case $((round % 3)) in
        0) tm send-keys -l "/keys" ;;
        1) tm send-keys -l "/config" ;;
        2) tm send-keys -l "/help" ;;
    esac
    tm send-keys Enter

    # 4 — a theme switch, which frees the previous theme's file bytes.
    if [ $((round % 2)) -eq 0 ]; then
        tm send-keys -l "/theme light"
    else
        tm send-keys -l "/theme dark"
    fi
    tm send-keys Enter

    # 5 — a resize, alternating between a width the tail wraps at and one it
    # does not.
    if [ $((round % 2)) -eq 0 ]; then
        tm resize-window -x 40 -y 12
    else
        tm resize-window -x 100 -y 30
    fi

    round=$((round + 1))
done

tm send-keys -l "/quit"
tm send-keys Enter

waited=0
while tm has-session 2>/dev/null; do
    if [ "$waited" -ge 180 ]; then
        fail "the long session never ended"
    fi
    sleep 1
    waited=$((waited + 1))
done

# Proof that the keystrokes above were interactions rather than a light show.
# Every submit and every command lands in the history file, so a session that
# quietly stopped accepting input leaves a short one — and a harness that drove
# nothing at all leaves none. Three entries a round are expected; one is the bar,
# because the point is to catch zero.
history_file="$state/tug/history"
if [ ! -s "$history_file" ]; then
    fail "nothing reached the history: the shell was not driven"
fi
entries=$(wc -l <"$history_file" | tr -d ' ')
if [ "$entries" -lt "$rounds" ]; then
    fail "history has $entries entries, expected at least $rounds"
fi

# Every fault mode, one Debug process each. A fault is a stream shape rather
# than an interaction, which is why these run after the count above rather than
# inside it.
for fault in midstream_error oversized_chunk split_utf8 empty stall firehose; do
    env TERM=xterm-256color XDG_STATE_HOME="$state" \
        timeout 60 script -qec \
        "$binary --provider mock --once --mock-fault $fault --mock-cadence instant" \
        /dev/null 2>>"$capture" >/dev/null \
        || fail "the $fault run did not exit cleanly"
done

# The specific reason first, so a leak reports as a leak rather than as the
# nonzero exit it also is.
if grep -q 'the session leaked memory' "$capture"; then
    fail "the session leaked memory"
fi
# Then the general one. A leak is a nonzero exit, and a session killed before it
# could report one leaves no line to grep for at all — requiring EXIT=0 to be
# present catches the second case, which is how this gate's first two drafts
# managed to pass without ever having driven the shell.
if ! grep -q '^EXIT=0$' "$capture"; then
    fail "the shell did not exit 0, or did not reach its exit at all"
fi
if grep -Eqi 'panic|reached unreachable|segmentation fault' "$capture"; then
    fail "the session crashed"
fi

printf 'soak-session: %s interactions plus every fault mode, no leaks, no crash\n' "$interactions"
