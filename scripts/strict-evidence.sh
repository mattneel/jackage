#!/bin/sh
# Record one evidence stage for a strict-execution case, inside the declared
# Linux environment.
#
# Usage: scripts/strict-evidence.sh <CASE> <STAGE>
#
# It exists because interpolating a shell loop through the Windows->WSL boundary
# mangles the loop variable; a script takes its arguments intact.
set -eu

case_id=$1
stage=$2

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
kit=/mnt/c/src/jackage/.jackage-delivery

cd "$repo_root"
exec python3 "$kit/tools/delivery.py" run \
    --case "$case_id" \
    --stage "$stage" \
    --test-id "$case_id" \
    --marker "JCKG_EVIDENCE $case_id" \
    --cwd . \
    -- sh scripts/strict-test.sh "$case_id"
