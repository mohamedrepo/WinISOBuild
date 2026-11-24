# Invoke-WinISOIntegrate.ps1
# Integrates the downloaded updates (.msu in the Updates folder) into the Pro
# install.wim taken from an existing ISO, then rebuilds a bootable ISO.
# Read-only on the source ISO; all work happens on copies under -Work.

[CmdletBinding()]
param(
    [string]$SourceIso = 'D:\WimMount\ISO\Win11_25H2_Pro_Updated.iso',
    [string]$UpdatesDir = 'D:\WimMount\Updates',
    [string]$Work = 'C:\WinISOBuild\Integrate',
    [string]$OutDir = 'D:\WimMount\Output',
    [string[]]$Packages = @(),   # explicit .msu filenames; empty = auto (latest CU + .NET)
    [switch]$SkipRebuild,
    [switch]$DryRun
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$script:Dism = "$env:SystemRoot\System32\Dism.exe"
$script:Oscdimg = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\OSCDIMG\oscdimg.exe'

$modulePath = Join-Path $PSScriptRoot 'WinISOIntegrity.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw ('Required module not found: ' + $modulePath) }
Import-Module -Name $modulePath -Force -ErrorAction Stop

function Log { param([string]$m) $ts = Get-Date -Format 'HH:mm:ss'; Write-Host ("[$ts] $m") }

# Element reader for DISM text, used by the health check and package probing.
function Get-DismText {
    param([string[]]$Arguments)
    $out = & $script:Dism @Arguments 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $out }
}

function Get-IsoLetter {
    param([string]$IsoPath)
    $before = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[A-Z]$' } | ForEach-Object { [string]$_.Name }))
    $img = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
    for ($i = 0; $i -lt 120; $i++) {
        Start-Sleep -Milliseconds 500
        $now = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[A-Z]$' } | ForEach-Object { [string]$_.Name }))
        $new = @($now | Where-Object { $before -notcontains $_ })
        foreach ($l in $new) { if (Test-Path -LiteralPath ("${l}:\sources\install.wim")) { return $l } }
    }
    return ''
}

# ---------- 1. extract the source ISO media ----------
$media = Join-Path $Work 'Media'
if (Test-Path -LiteralPath $media) { Remove-Item -LiteralPath $media -Recurse -Force -ErrorAction SilentlyContinue }
[void](New-Item -ItemType Directory -Path $media -Force)
Log ('extracting ISO -> ' + $media)
$letter = Get-IsoLetter -IsoPath $SourceIso
if (-not $letter) { throw 'could not mount the source ISO' }
try { Copy-Item -Path ("${letter}:\*") -Destination $media -Recurse -Force }
finally { Dismount-DiskImage -ImagePath $SourceIso -ErrorAction SilentlyContinue | Out-Null }
Get-ChildItem -LiteralPath $media -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { if ($_.IsReadOnly) { $_.IsReadOnly = $false } }
Log 'media extracted, read-only cleared'

$wim = Join-Path $media 'sources\install.wim'

# ---------- 2. choose packages ----------
if (-not $Packages -or $Packages.Count -eq 0) {
    $all = @(Get-ChildItem -LiteralPath $UpdatesDir -File -Filter *.msu -ErrorAction SilentlyContinue)
    # latest cumulative update = the kb* .msu with the largest size that is not a .NET (ndp) package
    $cu = $all | Where-Object { $_.Name -notmatch 'ndp' } | Sort-Object Length -Descending | Select-Object -First 1
    $dn = $all | Where-Object { $_.Name -match 'ndp' } | Sort-Object Length -Descending | Select-Object -First 1
    $Packages = @()
    if ($cu) { $Packages += $cu.FullName }
    if ($dn) { $Packages += $dn.FullName }
}
# A servicing stack update has to be applied before the cumulative update, and
# the order the caller listed is refused rather than silently repaired, so the
# mistake is visible instead of hidden.
$orderProblems = @(Test-WinISOPackageOrder -Packages $Packages)
if ($orderProblems.Count -gt 0) {
    foreach ($p in $orderProblems) { Log ('ORDER ERROR: ' + $p) }
    throw ('the package order is not serviceable; apply the servicing stack update first')
}
$Packages = @(Get-WinISOPackageOrder -Packages $Packages | ForEach-Object { $_.Package })
Log ('packages to integrate: ' + (($Packages | ForEach-Object { Split-Path $_ -Leaf }) -join ', '))

# Refuse a truncated or altered download before DISM is asked to apply it.
$manifestPath = Join-Path (Split-Path -Parent ([System.IO.Path]::GetFullPath($UpdatesDir))) 'Reports\DOWNLOAD-MANIFEST.json'
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    $payload = Test-WinISOManifestPayload -ManifestPath $manifestPath -DownloadDir $UpdatesDir
    Log ('manifest check: ' + @($payload.Ok).Count + ' of ' + $payload.Checked + ' package(s) match ' + $manifestPath)
    foreach ($m in @($payload.Mismatched)) {
        Log ('INTEGRITY ERROR: ' + $m.File + ' ' + $m.Reason)
        throw ('package ' + $m.File + ' does not match the download manifest; re-download it before integrating')
    }
} else {
    Log ('no download manifest at ' + $manifestPath + '; package hashes cannot be checked')
}

if ($DryRun) { Log 'DryRun: packages verified, stopping before mount'; exit 0 }

# ---------- 3. mount + integrate ----------
$mnt = Join-Path $Work 'Mount'
if (Test-Path -LiteralPath $mnt) { [void](Remove-Item -LiteralPath $mnt -Recurse -Force -ErrorAction SilentlyContinue) }
[void](New-Item -ItemType Directory -Path $mnt -Force)
Log ('mounting ' + $wim + ' index 1 -> ' + $mnt)
$logDir = Join-Path (Split-Path -Parent ([System.IO.Path]::GetFullPath($UpdatesDir))) 'Logs'
if (-not (Test-Path -LiteralPath $logDir)) { [void](New-Item -ItemType Directory -Path $logDir -Force) }
$dismLog = Join-Path $logDir ('dism-integrate-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
$null = & $script:Dism /English /Mount-Image /ImageFile:$wim /Index:1 /MountDir:$mnt /LogPath:$dismLog 2>&1 | Out-String
$mounted = $true
try {
    # Health before servicing: a damaged component store otherwise shows up as
    # an unrelated Add-Package failure much later.
    $health = Get-DismText -Arguments @('/English', ('/Image:' + $mnt), '/Cleanup-Image', '/CheckHealth')
    if ($health.Code -ne 0 -or [string]$health.Text -match '(?i)corrupt|not repairable') {
        throw ('the image component store is damaged (DISM /Cleanup-Image /CheckHealth exit ' + $health.Code + '); repair or replace the source media')
    }
    Log 'component store health: OK'

    $level = Get-DismText -Arguments @('/English', '/Get-ImageInfo', ('/ImageFile:' + $wim), '/Index:1')
    $mb = [regex]::Match([string]$level.Text, '(?im)^\s*Version\s+:\s*10\.0\.(\d+)')
    $mr = [regex]::Match([string]$level.Text, '(?im)^\s*ServicePack Build\s+:\s*(\d+)')
    $imageBuild = 0; $imageRevision = 0
    if ($mb.Success) { $imageBuild = [int]$mb.Groups[1].Value }
    if ($mr.Success) { $imageRevision = [int]$mr.Groups[1].Value }
    Log ('image level before integration: ' + $imageBuild + '.' + $imageRevision)

    foreach ($pkg in $Packages) {
        $info = $null
        $pi = Get-DismText -Arguments @('/English', '/Get-PackageInfo', ('/PackagePath:' + $pkg))
        if ($pi.Code -eq 0) { $info = ConvertFrom-WinISOPackageInfoText -Text $pi.Text }
        if ($info -and (Test-WinISOPackageAlreadyInImage -Kind $info.Kind -PackageBuild $info.Build -PackageRevision $info.Revision -ImageBuild $imageBuild -ImageRevision $imageRevision)) {
            Log ('SKIP ' + (Split-Path $pkg -Leaf) + ': the image is already at ' + $imageBuild + '.' + $imageRevision + ' and this package targets ' + $info.Build + '.' + $info.Revision)
            continue
        }
        Log ('Add-Package ' + (Split-Path $pkg -Leaf))
        $r = & $script:Dism /English /Image:$mnt /Add-Package /PackagePath:$pkg /NoRestart /LogPath:$dismLog 2>&1 | Out-String
        $tail = (($r -split "`r?`n") | Where-Object { $_ -match 'Error|completed successfully|Processing|not applicable' } | Select-Object -Last 3) -join ' | '
        Log ('  -> ' + $tail)
    }
    Log 'new level:'
    $gi = & $script:Dism /English /Get-ImageInfo /ImageFile:$wim /Index:1 2>&1 | Out-String
    (($gi -split "`r?`n") | Where-Object { $_ -match '^\s*(Version|ServicePack Build|Edition|Name)\s+:' } | ForEach-Object { $_.Trim() }) | ForEach-Object { Log ('  ' + $_) }
}
finally {
    if ($mounted) {
        Log 'committing image'
        $null = & $script:Dism /English /Unmount-Image /MountDir:$mnt /Commit 2>&1 | Out-String
        Log 'commit done'
    }
}

if ($SkipRebuild) { Log 'SkipRebuild: done'; exit 0 }

# ---------- 4. rebuild the ISO ----------
$gi2 = & $script:Dism /English /Get-ImageInfo /ImageFile:$wim /Index:1 2>&1 | Out-String
$mv = [regex]::Match($gi2, '(?im)^\s*Version\s+:\s*10\.0\.(\d+)'); $b = '0'; if ($mv.Success) { $b = $mv.Groups[1].Value }
$mr = [regex]::Match($gi2, '(?im)^\s*ServicePack Build\s+:\s*(\d+)'); $rv = '0'; if ($mr.Success) { $rv = $mr.Groups[1].Value }
$name = 'windows11pro' + $b + '.' + $rv + '.iso'

if (-not (Test-Path -LiteralPath $OutDir)) { [void](New-Item -ItemType Directory -Path $OutDir -Force) }
$outIso = Join-Path $OutDir $name
Log ('rebuilding ISO -> ' + $outIso)
& $script:Oscdimg -m -o -u2 -udfver102 ('-bootdata:2#p0,e,b' + (Join-Path $media 'boot\etfsboot.com') + '#pEF,e,b' + (Join-Path $media 'efi\microsoft\boot\efisys.bin')) $media $outIso 2>$null | Select-Object -Last 4 | ForEach-Object { Log ('  ' + $_) }
if (Test-Path -LiteralPath $outIso) {
    $sha = (Get-FileHash -LiteralPath $outIso -Algorithm SHA256).Hash
    Log ('ISO built: ' + $outIso + '  (' + [math]::Round((Get-Item $outIso).Length / 1GB, 2) + ' GB)')
    Log ('SHA256: ' + $sha)
    [System.IO.File]::WriteAllText((Join-Path $OutDir 'ISO-SHA256.txt'), ($sha + '  ' + $outIso))

    # Persist the build/revision-derived output suffix used for this ISO.
    $outBase = [System.IO.Path]::GetFileNameWithoutExtension($outIso)
    $buildRev = @{ }
    if ($b -match '^[0-9]+$') { $buildRev.build = [int]$b }
    if ($rv -match '^[0-9]+$') { $buildRev.servicePackBuild = [int]$rv }
    $meta = @{
        output_iso_name = $outIso
        output_iso_base = $outBase
        build           = $buildRev.build
        servicePackBuild= $buildRev.servicePackBuild
        integrated_at   = (Get-Date -Format 'o')
        source_media    = $SourceIso
    }
    $reportPath = Join-Path $OutDir 'OUTPUT-ISO-META.json'
    [System.IO.File]::WriteAllText($reportPath, ($meta | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    Log ('recorded output ISO metadata: ' + $reportPath)
} else { Log 'ISO NOT produced' }
Log 'DONE'
