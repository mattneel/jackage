# Jackage: start here

## Purpose

This pack directs test-driven delivery of Jackage in this existing repository.
It is an implementation specification and agent handoff, not an implemented package manager.
The pack does not replace the current source, build files, toolchain pin, or bootstrap scripts.

The supplied repository facts identify `C:\src\jackage` as the primary checkout.
The compiler is `0.18.0-dev.146+35accc06e`, through `scripts/zig.ps1`.
The existing implementation was not available to the author of this pack.
The first milestone audits that implementation before edits.

## Start the agent

1. Extract this archive into `C:\src\jackage` without an enclosing directory.
2. Open Oh-My-Pi in that repository.
3. Give the agent the prompt below.

```text
Read JACKAGE_START_HERE.md and .jackage-delivery/AGENT_PROMPT.md.
Implement the Jackage vision through the ordered TDD milestones in this pack.
Start with M00: audit the existing repository and preserve the current Zig pin.
Use scripts/zig.ps1 for compiler commands.
Do not replace working source or build files with a scaffold.
Continue through ready milestones with red-green-refactor evidence.
Treat missing platform access as blocked evidence, not a passing test.
Keep .jackage-delivery/state/SESSION_HANDOFF.md current between sessions.
Do not stop at a plan, a mocked CLI, or the bootstrap milestone.
```

## Optional persistent context

The supplied OMP files are templates until installed.
The installation script refuses existing project context paths to prevent context shadowing.
No model, provider, or account configuration changes occur.

1. Review `.jackage-delivery/tools/Install-OmpContext.ps1`.
2. If `.omp` does not exist, run the installation script.
3. If `.omp` exists, merge the template rules into its effective context file manually.
4. Restart the OMP session after a context change.

```powershell
.\.jackage-delivery\tools\Install-OmpContext.ps1
```

## Entry points

| File | Purpose |
|---|---|
| `.jackage-delivery/AGENT_PROMPT.md` | Execution instructions and authority boundaries. |
| `.jackage-delivery/PROJECT_CONTEXT.md` | User requirements, known facts, and open decisions. |
| `.jackage-delivery/ROADMAP.md` | Delivery milestones and dependencies. |
| `.jackage-delivery/acceptance/cases.json` | Machine-readable acceptance requirements. |
| `.jackage-delivery/TDD_PLAYBOOK.md` | Red-green-refactor and evidence rules. |
| `.jackage-delivery/ARCHITECTURE.md` | Core boundaries and backend contracts. |
| `.jackage-delivery/state/SESSION_HANDOFF.md` | Durable continuation point. |

## Optional pack tools

Python 3.10 or later runs the pack tools without third-party modules.
Python is not a Jackage runtime dependency.
The agent can start without these tools and implement equivalent checks in Zig.

```powershell
python .\.jackage-delivery\tools\delivery.py validate-kit
python .\.jackage-delivery\tools\delivery.py status
python -m unittest discover -s .\.jackage-delivery\tests -p "test_kit_*.py" -v
```

These commands test the handoff pack, not Jackage.
The initial product gate deliberately remains incomplete.
Every acceptance case begins with no product evidence.

## Product boundary

Jackage assembles packages, development environments, and release images.
It has independent execution, package, and repository backend families.
A future devcontainers-style frontend can consume those contracts.
A custom hypervisor is not a prerequisite for Jackage.

Source belongs to the user.
Caches belong to a bounded storage policy.
A release claim belongs to executed evidence.
