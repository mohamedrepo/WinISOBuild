Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'WinISOService.psm1') -Force -WarningAction SilentlyContinue
$res = Get-WinISOCatalogSearch -Query '"Windows 11" .NET Framework Cumulative Update' -MaxResults 30
foreach ($r in @($res.Rows)) {
    $t = [string]$r.Title
    if ($t -notmatch 'KB5127694') { continue }
    $size = ''
    if ($r.PSObject.Properties['Size']) { $size = ([string]$r.PSObject.Properties['Size'].Value -replace '\s+', ' ').Trim() }
    Write-Output ('TITLE: ' + $t)
    Write-Output ('SIZE : ' + $size)
}
$l = Get-Item 'D:\WimMount\Updates\windows11.0-kb5127694-x64-ndp481_a1a6f6d3c61e46a77278881fc5f7245bcf09ce3f.msu'
Write-Output ('LOCAL: ' + $l.Length)
