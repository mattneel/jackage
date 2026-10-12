<#
.SYNOPSIS
    Runs the repo-pinned Zig toolchain (tools\zig\zig.exe).

.EXAMPLE
    scripts\zig.ps1 version

.EXAMPLE
    scripts\zig.ps1 build
#>
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$ZigExe   = Join-Path $RepoRoot 'tools\zig\zig.exe'

if (-not (Test-Path -LiteralPath $ZigExe)) {
    $pin = (Get-Content -LiteralPath (Join-Path $RepoRoot '.zigversion') -Raw).Trim()
    throw "Pinned Zig $pin is not installed yet. Run scripts\fetch-zig.ps1 first."
}

& $ZigExe @args
exit $LASTEXITCODE
