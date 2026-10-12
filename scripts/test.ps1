<#
.SYNOPSIS
    Runs the Jackage test suite through the pinned toolchain.

.DESCRIPTION
    Three layers run, all through scripts/zig.ps1 so the pinned compiler is the
    only one ever used:

      1. the build-system test step, which covers the scaffold modules
         (src/main.zig, src/root.zig), the product module graph, and every
         module that installs its own test binary;
      2. every installed `*-tests` executable, run directly so that each test's
         own output (including its evidence marker) and the final
         "All N tests passed." line are visible in the transcript;
      3. the client binaries needed by the integration tests.

    Filter isolation: test artifacts are installed under a prefix derived from
    the filter, because several work units build filtered test binaries
    concurrently in the same worktree. Without that, one unit's filtered build
    would overwrite another unit's installed test binary - which already
    happened once and produced a meaningless result.

    Test filters are compiled into the binaries by `-Dfilter`, so no runtime
    flag is passed. The exit code is the first failing step's exit code.

.PARAMETER Filter
    Only run tests whose name contains this text. Used to run one acceptance
    case in isolation.

.EXAMPLE
    scripts\test.ps1

.EXAMPLE
    scripts\test.ps1 -Filter CAN-001
#>
[CmdletBinding()]
param(
    [string] $Filter
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Zig = Join-Path $PSScriptRoot 'zig.ps1'

# A filesystem-safe name for the filter, so concurrent filtered runs never
# share an install prefix.
$prefixName = 'zig-out'
if ($Filter) {
    $safe = ($Filter -replace '[^A-Za-z0-9._-]', '-')
    $prefixName = ".zig-cache/test-prefix-$safe"
}
$testPrefix = Join-Path $RepoRoot $prefixName

if ($Filter) {
    & $Zig build test "-Dfilter=$Filter" --prefix $testPrefix
} else {
    & $Zig build test --prefix $testPrefix
}
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Install the client binaries at the default prefix: the integration tests look
# for `zig-out/bin/jckg.exe`. Several work units share this worktree, so two
# concurrent runs can collide while copying that artifact ("failed updating file
# ... AccessDenied"); that is transient, while a compile error is not, so the
# retry is limited to the copy-collision case.
$installAttempts = 3
for ($attempt = 1; $attempt -le $installAttempts; $attempt++) {
    $installOutput = & $Zig build 2>&1
    $installExit = $LASTEXITCODE
    $installOutput | ForEach-Object { Write-Host $_ }
    if ($installExit -eq 0) { break }
    if ($installOutput -match 'failed updating file') {
        if ($attempt -lt $installAttempts) {
            Write-Host "install collided with a concurrent run; retrying ($attempt/$installAttempts)"
            Start-Sleep -Milliseconds 750
            continue
        }
    }
    exit $installExit
}

$binaryDirectory = Join-Path $testPrefix 'bin'
$binaries = Get-ChildItem -Path $binaryDirectory -Filter '*-tests*' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -eq '.exe' -or $_.Extension -eq '' } |
    Sort-Object -Property Name
if (-not $binaries) {
    Write-Error "no installed test binary was found under $binaryDirectory"
    exit 1
}

foreach ($binary in $binaries) {
    Write-Host "=== $($binary.Name) ==="
    & $binary.FullName
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
exit 0
