# Clear-WinISOWorkingFolders.ps1
# Removes the intermediate trees a finished build leaves behind, so the workspace
# goes back to just inputs and deliverables:
#
#   removed by default : Mount\, Work\, Output\FAT32-Media\, Updates\_expanded\
#                        ExtractedISO\ (the extracted media tree)
#                        Backup\ (the pre-servicing WIM copy)
#   never touched      : Output\*.iso, Output\ISO-SHA256.txt, Reports\, Logs\,
#                        State\, Source\, Drivers\, Scripts\
#   opt-in             : -RemoveUpdates also deletes Updates\*.msu / *.cab
#                        -KeepBackup / -KeepExtractedIso keep those trees
#
# The command refuses to run while DISM still has an image mounted, so a cleanup
# can never pull the media out from under a running phase. It deletes only
# contents (a .gitkeep stays), never the workspace itself.
#
# Exit codes: 0 = nothing left to do or cleanup succeeded, 1 = cleanup was
# refused or a file could not be removed.
#
# Examples:
#   .\Clear-WinISOWorkingFolders.ps1 -DryRun
#   .\Clear-WinISOWorkingFolders.ps1
#   .\Clear-WinISOWorkingFolders.ps1 -KeepBackup
#   .\Clear-WinISOWorkingFolders.ps1 -RemoveUpdates

[CmdletBinding()]
param(
    [string]$Workspace = 'D:\WimMount',
    [switch]$KeepBackup,
    [switch]$KeepExtractedIso,
    [switch]$RemoveUpdates,
    [switch]$DryRun
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'WinISOService.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) { throw ('Required module not found: ' + $modulePath) }
Import-Module -Name $modulePath -Force -ErrorAction Stop

$result = Clear-WinISOWorkingFolders -Workspace $Workspace -KeepBackup:$KeepBackup -KeepExtractedIso:$KeepExtractedIso -RemoveUpdates:$RemoveUpdates -DryRun:$DryRun

if (-not $result.Ok) { Write-Host $result.Message }
foreach ($line in @($result.Removed)) { Write-Host ('  cleaned  ' + $line) }
foreach ($line in @($result.Skipped)) { Write-Host ('  kept     ' + $line) }
$gb = [math]::Round([double]$result.BytesFreed / 1GB, 2)
if ($DryRun) { Write-Host ('Would free: ' + $gb + ' GB (dry run, nothing deleted)') }
else { Write-Host ('Freed: ' + $gb + ' GB') }

if (-not $result.Ok) { exit 1 }
exit 0
