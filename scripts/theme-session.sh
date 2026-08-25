#!/bin/sh
# A theme named in a config file, reaching a real terminal as an escape
# sequence.
#
# The unit tests prove the parser, the goldens prove the encoder, and
# `--debug-config` proves the loader — and none of the three can say whether the
# resolved theme reaches the renderer of a running shell. `repl.run` is the only
# thing that wires them together, and this is the only thing that runs it.
#
# It asserts *bytes*, unlike `editor-session.sh` beside it, and it can: the
# colours a theme names are fixed, so `38;2;29;78;216` is in the capture or the
# theme did not arrive. What it does not assert is where in the capture they
# are, because that depends on TERM, the window size and the probe's timing.
#
# Watched to fail: swap `light` for `dark` in the first case and the assertion
# stops matching. If it still matches, this script is testing nothing.
#
# Requires a POSIX system with a pty. Skips itself elsewhere rather than
# pretending to pass.
#
# usage: theme-session.sh <binary>
set -eu

binary=${1:-zig-out/bin/tug}

if ! command -v script >/dev/null 2>&1; then
    echo "theme-session: no script(1); skipping" >&2
    exit 0
fi

state=$(mktemp -d)
config=$(mktemp -d)
capture=$(mktemp)
trap 'rm -rf "$state" "$config" "$capture"' EXIT

mkdir -p "$config/tug/themes"

# #1d4ed8 and #9cdcfe, the two `user_block` colours, as the decimal triples a
# truecolor SGR spells them. The user's own words are the one slot a session
# this short is guaranteed to paint.
light_user='38;2;29;78;216'
dark_user='38;2;156;220;254'

fail() {
    printf 'theme-session: %s\n' "$1" >&2
    printf -- '--- capture ---\n' >&2
    cat -v "$capture" >&2
    exit 1
}

# `grep ... && fail` would be wrong under `set -e`: a grep that finds nothing
# exits non-zero, the `&&` short-circuits, and the line's own status kills the
# script before the assertion has said anything. Every "must not appear" check
# goes through this instead.
absent() {
    if grep -q "$1" "$capture"; then
        fail "$2"
    fi
}

# Extra environment for the next `drive`, as `NAME=value` pairs. Cleared after
# each call, so an assignment cannot leak into a later case and make it pass for
# the wrong reason.
extra_env=""

# Types one line, submits it, and leaves.
#
# The submission is the point. A draft is painted with the `prompt` slot and an
# echoed submission with `user_block`, and only the second is still on screen
# once the prompt has been redrawn under it — so `user_block` is the slot whose
# absence means something.
drive() {
    if ! { sleep 1
           printf 'colour me'
           sleep 1
           printf '\r'
           sleep 2
           printf '\004'; } |
        timeout 60 script -qec \
            "env TERM=xterm-256color COLORTERM=truecolor XDG_STATE_HOME=$state $extra_env $binary $*" \
            /dev/null >"$capture" 2>&1; then
        extra_env=""
        fail "the session did not exit cleanly"
    fi
    extra_env=""
    grep -q 'colour me' "$capture" || fail "the draft never reached the editor"
}

# --- a theme named in a config file reaches the terminal ---------------------

cat >"$config/tug/config.toml" <<'TOML'
theme = "light"
TOML

extra_env="XDG_CONFIG_HOME=$config"
drive
grep -q "$light_user" "$capture" || fail "the light theme never reached the renderer"
absent "$dark_user" "the dark theme was painted despite the config"
echo 'theme-session: theme = "light" in a config file reaches the renderer'

# --- and the other one, so the first case cannot be passing by accident ------

cat >"$config/tug/config.toml" <<'TOML'
theme = "dark"
TOML

extra_env="XDG_CONFIG_HOME=$config"
drive
grep -q "$dark_user" "$capture" || fail "the dark theme never reached the renderer"
absent "$light_user" "the light theme was painted despite the config"
echo 'theme-session: theme = "dark" paints something different'

# --- --theme outranks the file, which is the flag layer doing its job --------
#
# Phase 7 built five layers and left the top one with nothing but a unit test
# above it, because no flag wrote to a config key. This is the first that does.

cat >"$config/tug/config.toml" <<'TOML'
theme = "dark"
TOML

extra_env="XDG_CONFIG_HOME=$config"
drive --theme light
grep -q "$light_user" "$capture" || fail "--theme did not override the config file"
echo 'theme-session: --theme outranks the config file'

# --- NO_COLOR is a tier, not an absence --------------------------------------
#
# The claim the six goldens make in process, made once against a terminal: with
# NO_COLOR set no theme says anything, and the distinctions a theme was drawing
# are drawn by attributes instead. SGR 1 is what `user_block` degrades to.

extra_env="XDG_CONFIG_HOME=$config NO_COLOR=1"
drive --theme light
absent '38;2;' "NO_COLOR was set and a truecolor sequence was emitted"
absent '38;5;' "NO_COLOR was set and a 256-colour sequence was emitted"
grep -q '\[1m' "$capture" || fail "NO_COLOR lost the bold the user block degrades to"
echo 'theme-session: NO_COLOR emits no colour and keeps the attributes'

# --- a user theme, found by name in the themes directory ---------------------

cat >"$config/tug/themes/mine.toml" <<'TOML'
user_block = "#010203"
TOML
cat >"$config/tug/config.toml" <<'TOML'
theme = "mine"
TOML

extra_env="XDG_CONFIG_HOME=$config"
drive
grep -q '38;2;1;2;3' "$capture" || fail "a user theme in the themes directory was not found"
echo 'theme-session: a hand-written theme loads by name'

# --- and a theme that does not exist is a warning, not a dead shell ----------

cat >"$config/tug/config.toml" <<'TOML'
theme = "nope"
TOML

extra_env="XDG_CONFIG_HOME=$config"
drive
grep -q "$dark_user" "$capture" || fail "an unknown theme did not fall back to the dark built-in"
echo 'theme-session: an unknown theme falls back and the shell still opens'

echo 'theme-session: themes reach the terminal'
