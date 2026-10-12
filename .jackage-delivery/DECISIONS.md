# Decision register

## Fixed decisions

| ID | Decision | Origin |
|---|---|---|
| D001 | Zig core with an exact master toolchain pin. | User. |
| D002 | QuickJS-NG and TypeScript declarations, not the Nix language. | User. |
| D003 | Jackage remains distinct from the future development-runtime product. | User. |
| D004 | `jckg` and `jckgx` share resolution, trust, and storage. | User. |
| D005 | GitHub Pages and Releases support custom channels. | User. |
| D006 | Execution, package, and repository backends remain independent. | User and converged design. |
| D007 | `C:\src\jackage` is the first workspace and Jackage is the first package. | User. |
| D008 | Preserve the supplied compiler pin until an authorized upgrade. | User environment. |

## Proposed decisions

| ID | Proposal | Required evaluation |
|---|---|---|
| P001 | SHA-256 with versioned domain-separated identities. | Golden vectors and source audit. |
| P002 | `jckg-json-v1` for canonical data. | Independent implementations and invalid-value tests. |
| P003 | `jackage.ts` and `jackage.lock.json` project files. | Existing interface audit. |
| P004 | Maintained TypeScript transformer with a pinned toolchain. | Existing dependencies, licensing, and bootstrap. |
| P005 | TUF-compatible metadata and explicit trust enrollment. | Pinned specification and conformance tests. |
| P006 | Process protocol for external backends. | Two built-in implementations per relevant contract boundary. |
| P007 | Per-user immutable store with profile generations. | Windows atomic activation and runtime references. |
| P008 | Strict Linux executor before custom hypervisor work. | Local and remote infrastructure audit. |
| P009 | Stable logical paths inside strict execution roots. | Cross-root reproduction and artifact portability. |
| P010 | Host source snapshots instead of an unmanaged second checkout. | Case-zero transfer, watcher, and conflict tests. |

## Open decisions

| ID | Question | Decision milestone |
|---|---|---|
| O001 | Which existing modules and dependencies already implement this design? | M00. |
| O002 | Which TypeScript transformer fits the existing build and supported platforms? | M04. |
| O003 | What minimum OS and SDK versions can the supported targets enforce? | M11. |
| O004 | Which atomic profile-selection strategy satisfies Windows handle semantics? | M06. |
| O005 | Which Linux isolation implementation supplies the strict reference executor? | M08. |
| O006 | How does Windows provide stable logical store paths for portable build caching? | M11. |
| O007 | Which disk-image fields can be reproducible at the byte level? | M15. |
| O008 | Does the future devcontainers frontend live inside `jckg` or beside it? | After core image delivery. |
| O009 | Which local VM adapter best satisfies measured runtime requirements? | After image delivery and runtime benchmarks. |

## Decision procedure

1. Record the problem in `templates/ADR.md` format.
2. Identify the affected user requirement and existing code.
3. Compare feasible alternatives with evidence.
4. Select a reversible default when the user left the choice open.
5. Add acceptance tests for the selected behavior.
6. Record compatibility and migration consequences.
7. Update the contract version when semantics change.

Do not use a decision record to remove user scope silently.
Do not select a new compiler version to avoid the current pin's APIs.
Do not claim a backend capability before its tests execute.
