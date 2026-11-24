# Build-WinISOUpdated.ps1
# One-shot, restartable build of an updated Windows 10/11 ISO:
#
#   1. mount the source ISO and copy its media to a work folder
#   2. export the requested image indexes into sources\install.wim
#   3. mount each index and add the supplied cumulative/.NET packages
#   4. add the de-duplicated driver set (install.wim and, optionally, boot.wim)
#   5. commit the images, then rebuild a bootable ISO with oscdimg
#   6. write the ISO hashes, a per-file media manifest and a JSON report
#
# Every stage is logged with a timestamp to -LogFile, State\BUILD-STATUS.json is
# rewritten between stages, and State\BUILD-CHECKPOINT.json records finished
# stages so -Resume can continue a run that died (for example during oscdimg).
#
# Requires : an elevated PowerShell session (DISM image servicing).
# Platform : Windows PowerShell 5.1 and PowerShell 7. ASCII-only, BOM-less UTF-8.
#
# Exit codes : 0 = ISO produced, 1 = failure, 2 = pre-flight/DryRun problem.
#
# Examples:
#   .\Build-WinISOUpdated.ps1 -DryRun
#   .\Build-WinISOUpdated.ps1 -SourceIso D:\Win11.iso -Index 6 -Drivers D:\WimMount\Drivers `
#       -Packages D:\WimMount\Updates\cu.msu,D:\WimMount\Updates\ndp.msu
#   .\Build-WinISOUpdated.ps1 -SourceIso D:\Win11.iso -Indexes 1,6 -ExpectModernStorage -SignedDriversOnly
#   .\Build-WinISOUpdated.ps1 -SourceIso D:\Win11.iso -Resume
#   .\Build-WinISOUpdated.ps1 -SourceIso D:\Win11.iso -KeepBuilds 3 -PruneLogsDays 30 -PruneApply

[CmdletBinding()]
param(
    [string]$SourceIso = 'D:\Windows11_Client_x64_en-us_26300_9457.iso',
    [string]$Workspace = 'D:\WimMount',
    [ValidateRange(1, 99)][int]$Index = 6,
    [int[]]$Indexes = @(),
    [string]$Drivers = '',
    [switch]$SignedDriversOnly,
    [switch]$ExpectModernStorage,
    [string[]]$Packages = @(),
    [string]$UpdatesDir = '',
    [string]$OutDir = '',
    [string]$WorkDir = '',
    [string]$OutputName = '',
    [string]$Oscdimg = '',
    [switch]$SkipDrivers,
    [switch]$SkipPackages,
    [switch]$SkipBootWim,
    [ValidateRange(1, 9)][int]$BootWimIndex = 2,
    [switch]$StartComponentCleanup,
    [switch]$ResetBase,
    [string[]]$Capabilities = @(),
    [string[]]$OptionalFeatures = @(),
    [string[]]$RemoveAppx = @(),
    [string]$CapabilitySource = '',
    [switch]$ScanHealth,
    [switch]$Esd,
    [string]$Profile = '',
    [switch]$SaveProfile,
    [switch]$SkipManifestVerify,
    [switch]$NoReleaseLookup,
    [switch]$SkipMediaManifest,
    [switch]$QuickMediaManifest,
    [switch]$Resume,
    [switch]$CleanupStaleMounts,
    [switch]$NoLock,
    [int]$KeepBuilds = 0,
    [int]$PruneLogsDays = 0,
    [switch]$PruneApply,
    [switch]$VerifyOnly,
    [switch]$KeepWork,
    [switch]$Force,
    [int]$MinimumFreeGB = 30,
    [switch]$DryRun,
    [switch]$SelfTest
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$script:Dism = Join-Path $env:SystemRoot 'System32\Dism.exe'
$script:MinFreeGB = $MinimumFreeGB
$script:Log = ''
$script:StatusPath = ''
$script:DismLog = ''
$script:StartedUtc = [DateTime]::UtcNow
$script:CheckpointPath = ''
$script:LockPath = ''
$script:Stages = @()
$script:ServicedIndexes = @()

$modulePath = Join-Path $PSScriptRoot 'WinISOIntegrity.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw ('Required module not found: ' + $modulePath) }
Import-Module -Name $modulePath -Force -ErrorAction Stop
$tasksPath = Join-Path $PSScriptRoot 'WinISOBuildTasks.psm1'
if (-not (Test-Path -LiteralPath $tasksPath)) { throw ('Required module not found: ' + $tasksPath) }
Import-Module -Name $tasksPath -Force -ErrorAction Stop

# --------------------------------------------------------------------------
# logging helpers
# --------------------------------------------------------------------------
function Write-Stage {
    param([string]$Message)
    $ts = Get-Date -Format 'HH:mm:ss'
    $line = ('[' + $ts + '] ' + $Message)
    Write-Host $line
    if ($script:Log) { Add-Content -LiteralPath $script:Log -Value $line -Encoding UTF8 }
}

function Write-BuildStatus {
    param([string]$Stage, [int]$Percent, [string]$Detail = '', [string]$State = 'running')
    if (-not $script:StatusPath) { return }
    $obj = [ordered]@{
        stage   = $Stage
        percent = $Percent
        state   = $State
        detail  = $Detail
        updated = (Get-Date -Format 'o')
        pid     = $PID
    }
    try {
        [System.IO.File]::WriteAllText($script:StatusPath, ($obj | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
}

function Save-Checkpoint {
    param([string]$Stage = '', [switch]$MediaReady, [switch]$Exported)
    if (-not $script:CheckpointPath) { return }
    [void](Save-WinISOBuildCheckpoint -Path $script:CheckpointPath -Stages $script:Stages -IndexesServiced $script:ServicedIndexes `
        -MediaReady:$MediaReady -Exported:$Exported -SourceIso $SourceIso -Stage $Stage)
}

function Complete-Stage {
    param([string]$Name, [switch]$MediaReady, [switch]$Exported)
    if ($script:Stages -notcontains $Name) { $script:Stages += $Name }
    Save-Checkpoint -Stage $Name -MediaReady:$MediaReady -Exported:$Exported
}

function Invoke-Dism {
    param([string[]]$Arguments)
    $callArgs = @($Arguments)
    if ($script:DismLog -and -not (@($callArgs | Where-Object { ([string]$_) -like '/LogPath:*' }).Count -gt 0)) {
        $callArgs += ('/LogPath:' + $script:DismLog)
    }
    $out = & $script:Dism @callArgs 2>&1 | Out-String
    $code = $LASTEXITCODE
    if ($script:Log) { Add-Content -LiteralPath $script:Log -Value ($out.TrimEnd()) -Encoding UTF8 }
    return [pscustomobject]@{ Code = $code; Text = $out }
}

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FreeGB {
    param([string]$Path)
    $p = [System.IO.Path]::GetFullPath($Path)
    while ($p -and -not (Test-Path -LiteralPath $p)) { $p = Split-Path -Parent $p }
    $drive = (Get-Item -LiteralPath $p).PSDrive
    if (-not $drive) { $drive = Get-PSDrive -Name ($p.Substring(0, 1)) }
    return [math]::Round($drive.Free / 1GB, 1)
}

function Find-Oscdimg {
    $candidates = @(
        'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\OSCDIMG\oscdimg.exe',
        'C:\Program Files\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\OSCDIMG\oscdimg.exe',
        (Join-Path $env:ProgramFiles 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\OSCDIMG\oscdimg.exe')
    )
    if ($env:ProgramFilesX86 -and $env:ProgramFilesX86 -ne $env:ProgramFiles) {
        $candidates += (Join-Path $env:ProgramFilesX86 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\OSCDIMG\oscdimg.exe')
    }
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return ''
}

# Parse "Index : 1 / Name : ... / Architecture : x64 / Size : ..." from DISM.
function ConvertFrom-DismImageInfo {
    param([string]$Text)
    $images = @()
    $cur = $null
    foreach ($raw in ($Text -split "`r?`n")) {
        $line = $raw.Trim()
        if ($line -match '^Index\s*:\s*(\d+)$') {
            if ($cur) { $images += $cur }
            $cur = @{ index = [int]$Matches[1]; name = ''; description = ''; architecture = ''; size = 0 }
            continue
        }
        if (-not $cur) { continue }
        if ($line -match '^Name\s*:\s*(.+)$') { $cur.name = $Matches[1].Trim() }
        elseif ($line -match '^Architecture\s*:\s*(.+)$') { $cur.architecture = $Matches[1].Trim() }
        elseif ($line -match '^Description\s*:\s*(.+)$') { $cur.description = $Matches[1].Trim() }
        elseif ($line -match '^Size\s*:\s*([\d,]+)\s*bytes') { $cur.size = [long]($Matches[1] -replace ',', '') }
    }
    if ($cur) { $images += $cur }
    return $images
}

function Get-DismLevel {
    param([string]$Text)
    $b = 0; $r = 0
    $m = [regex]::Match($Text, '(?im)^\s*Version\s*:\s*10\.0\.(\d+)')
    if ($m.Success) { $b = [int]$m.Groups[1].Value }
    $m2 = [regex]::Match($Text, '(?im)^\s*ServicePack Build\s*:\s*(\d+)')
    if ($m2.Success) { $r = [int]$m2.Groups[1].Value }
    return @{ Build = $b; Revision = $r }
}

function Get-KbFromName {
    param([string]$Name)
    $m = [regex]::Match([string]$Name, '(?i)kb(\d{6,8})')
    if ($m.Success) { return ('KB' + $m.Groups[1].Value) }
    return ''
}

# Pick the newest cumulative update and the newest .NET cumulative update from a
# folder when no explicit -Packages were given.
function Resolve-AutoPackages {
    param([string]$Dir)
    $all = @(Get-ChildItem -LiteralPath $Dir -File -Filter *.msu -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) { return @() }
    $dotnet = @($all | Where-Object { $_.Name -match '(?i)-ndp\d+' -or $_.Name -match '(?i)\.net' } | Sort-Object LastWriteTime -Descending)
    $ssu = @($all | Where-Object { $_.Name -match '(?i)-ssu|servicing\s*stack' } | Sort-Object LastWriteTime -Descending)
    $cumulative = @($all | Where-Object { $_.Name -notmatch '(?i)-ndp\d+' -and $_.Name -notmatch '(?i)-ssu|servicing\s*stack' } | Sort-Object LastWriteTime -Descending)
    $picked = @()
    if ($ssu.Count -gt 0) { $picked += $ssu[0].FullName }
    if ($cumulative.Count -gt 0) { $picked += $cumulative[0].FullName }
    if ($dotnet.Count -gt 0) { $picked += $dotnet[0].FullName }
    return @(Get-WinISOPackageOrder -Packages $picked | ForEach-Object { $_.Package })
}

# --------------------------------------------------------------------------
# self test (no elevation, no DISM, no ISO required)
# --------------------------------------------------------------------------
function Invoke-BuildSelfTest {
    $problems = @()

    if ((Get-KbFromName -Name 'windows11.0-kb5127648-x64_2b88d2d3.msu') -ne 'KB5127648') { $problems += 'KB extraction from a catalog file name failed' }
    if ((Get-KbFromName -Name 'something.msu') -ne '') { $problems += 'KB extraction should return empty without a KB number' }

    $sample = @'
Deployment Image Servicing and Management tool

Details for image : D:\media\sources\install.wim

Index : 1
Name : Windows 11 Home
Description : Windows 11 Home
Architecture : x64
Size : 25,730,139,683 bytes

Index : 6
Name : Windows 11 Pro
Description : Windows 11 Pro
Architecture : x64
Size : 26,770,709,765 bytes

'@
    $imgs = @(ConvertFrom-DismImageInfo -Text $sample)
    if ($imgs.Count -ne 2) { $problems += ('image-info parser expected 2 indexes, got ' + $imgs.Count) }
    elseif ($imgs[1].index -ne 6) { $problems += 'image-info parser lost index 6' }
    elseif ($imgs[1].name -ne 'Windows 11 Pro') { $problems += ('image-info parser lost the edition name (got ' + $imgs[1].name + ')') }
    elseif ($imgs[1].architecture -ne 'x64') { $problems += 'image-info parser lost the architecture' }

    $lvl = Get-DismLevel -Text "`nVersion : 10.0.26300`nServicePack Build : 9711`n"
    if ($lvl.Build -ne 26300) { $problems += ('build parse failed (got ' + $lvl.Build + ')') }
    if ($lvl.Revision -ne 9711) { $problems += ('revision parse failed (got ' + $lvl.Revision + ')') }

    # Output naming: family + edition + build level, lower case and unseparated.
    $name11 = New-WinISOOutputName -EditionName 'Windows 11 Pro' -Build 26300 -Revision 10075 -Architecture 'x64'
    if ($name11 -ne 'windows11pro26300.10075.iso') { $problems += ('Windows 11 Pro output naming is wrong: ' + $name11) }
    $name10 = New-WinISOOutputName -EditionName 'Windows 10 Pro' -Build 19045 -Revision 3803 -Architecture 'x64'
    if ($name10 -ne 'windows10pro19045.3803.iso') { $problems += ('Windows 10 Pro output naming is wrong: ' + $name10) }
    $nameEnt = New-WinISOOutputName -EditionName 'Windows 11 Enterprise' -Build 26100 -Revision 1742 -Architecture 'amd64'
    if ($nameEnt -ne 'windows11enterprise26100.1742.iso') { $problems += ('Enterprise output naming is wrong: ' + $nameEnt) }
    $nameArm = New-WinISOOutputName -EditionName 'Windows 11 Pro' -Build 26100 -Revision 1 -Architecture 'arm64'
    if ($nameArm -ne 'windows11pro26100.1.arm64.iso') { $problems += ('arm64 output naming is wrong: ' + $nameArm) }

    # Release page parsing: newest level per base build wins, with its KB.
    $pageSample = '<table>' +
        '<tr><td>General Availability Channel</td><td>2026-11 D</td><td>2026-11-19</td><td>26300.10075</td><td><a href="x">KB5132057</a></td></tr>' +
        '<tr><td>General Availability Channel</td><td>2026-11 B</td><td>2026-11-10</td><td>26300.9974</td><td><a href="y">KB5132061</a></td></tr>' +
        '<tr><td>General Availability Channel</td><td>2026-10 B</td><td>2026-10-13</td><td>26100.9711</td><td><a href="z">KB5127648</a></td></tr>' +
        '</table>'
    $rel = Get-WinISOReleaseBuild -Family 'Windows 11' -BaseBuild 26300 -Content $pageSample
    if (-not $rel.Ok) { $problems += ('release page parser failed: ' + $rel.Error) }
    elseif ($rel.Build -ne 26300 -or $rel.Revision -ne 10075 -or $rel.Kb -ne 'KB5132057') {
        $problems += ('release page parser returned ' + $rel.Build + '.' + $rel.Revision + ' ' + $rel.Kb + ' (expected 26300.10075 KB5132057)')
    }
    $rel24 = Get-WinISOReleaseBuild -Family 'Windows 11' -BaseBuild 26100 -Content $pageSample
    if ($rel24.Build -ne 26100 -or $rel24.Revision -ne 9711) { $problems += ('release page parser ignored the base build filter: ' + $rel24.Build + '.' + $rel24.Revision) }

    # Boot data: x64 needs both loaders, arm64 only UEFI.
    $bd = Get-WinISOIsoBootData -Architecture 'x64' -EtfsbootPath 'C:\m\boot\etfsboot.com' -EfisysPath 'C:\m\efi\efisys.bin' -EtfsbootExists -EfisysExists
    if ($bd.BootData -ne '-bootdata:2#p0,e,bC:\m\boot\etfsboot.com#pEF,e,bC:\m\efi\efisys.bin') { $problems += 'x64 boot data is wrong' }
    $bdArm = Get-WinISOIsoBootData -Architecture 'arm64' -EtfsbootPath 'C:\m\boot\etfsboot.com' -EfisysPath 'C:\m\efi\efisys.bin' -EfisysExists
    if ($bdArm.BootData -notmatch '^-bootdata:1#pEF') { $problems += 'arm64 boot data must be UEFI-only' }
    $bdMissing = Get-WinISOIsoBootData -Architecture 'x64' -EtfsbootPath 'C:\m\boot\etfsboot.com' -EfisysPath 'C:\m\efi\efisys.bin' -EfisysExists
    if (-not $bdMissing.Error) { $problems += 'missing eftsboot.com was not reported' }

    if (-not (Find-Oscdimg)) { $problems += 'oscdimg.exe was not found' }

    if ($problems.Count -gt 0) {
        Write-Host 'SELFTEST FAILED:'
        foreach ($p in $problems) { Write-Host ('  - ' + $p) }
        exit 2
    }
    Write-Host 'SELFTEST OK: KB extraction, DISM image-info and build parsing, Windows 10/11 and arm64 naming, per-architecture boot data, oscdimg discovery.'
    exit 0
}

if ($SelfTest) { Invoke-BuildSelfTest }

# --------------------------------------------------------------------------
# build profile (State\BuildProfile.json): reproduce a run, hand it to the GUI
# --------------------------------------------------------------------------
if ($Profile) {
    $profileValues = Read-WinISOProfile -Path $Profile
    foreach ($key in @($profileValues.Keys)) {
        $value = $profileValues[$key]
        switch ([string]$key) {
            'workspace' { if ($Workspace -eq 'D:\WimMount') { $Workspace = [string]$value } }
            'source_iso' { if ($SourceIso -eq 'D:\Windows11_Client_x64_en-us_26300_9457.iso') { $SourceIso = [string]$value } }
            'edition_index' { if ($Index -eq 6 -and $null -ne $value) { $Index = [int]$value } }
            'drivers' { if (-not $Drivers -and $value) { $Drivers = [string]$value } }
            'output_name' { if (-not $OutputName -and $value) { $OutputName = [string]$value } }
            'run_cleanup' { if (-not $StartComponentCleanup -and $value) { $StartComponentCleanup = [switch]$true } }
            'scan_health' { if (-not $ScanHealth -and $value) { $ScanHealth = [switch]$true } }
            'esd' { if (-not $Esd -and $value) { $Esd = [switch]$true } }
            'capabilities' { if (@($Capabilities).Count -eq 0 -and $value) { $Capabilities = @($value) } }
            'optional_features' { if (@($OptionalFeatures).Count -eq 0 -and $value) { $OptionalFeatures = @($value) } }
            'remove_appx' { if (@($RemoveAppx).Count -eq 0 -and $value) { $RemoveAppx = @($value) } }
            'capability_source' { if (-not $CapabilitySource -and $value) { $CapabilitySource = [string]$value } }
        }
    }
}

$indexList = @()
if (@($Indexes).Count -gt 0) { $indexList = @($Indexes | ForEach-Object { [int]$_ } | Sort-Object -Unique) }
else { $indexList = @($Index) }

# --------------------------------------------------------------------------
# pre-flight
# --------------------------------------------------------------------------
$ws = [System.IO.Path]::GetFullPath($Workspace)
if (-not $OutDir) { $OutDir = Join-Path $ws 'Output' }
if (-not $WorkDir) { $WorkDir = Join-Path $ws 'Work' }
if (-not $UpdatesDir) { $UpdatesDir = Join-Path $ws 'Updates' }
$logDir = Join-Path $ws 'Logs'
$stateDir = Join-Path $ws 'State'
$reportsDir = Join-Path $ws 'Reports'
foreach ($d in @($OutDir, $WorkDir, $logDir, $stateDir, $reportsDir)) {
    if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
}
$script:Log = Join-Path $logDir ('build-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
$script:DismLog = Join-Path $logDir ('dism-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
$script:StatusPath = Join-Path $stateDir 'BUILD-STATUS.json'
$script:CheckpointPath = Join-Path $stateDir 'BUILD-CHECKPOINT.json'
$script:LockPath = Join-Path $stateDir 'BUILD-LOCK.json'

Write-BuildStatus -Stage 'preflight' -Percent 0
Write-Stage ('Build-WinISOUpdated starting. log=' + $script:Log)
Write-Stage ('Source ISO : ' + $SourceIso)
Write-Stage ('Indexes    : ' + ($indexList -join ', '))
Write-Stage ('Workspace  : ' + $ws)

$problems = @()
if (-not (Test-Path -LiteralPath $SourceIso)) { $problems += ('Source ISO not found: ' + $SourceIso) }
if (-not (Test-Path -LiteralPath $script:Dism)) { $problems += ('dism.exe not found: ' + $script:Dism) }

if (-not $Oscdimg) { $Oscdimg = Find-Oscdimg }
if (-not $Oscdimg) {
    $problems += 'oscdimg.exe not found'
    foreach ($line in ((Get-WinISOAdkGuidanceText) -split "`r?`n")) { Write-Stage ('  ' + $line) }
}
else { Write-Stage ('oscdimg    : ' + $Oscdimg) }

# --- single-instance lock -------------------------------------------------
$lockHeld = $false
if (-not $NoLock -and -not $DryRun -and -not $VerifyOnly) {
    $existingLock = Get-WinISOBuildLock -Path $script:LockPath
    if ($existingLock -and $existingLock.Alive -and $existingLock.Pid -ne $PID) {
        $problems += ('Another build is already running in this workspace (pid ' + $existingLock.Pid + ', stage ' + $existingLock.Stage + '). Wait for it to finish, or pass -NoLock if you know it is gone.')
    }
    elseif ($existingLock) {
        Write-Stage ('Replacing a stale build lock left by pid ' + $existingLock.Pid + ' (no longer running)')
        [void](New-WinISOBuildLock -Path $script:LockPath -Workspace $ws)
        $lockHeld = $true
    }
    else {
        [void](New-WinISOBuildLock -Path $script:LockPath -Workspace $ws)
        $lockHeld = $true
    }
}

# --- stale mount cleanup --------------------------------------------------
$mounts = @()
if (Test-Path -LiteralPath $script:Dism) {
    $mi = Invoke-Dism -Arguments @('/English', '/Get-MountedImageInfo')
    if ($mi.Code -eq 0) { $mounts = @(ConvertFrom-WinISOMountedImageText -Text $mi.Text) }
}
$stale = @(Get-WinISOStaleMounts -Mounts $mounts -Workspace $ws)
if ($stale.Count -gt 0) {
    Write-Stage ('Found ' + $stale.Count + ' mounted image(s) under the workspace (left by an interrupted run):')
    foreach ($m in $stale) { Write-Stage ('  ' + $m.MountDir + '  index ' + $m.Index + '  ' + $m.ImageFile) }
    if ($CleanupStaleMounts) {
        foreach ($m in $stale) {
            $discard = Invoke-Dism -Arguments @('/English', '/Unmount-Image', ('/MountDir:' + $m.MountDir), '/Discard')
            Write-Stage ('  discarded ' + $m.MountDir + ' (exit ' + $discard.Code + ')')
        }
    }
    else {
        $problems += ('Stale image mount(s) exist under ' + $ws + '. Pass -CleanupStaleMounts to discard them, or the mount in stage 4 will fail.')
    }
}

# --- checkpoint / resume --------------------------------------------------
$checkpoint = Read-WinISOBuildCheckpoint -Path $script:CheckpointPath
$reuseMedia = $false
$reuseExport = $false
if ($Resume) {
    if (-not $checkpoint.Exists) {
        Write-Stage 'Resume requested but State\BUILD-CHECKPOINT.json does not exist; starting from the beginning'
    }
    elseif ($checkpoint.SourceIso -and $checkpoint.SourceIso -ne $SourceIso) {
        Write-Stage ('Resume requested but the checkpoint belongs to ' + $checkpoint.SourceIso + '; starting from the beginning')
    }
    else {
        $script:Stages = @($checkpoint.Stages)
        $script:ServicedIndexes = @($checkpoint.IndexesServiced)
        $reuseMedia = $checkpoint.MediaReady
        $reuseExport = $checkpoint.Exported
        Write-Stage ('Resuming: ' + $script:Stages.Count + ' stage(s) recorded, index(es) already serviced: ' + (($script:ServicedIndexes -join ', ')))
    }
}

$pkgList = @()
if (-not $SkipPackages) {
    if (@($Packages).Count -eq 0) {
        Write-Stage ('Resolving packages from ' + $UpdatesDir)
        $pkgList = @(Resolve-AutoPackages -Dir $UpdatesDir)
        if ($pkgList.Count -eq 0) { $problems += ('No .msu packages found in ' + $UpdatesDir + ' and none supplied with -Packages') }
    }
    else {
        foreach ($p in @($Packages)) {
            if (Test-Path -LiteralPath $p) { $pkgList += (Resolve-Path -LiteralPath $p).Path }
            else { $problems += ('Package not found: ' + $p) }
        }
    }
    foreach ($orderProblem in @(Test-WinISOPackageOrder -Packages $pkgList)) { $problems += $orderProblem }
    $pkgList = @(Get-WinISOPackageOrder -Packages $pkgList | ForEach-Object { $_.Package })
    foreach ($p in $pkgList) {
        $sz = [math]::Round((Get-Item -LiteralPath $p).Length / 1MB, 1)
        Write-Stage ('Package    : ' + $p + '  (' + $sz + ' MB)')
    }
}

$manifestPath = Join-Path $reportsDir 'DOWNLOAD-MANIFEST.json'
if (-not $SkipManifestVerify -and @($pkgList).Count -gt 0) {
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        Write-Stage ('Verifying packages against ' + $manifestPath)
        $payload = Test-WinISOManifestPayload -ManifestPath $manifestPath -DownloadDir $UpdatesDir
        Write-Stage ('  ' + @($payload.Ok).Count + ' of ' + $payload.Checked + ' manifest entr(ies) intact')
        foreach ($m in @($payload.Mismatched)) {
            $problems += ('Package ' + $m.File + ' does not match DOWNLOAD-MANIFEST.json (' + $m.Reason + '); re-download it')
        }
    }
    else {
        Write-Stage 'No download manifest yet; package hashes cannot be checked (run Get-WinISOUpdates.ps1 to create Reports\DOWNLOAD-MANIFEST.json)'
    }
}

# --- drivers: inventory, de-duplicate, sign filter, storage coverage ------
$driverUnique = @()
$driverInventory = $null
$driverSelection = $null
$storageCoverage = $null
if (-not $SkipDrivers) {
    if (-not $Drivers) { $problems += 'No -Drivers folder given (use -SkipDrivers to build without drivers)' }
    elseif (-not (Test-Path -LiteralPath $Drivers)) { $problems += ('Drivers folder not found: ' + $Drivers) }
    else {
        Write-Stage ('Drivers    : ' + $Drivers + ' (building inventory...)')
        $driverInventory = @(Get-WinISODriverInventory -Drivers $Drivers -SignedOnly:$SignedDriversOnly)
        Write-Stage ('  ' + $driverInventory.Count + ' driver INF(s)' + $(if ($SignedDriversOnly) { ' with a valid catalog signature' } else { '' }))
        if ($driverInventory.Count -eq 0) { $problems += ('No usable .inf files under ' + $Drivers + $(if ($SignedDriversOnly) { ' (every package was unsigned; drop -SignedDriversOnly to include them)' } else { '' })) }
        $driverSelection = Select-WinISOUniqueDrivers -Inventory $driverInventory
        $driverUnique = @($driverSelection.Unique | ForEach-Object { [string]$_.Inf })
        Write-Stage ('  unique packages: ' + @($driverUnique).Count + ', duplicate copies: ' + @($driverSelection.Duplicates).Count + ', conflicts: ' + @($driverSelection.Conflicts).Count)
        foreach ($c in @($driverSelection.Conflicts)) { Write-Stage ('  CONFLICT: ' + $c.Kept + ' kept, ' + $c.Ignored + ' ignored (' + $c.Reason + ')') }

        $storageCoverage = Test-WinISOStorageDriverCoverage -Drivers $Drivers -RequireModernStorage:$ExpectModernStorage
        foreach ($e in @($storageCoverage.Evidence)) { Write-Stage ('  storage driver: ' + $e.Token + ' in ' + $e.Inf) }
        foreach ($w in @($storageCoverage.Warnings)) { Write-Stage ('  WARNING: ' + $w) }

        $invPath = Join-Path $reportsDir 'DRIVER-INVENTORY.json'
        $invDoc = [ordered]@{
            generated_utc      = [DateTime]::UtcNow.ToString('o')
            source             = [System.IO.Path]::GetFullPath($Drivers)
            signed_only        = [bool]$SignedDriversOnly
            inf_count          = $driverInventory.Count
            unique_count       = @($driverUnique).Count
            drivers            = @($driverInventory)
            duplicates         = @($driverSelection.Duplicates)
            conflicts          = @($driverSelection.Conflicts)
            storage_evidence   = @($storageCoverage.Evidence)
            storage_warnings   = @($storageCoverage.Warnings)
        }
        [System.IO.File]::WriteAllText($invPath, ($invDoc | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
        Write-Stage ('  driver inventory: ' + $invPath)
    }
}

$freeWork = 0
try { $freeWork = Get-FreeGB -Path $WorkDir } catch { $problems += ('Cannot determine free space for ' + $WorkDir) }
Write-Stage ('Free space : ' + $freeWork + ' GB on ' + (Split-Path -Qualifier $WorkDir))
if ($freeWork -gt 0 -and $freeWork -lt $script:MinFreeGB) {
    $problems += ('Only ' + $freeWork + ' GB free on the work volume; at least ' + $script:MinFreeGB + ' GB is required')
}

$elevated = Test-Elevated
Write-Stage ('Elevated   : ' + $elevated)
if (-not $elevated -and -not $DryRun) { $problems += 'DISM image servicing requires an elevated session. Re-run this script as administrator.' }

if ($problems.Count -gt 0) {
    Write-Stage 'PRE-FLIGHT FAILED:'
    foreach ($p in $problems) { Write-Stage ('  - ' + $p) }
    Write-BuildStatus -Stage 'preflight' -Percent 0 -Detail ($problems -join ' | ') -State 'failed'
    if ($lockHeld) { [void](Remove-WinISOBuildLock -Path $script:LockPath) }
    exit 2
}

if ($VerifyOnly) {
    Write-Stage 'VERIFY ONLY - inputs, package hashes, package order, drivers and prerequisites checked; no image was mounted or modified.'
    Write-Stage ('Verified ' + @($pkgList).Count + ' package(s) and ' + @($driverUnique).Count + ' unique driver(s) for index(es) ' + ($indexList -join ', ') + ' of ' + $SourceIso)
    if ($lockHeld) { [void](Remove-WinISOBuildLock -Path $script:LockPath) }
    Write-BuildStatus -Stage 'verified' -Percent 0 -Detail 'verify only' -State 'ok'
    exit 0
}

if ($DryRun) {
    Write-Stage 'DRY RUN - no image was mounted or modified.'
    $indexWord = 'index'
    if (@($indexList).Count -gt 1) { $indexWord = 'indexes' }
    Write-Stage ('Would export ' + $indexWord + ' ' + ($indexList -join ', ') + ' from ' + $SourceIso)
    Write-Stage ('Would apply ' + $pkgList.Count + ' package(s) and ' + @($driverUnique).Count + ' driver(s)')
    if (-not $SkipBootWim) { Write-Stage ('Would also service sources\boot.wim index ' + $BootWimIndex + ' (WinPE)') }
    Write-Stage ('Would write ISO to ' + $OutDir)
    if ($Resume -and $reuseMedia) { Write-Stage 'Resume: the existing work media would be reused.' }
    exit 0
}

# --------------------------------------------------------------------------
# build
# --------------------------------------------------------------------------
$media = Join-Path $WorkDir 'Media'
$mount = Join-Path $WorkDir 'Mount'
$bootMount = Join-Path $WorkDir 'Mount-Boot'
$result = [ordered]@{ ok = $false; stage = 'start' }
$imageResults = @()
$bootResult = $null
$mediaManifestPath = ''
$outIso = ''
$primary = $null
$archToken = 'x64'
$imageBuild = 0
$imageRevision = 0
$levelSource = 'image metadata'
$levelKb = ''

try {
    # 1-3. media copy and index export
    Write-BuildStatus -Stage 'copy-media' -Percent 5
    $export = Invoke-WinISOMediaExport -SourceIso $SourceIso -Media $media -IndexList $indexList `
        -ReuseMedia:($Resume -and $reuseMedia) -ReuseExport:($Resume -and $reuseExport) -Force:$Force `
        -LogFile $script:DismLog -Log { param($m) Write-Stage $m }
    if (-not $export.Ok) { throw $export.Error }
    $images = @($export.Images)
    if ($images.Count -eq 0) { throw 'No image index was exported.' }
    $primary = $images[0]
    if ($primary.architecture) { $archToken = [string]$primary.architecture }
    Complete-Stage -Name 'media-export' -MediaReady -Exported
    Write-Stage ('  media ready with ' + $images.Count + ' index(es); architecture ' + $archToken)

    $srcWim = Join-Path $media 'sources\install.wim'

    # 4-7. service every index
    $position = 0
    foreach ($im in $images) {
        $position++
        $newIndex = [int]$im.index
        $pct = 20 + [int](35 * ($position - 1) / $images.Count)
        if ($Resume -and ($script:ServicedIndexes -contains $newIndex)) {
            Write-Stage ('Index ' + $newIndex + ' (' + $im.name + ') was already serviced in the previous run; reading its level')
            $info = Invoke-Dism -Arguments @('/English', '/Get-ImageInfo', ('/ImageFile:' + $srcWim), ('/Index:' + $newIndex))
            $lvl = Get-DismLevel -Text $info.Text
            $imageResults += [pscustomobject]@{
                index = $newIndex; source_index = [int]$im.source_index; edition = [string]$im.name
                build = $lvl.Build; revision = $lvl.Revision; resumed = $true
                applied = @(); already_present = @(); failed = @(); features = @()
                drivers = [pscustomobject]@{ added = 0; failed = 0; total = 0 }
            }
            continue
        }
        Write-BuildStatus -Stage 'service-image' -Percent $pct -Detail ([string]$im.name)
        $svc = Invoke-WinISOIndexServicing -Wim $srcWim -ImageIndex $newIndex -MountDir $mount -EditionName ([string]$im.name) `
            -Packages $pkgList -DriverInfs $driverUnique -ForceUnsigned:(-not $SignedDriversOnly) `
            -Capabilities $Capabilities -OptionalFeatures $OptionalFeatures -RemoveAppx $RemoveAppx `
            -CapabilitySource $CapabilitySource -ScanHealth:$ScanHealth `
            -StartComponentCleanup:$StartComponentCleanup -ResetBase:$ResetBase `
            -LogFile $script:DismLog -Log { param($m) Write-Stage $m }
        if (-not $svc.Ok) { throw ('Servicing index ' + $newIndex + ' failed: ' + $svc.Error) }
        $imageResults += [pscustomobject]@{
            index          = $newIndex
            source_index   = [int]$im.source_index
            edition        = [string]$im.name
            build          = [int]$svc.LevelAfter.Build
            revision       = [int]$svc.LevelAfter.Revision
            build_before   = ([string]$svc.LevelBefore.Build + '.' + [string]$svc.LevelBefore.Revision)
            resumed        = $false
            applied        = @($svc.Applied)
            already_present = @($svc.AlreadyPresent)
            failed         = @($svc.FailedPackages)
            features       = @($svc.Features)
            drivers        = $svc.DriverStats
        }
        if ($script:ServicedIndexes -notcontains $newIndex) { $script:ServicedIndexes += $newIndex }
        Complete-Stage -Name ('serviced-' + $newIndex) -MediaReady -Exported
    }

    # 6d. boot.wim (WinPE): storage drivers and the cumulative update
    if (-not $SkipBootWim) {
        $bootWim = Join-Path $media 'sources\boot.wim'
        if (-not (Test-Path -LiteralPath $bootWim)) {
            Write-Stage ('boot.wim not found at ' + $bootWim + '; WinPE servicing skipped')
        }
        else {
            Write-BuildStatus -Stage 'service-bootwim' -Percent 60
            $bootPackages = @($pkgList | Where-Object { (Get-WinISOPackageKind -Identity (Split-Path $_ -Leaf)) -eq 'lcu' })
            $bootResult = Invoke-WinISOBootWimServicing -BootWim $bootWim -MountDir $bootMount -ImageIndex $BootWimIndex `
                -DriverInfs $driverUnique -Packages $bootPackages -ForceUnsigned:(-not $SignedDriversOnly) `
                -LogFile $script:DismLog -Log { param($m) Write-Stage $m }
            if (-not $bootResult.Ok) { throw ('WinPE servicing failed: ' + $bootResult.Error) }
            Complete-Stage -Name 'boot-wim' -MediaReady -Exported
        }
    }

    # 7b. optional ESD re-encode
    if ($Esd) {
        Write-Stage 'STAGE 7b/9 re-encoding install.wim as install.esd (/Compress:recovery)'
        Write-BuildStatus -Stage 'compress-esd' -Percent 68
        $esdPath = Join-Path $media 'sources\install.esd'
        if (Test-Path -LiteralPath $esdPath) { Remove-Item -LiteralPath $esdPath -Force }
        $enc = Invoke-Dism -Arguments @('/English', '/Export-Image', ('/SourceImageFile:' + $srcWim), ('/SourceIndex:1'), ('/DestinationImageFile:' + $esdPath), '/Compress:recovery')
        if ($enc.Code -ne 0 -or -not (Test-Path -LiteralPath $esdPath)) {
            throw ('Could not re-encode the image as install.esd (exit ' + $enc.Code + ').')
        }
        $wimGb = [math]::Round((Get-Item -LiteralPath $srcWim).Length / 1GB, 2)
        $esdGb = [math]::Round((Get-Item -LiteralPath $esdPath).Length / 1GB, 2)
        Write-Stage ('  install.esd written: ' + $esdGb + ' GB (install.wim was ' + $wimGb + ' GB)')
        Remove-Item -LiteralPath $srcWim -Force
    }

    # 8. output name, media manifest, ISO
    Write-Stage 'STAGE 8/9 rebuilding the ISO with oscdimg'
    Write-BuildStatus -Stage 'oscdimg' -Percent 75
    $imageBuild = [int]$imageResults[0].build
    $imageRevision = [int]$imageResults[0].revision
    $identity = Get-WinISOMediaIdentity -EditionName ([string]$primary.name) -Build $imageBuild -Architecture $archToken

    # The image metadata keeps the base build but not the revision an LCU was just
    # added at, so the newest level Microsoft lists for this base build names the
    # file (windows11pro26300.10075.iso). An offline run falls back to the image
    # level with -NoReleaseLookup.
    if (-not $NoReleaseLookup -and $imageBuild -gt 0 -and $identity.Family -in @('Windows 11', 'Windows 10')) {
        $appliedKbs = @()
        foreach ($ir in @($imageResults)) {
            foreach ($p in @($ir.applied)) { if ($p.kb) { $appliedKbs += ([string]$p.kb).ToUpperInvariant() } }
        }
        $resumed = @($imageResults | Where-Object { $_.resumed }).Count -gt 0
        if (-not $SkipPackages -and (@($appliedKbs).Count -gt 0 -or $resumed)) {
            Write-Stage ('Looking up the newest ' + $identity.Family + ' build for ' + $imageBuild + ' on the Microsoft release information page')
            $release = Get-WinISOReleaseBuild -Family $identity.Family -BaseBuild $imageBuild
            if (-not $release.Ok) {
                Write-Stage ('  WARNING: ' + [string]$release.Error)
                Write-Stage ('  the file name uses the image level ' + $imageBuild + '.' + $imageRevision + ' (pass -NoReleaseLookup to skip this lookup)')
            }
            elseif ([int]$release.Revision -le $imageRevision) {
                Write-Stage ('  the page lists ' + $release.Build + '.' + $release.Revision + ' ' + $release.Kb + '; the image is already at ' + $imageBuild + '.' + $imageRevision)
            }
            else {
                $imageRevision = [int]$release.Revision
                $levelKb = [string]$release.Kb
                $levelSource = ('Microsoft release information ' + $release.Kb).Trim()
                Write-Stage ('  newest listed level: ' + $release.Build + '.' + $release.Revision + ' ' + $release.Kb + '; used for the file name')
                if ($levelKb -and @($appliedKbs).Count -gt 0 -and ($appliedKbs -notcontains $levelKb.ToUpperInvariant())) {
                    Write-Stage ('  WARNING: ' + $levelKb + ' was not among the applied update(s) (' + ($appliedKbs -join ', ') + '); the file name may overstate the build inside the image.')
                }
            }
        }
        else {
            Write-Stage ('  no package was applied in this run, so the file name uses the image level ' + $imageBuild + '.' + $imageRevision)
        }
    }

    if (-not $OutputName) {
        $OutputName = New-WinISOOutputName -EditionName ([string]$primary.name) -Build $imageBuild `
            -Revision $imageRevision -Architecture $archToken
    }
    else {
        if ($OutputName -match '(?i)win10' -and $identity.Family -eq 'Windows 11') {
            Write-Stage ('  WARNING: the output file name says Win10 but the image is ' + $identity.Family + ' (build ' + $imageBuild + ').')
        }
        if ($OutputName -match '(?i)win11' -and $identity.Family -eq 'Windows 10') {
            Write-Stage ('  WARNING: the output file name says Win11 but the image is ' + $identity.Family + ' (build ' + $imageBuild + ').')
        }
        if ($OutputName -match '(?i)x64' -and $identity.ArchToken -eq 'arm64') {
            Write-Stage '  WARNING: the output file name says x64 but the image is arm64.'
        }
    }
    $outIso = Join-Path $OutDir $OutputName
    Write-Stage ('  level     : ' + $imageBuild + '.' + $imageRevision + ' (from ' + $levelSource + ')')
    Write-Stage ('  output    : ' + $outIso)

    $etfs = Join-Path $media 'boot\etfsboot.com'
    $efisys = Join-Path $media 'efi\microsoft\boot\efisys.bin'
    $bootData = Get-WinISOIsoBootData -Architecture $archToken -EtfsbootPath $etfs -EfisysPath $efisys `
        -EtfsbootExists:(Test-Path -LiteralPath $etfs) -EfisysExists:(Test-Path -LiteralPath $efisys)
    if ($bootData.Error) { throw $bootData.Error }

    if (-not $SkipMediaManifest) {
        Write-Stage ('STAGE 8b/9 hashing the media tree for the per-file manifest' + $(if ($QuickMediaManifest) { ' (sizes only)' } else { ' (this reads the whole tree)' }))
        Write-BuildStatus -Stage 'media-manifest' -Percent 78
        $manifest = New-WinISOMediaManifest -MediaRoot $media -Quick:$QuickMediaManifest -IsoName $OutputName
        $mediaManifestPath = Join-Path $OutDir ($OutputName + '.media.json')
        [System.IO.File]::WriteAllText($mediaManifestPath, ($manifest | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
        Write-Stage ('  media manifest: ' + $manifest.file_count + ' file(s), ' + [math]::Round($manifest.total_bytes / 1GB, 2) + ' GB -> ' + $mediaManifestPath)
    }

    Write-BuildStatus -Stage 'oscdimg' -Percent 82
    $osc = New-WinISOIsoFile -Oscdimg $Oscdimg -Media $media -OutputIso $outIso -BootData $bootData.BootData
    Write-Stage ('  oscdimg exit ' + $osc.ExitCode)
    if (-not $osc.Ok) { throw ('oscdimg failed (exit ' + $osc.ExitCode + ')') }
    $isoGb = [math]::Round((Get-Item -LiteralPath $outIso).Length / 1GB, 2)
    Write-Stage ('  ISO written: ' + $isoGb + ' GB')
    Complete-Stage -Name 'iso' -MediaReady -Exported

    # 9. hashes, report, history
    Write-Stage 'STAGE 9/9 hashing and writing the report'
    Write-BuildStatus -Stage 'report' -Percent 95
    $hashes = @(Get-WinISOFileHash -Path $outIso -Algorithm @('MD5', 'SHA256'))
    $sha = (@($hashes | Where-Object { $_.Algorithm -eq 'SHA256' })[0]).Hash
    $md5 = (@($hashes | Where-Object { $_.Algorithm -eq 'MD5' })[0]).Hash
    Write-Stage ('  SHA256: ' + $sha)
    Write-Stage ('  MD5   : ' + $md5)
    $sidecar = ($sha + '  ' + $outIso + "`r`n" + $md5 + '  ' + $outIso)
    [System.IO.File]::WriteAllText((Join-Path $OutDir 'ISO-SHA256.txt'), $sidecar, (New-Object System.Text.UTF8Encoding($false)))

    $primaryResult = $imageResults[0]
    $applied = @()
    $present = @()
    $failed = @()
    $features = @()
    $driverTotals = [ordered]@{ added = 0; failed = 0; total = 0 }
    foreach ($ir in $imageResults) {
        $applied += @($ir.applied)
        $present += @($ir.already_present)
        $failed += @($ir.failed)
        $features += @($ir.features)
        $driverTotals.added += [int]$ir.drivers.added
        $driverTotals.failed += [int]$ir.drivers.failed
        $driverTotals.total += [int]$ir.drivers.total
    }

    $meta = [ordered]@{
        output_iso        = $outIso
        output_iso_bytes  = (Get-Item -LiteralPath $outIso).Length
        sha256            = $sha
        md5               = $md5
        source_iso        = $SourceIso
        image_index       = [int]$primary.source_index
        build_level       = ([string]$imageBuild + '.' + [string]$imageRevision)
        build_level_source = $levelSource
        release_kb        = $levelKb
        image_indexes     = @($imageResults | ForEach-Object { [int]$_.source_index })
        edition           = [string]$primary.name
        editions          = @($imageResults | ForEach-Object { [string]$_.edition })
        build             = [int]$primaryResult.build
        revision          = [int]$primaryResult.revision
        family            = $identity.Family
        architecture      = $archToken
        images            = @($imageResults)
        packages_applied  = @($applied)
        packages_skipped  = @($present)
        packages_failed   = @($failed)
        drivers           = $driverTotals
        driver_inventory  = (Join-Path $reportsDir 'DRIVER-INVENTORY.json')
        storage_warnings  = @($(if ($storageCoverage) { $storageCoverage.Warnings } else { @() }))
        boot_wim          = $(if ($bootResult) { [ordered]@{ index = $BootWimIndex; applied = @($bootResult.Applied); failed = @($bootResult.Failed); drivers = $bootResult.DriverStats } } else { $null })
        features          = @($features)
        component_cleanup = [bool]$StartComponentCleanup
        reset_base        = [bool]$ResetBase
        scan_health       = [bool]$ScanHealth
        install_esd       = [bool]$Esd
        media_manifest    = $mediaManifestPath
        oscdimg           = $Oscdimg
        dism_log          = $script:DismLog
        resumed           = [bool]$Resume
        started_utc       = $script:StartedUtc.ToString('o')
        elapsed_minutes   = [math]::Round(([DateTime]::UtcNow - $script:StartedUtc).TotalMinutes, 1)
        built_utc         = [DateTime]::UtcNow.ToString('o')
        outcome           = 'ok'
    }
    $metaPath = Join-Path $OutDir 'OUTPUT-ISO-META.json'
    [System.IO.File]::WriteAllText($metaPath, ($meta | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    Write-Stage ('  report: ' + $metaPath)

    $reportPath = Join-Path $reportsDir 'BUILD-REPORT.json'
    $report = [ordered]@{}
    foreach ($k in $meta.Keys) { $report[$k] = $meta[$k] }
    $report['packages_requested'] = @($pkgList | ForEach-Object { Split-Path $_ -Leaf })
    $report['profile'] = $Profile
    [System.IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    Write-Stage ('  build report: ' + $reportPath)

    # Run history: one line per build, so a level or size change over time is visible.
    $historyPath = Join-Path $reportsDir 'RUN-HISTORY.json'
    $historyEntries = @(Add-WinISORunHistory -Path $historyPath -Run @{
        built_utc       = [DateTime]::UtcNow.ToString('o')
        source_iso      = $SourceIso
        edition         = [string]$primary.name
        editions        = @($imageResults | ForEach-Object { [string]$_.edition })
        build           = [int]$primaryResult.build
        revision        = [int]$primaryResult.revision
        iso_bytes       = [long](Get-Item -LiteralPath $outIso).Length
        iso_gb          = [math]::Round((Get-Item -LiteralPath $outIso).Length / 1GB, 2)
        elapsed_minutes = [math]::Round(([DateTime]::UtcNow - $script:StartedUtc).TotalMinutes, 1)
        packages        = @($applied | ForEach-Object { $_.kb })
        drivers_added   = [int]$driverTotals.added
        outcome         = 'ok'
    })
    Write-Stage ('  run history: ' + $historyPath + ' (' + $historyEntries.Count + ' run(s))')
    foreach ($line in @(Format-WinISORunHistoryTable -Entries $historyEntries)) { Write-Stage ('  ' + $line) }

    # Space usage and optional retention.
    $usage = Get-WinISOArtifactUsage -Workspace $ws
    $usagePath = Join-Path $reportsDir 'SPACE-USAGE.json'
    [System.IO.File]::WriteAllText($usagePath, ($usage | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    Write-Stage ('  space usage: ' + $usagePath)
    if ($KeepBuilds -gt 0 -or $PruneLogsDays -gt 0) {
        $plan = @(Get-WinISOPrunePlan -Workspace $ws -KeepBuilds $KeepBuilds -PruneLogsDays $PruneLogsDays)
        $reclaim = [long]0
        foreach ($item in $plan) { $reclaim += [long]$item.Bytes }
        Write-Stage ('  retention: ' + $plan.Count + ' item(s), ' + [math]::Round($reclaim / 1GB, 2) + ' GB reclaimable')
        foreach ($item in $plan) { Write-Stage ('    ' + $item.Kind + ' ' + $item.Path + ' (' + $item.Reason + ')') }
        if ($PruneApply -and $plan.Count -gt 0) {
            foreach ($item in $plan) {
                try { Remove-Item -LiteralPath $item.Path -Force -ErrorAction Stop } catch { Write-Stage ('    could not remove ' + $item.Path + ': ' + $_.Exception.Message) }
            }
            Write-Stage '  retention: the listed items were deleted (-PruneApply)'
        }
        elseif ($plan.Count -gt 0) {
            Write-Stage '  retention: nothing was deleted; pass -PruneApply to delete the listed items'
        }
    }

    if ($SaveProfile) {
        $profilePath = Join-Path $ws 'State\BuildProfile.json'
        [void](Save-WinISOProfile -Path $profilePath -Values @{
            workspace         = $Workspace
            source_iso        = $SourceIso
            edition_index     = $Index
            drivers           = $Drivers
            output_name       = $OutputName
            run_cleanup       = [bool]$StartComponentCleanup
            scan_health       = [bool]$ScanHealth
            esd               = [bool]$Esd
            capabilities      = @($Capabilities)
            optional_features = @($OptionalFeatures)
            remove_appx       = @($RemoveAppx)
            capability_source = $CapabilitySource
        })
        Write-Stage ('  profile saved: ' + $profilePath)
    }

    Complete-Stage -Name 'done' -MediaReady -Exported
    $result.ok = $true
    Write-Stage 'BUILD OK'
    Write-BuildStatus -Stage 'done' -Percent 100 -Detail $outIso -State 'ok'
}
catch {
    $msg = $_.Exception.Message
    Write-Stage ('BUILD FAILED: ' + $msg)
    Write-BuildStatus -Stage 'failed' -Percent 100 -Detail $msg -State 'failed'
    try {
        Add-WinISORunHistory -Path (Join-Path $reportsDir 'RUN-HISTORY.json') -Run @{
            built_utc       = [DateTime]::UtcNow.ToString('o')
            source_iso      = $SourceIso
            edition         = $(if ($primary) { [string]$primary.name } else { '' })
            build           = 0
            revision        = 0
            iso_gb          = 0
            elapsed_minutes = [math]::Round(([DateTime]::UtcNow - $script:StartedUtc).TotalMinutes, 1)
            outcome         = 'failed'
            error           = $msg
        } | Out-Null
    }
    catch { }
    throw
}
finally {
    if ($lockHeld) { [void](Remove-WinISOBuildLock -Path $script:LockPath) }
    if ($result.ok -and -not $KeepWork) {
        Write-Stage 'cleanup: removing the work media (pass -KeepWork to keep it)'
        Remove-Item -LiteralPath $media -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $mount -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $bootMount -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $script:CheckpointPath) { Remove-Item -LiteralPath $script:CheckpointPath -Force -ErrorAction SilentlyContinue }
    }
    elseif ($result.ok) {
        Write-Stage ('work media kept at ' + $media + ' (-KeepWork); State\BUILD-CHECKPOINT.json is retained so a re-run can -Resume')
    }
}
