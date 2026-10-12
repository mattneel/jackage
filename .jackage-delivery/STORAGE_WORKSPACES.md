# Storage and workspaces

## Ownership classes

| Class | Owner | Lifetime |
|---|---|---|
| Primary checkout | User | Never garbage-collected by Jackage. |
| Immutable input or output | Artifact store | Retained by reachability and leases. |
| Development workspace | Project session | Bounded and explicitly reusable. |
| Incremental build cache | Project and toolchain | Quota and retention policy. |
| Temporary action directory | Action | Removed after completion or diagnostic retention. |
| Platform image | Backend and manifest | Referenced artifact or managed mutable storage. |

The physical store location is configurable.
The initial defaults use per-user operating-system data locations outside `C:\src`.
Jackage must not turn `C:\src\jackage\.jackage` into another unbounded cache.
A small project state directory can hold references and metadata only.

## Immutable store

Content writes use a private staging namespace.
Digest verification precedes atomic commitment.
Concurrent writers for the same object converge on one verified object.
Partial, corrupt, or mismatched objects never enter the committed namespace.
The store records format versions for recovery and migration.

Artifacts retain dependency references for garbage collection.
References must include executable runtime dependencies, not only build-time dependencies.
A package that embeds an absolute dependency path needs the corresponding retained reference.
Reference discovery and explicit declarations require tests for missed runtime dependencies.

A consumer never receives a writable hardlink into committed storage.
A read-only attribute alone is not universal mutation protection.
Store materialization must use a platform-specific protection model with failure tests.
An output import verifies that input objects remained unchanged where the threat model requires it.

## Collection and leases

Installed generations, project pins, and active leases are collection roots.
A lease contains an owner identity and recovery metadata.
Wall-clock expiry alone cannot prove that a process is dead.
PID reuse and controller crashes require explicit reconciliation.

Collection first calculates candidates under a consistent view of roots.
A later transaction quarantines eligible candidates before physical deletion.
A newly acquired lease must prevent deletion or detect and retry the race safely.
A dry run reports candidates and retained reasons without mutation.

Collection reports unreachable logical bytes separately from recovered physical allocation.
Hardlinks, sparse extents, compression, and disk images can make those numbers differ.
A failed deletion remains visible as retained or pending state.
The system must never claim successful reclaim from only an internal counter.

## Development cache policy

Each mutable cache has a project identity, purpose, execution platform, toolchain identity, and size budget.
An active action owns a lease before cache eviction can occur.
Corrupt cache contents cannot replace verified release inputs.
Release reproducibility tests run without warm mutable caches.

The initial policy includes per-project limits and a global ceiling.
A cache without recent use becomes an eviction candidate.
Eviction order is deterministic under equal policy values.
Users can pin a cache explicitly and see the resulting retained bytes.
The implementation must report an exceeded budget that pinned objects prevent it from meeting.

## Source snapshots

The primary checkout remains `C:\src\jackage` during case zero.
A source snapshot records exactly which bytes and paths the action receives.
Dirty files can participate in local development snapshots.
A release records its commit and explicit dirty-state policy.
Secrets and ignored build outputs do not enter a snapshot accidentally.

Git ignore rules alone are not a sufficient source manifest.
Some required generated source is ignored, and some secrets are untracked.
The project declares include and exclude rules with a preview command.
`.git`, `.zig-cache`, and `zig-out` remain excluded unless a test explicitly declares an exception.

Snapshot construction must handle concurrent edits.
The implementation detects an unstable file or retries the snapshot operation.
A completed snapshot cannot contain mismatched length and digest metadata.
Input materialization preserves supported names, executable flags, and link semantics.

## Linux execution workspace

The executor materializes the source snapshot on guest-native storage.
Compilation, dependency reads, and incremental caches stay on that filesystem.
A Windows bind mount is not the normal Linux compilation path.
The host-to-guest transfer happens before the build hot path.

Development updates can use a delta protocol or an existing transport adapter.
A file update must reach the guest as a real filesystem change.
Watcher support requires real editor-save and rename tests.
Inotify cache invalidation and emitted events are separate behaviors.

A task waits for its declared source snapshot before execution.
Interactive sessions expose synchronization state and conflicts explicitly.
Guest-generated edits return through an explicit export or reconciled update path.
The initial source snapshot flow does not silently overwrite host edits.
A general bidirectional sync product is not required before immutable action execution works.

## Disk images

VM-backed mutable caches need an explicit trim and compaction capability.
Filesystem free space, image file length, and host allocated bytes are separate measurements.
Compaction runs only under the backend's supported safe lifecycle.
A mounted disk cannot be compacted through an unsafe generic operation.

The test uses disposable volumes and known data patterns.
It records host allocation before writes, after deletion, and after reclaim.
It records inability to compact as a capability limitation.
It never compacts or deletes the user's existing WSL disks.

## Performance targets

The initial target is at most 20 percent execution overhead against an equivalent local filesystem baseline.
This comparison excludes source transfer but reports transfer separately.
The initial interactive update target is p95 below one second for the documented small-edit workload.
These are proposed acceptance budgets, not measured product claims.

Benchmarks fix toolchains, inputs, cache state, CPU limits, and workload sizes.
They report sample counts, warm-up, distributions, and failures.
Large-tree transfer and cold-start costs remain visible.
A faster warm benchmark cannot hide an unbounded cache policy.
