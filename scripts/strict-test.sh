#!/bin/sh
# Run the strict-execution suite inside a Linux execution environment.
#
# This is the guest-side counterpart of scripts/test.sh for the sandbox cases
# (M08 STRICT-*): it uses the pinned Linux toolchain, builds the guest worker and
# probe for this host, and runs the sandbox acceptance tests.
#
# It uses its own cache directory. Builds in the same checkout share one cache
# lock, and a second build waiting on the first one's lock is indistinguishable
# from a hung test - which cost an afternoon once already.
#
# Usage: scripts/strict-test.sh [case-filter]
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

# Guest-local by default, and deliberately *outside* the checkout: the checkout is the
# Mutagen mirror, so a build cache inside it is written by both sides and invalidated by
# the sync. That produced builds that took minutes and produced nothing.
cache_dir=${JCKG_STRICT_CACHE:-/tmp/jckg-strict-cache}
mkdir -p "$cache_dir"

# The worker and the probe must exist before the suite runs: the tests start the
# real worker under real namespaces, and an action that cannot be found would look
# like a sandbox refusal.
"$zig" build worker probe --cache-dir "$cache_dir"

# The test binary is *run* directly rather than through `zig build strict-test`:
# the build runner buffers test output, so a hanging test produces a log of zero
# bytes, and the sandbox harness prints the steps it reached precisely so a
# failure can be located. Direct execution streams those prints as they happen.
build_log=$(mktemp)
status=0
if [ -n "$filter" ]; then
    "$zig" build strict-test -Dfilter="$filter" --cache-dir "$cache_dir" --summary none >"$build_log" 2>&1 || status=$?
else
    "$zig" build strict-test --cache-dir "$cache_dir" --summary none >"$build_log" 2>&1 || status=$?
fi
if [ "$status" -ne 0 ]; then
    # The build log is the diagnosis; hiding it behind a redirect cost an hour of
    # chasing a "hang" that was a compile failure.
    echo "strict suite failed to build:" >&2
    cat "$build_log" >&2
    exit "$status"
fi

binary=$(find "$cache_dir" -name strict-tests -type f | head -1)
if [ -z "$binary" ]; then
    echo "strict test binary not found under $cache_dir" >&2
    exit 2
fi
"$binary"
exit "$?"
