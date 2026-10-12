# Security and failure model

## Protected assets

The primary assets are user source, credentials, trusted package identities, immutable artifacts, and release signing authority.
The system also protects active workspaces from accidental collection and cache corruption.
A third-party package recipe, archive, channel, cache entry, or external plugin is not trusted by default.

## Trust boundaries

| Boundary | Required defense |
|---|---|
| Configuration to host | Restricted evaluator APIs, worker limits, and process isolation. |
| Channel to resolver | Trust enrollment, signed metadata, rollback state, and scoped namespaces. |
| Archive to filesystem | Validated paths, no traversal, bounded expansion, and race-safe extraction. |
| Action to machine | Enforced capabilities, declared inputs, and contained process trees. |
| Worker to artifact store | Digest verification, provenance policy, and output quarantine. |
| Profile to user execution | Atomic generations, collision handling, and active leases. |
| Collector to storage | Reachability transactions, lease reconciliation, and owned-path validation. |
| Build to publication | Separate credentials and explicit authorization. |

## Adversarial cases

- A recipe attempts to read SSH keys or cloud credentials.
- A recipe imports an undeclared file through a symlink.
- An evaluator loops forever or allocates beyond its budget.
- An archive uses traversal, links, devices, duplicate paths, or a decompression bomb.
- An artifact changes after digest calculation but before commitment.
- A repository serves expired, mixed, replayed, or wrongly signed metadata.
- A repository redirect captures a private GitHub token.
- A worker returns forged output identities or claims unsupported isolation.
- A cache advertises a malicious result under a legitimate action identity.
- A plugin emits oversized frames or mixes diagnostics into protocol stdout.
- An install crashes between generation creation and activation.
- Garbage collection races an action lease or a profile update.
- A process escapes cancellation through grandchildren.
- An attacker replaces a destination directory with a reparse point during extraction.

## Secrets

Build processes receive no ambient home directory, credential agent, or repository token by default.
A secret capability names a purpose and a specific authorized action.
Its value never enters a lockfile, artifact tree, or reusable public cache entry.
Logs use redaction as a secondary defense, not permission to expose a secret initially.
Publication and signing use separate workers or brokered operations.

## Privilege

The ordinary client operates per user.
An elevated helper exposes narrow operations through an authenticated interface.
It does not accept arbitrary shell commands or unchecked filesystem paths.
Privilege installation requires explicit user authorization.
Tests use disposable resources and cannot disable host protection features.

## Recovery

Crash tests interrupt every persistent transaction at documented points.
Recovery must select complete prior or complete new state.
It must not accept a partially written trust root, profile, or artifact.
Disk-full and permission-denied failures retain enough state for diagnosis and retry.
Quarantined corrupt data cannot reenter a trusted namespace without fresh validation.

## Policy claims

Hermeticity describes a declared and enforced environment perimeter.
Reproducibility describes equal output bytes under equivalent declared inputs [S06].
These are different claims.
A system can be isolated and still produce nondeterministic output.
A deterministic test does not prove that a worker cannot access undeclared files.

A capability test cannot prove security against every implementation vulnerability.
Security-sensitive code still requires review, fuzzing, updates, and a documented threat boundary.
The agent must not translate a passed smoke test into an absolute safety guarantee.

## Supply-chain implementation

Use maintained cryptographic implementations.
Pin dependencies and record their licenses.
Do not vendor arbitrary source without provenance.
Do not publish downloaded third-party binaries under an assumed redistribution license.
Jackage self-hosting does not eliminate trust in its bootstrap compiler or operating system.
Record that bootstrap perimeter explicitly.
