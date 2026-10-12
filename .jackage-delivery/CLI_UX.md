# Command-line interface proposal

## Status

These commands describe the intended public interface.
They are not assertions that the current checkout implements them.
The first audit must map existing commands before incompatible changes.

## Command families

| Command | Behavior |
|---|---|
| `jckg init` | Creates project declarations without overwriting existing files. |
| `jckg doctor` | Reports toolchain, platform, store, and backend capabilities. |
| `jckg plan` | Produces a validated plan without build effects. |
| `jckg lock` | Resolves inputs into an explicit lockfile transaction. |
| `jckg fetch --locked` | Retrieves and verifies the locked input closure. |
| `jckg build --locked` | Executes declared build outputs under the selected policy. |
| `jckg test --locked` | Executes declared test actions on compatible platforms. |
| `jckg develop` | Enters a declared development environment. |
| `jckg run <task> -- <args>` | Executes a declared task with explicit arguments. |
| `jckg package --format <format>` | Realizes package-construction actions. |
| `jckg install [--repo <url>] <package>` | Adds a verified package to a profile generation. |
| `jckg remove <package>` | Creates a generation without the selected package. |
| `jckg upgrade [<package>]` | Resolves permitted updates into a new generation. |
| `jckg search <query>` | Searches enrolled metadata without recipe execution. |
| `jckg show <package>` | Reports package identity, provenance, and supported targets. |
| `jckg list` | Reports selected packages and the active generation. |
| `jckg profile list` | Lists generations and retained references. |
| `jckg profile rollback <generation>` | Selects a validated retained generation. |
| `jckg repo add <url>` | Enrolls a repository through explicit trust. |
| `jckg repo update` | Refreshes and validates channel metadata. |
| `jckg repo remove <identity>` | Removes enrollment without deleting user source. |
| `jckg store status` | Reports logical, physical, pinned, and cache bytes separately. |
| `jckg store gc --dry-run` | Describes unreferenced deletion candidates. |
| `jckg store gc --apply` | Deletes eligible objects under lease protection. |
| `jckg publish --dry-run` | Describes an authorized publication transaction. |
| `jckg publish --apply` | Publishes after explicit authority validation. |
| `jckgx [--repo <url>] <package> [args]` | Executes through a transient profile. |

The parser must distinguish package-runner options from executable arguments.
`jckgx --repo <url> <package> --help` sends `--help` to the selected executable.
The `--` separator supplies an unambiguous alternative.
A package with multiple entry points requires an explicit selection or a declared default.

## Stable process behavior

`--version` reports the Jackage version and relevant build identity.
`--json` emits structured stdout without progress text.
Streaming commands emit one JSON object per line and one final summary event.
Human progress and diagnostics use stderr.
Secrets never appear in structured errors or progress messages.

The CLI refuses interactive trust prompts when stdin is not interactive.
`--yes` can approve a described local profile transaction.
It does not enroll arbitrary trust roots, enable privilege, or authorize publication.
Implicit global package installation is forbidden.

## Exit behavior

The initial proposal reserves `0` for successful completion.
CLI syntax, policy, resolution, integrity, action, and infrastructure errors need documented distinct codes.
A launched program's exit status is preserved through `jckgx` when the host supports it.
Launch failures remain distinguishable from the program's own exit status through structured output.
Signal and Windows status translation require platform-specific tests.

## Profiles

A profile references a dependency closure in immutable storage.
A profile generation is complete before it becomes active.
The activation pointer changes atomically under a profile lock.
A crash leaves either the old generation or the new validated generation active.

Windows can retain open executable handles after a profile change.
Generation deletion must respect active leases and open-handle failures.
A portable command shim resolves the active generation through one documented mechanism.
The initial design must not assume POSIX symlink replacement semantics on Windows.

Package removal removes references, not source directories.
Garbage collection later removes unreachable artifacts.
Rollback does not pretend to reverse external installers or arbitrary system mutations.
Native package export remains a separate feature.

## Transient execution

`jckgx` uses the same repository verification and resolver as installation.
It creates a lease for the complete execution closure.
It preserves that lease until the process tree exits.
Concurrent invocations share immutable artifacts, not writable work directories.
Network and filesystem authority follow the explicit execution policy.

A cached artifact can support offline execution only under the documented trust policy.
Transient execution does not modify installed profiles or global PATH.
A timeout cleans up child processes before releasing its lease.

## Scope of convenience

Apt-like naming serves discoverability, not apt implementation compatibility.
The initial project does not promise dpkg database compatibility or arbitrary maintainer scripts.
Future system installers must remain package backends with explicit platform and privilege requirements.
