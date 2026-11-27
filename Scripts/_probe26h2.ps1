Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WinISOService.psm1') -Force -WarningAction SilentlyContinue

$queries = @(
    'Windows 11 26H2 Cumulative Update',
    '.NET Framework 26H2 Cumulative Update',
    'Windows 11 26H2 Safe OS Dynamic Update',
    'Windows 11 26H2 Setup Dynamic Update'
)
foreach ($q in $queries) {
    Write-Host ('=== ' + $q)
    $res = Get-WinISOCatalogSearch -Query $q -MaxResults 40
    if (-not $res.Ok) { Write-Host ('  FAILED: ' + $res.Error); continue }
    $rows = @($res.Rows)
    Write-Host ('  rows: ' + $rows.Count)
    foreach ($r in $rows) {
        $t = [string]$r.Title
        if ($t -notmatch '(?i)26H2') { continue }
        if ($t -notmatch '(?i)\bx64\b') { continue }
        Write-Host ('  ' + [string]$r.Kb + '  ' + $t)
    }
}
