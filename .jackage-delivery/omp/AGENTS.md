# Jackage project context

Read `JACKAGE_START_HERE.md` and `.jackage-delivery/AGENT_PROMPT.md`.
Read `.jackage-delivery/state/SESSION_HANDOFF.md` before each work unit.
Use `.jackage-delivery/ROADMAP.md` for full delivery scope.
Use `.jackage-delivery/acceptance/cases.json` for acceptance requirements.

Preserve the existing repository implementation and user changes.
Use `scripts/zig.ps1` for Windows compiler commands.
Preserve the exact compiler pin unless the user authorizes an upgrade.
Use red-green-refactor tests and executed evidence.
Keep source, immutable artifacts, and disposable caches separate.
Keep execution, package, and repository backends independent.
Do not claim hermeticity from a VM label or a fake executor.
Do not publish, push, or change machine security without authorization.
Maintain the durable handoff before context exhaustion.
