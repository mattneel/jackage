# Linux suite findings (declared environment)

First run of the full product suite inside the declared Linux execution environment
(ADR-0001: WSL2 Ubuntu 24.04.5, kernel `7.2.6-locietta-WSL2-xanmod1`, x86_64, pinned
`0.18.0-dev.146+35accc06e`), against the Mutagen mirror of `C:\src\jackage`.

Raw log: `linux-suite-attempt-1.log` (same directory).

## Result

`25/36 tests passed (11 failed)`, plus two compile errors in the product test binary.

## Findings

| Finding | Owner | Evidence |
|---|---|---|
| `jckg-tests` does not compile on Linux: `src/exec/windows.zig:25:8: dependency on dynamic library 'kernel32' requires enabling Position Independent Code` | M03 work unit | Real Linux compile |
| `jckg-tests` does not compile on Linux: `src/exec/tests.zig:462:56: expected type '*anyopaque', found 'i32'` | M03 work unit | Real Linux compile |
| Eleven `m04/EVAL-0xx` cases fail with `error.TransformerUnavailable` because the vendored transformer is a Windows binary | M04 work unit | **Resolved**: esbuild linux-x64 0.25.10 and Node linux-x64 22.16.0 vendored with recorded digests; `zig build eval-test` then ran `All 33 tests passed` in the guest, including all eleven EVAL cases |
| Vendored tool binaries arrive non-executable because NTFS carries no POSIX mode bits through the Mutagen mirror | M04 / integrator | **Resolved**: `scripts/linux-vendor-modes.sh` restores modes for `vendor/**/bin/*` (idempotent, vendor-only); the same run reported `vendor tool modes: 2 executable file(s) ensured` |
| `eval-tests` itself builds and runs on Linux | - | `All 33 tests passed` (log: `linux-eval-check.log`) |

Platform note: these are portability gaps in the *test* build, not evidence about isolation or
execution. No `linux-*` acceptance case may be recorded until `sh scripts/test.sh` reaches a clean
suite in the guest; a red suite is reported as a blocker, never as partial success.

## What this proves positively

The declared environment itself works: the pinned Linux toolchain compiles and runs product code on
ext4 (`state/baseline/linux-environment.log`), the Mutagen mirror delivers the exact source bytes,
and a full multi-module build attempts to run - the remaining failures are ordinary defects with
named owners, not environment unknowns.
