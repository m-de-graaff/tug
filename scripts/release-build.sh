#!/bin/sh
# Builds the v0.1 release matrix from one machine, which is a large part of why
# the roadmap's five-minute CI wall is survivable at all.
#
# Signing, checksums-as-policy and distribution channels are v0.8 scope. What
# this produces is four binaries and the sums for them, to be labelled loudly
# pre-alpha wherever they are published.
#
# usage: release-build.sh
set -eu

out=zig-out/release
rm -rf "$out"
mkdir -p "$out"

for triple in \
    x86_64-linux-musl \
    aarch64-linux-musl \
    x86_64-macos \
    aarch64-macos
do
    echo "building $triple"
    zig build -Dtarget="$triple"
    cp zig-out/bin/tug "$out/tug-$triple"
done

( cd "$out" && sha256sum tug-* >SHA256SUMS )

ls -l "$out"
cat "$out/SHA256SUMS"
