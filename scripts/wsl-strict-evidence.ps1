<#
.SYNOPSIS
    Records a strict-execution acceptance-case observation inside the declared
    Linux execution environment (ADR-0001).

.DESCRIPTION
    The counterpart of scripts/wsl-evidence.ps1 for the sandbox cases (M08
    STRICT-*). Those cases only mean something where namespaces can actually be
    created, so the recorder runs in the guest and the suite starts the real
    worker under real `unshare` namespaces.

    The suite has its own build step and its own cache directory, so a strict run
    neither waits on nor disturbs a normal guest test run.

.PARAMETER Case
    Acceptance case identifier, for example STRICT-001.

.PARAMETER Stage
    Recorder stage: characterize, fault, green, or regression.

.PARAMETER Filter
    Test-name filter passed to the guest suite. Defaults to the case id.

.EXAMPLE
    .\scripts\wsl-strict-evidence.ps1 -Case STRICT-001 -Stage characterize
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Case,
    [Parameter(Mandatory = $true)][ValidateSet('red', 'green', 'characterize', 'fault', 'regression')][string] $Stage,
    [string] $TestId,
    [string] $Filter,
    [string] $GuestRepo = '~/jckg/dev',
    [string] $Distro = 'Ubuntu',
    [string] $Kit = '/mnt/c/src/jackage/.jackage-delivery'
)

$ErrorActionPreference = 'Stop'

# The test id and filter must be given literally: the payload is interpolated, so
# a value containing shell metacharacters would change what runs.
foreach ($value in @($Case, $Stage, $TestId, $Filter, $GuestRepo, $Distro)) {
    if ($value -and $value -match '[^\w\.\-/ ~+]') {
        throw "refusing to interpolate unsafe value: $value"
    }
}

if (-not $TestId) { $TestId = $Case }
if (-not $Filter) { $Filter = $Case }

$payload = @"
set -eu
cd $GuestRepo
python3 $Kit/tools/delivery.py run \
  --case $Case \
  --stage $Stage \
  --test-id "$TestId" \
  --marker "JCKG_EVIDENCE $Case" \
  --cwd . \
  -- sh scripts/strict-test.sh $Filter
"@

& wsl.exe -d $Distro -- bash -lc $payload
exit $LASTEXITCODE
