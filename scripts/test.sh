#!/bin/sh
# Run the product test suite inside a Linux execution environment.
#
# This is the guest-side counterpart of scripts/test.ps1: it uses the pinned
# Linux toolchain, builds and runs every test step, then runs the installed
# product test binaries so that each case's own output (including its evidence
# marker) is visible in the transcript.
#
# Test artifacts are installed under a prefix derived from the filter, so
# concurrent filtered runs never overwrite each other's binaries.
#
# Usage: scripts/test.sh [filter]
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
version=$(tr -d ' \r\n' < "$repo_root/.zigversion")
filter=${1:-}

zig=${JCKG_ZIG:-$HOME/jckg/toolchain/zig-$version/zig}
if [ ! -x "$zig" ]; then
    echo "pinned Linux Zig not found at $zig" >&2
    echo "run scripts/fetch-zig-linux.sh first" >&2
    exit 2
fi

cd "$repo_root"

prefix=zig-out
if [ -n "$filter" ]; then
    safe=$(printf '%s' "$filter" | tr -c 'A-Za-z0-9._-' '-')
    prefix=".zig-cache/test-prefix-$safe"
fi

if [ -n "$filter" ]; then
    "$zig" build test "-Dfilter=$filter" --prefix "$prefix"
else
    "$zig" build test --prefix "$prefix"
fi

# Install the client binaries at the default prefix: the integration tests look
# for zig-out/bin/jckg.
"$zig" build

found=0
for binary in "$prefix"/bin/*-tests*; do
    [ -f "$binary" ] || continue
    case "$binary" in
        *.pdb) continue ;;
    esac
    echo "=== $(basename "$binary") ==="
    "$binary"
    found=1
done

if [ "$found" -eq 0 ]; then
    echo "no installed test binary was found under $prefix/bin" >&2
    exit 1
fi
