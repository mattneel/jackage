# Read-only host capability inventory for the M00 audit. Performs no mutation.
# Emits a single JSON object on stdout.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

function Probe([string]$Name, [scriptblock]$Body) {
    try { return @{ status = 'ok'; value = (& $Body) } }
    catch { return @{ status = 'unavailable'; value = $null; error = $_.Exception.Message } }
}

function CommandPath([string]$Name) {
    $c = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $c) { return $null }
    return $c.Source
}

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1

$report = [ordered]@{
    probeUtc = (Get-Date).ToUniversalTime().ToString('o')
    os = [ordered]@{
        caption = $os.Caption
        version = $os.Version
        buildNumber = $os.BuildNumber
        architecture = $os.OSArchitecture
        installDate = $os.InstallDate
    }
    host = [ordered]@{
        manufacturer = $cs.Manufacturer
        model = $cs.Model
        logicalProcessors = $cs.NumberOfLogicalProcessors
        physicalMemoryBytes = [int64]$cs.TotalPhysicalMemory
        processorName = $cpu.Name
        processorArchitecture = $env:PROCESSOR_ARCHITECTURE
        processorIdentifier = $env:PROCESSOR_IDENTIFIER
    }
    powershell = $PSVersionTable.PSVersion.ToString()
    dotnet = $PSVersionTable.CLRVersion
    environment = [ordered]@{
        systemRoot = $env:SystemRoot
        temp = $env:TEMP
        userProfilePresent = [bool]$env:USERPROFILE
        pathSeparator = [System.IO.Path]::PathSeparator
        caseSensitiveFs = (Get-Command Get-ChildItem) -and $false
    }
    volumes = @(
        foreach ($v in Get-Volume | Where-Object { $null -ne $v.DriveLetter }) {
            [ordered]@{
                drive = $v.DriveLetter
                fileSystem = $v.FileSystem
                sizeBytes = [int64]($v.Size)
                freeBytes = [int64]($v.SizeRemaining)
                driveType = "$($v.DriveType)"
            }
        }
    )
    tools = [ordered]@{}
    wsl = [ordered]@{}
    virtualization = [ordered]@{}
    sdk = [ordered]@{}
    linuxToolchains = [ordered]@{}
    reparseAndLongPath = [ordered]@{}
}

$toolNames = @(
    'git', 'python', 'python3', 'py', 'pwsh', 'powershell', 'node', 'npm', 'bun', 'deno',
    'clang', 'clang-cl', 'cl', 'link', 'cmake', 'ninja', 'make', 'gcc', 'ld',
    'curl', 'tar', '7z', 'gpg', 'openssl', 'signtool', 'makensis', 'dpkg-deb', 'rpmbuild',
    'qemu-system-x86_64', 'icacls', 'msiexec', 'docker', 'podman', 'ssh', 'ssh-keygen',
    'rustc', 'cargo', 'go', 'java', 'wix'
)
foreach ($t in $toolNames) {
    $p = CommandPath $t
    $ver = $null
    if ($p) {
        $ver = Probe $t {
            switch -Regex ($t) {
                '^git$' { (& git --version) -join ' ' }
                '^python|^py$' { (& $t --version 2>&1) -join ' ' }
                '^node$|^npm$|^bun$|^deno$' { (& $t --version 2>&1) -join ' ' }
                '^clang|^clang-cl$' { (& $t --version 2>&1 | Select-Object -First 1) -join ' ' }
                '^cmake$' { (& cmake --version | Select-Object -First 1) -join ' ' }
                '^rustc$|^cargo$' { (& $t --version) -join ' ' }
                '^go$' { (& go version) -join ' ' }
                '^java$' { (& java -version 2>&1 | Select-Object -First 1) -join ' ' }
                '^qemu-system-x86_64$' { (& $t --version | Select-Object -First 1) -join ' ' }
                '^docker$|^podman$' { (& $t --version) -join ' ' }
                default { $null }
            }
        }
    }
    $report.tools[$t] = if ($p) { @{ present = $true; path = $p; version = $ver.value } } else { @{ present = $false } }
}

# Visual Studio / MSVC build tools discovery (presence only, no mutation).
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path -LiteralPath $vswhere) {
    $report.sdk.microsoftVisualStudio = Probe 'vswhere' {
        @(& $vswhere -latest -products * -format json | ConvertFrom-Json | Select-Object -First 1)
    }
} else {
    $report.sdk.microsoftVisualStudio = @{ status = 'unavailable'; value = $null; error = 'vswhere.exe not found' }
}
$report.sdk.windowsKits = Probe 'kits' {
    Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Include' -ErrorAction Stop |
        Select-Object -ExpandProperty Name
}

# WSL state: read-only enumeration only. No distribution is started or modified.
$report.wsl.executable = CommandPath 'wsl'
if ($report.wsl.executable) {
    $report.wsl.distributions = Probe 'wsl-l' {
        $raw = (& wsl.exe --list --verbose 2>&1) -join "`n"
        # wsl.exe writes UTF-16LE; strip NULs and whitespace for a stable record.
        ($raw -replace "`0", '')
    }
    $report.wsl.status = Probe 'wsl-status' {
        $raw = (& wsl.exe --status 2>&1) -join "`n"
        ($raw -replace "`0", '')
    }
} else {
    $report.wsl.distributions = @{ status = 'unavailable'; value = $null; error = 'wsl.exe not found' }
}

$report.virtualization = Probe 'virtualization' {
    $hv = Get-CimInstance Win32_ComputerSystem
    [ordered]@{
        hypervisorPresent = [bool]$hv.HypervisorPresent
        features = @(Get-CimInstance -ClassName Win32_OptionalFeature -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -in @('Microsoft-Hyper-V-All','VirtualMachinePlatform','Microsoft-Windows-Subsystem-Linux','HypervisorPlatform','Containers-DisposableClientVM') } |
            Select-Object Name, InstallState)
    }
}

# Windows path semantics probes (read-only, on a disposable temp directory).
$report.reparseAndLongPath = Probe 'path-semantics' {
    $tmp = Join-Path $env:TEMP ('jackage-probe-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $longDir = $tmp
        for ($i = 0; $i -lt 12; $i++) { $longDir = Join-Path $longDir ('directory-with-a-fairly-long-name-' + $i) }
        New-Item -ItemType Directory -Path $longDir -Force | Out-Null
        $longPathFile = Join-Path $longDir 'payload.bin'
        Set-Content -LiteralPath $longPathFile -Value 'x' -NoNewline
        $longPathOk = Test-Path -LiteralPath $longPathFile
        $longPathLength = $longPathFile.Length

        $caseProbe = Join-Path $tmp 'CaseProbe'
        Set-Content -LiteralPath $caseProbe -Value 'x' -NoNewline
        $caseInsensitive = Test-Path -LiteralPath (Join-Path $tmp 'caseprobe')

        $adsOk = $false
        try {
            Set-Content -LiteralPath ($caseProbe + ':jckgtest') -Value 'y' -Stream 'jckgtest' -ErrorAction Stop
            $adsOk = $true
        } catch { $adsOk = $false }

        [ordered]@{
            longPathCreated = $longPathOk
            longPathCharacters = $longPathLength
            caseInsensitiveLookup = $caseInsensitive
            alternateDataStreamWritable = $adsOk
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$report | ConvertTo-Json -Depth 8
