# Contract proposal version 1

## Contract status

The schemas and fixtures are proposed design contracts, not claims about current repository code.
M00 must identify any existing public contracts before adoption.
A changed contract requires a decision record, version analysis, and replacement vectors.
A failing test is not permission to weaken a requirement.

## Canonical values

`jckg-json-v1` defines the canonical JSON encoding for core identities.
It is a Jackage encoding, not a claim of RFC 8785 compliance.
The value domain contains null, booleans, strings, arrays, objects, and safe integers.
Integers lie between `-9007199254740991` and `9007199254740991` inclusive.
Larger sizes and counters use canonical decimal strings where their schema requires them.
Floating-point values, NaN, infinities, and negative zero are rejected.

Strings contain Unicode scalar values only.
Unpaired surrogate values are rejected.
No Unicode normalization occurs.
Objects contain distinct string keys and no duplicate keys at parse time.
Object keys sort by their UTF-8 byte sequences.
Arrays retain their declared order.

The encoder writes UTF-8 without a byte-order mark or trailing newline.
It uses no whitespace between JSON tokens.
Quote and backslash use `\"` and `\\` escapes.
Backspace, tab, newline, form feed, and carriage return use their short JSON escapes.
Other control characters from U+0000 through U+001F use lowercase `\u00xx` escapes.
Other valid characters remain literal UTF-8.

This format needs an independent Zig implementation and golden-vector tests.
The pack's Python oracle supplies a test reference, not production code.
A raw JSON parser must reject duplicate keys before canonical encoding.

## Digest domains

```text
blob digest   = SHA-256(file bytes)
tree digest   = SHA-256("jckg:tree:v1\0" || canonical tree)
action digest = SHA-256("jckg:action:v1\0" || canonical action)
plan digest   = SHA-256("jckg:plan:v1\0" || canonical plan)
```

Displayed digests use `sha256:` followed by 64 lowercase hexadecimal digits.
Domain prefixes contain a real NUL byte, not a literal backslash and zero.
Canonical content includes its semantic schema version.
A content digest proves integrity, not publisher identity.

## Tree format

The initial tree format is a flat array of entries in path order.
Each entry has a relative POSIX-style path and a kind.
File entries contain a blob digest, byte length, and an executable flag.
Directory entries preserve empty directories.
Symlink entries contain a literal target string, never followed during tree hashing.
Hardlink topology and platform-specific metadata require explicit extension versions.

Tree identities exclude file access times and arbitrary host ownership identifiers.
A package backend can require declared metadata that the generic portable tree lacks.
The backend must reject missing required metadata rather than invent it.

Paths cannot contain NUL, empty components, `.` components, or `..` components.
Paths cannot be absolute or contain backslashes in the portable tree representation.
A destination adapter also rejects its reserved names and normalization collisions.
A Linux-only tree can contain names that Windows cannot materialize.
The Windows adapter must report that incompatibility without renaming files silently.

The initial portable fixture policy also rejects drive syntax, alternate streams, and trailing dots or spaces.
Tree structure rejects a file that is an ancestor of another entry.
Link resolution must remain within authorized roots when links become accessible to a build.
The extraction implementation must resist link replacement races and reparse-point traversal.

## Action format

| Field | Requirement |
|---|---|
| `schemaVersion` | Names the semantic contract version. |
| `executionPlatform` | Defines the platform for tools. |
| `outputPlatform` | Defines the intended output platform. |
| `inputs` | Binds logical names to exact artifact digests. |
| `tool` | Identifies a declared executable inside an input artifact. |
| `arguments` | Contains an argv array, not an implicit shell string. |
| `environment` | Contains an explicit environment map. |
| `workingDirectory` | Uses a logical workspace path. |
| `outputs` | Declares relative output paths and expected kinds. |
| `requirements` | Specifies isolation and policy requirements. |
| `limits` | Bounds resources and execution duration. |
| `cachePolicy` | Distinguishes release, development, and noncacheable actions. |

A shell script is an explicit input executed by an explicit shell tool.
The executor does not expand argv through an ambient host shell.
The plan resolves user aliases before the action identity is calculated.
A secret value never appears in the action JSON, logs, or cache key.
An action with undeclared secret effects cannot enter a public reproducible cache.

## Plans and lockfiles

A plan is a directed acyclic graph of actions and declared outputs.
The planner rejects cycles and unresolved references before execution.
Runtime effects cannot discover hidden dependencies after identity calculation.
A future dynamic-dependency feature needs a separate verified protocol.

A lockfile records exact source identities, artifact digests, toolchain identities, and repository provenance.
It includes the QuickJS-NG engine and TypeScript transformation tool.
It distinguishes execution and output platforms.
It records bootstrap inputs and platform SDK boundaries.
Mutable labels such as `master` or `latest` cannot be the only locked identity.

`--locked` requires existing resolution and refuses lockfile changes.
A lock digest does not grant trust to its sources.
Repository authorization and artifact verification remain mandatory.

## Executor capabilities

Capabilities state whether an operation is supported, enforced, unavailable, or merely observed.
The core rejects release requirements that an executor cannot enforce.
Unknown capability names do not imply support.
A capability claim needs platform-specific conformance evidence.

Capability topics include filesystem isolation, network isolation, process cleanup, and output collection.
They also include stable logical paths, resource bounds, and workspace reclamation.
Time and CPU behavior need explicit environment policies.
No backend can promise perfect control of time or entropy without evidence for its declared mechanism.

## Process plugin protocol

The initial external transport uses newline-delimited UTF-8 JSON on stdin and stdout.
Stdout carries protocol frames only.
Stderr carries bounded plugin diagnostics.
The frame limit is 1 MiB before parsing.
Binary data travels through an artifact channel, never an unbounded JSON field.

A handshake exchanges protocol major version, minor version, and plugin capabilities.
Incompatible major versions fail before any action starts.
Requests include a unique identifier and a method.
Responses include that identifier and exactly one result or error.
Action events include an action identifier and a monotonic sequence number within their stream.

The minimum methods are `describe`, `prepare`, `execute`, `cancel`, and `collect`.
Session methods are a separate capability group.
A disconnect changes action status to unknown until reconciliation determines the real outcome.
Cancellation must reach the full process tree and preserve output quarantine.
The controller applies backpressure and detects oversized or malformed frames.

## Artifact transfer

Transfers declare expected digest and length before commitment.
The receiver writes to a private staging path and verifies actual bytes.
Publication is atomic within the chosen store transaction model.
Resume support verifies existing chunks instead of trusting a partial filename.
A remote cache result is not trusted solely because its transport used TLS.

## Results and errors

Results distinguish success, action failure, policy denial, cancellation, timeout, and infrastructure failure.
A result contains declared output identities only after validation.
It records the actual environment and backend identity separately from the action.
Structured errors include a stable code, human message, and safe diagnostic detail.
Secret data and credential-bearing URLs are prohibited in public error detail.

The CLI exposes structured results under `--json`.
Streaming operations use JSON lines with a documented schema and final summary event.
Human progress never mixes into structured stdout.
