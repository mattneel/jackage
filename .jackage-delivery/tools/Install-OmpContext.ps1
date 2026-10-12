#requires -Version 5.1
<#
.SYNOPSIS
Creates new OMP context files without replacing existing project context.
.DESCRIPTION
Review this script before execution. It refuses known existing context paths.
No provider settings, source files, or toolchain files change.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$kit = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$root = [IO.Path]::GetFullPath((Join-Path $kit '..'))
$existingContextPaths = @(
    '.omp', 'AGENTS.md', 'CLAUDE.md', 'GEMINI.md',
    '.claude/CLAUDE.md', '.agent/AGENTS.md', '.agents/AGENTS.md',
    '.github/copilot-instructions.md', '.github/instructions'
)
foreach ($relative in $existingContextPaths) {
    if (Test-Path -LiteralPath (Join-Path $root $relative)) {
        throw "Existing project context: $relative. Merge the supplied templates manually."
    }
}
foreach ($name in @('AGENTS.md', 'RULES.md')) {
    if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $kit 'omp') $name) -PathType Leaf)) {
        throw "Missing OMP template: $name"
    }
}
$state = Join-Path $kit 'state'
[IO.Directory]::CreateDirectory($state) | Out-Null
$stage = Join-Path $state ('context-stage-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($stage) | Out-Null
foreach ($name in @('AGENTS.md', 'RULES.md')) {
    [IO.File]::Copy((Join-Path (Join-Path $kit 'omp') $name), (Join-Path $stage $name), $false)
}
# Directory.Move refuses an existing destination. A concurrent creation remains safe.
[IO.Directory]::Move($stage, (Join-Path $root '.omp'))
Write-Output 'Created .omp/AGENTS.md and .omp/RULES.md. Restart OMP to load the context.'
