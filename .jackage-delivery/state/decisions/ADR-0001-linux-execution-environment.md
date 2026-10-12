# ADR-0001: Declared Linux x86_64 execution environment (WSL2)

## Status

Accepted, by explicit user direction (the agent had recorded Linux as blocked; the user corrected that).

## Requirement

- `PROJECT_CONTEXT.md` fixed scope: native Linux product support, and a "managed execution snapshot ... disposable and policy-controlled".
- `ROADMAP.md` M08: "Demonstrate real isolation and authenticated artifact exchange from the Windows client"; prerequisites M03 and M05.
- `TDD_PLAYBOOK.md` platform evidence: "Explicit targets require native evidence **or a documented declared execution environment**."
- `CASE_ZERO.md`: "The first Linux executor receives an immutable or versioned snapshot from `C:\src\jackage`. It builds on its native filesystem." and "The executor can be local or remote under an explicit policy. Existing Linux infrastructure can support development before the final local runtime exists."

## Observed problem

The M00 audit found no second Linux host, and the agent initially classified every `linux-*` case as blocked. That was too strict: the machine already runs WSL2, which is a real Linux kernel with real namespaces, and the pack allows a declared execution environment. Three constraints had to be respected:

1. the compiler pin must not change (`0.18.0-dev.146+35accc06e`);
2. compilation must happen on guest-native storage, not on a Windows bind mount;
3. the user's custom kernel and host security settings must not be touched.

## Alternatives

| Option | Evidence | Verdict |
|---|---|---|
| Keep Linux blocked | No Linux host was found in M00 | Rejected: WSL2 exists and is a real Linux environment; the pack permits a declared environment |
| New Hyper-V/VM guest | Requires new virtualization configuration and machine changes | Rejected for now: heavy, and `RELEASE_GATES.md` does not require it before the first executor |
| Remote CI/cloud Linux | No credentials are authorized; billable resources are forbidden without authorization | Rejected for this session; still required later for independent replay |
| Declared WSL2 environment | `uname -a`, `/etc/os-release`, toolchain and digest checks recorded below | **Chosen** |

Observed facts (recorded 2026-10-12):

```text
Linux MSI 7.2.6-locietta-WSL2-xanmod1 #1 SMP PREEMPT_DYNAMIC Tue Sep 15 07:31:37 UTC 2026 x86_64 GNU/Linux
PRETTY_NAME="Ubuntu 24.04.5 LTS"   (NAME="Ubuntu", VERSION_ID="24.04")
32 logical CPUs, 30 GiB RAM, 1007G root filesystem with 433G free
python3, curl, tar, sha256sum, rsync, xz present
```

Toolchain: `https://ziglang.org/builds/zig-x86_64-linux-0.18.0-dev.146+35accc06e.tar.xz`, SHA-256 `1061dbb921f62b67765810609a80c17fa69eeced9f21e9a7e0d06b4e0d7a3715`, 59,081,176 bytes, read from `https://ziglang.org/download/index.json` where `master` reports the same version the checkout pins.

## Decision

`wsl2-ubuntu-24.04.5-x86_64` is the **declared execution environment** for the `linux-x86_64` platform role, used through:

- `scripts/fetch-zig-linux.sh` - installs the pinned Linux toolchain into guest-native storage (`$HOME/jckg/toolchain`), verifying the archive digest from `.zigversion`;
- `scripts/test.sh` - the guest test loop (build-system steps plus the installed product test binary);
- the pack recorder executed **inside** the guest, so a `linux-x86_64` evidence record is produced by a process that really reports that platform.

Source reaches the guest through a versioned snapshot (see ADR-0002), and compilation happens on ext4. Declared outputs are exported back explicitly; nothing writes into `C:\src\jackage` implicitly except evidence files, which the recorder writes through the Windows path so all records stay in one place.

## Consequences

- M08, M09, M11 (Linux rows), and the Linux halves of M10/M15 become reachable instead of blocked.
- Platform-role separation stays honest: `windows-*` evidence still comes from Windows, and a Linux run cannot satisfy a Windows or macOS case.
- The guest filesystem is disposable state: deleting `~/jckg/dev` or the guest toolchain loses nothing that is not reproducible from the checkout plus the pinned digests.
- The custom XanMod kernel (the user's existing WSL setup) is used as-is; no kernel, WSL configuration, or host security setting is modified.
- Recorded limits, to be repeated in every report: WSL2 is **one** Linux environment, not the independent native Linux host the release matrix wants; a clean-checkout Linux replay in CI remains required before any Linux support claim; macOS and aarch64 targets stay unavailable; isolation claims measured inside WSL are labelled with that environment.

## Tests

- Positive: guest `zig version` equals the pin; the guest test suite builds and runs (`scripts/test.sh`); a `linux-x86_64` evidence record shows `actualPlatform: linux-x86_64`.
- Negative: an archive whose SHA-256 differs is refused (`fetch-zig-linux.sh` exit 3); a toolchain reporting a different version is refused (exit 4); the wrapper still refuses non-Windows hosts.
- Recovery: deleting the guest toolchain or workspace and re-running the bootstrap restores an identical environment; the Windows checkout is unaffected.

## Sources

- `CASE_ZERO.md`, `PLATFORMS_PACKAGING.md`, `STORAGE_WORKSPACES.md` ("Linux execution workspace"), `TDD_PLAYBOOK.md` (platform evidence).
- `https://ziglang.org/download/index.json` (pinned build available for x86_64-linux).
- Local observations recorded above.
