# ADR-0002: Development synchronization adapter (Mutagen)

## Status

Accepted, by explicit user direction ("look at using Mutagen to sync files between the dev and WSL guest host so we don't have to deal with slowdowns").

## Requirement

- `STORAGE_WORKSPACES.md`: "A Windows bind mount is not the normal Linux compilation path. The host-to-guest transfer happens before the build hot path." and "Development updates can use a delta protocol or an existing transport adapter. A file update must reach the guest as a real filesystem change."
- `CASE_ZERO.md`: the executor "does not require the user to maintain a second source checkout manually".
- ADR-0001: guest-native compilation is required.

## Observed problem

Compiling over `\\wsl.localhost` (9p) is slow and not the declared Linux compilation path. Manual copying is error-prone and gives no signal about what the guest actually has. The development loop therefore needs a real transport adapter with delta updates.

## Alternatives

| Option | Evidence | Verdict |
|---|---|---|
| Compile directly over the Windows mount | Explicitly ruled out by `STORAGE_WORKSPACES.md`; 9p is slow | Rejected |
| `rsync` before each build | Present in the guest (`/usr/bin/rsync`), but rescans and copies eagerly; no watcher | Kept as the fallback for one-off transfers |
| Mutagen session | Windows daemon + WSL agent, delta sync, real file events on the Windows side, MIT licence | **Chosen** |
| Two-way sync | Risk of silently overwriting host edits | Rejected: `one-way-safe` only |

Observed tool identity: Mutagen `v0.18.1` (release published 2025-02-24), Windows amd64 archive
`mutagen_windows_amd64_v0.18.1.zip`, SHA-256 `76f8223d5e6b607efdd9516473669ae5492e4f142887352d59bc6934d1f07a2d`,
102,206,512 bytes, MIT licence (LICENSE at tag `v0.18.1`, 2036 bytes, SHA-256 `886ee5c61fb4b87bfe80499a667e1b0e4ab0216d133b0c7ec9f0859f73127d55`). Installed outside the checkout at `%USERPROFILE%\jckg\tooling\mutagen-v0.18.1\`.

## Decision

A single Mutagen session named `jckg-dev` synchronizes `C:\src\jackage` (source of truth, user-owned) into the guest path `~/jckg/dev` (derived, disposable, ext4):

```text
mutagen sync create --name=jckg-dev --sync-mode=one-way-safe --ignore-vcs \
  --ignore=.zig-cache --ignore=zig-out --ignore=tools/zig --ignore=*.pdb --ignore=*.log \
  --ignore=.jackage-delivery/state/evidence \
  C:\src\jackage \\wsl.localhost\Ubuntu\home\autark\jckg\dev
```

- `one-way-safe`: the guest mirror never overwrites or deletes the Windows source; guest-only changes are surfaced as conflicts.
- Build outputs and the Windows toolchain are excluded, so the guest compiles into its own `zig-out`/`.zig-cache` on ext4.
- Evidence logs are excluded from the sync because the recorder writes them through the Windows path directly.

## Consequences

- The development loop is edit-on-Windows, compile-on-Linux with delta updates instead of full copies.
- Mutagen is **development tooling only**: it is not a product dependency, not part of any action identity, and never used to produce release inputs. Release and action inputs still come from an immutable, digest-recorded snapshot (`STORAGE_WORKSPACES.md`, M12).
- The daemon runs per user and can be stopped (`mutagen daemon stop`); no service, firewall, or security setting is registered or changed.
- The guest workspace can be deleted at any time; re-creating the session reproduces it.
- A missing or stopped daemon degrades to the `rsync` fallback rather than to a stale build directory.

## Tests

- Positive: `mutagen sync flush jckg-dev` reports the session connected on both endpoints; a file written on Windows appears in the guest after a flush; `scripts/test.sh` builds from the guest copy.
- Negative: a guest-only file is reported as a conflict and is not deleted by a flush; an excluded path (`.zig-cache`, `zig-out`, `tools/zig`) never appears in the guest mirror.
- Recovery: stopping the daemon and re-running the session leaves both sides consistent; deleting the guest root and flushing restores the mirror.

## Sources

- `STORAGE_WORKSPACES.md` (source snapshots, Linux execution workspace), `CASE_ZERO.md` (Linux workflow).
- Mutagen documentation (synchronization modes and ignore semantics) and the pinned release assets listed above.
- Local observations: session `jckg-dev` created and connected on 2026-10-12.
