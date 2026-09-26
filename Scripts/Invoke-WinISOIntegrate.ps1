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

function Log { param([string]$m) $ts = Get-Date -Format 'HH:mm:ss'; Write-Host ("[$ts] $m") }

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
Log ('packages to integrate: ' + (($Packages | ForEach-Object { Split-Path $_ -Leaf }) -join ', '))
if ($DryRun) { Log 'DryRun: stopping before mount'; exit 0 }

# ---------- 3. mount + integrate ----------
$mnt = Join-Path $Work 'Mount'
if (Test-Path -LiteralPath $mnt) { [void](Remove-Item -LiteralPath $mnt -Recurse -Force -ErrorAction SilentlyContinue) }
[void](New-Item -ItemType Directory -Path $mnt -Force)
Log ('mounting ' + $wim + ' index 1 -> ' + $mnt)
$null = & $script:Dism /English /Mount-Image /ImageFile:$wim /Index:1 /MountDir:$mnt 2>&1 | Out-String
$mounted = $true
try {
    foreach ($pkg in $Packages) {
        Log ('Add-Package ' + (Split-Path $pkg -Leaf))
        $r = & $script:Dism /English /Image:$mnt /Add-Package /PackagePath:$pkg /NoRestart 2>&1 | Out-String
        $tail = (($r -split "`r?`n") | Where-Object { $_ -match 'Error|completed successfully|Processing' } | Select-Object -Last 3) -join ' | '
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
$name = 'Win11_Pro_Updated_' + $b + '.' + $rv + '.iso'

if (-not (Test-Path -LiteralPath $OutDir)) { [void](New-Item -ItemType Directory -Path $OutDir -Force) }
$outIso = Join-Path $OutDir $name
Log ('rebuilding ISO -> ' + $outIso)
& $script:Oscdimg -m -o -u2 -udfver102 ('-bootdata:2#p0,e,b' + (Join-Path $media 'boot\etfsboot.com') + '#pEF,e,b' + (Join-Path $media 'efi\microsoft\boot\efisys.bin')) $media $outIso 2>$null | Select-Object -Last 4 | ForEach-Object { Log ('  ' + $_) }
if (Test-Path -LiteralPath $outIso) {
    $sha = (Get-FileHash -LiteralPath $outIso -Algorithm SHA256).Hash
    Log ('ISO built: ' + $outIso + '  (' + [math]::Round((Get-Item $outIso).Length / 1GB, 2) + ' GB)')
    Log ('SHA256: ' + $sha)
    [System.IO.File]::WriteAllText((Join-Path $OutDir 'ISO-SHA256.txt'), ($sha + '  ' + $outIso))
} else { Log 'ISO NOT produced' }
Log 'DONE'
