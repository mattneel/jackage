# Platforms and package backends

## Support matrix

The full delivery target includes the native clients below.
Each claimed target needs a native process test, not only successful cross-compilation.
Unavailable hardware remains an open release gate.

| Client target | Required product behavior |
|---|---|
| Windows x86_64 | Install, profile transactions, `jckgx`, local builds, and remote execution. |
| Windows aarch64 | The same client contracts with native execution evidence. |
| Linux x86_64 | The same contracts plus the strict reference executor. |
| Linux aarch64 | The same client contracts and validated strict-executor support. |
| macOS x86_64 | The same client contracts with SDK and signing boundaries recorded. |
| macOS aarch64 | The same client contracts with native execution evidence. |

The first usable development milestone targets the user's actual Windows architecture.
The agent must discover that architecture rather than infer it from the directory listing.
M00 also records the minimum available OS versions and SDK requirements.

## Cross-platform claims

Client portability, compiler output support, native testing, and hermetic execution are separate claims.
An exported Windows executable does not prove native Windows tests passed.
A Linux container does not run a macOS SDK without an appropriate supported environment.
Platform SDK licensing and redistribution restrictions require explicit review before packaging.

The core must handle path separators, Unicode, case collisions, executable metadata, and process status differences.
Windows tests include long paths, spaces, reparse points, locked executables, and alternate data stream rejection.
macOS tests include case-insensitive destinations and relevant signing behavior.
Linux tests include executable flags, link semantics, and container isolation failures.

## Package family

| Backend | Required output and validation |
|---|---|
| Portable ZIP | Safe names, declared metadata policy, deterministic order, and reproducible bytes. |
| Portable tar archive | Deterministic metadata, supported link semantics, and round-trip tree equality. |
| OCI image | Image layout, validated descriptors, configuration, layers, and digest checks. |
| Debian package | Native package metadata and installation smoke tests in a disposable Debian environment. |
| RPM package | Native package metadata and installation smoke tests in a disposable RPM environment. |
| Windows MSIX | Manifest validation, architecture mapping, and unsigned versus signed output distinction. |
| macOS package | Package layout and a disposable native installation test under authorized conditions. |
| Linux root filesystem | Declared runtime closure and boot or container smoke test. |
| ext4 image | Filesystem validation and deterministic payload verification. |
| VHDX image | Valid container, correct guest filesystem payload, and attachment smoke test. |

Compression tools and options belong to package action identities.
Unsigned package construction precedes any signing action.
Signed wrappers and publication attestations can contain intentional nonreproducible fields.
Their policy must distinguish reproducible payloads from nonreproducible envelopes.
A backend cannot call a whole image byte-reproducible when only its payload was compared.

OCI image, runtime, and distribution are separate specifications [S07].
The Jackage OCI exporter does not imply a built-in container runtime.
Disk-image export does not imply a built-in hypervisor.

## Reference executor

The initial strict backend executes on Linux with an explicit root and network policy.
The implementation can use a reviewed existing isolation tool or a native implementation.
The choice requires an architecture decision and adversarial capability tests.
The backend must work through one actual transport from the Windows client.

A remote backend authenticates the worker and scopes artifact access to the authorized action.
A host-to-guest socket is not remote authentication by itself.
The backend must validate all returned artifact identities and declared outputs.
A malicious worker test covers cache poisoning and forged capability claims.

## Later adapters

Hyper-V and Firecracker are separate adapters to the action and session contracts.
WHPX remains an option only if higher-level adapters fail a measured requirement.
A runtime comparison needs startup, transfer, execution, reclaim, and recovery data.
The product must not select a hypervisor solely to avoid a storage lifecycle decision.

A future devcontainers frontend can consume Jackage environment manifests and image outputs.
Editor attachment, ports, and service lifecycle remain separate from the immutable package core.
The user has not committed to a bundled frontend or a separate product.
