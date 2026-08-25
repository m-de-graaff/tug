#!/bin/sh
# A real editing session, through a real pty, in the real binary.
#
# The goldens in `src/shell/edit/golden.zig` pin the bytes a scripted edit
# produces, and they do it in process where they are stable on every platform.
# What they cannot check is whether a keystroke reaches the editor at all,
# whether a submission starts a turn, whether the prompt comes back after one,
# whether the process ends when it is told to, and whether the history file
# outlives the process that wrote it. That is this script.
#
# It asserts *behaviour*, not transcripts. A pty capture depends on TERM, the
# window size and the probe's timing, and a byte-exact assertion over one is a
# flaky test wearing a golden's clothes.
#
# The pty answers neither capability query, so the kitty protocol is off and
# `alt+enter` is the newline chord (`DR-003`). That is deliberate: it is the
# fallback path, and the fallback path is the one nobody would otherwise run.
#
# Requires a POSIX system with a pty. Skips itself elsewhere rather than
# pretending to pass.
#
# usage: editor-session.sh <binary>
set -eu

binary=${1:-zig-out/bin/tug}

if ! command -v script >/dev/null 2>&1; then
    echo "editor-session: no script(1); skipping" >&2
    exit 0
fi

state=$(mktemp -d)
capture=$(mktemp)
trap 'rm -rf "$state" "$capture"' EXIT

history_file="$state/tug/history"

fail() {
    printf 'editor-session: %s\n' "$1" >&2
    printf -- '--- capture ---\n' >&2
    cat -v "$capture" >&2
    exit 1
}

# Extra environment for the next `drive`, as `NAME=value` pairs. Set it, call
# `drive`, and it is cleared again — an assignment that leaked into a later case
# would be a test passing for the wrong reason.
extra_env=""

# Runs the binary under a pty with $1 driving its stdin.
#
# The input is a shell fragment rather than a string so each case reads as the
# sequence of keystrokes it is. The sleeps are what make the pty deliver them as
# separate reads instead of one burst, which is the only way to tell "the prompt
# came back" from "everything was typed before anything was drawn".
drive() {
    input=$1
    shift
    if ! eval "$input" | timeout 60 script -qec \
        "env XDG_STATE_HOME=$state $extra_env $binary $*" /dev/null >"$capture" 2>&1; then
        extra_env=""
        fail "the session did not exit cleanly"
    fi
    extra_env=""
}

# --- a prompt appears, and ctrl+d leaves ------------------------------------

drive "sleep 1; printf '\004'"
grep -q '> ' "$capture" || fail "no prompt was ever drawn"
echo "editor-session: the prompt opens and ctrl+d closes it"

# --- typing reaches the editor ----------------------------------------------

drive "sleep 1; printf 'hello there'; sleep 1; printf '\003\004'"
grep -q 'hello there' "$capture" || fail "typed text never reached the draft"
echo "editor-session: keystrokes reach the draft"

# --- two turns: the prompt comes back after a response ----------------------
#
# The second message is the assertion. You cannot type `bravo` at a prompt that
# never came back, so its presence in the capture is the round trip.

drive "sleep 1; printf 'alpha'; sleep 1; printf '\r'; sleep 4; \
       printf 'bravo'; sleep 1; printf '\r'; sleep 4; printf '\004'" \
    --provider mock --mock-seed 1 --mock-cadence instant
grep -q 'alpha' "$capture" || fail "the first submission was not echoed"
grep -q 'bravo' "$capture" || fail "the prompt did not come back after a turn"
# Any of the mock's fixed corpus sentences will do. Which ones a turn draws is
# a function of its seed, so pinning one would be pinning the PRNG rather than
# checking that a response arrived.
grep -qE 'bollard pull|no runtime, no telemetry|freestanding library|a cost somebody pays|enforced by CI|can be a plugin' "$capture" ||
    fail "the mock never answered"
echo "editor-session: two turns, and the prompt returns between them"

# --- ctrl+c interrupts a running response -----------------------------------
#
# `stall` and not `firehose`, and the difference was measured rather than
# assumed: a firehose finishes in well under a second here, so a ctrl+c two
# seconds in lands on a prompt that has already come back and arms the exit
# instead of interrupting anything. `stall` parks the provider thread mid-turn
# for as long as it is told to, which is a window this script can actually aim
# at.
#
# ctrl+c before ctrl+d, here and below: on a non-empty draft ctrl+d deletes
# forward — as it does in bash — and only quits on an empty one. ctrl+c clears
# the whole draft, including a multiline one, which is what makes it the
# reliable way to get to an empty prompt.
#
# The waits after the ctrl+c are generous on purpose. A stalled provider is
# sleeping rather than watching the stop flag, so the join that ends the turn
# does not return until the stall does — and until it returns, nothing is
# painted. Typing into that gap would put every following keystroke into one
# read, where the draft would be built and cleared between two frames and never
# drawn at all.
drive "sleep 1; printf 'go'; sleep 1; printf '\r'; sleep 2; printf '\003'; \
       sleep 4; printf 'after'; sleep 2; printf '\003\004'" \
    --provider mock --mock-seed 1 --mock-fault stall=3000
grep -q 'interrupted' "$capture" || fail "ctrl+c did not stop the response"
grep -q 'after' "$capture" || fail "the prompt did not come back after an interrupt"
echo "editor-session: ctrl+c stops a running turn and returns to the prompt"

# --- a multiline entry, written and read back -------------------------------
#
# `\033\r` is alt+enter, which is the newline chord on a terminal without the
# kitty protocol. One entry is one line in the file, with the newline escaped.

drive "sleep 1; printf 'line one\033\rline two'; sleep 1; printf '\r'; \
       sleep 3; printf '\004'"
[ -f "$history_file" ] || fail "no history file was written to $history_file"
grep -qF 'line one\nline two' "$history_file" ||
    fail "the multiline entry was not escaped onto one line"
echo "editor-session: a multiline entry is one escaped line in the history"

# --- history survives the process that wrote it -----------------------------

drive "sleep 1; printf '\033[A'; sleep 2; printf '\003\004'"
grep -q 'line one' "$capture" || fail "up did not recall the previous entry"
grep -q 'line two' "$capture" || fail "the recalled entry lost its second line"
echo "editor-session: history survives a restart, multiline intact"

# --- the file is one line per entry -----------------------------------------

entries=$(wc -l <"$history_file" | tr -d ' ')
if [ "$entries" -lt 3 ]; then
    fail "expected at least three history entries, found $entries"
fi
echo "editor-session: $entries entries, one line each"

# --- the config reaches the shell, not just --debug-config ------------------
#
# `--debug-config` prints the resolved config without ever calling `repl.run`,
# so on its own it proves the loader works and says nothing about whether the
# shell uses what it loaded. `[history] enabled = false` is the one v0.1 setting
# whose effect is visible from outside the process: with it set, a submission
# must leave the history file exactly as it was.
config=$(mktemp -d)
trap 'rm -rf "$state" "$capture" "$config"' EXIT
mkdir -p "$config/tug"
cat >"$config/tug/config.toml" <<'TOML'
[history]
enabled = false
TOML

before=$(wc -l <"$history_file" | tr -d ' ')
extra_env="XDG_CONFIG_HOME=$config"
drive "sleep 1; printf 'not recorded'; sleep 1; printf '\r'; sleep 3; printf '\004'"
after=$(wc -l <"$history_file" | tr -d ' ')

grep -q 'not recorded' "$capture" ||
    fail "the draft never reached the editor in the history-disabled run"
if [ "$before" != "$after" ]; then
    fail "history was disabled in the config and the file still grew: $before -> $after"
fi
if grep -qF 'not recorded' "$history_file"; then
    fail "a submission was written to a history the config had turned off"
fi
echo "editor-session: [history] enabled = false reaches the shell and holds"

# --- a chord rebound from a project config reaches the editor ----------------
#
# The spec's own example: `newline` on ctrl+j. The decoder maps 0x0a to ctrl+j
# and 0x0d to enter (src/shell/input/decoder.zig), so a `\012` is a ctrl+j and
# a `\r` is a submit -- one drive proves the rebind fired *and* that enter
# still submits.
#
# ctrl+j is unbound by default, so this is additive rather than a replacement.
# The replacement case is unit-tested; what a pty adds is that the file was
# found, read, parsed, resolved, and consulted by a real keypress.

cat >"$config/tug/config.toml" <<'TOML'
[keys]
"ctrl+j" = "newline"
TOML

before=$(wc -l <"$history_file" | tr -d ' ')
extra_env="XDG_CONFIG_HOME=$config"
drive "sleep 1; printf 'first\012second'; sleep 1; printf '\r'; sleep 3; printf '\004'"
after=$(wc -l <"$history_file" | tr -d ' ')

if [ "$before" = "$after" ]; then
    fail "nothing was submitted: ctrl+j may have submitted instead of inserting"
fi
grep -qF 'first\nsecond' "$history_file" ||
    fail "ctrl+j did not insert a newline; the project keymap never reached the shell"
echo "editor-session: a chord rebound in .config reaches the keymap"

# --- and a keymap typo is a warning, not a dead shell ------------------------

cat >"$config/tug/config.toml" <<'TOML'
[keys]
"ctrl+nope" = "submit"
"ctrl+j" = "newlin"
TOML

extra_env="XDG_CONFIG_HOME=$config"
drive "sleep 1; printf 'still alive'; sleep 1; printf '\r'; sleep 3; printf '\004'"
grep -q 'still alive' "$capture" ||
    fail "a keymap with two bad entries stopped the shell from opening"
echo "editor-session: a keymap typo warns and the shell still opens"

echo "editor-session: the editor behaves"
