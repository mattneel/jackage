# Agent delivery contract

## Mission

Build Jackage as a cross-platform package manager and reproducible software assembly system.
Use Zig for the core and QuickJS-NG for JavaScript evaluation.
Use TypeScript for authored configuration and control declarations.
Deliver both `jckg` and the transient runner `jckgx`.
Use Jackage itself as the first package, development environment, and release image.

## First actions

1. Read `PROJECT_CONTEXT.md`.
2. Read `state/SESSION_HANDOFF.md`.
3. Read the repository's effective agent instructions.
4. Record the current branch and worktree changes.
5. Inspect `build.zig`, `build.zig.zon`, `.zigversion`, and `scripts/zig.ps1`.
6. Inspect the existing `src`, `scripts`, and `tools` directories.
7. Compare the existing implementation with M00 acceptance cases.
8. Run the reviewed wrapper's version command.
9. Run the existing build and test steps after their purpose is clear.
10. Save the baseline in `state/audit.md` from `templates/AUDIT.md`.

## Work loop

1. Select the earliest ready milestone.
2. Select one acceptance case or a tightly coupled case group.
3. Write a product test for the missing behavior.
4. Run the test before its implementation.
5. Record the relevant assertion failure.
6. Implement the smallest complete behavior that satisfies the test.
7. Run the targeted test.
8. Run the affected regression tests.
9. Refactor after the tests pass.
10. Record evidence and update the handoff.
11. Continue with the next ready case.

A dependency or syntax failure is not a behavioral red test.
For preexisting behavior, use the documented characterization route.
A fake executor tests scheduling logic, not operating-system isolation.
A planned test, skipped test, or unavailable machine supplies no passing product evidence.

## Continuation

Continue beyond an architectural plan or a command parser.
Continue beyond self-hosting when later milestones are ready.
Use `ROADMAP.md` for the complete delivery scope.
Keep a durable handoff before context exhaustion.
At a real blocker, record the failed command and missing prerequisite.
Continue independent cases that do not require that prerequisite.

## Repository protection

Preserve unrelated user changes.
Use `scripts/zig.ps1` instead of a global Zig executable on Windows.
Preserve `0.18.0-dev.146+35accc06e` until the user authorizes a compiler upgrade.
Do not run `git reset --hard` or `git clean`.
Do not delete `.zig-cache`, `zig-out`, existing toolchains, or the user's WSL data.
Use disposable test directories for deletion and corruption tests.
Do not rename or replace working modules to match a preferred scaffold.
Do not add secrets or private source to evidence logs.

## Authority boundaries

Edit project files and run local development tests within this task.
Fetch declared public dependencies after the source and digest policy is clear.
Do not push commits, publish releases, or mutate remote repositories without explicit authorization.
Do not create billable resources without explicit authorization.
Do not change Hyper-V, firewall, antivirus, kernel, or machine security settings without explicit authorization.
Do not import host credentials into recipe evaluation or build actions.
Use local test keys for security tests.

## Engineering constraints

Implement product logic in Zig.
Reuse maintained dependencies through explicit pins where appropriate.
Do not handwrite cryptographic primitives or a partial TypeScript parser.
Do not execute package hooks outside declared action contracts.
Keep execution, package, and repository backends independent.
Reject unsupported isolation instead of silently weakening it.
Keep bootstrap success distinct from release hermeticity.
Keep artifact digests distinct from action identities.
Keep workspace caches outside source synchronization.

## Completion

Require real evidence for every required acceptance case.
Require native execution evidence for every claimed platform.
Require repeat builds without cached results for every reproducibility claim.
Require a real backend test for every claimed isolation capability.
Require storage reclamation measurements for reclaimed-space claims.
Use `RELEASE_GATES.md` before any complete-delivery claim.

## Final report

Report implemented behaviors and executable commands.
Report test results with paths to their evidence.
Report unsupported platforms and unresolved risks.
Report changes to proposed contracts through decision records.
Do not call the product complete while required cases remain blocked or unimplemented.
