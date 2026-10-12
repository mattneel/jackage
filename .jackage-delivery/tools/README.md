# Optional delivery tools

## Scope

These tools support the implementation handoff.
They are not part of the shipped Jackage runtime.
They do not implement the product acceptance cases.
Python tools require Python 3.10 or later and no third-party modules.
PowerShell scripts declare compatibility with PowerShell 5.1 or later, but native Windows validation remains outstanding.

## Pack validation

```powershell
python .\.jackage-delivery\tools\delivery.py validate-kit
python .\.jackage-delivery\tools\delivery.py validate-kit --integrity
python -m unittest discover -s .\.jackage-delivery\tests -p "test_kit_*.py" -v
```

The first command validates catalog references and independent fixtures.
It parses schema files but does not implement a complete JSON Schema validator.
The preparation report records separate full schema validation.

The integrity command verifies the original static payload.
Intentional edits to specification files invalidate that original manifest.
Mutable `state/` files remain outside the static manifest.
Regenerate the manifest after a reviewed static-pack revision.
Do not regenerate it to conceal accidental corruption.

## Baseline inventory

1. Review `Inspect-JackageBaseline.ps1`.
2. Run its default inventory mode.
3. Review the existing repository wrapper and build files.
4. Run the version or baseline mode only after that review.

```powershell
.\.jackage-delivery\tools\Inspect-JackageBaseline.ps1
.\.jackage-delivery\tools\Inspect-JackageBaseline.ps1 -RunVersion
.\.jackage-delivery\tools\Inspect-JackageBaseline.ps1 -RunBaseline
```

Default mode reads source metadata and writes a managed report under `state/`.
Baseline mode invokes the existing build and test steps.
Those steps can create normal compiler outputs or retrieve dependencies through the existing build.
A missing test step remains an audit result, not permission to replace the build system.

## Evidence operations

```powershell
python .\.jackage-delivery\tools\delivery.py status
python .\.jackage-delivery\tools\delivery.py next
python .\.jackage-delivery\tools\delivery.py gate M00
```

An incomplete gate exits with status `2`.
The initial gate is intentionally incomplete.
`status` reports local evidence structure, not product certification.

The `run` operation executes a supplied command without an implicit shell.
Use `pwsh -NoProfile -File` explicitly when the supplied command is a PowerShell script.
Use an actual test-runner marker that proves the named assertion or test ran.
Do not substitute an unconditional print statement for product test execution.

The red and green records must use the same test identifier and command.
A subsequent regression record and a named review are also required.
The characterization route adds an earlier passing record before its deliberate fault.
The recorder rejects missing markers, infrastructure failures, and incorrect native platform labels.
A red observation still returns the test's nonzero exit code.

```text
python .jackage-delivery/tools/delivery.py run --help
python .jackage-delivery/tools/delivery.py review --help
```

A native Windows role cannot be recorded from Linux by changing its label.
Run target-specific commands on their actual target machine.
Move the resulting records and logs into the common evidence directory through the reviewed integration workflow.
Review evidence only after all required records are present.

The review command is:

```text
python .jackage-delivery/tools/delivery.py review --case CAN-001 --reviewer reviewer-name --note "Reviewed the real assertion and its production path."
```

The marker and review mechanisms do not establish security against a dishonest author.
Independent clean-checkout CI and code review remain release requirements.
