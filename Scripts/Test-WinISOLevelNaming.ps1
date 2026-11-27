# Test-WinISOLevelNaming.ps1
# Headless checks for the output ISO naming rules.
#
# Verifies that the file name always carries the level the image reaches AFTER
# the commit (the level its applied packages declare), never the source level,
# and that the level readers pick up the record Phase 4 writes. No image, DISM
# call or admin rights are required.
#
# Exit codes: 0 = all checks passed, 1 = at least one check failed.
#
# Example:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Scripts\Test-WinISOLevelNaming.ps1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WinISOService.psm1') -Force

$script:pass = 0
$script:fail = 0
function Check([string]$Name, [string]$Actual, [string]$Expected) {
    if ($Actual -eq $Expected) { $script:pass++; Write-Host ('  PASS  ' + $Name + ' -> ' + $Actual) }
    else { $script:fail++; Write-Host ('  FAIL  ' + $Name + ' -> got "' + $Actual + '" expected "' + $Expected + '"') -ForegroundColor Red }
}

Write-Host 'Resolve-WinISOOutputIsoName'
$svc = [pscustomobject]@{ Build = 26300; Revision = 9974; Edition = 'Windows 11 Pro'; LevelSource = 'applied-package' }
Check 'source level is re-based' (Resolve-WinISOOutputIsoName -Requested 'windows11pro26300.9457.iso' -Serviced $svc) 'windows11pro26300.9974.iso'
Check 'already correct level survives' (Resolve-WinISOOutputIsoName -Requested 'windows11pro26300.9974.iso' -Serviced $svc) 'windows11pro26300.9974.iso'
Check 'no request names from edition+level' (Resolve-WinISOOutputIsoName -Requested '' -Serviced $svc -Architecture 'x64') 'windows11pro26300.9974.iso'
Check 'custom name gains the level' (Resolve-WinISOOutputIsoName -Requested 'my-media.iso' -Serviced $svc) 'my-media_26300.9974.iso'
Check 'arm64 keeps its arch token' (Resolve-WinISOOutputIsoName -Requested 'windows11pro.arm6426300.9457.iso' -Serviced $svc) 'windows11pro.arm6426300.9974.iso'
$none = [pscustomobject]@{ Build = 0; Revision = 0; Edition = ''; LevelSource = '' }
Check 'unknown level keeps the request' (Resolve-WinISOOutputIsoName -Requested 'windows11pro26300.9457.iso' -Serviced $none) 'windows11pro26300.9457.iso'
Check 'unknown level uses the fallback' (Resolve-WinISOOutputIsoName -Requested '' -Serviced $none -FallbackName 'WinISO-26300-x64-stamp.iso') 'WinISO-26300-x64-stamp.iso'
Check 'edition token follows the image name' (Resolve-WinISOOutputIsoName -Requested '' -Serviced ([pscustomobject]@{ Build = 26300; Revision = 9974; Edition = 'Windows 11 Home'; LevelSource = 'serviced-wim' })) 'windows11home26300.9974.iso'

Write-Host 'Get-WinISOAppliedUpdateLevel'
$manifest = Join-Path $env:TEMP ('man-' + [guid]::NewGuid().ToString('N') + '.json')
@'
{ "candidates": [
  { "kb": "KB5132061", "title": "2026-11 Cumulative Update for Windows 11, version 26H2 for x64-based Systems (KB5132061) (26300.9974)" },
  { "kb": "KB5132057", "title": "2026-11 Cumulative Update Preview for Windows 11, version 26H2 for x64-based Systems (KB5132057) (26300.10075)" },
  { "kb": "KB5137006", "title": "2026-11 Cumulative Update Preview for .NET Framework 3.5 and 4.8.1 for Windows 11, version 26H2 for x64 (KB5137006)" },
  { "kb": "KB5135185", "title": "2026-11 Setup Dynamic Update for Windows 11, version 26H1 for x64-based Systems (KB5135185)" }
] }
'@ | Set-Content -LiteralPath $manifest -Encoding UTF8

function New-Srv([string[]]$Kb) {
    $u = @()
    foreach ($k in $Kb) { $u += [pscustomobject]@{ Kb = $k; Result = 'Applied' } }
    return [pscustomobject]@{ images = @([pscustomobject]@{ Index = 1; Updates = $u }) }
}
$l1 = Get-WinISOAppliedUpdateLevel -ServicingResults (New-Srv @('KB5132061', 'KB5137006')) -UpdateManifest $manifest -Build 26300 -FallbackRevision 9457
Check '3061 applied -> 26300.9974' ($l1.Build.ToString() + '.' + $l1.Revision.ToString()) '26300.9974'
Check 'level source is the package' $l1.LevelSource 'applied-package'
Check 'level KB recorded' $l1.LevelKb 'KB5132061'
$l2 = Get-WinISOAppliedUpdateLevel -ServicingResults (New-Srv @('KB5132057')) -UpdateManifest $manifest -Build 26300 -FallbackRevision 9457
Check 'preview alone -> 26300.10075' ($l2.Build.ToString() + '.' + $l2.Revision.ToString()) '26300.10075'
$l3 = Get-WinISOAppliedUpdateLevel -ServicingResults (New-Srv @()) -UpdateManifest $manifest -Build 26300 -FallbackRevision 9457
Check 'nothing applied -> source level' ($l3.Build.ToString() + '.' + $l3.Revision.ToString()) '26300.9457'
Check 'nothing applied -> image source' $l3.LevelSource 'image'

Write-Host 'Get-WinISOServicedLevel'
$ws = Join-Path $env:TEMP ('winiso-level-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $ws 'State') -Force
@'
{ "build": 26300, "revision": 9974, "level_source": "applied-package", "edition": "Windows 11 Pro", "output_iso_name": "windows11pro26300.9974.iso" }
'@ | Set-Content -LiteralPath (Join-Path $ws 'State\SERVICED-LEVEL.json') -Encoding UTF8
$g = Get-WinISOServicedLevel -Workspace $ws
Check 'reads the commit record' ($g.Build.ToString() + '.' + $g.Revision.ToString()) '26300.9974'
Check 'reads the recorded edition' $g.Edition 'Windows 11 Pro'
Check 'reads the level source' $g.LevelSource 'applied-package'
Remove-Item -LiteralPath $ws -Recurse -Force
Remove-Item -LiteralPath $manifest -Force

Write-Host ''
Write-Host ('RESULT: ' + $script:pass + ' passed, ' + $script:fail + ' failed')
if ($script:fail -gt 0) { exit 1 }
