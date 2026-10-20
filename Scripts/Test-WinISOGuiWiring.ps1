# Test-WinISOGuiWiring.ps1
# Headless wiring check for WinISO-GUI.ps1.
#
# Builds the real WinForms form, all of its controls, the timers and the
# meta/name helpers, then exits without showing a window (-NoShow). This
# catches the class of bug that a syntax check cannot: a control variable that
# is never assigned, an out-of-range Controls[] index, an event handler wired
# to a null object, or a StrictMode property read that would crash the GUI the
# moment a user opens it.
#
# Exit codes: 0 = wiring OK, 1 = wiring broken.
#
# Example:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-WinISOGuiWiring.ps1

[CmdletBinding()]
param([string]$GuiPath = '')

$ErrorActionPreference = 'Stop'

if (-not $GuiPath) { $GuiPath = Join-Path $PSScriptRoot 'WinISO-GUI.ps1' }
if (-not (Test-Path -LiteralPath $GuiPath -PathType Leaf)) {
    Write-Host ('MISSING: ' + $GuiPath) -ForegroundColor Red
    exit 1
}

$psExe = (Get-Process -Id $PID).Path
if (-not $psExe) { $psExe = 'powershell.exe' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outPath = Join-Path $env:TEMP ('winiso-guicheck-' + $stamp + '.out.log')
$errPath = Join-Path $env:TEMP ('winiso-guicheck-' + $stamp + '.err.log')

$proc = Start-Process -FilePath $psExe -NoNewWindow -Wait -PassThru `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $GuiPath, '-NoShow', '-NoElevate') `
        -RedirectStandardOutput $outPath -RedirectStandardError $errPath

$stdout = ''
if (Test-Path -LiteralPath $outPath) { $stdout = [string](Get-Content -LiteralPath $outPath -Raw -Encoding UTF8) }
$stderr = ''
if (Test-Path -LiteralPath $errPath) { $stderr = [string](Get-Content -LiteralPath $errPath -Raw -Encoding UTF8) }
Remove-Item -LiteralPath $outPath, $errPath -Force -ErrorAction SilentlyContinue

if ($proc.ExitCode -ne 0 -or $stdout -notmatch 'GUICHECK OK') {
    Write-Host 'WIRING FAILED: the GUI did not build cleanly.' -ForegroundColor Red
    Write-Host ('  exit code: ' + $proc.ExitCode) -ForegroundColor Red
    foreach ($line in @($stdout -split "`r?`n")) { if ($line) { Write-Host ('  out: ' + $line) -ForegroundColor Red } }
    foreach ($line in @($stderr -split "`r?`n")) { if ($line) { Write-Host ('  err: ' + $line) -ForegroundColor Red } }
    exit 1
}

Write-Host 'WIRING OK: form, controls, timers and meta helpers constructed (no window shown).' -ForegroundColor Green
foreach ($line in @($stdout -split "`r?`n")) {
    if ($line -match '^GUICHECK (tree|last-applied|enriched name)') { Write-Host ('  ' + $line) }
}
# A populated control tree is the difference between a window that renders and
# an empty grey one, so require the panes to be attached.
if ($stdout -notmatch 'GUICHECK tree\s*:\s*(\d+) controls') {
    Write-Host 'WIRING FAILED: the GUI did not report its control tree.' -ForegroundColor Red
    exit 1
}
if ([int]$Matches[1] -lt 50) {
    Write-Host ('WIRING FAILED: only ' + $Matches[1] + ' controls are attached to the form.') -ForegroundColor Red
    exit 1
}
if ($stderr -and $stderr.Trim()) { Write-Host ('  stderr: ' + $stderr.Trim()) -ForegroundColor Yellow }
exit 0
