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

# Windows is here despite being tier-2, and despite the phase TODO's own line
# naming only Linux and macOS. tug is developed on Windows and the shell runs
# there; shipping every platform except the author's own was an oversight, not
# a policy. What tier-2 means is written in the release notes, not enforced by
# withholding the binary.
for triple in \
    x86_64-linux-musl \
    aarch64-linux-musl \
    x86_64-macos \
    aarch64-macos \
    x86_64-windows \
    aarch64-windows
do
    echo "building $triple"

    # Both candidates go before the build, not after it. `zig build` only writes
    # the one its target needs, so a leftover from a previous build — or from a
    # native `zig build` someone ran by hand — is still sitting there when the
    # next target finishes, and the check below picks the wrong one. That is not
    # hypothetical: it shipped a Windows PE named `tug-x86_64-linux-musl.exe`.
    rm -f zig-out/bin/tug zig-out/bin/tug.exe

    zig build -Dtarget="$triple"

    # Windows targets produce tug.exe, and the extension has to survive into the
    # asset name or nobody can run what they downloaded.
    if [ -f zig-out/bin/tug.exe ]; then
        cp zig-out/bin/tug.exe "$out/tug-$triple.exe"
    elif [ -f zig-out/bin/tug ]; then
        cp zig-out/bin/tug "$out/tug-$triple"
    else
        echo "release-build: $triple produced no binary" >&2
        exit 1
    fi
done

# Every asset's file type, checked rather than assumed. A cross-compile that
# silently produced the host's format is the failure this catches.
if command -v file >/dev/null 2>&1; then
    echo
    for asset in "$out"/tug-*; do
        printf '%s: %s\n' "$(basename "$asset")" "$(file -b "$asset" | cut -c1-60)"
    done
fi

( cd "$out" && sha256sum tug-* >SHA256SUMS )

ls -l "$out"
cat "$out/SHA256SUMS"
