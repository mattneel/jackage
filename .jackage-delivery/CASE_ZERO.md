# Case zero: Jackage builds Jackage

## Bootstrap boundary

The existing checkout and `scripts/zig.ps1` form the initial development environment.
The compiler version remains `0.18.0-dev.146+35accc06e`.
The official index currently records that exact build [S01].
A matching version string does not prove the local compiler binary's provenance.
The audit must inspect the bootstrap script's verification path.

The audit must not replace the current build to match this document.
Existing QuickJS-NG integration, platform support, or tests count as implementation to characterize.
Unknown dependency pins require inspection, not invented versions or digests.

## Bootstrap stages

| Stage | Construction | Evidence |
|---|---|---|
| B0 | Existing pinned tools build the first client. | Baseline build, test, and toolchain identity. |
| B1 | B0 realizes the locked Jackage environment and builds the client. | Declared inputs, action results, and output digests. |
| B2 | B1 repeats that build from a fresh workspace. | Independent output comparison under equal declared inputs. |
| B3 | The resulting client creates its packages and environment image. | Package tests, image tests, and local-channel installation. |

A stage comparison needs the same compiler inputs and recipe semantics.
A different bootstrap recipe cannot silently justify mismatched binaries.
Unsigned payloads and intentionally variable signing envelopes need separate comparisons.

## Initial declaration

The future `jackage.ts` describes Jackage sources, the Zig toolchain, QuickJS-NG, and transformation tools.
It declares build, test, package, and development targets.
The lockfile resolves every imported recipe and downloaded artifact.
The source declaration excludes `.zig-cache`, `zig-out`, logs, and secret files.

OMP can initially run as the existing host tool.
Its model credentials stay outside Jackage build actions.
A later development-image recipe can package OMP only after its dependencies and licenses are reviewed.
The agent harness is not a release-build dependency unless the recipe explicitly declares it.

## Development workflow

The desired eventual commands are:

```powershell
jckg doctor
jckg lock
jckg develop
jckg test --locked
jckg build --locked
jckg package --format oci --locked
```

These commands are product targets, not current executable instructions.
The first agent session must use the real existing wrapper and discovered test commands.

## Linux workflow

The first Linux executor receives an immutable or versioned snapshot from `C:\src\jackage`.
It builds on its native filesystem.
It exports declared outputs through verified artifact transfer.
It does not require the user to maintain a second source checkout manually.

The executor can be local or remote under an explicit policy.
Existing Linux infrastructure can support development before the final local runtime exists.
A missing VM capability is not permission to rewrite the kernel or host security configuration.

## Migration demonstration

One disposable legacy fixture demonstrates migration from separate Windows and Linux caches.
The demonstration preserves source ownership and maps caches into managed storage classes.
It reports retained bytes before and after managed cleanup.
No real legacy project or WSL distribution is deleted by this demonstration.

The final migration guide includes rollback to the previous workflow.
The guide names all changed files and all created storage roots.
It must preserve uncommitted source and generated files that the user explicitly retains.

## Definition of first useful delivery

A native Windows client can build and test Jackage through its locked environment.
It can package itself and install that package from a local verified channel.
`jckgx` can run the same package without changing the installed profile.
The store can report ownership and safely collect an unreferenced artifact.

That milestone is useful but not full delivery.
Native cross-platform support, strict execution, public channel support, images, and external plugins remain required later gates.
