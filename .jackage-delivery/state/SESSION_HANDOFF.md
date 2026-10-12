# Jackage delivery handoff

Last updated: after M02 closed; M03 (execution) and M04 (evaluation) run as parallel work units; M05 (resolution/plans/locks) implemented, evidence pending.

## Current state

| Item | Value |
|---|---|
| Repository | `C:\src\jackage`, branch `master`, base commit `9daddcd` (work is uncommitted by design) |
| Host | Windows 11 Pro 10.0.26200, x86_64, 32 logical CPUs, 64 GiB RAM |
| Compiler (Windows) | `0.18.0-dev.146+35accc06e` via `scripts/zig.ps1` |
| Declared Linux environment | WSL2 `Ubuntu 24.04.5 LTS`, kernel `7.2.6-locietta-WSL2-xanmod1`, x86_64, 32 CPUs, 433 GB free (ADR-0001) |
| Compiler (guest) | same pin via `scripts/fetch-zig-linux.sh` into `$HOME/jckg/toolchain` |
| Dev sync | Mutagen 0.18.1 session `jckg-dev`, `one-way-safe`, `C:\src\jackage` -> `~/jckg/dev` (ADR-0002) |
| Completed cases | 36 / 188 (M00 8/8, M01 10/10, M02 18/18) |
| Local gate | `python .jackage-delivery/tools/delivery.py gate M02` -> complete for M00..M02 |

## Test entry points

```powershell
.\scripts\zig.ps1 version                        # pinned compiler
.\scripts\zig.ps1 build test -Dfilter=<text>     # build-system steps only
.\scripts\test.ps1 [-Filter <text>]              # full loop with visible per-test output
.\scripts\fetch-zig-linux.sh                     # guest only: install the pinned Linux toolchain
.\scripts\test.sh [filter]                       # guest only: full loop on ext4
```

`scripts/test.ps1` runs the build-system test steps, installs the client, then executes
`zig-out/bin/jckg-tests.exe` so each case's evidence marker is visible in the log.

## Declared execution environments (ADR-0001, ADR-0002)

- `host` / `windows-*` evidence: the Windows host above.
- `linux-x86_64` evidence: the declared WSL2 environment; the recorder must run *inside* the guest so its
  observed platform is genuinely `linux-x86_64`. Compilation happens on ext4; a Windows bind mount is never
  the compilation path.
- Source reaches the guest as a derived mirror through Mutagen (`one-way-safe`); guest edits are surfaced as
  conflicts, never applied to the Windows source.
- Recorded limits: WSL2 is **one** Linux environment, not the independent native host the release matrix
  requires - a clean-checkout Linux replay is still required before any Linux support claim. macOS and
  aarch64 stay unavailable. The custom XanMod kernel and all host security settings are untouched.

## Work units and evidence protocol

Per case, through `.jackage-delivery/tools/delivery.py`:

1. `characterize` - the case test passes against the current implementation.
2. `fault` - one deliberate, reversible inversion in agent-owned implementation code makes that case's own
   assertion fail (real exit code, marker present in the log). All faults for a milestone go in at once and
   are then reverted.
3. `green` - the same command and test id pass again.
4. `regression` - the full suite passes.
5. `review` - a named review recording what was inspected.

Rules learned here: a panic aborts the whole test binary and destroys other cases' markers, so case tests
must be panic-free (check optionals before unwrapping); a compile error or a missing binary is never fault
evidence; filters are baked into the test artifact at build time (`-Dfilter`), because the test runner
binary itself has no runtime filter flag.

## Milestone status

| Milestone | Cases | State |
|---|---|---|
| M00 audit | AUD-001..008 | complete, gate green |
| M01 CLI | CLI-001..010 | complete, gate green |
| M02 identities and store | CAN-001..010, CAS-001..008 | complete, gate green |
| M03 native execution | EXE-001..010 | implementation in flight (parallel work unit) |
| M04 TS/QuickJS evaluation | EVAL-001..011 | implementation in flight (parallel work unit) |
| M05 plans and lockfiles | PLAN-001..011 | implemented (`src/plan/**`), characterize+fault+green recorded, regression in flight |
| M06 profiles and `jckgx` | PROFILE-001..010 | Windows: all ten cases pass; Linux path in progress (parallel work unit) |
| M07 repository trust | TRUST-001..008 | implemented (`src/trust/keys.zig`, `root.zig`, `metadata.zig`), characterize+fault+green recorded, regression in flight |
| M07 repository trust | TRUST-009..012 | delegated to the transport work unit (`src/trust/download.zig`, `archive.zig`) |
| M08..M17 | as per roadmap | not started; M08 plan recorded below and unblocked by ADR-0001 |

M07 trust design as implemented:

- `keys.zig` - Ed25519 from the pinned std, key ids as `sha256("jckg:key:v1\0" || algorithm || key)` fingerprints, role-scoped
  authorization, and threshold verification that counts **distinct authorized keys only** (a repeated signer never meets a
  threshold of two; an unknown key or wrong role is refused outright).
- `root.zig` - root metadata whose fingerprint is the digest of its canonical document, explicit enrollment against an
  independently approved fingerprint (a channel's own claim is never authority), rotation requiring the old root *and* the
  new root at their thresholds with a strictly increasing version, and timestamp validation that refuses malformed values
  instead of comparing them.
- `metadata.zig` - the timestamp -> snapshot -> targets chain: per-role thresholds over canonical bytes, per-document expiry,
  strict version monotonicity against trusted state, and cross-pinning (the timestamp pins the snapshot version *and* digest,
  the snapshot pins the targets version *and* digest). Trusted state advances only after every check passes, so an
  interrupted or mixed transaction cannot downgrade a role. Offline use is a separate policy: already installed artifacts
  stay usable, new metadata never is.

## M08 groundwork landed (portable half)

Two worker modules exist and pass, ready for the guest-side worker and the controller:

| Module | Purpose |
|---|---|
| `src/worker/frames.zig` | One UTF-8 JSON document per line, 1 MiB cap before parsing; requests carry a unique id, responses exactly one result or one error, events a monotonic sequence per action; a session tracker refuses duplicate ids, unknown ids and reordered streams. Decoding owns its strings (`Frame.deinit`). |
| `src/worker/auth.zig` | Per-session tokens and challenge/response over a local test key with `std.crypto.auth.hmac.sha2.HmacSha256` and a constant-time compare; the MAC covers session, worker, expiry and nonce, so an edited token is refused rather than re-scoped (a re-scoped token fails the MAC check, a genuine foreign-session token fails the binding check); artifact requests are checked against a per-session scope, so session A's token cannot reach session B's artifacts. Case test: `m08/STRICT-006`. |
| `src/worker/sandbox.zig` | The sandbox launch plan as data: absolute, traversal-free host paths; writable mounts only when explicitly declared; duplicate bind targets refused; fixed logical paths (`/jckg/workspace`, `/jckg/store`) so artifacts never embed a host path; a non-zero policy for every limit. The `unshare` preamble creates user/mount/pid/net namespaces and hands control to the worker, which performs the mounts itself and then `execve`s the action argv - no shell, so argument boundaries survive by construction. |
| `src/worker/controller.zig` | Controller state machine over readers/writers: handshake (protocol major check, session identity must match the authenticated token), request/response with unique ids and exactly one response, event ordering, and capability claims that start unconfirmed. `applyProbes` confirms a claim only when an independent violation attempt *failed* to break it, and removes the claim entirely when the probe succeeded - a worker's self-description is never trust. Tests drive the real state machine with in-memory streams. |

Note on evidence: the `STRICT-*` cases are `linux-x86_64`, so their evidence must be recorded **inside the declared guest environment** (`scripts/wsl-evidence.ps1`) once the Linux worker exists; the unit tests above are implementation-level and run everywhere.

Remaining M08 work: the Linux worker binary and its namespace isolation (`unshare --user --map-root-user --mount --net --pid`), the controller probe that rejects a worker claiming isolation it does not enforce (STRICT-010), stable logical paths inside the namespace (STRICT-004), and the cross-Windows-to-Linux transport with verified return artifacts (STRICT-007/008/009). Evidence for `STRICT-*` must be recorded **in the guest** via `scripts/wsl-evidence.ps1`.

## Fault-window and regression-slot rules (as operated)

- A fault window is announced before opening and closed immediately after the revert; while any window is open, nobody runs an **unfiltered** suite. Filtered runs may overlap, subject to two declared dependencies: M03's executor is executed by M06's PROFILE tests (alternate), and my `plan/cache.zig` is exercised by M07Transport's TRUST-012 (one at a time).
- Regression records are granted one unit at a time when all windows are closed and the tree compiles; a regression must be the last record for its case.
- Current queue after the last broadcast: M06's ten regressions, then M04's eleven, then M07Transport's four.
- `scripts/test.ps1` retries the client-install step when it collides with a concurrent run (transient `AccessDenied`), and installs test artifacts under a per-filter prefix so filtered builds cannot overwrite each other.

## Evidence queue (integration ownership)

**All four streams closed** with complete bundles, and every gate from M00 to M07 exits 0
with `localGateComplete: true`:

| Milestone | Cases | Own complete |
|---|---|---|
| M00 audit, M01 CLI, M02 identities/store, M05 plans | 8 + 10 + 18 + 11 | ✅ |
| M03 execution | 10/10 | ✅ (fault audit: every case failed its own assertion; EXE-007 `expected .gone, found .live` inside the descendant loop) |
| M04 evaluation | 11/11 | ✅ (gate exits 0; real vendored QuickJS-NG, esbuild, TypeScript, Node with digests) |
| M06 profiles | 10/10 | ✅ (including the exact Windows exit 1234567 in the reviews) |
| M07 trust core | 12/12 | ✅ |

Total: **90 of 188 cases**, 8 of 18 milestones gate-green. M08 is the only milestone with
work in flight, and everything from M09 onward depends on it.

Unfiltered runs and fault windows are mutually exclusive; one unit holds each at a time.
This session's record of *why* that rule exists is worth keeping: four batches were
rejected because another unit's in-flight edit or applied fault was in the tree when a
record was taken. Rejected records cost a re-run; a record that measured a faulted tree
while claiming a clean one costs the whole evidence chain.

Current state at handoff time:

| Unit | Bundle state |
|---|---|
| M03 execution | adapter green; characterize/regression bundle queued behind M06 |
| M04 evaluation | eleven characterize records accepted; window queued |
| M06 profiles | ten fault + ten green accepted; ten regressions queued (first in line) |
| M07 trust core | eight cases recorded with reviews; four fault + four green accepted; four regressions in the current slot |

Rule for whoever integrates next: announce green *before* granting a slot, never edit
shared source while a batch is running, and treat a rejected record as a non-event -
re-record it rather than loosening the assertion.

**Filtered runs are not a build gate.** Zig analyses test bodies lazily, so
`scripts/test.ps1 -Filter <case>` executes one body and never type-checks the rest of the
module. Four compile errors and one allocation leak sat in `src/worker/controller.zig`
while filtered runs reported green twice. The unfiltered run - which is what the pack's
`regression` stage records - is the only compile gate; filtered evidence may iterate, but
it never authorizes a slot.


## M08 case mapping (verified against `acceptance/cases.json`)
The case titles are terse and the first pass of the guest tests mapped two of them wrong, so
the mapping is written down here with its evidence:

| Case | Actual requirement | Evidence path |
|---|---|---|
| STRICT-001 | **Reads** outside declared roots fail (linux-x86_64) | `probe.zig` checks `undeclared-read-denied`, `undeclared-write-denied`, `host-path-hidden`, driven by `strict_tests.zig` |
| STRICT-002 | Deny network | `network-isolated` (only `lo` visible) |
| STRICT-003 | Isolate writable state | `workspace-writable` plus `store-read-only` |
| STRICT-004 | Stable logical paths | `logical-paths` run twice against different host workspaces |
| STRICT-005 | Enforce resources | `resource-limit-enforced` (fork until the declared limit refuses) plus `pid-isolated` |
| STRICT-006 | Authenticate workers | `worker/auth.zig` unit test, case-tagged |
| STRICT-007 | Verify returned artifacts (portable) | the worker reports declared-output digests; the client must reject corrupt or undeclared results **before** store/cache commitment - the rejection half is the transport/download path |
| STRICT-008 | Transport interruption (portable) | reconnect reconciles the action and verifies resumed data instead of guessing success |
| STRICT-009 | Cross Windows to Linux (host) | a Windows client requests a Linux action through the declared environment; inputs materialize on Linux-native storage and validated results return |
| STRICT-010 | Reject fake capabilities | `controller.applyProbes` - a claim the probe disproves is removed, and `usableCapabilities` never returns an unconfirmed claim |

STRICT-007 and STRICT-008 are shared with the transport/download work; STRICT-009 is the
declared-environment crossing and belongs to this unit.

## Guest portability ports (integrator-owned, in progress)

### `jckgx`: deferred to M09 deliberately

The mission requires both `jckg` and the transient runner `jckgx`. The *library* half
exists and is evidenced (PROFILE): `runner.parse`, `prepareTransient`, `prepareCommand`,
`Execution.run`, and `RunResult.callerStatus()` as the single CLI exit mapping. What does
not exist is the binary, and for a reason worth recording rather than working around:
`profile.Manager.init` takes a *root directory*, and nothing in the CLI defines where that
root lives yet - `jckg init` writes only the project declaration in the current directory,
and the install/profile commands that would establish the root are M09's self-hosting
surface.

Adding `jckgx` now would mean inventing that convention ahead of the milestone that
defines it, so it is scheduled with M09. The exit-status rule it must honor is already
written down: native status unchanged (Windows DWORD, POSIX byte or 128+signal), and on
Windows it cannot narrow through `std.process.exit(u8)`.

### What running the sandbox actually taught (M08)

Every one of these was found by executing the thing, not by reading it:

1. **A worker that does not flush its frames is a worker that says nothing.** The
   controller waits for the handshake before sending anything else, so a buffered write
   deadlocks the protocol. `writeFrame` now flushes.
2. **Never verify token expiry against the caller's timestamp.** The worker takes its own
   clock; a peer that supplies "now" makes expiry decorative.
3. **The logical root must be read-only *before* anything is bound into it.** Otherwise
   the empty tmpfs accepts writes to undeclared paths and STRICT-001 passes while being
   false.
4. **A bind target must match its source's kind.** Binding a file onto a directory fails
   with ENOTDIR; the target is now created as a file or a directory depending on the
   source. Parents only - creating the final component as a directory is what broke it.
5. **The harness must close the worker's stdin after the last request.** The worker serves
   until its input ends; leaving the pipe open makes the test wait for a process that is
   waiting for the test.
6. **Each mount names its own failure.** `MountFailed` for six different mounts told me
   nothing; `BindMountFailed` versus `StoreRemountFailed` located the bug immediately.
7. **Guest builds share one cache directory with concurrent guest runs.** A second
   `zig build` waits on the first one's lock, which looks exactly like a hang.

Also: the worker's argv is exactly its preamble plus one flag. A stray argument is refused,
because a worker that accepts extra arguments is one a caller can smuggle behaviour past
the declared plan with.

### Sandbox shape (as implemented)

`execute.zig` builds the action's view in this order, and the order matters:

1. a fresh tmpfs at the logical root `/jckg` (read-only for the action),
2. the target directories, created inside that tmpfs,
3. `/usr`, `/bin`, `/lib`, `/lib64`, `/etc/ld.so.cache` bound **read-only inside the
   logical tree**, so a tool can run without the host being reachable - without this step
   the sandbox leaves the entire host filesystem visible and "reads outside declared
   roots fail" is simply false,
4. the logical root remounted read-only, so only declared mounts are writable,
5. the workspace bound writable, the store bound then remounted read-only,
6. a **fresh tmpfs over `/tmp`**, so the host's temporary files are unreachable,
7. extra binds, with the target created as a file or a directory to match its source.

Limits are applied before the action starts, the action's environment is exactly what the
plan declares, and each mount names its own failure.

## Blocked: M08 guest verification (environment)
The sandbox work is written, wired into its own build steps, and compiles clean
(`zig build worker probe` exits 0). What cannot proceed tonight is *running* it in the
declared guest:

- A fresh strict-cache build did not finish in 10 minutes, and the script redirects build
  output, so the run produced a zero-byte log. Earlier, the same build completed in about
  five seconds.
- Load is modest (1.3-1.9) but other workloads (`omp` from other agents, unrelated
  processes) hold CPU, and two runs produced literally no output before their timeouts.
- Killed runs leave `strict-tests` and `jckg-worker` behind; both must be cleared before
  retrying, or the next attempt looks like a build hang.

Unblock criteria: a guest window with no competing load, then
`sh scripts/strict-test.sh STRICT-001` (which now runs the test binary directly so
harness prints stream as they happen, and enforces a 45-second deadline around the whole
worker exchange).

### Known open item

The run path is exercised end to end in the guest, and this is exactly where it stands:

| Step | State |
|---|---|
| namespaces (`unshare --user --map-root-user --mount --pid --fork --mount-proc --net`) | ✅ |
| tmpfs root at `/jckg`, tmpfs workspace/store/`/tmp`, procfs inside the tree | ✅ |
| declared inputs copied into the tree (`/jckg/jckg/tools/probe`) | ✅ |
| store remounted read-only, root remounted read-only | ✅ |
| `chroot("/jckg")` + `chdir("/jckg/workspace")` | ✅ |
| action program reachable after the chroot (`accessAbsolute` succeeds) | ✅ |
| starting the action | ❌ hangs, then crashes when killed |

Tried and ruled out, so nobody repeats them:

- `std.process.spawn` with `explicit { dir, path }` → `FileNotFound`.
- `std.process.spawn` with `path` (argv[0]-as-path) → `FileNotFound` (the variant is
  relative-only, so an absolute argv[0] is invalid there).
- A fresh procfs inside the chroot as an explanation for a `fexecve` failure → the failure
  survived it.
- `fork` + `execve` with explicit pipes and the child's errno as its exit status → still
  hangs in the guest, which points at the pipe lifecycle around the fork rather than at
  the exec itself.
- Closing every inherited descriptor above 2 in the child (the stray-write-end theory) →
  the hang survives it, so the open write end is not in the child.

Operational notes for anyone driving the guest suite:

- `zig build strict-test` **runs** the suite, and the build runner buffers test output, so
  a hanging test produces a log of literally zero bytes. Run the built binary directly
  (`find .zig-cache-strict -name strict-tests`) to watch the harness prints live.
- The guest shell is zsh: a glob that matches nothing is a hard error, so
  `ls .zig-cache-strict/o/*/strict-tests` aborts the whole command. Use `find`.
- `pkill -f strict-tests; pkill -f jckg-worker` before retrying: a killed run leaves both
  processes behind, and the next attempt then looks like a build hang.

Next instrumentation, in order: (1) have the parent close the read end it is not using
*before* reading the other, and read stdout and stderr concurrently rather than
sequentially - a child that fills the stderr pipe while the parent is still draining
stdout blocks forever, which is the classic deadlock this shape produces and the one
explanation left that fits "hangs with no output at all"; (2) log the pipe descriptor
numbers and the fork result to the worker's stderr, which the harness already captures.

Design constraints already established (do not re-derive): host bind mounts are refused in
this user namespace, so inputs are copied; `/tmp` must be mounted after every mount whose
source lives under the host's `/tmp`; a mount cannot be created inside a read-only
filesystem, so any read-only remount comes last; and the action's cwd inside the chroot is
`/jckg/workspace`, which is why the physical tree repeats the `/jckg` prefix.

### Environment finding that changes the sandbox design

Measured in the declared guest, not assumed:

| Operation | Result |
|---|---|
| `mount -t tmpfs` inside `unshare --user --map-root-user --mount` | ✅ works |
| `mount --bind <host dir> <tmpfs path>` | ❌ EINVAL (`mount --bind /usr /jckg/usr` fails) |
| `mount --bind <host file> <tmpfs file>` | ❌ reports success, target stays a 0-byte file - i.e. the bind does not attach |
| `chroot` as namespace root | available (the namespace is root inside itself) |

Consequences, all of which the current code reflects or must reflect:

1. **Runtime roots cannot be host binds.** `default_runtime_roots` is empty, and a plan
   that needs dynamic libraries needs a *prepared rootfs image* (M15), not host binds.
   A statically linked action needs nothing from the host.
2. **The logical root is built from tmpfs mounts, not binds.** Planned shape: tmpfs at
   `/jckg`; a tmpfs at `/jckg/workspace` (writable) and one at `/jckg/store` (remounted
   read-only - remounting a tmpfs works, mounting onto a read-only filesystem does not,
   and remounting the parent read-only does not affect these child mounts); declared
   inputs **copied** in rather than bound; then the root remounted read-only.
3. **Hiding the host needs `chroot`.** A fresh tmpfs root does not hide `/etc`, `/home`,
   or anything else, so STRICT-001's read half stays false until the action is chrooted
   into the logical root. Inside that chroot the workspace must still appear at
   `/jckg/workspace`, which means the physical layout carries the prefix twice
   (`/jckg/jckg/workspace`).
4. Ordering rules learned the hard way: binds *before* anything is remounted read-only
   (a mount cannot be created inside a read-only filesystem), and the fresh `/tmp`
   *after* every mount whose source lives under the host's `/tmp`, or those sources
   become unreachable.

### Exit-status propagation (constraint for `jckgx`)

`RunResult.callerStatus()` (`src/profile/runner.zig`) returns `u32` on purpose: Windows
exit codes are 32-bit and PROFILE-009 exercises a value above 255 unchanged. Two
consequences for the transient runner, which must be honored when it is built:

- Windows: exit through the native status API; `std.process.exit` takes a `u8` and would
  truncate (a truncated status still *looks* like a status, so this passes casual testing).
- POSIX: the native convention is one byte, or `128 + signal` for a signal death.

### Worker protocol (M08 portable half complete)

`src/worker/main.zig` implements the guest side of the protocol and is green under
`-Filter m08`: the session secret arrives on the first line of stdin (never argv or
`/proc`), the handshake reports *claimed* capabilities, an `auth` request is verified
against the worker's **own** clock (a caller-supplied time would make expiry decorative),
every other method is refused until that succeeds, and `run` requests stream output as
events and answer exactly once.

Wire-form details that cost debugging time and should not be re-guessed:

- failures are nested: `{"error":{"code":…,"message":…}}`, not flat `error_code` fields;
- event payloads are JSON, so a string payload is `"\"text\""`.

### Pending wiring for the Linux runner (`src/worker/execute.zig`)

The runner is written but deliberately **not yet referenced anywhere**, so it cannot
affect the build while other units are mid-batch. Two steps remain, to be done with the
tree quiet, each verified immediately:

1. `sandbox.zig` needs `pub const logical_root = "/jckg";` - `execute.zig` has a
   `comptime` check that the logical layout matches the plan module, and the root
   constant does not exist yet, so the file will not compile until it does.
2. Register `execute.zig` in `src/jckg.zig`'s test block, then run
   `scripts/test.ps1 -Filter m08` and the guest suite before recording `STRICT-*`
   evidence in the guest.

The runner mounts a fresh tmpfs at `/jckg`, binds the workspace writable and the store
read-only (bind, then read-only remount - a single bind call ignores the flag), applies
the plan's process limit before forking, and `execve`s the action argv with the declared
environment and no shell. A mount that cannot be made is a refusal: an action must never
run against a store that silently stayed writable.



M06's guest run proved the Linux suite is nearly green: their ten PROFILE cases pass, and the remaining failures
are Windows facts asserted inside tests that also run in the guest - all in audit/core files this work unit owns:

| Site | Wrong assertion | Port |
|---|---|---|
| `src/audit/host.zig` (AUD-006) | detected OS/arch and the native support-matrix entry hardcoded to Windows | assert the detected platform equals the platform the binary was built for, keep concrete Windows values under `builtin.os.tag == .windows`, and make the "unavailable" branch exclude the *computed* native target |
| `src/audit/mod.zig` (report test) | host facts and the JSON `os` field compared to "windows" | compare against the builtin-derived platform |
| `src/audit/provenance.zig` (AUD-007) | requires `tools/zig/LICENSE` to be present | conditional on the Windows toolchain directory existing; the guest keeps its toolchain outside the checkout, and the absence is asserted as such |
| `src/audit/hostenv.zig` (AUD-008) | requires WSL to be available | available on Windows, **unavailable with a reason** in the guest, both asserted |
| `src/core/version.zig` (CLI-001) | build target hardcoded to `windows-x86_64` | compare against the target derived from `builtin` |

The `host` platform role still means the case-zero Windows host for evidence; only the assertions become
host-aware, which *strengthens* them in the guest (it now checks the real Linux facts rather than skipping).

## Cache provenance fix (complete, evidence in progress)

`src/plan/cache.zig` no longer converges on bytes alone:

| Situation | Outcome |
|---|---|
| Same action, same artifact, *equivalent* provenance (policy, backend identity, reproducibility) | `converged` |
| Same action, same artifact, different provenance | `provenance_added` - the claim is kept, so a release request can be satisfied by the release claim instead of being refused because a development claim arrived first |
| Same action, different artifact | `discrepancy` - both kept, earlier artifact identity preserved and reported |
| New action identity | `inserted` |

Precedence is deliberate: a same-bytes claim is an upgrade, not a new discrepancy (the discrepancy was reported when the differing artifact arrived). The change was prompted by the transport work unit reading the cache while building TRUST-012 ("converge on action+artifact before examining policy/backend/reproducibility"). PLAN-008 and PLAN-011 are re-recorded with assertions pinning both directions: a same-bytes development claim after a release claim is `provenance_added` (and repeating it converges), and a release claim for the development entry's exact bytes becomes usable for a release request while the development request still finds its own entry.

## Defects found by cross-unit review (fixed in place)

A fifth defect was found by the transport work unit reading `src/plan/cache.zig` while building TRUST-012 - the
kind of catch that only happens when another unit integrates against the code:

- **Cache convergence discarded stronger provenance.** `Cache.record` converged on `(action, artifact)` before
  examining policy, backend identity or reproducibility, so a *signed release* claim arriving after an identical
  *development* claim with the same bytes was reported as `converged` and dropped. A later `lookup(release)`
  then saw only the development entry and refused a hit that should have been valid. Convergence is now
  provenance-aware: `.converged` requires an equivalent entry, a same-bytes entry with different provenance is
  kept as an additional claim, and the discrepancy rule for different artifacts is unchanged. PLAN-008 and
  PLAN-011 were re-recorded with a test that pins both directions.

## Defects the M05 evidence cycle found (fixed)

The characterize stage is not a formality; four real defects surfaced only because the tests were
actually run to failure and then to green with concurrent access:

1. **Scheduler teardown deadlock** (`src/plan/planner.zig`): the first worker loop decided to exit by
   inspecting "any node not started" plus "nothing running", which left a worker waiting on the condition
   variable after the last action had already finished - the `PLAN-009` run hung until killed. Rewritten with a
   single invariant: a worker returns only when the schedule failed or when `finished_nodes == nodes.len`, and
   every completion broadcasts.
2. **Double free on the failure paths** (`src/plan/planner.zig`): the event array was freed manually *and* by
   the `errdefer`, so the "action failed" case aborted the test binary - which also destroys every later case's
   evidence marker. Both failure returns now rely on the `errdefer` alone.
3. **Unbounded resolver recursion** (`src/plan/resolver.zig`): a candidate pool that ignores namespaces drove
   the backtracking walk into a stack overflow. The search now has an explicit depth budget
   (`max_search_depth`) and reports a conflict when it is exhausted.
4. **Concurrent filtered builds overwrote each other's test binary** (`scripts/test.ps1`, `scripts/test.sh`):
   several work units built `-Dfilter=...` into the same `zig-out/bin/jckg-tests.exe`, so one unit's evidence
   run could execute another unit's test binary (observed by M03). Test artifacts now install under
   `.zig-cache/test-prefix-<filter>`; client binaries stay in `zig-out` because the integration tests look for
   them there.

Also corrected: the `PLAN-007` expectation asserted `1.1.0` had patch 1 (it is 0); the locked-version
assertion now pins major/minor/patch explicitly.

## Product code map

| Area | Files |
|---|---|
| Audit | `src/audit/**` (pin, host, inventory, provenance, manifest, baseline, WSL guard, aggregator) |
| Core | `src/core/**` (canonical, digest, tree, store, version, capabilities, policy, cancel, redact) |
| Plans | `src/plan/**` (version, resolver, planner/scheduler, lockfile, cache) |
| CLI | `src/cli/**` (args, output, exit codes, console, commands, integration tests) |
| Execution | `src/exec/**` (work unit M03) |
| Evaluation | `src/eval/**` and `vendor/**` (work unit M04) |

## Blockers and honest gaps

- macOS (x86_64/aarch64) and Windows/Linux aarch64 have no evidence path on this machine.
- The `windows-aarch64` rows likewise stay unavailable.
- M03 records a Windows cleanup limitation: `taskkill /T /F` against creation-time-checked owned process
  identities, no job-object guarantee, no guarantee for detached or racing descendants.
- `scripts/zig.ps1` refuses non-Windows hosts; the guest uses `scripts/test.sh` with its own pinned toolchain.
- **Integration exclusion resolved:** `src/jckg.zig` imports `src/eval/mod.zig` again. M04 replaced the
  unsupported `@cImport` with a `zig translate-c` generated binding (`vendor/quickjs-ng/quickjs.zig`,
  SHA-256 `2cde72782141e64274cf8d6024274e1f816f4d2c6f3cd24a42f1ebf849c93249`) and installs its own
  `zig-out/bin/eval-tests` artifact. `scripts/test.ps1` runs every installed `*-tests.exe`, so the evaluation
  cases produce visible per-test output like the rest.
- **Integration mistake recorded:** to restore the compiling tree I created `src/eval/tests.zig` as a
  coordination placeholder, and that whole-file write landed on top of the M04 work unit's just-written real
  test file (untracked files have no history to recover from). The M04 unit rewrites it. Rule adopted: never
  use a whole-file write on a path owned by another work unit, not even for a placeholder; message the owner
  instead.
- **Shared-worktree coordination rule:** a milestone's fault window (deliberately failing implementation) breaks
  every other work unit's full-suite regression stage, so fault windows are serialized. Order agreed so far:
  M05 (this work unit) first, then M03, then M06. Each unit announces completion.

## Next actions

1. M05: record characterize/fault/green/regression evidence and reviews for PLAN-001..011 (in flight now).
2. Announce "fault window free" to M03, then to M06, as their evidence batches land.
3. Restore the `src/eval/mod.zig` import and re-record any affected evidence once M04's binding compiles.
4. When M03 lands: wire `exec.nativeBackend()` into `jckg doctor`, update the stale core capability text, and
   re-record CLI-008 with the new honest expectations.
5. Guest proof for `linux-x86_64` (done once, recorded in `state/baseline/linux-environment.log`); the full guest
   suite must pass on ext4 before any `linux-*` case is recorded.
6. Then M07 (trust/channels) and M08 (strict Linux execution) with the declared environment.

## M08 plan with the declared environment (replaces "blocked")

M08 (STRICT-001..010) was previously listed as blocked. With ADR-0001 it becomes a concrete plan:

| Element | Approach |
|---|---|
| Worker | A Linux build of the same source (`jckg-worker`) installed in the guest, driven over the pack's newline-delimited JSON frame protocol (`CONTRACTS.md`), never a shell. |
| Isolation | Real Linux namespaces from the guest kernel: `unshare --user --map-root-user --mount --net --pid --fork`, bind-mounting only the workspace and the store at a fixed logical path, with no network interfaces up. Check `bubblewrap`/`unshare` availability first and record which mechanism was actually used. |
| Stable logical paths | Inside the namespace the store appears at a constant logical path (`/jckg/store`), so artifacts never embed the Windows path (STRICT-004, and the relocation question in `ARCHITECTURE.md`). |
| Provenance and transport | Length and digest declared before commitment, verified on return, staged privately, published atomically; an interruption is reported rather than blindly resumed (STRICT-007, STRICT-008). |
| Authentication | A per-session token derived from a local test key; the worker refuses requests without it and denies access to another session's artifacts (STRICT-006). Local test keys only - no host credentials. |
| Honest capabilities | The controller probes a worker that claims enforced isolation (write outside the workspace, open a socket) and rejects the claim when the probe succeeds (STRICT-002, STRICT-010). |
| Evidence | Recorded through `scripts/wsl-evidence.ps1` so records genuinely report `linux-x86_64`; abuse cases are adversarial tests, not smoke tests. |

Prerequisites before M08 starts: M05 regression evidence closed, M03's executor and M06's profile/lease
contracts landed, and the guest full suite green on ext4.

## Session close: M08 at 4 of 10

Complete, each with characterize / fault / green / byte-identical-revert / unfiltered
regression / review:

| Case | What its evidence shows |
|---|---|
| STRICT-006 authenticate workers | skipping the constant-time MAC comparison makes the case fail; an edited token is refused rather than re-scoped |
| STRICT-010 reject fake capabilities | confirming a disproved claim makes the case fail; `usableCapabilities` never returns an unconfirmed claim |
| STRICT-007 verify returned artifacts | a same-length corrupt later output is rejected **before** the earlier good blob or any cache entry commits; a hash-correct *undeclared* replacement is rejected with an unchanged count; missing and duplicate outputs are covered |
| STRICT-008 handle transport interruption | real truncation observed; success and chunk reuse refused until the exact action is reconciled; unknown / running / wrong-action reports refused; same-length corrupted private chunks and whole resumed data verified |

Remaining: STRICT-001..005 and STRICT-009, all linux-x86_64 or host, all blocked on running
the sandbox in the guest rather than on writing it (see the blocked section above for the
unblock command and the current guest behaviour).

Two operational lessons worth carrying forward:

1. **A redirect that hides a failure costs more than the noise it saves.** The strict
   script redirected the build log to `/dev/null`; a build *failure* then looked exactly
   like a hang, and both were chased as a runtime bug for a long stretch. It now prints the
   log on failure.
2. **Silence is not evidence of hanging.** Guest builds that produced no output at all were
   reported as timeouts; the same code built in seconds once the machine was idle.

## M08 complete: nine milestones gate-green

M00 through M08 all report `localGateComplete: true` (gates exit 0). 100 of 188 cases are
complete. Every STRICT case carries characterize, fault, green with a byte-identical
revert, an unfiltered regression, and a review.

The defects that running it found, all fixed and each now covered by a case:

1. **Pipes around fork were the hang.** The action's output went through pipes to the
   worker and the EOF lifecycle was never right; the action now writes into its own
   workspace and the worker reads the files after `wait4`. Suite time went from 400+
   seconds of hang to about five seconds.
2. **Limits belonged to the child.** Applying `RLIMIT_AS`/`NPROC` in the worker also
   constrained the worker's own fork; the child applies them with raw syscalls before exec.
3. **Host binds are refused in this user namespace.** Declared inputs are copied in, the
   root is a tmpfs, and `chroot` hides the host - which is what makes STRICT-001 true.
4. **Read-only remounts come last.** A mount cannot be created inside a read-only
   filesystem, and remounting a parent does not affect a child mount.
5. **Attempt the violation, do not take inventory.** The network check opens a socket and
   tries a real connection; the abandoned `/proc/net/dev` inventory read as empty inside
   the chroot and was weaker evidence anyway.
6. **A filtered run is not a build gate, and a hidden log is not a diagnosis.** Both cost
   real time tonight; both are now written rules.

### Decision: audit baselines follow the checkout

Publishing the repository added `LICENSE`, `AGENTS.md`, `.github/FUNDING.yml`, a README,
and vendor rules in `.gitignore`, and the M08 work extended `build.zig`. The audit cases
correctly detected all of it. Two responses were taken, and they are different:

- `.gitignore` is classed `preserved`, so its recorded digest was **re-recorded** with the
  reason stated in the record's own `meaning` field - a preserved file moved once, with a
  recorded reason, rather than silently.
- The licence assertions previously asserted that **no** project licence existed. They now
  assert that a declared `LICENSE` **is detected** (path reported, MIT text present), which
  is what the audit is for. Re-pinning the old expectation would have made the audit lie.
