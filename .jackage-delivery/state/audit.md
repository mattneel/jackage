# Repository audit

Baseline recorded by the M00 work unit of the Jackage delivery session on 2026-10-12 (UTC).

## Observed state

- Repository root: `C:\src\jackage` (primary checkout, matches case zero).
- Branch and commit: `master` at `9daddcd` (`chore(repo): initial scaffold`). No remote is configured.
- Uncommitted user changes: untracked `.jackage-delivery/` and `JACKAGE_START_HERE.md` (the delivery pack itself). No tracked file is modified; `git status --porcelain` shows only `??` entries. `git diff HEAD` is empty.
- Host OS, architecture, and minimum tested version: Microsoft Windows 11 Pro, `10.0.26200` (build 26200), 64-bit x86_64 on an AMD Ryzen 9 9955HX3D (32 logical processors, 66,187,247,616 bytes physical memory). The minimum tested version is the running build, `10.0.26200`; nothing older was exercised.
- Wrapper path and exact compiler version: `scripts/zig.ps1` → `tools\zig\zig.exe`, reporting `0.18.0-dev.146+35accc06e` (`scripts/zig.ps1 version`, exit 0). `.zigversion` contains `0.18.0-dev.146+35accc06e` (unchanged, digest in the protected-file record).
- Toolchain provenance mechanism: `scripts/fetch-zig.ps1` downloads `https://ziglang.org/builds/zig-x86_64-windows-<.zigversion>.zip` and verifies it against a hard-coded SHA-256 (`ec5d64aae44b54ce8425ecd7b40f1fa5c8061d1dc80939b02ed036513d69ae67`, comment: from `https://ziglang.org/download/index.json`). Extraction uses the bundled `tar.exe`, then re-runs `zig.exe version` and compares it to `.zigversion`. The pin covers an x86_64-windows build only; the script refuses to run when `$env:OS` is not `Windows_NT`.
- Verified locally: the installed `tools/zig/zig.exe` reports exactly `0.18.0-dev.146+35accc06e`, matching `.zigversion`. The archive digest was not re-verified in this session (the download was already installed and no network fetch occurred); the recorded hash is the script's pin, not an independent observation. `tools/zig/LICENSE` ships the Zig MIT license text.
- Existing license and redistribution constraints: the repository has **no** `LICENSE`, `COPYING`, or `NOTICE` file, so no project-level redistribution terms are declared yet (gap recorded, not invented). The pinned Zig distribution carries its own MIT license at `tools/zig/LICENSE` and is `.gitignore`d (`/tools/zig/`), so it is a bootstrap download, not redistributed source. The delivery pack itself declares original content in `.jackage-delivery/README.md`.

## Existing implementation

The checkout is the unmodified output of `zig init` for Zig 0.18-dev: two source files, an unmodified build graph, and an empty dependency set. There is no Jackage product behavior to characterize beyond the scaffold's own demo behavior.

| Area | Files and behavior | Existing tests | Required delta |
|---|---|---|---|
| Build and bootstrap | `build.zig` (8,435 bytes): one module `jackage` (root `src/root.zig`), one executable `jackage` (root `src/main.zig`), a `run` step with passthrough args, and a `test` step running two test executables. `build.zig.zon`: name `.jackage`, version `0.0.0`, fingerprint `0x1dc6a415088bf9cc`, `minimum_zig_version = "0.18.0-dev.146+35accc06e"`, empty `dependencies`, package paths `build.zig`, `build.zig.zon`, `src`. `scripts/zig.ps1` and `scripts/fetch-zig.ps1` bootstrap the pinned compiler. | `build.zig` itself has no tests; the `test` step exists and passes. | Add `jckg`/`jckgx` artifacts, per-case test filtering, and real modules without replacing the existing graph. |
| CLI and core | `src/main.zig`: prints `All your codebase are belong to us.` to stderr, logs each argv entry via `std.log.info`, writes a demo message to stdout. Uses `std.process.Init` (arena allocator + `std.Io`), `Io.File.Writer` with a 1024-byte buffer, and flushes explicitly. `src/root.zig`: `printAnotherMessage(writer)` and `add(a, b)`. No argument parser, no command registry, no exit-code policy, no structured output. | `src/main.zig`: `simple test` (ArrayList append/pop) and `fuzz example` (`std.testing.fuzz` with `Smith`, self-referential dup check). `src/root.zig`: `basic add functionality`. All pass. | Everything in `CLI_UX.md`; treat the scaffold's own two tests as characterization targets, not as product behavior. |
| QuickJS-NG | Absent. `build.zig.zon` has no dependencies and no vendored C sources exist (`tools/` contains only the Zig toolchain). | None. | Needs dependency selection and licensing review in M04 (`O002`). |
| TypeScript | Absent. No `jackage.ts`, no transformer, no `.d.ts` outside the pack's proposal fixtures. | None. | Needs the M04 transformer decision (`O002`). |
| Platforms | Windows x86_64 host only; the pinned toolchain is single-target (`zig-x86_64-windows`). Cross-targets are compilable by the compiler but have no native evidence. | None. | Native evidence per target requires hardware/toolchain work recorded in M11. |

Preserved (not to be replaced): `src/main.zig`, `src/root.zig`, `build.zig` (extended, not rewritten), `build.zig.zon` (extended, not rewritten), `scripts/*`, `.zigversion`, `.gitignore`. Digests of these eight files were recorded pre-edit in `state/baseline/protected-files.json` and are re-verified by the audit tool.

## Host capability inventory

Produced by `evidence/baseline/host-inventory.ps1` (read-only; only a disposable `%TEMP%` directory was created and removed) into `evidence/baseline/host-inventory.json`.

| Capability | Observed value |
|---|---|
| OS / build | Windows 11 Pro, 10.0.26200, 64-bit |
| Architecture | x86_64 (`AMD64`, `AMD64 Family 26 Model 68 Stepping 0`) |
| Logical processors / memory | 32 / 66,187,247,616 bytes |
| Case sensitivity | Insensitive lookup confirmed (`CaseProbe` found as `caseprobe`) |
| Alternate data streams | Writable on NTFS (`:stream` create succeeded) |
| Long paths | 526-character path created successfully under `%TEMP%` |
| Virtualization | Hypervisor present; `Hyper-V-All`, `VirtualMachinePlatform`, `HypervisorPlatform`, `Microsoft-Windows-Subsystem-Linux` features enabled; `Containers-DisposableClientVM` disabled (state 2) |
| WSL (read-only enumeration) | Distros: `Ubuntu` (running, WSL2, default), `docker-desktop` (running, WSL2). No distro was started, modified, or deleted. |
| Docker | `Docker version 29.2.1` |
| Compilers/SDKs | Visual Studio Community 2026 18.9.12120.119 (complete, launchable), Windows Kits 10.0.18362.0, 19041.0, 22621.0, 26100.0, 28000.0, CMake 4.4.3 |
| Scripting/runtimes | Python 3.13.15 / 3.14.7 / 3.14.8, Node v26.7.0, npm 12.0.2, Bun 1.4.2, PowerShell 7.6.6, Git 2.54.0, Rust 1.92.0, OpenJDK 8, 7-Zip, OpenSSH, GnuPG, OpenSSL, `curl`, `tar` |
| Missing | `clang`, `clang-cl`, MSVC `cl`/`link` on `PATH` (VS is installed; the developer environment is not initialized in this shell), `ninja`, `make`, `gcc`, `dpkg-deb`, `rpmbuild`, `makensis`, `signtool`, `wix`, `qemu-system-x86_64`, `podman`, `go` |
| Unavailable for product evidence | macOS hosts (x86_64/aarch64), aarch64 hosts (Windows and Linux) — no evidence path from this machine |
| Declared execution environment | WSL2 `Ubuntu 24.04.5 LTS` on kernel `7.2.6-locietta-WSL2-xanmod1`, x86_64, 32 CPUs, 433 GB free, with the same pinned Zig build installed through `scripts/fetch-zig-linux.sh` (ADR-0001). Linux evidence is recorded with the recorder running inside that guest, and compilation happens on guest-native storage |

Honest labels: the Windows host is `windows-x86_64` and the declared Linux environment covers `linux-x86_64` as a *declared* environment, not as a second native host. `windows-aarch64`, `linux-aarch64`, `macos-x86_64`, and `macos-aarch64` remain **unavailable**. WSL2 is one Linux environment; a clean-checkout Linux replay is still required before any Linux support claim, so the release matrix stays open even though the milestone work is unblocked. The custom XanMod kernel and host security settings are untouched.

## Dependency provenance

| Input | Pin mechanism | Verification state | License state |
|---|---|---|---|
| Zig toolchain `0.18.0-dev.146+35accc06e` | `.zigversion` + archive SHA-256 in `scripts/fetch-zig.ps1` | Version string verified locally (`zig version`); archive digest **not** re-verified this session (already installed) | Provider license present at `tools/zig/LICENSE` (MIT); distribution is gitignored, not redistributed |
| Zig package dependencies | `build.zig.zon` `.dependencies` | Empty — no external packages are fetched at all | N/A |
| QuickJS-NG | None yet | Absent from the checkout; version/license decision deferred to M04 | Unresolved |
| TypeScript transformer | None yet | Absent; decision deferred to M04 | Unresolved |
| Delivery pack | `MANIFEST.sha256` over the static payload | `delivery.py validate-kit --integrity` state recorded below | Original content per pack README |

No digest is invented for any input that was not observed. Gaps listed as gaps.

## Commands

| Command | Actual exit code | Log | Interpretation |
|---|---|---|---|
| `pwsh -NoProfile -File scripts/zig.ps1 version` | 0 | `evidence/baseline/version.log` | Prints `0.18.0-dev.146+35accc06e`; wrapper works, pin honored |
| `pwsh -NoProfile -File scripts/zig.ps1 build` | 0 | `evidence/baseline/build.log` | Existing build graph succeeds unmodified |
| `pwsh -NoProfile -File scripts/zig.ps1 build test` | 0 | `evidence/baseline/test.log` | Existing test step passes (3 test blocks: 2 in `src/main.zig`, 1 in `src/root.zig`) |
| `pwsh -NoProfile -File .jackage-delivery/evidence/baseline/host-inventory.ps1` | 0 | `evidence/baseline/host-inventory.json` | Host capability inventory captured |
| `python .jackage-delivery/tools/delivery.py validate-kit` | 0 | see `pack-validation` record below | Pack structure valid; 188 cases, 18 milestones, 15 canonical vectors, 40 path vectors, 8 schemas |
| `pwsh -NoProfile -File scripts/test.ps1 -Filter AUD` | 0 | `state/evidence/*.log` | 9 product audit tests pass; per-case markers `JCKG_EVIDENCE AUD-00x` present |
| `pwsh -NoProfile -File scripts/test.ps1` | 0 | `state/evidence/*.log` | Full suite: scaffold tests, product module graph, and audit tests all pass |
| `python .jackage-delivery/tools/delivery.py gate M00` | 0 | `state/evidence/*.json` | `localGateComplete: true`, 8/8 M00 cases with characterize→fault→green→regression evidence and reviews |

The audit is implementation-backed: `src/audit/` re-reads `.zigversion`, the host,
`src/`, `build.zig.zon`, `scripts/fetch-zig.ps1`, the protection record, and the
read-only WSL enumeration every time it runs, and emits the same values as JSON.

No pre-existing test failure was observed: the baseline is fully green. `AUD-005` therefore records the *classification rule* (a pre-existing failure must be preserved and separated from a new failure) against fixture data rather than against a live failure, and the `then` clause ("the report preserves the real exit code") is satisfied by the exit codes above.

Pack validation output (verbatim):

```json
{"kind":"pack-validation","productTestsExecuted":false,"cases":188,"milestones":18,"canonicalVectors":15,"pathVectors":40,"schemaFilesParsed":8,"manifestFilesVerified":0}
```

## Integration decisions

- Preserved implementation: the entire existing checkout. `build.zig` and `build.zig.zon` are extended by the product work unit; `src/main.zig`, `src/root.zig`, `scripts/*`, `.zigversion` and `.gitignore` are not modified, and their pre-edit digests are asserted by the audit tool.
- Existing scaffold behavior to characterize: `jackage.add` (library), `printAnotherMessage` (library writer), and the demo executable's stdout/stderr behavior. These are the only pre-existing behaviors, so the characterization route applies to them rather than to a new-behavior red→green cycle.
- First missing behavior: there is no `jckg` product CLI, no canonical identity/encoding, no store, no executor, no evaluator, no planner, no profile manager. The first product increment is the M01 CLI foundation, which also surfaces the M00 audit through `jckg doctor`.
- First test command: `pwsh -NoProfile -File scripts/zig.ps1 build test` (existing, green). Per-case product evidence uses `pwsh -NoProfile -File scripts/zig.ps1 build test -Dfilter=<case-id>` once the filtered test step exists; the full suite is the regression command.
- Platform or dependency blockers: macOS and aarch64 targets have no evidence path on this machine and stay blocked with recorded evidence of the blocker. Linux is **not** blocked: ADR-0001 declares WSL2 Ubuntu 24.04.5 (same pinned compiler, guest-native build, recorder run in the guest) as the `linux-x86_64` execution environment, with the limits recorded there. ADR-0002 adds the Mutagen development-sync adapter so the guest mirror stays a derived, disposable workspace and a Windows bind mount is never the compilation path. M08 is therefore planned around the declared environment instead of being left blocked.
- Proposed contract changes: none yet. The pack's contracts are adopted as proposals (P001/P002/P003/P004/P005/P006/P007/P009) pending their milestone tests; no existing public contract was found in the checkout, so nothing conflicts with M00's audit mandate.
- Open decisions carried forward: `O001` is answered by this audit (nothing pre-exists beyond the scaffold). `O002` (transformer), `O004` (Windows atomic profile selection), `O005` (Linux isolation implementation) and `O006` (stable logical store paths on Windows) stay open for their milestones.
