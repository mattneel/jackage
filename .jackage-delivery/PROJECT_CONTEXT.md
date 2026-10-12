# Project context

## User requirements

Jackage is a separate project from the future development runtime.
It assembles reproducible development environments and release images, with a Nix-like dependency model.
Its implementation language is Zig master, with an exact compiler pin.
QuickJS-NG evaluates the JavaScript produced from TypeScript configuration.
Its user interface resembles an apt-style package manager without system-wide file scattering.

The required entry points include:

```text
jckg install --repo https://github.com/mattneel/myproject myproject
jckgx --repo https://github.com/mattneel/myproject myproject --help
```

The URL is the user's illustrative interface example.
It is not evidence that the repository or channel currently exists.
Tests must not publish to that repository.

Repository backends support custom channels through GitHub Pages, GitHub Releases, or both.
Execution backends and platform package backends are independent extension families.
Humans and coding agents use the same plans, policies, and result contracts.

## Case zero

The primary checkout is `C:\src\jackage`.
Oh-My-Pi is the user's coding agent.
The user supplied the following repository inventory:

```text
.zig-cache/
scripts/
src/
tools/
zig-out/
.gitignore
.zigversion
build.zig
build.zig.zon
```

The supplied command and result are:

```powershell
.\scripts\zig.ps1 version
# 0.18.0-dev.146+35accc06e
```

No implementation contents accompanied that inventory.
No license, Git remote, CPU architecture, or current test layout is assumed.
M00 must discover those details locally.

## Workflow problem

The old workflow contains a large WSL distribution and a second source tree under `~/src`.
Windows and Linux retain separate build caches without a unified lifecycle.
The desired workflow keeps source ownership clear and uses native filesystems for build operations.
It does not require immediate shared-file semantics across NTFS and Linux.
A managed execution snapshot is acceptable when it is disposable and policy-controlled.

The user already uses a custom XanMod kernel in ordinary WSL.
This pack does not modify that kernel or infer the kernel inside any separate VM.

## Fixed scope

- Zig core, QuickJS-NG evaluator, and TypeScript authoring.
- Exact toolchain pins and explicit bootstrap inputs.
- Immutable artifacts, dependency closures, profiles, and rollback.
- `jckg` and `jckgx` through the same resolver and store.
- Independent execution, package, and repository backends.
- GitHub Pages-only, Releases-only, and hybrid channel tests.
- Hermetic release actions with explicit platform limits.
- Reproducibility evidence and bounded storage.
- Jackage self-hosting and Jackage-built development and release images.
- Native Windows, Linux, and macOS product support through a published support matrix.

## Initial proposals

The file names `jackage.ts` and `jackage.lock.json` are proposed interfaces.
The JSON contracts in this pack define proposal version 1.
SHA-256 is the initial digest algorithm for interoperability and test vectors.
External plugins use a versioned process protocol after internal contracts stabilize.
A Linux reference executor precedes custom local Hyper-V or Firecracker adapters.

## Deferred decisions, not deleted requirements

The final devcontainers-style frontend and its product name remain undecided.
A local Hyper-V, WSLC, or WHPX adapter requires an evidence-based runtime decision.
The remote Firecracker provider remains a separate integration target.
The model provider inside OMP remains the user's choice.
This pack makes no assertion about a model's current availability or pricing.

The universal vision does not claim every OS, architecture, ABI, or installer format at version 1.
`PLATFORMS_PACKAGING.md` defines the delivery matrix and explicit expansion points.
New platform claims require new executed acceptance evidence.
