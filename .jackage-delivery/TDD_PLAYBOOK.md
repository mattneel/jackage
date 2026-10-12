# Test-driven delivery

## Test layers

| Layer | Purpose |
|---|---|
| Unit | Canonical values, parsing, graphs, state transitions, and policy matching. |
| Property | Identity invariants, round trips, malformed inputs, and state-machine sequences. |
| Contract | Backend interchangeability and protocol compatibility. |
| Integration | Real store transactions, processes, channels, and archive operations. |
| Native platform | Actual Windows, Linux, or macOS behavior. |
| Adversarial | Isolation escape attempts, malicious metadata, and path attacks. |
| Recovery | Crash, cancellation, disk-full, and interrupted transactions. |
| End-to-end | Build, package, install, run, rollback, and collect. |
| Reproduction | Independent builds without cached results. |
| Performance | Native-filesystem baseline and storage lifecycle costs. |

The pack tests validate support tools only.
They do not satisfy any product acceptance requirement.
JSON schemas and fixture vectors are test inputs, not implemented features.

## Red-green-refactor procedure

1. Select a case from `acceptance/cases.json`.
2. Add an executable product test for its expected behavior.
3. Run the test against the current implementation.
4. Confirm that the observed failure matches the missing behavior.
5. Save the red log with its command, source state, and assertion marker.
6. Implement the behavior without weakening the assertion.
7. Run the same test after implementation.
8. Save the green log and source state.
9. Run affected regression tests.
10. Refactor while the tests remain green.
11. Obtain a review of the behavior and evidence.
12. Mark the case complete only after the evidence gate passes.

An unresolved import, missing binary, network outage, or syntax error is infrastructure failure.
Such a failure does not count as the red assertion.
A test command that exits successfully without executing a test does not count as green evidence.

## Existing behavior procedure

1. Identify the existing production path for the case.
2. Add a characterization test against that path.
3. Record a passing result.
4. Apply a reversible fault only within agent-owned test or implementation changes.
5. Run the characterization test against the fault.
6. Record its relevant assertion failure.
7. Revert only the deliberate fault.
8. Run the test again.
9. Record the final passing result.

Do not introduce a fault into unrelated user changes.
A negative control can substitute for the fault when it exercises the same assertion path.
The evidence record must describe that substitution.

## Test implementation rules

Use Zig tests for core product behavior.
Use the pinned compiler's local standard library as the API reference.
Do not paste obsolete Zig APIs from memory and then upgrade the compiler to accommodate them.
Use native integration helpers where operating-system behavior requires them.
Keep helper dependencies pinned and outside the shipped runtime unless needed by the product.

Use injected clocks and randomness for pure logic tests.
Use real clocks and processes for capability tests where enforcement matters.
Mocks can cover scheduling but cannot establish sandbox isolation.
Live network tests require opt-in and separate credentials.
Local signed repository fixtures cover routine channel tests.

## Evidence tooling

The optional recorder executes the supplied command and captures its exit code and output.
It records a digest of the log and a Git source-state observation.
It does not certify that the test is honest or sufficient.
A reviewer must inspect the test, assertion, and implementation.
An independent CI replay remains required for a release.

Example commands below use placeholders that the audit must replace with actual test commands:

```text
python .jackage-delivery/tools/delivery.py run --case CAN-001 --stage red --test-id canonical-order --marker EXPECT_ORDER -- <actual failing test command>
python .jackage-delivery/tools/delivery.py run --case CAN-001 --stage green --test-id canonical-order --marker TEST_EXECUTED -- <actual passing test command>
python .jackage-delivery/tools/delivery.py gate M02
```

The recorder returns the subprocess status.
A successful red observation therefore still returns a nonzero command status.
The saved record states whether the result met that stage's evidence conditions.
The `review` command records a named review after the red and green evidence exists.
Review metadata is self-reported local evidence, not a cryptographic attestation.

## Platform evidence

Every case lists its required platform roles.
`host` means the actual initial development host recorded during M00.
`portable` means an implementation-level case without an OS-specific guarantee.
Explicit targets require native evidence or a documented declared execution environment.
A platform run cannot satisfy another target merely because the source cross-compiles.

The local gate checks evidence structure and coverage only.
`RELEASE_GATES.md` also requires an independent platform matrix and clean-checkout replay.
No local completion flag can replace those release checks.

## Fuzzing

Fuzz parsers, canonical values, archive names, channel metadata, and plugin frames.
Use bounded inputs and deterministic seeds in regression tests.
Persist minimized crash cases as fixtures.
Run memory safety instrumentation where the platform and dependencies support it.
A fuzz timeout does not justify accepting malformed input.

## Stop conditions

Stop a task before unauthorized remote changes, privilege changes, or source deletion.
Record a blocker when required hardware, SDK access, or credentials are unavailable.
Continue independent ready tasks.
Do not mark a blocked case as skipped success.
Do not change acceptance thresholds solely to make a failing run pass.

## Source observation limit

The pack recorder hashes Git status and the tracked diff.
It does not capture untracked file contents or create a complete source snapshot.
A Jackage source snapshot and independent CI replay supply stronger release provenance later.
The local recorder must not be presented as a trusted attestation service.
