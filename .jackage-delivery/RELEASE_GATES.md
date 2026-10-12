# Release gates

## Claims

A release declares its supported client targets, execution policies, package formats, and repository transports.
Each claim links to native or protocol-specific acceptance evidence.
A feature flag or successful compilation does not establish support.
The full delivery target is the scope in `PROJECT_CONTEXT.md` and the required case catalog.

## Mandatory gates

| Gate | Required evidence |
|---|---|
| Functional coverage | Every required case has product tests, a reviewed red-green or characterization sequence, and regression results. |
| Native platforms | Every claimed OS and architecture runs the client and its critical workflows. |
| Hermetic execution | Adversarial tests demonstrate the claimed filesystem and network restrictions. |
| Reproduction | Two fresh action executions produce equal declared unsigned artifacts without result-cache reuse. |
| Channels | Pages-only, Releases-only, and hybrid transports pass signed metadata and failure tests. |
| Profiles | Crash and concurrency tests preserve complete generations and live executable leases. |
| Storage | Collection protects source and active work, with measured physical reclaim for disk-backed claims. |
| Package formats | Native inspection and disposable installation tests validate claimed formats. |
| Images | Images boot or run through a real compatible runtime and contain their declared closure. |
| Plugins | Independent backend implementations pass the same versioned contracts. |
| Security | Abuse cases, parser fuzz regressions, and dependency review have no unresolved release-blocking findings. |
| Bootstrap | A clean machine can build or verify the initial client from declared bootstrap inputs. |
| Agent workflow | OMP can perform the case-zero workflow without secret leakage or policy bypass. |
| Documentation | Install, rollback, migration, diagnostics, and recovery instructions match executed commands. |

## Independent replay

The local evidence tool prevents several bookkeeping mistakes.
It does not prevent an agent from constructing a dishonest test or editing evidence files.
A release therefore requires clean-checkout CI replay and review outside the implementation work unit.
The CI report records source revision, dependency locks, platform, and complete commands.

Logs and timing data are not reproducible build artifacts.
The selected payload artifacts require byte comparison.
Signing, notarization, and externally generated attestations need separate artifact policies.
The release cannot hide a variable payload inside an excluded envelope.

## Required platform matrix

The full target includes Windows, Linux, and macOS on x86_64 and aarch64.
A narrower preview can ship only with an explicit support statement.
A preview does not satisfy the full delivery gate.
Hardware or SDK limitations remain visible in the case catalog and report.

The exact minimum OS versions and ABI policies require M00 and a platform decision record.
Do not invent a minimum version from the compiler target name.
Do not redistribute a platform SDK before its license permits the chosen channel.

## Performance report

The report separates input transfer, workspace preparation, execution, and output export.
It reports cold and warm behavior against an equivalent native-filesystem baseline.
It reports allocated bytes before and after the full cleanup lifecycle.
It contains measured values, machine details, and reproducible workload definitions.
An unrun benchmark remains pending, not estimated success.

## Release authorization

A local release rehearsal uses fixture repositories and test keys.
A public publication needs explicit user authorization and production trust material.
The agent must not create a public release merely because all tests pass.
A signed release requires controlled signing authority outside untrusted build actions.

## Completion report

The report includes exact executable commands and their tested platforms.
It includes acceptance coverage, known risks, and unsupported combinations.
It includes artifact digests, provenance, and reproduction comparisons.
It includes bootstrap and rollback paths.
It must not report full delivery while a required gate remains open.
