# Get-WinISOUpdates.ps1
# Finds the Microsoft updates that apply to a given Windows build/architecture
# (Servicing Stack, latest Cumulative Update, .NET cumulative update, Safe OS
# and Setup dynamic updates) and can download them (.msu) into the workspace
# Updates folder. Reuses the catalog search helper in WinISOService.psm1.
#
# It can also report ONLY the updates the target image is MISSING: it reads the
# image's installed cumulative-update level and marks each candidate as
# MISSED (newer than the image) or ALREADY-PRESENT.
#
# Compatibility : Windows PowerShell 5.1 and PowerShell 7.
# Encoding      : BOM-less UTF-8, ASCII-only.
#
# Examples:
#   .\Get-WinISOUpdates.ps1 -Iso D:\ISO\Win11.iso -ListOnly -MissedOnly
#   .\Get-WinISOUpdates.ps1 -Build 26200 -Architecture x64 -MissedOnly
#   .\Get-WinISOUpdates.ps1 -Build 26200 -ImageRevision 9457 -ListOnly
#   .\Get-WinISOUpdates.ps1 -SelfTest

[CmdletBinding()]
param(
    [int]$Build = 0,
    [string]$Architecture = 'x64',
    [string]$Workspace = 'D:\WimMount',
    [string]$OutDir = '',
    [string]$Iso = '',
    [int]$ImageBuild = 0,
    [int]$ImageRevision = 0,
    [ValidateSet('SSU', 'LatestCU', 'DotNetCU', 'SafeOS', 'SetupDU')]
    [string[]]$Kinds = @('SSU', 'LatestCU', 'DotNetCU', 'SafeOS', 'SetupDU'),
    [switch]$MissedOnly,
    [switch]$ListOnly,
    [switch]$SelfTest
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$script:ModulePath = Join-Path $PSScriptRoot 'WinISOService.psm1'
$script:DownloadDialog = 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx'
$script:UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) WinISOBuild/1.0'
$script:Dism = "$env:SystemRoot\System32\Dism.exe"

# Build -> marketing version hints. Hint only.
$script:VersionHints = @(
    @{ Build = 26200; Version = '25H2' }, @{ Build = 26100; Version = '24H2' },
    @{ Build = 22631; Version = '23H2' }, @{ Build = 22621; Version = '22H2' },
    @{ Build = 22000; Version = '21H2' },
    @{ Build = 19045; Version = '22H2' }, @{ Build = 19044; Version = '21H2' },
    @{ Build = 19041; Version = '2004' }, @{ Build = 18363; Version = '1909' },
    @{ Build = 14393; Version = '1607' }, @{ Build = 10240; Version = '1507' }
)

function Get-WinISOProductFromBuild { param([int]$B)
    if ($B -ge 22000) { return 'Windows 11' }
    if ($B -ge 10240) { return 'Windows 10' }
    return ''
}
function Get-WinISOVersionFromBuild { param([int]$B)
    foreach ($h in $script:VersionHints) { if ($B -eq $h.Build) { return [string]$h.Version } }
    return ''
}
function New-WinISOCatalogSearchUrl { param([string]$Query)
    return ('https://www.catalog.update.microsoft.com/Search.aspx?q=' + [System.Uri]::EscapeDataString($Query))
}
function New-WinISODownloadDialogBody { param([string]$Guid)
    return ('updateIDs=[{"size":0,"updateID":"' + $Guid + '","uidInfo":"' + $Guid + '"}]')
}

# "KB5129195 (26200.9457)" -> @{ Build = 26200; Revision = 9457 }
function Get-WinISOTargetLevel {
    param([string]$Title)
    $m = [regex]::Match([string]$Title, '\((\d{5,6})\.(\d{1,6})\)')
    if ($m.Success) { return @{ Build = [int]$m.Groups[1].Value; Revision = [int]$m.Groups[2].Value } }
    return @{ Build = 0; Revision = 0 }
}

# Classify a candidate against the image level.
function Get-WinISOMissedState {
    param([string]$Title, [int]$ImageBuild, [int]$ImageRevision)
    $t = Get-WinISOTargetLevel -Title $Title
    if ($t.Build -eq 0) { return 'unknown' }
    if ($ImageBuild -le 0) { return 'unknown' }
    if ($t.Build -gt $ImageBuild) { return 'missed' }
    if ($t.Build -lt $ImageBuild) { return 'already-present' }
    if ($t.Revision -gt $ImageRevision) { return 'missed' }
    return 'already-present'
}

function Select-WinISOApplicable {
    param([object[]]$Rows, [string]$Version, [string]$Architecture)
    $out = New-Object System.Collections.Generic.List[System.Management.Automation.PSObject]
    foreach ($r in @($Rows)) {
        $title = [string]$r.Title
        $tv = ''
        $m = [regex]::Match($title, '(?i)version\s+(\d{2}H\d)')
        if ($m.Success) { $tv = $m.Groups[1].Value.ToUpper() }
        $ta = ''
        if ($title -match '(?i)\bx64\b') { $ta = 'x64' }
        elseif ($title -match '(?i)\barm64\b') { $ta = 'arm64' }
        elseif ($title -match '(?i)\bx86\b') { $ta = 'x86' }
        $ok = $true
        if ($title -match '(?i)\bpreview\b') { $ok = $false }
        if ($Version -and $tv -and $tv -ne $Version.ToUpper()) { $ok = $false }
        if ($Architecture -and $ta -and $ta -ne $Architecture) { $ok = $false }
        if ($ok) { $out.Add($r) }
    }
    return ,$out
}

function Get-WinISODownloadUrls {
    param([string]$Guid)
    $body = New-WinISODownloadDialogBody -Guid $Guid
    $resp = Invoke-WebRequest -Uri $script:DownloadDialog -Method Post -Body $body `
        -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -UserAgent $script:UserAgent -TimeoutSec 120
    $urls = @([regex]::Matches([string]$resp.Content, 'https?://[^\s"'']+\.msu') | ForEach-Object { $_.Value } | Select-Object -Unique)
    return ,$urls
}

function Get-WinISOIsoDriveLetter {
    param([string]$IsoPath, [int]$TimeoutSeconds = 60)
    $before = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[A-Z]$' } | ForEach-Object { [string]$_.Name }))
    $img = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
    for ($i = 0; $i -lt ($TimeoutSeconds * 2); $i++) {
        Start-Sleep -Milliseconds 500
        $now = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[A-Z]$' } | ForEach-Object { [string]$_.Name }))
        $new = @($now | Where-Object { $before -notcontains $_ })
        foreach ($l in $new) { if (Test-Path -LiteralPath ("${l}:\sources\install.wim")) { return $l } }
    }
    return ''
}

# Detect the image's current build/revision from an ISO (or its inventory).
function Get-WinISOImageLevel {
    param([string]$IsoPath, [string]$Workspace)
    $res = @{ Build = 0; Revision = 0; Source = '' }
    if ($IsoPath -and (Test-Path -LiteralPath $IsoPath)) {
        $letter = ''
        try { $letter = Get-WinISOIsoDriveLetter -IsoPath $IsoPath } catch { $letter = '' }
        if ($letter) {
            $wim = ("${letter}:\sources\install.wim")
            if (-not (Test-Path -LiteralPath $wim)) { $wim = ("${letter}:\sources\install.esd") }
            $tmp = Join-Path $env:TEMP ('winiso-lvl-' + (Get-Date -Format 'HHmmss'))
            [void](New-Item -ItemType Directory -Path $tmp -Force)
            try {
                $null = & $script:Dism /English /Mount-Image /ImageFile:$wim /Index:1 /MountDir:$tmp /ReadOnly 2>&1
                $pkgs = & $script:Dism /English /Image:$tmp /Get-Packages 2>&1 | Out-String
                $best = @{ Build = 0; Revision = 0 }
                foreach ($mm in [regex]::Matches($pkgs, 'Package_for_RollupFix~[^~]+~[^~]+~~(\d{5,6})\.(\d{1,6})')) {
                    $b = [int]$mm.Groups[1].Value; $rv = [int]$mm.Groups[2].Value
                    if ($b -gt $best.Build -or ($b -eq $best.Build -and $rv -gt $best.Revision)) { $best = @{ Build = $b; Revision = $rv } }
                }
                if ($best.Build -gt 0) { $res.Build = $best.Build; $res.Revision = $best.Revision; $res.Source = 'image packages' }
            }
            finally {
                $null = & $script:Dism /English /Unmount-Image /MountDir:$tmp /Discard 2>&1
                Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }
    if ($res.Build -eq 0) {
        $inv = Join-Path ([System.IO.Path]::GetFullPath($Workspace)) 'Reports\ISO-INVENTORY.json'
        if (Test-Path -LiteralPath $inv) {
            try {
                $j = Get-Content -LiteralPath $inv -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($j.detected.build) { $res.Build = [int]$j.detected.build }
                if ($j.detected.revision) { $res.Revision = [int]$j.detected.revision }
                $res.Source = 'inventory'
            }
            catch { }
        }
    }
    return $res
}

function Invoke-WinISOUpdateSelfTest {
    $problems = @()
    if (-not (Test-Path -LiteralPath $script:ModulePath)) { $problems += ('module not found: ' + $script:ModulePath) }
    if ((Get-WinISOProductFromBuild 26100) -ne 'Windows 11') { $problems += 'product map failed for 26100' }
    if ((Get-WinISOVersionFromBuild 26200) -ne '25H2') { $problems += 'version map failed for 26200' }
    $u = New-WinISOCatalogSearchUrl -Query 'Windows 11 Cumulative Update'
    if ($u -notmatch '^https://www\.catalog\.update\.microsoft\.com/Search\.aspx\?q=') { $problems += 'search URL construction failed' }
    if ($u -notmatch 'Cumulative%20Update') { $problems += 'search URL did not encode spaces' }
    $b = New-WinISODownloadDialogBody -Guid '00000000-0000-0000-0000-000000000000'
    if ($b -notmatch 'updateIDs=\[\{"size":0,"updateID":"00000000-0000-0000-0000-000000000000","uidInfo":') { $problems += 'download body construction failed' }

    $tl = Get-WinISOTargetLevel -Title '2026-09 Cumulative Update for Windows 11, version 25H2 for x64-based Systems (KB5129195) (26200.9457)'
    if ($tl.Build -ne 26200 -or $tl.Revision -ne 9457) { $problems += 'target level parse failed' }
    if ((Get-WinISOMissedState -Title '... (KB1) (26200.9457)' -ImageBuild 26200 -ImageRevision 9457) -ne 'already-present') { $problems += 'missed-state should be already-present at equal level' }
    if ((Get-WinISOMissedState -Title '... (KB2) (26200.9550)' -ImageBuild 26200 -ImageRevision 9457) -ne 'missed') { $problems += 'missed-state should be missed for newer revision' }
    if ((Get-WinISOMissedState -Title '... (KB3) (26200.8037)' -ImageBuild 26200 -ImageRevision 9457) -ne 'already-present') { $problems += 'missed-state should be already-present for older revision' }
    if ((Get-WinISOMissedState -Title 'no build here' -ImageBuild 26200 -ImageRevision 9457) -ne 'unknown') { $problems += 'missed-state should be unknown without a build' }

    $sel = Select-WinISOApplicable -Rows @(
        [pscustomobject]@{ Title = '2026-09 Cumulative Update for Windows 11, version 25H2 for x64-based Systems (KB1)' },
        [pscustomobject]@{ Title = '2026-09 Cumulative Update for Windows 11, version 26H1 for x64-based Systems (KB2)' },
        [pscustomobject]@{ Title = '2026-09 Cumulative Update for .NET Framework for Windows 11, version 25H2 for arm64 (KB3)' }
    ) -Version '25H2' -Architecture 'x64'
    if (@($sel).Count -ne 1) { $problems += ('applicability filter expected 1 row, got ' + @($sel).Count) }

    if ($problems.Count -gt 0) {
        Write-Host 'SELFTEST FAILED:'
        $problems | ForEach-Object { Write-Host ('  - ' + $_) }
        exit 2
    }
    Write-Host 'SELFTEST OK: module found; build/version maps; search URL + download body; target-level parse; missed-state classification; applicability filter.'
    exit 0
}

if ($SelfTest) { Invoke-WinISOUpdateSelfTest }

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Import-Module -Name $script:ModulePath -Force -ErrorAction Stop

$fullWs = [System.IO.Path]::GetFullPath($Workspace)
if (-not $OutDir) { $OutDir = Join-Path $fullWs 'Updates' }
if (-not (Test-Path -LiteralPath $OutDir)) { [void](New-Item -ItemType Directory -Path $OutDir -Force) }

if ($Build -eq 0 -and $Iso) {
    Write-Host ('Detecting build/architecture from ISO: ' + $Iso)
    $det = Get-WinISOImageLevel -IsoPath $Iso -Workspace $fullWs
    if ($det.Build -gt 0) { $Build = $det.Build }
}
if ($Build -eq 0) {
    $inv = Join-Path $fullWs 'Reports\ISO-INVENTORY.json'
    if (Test-Path -LiteralPath $inv) {
        try { $j = Get-Content -LiteralPath $inv -Raw -Encoding UTF8 | ConvertFrom-Json; if ($j.detected.build) { $Build = [int]$j.detected.build }; if ($j.detected.architecture) { $Architecture = [string]$j.detected.architecture } } catch { }
    }
}
if ($Build -eq 0) { throw 'Build number unknown. Pass -Build or -Iso (or run the toolchain inventory first).' }

$product = Get-WinISOProductFromBuild -B $Build
$version = Get-WinISOVersionFromBuild -B $Build
if (-not $product) { throw ('Unsupported build ' + $Build) }

# Image current level (for missed-only classification).
$imgLevel = @{ Build = $ImageBuild; Revision = $ImageRevision; Source = 'parameter' }
if ($imgLevel.Build -eq 0) {
    $det = Get-WinISOImageLevel -IsoPath $Iso -Workspace $fullWs
    if ($det.Build -gt 0) { $imgLevel = $det }
}
if ($imgLevel.Build -eq 0) { $imgLevel = @{ Build = $Build; Revision = 0; Source = 'assumed equal build, unknown revision' } }

Write-Host ('Target : ' + $product + ' build ' + $Build + ' (' + $version + ') ' + $Architecture)
Write-Host ('Image  : build ' + $imgLevel.Build + '.' + $imgLevel.Revision + '  (source: ' + $imgLevel.Source + ')')
if ($MissedOnly) { Write-Host 'Mode   : MISSED ONLY' }
if ($ListOnly) { Write-Host 'Mode   : LIST ONLY (no download)' }

$queryPlan = @()
if ($Kinds -contains 'SSU')      { $queryPlan += [pscustomobject]@{ Kind = 'SSU';      Query = 'Servicing Stack Update "' + $product + '"' } }
if ($Kinds -contains 'LatestCU') { $queryPlan += [pscustomobject]@{ Kind = 'LatestCU'; Query = '"' + $product + '" Cumulative Update for ' + $Architecture } }
if ($Kinds -contains 'DotNetCU') { $queryPlan += [pscustomobject]@{ Kind = 'DotNetCU'; Query = '.NET Framework Cumulative Update "' + $product + '"' } }
if ($Kinds -contains 'SafeOS')   { $queryPlan += [pscustomobject]@{ Kind = 'SafeOS';   Query = 'Safe OS Dynamic Update "' + $product + '"' } }
if ($Kinds -contains 'SetupDU')  { $queryPlan += [pscustomobject]@{ Kind = 'SetupDU';  Query = 'Setup Dynamic Update "' + $product + '"' } }

$all = New-Object System.Collections.Generic.List[System.Management.Automation.PSObject]
foreach ($q in $queryPlan) {
    Write-Host ('Searching catalog: [' + $q.Kind + '] ' + $q.Query)
    $res = Get-WinISOCatalogSearch -Query $q.Query -MaxResults 30
    if (-not $res.Ok) { Write-Host ('  catalog query failed: ' + $res.Error); continue }
    $rows = @($res.Rows)
    Write-Host ('  rows: ' + $rows.Count)
    $applicable = Select-WinISOApplicable -Rows $rows -Version $version -Architecture $Architecture
    foreach ($r in @($applicable)) {
        $r | Add-Member -NotePropertyName 'Kind' -NotePropertyValue $q.Kind -Force
        $all.Add($r)
    }
}

$byKb = @{}
foreach ($r in $all) { $kb = [string]$r.Kb; if ($kb -and -not $byKb.ContainsKey($kb)) { $byKb[$kb] = $r } }
$candidates = @($byKb.Values | Sort-Object { [string]$_.Kb })

foreach ($c in $candidates) {
    $c | Add-Member -NotePropertyName 'MissedState' -NotePropertyValue (Get-WinISOMissedState -Title ([string]$c.Title) -ImageBuild $imgLevel.Build -ImageRevision $imgLevel.Revision) -Force
}

$missed = @($candidates | Where-Object { $_.MissedState -eq 'missed' })
$present = @($candidates | Where-Object { $_.MissedState -eq 'already-present' })
$unknown = @($candidates | Where-Object { $_.MissedState -eq 'unknown' })

Write-Host ''
Write-Host ('Applicable updates (' + $candidates.Count + '): ' + $missed.Count + ' missed, ' + $present.Count + ' already-present, ' + $unknown.Count + ' unknown build')
foreach ($c in $candidates) {
    $tag = '[?????]'
    if ($c.MissedState -eq 'missed') { $tag = '[MISSED]' }
    elseif ($c.MissedState -eq 'already-present') { $tag = '[PRESENT]' }
    Write-Host ('  ' + $tag + ' ' + [string]$c.Kb + '  [' + [string]$c.Kind + ']  ' + [string]$c.Title)
}

$toProcess = $candidates
if ($MissedOnly) { $toProcess = $missed }

if (@($toProcess).Count -eq 0) {
    if ($MissedOnly) { Write-Host ''; Write-Host ('No missed updates: the image is already at ' + $imgLevel.Build + '.' + $imgLevel.Revision + ' for every applicable package found.') }
    else { Write-Host 'No applicable updates found (or catalog unreachable).' }
    exit 0
}

if ($ListOnly) {
    Write-Host ''
    Write-Host ('LIST ONLY - nothing downloaded. Re-run without -ListOnly to download into: ' + $OutDir)
    exit 0
}

$manifestFiles = New-Object System.Collections.Generic.List[System.Management.Automation.PSObject]
foreach ($c in $toProcess) {
    $guid = [string]$c.UpdateGuid
    if (-not $guid) { Write-Host ('SKIP ' + $c.Kb + ': no catalog GUID'); continue }
    Write-Host ('Resolving download URL for ' + $c.Kb + ' ...')
    $urls = @()
    try { $urls = Get-WinISODownloadUrls -Guid $guid } catch { Write-Host ('  failed: ' + $_.Exception.Message); continue }
    foreach ($u in @($urls)) {
        $name = ($u.Split('/'))[-1]
        $dest = Join-Path $OutDir $name
        if (Test-Path -LiteralPath $dest) {
            Write-Host ('  exists, skipping: ' + $name)
            $manifestFiles.Add([pscustomobject]@{ kb = [string]$c.Kb; kind = [string]$c.Kind; missed_state = [string]$c.MissedState; url = $u; file = $name; bytes = (Get-Item $dest).Length; sha256 = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash })
            continue
        }
        Write-Host ('  downloading: ' + $name)
        try { Invoke-WebRequest -Uri $u -OutFile $dest -UseBasicParsing -UserAgent $script:UserAgent -TimeoutSec 3600 }
        catch { Write-Host ('  download failed: ' + $_.Exception.Message); continue }
        $len = (Get-Item -LiteralPath $dest).Length
        $sha = (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash
        Write-Host ('  saved ' + $name + ' (' + [math]::Round($len / 1MB, 1) + ' MB)')
        $manifestFiles.Add([pscustomobject]@{ kb = [string]$c.Kb; kind = [string]$c.Kind; missed_state = [string]$c.MissedState; url = $u; file = $name; bytes = $len; sha256 = $sha })
    }
}

$manifest = [ordered]@{
    generated_utc  = [DateTime]::UtcNow.ToString('o')
    product        = $product
    build          = $Build
    version        = $version
    architecture   = $Architecture
    image_build    = $imgLevel.Build
    image_revision = $imgLevel.Revision
    image_source   = $imgLevel.Source
    missed_only    = [bool]$MissedOnly
    missed_count   = $missed.Count
    present_count  = $present.Count
    out_dir        = $OutDir
    files          = @($manifestFiles)
}
$reportDir = Join-Path $fullWs 'Reports'
if (-not (Test-Path -LiteralPath $reportDir)) { [void](New-Item -ItemType Directory -Path $reportDir -Force) }
$manifestPath = Join-Path $reportDir 'DOWNLOAD-MANIFEST.json'
[System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ''
Write-Host ('Downloaded/verified ' + @($manifestFiles).Count + ' package file(s).')
Write-Host ('Manifest: ' + $manifestPath)
