#!/bin/sh
# Restore POSIX modes for vendored tool binaries inside a guest environment.
#
# The checkout lives on NTFS and reaches this environment through Mutagen
# (ADR-0002). NTFS has no POSIX mode bits, so a synced executable arrives
# non-executable and the evaluator would then honestly report its transformer or
# engine as unavailable. This script makes the known tool binaries executable
# again. It is idempotent, only touches files under `vendor/` that look like
# executables, and changes nothing else.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

count=0
for candidate in "$repo_root"/vendor/*/*/bin/* "$repo_root"/vendor/*/*/*/bin/*; do
    [ -f "$candidate" ] || continue
    case "$candidate" in
        *.pdb|*.dll|*.lib|*.h|*.json|*.md|*.txt) continue ;;
    esac
    chmod 755 "$candidate" 2>/dev/null || continue
    count=$((count + 1))
done

echo "vendor tool modes: $count executable file(s) ensured"
