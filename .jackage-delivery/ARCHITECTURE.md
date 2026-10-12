# Architecture

## Product boundary

Jackage turns declared inputs into installed profiles, development environments, and distributable artifacts.
The core controls dependency resolution, identity, policy, storage, and evidence.
Backends supply execution, package construction, and repository transport.
A backend cannot redefine core trust policy or artifact identity.

```text
TypeScript configuration
        |
Pinned transformation -> QuickJS-NG -> validated plan
                                      |
                           Resolver and lockfile
                                      |
                           Canonical action graph
                                      |
                     Policy and capability matching
                                      |
                        Pluggable action executor
                                      |
                  Output validation and artifact store
                         /                         \
               Managed profiles             Package actions
                    |                            |
              jckg / jckgx                 Release artifacts
                                                 |
                                      Authorized publication
```

## Core components

| Component | Responsibility |
|---|---|
| Configuration frontend | Converts locked TypeScript modules into validated declarations. |
| Resolver | Selects exact, namespaced package versions and dependency closures. |
| Planner | Produces action graphs, output references, and policy requirements. |
| Policy engine | Grants effects and rejects unsupported execution requirements. |
| Scheduler | Executes ready actions, deduplicates work, and handles cancellation. |
| Artifact store | Imports immutable blobs and trees with atomic publication. |
| Action cache | Associates eligible action identities with validated artifact identities. |
| Profile manager | Creates transactional generations and resolves executable commands. |
| Storage manager | Tracks roots, leases, quotas, and recoverable deletion state. |
| Evidence layer | Records outcomes, provenance, capabilities, and reproduction results. |

These are responsibility boundaries, not mandatory directory names.
The M00 audit determines how they fit the existing source.

## Execution family

An action executor receives a validated action and explicit artifact references.
It materializes inputs, enforces supported restrictions, runs the process, and collects declared outputs.
Its result includes observed capabilities and relevant environment properties.
A successful process exit alone does not validate the outputs.

A native process executor is the bootstrap backend.
It must identify unrestricted filesystem or network access honestly.
A separate strict executor must demonstrate its restrictions with adversarial tests.
The backend name, VM boundary, and container label are not proof of hermeticity.

Development sessions use a distinct contract for mutable state and long-lived services.
They can reuse artifact transfer, execution transport, and leases.
They do not enter the immutable action cache as release builds.

## Package family

A package backend transforms an artifact tree into a plan for package construction.
Its tools and platform requirements become declared action inputs.
It does not run arbitrary host callbacks during planning.
Archive, OCI, native package, and disk-image outputs follow the same validation rules.

Package construction does not imply permission to sign or publish.
A signing stage receives only the required signing authority.
A publication stage receives only the required repository authority.
Their results remain distinct from the unsigned artifact identities.

## Repository family

A repository backend resolves channel metadata and transfers bytes.
The core verifies trust, lengths, digests, identity, and rollback state.
A plugin cannot approve its own untrusted package metadata.
An install request does not execute a repository's configuration file to discover package names.

GitHub Pages and Releases are hosting transports, not new trust roots.
A local fixture backend exercises the full trust path without public publication.
The first public GitHub backend must support explicit root enrollment.

## State separation

A source checkout is user state.
An immutable source snapshot is an input artifact.
A development cache is mutable, bounded acceleration state.
A release output is an immutable artifact after validation.
A profile is a set of references, not a copied filesystem hierarchy.

A worker never receives writable hardlinks into immutable storage.
Copies or copy-on-write materialization preserve store immutability.
Read-only materialization still needs protection against privileged or same-user mutation.
The platform adapter must declare its enforcement boundary.

## Action lifecycle

```text
planned -> validated -> inputs-ready -> leased -> executing
executing -> collecting -> validated-output -> committed
executing -> canceled | failed | infrastructure-error
collecting -> failed | infrastructure-error
```

Only a committed, eligible result enters the shared action cache.
Partial outputs remain outside the artifact namespace.
Cancellation releases leases only after all action processes stop.
A restarted controller reconciles persisted action and lease state before collection.

## Platform model

The client platform, execution platform, and output platform are different fields.
A Windows client can request a Linux action that produces a Windows executable.
The subsequent Windows test action still requires a Windows executor or a declared emulation environment.
An architecture match alone does not establish ABI compatibility.

Relevant platform fields include OS, architecture, ABI, minimum platform version, and required CPU features.
Unconstrained host-native CPU flags are forbidden for portable release outputs.
Kernel and platform dependencies form a declared environment perimeter, not an invisible assumption.

## Identity and caching

An action identity describes the requested computation.
An artifact identity describes actual output bytes and defined metadata.
Distinct output identities for the same action indicate nondeterminism or a compromised execution path.
The cache must preserve that discrepancy instead of silently overwriting the earlier result.

Purely observational fields do not enter an action identity.
Wall-clock duration, worker labels, and log locations are examples.
Policy-relevant environment properties and execution semantics do enter the compatibility decision.
A cache hit cannot weaken the requesting policy's provenance requirements.

## Physical store paths

Absolute store paths can leak into binaries, scripts, and debug information.
Each execution platform needs a stable logical store namespace or an explicit relocation design.
A user-specific Windows path cannot silently become a global cache assumption.

The initial bootstrap backend can use path-bound action identities.
Portable cache claims require independent builds under different physical checkout and cache roots.
The proposed strict Linux executor uses a stable virtual namespace inside its isolated root.
A Windows strategy requires its own decision and native tests.

## Extension strategy

Implement built-in backends behind ordinary Zig interfaces first.
Freeze an external protocol only after two independent implementations exercise those interfaces.
Use process isolation for external plugins to avoid an unstable Zig ABI boundary.
A plugin manifest declares its version, digest, permissions, and supported capabilities.
Process isolation does not make a privileged executor safe or trustworthy.

## Runtime decision

The first Linux executor can use an existing local or remote Linux environment.
That environment is an execution dependency, not a new primary development checkout.
A managed input snapshot keeps filesystem-intensive compilation local to its executor.

Hyper-V, WSLC, WHPX, and Firecracker are candidate later adapters.
WHPX exposes low-level virtualization primitives, not a complete filesystem or package environment [S08].
No custom hypervisor work is necessary before Jackage produces its first images.
