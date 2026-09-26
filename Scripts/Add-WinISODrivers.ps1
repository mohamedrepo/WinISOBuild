# Add-WinISODrivers.ps1
# Injects a driver folder into the already-integrated Pro install.wim and
# rebuilds a bootable ISO (UDF, BIOS+UEFI) named with the full build number.

[CmdletBinding()]
param(
    [string]$Media = 'C:\WinISOBuild\Integrate\Media',
    [string]$Drivers = 'D:\WimMount\Drivers-Laptop',
    [string]$Mount = 'C:\WinISOBuild\Integrate\Mount2',
    [string]$OutDir = 'D:\WimMount\Output'
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$script:Dism = "$env:SystemRoot\System32\Dism.exe"
$script:Oscdimg = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\OSCDIMG\oscdimg.exe'

function Log { param([string]$m) Write-Host ('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $m) }

$wim = Join-Path $Media 'sources\install.wim'
if (-not (Test-Path -LiteralPath $wim)) { throw ('install.wim not found: ' + $wim) }
if (-not (Test-Path -LiteralPath $Drivers)) { throw ('drivers folder not found: ' + $Drivers) }

if (Test-Path -LiteralPath $Mount) { [void](Remove-Item -LiteralPath $Mount -Recurse -Force -ErrorAction SilentlyContinue) }
[void](New-Item -ItemType Directory -Path $Mount -Force)

Log ('mounting ' + $wim + ' index 1 -> ' + $Mount)
$null = & $script:Dism /English /Mount-Image /ImageFile:$wim /Index:1 /MountDir:$Mount 2>&1 | Out-String
try {
    Log ('Add-Driver /Recurse from ' + $Drivers)
    $dr = & $script:Dism /English /Image:$Mount /Add-Driver /Driver:$Drivers /Recurse /NoRestart 2>&1 | Out-String
    $okc = ([regex]::Matches($dr, 'successfully installed')).Count
    $errc = ([regex]::Matches($dr, '(?i)error')).Count
    Log ('  drivers installed: ' + $okc + '  (error lines: ' + $errc + ')')
    Log 'level after:'
    $gi = & $script:Dism /English /Get-ImageInfo /ImageFile:$wim /Index:1 2>&1 | Out-String
    (($gi -split "`r?`n") | Where-Object { $_ -match '^\s*(Version|ServicePack Build|Edition|Name)\s+:' } | ForEach-Object { $_.Trim() }) | ForEach-Object { Log ('  ' + $_) }
}
finally {
    Log 'committing'
    $null = & $script:Dism /English /Unmount-Image /MountDir:$Mount /Commit 2>&1 | Out-String
    Log 'commit done'
}

# rebuild
$gi2 = & $script:Dism /English /Get-ImageInfo /ImageFile:$wim /Index:1 2>&1 | Out-String
$mv = [regex]::Match($gi2, '(?im)^\s*Version\s+:\s*10\.0\.(\d+)'); $b = '0'; if ($mv.Success) { $b = $mv.Groups[1].Value }
$mr = [regex]::Match($gi2, '(?im)^\s*ServicePack Build\s+:\s*(\d+)'); $rv = '0'; if ($mr.Success) { $rv = $mr.Groups[1].Value }
$name = 'Win11_Pro_Updated_' + $b + '.' + $rv + '.iso'
if (-not (Test-Path -LiteralPath $OutDir)) { [void](New-Item -ItemType Directory -Path $OutDir -Force) }
$outIso = Join-Path $OutDir $name
Log ('rebuilding ISO -> ' + $outIso)
& $script:Oscdimg -m -o -u2 -udfver102 ('-bootdata:2#p0,e,b' + (Join-Path $Media 'boot\etfsboot.com') + '#pEF,e,b' + (Join-Path $Media 'efi\microsoft\boot\efisys.bin')) $Media $outIso 2>$null | Select-Object -Last 3 | ForEach-Object { Log ('  ' + $_) }
if (Test-Path -LiteralPath $outIso) {
    $sha = (Get-FileHash -LiteralPath $outIso -Algorithm SHA256).Hash
    Log ('ISO built: ' + $outIso + '  (' + [math]::Round((Get-Item $outIso).Length / 1GB, 2) + ' GB)')
    Log ('SHA256: ' + $sha)
    [System.IO.File]::WriteAllText((Join-Path $OutDir 'ISO-SHA256.txt'), ($sha + '  ' + $outIso))
}
Log 'DONE'
