# Fetch the vendored toolchain distributions recorded in vendor/manifest.json.
#
# The distributions (esbuild, TypeScript, Node) are *not* committed: they are
# large, they are third-party, and vendor/manifest.json already records the exact
# URL and SHA-256 for each one. This script downloads them, verifies the digest
# before anything is unpacked, and unpacks into the path the manifest names.
#
# vendor/quickjs-ng is committed instead: it is 5 MB of C sources that the build
# compiles directly, so it must not depend on a network fetch.
#
# Usage: pwsh -NoProfile -File scripts/fetch-vendor.ps1 [-Only <name>]

[CmdletBinding()]
param(
    [string] $Only
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$manifestPath = Join-Path $repoRoot 'vendor/manifest.json'
if (-not (Test-Path $manifestPath)) { throw "vendor manifest not found at $manifestPath" }

$manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json
if ($manifest.format -ne 1) { throw "unsupported manifest format: $($manifest.format)" }

$vendorRoot = Join-Path $repoRoot 'vendor'

foreach ($entry in $manifest.artifacts) {
    if ($Only -and $entry.name -ne $Only) { continue }

    $archive = Join-Path $vendorRoot $entry.artifact
    $destination = Join-Path $vendorRoot $entry.path
    $archiveDirectory = Split-Path -Parent $archive
    if (-not (Test-Path $archiveDirectory)) { New-Item -ItemType Directory -Path $archiveDirectory | Out-Null }

    if (-not (Test-Path $archive)) {
        Write-Host "fetching $($entry.name) from $($entry.url)"
        Invoke-WebRequest -Uri $entry.url -OutFile $archive
    }

    # The digest is checked before unpacking: an artifact that does not match is
    # removed rather than extracted, so a tampered or truncated download cannot
    # leave a plausible-looking tree behind.
    $actual = (Get-FileHash -Algorithm SHA256 -Path $archive).Hash.ToLowerInvariant()
    if ($actual -ne $entry.sha256) {
        Remove-Item -Force $archive
        throw "digest mismatch for $($entry.name): expected $($entry.sha256), got $actual (archive removed)"
    }

    if (-not (Test-Path $destination)) { New-Item -ItemType Directory -Path $destination | Out-Null }

    Write-Host "unpacking $($entry.name) into vendor/$($entry.path)"
    if ($archive.EndsWith('.zip')) {
        Expand-Archive -Path $archive -DestinationPath $destination -Force
    }
    else {
        # `tar` ships with Windows 10+ and handles .tgz/.tar.gz; the leading path
        # component of these distributions is stripped so the tree matches the
        # layout the build expects.
        & tar -xzf $archive --strip-components=1 -C $destination
        if ($LASTEXITCODE -ne 0) { throw "tar failed for $($entry.name) with exit $LASTEXITCODE" }
    }
}

Write-Host 'vendor artifacts are present and verified'
