#requires -Version 5.1
<#
.SYNOPSIS
    Downloads the repo-pinned Zig toolchain into tools\zig.

.DESCRIPTION
    The pinned version lives in .zigversion (repo root, committed). This script
    downloads the matching x86_64-windows build from ziglang.org, verifies it
    against the SHA-256 pinned below, and extracts it to tools\zig (gitignored).

    Re-running is a no-op once the pinned version is installed.

.PARAMETER Force
    Reinstall even if the pinned version is already present.
#>
[CmdletBinding()]
param(
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

if ($env:OS -ne 'Windows_NT') {
    throw 'This repo pins the x86_64-windows toolchain; this script only runs on Windows.'
}

# sha256 of zig-x86_64-windows-<.zigversion>.zip, from https://ziglang.org/download/index.json
$Sha256 = 'ec5d64aae44b54ce8425ecd7b40f1fa5c8061d1dc80939b02ed036513d69ae67'

# BCL SHA256 instead of Get-FileHash: the cmdlet is missing on some Windows
# PowerShell 5.1 installs with stale module sets.
function Get-Sha256Hex([string] $Path) {
    $sha    = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant()
    } finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

$RepoRoot = Split-Path -Parent $PSScriptRoot
$Version  = (Get-Content -LiteralPath (Join-Path $RepoRoot '.zigversion') -Raw).Trim()
$Url      = "https://ziglang.org/builds/zig-x86_64-windows-$Version.zip"
$ToolsDir = Join-Path $RepoRoot 'tools'
$DestDir  = Join-Path $ToolsDir 'zig'
$ZigExe   = Join-Path $DestDir 'zig.exe'

if (-not $Force -and (Test-Path -LiteralPath $ZigExe)) {
    $installed = ((& $ZigExe version) -join '').Trim()
    if ($installed -eq $Version) {
        Write-Host "Pinned Zig $Version already installed at $ZigExe"
        return
    }
    Write-Warning "tools\zig contains Zig $installed, expected $Version; reinstalling."
}

# Keep a verified archive in %TEMP% so a failed extraction can be retried without re-downloading.
$Zip = Join-Path ([IO.Path]::GetTempPath()) "zig-x86_64-windows-$Version.zip"
if (Test-Path -LiteralPath $Zip) {
    $cached = (Get-Sha256Hex $Zip)
    if ($cached -ne $Sha256) { Remove-Item -LiteralPath $Zip -Force }
}
if (-not (Test-Path -LiteralPath $Zip)) {
    Write-Host "Downloading $Url"
    (New-Object System.Net.WebClient).DownloadFile($Url, $Zip)
}

$actual = (Get-Sha256Hex $Zip)
if ($actual -ne $Sha256) {
    throw "SHA-256 mismatch for $Url`n  expected: $Sha256`n  actual:   $actual"
}

Write-Host "Extracting to $DestDir"
Remove-Item -LiteralPath $DestDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $DestDir | Out-Null

# The zip holds a single zig-x86_64-windows-<version>\ directory; tar (bsdtar,
# bundled with Windows 10 1803+) strips it so the result is tools\zig\zig.exe.
& (Join-Path $env:SystemRoot 'System32\tar.exe') -xf $Zip -C $DestDir --strip-components=1
if ($LASTEXITCODE -ne 0) {
    Remove-Item -LiteralPath $DestDir -Recurse -Force -ErrorAction SilentlyContinue
    throw "Extraction failed (tar exit code $LASTEXITCODE)."
}

$installed = ((& $ZigExe version) -join '').Trim()
if ($installed -ne $Version) {
    throw "Extracted Zig reports '$installed', but .zigversion pins '$Version'."
}
Write-Host "Zig $installed installed at $ZigExe"
Write-Host 'Use it via scripts\zig.ps1 <args>, or add tools\zig to PATH.'
