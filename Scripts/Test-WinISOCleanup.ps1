# Test-WinISOCleanup.ps1
# Headless checks for Clear-WinISOWorkingFolders.
#
# Builds a throw-away workspace, fills it the way a finished build leaves it and
# verifies that the cleanup removes only the intermediate trees: the output ISO,
# the hash file and the downloaded packages survive, a .gitkeep stays, and
# -RemoveUpdates is the only way to delete the packages. -DryRun must change
# nothing. No image, DISM mount or admin rights are required.
#
# Exit codes: 0 = all checks passed, 1 = at least one check failed.
#
# Example:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\Test-WinISOCleanup.ps1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WinISOService.psm1') -Force

$ws = Join-Path $env:TEMP ('ws-clean-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $ws 'Mount\Image1') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $ws 'Backup') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $ws 'ExtractedISO\sources') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $ws 'Output') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $ws 'Updates\_expanded') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $ws 'Work') -Force
$bytes = New-Object byte[] (1MB)
[System.IO.File]::WriteAllBytes((Join-Path $ws 'Mount\Image1\install.wim'), $bytes)
[System.IO.File]::WriteAllBytes((Join-Path $ws 'Backup\install.wim.pre-servicing'), $bytes)
[System.IO.File]::WriteAllBytes((Join-Path $ws 'ExtractedISO\sources\boot.wim'), $bytes)
[System.IO.File]::WriteAllText((Join-Path $ws 'Output\windows11pro26300.9974.iso'), 'iso')
[System.IO.File]::WriteAllText((Join-Path $ws 'Output\ISO-SHA256.txt'), 'hash')
[System.IO.File]::WriteAllText((Join-Path $ws 'Updates\_expanded\x.cab'), 'cab')
[System.IO.File]::WriteAllText((Join-Path $ws 'Updates\windows11.0-kb5132061-x64.msu'), 'msu')
[System.IO.File]::WriteAllText((Join-Path $ws 'Mount\.gitkeep'), '')
Set-ItemProperty -LiteralPath (Join-Path $ws 'Output\windows11pro26300.9974.iso') -Name IsReadOnly -Value $false

$dry = Clear-WinISOWorkingFolders -Workspace $ws -DryRun
Write-Host ('DRY removed: ' + (@($dry.Removed) -join ' | '))
Write-Host ('DRY kept: ' + (@($dry.Skipped) -join ' | '))
Write-Host ('DRY freed MB: ' + [math]::Round([double]$dry.BytesFreed / 1MB, 2))
if (-not (Test-Path (Join-Path $ws 'Mount\Image1\install.wim'))) { throw 'dry run deleted a file' }

$real = Clear-WinISOWorkingFolders -Workspace $ws
Write-Host ('REAL removed: ' + (@($real.Removed) -join ' | '))
Write-Host ('REAL kept: ' + (@($real.Skipped) -join ' | '))
Write-Host ('REAL freed MB: ' + [math]::Round([double]$real.BytesFreed / 1MB, 2))

$checks = @(
    @{ Name = 'Mount contents removed'; Pass = -not (Test-Path (Join-Path $ws 'Mount\Image1')) },
    @{ Name = 'Mount .gitkeep kept'; Pass = (Test-Path (Join-Path $ws 'Mount\.gitkeep')) },
    @{ Name = 'Backup removed'; Pass = -not (Test-Path (Join-Path $ws 'Backup\install.wim.pre-servicing')) },
    @{ Name = 'ExtractedISO removed'; Pass = -not (Test-Path (Join-Path $ws 'ExtractedISO\sources\boot.wim')) },
    @{ Name = 'Output ISO kept'; Pass = (Test-Path (Join-Path $ws 'Output\windows11pro26300.9974.iso')) },
    @{ Name = 'SHA file kept'; Pass = (Test-Path (Join-Path $ws 'Output\ISO-SHA256.txt')) },
    @{ Name = 'Updates msu kept by default'; Pass = (Test-Path (Join-Path $ws 'Updates\windows11.0-kb5132061-x64.msu')) },
    @{ Name = '_expanded removed'; Pass = -not (Test-Path (Join-Path $ws 'Updates\_expanded\x.cab')) }
)
$fail = 0
foreach ($c in $checks) { if ($c.Pass) { Write-Host ('  PASS  ' + $c.Name) } else { $fail++; Write-Host ('  FAIL  ' + $c.Name) -ForegroundColor Red } }

$withUpdates = Clear-WinISOWorkingFolders -Workspace $ws -RemoveUpdates
if (-not (Test-Path (Join-Path $ws 'Updates\windows11.0-kb5132061-x64.msu'))) { Write-Host '  PASS  -RemoveUpdates deletes the packages' } else { $fail++; Write-Host '  FAIL  -RemoveUpdates left the package' -ForegroundColor Red }

Remove-Item -LiteralPath $ws -Recurse -Force
Write-Host ''
Write-Host ('RESULT: ' + $(if ($fail -eq 0) { 'all cleanup checks passed' } else { $fail.ToString() + ' failed' }))
if ($fail -gt 0) { exit 1 }
