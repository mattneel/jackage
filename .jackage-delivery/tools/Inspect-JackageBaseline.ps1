#requires -Version 5.1
<#
.SYNOPSIS
Records the existing repository baseline without source edits.
.DESCRIPTION
The default mode only reads known repository metadata and files.
Review the repository wrapper and build before using -RunVersion or -RunBaseline.
RunBaseline executes the existing wrapper and can create normal compiler outputs.
#>
[CmdletBinding()]
param(
    [switch]$RunVersion,
    [switch]$RunBaseline
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$kit = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$root = [IO.Path]::GetFullPath((Join-Path $kit '..'))
$expected = '0.18.0-dev.146+35accc06e'
$wrapper = Join-Path $root 'scripts/zig.ps1'
$files = @()
foreach ($relative in @('.zigversion', 'build.zig', 'build.zig.zon', 'scripts/zig.ps1', '.gitignore')) {
    $path = Join-Path $root $relative
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $item = Get-Item -LiteralPath $path
        $files += [ordered]@{
            path = $relative
            length = $item.Length
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    } else {
        $files += [ordered]@{ path = $relative; missing = $true }
    }
}
$pinFile = Join-Path $root '.zigversion'
$pin = $null
if (Test-Path -LiteralPath $pinFile -PathType Leaf) {
    $pin = [IO.File]::ReadAllText($pinFile).Trim()
}
$report = [ordered]@{
    schemaVersion = 1
    observedUtc = [DateTime]::UtcNow.ToString('o')
    root = $root
    expectedCompiler = $expected
    pinFile = $pin
    pinMatches = ($pin -eq $expected)
    powershellVersion = $PSVersionTable.PSVersion.ToString()
    osDescription = [Environment]::OSVersion.VersionString
    is64BitProcess = [Environment]::Is64BitProcess
    files = $files
    commands = @()
    productAuditComplete = $false
    note = 'This inventory does not replace source inspection or product tests.'
}
function Invoke-WrapperStep {
    param([string[]]$StepArguments)
    if (-not (Test-Path -LiteralPath $wrapper -PathType Leaf)) {
        throw 'The existing scripts/zig.ps1 wrapper is missing.'
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $shell = Join-Path $PSHOME 'pwsh'
        if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            $shell = Join-Path $PSHOME 'pwsh.exe'
        }
    } else {
        $shell = Join-Path $PSHOME 'powershell.exe'
    }
    $oldPreference = $ErrorActionPreference
    Push-Location -LiteralPath $root
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $shell -NoProfile -File $wrapper @StepArguments 2>&1)
        $code = $LASTEXITCODE
        return [ordered]@{
            command = @($shell, '-NoProfile', '-File', $wrapper) + $StepArguments
            exitCode = $code
            output = ($output | Out-String)
        }
    } finally {
        $ErrorActionPreference = $oldPreference
        Pop-Location
    }
}
if ($RunVersion -or $RunBaseline) {
    $version = Invoke-WrapperStep -StepArguments @('version')
    $report.commands += $version
    $report['observedVersionMatches'] = (($version.exitCode -eq 0) -and ($version.output.Trim() -eq $expected))
    if (-not $report.observedVersionMatches) {
        $report['baselineBlocked'] = 'The actual wrapper compiler version differs from the supplied pin.'
    } elseif ($RunBaseline) {
        foreach ($step in @(@('build', '--help'), @('build'), @('build', 'test'))) {
            $report.commands += Invoke-WrapperStep -StepArguments $step
        }
    }
}
$state = Join-Path $kit 'state'
[IO.Directory]::CreateDirectory($state) | Out-Null
$destination = Join-Path $state ('baseline-' + [Guid]::NewGuid().ToString('N') + '.json')
$json = $report | ConvertTo-Json -Depth 12
[IO.File]::WriteAllText($destination, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
Write-Output $json
Write-Output "Saved baseline report: $destination"
if (-not $report.pinMatches) { exit 2 }
if ($report.Contains('observedVersionMatches') -and -not $report.observedVersionMatches) { exit 2 }
foreach ($step in $report.commands) {
    if ($step.exitCode -ne 0) { exit 2 }
}
