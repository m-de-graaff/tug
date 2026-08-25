#!/bin/sh
# The `/` surface, through a real terminal.
#
# The goldens pin what each command prints and the unit tests pin the router's
# decisions. Neither can say whether a slash typed into a running shell reaches
# a handler, because only `repl.run` wires the two together and only a pty runs
# it. That is the same claim `theme-session.sh` makes about themes.
#
# Watched to fail: drop the tab from the completion case and `no such command`
# appears; drop the `warnAtStartup` call and the warning case stops matching.
# If either still passes, this script is testing nothing.
#
# Requires a POSIX system with a pty. Skips itself elsewhere rather than
# pretending to pass.
#
# usage: command-session.sh <binary>
set -eu

binary=${1:-zig-out/bin/tug}

if ! command -v script >/dev/null 2>&1; then
    echo "command-session: no script(1); skipping" >&2
    exit 0
fi

state=$(mktemp -d)
config=$(mktemp -d)
capture=$(mktemp)
trap 'rm -rf "$state" "$config" "$capture"' EXIT

mkdir -p "$config/tug"

fail() {
    printf 'command-session: %s\n' "$1" >&2
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
# each call so an assignment cannot leak into a later case and make it pass for
# the wrong reason.
extra_env=""

# Feeds stdin — assembled by the caller — to a shell in a pty.
drive() {
    if ! timeout 60 script -qec \
        "env TERM=xterm-256color COLORTERM=truecolor XDG_STATE_HOME=$state $extra_env $binary" \
        /dev/null >"$capture" 2>&1; then
        extra_env=""
        fail "the session did not exit cleanly"
    fi
    extra_env=""
}

# --- /help lists the registry ------------------------------------------------

{ sleep 1; printf '/help\r'; sleep 1; printf '\004'; sleep 1; } | drive
grep -q '/config' "$capture" || fail "/help did not list /config"
grep -q '/theme \[name\]' "$capture" || fail "/help did not print the argument spec"
echo 'command-session: /help lists the registry'

# --- an unknown command suggests rather than sends ---------------------------

{ sleep 1; printf '/thme\r'; sleep 1; printf '\004'; sleep 1; } | drive
grep -q 'no such command' "$capture" || fail "an unknown command was not reported"
grep -q "did you mean '/theme'" "$capture" || fail "the near miss was not suggested"
echo 'command-session: an unknown command suggests the near miss'

# --- a line that merely starts with a slash is still a prompt ----------------
#
# No provider is configured, so a submission that reaches the provider path says
# so. That notice is the proof the router let the line through.

{ sleep 1; printf '/etc/hosts is wrong\r'; sleep 1; printf '\004'; sleep 1; } | drive
absent 'no such command' "a path was eaten as a command"
grep -q 'no provider configured' "$capture" || fail "the path was not submitted as a prompt"
echo 'command-session: a path is submitted, not routed'

# --- tab completes, and the completed command runs ---------------------------
#
# `/qui` + tab + enter. If completion did not fire the line is not a command and
# the shell answers `no such command` instead of leaving.

{ sleep 1; printf '/qui\t'; sleep 1; printf '\r'; sleep 2; } | drive
absent 'no such command' "tab did not complete /qui before it was submitted"
echo 'command-session: tab completes a command name and the result runs'

# --- /theme switches the live theme -----------------------------------------
#
# #1d4ed8, the light theme's `user_block`, as the decimal triple a truecolor SGR
# spells it. The submission after the switch is what paints it.

light_user='38;2;29;78;216'
{ sleep 1; printf '/theme light\r'; sleep 1; printf 'colour me\r'; sleep 2; printf '\004'; sleep 1; } | drive
grep -q 'colour me' "$capture" || fail "the draft after the switch never reached the editor"
grep -q "$light_user" "$capture" || fail "/theme did not reach the renderer"
echo 'command-session: /theme switches the live theme'

# --- /config renders all three warning lists, and the startup line counts them

cat >"$config/tug/config.toml" <<'TOML'
theme = "nope"
nosuch = 1
[keys]
"ctrl+@@" = "newline"
TOML

extra_env="XDG_CONFIG_HOME=$config"
{ sleep 1; printf '/config\r'; sleep 2; printf '\004'; sleep 1; } | drive
grep -q 'warnings in your configuration' "$capture" || fail "the startup line did not count the warnings"
grep -q 'no such setting' "$capture" || fail "/config did not print the config's own list"
grep -q 'not a key chord' "$capture" || fail "/config did not print the keymap's list"
grep -q 'no such theme' "$capture" || fail "/config did not print the theme's list"
echo 'command-session: /config renders all three warning lists'

# --- and a clean config says nothing ----------------------------------------

cat >"$config/tug/config.toml" <<'TOML'
theme = "light"
TOML

extra_env="XDG_CONFIG_HOME=$config"
{ sleep 1; printf '\004'; sleep 1; } | drive
absent 'in your configuration' "a clean config opened with a warning line"
echo 'command-session: a clean config opens silently'

echo 'command-session: commands reach the terminal'
