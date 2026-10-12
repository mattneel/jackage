# Primary sources

These references support specific external facts, not the proposed Jackage architecture.
The architecture and acceptance thresholds are design decisions in this pack.
No third-party source files or binaries are bundled.

## S01: Zig download index

<https://ziglang.org/download/index.json>

The index identifies the exact compiler build supplied by the user. It does not verify the user's local executable.

## S02: QuickJS-NG C API

<https://quickjs-ng.github.io/quickjs/developer-guide/intro/>

The primary API describes runtime limits, interrupts, and bytecode cautions. Jackage policy is a separate proposed design.

## S03: TUF specification and metadata

<https://theupdateframework.github.io/specification/v1.0.36/>

The specification defines signed metadata roles and client verification. Pin a reviewed version during implementation.

## S04: GitHub Pages limits

<https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits>

Pages imposes site and bandwidth limits. Recheck applicable limits before production channel publication.

## S05: GitHub immutable releases

<https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases>

Enabled immutable releases protect assets and associated tags. This does not replace client trust enrollment.

## S06: Reproducible Builds definition

<https://reproducible-builds.org/docs/definition/>

A reproduction claim concerns identical declared artifact bytes under the specified inputs and environment.

## S07: OCI overview

<https://opencontainers.org/about/overview/>

OCI distinguishes image, runtime, and distribution specifications. Pin the concrete specification versions for backend conformance.

## S08: Windows Hypervisor Platform API

<https://learn.microsoft.com/en-us/virtualization/api/hypervisor-platform/hypervisor-platform>

WHP exposes low-level partition, memory, and processor APIs. A complete Jackage runtime requires additional components.

## S09: Oh-My-Pi context files

<https://github.com/can1357/oh-my-pi/blob/main/docs/context-files.md>

The primary project documentation describes context discovery and precedence. Audit the installed OMP version before context integration.

## Repository evidence

The actual Jackage source was not supplied.
The directory inventory and compiler output come directly from the user.
The OMP context documentation was retrieved from the public upstream repository.
The pack does not assume a GitHub remote for Jackage.
