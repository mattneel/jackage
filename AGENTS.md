# Working in this repository

Conventions for humans and coding agents. The delivery plan, acceptance cases, and
recorded evidence live in `.jackage-delivery/`; read `JACKAGE_START_HERE.md` there first.

## Toolchain

- Use `scripts/zig.ps1` for every Windows compiler command. It installs the pinned
  toolchain recorded in `.zigversion` on first use and refuses to run without it.
- Do not change the compiler pin without an explicit decision: the pin is part of the
  evidence.
- Linux work runs in the declared execution environment through the guest scripts.

## Tests and evidence

- `scripts/test.ps1` is the host suite; `-Filter <case>` selects a case or group.
- `scripts/test.sh` and `scripts/strict-test.sh` are the guest suites.
- An acceptance case is complete only with four recorded observations - characterize,
  fault, green, and an unfiltered regression - plus a review. Record them with
  `.jackage-delivery/tools/delivery.py run`; the guest helper is
  `scripts/strict-evidence.sh <CASE> <STAGE>`.
- A fault observation must fail *that case's own assertion*. If a fault fails for some
  other reason, the case is not evidenced.
- Revert a fault byte-identically and prove it; a `diff` against a backup costs nothing
  and prevents an accidental behaviour change from riding along with the revert.

## House rules learned the hard way

- **Filtered runs are not a build gate.** Zig analyses test bodies lazily, so a filtered
  run can pass while the unfiltered tree does not compile. Only the unfiltered suite
  counts as a compile gate.
- **Never hide a failure behind output redirection.** A build log sent to `/dev/null`
  makes a compile failure look exactly like a hang.
- **One writer at a time.** Do not edit shared source while someone else's test batch is
  running; announce a fault window before opening it and close it immediately after the
  revert.
- **A claim is not evidence.** Probes attempt the violation; a backend's self-description
  is never trust.

## Layout

`src/core` canonical encoding, digests, store, journal · `src/plan` resolver and lockfile ·
`src/exec` native execution · `src/eval` TypeScript and QuickJS-NG · `src/profile`
generations and leases · `src/trust` keys, metadata, download, archives · `src/worker`
strict execution · `src/cli` the `jckg` surface.
