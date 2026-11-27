# Invoke-WinISOService.ps1
# Master orchestrator / state-machine entry point for the Windows 10/11 ISO
# servicing toolchain. Runs phases 1..TargetPhase in order, persists progress
# to State\STATE.json after every phase, and is restartable: phases whose
# number is <= state.phase are skipped unless -Force is used.
#
# Compatibility : Windows PowerShell 5.1 and PowerShell 7.
# Encoding      : BOM-less UTF-8, ASCII-only content.
#
# Exit codes    : 0 = all executed phases Succeeded/Partial/Skipped
#                 1 = at least one phase Failed (or a pre-flight error)
#                 3 = stopped between phases on request (State\BUILD-CANCEL.json)
#
# A stop request is only honoured at a phase boundary: the phase that is running
# finishes, so a run stopped from the GUI cannot leave an image mounted.
#
# Examples:
#   .\Invoke-WinISOService.ps1 -TargetPhase 1
#   .\Invoke-WinISOService.ps1 -SourceIso D:\WimMount\Source\Win11.iso
#   .\Invoke-WinISOService.ps1 -ShowState
#   .\Invoke-WinISOService.ps1 -Force -Profile Standard

[CmdletBinding()]
param(
    [string]$Workspace = 'D:\WimMount',
    [string]$SourceIso = '',
    [ValidateRange(1, 10)][int]$TargetPhase = 10,
    [ValidateSet('Safe', 'Standard', 'Aggressive')][string]$Profile = 'Safe',
    [switch]$AllowRemoval,
    [string[]]$RemovePackages = @(),
    [hashtable]$RemoveReasons = @{},
    [switch]$SkipDependencyAnalysis,
    [string]$Drivers = '',
    [string]$UpdateManifest = '',
    [int[]]$ImageIndexes = @(),
    [switch]$RunCleanup,
    [switch]$ResetBase,
    [hashtable]$Unattend = @{},
    [string]$UnattendFile = '',
    [string]$OutputIsoName = '',
    [int]$MinimumFreeGB = 25,
    [switch]$AllowUnoelevated,
    [string]$Build = '',
    [string]$Architecture = '',
    [switch]$SkipHash,
    [switch]$Force,
    [switch]$DryRun,
    [string[]]$SkipPhase = @(),
    [switch]$ContinueOnError,
    [switch]$ShowState
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -SkipPhase accepts an array and the command-line form "1,2,3": a -File
# argument arrives as one string, which [int[]] would read as a single number.
$skipPhases = @()
foreach ($entry in @($SkipPhase)) {
    foreach ($part in ([string]$entry).Split(',')) {
        $text = $part.Trim()
        if ($text -match '^\d+$') { $skipPhases += [int]$text }
    }
}

$modulePath = Join-Path $PSScriptRoot 'WinISOService.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw ('Required module not found: ' + $modulePath)
}
Import-Module -Name $modulePath -Force -ErrorAction Stop

$fullWorkspace = [System.IO.Path]::GetFullPath($Workspace)

# The stop request the GUI writes (pid-scoped, so a leftover file cannot stop a
# later run) and the shared helpers that read it.
$integrityModulePath = Join-Path $PSScriptRoot 'WinISOIntegrity.psm1'
if (Test-Path -LiteralPath $integrityModulePath) { Import-Module -Name $integrityModulePath -Force -ErrorAction SilentlyContinue }
$cancelPath = Get-WinISOCancelPath -Workspace $fullWorkspace
if (Test-Path -LiteralPath $cancelPath) {
    if (-not (Test-WinISOCancelRequest -Path $cancelPath -ProcessId $PID)) {
        [void](Remove-WinISOCancelRequest -Path $cancelPath)
    }
}

# Ensure the workspace layout exists (idempotent; Initialize-WorkSpace.ps1 is
# the dedicated tool, this is just a safety net so the state machine can run).
foreach ($d in @('Source', 'ExtractedISO', 'Mount', 'Updates', 'Drivers', 'Scripts', 'Logs', 'Output', 'Backup', 'Reports', 'State')) {
    $p = Join-Path $fullWorkspace $d
    if (-not (Test-Path -LiteralPath $p)) {
        [void](New-Item -ItemType Directory -Path $p -Force)
    }
}

if ($ShowState) {
    $st = Read-WinISOState -Workspace $fullWorkspace
    if ($null -eq $st) {
        Write-Output 'STATE.json does not exist yet. Run Initialize-WorkSpace.ps1 or Invoke-WinISOService.ps1 once.'
    }
    else {
        Write-Output ($st | ConvertTo-Json -Depth 10)
    }
    exit 0
}

$transcriptPath = Join-Path $fullWorkspace ('Logs\orchestrator-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.transcript.txt')
Start-Transcript -Path $transcriptPath -Force
try {
    Write-Host ('WinISOBuild v' + (Get-WinISOVersion) + ' - Windows ISO servicing toolchain')

    # Reads the existing state; creates the initial STATE.json when absent.
    # Never overwrites state - restartability depends on it.
    $state = Initialize-WinISOState -Workspace $fullWorkspace
    if ($null -eq $state) {
        throw 'Could not initialize or read STATE.json.'
    }

    $phaseMap = @{
        1  = @{ Name = 'Environment audit';     Fn = 'Invoke-WinISOEnvironmentAudit' }
        2  = @{ Name = 'ISO inspection';        Fn = 'Invoke-WinISOInspectSource' }
        3  = @{ Name = 'Update discovery';      Fn = 'Invoke-WinISOUpdateDiscovery' }
        4  = @{ Name = 'Image servicing';       Fn = 'Invoke-WinISOServiceImage' }
        5  = @{ Name = 'OOBE / unattend';       Fn = 'Invoke-WinISOOobeUnattend' }
        6  = @{ Name = 'Customization profile'; Fn = 'Invoke-WinISOProfile' }
        7  = @{ Name = 'Boot media rebuild';    Fn = 'Invoke-WinISORebuildMedia' }
        8  = @{ Name = 'Validation';            Fn = 'Invoke-WinISOValidate' }
        9  = @{ Name = 'Test installation';     Fn = 'Invoke-WinISOVmTest' }
        10 = @{ Name = 'Final report';          Fn = 'Invoke-WinISOFinalReport' }
    }

    if ($DryRun) {
        Write-Output 'DRY RUN - phases that would execute:'
        foreach ($n in 1..$TargetPhase) {
            $alreadyDone = ([int]$state.phase -ge $n) -and (-not $Force)
            $userSkip = $skipPhases -contains $n
            $verdict = 'RUN'
            if ($userSkip) { $verdict = 'SKIP (user-requested)' }
            elseif ($alreadyDone) {
                if (@(Get-WinISOMissingPhaseArtifacts -State $state -Phase $n).Count -eq 0) {
                    $verdict = 'SKIP (already completed; use -Force)'
                }
                else {
                    $verdict = 'RUN (recorded artifacts are gone)'
                }
            }
            Write-Output ('{0,2}. {1} -> {2}' -f $n, $phaseMap[$n].Name, $verdict)
        }
        exit 0
    }

    $failed = $false
    foreach ($n in 1..$TargetPhase) {
        $name = $phaseMap[$n].Name
        if ($skipPhases -contains $n) {
            Write-Host ('Phase {0} ({1}): skipped by -SkipPhase.' -f $n, $name)
            continue
        }
        if (-not $Force -and [int]$state.phase -ge $n) {
            # The phase number alone is not proof: STATE.json also names the files
            # the phase produced, and a phase whose output was deleted must run
            # again rather than be reported as done.
            $missing = @(Get-WinISOMissingPhaseArtifacts -State $state -Phase $n)
            if ($missing.Count -eq 0) {
                Write-Host ('Phase {0} ({1}): already completed (state.phase={2}); skipping. Use -Force to re-run.' -f $n, $name, $state.phase)
                continue
            }
            Write-Host ('Phase {0} ({1}): recorded as complete, but {2} of its artifacts are gone; re-running it.' -f $n, $name, $missing.Count)
            foreach ($m in $missing) { Write-Host ('  missing: ' + $m) }
        }
        if (Test-WinISOCancelRequest -Path $cancelPath -ProcessId $PID) {
            Write-Host ('Phase {0} ({1}): not started because a stop was requested.' -f $n, $name)
            $state.status = 'cancelled'
            $state.next_action = 'Stopped at a phase boundary on request. Re-run Invoke-WinISOService.ps1 to continue from phase ' + ([int]$state.phase + 1) + '.'
            Save-WinISOState -Workspace $fullWorkspace -State $state
            [void](Remove-WinISOCancelRequest -Path $cancelPath)
            Write-Host ''
            Write-Host ('Stopped at a phase boundary after phase {0}; no image is mounted.' -f $state.phase)
            exit 3
        }
        Write-Host ('Phase {0} ({1}): running...' -f $n, $name)
        $par = @{}
        switch ($n) {
            1 {
                $par.MinimumFreeGB = $MinimumFreeGB
                $par.AllowUnoelevated = [bool]$AllowUnoelevated
            }
            2 {
                $par.SkipHash = [bool]$SkipHash
            }
            3 {
                if ($Build) { $par.Build = [int]$Build }
                if ($Architecture) { $par.Architecture = $Architecture }
            }
            4 {
                if ($UpdateManifest) { $par.UpdateManifest = $UpdateManifest }
                if ($Drivers) { $par.DriversPath = $Drivers }
                if ($ImageIndexes) { $par.ImageIndexes = $ImageIndexes }
                $par.RunCleanup = [bool]$RunCleanup
                $par.ResetBase = [bool]$ResetBase
            }
            5 {
                $par.Unattend = $Unattend
                if ($UnattendFile) { $par.UnattendFile = $UnattendFile }
            }
            6 {
                $par.Profile = $Profile
                $par.AllowRemoval = [bool]$AllowRemoval
                $par.RemovePackages = $RemovePackages
                $par.RemoveReasons = $RemoveReasons
                $par.SkipDependencyAnalysis = [bool]$SkipDependencyAnalysis
            }
            7 {
                if ($OutputIsoName) { $par.OutputIsoName = $OutputIsoName }
            }
            9 {
                $par.VmName = 'WinISO-TestVM'
                $par.Hypervisor = 'Auto'
            }
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $result = & $phaseMap[$n].Fn -Workspace $fullWorkspace -SourceIso $SourceIso @par
        $sw.Stop()
        $result.DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)

        $line = 'Phase {0} ({1}): {2}' -f $n, $name, $result.Status
        if ($result.Reason) { $line += ' - ' + $result.Reason }
        $state.completed_steps = @($state.completed_steps) + $line

        if ($result.Artifacts.Count -gt 0) {
            $state.artifacts | Add-Member -NotePropertyName ('Phase' + $n) -NotePropertyValue (@($result.Artifacts.Values)) -Force
        }
        if ($result.Status -eq 'Succeeded' -or $result.Status -eq 'Partial') {
            $state.phase = $n
            Write-Host ('  -> {0}: {1}' -f $result.Status, $result.Summary)
        }
        elseif ($result.Status -eq 'Skipped') {
            Write-Host ('  -> Skipped: {0}' -f $result.Reason)
        }
        else {
            $failed = $true
            foreach ($e in @($result.Errors)) {
                $state.errors = @($state.errors) + [string]$e
                $state.failed_steps = @($state.failed_steps) + ('Phase ' + $n + ': ' + $e)
            }
            Write-Host ('  -> FAILED: ' + (@($result.Errors) -join ' | '))
            if (-not $ContinueOnError) { break }
        }
        Save-WinISOState -Workspace $fullWorkspace -State $state
    }

    # Determine the first phase that is not yet completed (used for next_action).
    $blocked = $null
    foreach ($n in 1..$TargetPhase) {
        if ($skipPhases -contains $n) { continue }
        if ([int]$state.phase -ge $n) { continue }
        $blocked = $n
        break
    }
    if ($failed) {
        $state.status = 'failed'
        $state.next_action = 'A phase failed. Review Logs\ and State\STATE.json, fix the cause, then re-run Invoke-WinISOService.ps1 (it resumes automatically).'
    }
    elseif ($null -ne $blocked) {
        $state.status = 'blocked'
        $state.next_action = 'Phase ' + $blocked + ' (' + $phaseMap[$blocked].Name + ') was not completed (skipped or pending). Satisfy its prerequisites (typically: place a source ISO in Source\ or pass -SourceIso), then re-run Invoke-WinISOService.ps1.'
    }
    else {
        $state.status = 'complete'
        $state.next_action = 'All phases through ' + $TargetPhase + ' completed. Review artifacts in Output\ and Reports\.'
    }
    Save-WinISOState -Workspace $fullWorkspace -State $state

    Write-Host ''
    Write-Host ('State phase: {0}; status: {1}' -f $state.phase, $state.status)
    Write-Host ('Next action: {0}' -f $state.next_action)
    if ($failed) { exit 1 }
    exit 0
}
finally {
    Stop-Transcript | Out-Null
}
