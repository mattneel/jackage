# Repository channels and trust

## Identity

A package identity contains a repository namespace, package name, version, and output platform.
Two repositories cannot satisfy each other's dependencies through a shared package name alone.
A GitHub owner/name pair is a transport locator, not permanent cryptographic identity.
The trust root identifies the publisher independently of redirects or repository renames.

## Repository discovery

The proposed GitHub adapter retrieves `jackage-repository.json` from the selected repository revision.
This discovery file contains metadata endpoints and a claimed repository identity.
The discovery file does not authorize itself.
A signed or explicitly enrolled trust root supplies authorization.
The adapter records the actual descriptor revision after discovery.

The proposed descriptor supports three hosting modes:

- Pages hosts metadata and small artifacts.
- Releases hosts versioned metadata and artifact assets.
- Pages hosts metadata while Releases hosts artifact assets.

A discovery pointer can be mutable.
All downloaded metadata and artifacts still pass the pinned trust and digest rules.
Static hosting requires no custom repository server.
No fixed GitHub Pages URL pattern is assumed when a repository supplies a custom domain.

## Trust bootstrap

An initial repository enrollment requires a trusted root file or an independently approved fingerprint.
Interactive trust prompts show the repository identity and fingerprint before installation.
Noninteractive operation requires an explicit trust policy and fails without it.
An HTTPS connection and a checksum from the same untrusted source do not establish publisher authenticity.
The test suite uses generated local keys and an isolated trust directory.

The release trust design follows a pinned TUF specification and compatible metadata [S03].
It must preserve root, targets, snapshot, and timestamp responsibilities.
Implementations must use standard cryptographic libraries or reviewed primitives from dependencies.
A custom signature envelope cannot be called TUF-compatible without conformance evidence.

## Metadata protections

The client verifies signature thresholds, role scope, metadata lengths, hashes, versions, and expiration.
Trusted state survives process restarts.
Rollback state changes only after a complete successful metadata transaction.
Root rotation requires the documented previous-root and new-root authorization path.
An interrupted root rotation cannot leave the client with an unverified root.

A pinned artifact remains integrity-verifiable offline.
Expired online metadata does not become fresh merely because its artifact is cached.
Offline use of already trusted installed artifacts follows a distinct documented policy.
A network failure must not silently downgrade an update into stale metadata acceptance.

## GitHub behavior

The transport handles pagination, rate limits, bounded retry, and conditional requests.
Redirects must not forward authorization headers to an unrelated host.
The adapter never places a private token in an asset URL, log, or lockfile.
Public channel tests use a local HTTP fixture server by default.
Live GitHub smoke tests require explicit opt-in and read-only scopes unless publication is authorized.

Pages has size and bandwidth limits, so large binary artifacts normally fit Releases better [S04].
Immutable Releases can protect published assets and their tags when enabled [S05].
Those protections supplement, rather than replace, Jackage's verification and trust state.

## Resolution

The first version policy uses a documented SemVer subset with exact prerelease behavior.
A locked graph contains exact selections regardless of the initial user range.
Solver output is deterministic for the same candidate metadata and policy.
Errors explain dependency conflicts and preserve repository namespaces.
A deterministic exhaustive fixture solver can validate the production resolver on small graphs.

Yanked versions need explicit policy.
Existing locked use and fresh selection are separate decisions.
The resolver cannot substitute a different artifact for the same locked identity.
Mirror substitution is permitted only when the verified identity and artifact digest remain unchanged.

## Publication transaction

Publication follows an explicit plan before any network mutation.
Assets upload before metadata advertises them.
TUF metadata becomes visible in an order that preserves consistent snapshots.
A failed upload leaves no channel entry that advertises absent assets.
Retries use idempotent operations or detect an already completed identical publication.

Release signing keys do not enter recipe evaluation or general build workers.
Public release publication requires explicit authorization.
A dry run can validate names, sizes, digests, and metadata without publishing.
A local fixture publication must pass before a live channel test.

## Extraction

Downloaded archives remain untrusted until validation and extraction complete.
The extractor rejects path escape, reserved destination names, link attacks, and duplicate conflicting entries.
It enforces entry-count, total-size, nesting, and expansion limits.
Platform executable bits and supported link semantics must round-trip correctly.
The store never publishes a tree after a partial extraction failure.

## Cache trust

A remote action cache contains claims about computations, not only content-addressed bytes.
The client verifies artifact bytes and requires provenance appropriate to the requested policy.
An untrusted worker cannot create trusted release cache entries through a guessed action digest.
Cache poisoning tests must cover this distinction.
