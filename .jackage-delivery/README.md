# Delivery pack index

## Status

Pack version: `1.0.0`.
The workspace snapshot comes from the user's October 11, 2026 terminal output.
Source verification for external references occurred during this session.
This pack contains original specifications, test designs, examples, and support scripts.
It does not contain third-party binaries or the user's repository implementation.

## Read order

1. Read `AGENT_PROMPT.md` and `PROJECT_CONTEXT.md`.
2. Read `ROADMAP.md` and `TDD_PLAYBOOK.md`.
3. Read `ARCHITECTURE.md` and the contracts for the active milestone.
4. Select acceptance cases from `acceptance/cases.json`.
5. Maintain `state/SESSION_HANDOFF.md` after each completed work unit.

## Specification map

| Document | Subject |
|---|---|
| `ARCHITECTURE.md` | Component boundaries, identity, and action lifecycle. |
| `CONTRACTS.md` | Plans, locks, digests, actions, events, and plugins. |
| `EVALUATOR.md` | TypeScript transformation and QuickJS-NG restrictions. |
| `REPOSITORIES_TRUST.md` | GitHub channels, TUF trust, publication, and offline policy. |
| `CLI_UX.md` | Apt-like commands, profiles, and `jckgx`. |
| `STORAGE_WORKSPACES.md` | Immutable storage, leases, caches, and reclaim evidence. |
| `PLATFORMS_PACKAGING.md` | Native platforms, cross-compilation, package formats, and images. |
| `SECURITY.md` | Threat model and abuse cases. |
| `CASE_ZERO.md` | Bootstrap and Jackage self-hosting. |
| `RELEASE_GATES.md` | Evidence required for release claims. |
| `OMP_PLAYBOOK.md` | Agent roles, context continuity, and worktree discipline. |
| `DECISIONS.md` | Decision register and change control. |
| `SOURCES.md` | Primary references and their scope. |

## Data and support files

`acceptance/cases.json` defines product behaviors, not test implementations.
`acceptance/milestones.json` defines the delivery dependency graph.
`fixtures/` contains independent test vectors and inert examples.
`schemas/` validates the proposed contract shapes.
`tools/delivery.py` validates the pack and records local command evidence.
`tests/test_kit_tools.py` tests those support tools only.

`templates/` contains audit, decision, and session templates.
`omp/` contains optional context templates.
`state/` contains mutable progress files and future evidence.
`MANIFEST.sha256` covers the original static payload.
Intentional specification edits require a new manifest before an integrity check.

## Authority

User requirements control product scope.
Existing repository facts control integration details until an explicit decision changes them.
This pack proposes initial contract versions.
An agent can improve a proposed contract through a recorded decision and new tests.
An agent cannot delete a requirement or relabel a missing capability as delivered.

## Exclusions

The archive contains no root `AGENTS.md`, `.omp` configuration, or replacement `build.zig`.
It contains no root `.gitignore`, `.zigversion`, or `build.zig.zon`.
It contains no production source, dependency downloads, credentials, or generated build caches.
The optional context script creates new OMP files only after an explicit invocation.
It refuses known existing context files instead of replacing or shadowing them.
