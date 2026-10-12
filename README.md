# Jackage

[![License: MIT](https://img.shields.io/github/license/mattneel/jackage)](LICENSE)
[![Zig 0.18.0-dev.146](https://img.shields.io/badge/Zig-0.18.0--dev.146-F7A41D?logo=zig&logoColor=black)](.zigversion)
[![QuickJS-NG 0.17.0](https://img.shields.io/badge/QuickJS--NG-0.17.0-5A5A5A)](vendor/manifest.json)
[![Linux](https://img.shields.io/badge/Linux-x86__64-FCC624?logo=linux&logoColor=black)](#build-and-test)
[![Windows](https://img.shields.io/badge/Windows-x86__64-0078D4?logo=windows&logoColor=white)](#build-and-test)

A package manager and reproducible software assembly system, written in Zig with
QuickJS-NG for JavaScript evaluation. Jackage assembles packages, development
environments, and release images, with three independent backend families.

* **Execution, package, and repository backends are independent.** The core owns
  dependency resolution, identity, policy, storage, and evidence; a backend supplies
  capability but cannot redefine trust policy or artifact identity.
* **Source, immutable artifacts, and disposable caches are separate.** Identities are
  canonical digests, the store is content-addressed and append-only, and a cache is
  something that can be deleted without losing a fact.
* **A release claim belongs to executed evidence.** Each acceptance case records a
  deliberate implementation fault and shows the test failing for that reason, so the
  evidence demonstrates the assertion is load-bearing rather than merely present.

The strict execution backend runs actions inside user, mount, PID, and network
namespaces: a fresh tmpfs root, the workspace writable, the store read-only, declared
inputs copied in rather than bind-mounted (the kernel refuses host binds in an
unprivileged user namespace), and a `chroot` so the host filesystem is not reachable.
A worker's capability claims are never trusted until an independent probe fails to break
them.

## Status

Mid-delivery, and honest about it. The implementation follows an ordered, test-driven
milestone plan; every completed case carries characterize, fault, green, and regression
evidence plus a review.

| Milestone | State |
|---|---|
| M00 repository audit and baseline | complete |
| M01 CLI foundation and diagnostics | complete |
| M02 canonical identities and immutable storage | complete |
| M03 native action execution | complete |
| M04 TypeScript and QuickJS-NG evaluation | complete |
| M05 resolution, plans, and lockfiles | complete |
| M06 profiles and transient execution | complete |
| M07 repository trust and local channels | complete |
| M08 strict Linux execution and verified transport | in progress |
| M09–M17 | not started |

## Requirements

- The pinned Zig toolchain in `.zigversion` (currently `0.18.0-dev.146+35accc06e`).
  `scripts/zig.ps1` fetches the pinned compiler into `tools/zig/` on first use.
- Windows for the host test suite, and a Linux environment for the guest suites.
  The strict sandbox requires Linux namespaces.

## Build and test

```powershell
pwsh -NoProfile -File scripts/zig.ps1 build            # build jckg
pwsh -NoProfile -File scripts/test.ps1                 # full test suite
pwsh -NoProfile -File scripts/test.ps1 -Filter m05     # one case or group
```

Linux (guest) suites, including the sandbox acceptance tests:

```sh
sh scripts/test.sh                      # product suite in the guest
sh scripts/strict-test.sh STRICT-001    # build worker, probe, and the sandbox suite
```

The sandbox builds two helper programs for the Linux execution environment:

```powershell
pwsh -NoProfile -File scripts/zig.ps1 build worker probe
```

## Vendored tools

`vendor/manifest.json` records every third-party distribution with its version, license,
download URL, and SHA-256. The large distributions (esbuild, TypeScript, Node) are **not**
committed; fetch and verify them with:

```powershell
pwsh -NoProfile -File scripts/fetch-vendor.ps1
```

`vendor/quickjs-ng` is committed: it is C source the build compiles directly, so it must
not depend on a network fetch.

## Repository layout

| Path | Contents |
|---|---|
| `src/core` | Canonical encoding, digests, artifact store, cancellation, journal |
| `src/plan` | Resolver, planner, lockfile |
| `src/exec` | Native execution backends and their journals |
| `src/eval` | TypeScript transform and QuickJS-NG evaluation |
| `src/profile` | Profile generations, leases, and transient execution |
| `src/trust` | Keys, root metadata, download, archive extraction |
| `src/worker` | Strict execution: protocol, authentication, sandbox, probes |
| `src/cli` | `jckg` command surface |
| `scripts` | Build, test, and evidence wrappers for Windows and Linux |
| `.jackage-delivery` | Delivery plan, acceptance cases, and recorded evidence |

## License

MIT. See [LICENSE](LICENSE).
