# Validate-WinISO.ps1
# Static + wiring validation for the toolchain entry points.
#
#  1. Parses every shipped PowerShell entry point (syntax only).
#  2. Runs the headless GUI wiring check (Test-WinISOGuiWiring.ps1), which
#     actually constructs the WinForms form and every control without showing
#     a window. That catches null/mis-indexed control references, unwired
#     event handlers and StrictMode property reads that a parse cannot see.
#
# Exit codes: 0 = everything passed, 1 = at least one check failed.
#
# Examples:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Validate-WinISO.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Validate-WinISO.ps1 -SkipWiring

[CmdletBinding()]
param([switch]$SkipWiring)

$ErrorActionPreference = 'Stop'

$files = @(
    (Join-Path $PSScriptRoot 'WinISO-GUI.ps1'),
    (Join-Path $PSScriptRoot 'WinISOService.psm1'),
    (Join-Path $PSScriptRoot 'Invoke-WinISOService.ps1'),
    (Join-Path $PSScriptRoot 'Get-WinISOUpdates.ps1'),
    (Join-Path $PSScriptRoot 'New-UnattendXml.ps1'),
    (Join-Path $PSScriptRoot 'Initialize-WorkSpace.ps1'),
    (Join-Path $PSScriptRoot 'Invoke-WinISOIntegrate.ps1'),
    (Join-Path $PSScriptRoot 'Add-WinISODrivers.ps1'),
    (Join-Path $PSScriptRoot 'Build-WinISOUpdated.ps1'),
    (Join-Path $PSScriptRoot 'Burn-WinISOToUsb.ps1')
)

$failed = $false
foreach ($path in $files) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Host ('MISSING: ' + $path) -ForegroundColor Red
        $failed = $true
        continue
    }
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        Write-Host ('PARSE FAILED: ' + $path) -ForegroundColor Red
        foreach ($errorItem in $parseErrors) {
            Write-Host ('  Line ' + $errorItem.Extent.StartLineNumber + ', column ' + $errorItem.Extent.StartColumnNumber + ': ' + $errorItem.Message) -ForegroundColor Red
        }
        $failed = $true
    }
    else {
        Write-Host ('PARSE OK: ' + [System.IO.Path]::GetFileName($path)) -ForegroundColor Green
    }
}

if (-not $SkipWiring -and -not $failed) {
    $wiring = Join-Path $PSScriptRoot 'Test-WinISOGuiWiring.ps1'
    if (Test-Path -LiteralPath $wiring) {
        & $wiring
        if ($LASTEXITCODE -ne 0) { $failed = $true }
    }
    else {
        Write-Host ('MISSING: ' + $wiring) -ForegroundColor Red
        $failed = $true
    }
}

if ($failed) {
    Write-Host 'Validation FAILED.' -ForegroundColor Red
    exit 1
}

Write-Host 'Validation passed: parses cleanly and the GUI builds headlessly. This does not execute DISM, disk, oscdimg or USB workflows.' -ForegroundColor Yellow
exit 0
