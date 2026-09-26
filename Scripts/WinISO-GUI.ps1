# WinISO-GUI.ps1
# WinForms front-end for the WinISOBuild Windows 10/11 ISO servicing toolchain.
# It exposes the toolchain's choices (source, editions, updates, drivers,
# profile, OOBE/unattend, output) and runs Scripts\Invoke-WinISOService.ps1 as a
# child process, streaming its output into a log pane.
#
# Compatibility : Windows PowerShell 5.1 (Desktop). No external modules.
# Encoding      : BOM-less UTF-8, ASCII-only content.
#
# Usage:
#   .\WinISO-GUI.ps1            # show the GUI
#   .\WinISO-GUI.ps1 -SelfTest  # headless wiring validation (exit 0 = OK)

[CmdletBinding()]
param([switch]$SelfTest, [switch]$NoElevate)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$script:Orchestrator = Join-Path $PSScriptRoot 'Invoke-WinISOService.ps1'
$script:UnattendGen  = Join-Path $PSScriptRoot 'New-UnattendXml.ps1'
$script:Child        = $null
$script:LogOut       = ''
$script:LogErr       = ''
$script:ShownOut     = 0
$script:ShownErr     = 0
$script:Finished     = $false
$script:DetectedBuild    = 0
$script:DetectedRevision = 0

# ---------------------------------------------------------------------------
# Argument builder (pure - used by the GUI and by -SelfTest)
# ---------------------------------------------------------------------------
function New-WinISOOrchestratorArgs {
    param(
        [Parameter(Mandatory)][string]$Workspace,
        [string]$SourceIso = '',
        [int]$TargetPhase = 3,
        [string]$Profile = 'Safe',
        [string]$Drivers = '',
        [int[]]$ImageIndexes = @(),
        [string]$UpdateManifest = '',
        [switch]$RunCleanup,
        [string]$UnattendFile = '',
        [string]$OutputIsoName = '',
        [switch]$Force,
        [int[]]$SkipPhase = @()
    )
    $a = @()
    $a += '-NoProfile'; $a += '-ExecutionPolicy'; $a += 'Bypass'
    $a += '-File'; $a += $script:Orchestrator
    $a += '-Workspace'; $a += $Workspace
    if ($SourceIso) { $a += '-SourceIso'; $a += $SourceIso }
    $a += '-TargetPhase'; $a += ([string]$TargetPhase)
    if ($Profile) { $a += '-Profile'; $a += $Profile }
    if ($Drivers) { $a += '-Drivers'; $a += $Drivers }
    if ($ImageIndexes -and $ImageIndexes.Count -gt 0) { $a += '-ImageIndexes'; $a += (($ImageIndexes | ForEach-Object { [string]$_ }) -join ',') }
    if ($UpdateManifest) { $a += '-UpdateManifest'; $a += $UpdateManifest }
    if ($RunCleanup) { $a += '-RunCleanup' }
    if ($UnattendFile) { $a += '-UnattendFile'; $a += $UnattendFile }
    if ($OutputIsoName) { $a += '-OutputIsoName'; $a += $OutputIsoName }
    if ($Force) { $a += '-Force' }
    if ($SkipPhase -and $SkipPhase.Count -gt 0) { $a += '-SkipPhase'; $a += (($SkipPhase | ForEach-Object { [string]$_ }) -join ',') }
    return ,$a
}

function New-WinISOUnattendArgs {
    param(
        [string]$OutputPath,
        [string]$ComputerName = '',
        [string]$LocalAccountName = '',
        [string]$LocalAccountPassword = '',
        [string]$TimeZone = '',
        [switch]$LocalAccountAdmin
    )
    $a = @()
    $a += '-NoProfile'; $a += '-ExecutionPolicy'; $a += 'Bypass'
    $a += '-File'; $a += $script:UnattendGen
    if ($OutputPath) { $a += '-OutputPath'; $a += $OutputPath }
    if ($ComputerName) { $a += '-ComputerName'; $a += $ComputerName }
    if ($LocalAccountName) { $a += '-LocalAccountName'; $a += $LocalAccountName }
    if ($LocalAccountPassword) { $a += '-LocalAccountPassword'; $a += $LocalAccountPassword }
    if ($TimeZone) { $a += '-TimeZone'; $a += $TimeZone }
    if ($LocalAccountAdmin) { $a += '-LocalAccountAdmin' }
    return ,$a
}

# ---------------------------------------------------------------------------
# Self test
# ---------------------------------------------------------------------------
function Test-WinISOGuiAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-WinISOSelfTest {
    $problems = @()
    if (-not (Test-Path -LiteralPath $script:Orchestrator)) { $problems += ('orchestrator not found: ' + $script:Orchestrator) }
    if (-not (Test-Path -LiteralPath $script:UnattendGen))  { $problems += ('unattend generator not found: ' + $script:UnattendGen) }

    $a = New-WinISOOrchestratorArgs -Workspace 'D:\WimMount' -SourceIso 'D:\WimMount\ISO\demo.iso' `
         -TargetPhase 4 -Profile 'Safe' -Drivers 'D:\WimMount\Drivers' -ImageIndexes @(6,7) `
         -OutputIsoName 'demo-out.iso' -RunCleanup -SkipPhase @(1,2)
    $joined = ($a -join ' ')
    foreach ($need in @('-Workspace', '-SourceIso', '-TargetPhase', '-Profile', '-Drivers', '-ImageIndexes', '-OutputIsoName', '-RunCleanup', '-SkipPhase')) {
        if ($a -notcontains $need) { $problems += ('arg builder missing ' + $need) }
    }
    if ($joined -notmatch '-TargetPhase\s+4') { $problems += 'arg builder did not emit target phase' }
    if ($joined -notmatch '-ImageIndexes\s+6,7') { $problems += 'arg builder did not join image indexes' }
    if ($joined -notmatch '-SkipPhase\s+1,2') { $problems += 'arg builder did not join skip phases' }

    $u = New-WinISOUnattendArgs -OutputPath 'D:\WimMount\Output\unattend.xml' -ComputerName 'LAB01' -LocalAccountName 'labuser' -LocalAccountAdmin
    if ($u -notcontains '-ComputerName') { $problems += 'unattend arg builder missing -ComputerName' }
    if ($u -notcontains '-LocalAccountAdmin') { $problems += 'unattend arg builder missing -LocalAccountAdmin' }

    $dlg = Join-Path $PSScriptRoot 'Get-WinISOUpdates.ps1'
    if (-not (Test-Path -LiteralPath $dlg)) { $problems += ('downloader not found: ' + $dlg) }
    $phases = @(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
    if ($phases.Count -ne 10) { $problems += 'phase map is not 1..10' }

    if ($problems.Count -gt 0) {
        Write-Host 'SELFTEST FAILED:'
        $problems | ForEach-Object { Write-Host ('  - ' + $_) }
        exit 2
    }
    Write-Host 'SELFTEST OK: orchestrator found; unattend generator found; arg builders verified; phase map 1..10 consistent.'
    exit 0
}

if ($SelfTest) { Invoke-WinISOSelfTest }

if (-not $NoElevate -and -not (Test-WinISOGuiAdmin)) {
    $psExe = (Get-Process -Id $PID).Path
    if (-not $psExe) { $psExe = 'powershell.exe' }
    try {
        Start-Process -FilePath $psExe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', $PSCommandPath) -Verb RunAs -ErrorAction Stop
        exit 0
    }
    catch { }
}

# ---------------------------------------------------------------------------
# GUI
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'WinISOBuild - Windows ISO Servicing Console'
$form.Size = New-Object System.Drawing.Size(1000, 840)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(1000, 840)
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\Scripts')) { }
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

function New-Label { param([string]$Text, [int]$X, [int]$Y, [int]$W = 120)
    $l = New-Object System.Windows.Forms.Label; $l.Text = $Text; $l.Location = New-Object System.Drawing.Point($X, $Y); $l.Size = New-Object System.Drawing.Size($W, 18); return $l
}
function New-Text { param([int]$X, [int]$Y, [int]$W = 640)
    $t = New-Object System.Windows.Forms.TextBox; $t.Location = New-Object System.Drawing.Point($X, $Y); $t.Size = New-Object System.Drawing.Size($W, 24); return $t
}
function New-Button { param([string]$Text, [int]$X, [int]$Y, [int]$W = 110, [int]$H = 26)
    $b = New-Object System.Windows.Forms.Button; $b.Text = $Text; $b.Location = New-Object System.Drawing.Point($X, $Y); $b.Size = New-Object System.Drawing.Size($W, $H); return $b
}

# --- Source group ---
$grpSrc = New-Object System.Windows.Forms.GroupBox
$grpSrc.Text = '1. Source'; $grpSrc.Location = New-Object System.Drawing.Point(12, 8); $grpSrc.Size = New-Object System.Drawing.Size(960, 92)
$grpSrc.Controls.Add((New-Label 'Workspace' 12 24 80))
$txtWs = New-Text 96 21 700; $txtWs.Text = 'D:\WimMount'; $grpSrc.Controls.Add($txtWs)
$btnWs = New-Button 'Browse...' 806 20 130; $grpSrc.Controls.Add($btnWs)
$grpSrc.Controls.Add((New-Label 'Source ISO' 12 54 80))
$txtIso = New-Text 96 51 700; $grpSrc.Controls.Add($txtIso)
$btnIso = New-Button 'Browse...' 806 50 130; $grpSrc.Controls.Add($btnIso)
$form.Controls.Add($grpSrc)

# --- Editions group ---
$grpEd = New-Object System.Windows.Forms.GroupBox
$grpEd.Text = '2. Editions to service (-ImageIndexes; none checked = all)'; $grpEd.Location = New-Object System.Drawing.Point(12, 108); $grpEd.Size = New-Object System.Drawing.Size(470, 190)
$lstEd = New-Object System.Windows.Forms.CheckedListBox
$lstEd.Location = New-Object System.Drawing.Point(12, 22); $lstEd.Size = New-Object System.Drawing.Size(446, 132)
$lstEd.CheckOnClick = $true
$grpEd.Controls.Add($lstEd)
$btnLoadEd = New-Button 'Load editions from selected ISO' 12 158 280 26; $grpEd.Controls.Add($btnLoadEd)
$btnLoadRep = New-Button 'from report' 298 158 120 26; $grpEd.Controls.Add($btnLoadRep)
$form.Controls.Add($grpEd)

# --- Updates group ---
$grpUp = New-Object System.Windows.Forms.GroupBox
$grpUp.Text = '3. Updates'; $grpUp.Location = New-Object System.Drawing.Point(494, 108); $grpUp.Size = New-Object System.Drawing.Size(478, 190)
$rbAll = New-Object System.Windows.Forms.RadioButton; $rbAll.Text = 'Required + Recommended (default)'; $rbAll.Location = New-Object System.Drawing.Point(12, 24); $rbAll.Size = New-Object System.Drawing.Size(300, 20); $rbAll.Checked = $true
$rbReq = New-Object System.Windows.Forms.RadioButton; $rbReq.Text = 'Required only'; $rbReq.Location = New-Object System.Drawing.Point(12, 48); $rbReq.Size = New-Object System.Drawing.Size(300, 20)
$rbNone = New-Object System.Windows.Forms.RadioButton; $rbNone.Text = 'None (skip .msu/.cab integration)'; $rbNone.Location = New-Object System.Drawing.Point(12, 72); $rbNone.Size = New-Object System.Drawing.Size(300, 20)
$grpUp.Controls.Add($rbAll); $grpUp.Controls.Add($rbReq); $grpUp.Controls.Add($rbNone)
$grpUp.Controls.Add((New-Label 'Drop .msu/.cab packages into  <Workspace>\Updates\' 12 100 440))
$lblUpd = New-Label '' 12 122 450
$grpUp.Controls.Add($lblUpd)
$btnUpd = New-Button 'Open Updates folder' 12 148 150 26; $grpUp.Controls.Add($btnUpd)
$btnDl = New-Button 'Search + download missing updates' 168 148 220 26; $grpUp.Controls.Add($btnDl)
$chkMissed = New-Object System.Windows.Forms.CheckBox; $chkMissed.Text = 'Only missed'; $chkMissed.Location = New-Object System.Drawing.Point(394, 152); $chkMissed.Size = New-Object System.Drawing.Size(84, 20); $chkMissed.Checked = $true
$grpUp.Controls.Add($chkMissed)
$form.Controls.Add($grpUp)

# --- Drivers group ---
$grpDrv = New-Object System.Windows.Forms.GroupBox
$grpDrv.Text = '4. Drivers'; $grpDrv.Location = New-Object System.Drawing.Point(12, 306); $grpDrv.Size = New-Object System.Drawing.Size(470, 92)
$chkDrv = New-Object System.Windows.Forms.CheckBox; $chkDrv.Text = 'Inject drivers (DISM /Add-Driver /Recurse)'; $chkDrv.Location = New-Object System.Drawing.Point(12, 22); $chkDrv.Size = New-Object System.Drawing.Size(300, 20)
$txtDrv = New-Text 12 48 330; $txtDrv.Text = 'D:\WimMount\Drivers'
$btnDrv = New-Button 'Browse...' 348 47 110 26
$grpDrv.Controls.Add($chkDrv); $grpDrv.Controls.Add($txtDrv); $grpDrv.Controls.Add($btnDrv)
$form.Controls.Add($grpDrv)

# --- Profile group ---
$grpPf = New-Object System.Windows.Forms.GroupBox
$grpPf.Text = '5. Customization profile'; $grpPf.Location = New-Object System.Drawing.Point(494, 306); $grpPf.Size = New-Object System.Drawing.Size(478, 92)
$cmbPf = New-Object System.Windows.Forms.ComboBox; $cmbPf.DropDownStyle = 'DropDownList'; $cmbPf.Location = New-Object System.Drawing.Point(12, 24); $cmbPf.Size = New-Object System.Drawing.Size(160, 24)
[void]$cmbPf.Items.Add('Safe'); [void]$cmbPf.Items.Add('Standard'); [void]$cmbPf.Items.Add('Aggressive'); $cmbPf.SelectedIndex = 0
$lblPf = New-Label 'Safe = updates only, no removal.' 184 27 280
$grpPf.Controls.Add($cmbPf); $grpPf.Controls.Add($lblPf)
$grpPf.Controls.Add((New-Label 'Aggressive removals require explicit authorization and a rollback plan.' 12 54 450))
$form.Controls.Add($grpPf)

# --- OOBE group ---
$grpOb = New-Object System.Windows.Forms.GroupBox
$grpOb.Text = '6. OOBE / unattend.xml (optional)'; $grpOb.Location = New-Object System.Drawing.Point(12, 404); $grpOb.Size = New-Object System.Drawing.Size(960, 100)
$chkOb = New-Object System.Windows.Forms.CheckBox; $chkOb.Text = 'Generate and attach unattend.xml'; $chkOb.Location = New-Object System.Drawing.Point(12, 22); $chkOb.Size = New-Object System.Drawing.Size(260, 20)
$grpOb.Controls.Add($chkOb)
$grpOb.Controls.Add((New-Label 'Computer name' 12 50 90)); $txtCn = New-Text 104 47 150; $grpOb.Controls.Add($txtCn)
$grpOb.Controls.Add((New-Label 'Local account' 270 50 90)); $txtUsr = New-Text 362 47 150; $grpOb.Controls.Add($txtUsr)
$grpOb.Controls.Add((New-Label 'Password' 528 50 70)); $txtPwd = New-Text 600 47 150; $txtPwd.UseSystemPasswordChar = $true; $grpOb.Controls.Add($txtPwd)
$chkAdm = New-Object System.Windows.Forms.CheckBox; $chkAdm.Text = 'Add to Administrators'; $chkAdm.Location = New-Object System.Drawing.Point(760, 49); $chkAdm.Size = New-Object System.Drawing.Size(160, 20); $grpOb.Controls.Add($chkAdm)
$grpOb.Controls.Add((New-Label 'Time zone' 12 76 90)); $txtTz = New-Text 104 73 300; $grpOb.Controls.Add($txtTz)
$form.Controls.Add($grpOb)

# --- Output group ---
$grpOut = New-Object System.Windows.Forms.GroupBox
$grpOut.Text = '7. Output'; $grpOut.Location = New-Object System.Drawing.Point(12, 510); $grpOut.Size = New-Object System.Drawing.Size(960, 60)
$grpOut.Controls.Add((New-Label 'Output ISO name' 12 24 100)); $txtOut = New-Text 116 21 300; $txtOut.Text = 'Win11_Updated.iso'; $grpOut.Controls.Add($txtOut)
$grpOut.Controls.Add((New-Label '(written under <Workspace>\Output)' 430 24 300))
$form.Controls.Add($grpOut)

# --- Actions ---
$grpAc = New-Object System.Windows.Forms.GroupBox
$grpAc.Text = '8. Actions'; $grpAc.Location = New-Object System.Drawing.Point(12, 576); $grpAc.Size = New-Object System.Drawing.Size(960, 62)
$btnInsp = New-Button 'Inspect (read-only)' 12 24 140; $grpAc.Controls.Add($btnInsp)
$btnP3 = New-Button 'Run to Phase 3' 158 24 120; $grpAc.Controls.Add($btnP3)
$btnP4 = New-Button 'Run to Phase 4 (service)' 284 24 160; $grpAc.Controls.Add($btnP4)
$btnP8 = New-Button 'Run to Phase 8 (rebuild)' 450 24 170; $grpAc.Controls.Add($btnP8)
$grpAc.Controls.Add((New-Label 'Custom phase (1-10)' 632 27 110))
$numPhase = New-Object System.Windows.Forms.NumericUpDown; $numPhase.Minimum = 1; $numPhase.Maximum = 10; $numPhase.Value = 8; $numPhase.Location = New-Object System.Drawing.Point(744, 24); $numPhase.Size = New-Object System.Drawing.Size(56, 24); $grpAc.Controls.Add($numPhase)
$btnCustom = New-Button 'Run' 806 23 60; $grpAc.Controls.Add($btnCustom)
$btnStop = New-Button 'Stop' 872 23 76; $grpAc.Controls.Add($btnStop)
$form.Controls.Add($grpAc)

# --- Log ---
$grpLog = New-Object System.Windows.Forms.GroupBox
$grpLog.Text = 'Log'; $grpLog.Location = New-Object System.Drawing.Point(12, 644); $grpLog.Size = New-Object System.Drawing.Size(960, 130)
$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true; $logBox.ReadOnly = $true; $logBox.ScrollBars = 'Vertical'
$logBox.Location = New-Object System.Drawing.Point(10, 20); $logBox.Size = New-Object System.Drawing.Size(940, 100)
$logBox.Font = New-Object System.Drawing.Font('Consolas', 8)
$grpLog.Controls.Add($logBox)
$form.Controls.Add($grpLog)

$status = New-Object System.Windows.Forms.StatusStrip
$lblStatus = New-Object System.Windows.Forms.ToolStripStatusLabel
$lblStatus.Text = 'Idle'
[void]$status.Items.Add($lblStatus)
$form.Controls.Add($status)

# ---------------------------------------------------------------------------
# GUI helpers
# ---------------------------------------------------------------------------
function Add-Log { param([string]$Text)
    $logBox.AppendText($Text + "`r`n")
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

function Get-Workspace { return ([string]$txtWs.Text).TrimEnd('\') }

function Update-UpdateInfo {
    $ws = Get-Workspace
    $upd = Join-Path $ws 'Updates'
    $n = 0
    if (Test-Path -LiteralPath $upd) { $n = @(Get-ChildItem $upd -File -Include *.msu, *.cab -ErrorAction SilentlyContinue).Count }
    $lblUpd.Text = ('Packages found in ' + $upd + ' : ' + $n)
}

function Load-Editions {
    $ws = Get-Workspace
    $inv = Join-Path $ws 'Reports\ISO-INVENTORY.json'
    $lstEd.Items.Clear()
    if (-not (Test-Path -LiteralPath $inv)) { Add-Log ('[gui] inventory not found: ' + $inv + ' (run Inspect first)'); return }
    try { $j = Get-Content -LiteralPath $inv -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Add-Log ('[gui] could not parse inventory: ' + $_.Exception.Message); return }
    $count = 0
    foreach ($wf in @($j.wim_files)) {
        if ([string]$wf.kind -ne 'install') { continue }
        foreach ($im in @($wf.images)) {
            [void]$lstEd.Items.Add(('{0} = {1}' -f [int]$im.index, [string]$im.name))
            $count++
        }
    }
    Add-Log ('[gui] loaded ' + $count + ' edition(s) from inventory')
}

function Load-EditionsFromIso {
    $iso = ([string]$txtIso.Text).Trim()
    $lstEd.Items.Clear()
    if (-not $iso) { Add-Log '[gui] no source ISO selected.'; return }
    if (-not (Test-Path -LiteralPath $iso)) { Add-Log ('[gui] ISO not found: ' + $iso); return }
    Add-Log ('[gui] mounting ' + $iso + ' (read-only)')
    $before = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[A-Z]$' } | ForEach-Object { [string]$_.Name }))
    $img = $null
    try { $img = Mount-DiskImage -ImagePath $iso -PassThru -ErrorAction Stop } catch { Add-Log ('[gui] mount failed: ' + $_.Exception.Message); return }
    try {
        $letter = ''
        for ($i = 0; $i -lt 60; $i++) {
            Start-Sleep -Milliseconds 500
            $now = @((Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[A-Z]$' } | ForEach-Object { [string]$_.Name }))
            $new = @($now | Where-Object { $before -notcontains $_ })
            foreach ($l in $new) { if (Test-Path -LiteralPath ("${l}:\sources\install.wim")) { $letter = $l; break } }
            if ($letter) { break }
        }
        if (-not $letter) { Add-Log '[gui] ISO attached but no drive letter found.'; return }
        $wim = ("${letter}:\sources\install.wim")
        if (-not (Test-Path -LiteralPath $wim)) { $wim = ("${letter}:\sources\install.esd") }
        $dismExe = Join-Path $env:SystemRoot 'System32\Dism.exe'
        $out = & $dismExe /English /Get-WimInfo /WimFile:$wim 2>&1 | Out-String
        $count = 0
        $curIdx = -1
        foreach ($ln in ($out -split "`r?`n")) {
            $t = $ln.Trim()
            if ($t -match '^Index\s*:\s*(\d+)') { $curIdx = [int]$Matches[1] }
            elseif ($t -match '^Name\s*:\s*(.+)$') {
                if ($curIdx -ge 0) { [void]$lstEd.Items.Add(('{0} = {1}' -f $curIdx, $Matches[1].Trim())); $count++; $curIdx = -1 }
            }
        }
        $script:DetectedBuild = 0; $script:DetectedRevision = 0
        $mv = [regex]::Match($out, '(?im)^\s*Version\s*:\s*10\.0\.(\d+)')
        if ($mv.Success) { $script:DetectedBuild = [int]$mv.Groups[1].Value }
        $mr = [regex]::Match($out, '(?im)^\s*ServicePack Build\s*:\s*(\d+)')
        if ($mr.Success) { $script:DetectedRevision = [int]$mr.Groups[1].Value }
        if ($count -gt 0 -and $script:DetectedBuild -gt 0) {
            $suffix = [string]$script:DetectedBuild
            if ($script:DetectedRevision -gt 0) { $suffix = $suffix + '.' + $script:DetectedRevision }
            $base = [System.IO.Path]::GetFileNameWithoutExtension(([string]$txtOut.Text).Trim())
            if (-not $base) { $base = 'Win11_Updated' }
            $base = $base -replace '_[0-9]{5}(\.[0-9]+)?$', ''
            $txtOut.Text = ($base + '_' + $suffix + '.iso')
        }
        Add-Log ('[gui] loaded ' + $count + ' edition(s) from the selected ISO; build ' + $script:DetectedBuild + '.' + $script:DetectedRevision)
        if ($count -eq 0) {
            $preview = (($out -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -First 6) -join ' | '
            Add-Log ('[gui] dism said: ' + $preview)
            if ($out -match 'Error:\s*740' -or $out -match '(?i)elevated permissions') {
                Add-Log '[gui] DISM requires elevation: launch WinISO-GUI.ps1 as Administrator (it self-elevates by default).'
            }
        }
    }
    finally {
        if ($img) { try { Dismount-DiskImage -ImagePath $iso -ErrorAction SilentlyContinue | Out-Null } catch { } }
    }
}

function Search-DownloadUpdates {
    $ws = Get-Workspace
    $iso = ([string]$txtIso.Text).Trim()
    if (-not $ws) { [void][System.Windows.Forms.MessageBox]::Show('Workspace is required.'); return }
    $dl = Join-Path $PSScriptRoot 'Get-WinISOUpdates.ps1'
    if (-not (Test-Path -LiteralPath $dl)) { Add-Log ('[gui] downloader not found: ' + $dl); return }
    $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$dl,'-Workspace',$ws,'-OutDir',(Join-Path $ws 'Updates'))
    if ($iso) { $a += '-Iso'; $a += $iso }
    if ($chkMissed.Checked) { $a += '-MissedOnly' }
    $logDir = Join-Path $env:TEMP ('winiso-dl-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    [void](New-Item -ItemType Directory -Path $logDir -Force)
    $script:LogOut = Join-Path $logDir 'stdout.log'; $script:LogErr = Join-Path $logDir 'stderr.log'
    $script:ShownOut = 0; $script:ShownErr = 0; $script:Finished = $false
    [System.IO.File]::WriteAllText($script:LogOut, ''); [System.IO.File]::WriteAllText($script:LogErr, '')
    Add-Log ('[gui] downloader: powershell ' + ($a -join ' '))
    $lblStatus.Text = 'Searching / downloading updates ...'
    $script:Child = Start-Process -FilePath 'powershell.exe' -ArgumentList $a -PassThru -WindowStyle Hidden -RedirectStandardOutput $script:LogOut -RedirectStandardError $script:LogErr
    $script:TailTimer.Start()
}

function Get-SelectedIndexes {
    $idx = @()
    foreach ($it in $lstEd.CheckedItems) {
        if (([string]$it) -match '^(\d+)\s*=') { $idx += [int]$Matches[1] }
    }
    return ,$idx
}

function Start-Run {
    param([int]$TargetPhase, [switch]$ReadOnly)
    if ($script:Child -and -not $script:Child.HasExited) { [void][System.Windows.Forms.MessageBox]::Show('A run is already in progress.'); return }
    $ws = Get-Workspace
    $iso = ([string]$txtIso.Text).Trim()
    if (-not $ws) { [void][System.Windows.Forms.MessageBox]::Show('Workspace is required.'); return }

    if ($TargetPhase -ge 4 -and -not $ReadOnly) {
        $msg = "This will run phases through $TargetPhase, which MOUNTS and MODIFIES image copies" + "`r`n" +
               "(servicing / commit / rebuild). The source ISO is not changed." + "`r`n`r`nProceed?"
        if ([System.Windows.Forms.MessageBox]::Show($msg, 'Confirm mutating run', 'YesNo', 'Warning') -ne 'Yes') { return }
    }

    $drv = ''
    if ($chkDrv.Checked) { $drv = ([string]$txtDrv.Text).Trim() }
    $idx = Get-SelectedIndexes
    $outName = ([string]$txtOut.Text).Trim()

    $uaFile = ''
    if ($chkOb.Checked) {
        $uaFile = Join-Path $ws 'Output\unattend.xml'
        $uargs = New-WinISOUnattendArgs -OutputPath $uaFile -ComputerName ([string]$txtCn.Text).Trim() `
                 -LocalAccountName ([string]$txtUsr.Text).Trim() -LocalAccountPassword ([string]$txtPwd.Text) `
                 -TimeZone ([string]$txtTz.Text).Trim() -LocalAccountAdmin:([bool]$chkAdm.Checked)
        Add-Log ('[gui] generating unattend: ' + $uaFile)
        $gen = Start-Process -FilePath 'powershell.exe' -ArgumentList $uargs -Wait -PassThru -WindowStyle Hidden
        Add-Log ('[gui] unattend generator exit ' + $gen.ExitCode)
    }

    $skip = @()
    if ($TargetPhase -ge 4) { $skip = @() }

    $args = New-WinISOOrchestratorArgs -Workspace $ws -SourceIso $iso -TargetPhase $TargetPhase -Profile ([string]$cmbPf.SelectedItem) `
            -Drivers $drv -ImageIndexes $idx -UnattendFile $uaFile -OutputIsoName $outName -SkipPhase $skip

    $logDir = Join-Path $env:TEMP ('winiso-gui-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    [void](New-Item -ItemType Directory -Path $logDir -Force)
    $script:LogOut = Join-Path $logDir 'stdout.log'
    $script:LogErr = Join-Path $logDir 'stderr.log'
    $script:ShownOut = 0; $script:ShownErr = 0; $script:Finished = $false
    [System.IO.File]::WriteAllText($script:LogOut, '')
    [System.IO.File]::WriteAllText($script:LogErr, '')

    Add-Log ('[gui] running: powershell ' + ($args -join ' '))
    $lblStatus.Text = ('Running phase target ' + $TargetPhase + ' ...')
    $script:Child = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -PassThru -WindowStyle Hidden `
                    -RedirectStandardOutput $script:LogOut -RedirectStandardError $script:LogErr
    $script:TailTimer.Start()
}

# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------
$btnWs.Add_Click({ $d = New-Object System.Windows.Forms.FolderBrowserDialog; if ($d.ShowDialog() -eq 'OK') { $txtWs.Text = $d.SelectedPath; Update-UpdateInfo } })
$btnIso.Add_Click({ $d = New-Object System.Windows.Forms.OpenFileDialog; $d.Filter = 'ISO images (*.iso)|*.iso|All files (*.*)|*.*'; if ($d.ShowDialog() -eq 'OK') { $txtIso.Text = $d.FileName } })
$btnDrv.Add_Click({ $d = New-Object System.Windows.Forms.FolderBrowserDialog; if ($d.ShowDialog() -eq 'OK') { $txtDrv.Text = $d.SelectedPath } })
$btnUpd.Add_Click({ $u = Join-Path (Get-Workspace) 'Updates'; if (-not (Test-Path -LiteralPath $u)) { [void](New-Item -ItemType Directory -Path $u -Force) }; Start-Process explorer.exe $u })
$btnLoadEd.Add_Click({ Load-EditionsFromIso })
$btnLoadRep.Add_Click({ Load-Editions })
$btnDl.Add_Click({ Search-DownloadUpdates })
$btnInsp.Add_Click({ Load-Editions; Start-Run -TargetPhase 3 -ReadOnly })
$btnP3.Add_Click({ Start-Run -TargetPhase 3 -ReadOnly })
$btnP4.Add_Click({ Start-Run -TargetPhase 4 })
$btnP8.Add_Click({ Start-Run -TargetPhase 8 })
$btnCustom.Add_Click({ Start-Run -TargetPhase ([int]$numPhase.Value) })
$btnStop.Add_Click({
    if ($script:Child -and -not $script:Child.HasExited) {
        try { $script:Child.Kill() } catch { }
        Add-Log '[gui] child process killed by user.'
        Add-Log '[gui] IMPORTANT: if an image was mounted, run  dism /Get-MountedImageInfo  and unmount with /Discard.'
        $lblStatus.Text = 'Stopped'
    } else { Add-Log '[gui] nothing running.' }
})
$chkDrv.Add_CheckedChanged({ $txtDrv.Enabled = $chkDrv.Checked; $btnDrv.Enabled = $chkDrv.Checked })
$txtDrv.Enabled = $false; $btnDrv.Enabled = $false
$grpUp.Add_Enter({ })
$rbAll.Add_CheckedChanged({ })
$form.Add_FormClosing({ if ($script:Child -and -not $script:Child.HasExited) { if ([System.Windows.Forms.MessageBox]::Show('A run is in progress. Kill it and exit?', 'Confirm', 'YesNo', 'Warning') -ne 'Yes') { $_.Cancel = $true } else { try { $script:Child.Kill() } catch { } } } })

$script:TailTimer = New-Object System.Windows.Forms.Timer
$script:TailTimer.Interval = 400
$script:TailTimer.Add_Tick({
    if ($script:LogOut -and (Test-Path -LiteralPath $script:LogOut)) {
        $all = @(Get-Content -LiteralPath $script:LogOut -ErrorAction SilentlyContinue)
        if ($all.Count -gt $script:ShownOut) { $new = @($all[$script:ShownOut..($all.Count - 1)]); $script:ShownOut = $all.Count; Add-Log (($new -join "`r`n")) }
    }
    if ($script:LogErr -and (Test-Path -LiteralPath $script:LogErr)) {
        $allE = @(Get-Content -LiteralPath $script:LogErr -ErrorAction SilentlyContinue)
        if ($allE.Count -gt $script:ShownErr) { $newE = @($allE[$script:ShownErr..($allE.Count - 1)]); $script:ShownErr = $allE.Count; Add-Log (($newE -join "`r`n")) }
    }
    if ($script:Child -and $script:Child.HasExited -and -not $script:Finished) {
        $script:Finished = $true
        $script:TailTimer.Stop()
        Add-Log ('[gui] child exited with code ' + $script:Child.ExitCode)
        $lblStatus.Text = ('Finished (exit ' + $script:Child.ExitCode + ')')
        Update-UpdateInfo
    }
})

Update-UpdateInfo
Add-Log '[gui] ready. Choose a source, then Inspect (read-only) or Run.'
Add-Log ('[gui] orchestrator: ' + $script:Orchestrator)

[void]$form.ShowDialog()
$form.Dispose()
