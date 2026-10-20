# Build-WinISOUpdated.ps1
# One-shot, restartable-by-inspection build of an updated Windows ISO:
#
#   1. mount the source ISO and copy its media to a work folder
#   2. export ONE image (default index 6 = Windows 11 Pro) into sources\install.wim
#   3. mount that image and add the supplied cumulative/.NET packages
#   4. add every driver under -Drivers
#   5. commit the image, then rebuild a bootable BIOS+UEFI ISO with oscdimg
#   6. write the ISO hash and a JSON report of everything that was applied
#
# Every stage is logged with a timestamp to -LogFile (and the transcript), and
# State\BUILD-STATUS.json is rewritten between stages so a long unattended run
# can be watched from another process.
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

[CmdletBinding()]
param(
    [string]$SourceIso = 'D:\Windows11_Client_x64_en-us_26300_9457.iso',
    [string]$Workspace = 'D:\WimMount',
    [ValidateRange(1, 99)][int]$Index = 6,
    [string]$Drivers = '',
    [string[]]$Packages = @(),
    [string]$UpdatesDir = '',
    [string]$OutDir = '',
    [string]$WorkDir = '',
    [string]$OutputName = '',
    [string]$Oscdimg = '',
    [switch]$SkipDrivers,
    [switch]$SkipPackages,
    [switch]$StartComponentCleanup,
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
        stage      = $Stage
        percent    = $Percent
        state      = $State
        detail     = $Detail
        updated    = (Get-Date -Format 'o')
        pid        = $PID
    }
    try {
        [System.IO.File]::WriteAllText($script:StatusPath, ($obj | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
}

# Run DISM and return @{ Code; Text }. Output is captured through PowerShell so
# it stays UTF-16-safe and does not depend on console redirection.
function Invoke-Dism {
    param([string[]]$Arguments)
    $out = & $script:Dism @Arguments 2>&1 | Out-String
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
    # Walk up to the nearest existing ancestor so a not-yet-created folder works.
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

# Parse "Index : 1 / Name : Windows 11 Home / Size : ..." blocks from DISM.
function ConvertFrom-DismImageInfo {
    param([string]$Text)
    $images = @()
    $cur = $null
    foreach ($raw in ($Text -split "`r?`n")) {
        $line = $raw.Trim()
        if ($line -match '^Index\s*:\s*(\d+)$') {
            if ($cur) { $images += $cur }
            $cur = @{ index = [int]$Matches[1]; name = ''; description = ''; size = 0 }
            continue
        }
        if (-not $cur) { continue }
        if ($line -match '^Name\s*:\s*(.+)$') { $cur.name = $Matches[1].Trim() }
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
    $cumulative = @($all | Where-Object { $_.Name -notmatch '(?i)-ndp\d+' } | Sort-Object LastWriteTime -Descending)
    $picked = @()
    # newest first: it must be the current cumulative update for this build
    if ($cumulative.Count -gt 0) { $picked += $cumulative[0].FullName }
    if ($dotnet.Count -gt 0) { $picked += $dotnet[0].FullName }
    return $picked
}

# --------------------------------------------------------------------------
# self test (no elevation, no DISM, no ISO required)
# --------------------------------------------------------------------------
function Invoke-BuildSelfTest {
    $problems = @()

    if ((Get-KbFromName -Name 'windows11.0-kb5127648-x64_2b88d2d3.msu') -ne 'KB5127648') { $problems += 'KB extraction from a catalog file name failed' }
    if ((Get-KbFromName -Name 'windows11.0-kb5127694-x64-ndp481_a1a6f6d3.msu') -ne 'KB5127694') { $problems += 'KB extraction from a .NET file name failed' }
    if ((Get-KbFromName -Name 'something.msu') -ne '') { $problems += 'KB extraction should return empty without a KB number' }

    $sample = @'
Deployment Image Servicing and Management tool

Details for image : D:\media\sources\install.wim

Index : 1
Name : Windows 11 Home
Description : Windows 11 Home
Size : 25,730,139,683 bytes

Index : 6
Name : Windows 11 Pro
Description : Windows 11 Pro
Size : 26,770,709,765 bytes

'@
    $imgs = @(ConvertFrom-DismImageInfo -Text $sample)
    if ($imgs.Count -ne 2) { $problems += ('image-info parser expected 2 indexes, got ' + $imgs.Count) }
    elseif ($imgs[1].index -ne 6) { $problems += 'image-info parser lost index 6' }
    elseif ($imgs[1].name -ne 'Windows 11 Pro') { $problems += ('image-info parser lost the edition name (got ' + $imgs[1].name + ')') }
    elseif ($imgs[1].size -ne [long]26770709765) { $problems += 'image-info parser lost the size' }

    $lvl = Get-DismLevel -Text "`nVersion : 10.0.26300`nServicePack Build : 9711`n"
    if ($lvl.Build -ne 26300) { $problems += ('build parse failed (got ' + $lvl.Build + ')') }
    if ($lvl.Revision -ne 9711) { $problems += ('revision parse failed (got ' + $lvl.Revision + ')') }
    $lvl0 = Get-DismLevel -Text 'no level here'
    if ($lvl0.Build -ne 0 -or $lvl0.Revision -ne 0) { $problems += 'level parse should return zeros when absent' }

    $tmp = Join-Path $env:TEMP ('winiso-pkg-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $tmp -Force)
    try {
        $cu = Join-Path $tmp 'windows11.0-kb5127648-x64_abc.msu'
        $net = Join-Path $tmp 'windows11.0-kb5127694-x64-ndp481_def.msu'
        [System.IO.File]::WriteAllText($cu, 'x')
        [System.IO.File]::WriteAllText($net, 'x')
        (Get-Item -LiteralPath $cu).LastWriteTime = (Get-Date).AddHours(-2)
        (Get-Item -LiteralPath $net).LastWriteTime = (Get-Date).AddHours(-1)
        $picked = @(Resolve-AutoPackages -Dir $tmp)
        if ($picked.Count -ne 2) { $problems += ('auto package selection expected 2 files, got ' + $picked.Count) }
        elseif ($picked[0] -notmatch 'kb5127648') { $problems += 'the cumulative update must be applied before the .NET update' }
        elseif ($picked[1] -notmatch 'ndp481') { $problems += 'the .NET cumulative update was not selected' }
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

    if (-not (Find-Oscdimg)) { $problems += 'oscdimg.exe was not found' }

    if ($problems.Count -gt 0) {
        Write-Host 'SELFTEST FAILED:'
        foreach ($p in $problems) { Write-Host ('  - ' + $p) }
        exit 2
    }
    Write-Host 'SELFTEST OK: KB extraction, DISM image-info and build parsing, auto package ordering, oscdimg discovery.'
    exit 0
}

if ($SelfTest) { Invoke-BuildSelfTest }

# --------------------------------------------------------------------------
# pre-flight
# --------------------------------------------------------------------------
$ws = [System.IO.Path]::GetFullPath($Workspace)
if (-not $OutDir) { $OutDir = Join-Path $ws 'Output' }
if (-not $WorkDir) { $WorkDir = Join-Path $ws 'Work' }
if (-not $UpdatesDir) { $UpdatesDir = Join-Path $ws 'Updates' }
$logDir = Join-Path $ws 'Logs'
foreach ($d in @($OutDir, $WorkDir, $logDir, (Join-Path $ws 'State'), (Join-Path $ws 'Reports'))) {
    if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
}
$script:Log = Join-Path $logDir ('build-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
$script:StatusPath = Join-Path $ws 'State\BUILD-STATUS.json'

Write-BuildStatus -Stage 'preflight' -Percent 0
Write-Stage ('Build-WinISOUpdated starting. log=' + $script:Log)
Write-Stage ('Source ISO : ' + $SourceIso)
Write-Stage ('Index      : ' + $Index)
Write-Stage ('Workspace  : ' + $ws)

$problems = @()
if (-not (Test-Path -LiteralPath $SourceIso)) { $problems += ('Source ISO not found: ' + $SourceIso) }
if (-not (Test-Path -LiteralPath $script:Dism)) { $problems += ('dism.exe not found: ' + $script:Dism) }

if (-not $Oscdimg) { $Oscdimg = Find-Oscdimg }
if (-not $Oscdimg) { $problems += 'oscdimg.exe not found (install the Windows ADK Deployment Tools)' }
else { Write-Stage ('oscdimg    : ' + $Oscdimg) }

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
    # cumulative update first, then the .NET cumulative update
    $pkgList = @($pkgList | Sort-Object { if ($_ -match '(?i)-ndp\d+') { 1 } else { 0 } })
    foreach ($p in $pkgList) {
        $sz = [math]::Round((Get-Item -LiteralPath $p).Length / 1MB, 1)
        Write-Stage ('Package    : ' + $p + '  (' + $sz + ' MB)')
    }
}

if (-not $SkipDrivers) {
    if (-not $Drivers) { $problems += 'No -Drivers folder given (use -SkipDrivers to build without drivers)' }
    elseif (-not (Test-Path -LiteralPath $Drivers)) { $problems += ('Drivers folder not found: ' + $Drivers) }
    else {
        $infCount = @(Get-ChildItem -LiteralPath $Drivers -Filter *.inf -Recurse -File -ErrorAction SilentlyContinue).Count
        Write-Stage ('Drivers    : ' + $Drivers + ' (' + $infCount + ' .inf files)')
        if ($infCount -eq 0) { $problems += ('No .inf files under ' + $Drivers) }
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
    exit 2
}

if ($DryRun) {
    Write-Stage 'DRY RUN - no image was mounted or modified.'
    Write-Stage ('Would export index ' + $Index + ' from ' + $SourceIso)
    $driverPlan = 'all'
    if ($SkipDrivers) { $driverPlan = '0' }
    Write-Stage ('Would apply ' + $pkgList.Count + ' package(s) and ' + $driverPlan + ' driver(s)')
    Write-Stage ('Would write ISO to ' + $OutDir)
    exit 0
}

# --------------------------------------------------------------------------
# 1. mount the source ISO and copy the media
# --------------------------------------------------------------------------
$media = Join-Path $WorkDir 'Media'
$mount = Join-Path $WorkDir 'Mount'
$isoMounted = $false
$imageMounted = $false
$result = [ordered]@{ ok = $false; stage = 'start' }

try {
    Write-BuildStatus -Stage 'copy-media' -Percent 5
    Write-Stage 'STAGE 1/9 mounting source ISO'
    $disk = Mount-DiskImage -ImagePath $SourceIso -PassThru -ErrorAction Stop
    $isoMounted = $true
    $letter = ''
    for ($i = 0; $i -lt 60; $i++) {
        $v = Get-DiskImage -ImagePath $SourceIso | Get-Volume -ErrorAction SilentlyContinue
        if ($v -and $v.DriveLetter) { $letter = [string]$v.DriveLetter; break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $letter) { throw 'The source ISO mounted but did not get a drive letter.' }
    $root = ($letter + ':\')
    Write-Stage ('  mounted at ' + $root)
    if (-not (Test-Path -LiteralPath ($root + 'sources'))) { throw ('Not a Windows ISO: no sources folder at ' + $root) }

    if (Test-Path -LiteralPath $media) {
        if (-not $Force) { throw ('Work media already exists: ' + $media + '. Delete it or pass -Force.') }
        Write-Stage '  removing previous media (-Force)'
        Remove-Item -LiteralPath $media -Recurse -Force
    }
    [void](New-Item -ItemType Directory -Path $media -Force)

    Write-Stage ('STAGE 2/9 copying media to ' + $media)
    Write-BuildStatus -Stage 'copy-media' -Percent 12
    $rc = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\robocopy.exe') `
        -ArgumentList @(('"' + $root + '"'), ('"' + $media + '"'), '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/R:2', '/W:2', '/MT:8') `
        -Wait -PassThru -NoNewWindow
    if ($rc.ExitCode -ge 8) { throw ('robocopy failed copying the ISO media (exit ' + $rc.ExitCode + ')') }
    Write-Stage ('  media copied (robocopy exit ' + $rc.ExitCode + ')')
    Dismount-DiskImage -ImagePath $SourceIso -ErrorAction SilentlyContinue | Out-Null
    $isoMounted = $false

    Get-ChildItem -LiteralPath $media -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.IsReadOnly) { $_.IsReadOnly = $false }
    }

    # ----------------------------------------------------------------------
    # 3. locate the install image and export the requested index
    # ----------------------------------------------------------------------
    Write-Stage 'STAGE 3/9 inspecting the install image'
    Write-BuildStatus -Stage 'export-image' -Percent 20
    $srcWim = Join-Path $media 'sources\install.wim'
    $srcEsd = Join-Path $media 'sources\install.esd'
    $usingEsd = $false
    if (-not (Test-Path -LiteralPath $srcWim)) {
        if (Test-Path -LiteralPath $srcEsd) { $srcWim = $srcEsd; $usingEsd = $true }
        else { throw 'Neither sources\install.wim nor sources\install.esd exists in the ISO media.' }
    }
    Write-Stage ('  source image: ' + $srcWim)

    $info = Invoke-Dism -Arguments @('/English', '/Get-WimInfo', ('/WimFile:' + $srcWim))
    if ($info.Code -ne 0) { throw ('DISM could not read the source image (exit ' + $info.Code + '): ' + $info.Text.Trim()) }
    $images = @(ConvertFrom-DismImageInfo -Text $info.Text)
    Write-Stage ('  indexes found: ' + $images.Count)
    foreach ($im in $images) { Write-Stage ('    ' + $im.index + '  ' + $im.name) }
    $target = @($images | Where-Object { $_.index -eq $Index })
    if ($target.Count -eq 0) { throw ('Image index ' + $Index + ' does not exist (found ' + $images.Count + ').') }
    $targetName = $target[0].name
    Write-Stage ('  selected index ' + $Index + ' = ' + $targetName)
    if ($targetName -notmatch '(?i)\bPro\b') {
        Write-Stage ('  WARNING: index ' + $Index + ' is "' + $targetName + '", not a Pro edition. Continuing because it was requested explicitly.')
    }

    $exportTmp = Join-Path $media ('sources\install_export_' + $Index + '.wim')
    if (Test-Path -LiteralPath $exportTmp) { Remove-Item -LiteralPath $exportTmp -Force }
    Write-Stage ('  exporting index ' + $Index + ' (this reads the whole image; expect several minutes)')
    Write-BuildStatus -Stage 'export-image' -Percent 25 -Detail $targetName
    $exp = Invoke-Dism -Arguments @('/English', '/Export-Image', ('/SourceImageFile:' + $srcWim), ('/SourceIndex:' + $Index), ('/DestinationImageFile:' + $exportTmp), '/Compress:max')
    if ($exp.Code -ne 0) { throw ('Export-Image failed (exit ' + $exp.Code + '). See the log for DISM output.') }
    $expGb = [math]::Round((Get-Item -LiteralPath $exportTmp).Length / 1GB, 2)
    Write-Stage ('  exported image: ' + $expGb + ' GB')

    # Replace the multi-edition image with the single exported edition.
    Remove-Item -LiteralPath $srcWim -Force
    Move-Item -LiteralPath $exportTmp -Destination (Join-Path $media 'sources\install.wim') -Force
    if ($usingEsd -and (Test-Path -LiteralPath $srcEsd)) { Remove-Item -LiteralPath $srcEsd -Force }
    $srcWim = Join-Path $media 'sources\install.wim'
    Write-Stage '  sources\install.wim now holds only the selected edition'

    # ----------------------------------------------------------------------
    # 4. mount the image
    # ----------------------------------------------------------------------
    Write-Stage 'STAGE 4/9 mounting the image for servicing'
    Write-BuildStatus -Stage 'mount' -Percent 32
    if (Test-Path -LiteralPath $mount) { Remove-Item -LiteralPath $mount -Recurse -Force -ErrorAction SilentlyContinue }
    [void](New-Item -ItemType Directory -Path $mount -Force)
    $mnt = Invoke-Dism -Arguments @('/English', '/Mount-Image', ('/ImageFile:' + $srcWim), '/Index:1', ('/MountDir:' + $mount))
    if ($mnt.Code -ne 0) { throw ('Mount-Image failed (exit ' + $mnt.Code + ').') }
    $imageMounted = $true
    Write-Stage '  mounted'

    $before = Invoke-Dism -Arguments @('/English', ('/Image:' + $mount), '/Get-ImageInfo')
    $levelBefore = Get-DismLevel -Text $before.Text
    Write-Stage ('  image level before servicing: ' + $levelBefore.Build + '.' + $levelBefore.Revision)

    # ----------------------------------------------------------------------
    # 5. add packages
    # ----------------------------------------------------------------------
    $applied = @()
    $skipped = @()
    if ($pkgList.Count -gt 0) {
        Write-Stage ('STAGE 5/9 adding ' + $pkgList.Count + ' package(s)')
        $n = 0
        foreach ($pkg in $pkgList) {
            $n++
            $kb = Get-KbFromName -Name (Split-Path $pkg -Leaf)
            $pct = 32 + [int](18 * $n / $pkgList.Count)
            Write-BuildStatus -Stage 'add-package' -Percent $pct -Detail $kb
            Write-Stage ('  [' + $n + '/' + $pkgList.Count + '] Add-Package ' + (Split-Path $pkg -Leaf))
            $r = Invoke-Dism -Arguments @('/English', ('/Image:' + $mount), '/Add-Package', ('/PackagePath:' + $pkg), '/NoRestart')
            if ($r.Code -eq 0) {
                Write-Stage '    OK'
                $applied += [pscustomobject]@{ kb = $kb; file = (Split-Path $pkg -Leaf); result = 'applied' }
            }
            else {
                $msg = (($r.Text -split "`r?`n") | Where-Object { $_ -match '(?i)error|not applicable|0x[0-9a-f]{8}' } | Select-Object -First 3) -join ' | '
                Write-Stage ('    FAILED (exit ' + $r.Code + ') ' + $msg)
                $skipped += [pscustomobject]@{ kb = $kb; file = (Split-Path $pkg -Leaf); result = 'failed'; detail = $msg }
            }
        }
    }
    else { Write-Stage 'STAGE 5/9 no packages to add' }

    # ----------------------------------------------------------------------
    # 6. add drivers
    # ----------------------------------------------------------------------
    $driverStats = @{ added = 0; existing = 0; failed = 0; total = 0 }
    if (-not $SkipDrivers) {
        Write-Stage ('STAGE 6/9 adding drivers from ' + $Drivers)
        Write-BuildStatus -Stage 'add-driver' -Percent 52
        $dr = Invoke-Dism -Arguments @('/English', ('/Image:' + $mount), '/Add-Driver', ('/Driver:' + $Drivers), '/Recurse', '/ForceUnsigned')
        if ($script:Log) { Add-Content -LiteralPath $script:Log -Value $dr.Text -Encoding UTF8 }
        foreach ($ln in ($dr.Text -split "`r?`n")) {
            if ($ln -match '(?i)^\s*Installing\s+\d+\s+of\s+\d+\s+-\s') { $driverStats.total++ }
            elseif ($ln -match '(?i)already exists') { $driverStats.existing++ }
            elseif ($ln -match '(?i)^\s*Error') { $driverStats.failed++ }
        }
        if ($dr.Code -ne 0) {
            Write-Stage ('  Add-Driver returned ' + $dr.Code + ' (some packages may have failed); continuing')
        }
        # /Get-Drivers lists one row per driver, keyed by its published oem*.inf name.
        $dg = Invoke-Dism -Arguments @('/English', ('/Image:' + $mount), '/Get-Drivers', '/Format:Table')
        $driverStats.added = @(($dg.Text -split "`r?`n") | Where-Object { $_ -match '^\s*oem\d+\.inf\s' }).Count
        Write-Stage ('  drivers in image now: ' + $driverStats.added + ' (processed ' + $driverStats.total + ', already present ' + $driverStats.existing + ')')
    }
    else { Write-Stage 'STAGE 6/9 drivers skipped' }

    if ($StartComponentCleanup) {
        Write-Stage 'STAGE 6b/9 StartComponentCleanup (this can take a long time)'
        Write-BuildStatus -Stage 'cleanup' -Percent 60
        $cu = Invoke-Dism -Arguments @('/English', ('/Image:' + $mount), '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase')
        if ($cu.Code -ne 0) { Write-Stage ('  cleanup returned ' + $cu.Code + '; continuing') }
    }

    # ----------------------------------------------------------------------
    # 7. commit
    # ----------------------------------------------------------------------
    Write-Stage 'STAGE 7/9 committing the image'
    Write-BuildStatus -Stage 'commit' -Percent 65
    $un = Invoke-Dism -Arguments @('/English', '/Unmount-Image', ('/MountDir:' + $mount), '/Commit')
    $imageMounted = $false
    if ($un.Code -ne 0) { throw ('Unmount/Commit failed (exit ' + $un.Code + '). The image may be left mounted at ' + $mount + '.') }
    Write-Stage '  committed'

    $after = Invoke-Dism -Arguments @('/English', '/Get-ImageInfo', ('/ImageFile:' + $srcWim), '/Index:1')
    $levelAfter = Get-DismLevel -Text $after.Text
    Write-Stage ('  image level after servicing: ' + $levelAfter.Build + '.' + $levelAfter.Revision)

    $pkgs = Invoke-Dism -Arguments @('/English', '/Get-Packages', ('/ImageFile:' + $srcWim), '/Index:1')
    $pkgCount = @(($pkgs.Text -split "`r?`n") | Where-Object { $_ -match '^Package Identity\s*:' }).Count
    Write-Stage ('  packages recorded in image: ' + $pkgCount)

    # ----------------------------------------------------------------------
    # 8. rebuild the ISO
    # ----------------------------------------------------------------------
    Write-Stage 'STAGE 8/9 rebuilding the ISO with oscdimg'
    Write-BuildStatus -Stage 'oscdimg' -Percent 78
    $etfs = Join-Path $media 'boot\etfsboot.com'
    $efisys = Join-Path $media 'efi\microsoft\boot\efisys.bin'
    if (-not (Test-Path -LiteralPath $etfs)) { throw ('Missing boot file: ' + $etfs) }
    if (-not (Test-Path -LiteralPath $efisys)) { throw ('Missing EFI boot file: ' + $efisys) }

    if (-not $OutputName) {
        $rev = if ($levelAfter.Revision -gt 0) { $levelAfter.Revision } else { 'x' }
        $OutputName = ('Win11_Pro_x64_' + $levelAfter.Build + '.' + $rev + '_Updated_' + (Get-Date -Format 'yyyyMMdd') + '.iso')
    }
    $outIso = Join-Path $OutDir $OutputName
    if (Test-Path -LiteralPath $outIso) { Remove-Item -LiteralPath $outIso -Force }
    Write-Stage ('  output: ' + $outIso)

    $bootData = ('-bootdata:2#p0,e,b' + $etfs + '#pEF,e,b' + $efisys)
    $osc = Start-Process -FilePath $Oscdimg `
        -ArgumentList @('-m', '-o', '-u2', '-udfver102', $bootData, ('"' + $media + '"'), ('"' + $outIso + '"')) `
        -Wait -PassThru -NoNewWindow
    Write-Stage ('  oscdimg exit ' + $osc.ExitCode)
    if ($osc.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $outIso)) { throw ('oscdimg failed (exit ' + $osc.ExitCode + ')') }
    $isoGb = [math]::Round((Get-Item -LiteralPath $outIso).Length / 1GB, 2)
    Write-Stage ('  ISO written: ' + $isoGb + ' GB')

    # ----------------------------------------------------------------------
    # 9. report
    # ----------------------------------------------------------------------
    Write-Stage 'STAGE 9/9 hashing and writing the report'
    Write-BuildStatus -Stage 'report' -Percent 95
    $sha = (Get-FileHash -LiteralPath $outIso -Algorithm SHA256).Hash
    Write-Stage ('  SHA256: ' + $sha)
    [System.IO.File]::WriteAllText((Join-Path $OutDir 'ISO-SHA256.txt'), ($sha + '  ' + $outIso), (New-Object System.Text.UTF8Encoding($false)))

    $meta = [ordered]@{
        output_iso        = $outIso
        output_iso_bytes  = (Get-Item -LiteralPath $outIso).Length
        sha256            = $sha
        source_iso        = $SourceIso
        image_index       = $Index
        edition           = $targetName
        build             = $levelAfter.Build
        revision          = $levelAfter.Revision
        build_before      = ($levelBefore.Build.ToString() + '.' + $levelBefore.Revision.ToString())
        packages_applied  = @($applied)
        packages_failed   = @($skipped)
        drivers           = $driverStats
        packages_in_image = $pkgCount
        oscdimg           = $Oscdimg
        built_utc         = [DateTime]::UtcNow.ToString('o')
    }
    $metaPath = Join-Path $OutDir 'OUTPUT-ISO-META.json'
    [System.IO.File]::WriteAllText($metaPath, ($meta | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    Write-Stage ('  report: ' + $metaPath)

    $result.ok = $true
    Write-Stage 'BUILD OK'
    Write-BuildStatus -Stage 'done' -Percent 100 -Detail $outIso -State 'ok'
}
catch {
    $msg = $_.Exception.Message
    Write-Stage ('BUILD FAILED: ' + $msg)
    Write-BuildStatus -Stage 'failed' -Percent 100 -Detail $msg -State 'failed'
    throw
}
finally {
    if ($imageMounted) {
        Write-Stage 'cleanup: discarding the mounted image (no commit)'
        $d = Invoke-Dism -Arguments @('/English', '/Unmount-Image', ('/MountDir:' + $mount), '/Discard')
        Write-Stage ('  discard exit ' + $d.Code)
    }
    if ($isoMounted) {
        Write-Stage 'cleanup: dismounting the source ISO'
        Dismount-DiskImage -ImagePath $SourceIso -ErrorAction SilentlyContinue | Out-Null
    }
    if ($result.ok -and -not $KeepWork) {
        Write-Stage 'cleanup: removing the work media (pass -KeepWork to keep it)'
        Remove-Item -LiteralPath $media -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $mount -Recurse -Force -ErrorAction SilentlyContinue
    }
}
