# Initialize-WorkSpace.ps1
# Creates the workspace directory layout for the Windows 10/11 ISO servicing
# toolchain and (on first run) writes the initial State\STATE.json.
#
# Idempotent: existing directories are left alone and an existing STATE.json
# is NEVER overwritten (restartability depends on it).
#
# Compatibility : Windows PowerShell 5.1 and PowerShell 7.
# Encoding      : BOM-less UTF-8, ASCII-only content.
#
# Example:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Initialize-WorkSpace.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Initialize-WorkSpace.ps1 -Workspace E:\Servicing

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Workspace = 'D:\WimMount',
    [switch]$NoState
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$full = [System.IO.Path]::GetFullPath($Workspace)
$dirs = @('Source', 'ExtractedISO', 'Mount', 'Updates', 'Drivers', 'Scripts', 'Logs', 'Output', 'Backup', 'Reports', 'State')

$created = @()
$present = @()
foreach ($d in $dirs) {
    $p = Join-Path $full $d
    if (Test-Path -LiteralPath $p -PathType Container) {
        $present += $p
        continue
    }
    if ($PSCmdlet.ShouldProcess($p, 'Create directory')) {
        [void](New-Item -ItemType Directory -Path $p -Force)
        $created += $p
    }
}

$stateInitialized = $false
$statePath = Join-Path $full 'State\STATE.json'
if (-not $NoState) {
    if (Test-Path -LiteralPath $statePath) {
        Write-Verbose ('STATE.json already exists; leaving it untouched: ' + $statePath)
    }
    else {
        $state = [ordered]@{
            phase           = 0
            status          = 'idle'
            completed_steps = @()
            failed_steps    = @()
            artifacts       = @{}
            errors          = @()
            next_action     = 'Phase 1 (environment audit) has not been run yet. Run Scripts\Invoke-WinISOService.ps1 -TargetPhase 1.'
        }
        $json = $state | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($statePath, $json, (New-Object System.Text.UTF8Encoding($false)))
        $stateInitialized = $true
    }
}

$summary = [pscustomobject]@{
    Workspace        = $full
    DirectoriesTotal = $dirs.Count
    DirectoriesCreated = $created.Count
    DirectoriesPresent = $present.Count
    CreatedPaths     = @($created)
    StateJsonPath    = $statePath
    StateInitialized = $stateInitialized
}
Write-Output ($summary | ConvertTo-Json -Depth 5)
exit 0
