#!/bin/sh
# The zero-network tripwire.
#
# v0.1's strongest claim is that it cannot talk to the network, and a claim that
# rests on everyone remembering is not a claim. Network code arrives in v0.2
# behind the provider interface; until then a hit here is a failed build.
#
# usage: no-network.sh [directory]
set -eu

root=${1:-src}
pattern='std\.http|std\.net|std\.posix\.socket|std\.crypto\.tls'

if grep -rnE "$pattern" "$root"; then
    echo "" >&2
    echo "no-network: v0.1 ships zero network code; the matches above fail the build." >&2
    echo "If this is v0.2 provider work, delete this gate in the commit that adds it." >&2
    exit 1
fi

echo "no-network: clean ($root)"
