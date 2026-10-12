<#
.SYNOPSIS
    Records an acceptance-case observation inside the declared Linux execution
    environment (ADR-0001).

.DESCRIPTION
    The pack recorder must observe the platform it claims. This wrapper runs the
    recorder *inside* the WSL2 guest, so `actualPlatform` is genuinely
    linux-x86_64, while the evidence files are written into this Windows
    checkout through the pack path. The guest workspace is the Mutagen mirror
    (ADR-0002) and compilation happens on guest-native storage.

    Use this only for cases whose platform role is a linux-* role. Windows and
    portable cases keep using scripts/test.ps1 on the host.

.PARAMETER Case
    Acceptance case identifier, for example STRICT-001.

.PARAMETER Stage
    Recorder stage: characterize, fault, green, or regression.

.PARAMETER Filter
    Test-name filter passed to the guest test loop. Defaults to the case id.

.PARAMETER GuestRepo
    Guest workspace path (eventually the M12 snapshot path).

.PARAMETER Distro
    WSL distribution name.

.EXAMPLE
    .\scripts\wsl-evidence.ps1 -Case PLAT-003 -Stage characterize
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

if (-not $TestId) { $TestId = $Case }
if (-not $Filter) { $Filter = $Case }

# The payload runs inside the guest: the recorder process, the workspace, and
# the compiler are all Linux, so the observed platform is real.
$payload = @"
set -eu
cd $GuestRepo
python3 $Kit/tools/delivery.py run \
  --case $Case \
  --stage $Stage \
  --test-id "$TestId" \
  --marker "JCKG_EVIDENCE $Case" \
  --cwd . \
  -- sh scripts/test.sh $Filter
"@

& wsl.exe -d $Distro -- bash -lc $payload
exit $LASTEXITCODE
