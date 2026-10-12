# Oh-My-Pi work protocol

## Context integration

OMP supports native project context under `.omp` and standalone `AGENTS.md` conventions [S09].
Nearest native directories and discovery precedence can affect which rules load.
The pack therefore does not overwrite or create active context during extraction.
The optional installer refuses an existing `.omp` directory or known project context files.

The installed context remains short.
It directs the agent to the active milestone and durable handoff.
It does not inject every specification into every request.
No special undocumented slash command or provider configuration is required.

## Roles

| Role | Responsibility |
|---|---|
| Integrator | Owns contracts, milestone selection, and cross-module integration. |
| Implementer | Owns one bounded behavior and its red-green tests. |
| Adversarial reviewer | Tests policy boundaries, failure paths, and false-success claims. |
| Platform verifier | Runs native evidence on the required OS and architecture. |

Start with one implementer until the core contracts stabilize.
Parallel work must use distinct worktrees or nonoverlapping owned files.
Two agents must not edit one checkout concurrently without an explicit integration protocol.
Shared immutable artifacts are acceptable.
Shared mutable build directories are not.

## Work unit procedure

1. Read the current handoff and effective repository instructions.
2. Inspect the current Git status before edits.
3. Claim a case group and record owned files.
4. Read the relevant contract and test vectors.
5. Follow the red-green-refactor procedure.
6. Review the resulting diff for unrelated changes.
7. Record tests, unresolved risks, and remaining cases.
8. Hand integration back to the integrator.

## Durable handoff

The handoff records the actual repository state, not a reconstructed success story.
It includes the current milestone and next failing test.
It identifies commands that ran and commands that did not run.
It names any capability or credential blocker.
It includes changed contracts and decision records.

At context exhaustion, leave a resumable work unit.
Do not abandon a failing test without its command and failure explanation.
Do not reset the worktree to create an apparently clean handoff.
No background or asynchronous delivery is assumed.

## Tool discipline

Use the project's Zig wrapper for Windows builds.
Consult the pinned toolchain's local API definitions before unfamiliar Zig code.
Use independent platform jobs for native target validation.
Keep browser research focused on actual dependencies and authoritative APIs.
Do not use generated documentation as proof that a function exists.

## Completion discipline

An agent cannot mark a case complete because it generated a test file.
A reviewer must inspect the assertion and the production path it exercises.
A fake worker proves the core protocol path, not real isolation.
The final independent CI replay remains mandatory.
