#!/bin/sh
# Verify the declared Linux execution environment (ADR-0001).
#
# Records the guest platform, checks that the pinned toolchain is the one
# `.zigversion` requires, and compiles plus runs two self-contained product
# modules so the check is evidence of a working compiler rather than of a
# version string.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
version=$(tr -d ' \r\n' < "$repo_root/.zigversion")
zig=${JCKG_ZIG:-$HOME/jckg/toolchain/zig-$version/zig}

echo "uname: $(uname -srm)"
echo "kernel: $(uname -r)"
echo "distro: $(. /etc/os-release 2>/dev/null && printf '%s' "$PRETTY_NAME" || echo unknown)"
echo "arch: $(uname -m)"
echo "logical cpus: $(nproc 2>/dev/null || echo unknown)"
echo "toolchain: $zig"

if [ ! -x "$zig" ]; then
    echo "pinned Linux Zig not found; run scripts/fetch-zig-linux.sh" >&2
    exit 2
fi
reported=$("$zig" version)
echo "toolchain version: $reported"
if [ "$reported" != "$version" ]; then
    echo "toolchain reports '$reported' but .zigversion pins '$version'" >&2
    exit 3
fi

cd "$repo_root"

echo "--- compile and run: src/core/canonical.zig"
"$zig" test src/core/canonical.zig

echo "--- compile and run: src/plan/version.zig"
"$zig" test src/plan/version.zig

echo "--- compile and run: src/core/digest.zig"
"$zig" test src/core/digest.zig

echo "linux environment verified"
