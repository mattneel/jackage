# Delivery roadmap

The milestones form a dependency graph, not an instruction to create a new scaffold.
Existing working behavior takes the characterization route.
Every required milestone remains in scope until executed evidence satisfies it.

## M00: Repository audit and baseline

Characterize existing code before edits. Preserve the supplied toolchain and user changes.

Prerequisites: None.

Read the matching cases in `acceptance/cases.json`.
Deliver a usable behavior slice with tests before the next slice.
Do not satisfy this milestone with a mock-only demonstration.

## M01: CLI foundation and diagnostics

Deliver a real native CLI with safe structured output and a discovered build/test loop.

Prerequisites: M00.

Read the matching cases in `acceptance/cases.json`.
Deliver a usable behavior slice with tests before the next slice.
Do not satisfy this milestone with a mock-only demonstration.

## M02: Canonical identities and immutable storage

Implement verified blobs and trees, independent golden vectors, and atomic store transactions.

Prerequisites: M01.

Read the matching cases in `acceptance/cases.json`.
Deliver a usable behavior slice with tests before the next slice.
Do not satisfy this milestone with a mock-only demonstration.

## M03: Native action execution

Execute declared argv with real output collection, cancellation, and honest capabilities.

Prerequisites: M02.

Read the matching cases in `acceptance/cases.json`.
Deliver a usable behavior slice with tests before the next slice.
Do not satisfy this milestone with a mock-only demonstration.

## M04: TypeScript and QuickJS-NG evaluation

Evaluate locked configuration without ambient effects and with enforced resource limits.

Prerequisites: M02.

Read the matching cases in `acceptance/cases.json`.
Deliver a usable behavior slice with tests before the next slice.
Do not satisfy this milestone with a mock-only demonstration.

## M05: Resolution, plans, and lockfiles

Resolve exact dependency closures and schedule validated action graphs.

Prerequisites: M03, M04.

Read the matching cases in `acceptance/cases.json`.
Deliver a usable behavior slice with tests before the next slice.
Do not satisfy this milestone with a mock-only demonstration.

## M06: Profiles and transient execution

Install transactionally, roll back generations, and run through jckgx without profile mutation.

Prerequisites: M05.

Read the matching cases in `acceptance/cases.json`.
Deliver a usable behavior slice with tests before the next slice.
Do not satisfy this milestone with a mock-only demonstration.

## M07: Repository trust and local channels

Implement explicit trust enrollment, signed metadata, and safe artifact retrieval.

Prerequisites: M05.

Read the matching cases in `acceptance/cases.json`.
Deliver a usable behavior slice with tests before the next slice.
Do not satisfy this milestone with a mock-only demonstration.

## M08: Strict Linux execution and verified transport

Demonstrate real isolation and authenticated artifact exchange from the Windows client.

Prerequisites: M03, M05.

Read the matching cases in `acceptance/cases.json`.
Deliver a usable behavior slice with tests before the next slice.
Do not satisfy this milestone with a mock-only demonstration.

## M09: Jackage self-hosting

Build Jackage through its own locked environment and compare independent stage outputs.

Prerequisites: M06, M07, M08.

Read the matching cases in `acceptance/cases.json`.
Deliver a usable behavior slice with tests before the next slice.
Do not satisfy this milestone with a mock-only demonstration.

## M10: Portable and OCI package backends

Build package artifacts through declared actions and validate their deterministic payloads.

Prerequisites: M09.

Read the matching cases in `acceptance/cases.json`.
Deliver a usable behavior slice with tests before the next slice.
Do not satisfy this milestone with a mock-only demonstration.

## M11: Native platform matrix and packages

Run native client evidence and package smoke tests across the supported target matrix.

Prerequisites: M10.

Read the matching cases in `acceptance/cases.json`.
Deliver a usable behavior slice with tests before the next slice.
Do not satisfy this milestone with a mock-only demonstration.

## M12: Workspace, cache, and reclaim lifecycle

Eliminate unmanaged replicas and unbounded caches through measured lifecycle policies.

Prerequisites: M06, M08.

Read the matching cases in `acceptance/cases.json`.
Deliver a usable behavior slice with tests before the next slice.
Do not satisfy this milestone with a mock-only demonstration.

## M13: External backend contracts

Deliver versioned independent plugins for execution, packaging, and repository transport.

Prerequisites: M07, M08, M10.

Read the matching cases in `acceptance/cases.json`.
Deliver a usable behavior slice with tests before the next slice.
Do not satisfy this milestone with a mock-only demonstration.

## M14: GitHub channels and authorized publication

Support Pages-only, Releases-only, and hybrid channels with local publication rehearsals.

Prerequisites: M07, M10.

Read the matching cases in `acceptance/cases.json`.
Deliver a usable behavior slice with tests before the next slice.
Do not satisfy this milestone with a mock-only demonstration.

## M15: Development and release images

Build Jackage environments and release images with validated closures and real runtime tests.

Prerequisites: M10, M12.

Read the matching cases in `acceptance/cases.json`.
Deliver a usable behavior slice with tests before the next slice.
Do not satisfy this milestone with a mock-only demonstration.

## M16: Agent-native factory and migration

Demonstrate the complete human and OMP workflow with safe source ownership.

Prerequisites: M11, M12, M13, M14, M15.

Read the matching cases in `acceptance/cases.json`.
Deliver a usable behavior slice with tests before the next slice.
Do not satisfy this milestone with a mock-only demonstration.

## M17: Release hardening and independent evidence

Replay the full support matrix, reproduction, recovery, fuzzing, and performance gates.

Prerequisites: M16.

Read the matching cases in `acceptance/cases.json`.
Deliver a usable behavior slice with tests before the next slice.
Do not satisfy this milestone with a mock-only demonstration.

## Parallel work

M03 and M04 can proceed independently after the store contracts stabilize.
M06, M07, and M08 have separate integration paths after M05.
M12, M13, and M14 can proceed when their prerequisites pass.
One integrator owns cross-cutting contract changes.

## Deferred runtime product

Custom Hyper-V, WHPX, WSLC, and Firecracker adapters remain valid extensions.
A final devcontainers frontend does not block the package and image core.
The later runtime decision must use measured startup, transfer, execution, and reclaim results.
No requirement for Jackage changes into a mandatory hypervisor rewrite.
