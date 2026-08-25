#!/bin/sh
# Runs a command with no network at all.
#
# v0.2's claim is that CI never touches a network. A grep proves nothing about
# what a test does at runtime; a namespace with no interfaces does. A test that
# opens a socket in here does not flake, it fails.
#
# Loopback is brought up because the Phase 10 bench server needs it, and a
# loopback-only namespace is still a namespace with no route off the machine.
#
# usage: offline.sh <command> [args...]
set -eu

if [ "$#" -eq 0 ]; then
    echo "offline: usage: offline.sh <command> [args...]" >&2
    exit 2
fi

if ! command -v unshare >/dev/null 2>&1; then
    echo "offline: unshare(1) not found; install util-linux." >&2
    exit 2
fi

# -r maps the caller to root inside the namespace, which is what makes -n work
# without sudo on a stock GitHub runner. If the kernel refuses unprivileged user
# namespaces, unshare fails loudly rather than running with a network.
#
# Unrelated to this script but hit at the same time: a Zig build whose cache
# lives on a Windows drive mount under WSL fails to rename its results into
# place, with or without the namespace. Point the cache at the Linux filesystem
# — `export ZIG_LOCAL_CACHE_DIR=$HOME/.cache/tug-zig` — before running a build
# through here from that machine.
exec unshare -rn sh -c 'ip link set lo up 2>/dev/null || true; exec "$@"' sh "$@"
