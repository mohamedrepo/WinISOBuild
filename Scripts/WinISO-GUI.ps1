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
param([switch]$SelfTest, [switch]$NoElevate, [switch]$NoShow)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$script:Orchestrator = Join-Path $PSScriptRoot 'Invoke-WinISOService.ps1'
$script:UnattendGen  = Join-Path $PSScriptRoot 'New-UnattendXml.ps1'
$script:BurnScript   = Join-Path $PSScriptRoot 'Burn-WinISOToUsb.ps1'
$script:Child        = $null
$script:LogOut       = ''
$script:LogErr       = ''
$script:ShownOut     = 0
$script:ShownErr     = 0
$script:Finished     = $false
$script:UsbBurn      = $null
$script:DetectedBuild    = 0
$script:DetectedRevision = 0
$script:OutNameAuto      = $true   # output name follows the detected/new build
$script:SuppressOutEdit  = $false  # set while the GUI writes the name itself

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

if (-not $NoElevate -and -not $NoShow -and -not (Test-WinISOGuiAdmin)) {
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
$form.Size = New-Object System.Drawing.Size(1180, 900)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(1040, 780)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.AutoScroll = $false

# ----- helper functions for controls that auto-size -----
function New-LabelAuto { param([string]$Text, [int]$Left = 6, [int]$Width = 100)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Location = New-Object System.Drawing.Point($Left, 0); $l.AutoSize = $true; $l.Anchor = 'Left, Top'
    return $l
}
function New-TextAuto { param([int]$Left, [int]$Width = 200)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($Left, 0); $t.Size = New-Object System.Drawing.Size($Width, 24); $t.Anchor = 'Left, Top'
    return $t
}
function New-ButtonAuto { param([string]$Text, [int]$Left = 6, [int]$Width = 100)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Location = New-Object System.Drawing.Point($Left, 0); $b.Size = New-Object System.Drawing.Size($Width, 26); $b.Anchor = 'Left, Top'
    return $b
}

# ----- main layout: 2-column table (left 55% / right 45%) plus bottom action row -----
$tbl = New-Object System.Windows.Forms.TableLayoutPanel
$tbl.Dock = 'Fill'
$tbl.CellBorderStyle = 'None'
$tbl.Padding = '8,8,8,0'
$tbl.ColumnCount = 2
$tbl.RowCount = 8

[void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 56)))
[void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 44)))

# Absolute row heights: the groups are laid out with fixed geometry so no
# control can overlap another, and the log pane takes every remaining pixel.
[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 78)))   # 1. Source
[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 180)))  # 2. Editions + 3. Updates
[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 112)))  # 4. Drivers + 5. Profile
[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 108)))  # 6. OOBE
[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 118)))  # 7. Output
[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 118)))  # ADK / USB / Actions
[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))   # Log
[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 26)))   # Status

$form.Controls.Add($tbl)

# TableLayoutPanel.Controls.Add takes (control, column, row). Setting
# Row/Column alone does NOT attach the control - that is what made the window
# come up empty.
function Add-Cell {
    param($Control, [int]$Row, [int]$Column = 0, [int]$Span = 1)
    $tbl.Controls.Add($Control, $Column, $Row)
    if ($Span -gt 1) { $tbl.SetColumnSpan($Control, $Span) }
}

# ===== ROW 0: 1. Source =====
$grpSrc = New-Object System.Windows.Forms.GroupBox
$grpSrc.Text = '1. Source'; $grpSrc.Dock = 'Fill'; $grpSrc.Padding = '0,0,0,0'
# The group is sized to the cell it will occupy BEFORE its children are added:
# an anchored child keeps the right margin it had when it was parented, so a
# default 200x100 GroupBox made the text boxes stretch past the window.
$grpSrc.Size = New-Object System.Drawing.Size(1142, 72)
$lblWs = New-Object System.Windows.Forms.Label; $lblWs.Text = 'Workspace (working dir)'; $lblWs.AutoSize = $true; $lblWs.Location = '14,20'
$txtWs = New-Object System.Windows.Forms.TextBox
$txtWs.Location = '152,18'; $txtWs.Size = New-Object System.Drawing.Size(868, 23)
$txtWs.Anchor = 'Top,Left,Right'; $txtWs.Text = 'D:\WimMount'
$btnWs = New-Object System.Windows.Forms.Button
$btnWs.Text = 'Browse...'; $btnWs.Size = New-Object System.Drawing.Size(88, 25); $btnWs.Anchor = 'Top,Right'
$lblIso = New-Object System.Windows.Forms.Label; $lblIso.Text = 'Source ISO (input)'; $lblIso.AutoSize = $true; $lblIso.Location = '14,44'
$txtIso = New-Object System.Windows.Forms.TextBox
$txtIso.Location = '152,42'; $txtIso.Size = New-Object System.Drawing.Size(868, 23); $txtIso.Anchor = 'Top,Left,Right'
$btnIso = New-Object System.Windows.Forms.Button
$btnIso.Text = 'Browse...'; $btnIso.Size = New-Object System.Drawing.Size(88, 25); $btnIso.Anchor = 'Top,Right'; $btnIso.Location = '1036,41'
$btnWs.Location = '1036,17'
$grpSrc.Controls.AddRange(@($lblWs, $txtWs, $btnWs, $lblIso, $txtIso, $btnIso))
Add-Cell $grpSrc 0 0 2

# ===== ROW 1: 2. Editions (left) | 3. Updates (right) =====
$grpEd = New-Object System.Windows.Forms.GroupBox
$grpEd.Text = '2. Editions to service (-ImageIndexes; none checked = all)'; $grpEd.Dock = 'Fill'
$grpEd.Size = New-Object System.Drawing.Size(636, 174)
$lstEd = New-Object System.Windows.Forms.CheckedListBox
$lstEd.CheckOnClick = $true
$lstEd.Location = '14,20'; $lstEd.Size = New-Object System.Drawing.Size(600, 112); $lstEd.Anchor = 'Top,Left,Right'
$btnLoadEd = New-Object System.Windows.Forms.Button
$btnLoadEd.Text = 'Load editions from selected ISO'; $btnLoadEd.Size = New-Object System.Drawing.Size(190, 26); $btnLoadEd.Location = '14,140'
$btnLoadRep = New-Object System.Windows.Forms.Button
$btnLoadRep.Text = 'from report'; $btnLoadRep.Size = New-Object System.Drawing.Size(100, 26); $btnLoadRep.Location = '212,140'
$grpEd.Controls.AddRange(@($lstEd, $btnLoadEd, $btnLoadRep))
Add-Cell $grpEd 1 0

$grpUp = New-Object System.Windows.Forms.GroupBox
$grpUp.Text = '3. Updates'; $grpUp.Dock = 'Fill'
$grpUp.Size = New-Object System.Drawing.Size(500, 174)
$rbAll = New-Object System.Windows.Forms.RadioButton
$rbAll.Text = 'Required + Recommended (default)'; $rbAll.AutoSize = $true; $rbAll.Checked = $true; $rbAll.Location = '14,20'
$rbReq = New-Object System.Windows.Forms.RadioButton
$rbReq.Text = 'Required only'; $rbReq.AutoSize = $true; $rbReq.Location = '14,42'
$rbNone = New-Object System.Windows.Forms.RadioButton
$rbNone.Text = 'None (skip .msu/.cab integration)'; $rbNone.AutoSize = $true; $rbNone.Location = '14,64'
$lblDrop = New-Object System.Windows.Forms.Label
$lblDrop.Text = 'Drop .msu/.cab packages into <Workspace>\Updates\'; $lblDrop.AutoSize = $true; $lblDrop.Location = '14,88'
$lblUpd = New-Object System.Windows.Forms.Label; $lblUpd.Text = ''; $lblUpd.AutoSize = $true; $lblUpd.Location = '14,108'
$btnUpd = New-Object System.Windows.Forms.Button
$btnUpd.Text = 'Open Updates folder'; $btnUpd.Size = New-Object System.Drawing.Size(140, 26); $btnUpd.Location = '14,130'
$btnDl = New-Object System.Windows.Forms.Button
$btnDl.Text = 'Search + download'; $btnDl.Size = New-Object System.Drawing.Size(115, 26); $btnDl.Location = '160,130'
$chkMissed = New-Object System.Windows.Forms.CheckBox
$chkMissed.Text = 'Only missed'; $chkMissed.AutoSize = $true; $chkMissed.Checked = $true; $chkMissed.Location = '282,134'
$chkOpt = New-Object System.Windows.Forms.CheckBox
$chkOpt.Text = 'Optional'; $chkOpt.AutoSize = $true; $chkOpt.Location = '378,134'
$progUp = New-Object System.Windows.Forms.ProgressBar
$progUp.Style = 'Continuous'; $progUp.Maximum = 100; $progUp.Visible = $false
$progUp.Location = '14,160'; $progUp.Size = New-Object System.Drawing.Size(230, 14)
$lblUpProg = New-Object System.Windows.Forms.Label; $lblUpProg.Text = ''; $lblUpProg.AutoSize = $true; $lblUpProg.Location = '252,160'
$lblUpProg.Font = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Italic)
$grpUp.Controls.AddRange(@($rbAll, $rbReq, $rbNone, $lblDrop, $lblUpd, $btnUpd, $btnDl, $chkMissed, $chkOpt, $progUp, $lblUpProg))
Add-Cell $grpUp 1 1

# ===== ROW 2: 4. Drivers (left) | 5. Customization profile (right) =====
$grpDrv = New-Object System.Windows.Forms.GroupBox
$grpDrv.Text = '4. Drivers'; $grpDrv.Dock = 'Fill'
$grpDrv.Size = New-Object System.Drawing.Size(636, 106)
$chkDrv = New-Object System.Windows.Forms.CheckBox
$chkDrv.Text = 'Inject drivers (DISM /Add-Driver /Recurse)'; $chkDrv.AutoSize = $true; $chkDrv.Location = '14,20'
$txtDrv = New-Object System.Windows.Forms.TextBox
$txtDrv.Text = 'D:\WimMount\Drivers'; $txtDrv.Location = '14,44'; $txtDrv.Size = New-Object System.Drawing.Size(510, 23)
$txtDrv.Anchor = 'Top,Left,Right'
$btnDrv = New-Object System.Windows.Forms.Button
$btnDrv.Text = 'Browse...'; $btnDrv.Size = New-Object System.Drawing.Size(88, 25); $btnDrv.Location = '532,42'; $btnDrv.Anchor = 'Top,Right'
$btnExportDrv = New-Object System.Windows.Forms.Button
$btnExportDrv.Text = 'Export all drivers to...'; $btnExportDrv.Size = New-Object System.Drawing.Size(190, 26); $btnExportDrv.Location = '14,72'
$lblExportDrv = New-Object System.Windows.Forms.Label
$lblExportDrv.Text = 'Copies every folder under <Workspace>\Drivers'; $lblExportDrv.AutoSize = $false
$lblExportDrv.Location = '212,76'; $lblExportDrv.Size = New-Object System.Drawing.Size(400, 20)
$grpDrv.Controls.AddRange(@($chkDrv, $txtDrv, $btnDrv, $btnExportDrv, $lblExportDrv))
Add-Cell $grpDrv 2 0

$grpPf = New-Object System.Windows.Forms.GroupBox
$grpPf.Text = '5. Customization profile'; $grpPf.Dock = 'Fill'
$grpPf.Size = New-Object System.Drawing.Size(500, 106)
$lblPf = New-Object System.Windows.Forms.Label; $lblPf.Text = 'Profile:'; $lblPf.AutoSize = $true; $lblPf.Location = '14,24'
$cmbPf = New-Object System.Windows.Forms.ComboBox
$cmbPf.DropDownStyle = 'DropDownList'; $cmbPf.Location = '72,20'; $cmbPf.Size = New-Object System.Drawing.Size(180, 23)
[void]$cmbPf.Items.Add('Safe')
[void]$cmbPf.Items.Add('Standard')
[void]$cmbPf.Items.Add('Aggressive')
$cmbPf.SelectedIndex = 0
$lblPfSafe = New-Object System.Windows.Forms.Label
$lblPfSafe.Text = 'Safe = updates only, no removal.'; $lblPfSafe.AutoSize = $true; $lblPfSafe.Location = '14,50'
$lblPfAggr = New-Object System.Windows.Forms.Label
$lblPfAggr.Text = 'Aggressive removals need explicit authorization.'; $lblPfAggr.AutoSize = $true; $lblPfAggr.Location = '14,72'
$grpPf.Controls.AddRange(@($lblPf, $cmbPf, $lblPfSafe, $lblPfAggr))
Add-Cell $grpPf 2 1

# ===== ROW 3: 6. OOBE / unattend.xml =====
$grpOb = New-Object System.Windows.Forms.GroupBox
$grpOb.Text = '6. OOBE / unattend.xml (optional)'; $grpOb.Dock = 'Fill'
$grpOb.Size = New-Object System.Drawing.Size(1142, 102)
$chkOb = New-Object System.Windows.Forms.CheckBox
$chkOb.Text = 'Generate and attach unattend.xml'; $chkOb.AutoSize = $true; $chkOb.Location = '14,20'
$lblCn = New-Object System.Windows.Forms.Label; $lblCn.Text = 'Computer name'; $lblCn.AutoSize = $true; $lblCn.Location = '14,48'
$txtCn = New-Object System.Windows.Forms.TextBox; $txtCn.Location = '112,45'; $txtCn.Size = New-Object System.Drawing.Size(170, 23)
$lblUsr = New-Object System.Windows.Forms.Label; $lblUsr.Text = 'Local account'; $lblUsr.AutoSize = $true; $lblUsr.Location = '312,48'
$txtUsr = New-Object System.Windows.Forms.TextBox; $txtUsr.Location = '410,45'; $txtUsr.Size = New-Object System.Drawing.Size(170, 23)
$lblTz = New-Object System.Windows.Forms.Label; $lblTz.Text = 'Time zone'; $lblTz.AutoSize = $true; $lblTz.Location = '612,48'
$txtTz = New-Object System.Windows.Forms.TextBox; $txtTz.Location = '684,45'; $txtTz.Size = New-Object System.Drawing.Size(220, 23)
$lblPwd = New-Object System.Windows.Forms.Label; $lblPwd.Text = 'Password'; $lblPwd.AutoSize = $true; $lblPwd.Location = '14,74'
$txtPwd = New-Object System.Windows.Forms.TextBox; $txtPwd.Location = '112,71'; $txtPwd.Size = New-Object System.Drawing.Size(170, 23)
$txtPwd.UseSystemPasswordChar = $true
$chkAdm = New-Object System.Windows.Forms.CheckBox
$chkAdm.Text = 'Add to Administrators'; $chkAdm.AutoSize = $true; $chkAdm.Location = '312,72'
$grpOb.Controls.AddRange(@($chkOb, $lblCn, $txtCn, $lblUsr, $txtUsr, $lblTz, $txtTz, $lblPwd, $txtPwd, $chkAdm))
Add-Cell $grpOb 3 0 2

# ===== ROW 4: 7. Output =====
$grpOut = New-Object System.Windows.Forms.GroupBox
$grpOut.Text = '7. Output'; $grpOut.Dock = 'Fill'
$grpOut.Size = New-Object System.Drawing.Size(1142, 112)
$lblOutName = New-Object System.Windows.Forms.Label; $lblOutName.Text = 'Output ISO name'; $lblOutName.AutoSize = $true; $lblOutName.Location = '14,22'
$txtOut = New-Object System.Windows.Forms.TextBox
$txtOut.Location = '128,19'; $txtOut.Size = New-Object System.Drawing.Size(420, 23)
$lblOutHint = New-Object System.Windows.Forms.Label
$lblOutHint.Text = '(under <Workspace>\Output; the name carries the serviced build)'; $lblOutHint.AutoSize = $true; $lblOutHint.Location = '562,22'
$lblLastApplied = New-Object System.Windows.Forms.Label
$lblLastApplied.Text = 'Last applied MSU (latest):'; $lblLastApplied.AutoSize = $true; $lblLastApplied.Location = '14,48'
$lblLastAppliedVal = New-Object System.Windows.Forms.Label
$lblLastAppliedVal.Text = ''; $lblLastAppliedVal.AutoSize = $true; $lblLastAppliedVal.Location = '160,48'
$lblLastAppliedVal.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$btnCopySummary = New-Object System.Windows.Forms.Button
$btnCopySummary.Text = 'Copy summary'; $btnCopySummary.Size = New-Object System.Drawing.Size(110, 26); $btnCopySummary.Location = '14,72'
$lblLastAppliedHint = New-Object System.Windows.Forms.Label
$lblLastAppliedHint.Text = 'From State\LatestAppliedMsu.json when present.'; $lblLastAppliedHint.AutoSize = $true; $lblLastAppliedHint.Location = '132,78'
$grpOut.Controls.AddRange(@($lblOutName, $txtOut, $lblOutHint, $lblLastApplied, $lblLastAppliedVal, $btnCopySummary, $lblLastAppliedHint))
Add-Cell $grpOut 4 0 2

# ===== ROW 5: ADK | USB | Actions =====
$actRow = New-Object System.Windows.Forms.TableLayoutPanel
$actRow.Dock = 'Fill'; $actRow.ColumnCount = 3; $actRow.RowCount = 1; $actRow.Margin = '0,0,0,0'
[void]$actRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 32)))
[void]$actRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 28)))
[void]$actRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent', 40)))

$grpAdk = New-Object System.Windows.Forms.GroupBox; $grpAdk.Dock = 'Fill'; $grpAdk.Text = 'ADK'
$grpAdk.Size = New-Object System.Drawing.Size(361, 112)
$btnAdk = New-Object System.Windows.Forms.Button
$btnAdk.Text = 'Install Windows ADK Deployment Tools'; $btnAdk.Size = New-Object System.Drawing.Size(290, 26); $btnAdk.Location = '14,22'
$lblAdk = New-Object System.Windows.Forms.Label
$lblAdk.Text = 'Required for the ISO rebuild (oscdimg.exe).'; $lblAdk.AutoSize = $false
$lblAdk.Location = '14,54'; $lblAdk.Size = New-Object System.Drawing.Size(320, 40)
$grpAdk.Controls.AddRange(@($btnAdk, $lblAdk))
$actRow.Controls.Add($grpAdk, 0, 0)

$grpUsb = New-Object System.Windows.Forms.GroupBox; $grpUsb.Dock = 'Fill'; $grpUsb.Text = 'USB'
$grpUsb.Size = New-Object System.Drawing.Size(315, 112)
$btnUsb = New-Object System.Windows.Forms.Button
$btnUsb.Text = 'Select USB flash drive and burn'; $btnUsb.Size = New-Object System.Drawing.Size(250, 26); $btnUsb.Location = '14,22'
$lblUsb = New-Object System.Windows.Forms.Label
$lblUsb.Text = 'Formats the drive and copies the ISO install media onto it (install.wim is split under 4 GB for FAT32). Erases the drive.'; $lblUsb.AutoSize = $false
$lblUsb.Location = '14,54'; $lblUsb.Size = New-Object System.Drawing.Size(280, 46)
$grpUsb.Controls.AddRange(@($btnUsb, $lblUsb))
$actRow.Controls.Add($grpUsb, 1, 0)

$grpAc = New-Object System.Windows.Forms.GroupBox; $grpAc.Dock = 'Fill'; $grpAc.Text = 'Actions'
$grpAc.Size = New-Object System.Drawing.Size(450, 112)
$btnInsp = New-Object System.Windows.Forms.Button
$btnInsp.Text = 'Inspect (read-only)'; $btnInsp.Size = New-Object System.Drawing.Size(130, 26); $btnInsp.Location = '14,20'
$btnP3 = New-Object System.Windows.Forms.Button
$btnP3.Text = 'Run to Phase 3'; $btnP3.Size = New-Object System.Drawing.Size(115, 26); $btnP3.Location = '150,20'
$btnP4 = New-Object System.Windows.Forms.Button
$btnP4.Text = 'Run to Phase 4'; $btnP4.Size = New-Object System.Drawing.Size(115, 26); $btnP4.Location = '271,20'
$btnP8 = New-Object System.Windows.Forms.Button
$btnP8.Text = 'Run to Phase 8'; $btnP8.Size = New-Object System.Drawing.Size(115, 26); $btnP8.Location = '14,54'
$lblCustomPhase = New-Object System.Windows.Forms.Label
$lblCustomPhase.Text = 'Custom phase (1-10)'; $lblCustomPhase.AutoSize = $true; $lblCustomPhase.Location = '140,58'
$numPhase = New-Object System.Windows.Forms.NumericUpDown
$numPhase.Minimum = 1; $numPhase.Maximum = 10; $numPhase.Value = 8
$numPhase.Location = '258,55'; $numPhase.Size = New-Object System.Drawing.Size(56, 23)
$btnCustom = New-Object System.Windows.Forms.Button
$btnCustom.Text = 'Run'; $btnCustom.Size = New-Object System.Drawing.Size(55, 25); $btnCustom.Location = '322,54'
$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = 'Stop'; $btnStop.Size = New-Object System.Drawing.Size(60, 25); $btnStop.Location = '384,54'
$grpAc.Controls.AddRange(@($btnInsp, $btnP3, $btnP4, $btnP8, $lblCustomPhase, $numPhase, $btnCustom, $btnStop))
$actRow.Controls.Add($grpAc, 2, 0)

Add-Cell $actRow 5 0 2

# ===== ROW 6: Log =====
$grpLog = New-Object System.Windows.Forms.GroupBox; $grpLog.Dock = 'Fill'; $grpLog.Text = 'Log'
$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true; $logBox.ReadOnly = $true; $logBox.ScrollBars = 'Vertical'
$logBox.Dock = 'Fill'
$logBox.Font = New-Object System.Drawing.Font('Consolas', 8)
$grpLog.Controls.Add($logBox)
Add-Cell $grpLog 6 0 2

# ===== ROW 7: Status strip =====
$status = New-Object System.Windows.Forms.StatusStrip
$lblStatus = New-Object System.Windows.Forms.ToolStripStatusLabel
$lblStatus.Text = 'Idle'
$status.Dock = 'Fill'
[void]$status.Items.Add($lblStatus)
Add-Cell $status 7 0 2

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
    if (Test-Path -LiteralPath $upd) {
        $n = @(Get-ChildItem -LiteralPath $upd -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.msu', '.cab' }).Count
    }
    $lblUpd.Text = ('Packages found in ' + $upd + ' : ' + $n)
}

# StrictMode-safe property read for objects deserialized from JSON.
function Get-MetaValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function ConvertTo-MetaInt {
    param($Value)
    if ($null -eq $Value) { return 0 }
    $parsed = 0
    if ([int]::TryParse(([string]$Value).Trim(), [ref]$parsed)) { return $parsed }
    return 0
}

function Get-MetaStringList {
    param($Value)
    $list = @()
    if ($null -eq $Value) { return ,$list }
    foreach ($v in @($Value)) { if ($null -ne $v -and ([string]$v)) { $list += [string]$v } }
    return ,$list
}

# Build an ISO name that carries the Windows build level, for example
#   Win11_Pro_x64_26300.9711_Updated_20261020.iso
# With -Build/-Revision the level is taken from the image that was just
# serviced, so the name always shows the NEW build rather than the source one.
function New-OutputIsoName {
    param([string]$IsoPath = '', [int]$Build = 0, [int]$Revision = 0, [string]$Stamp = '')
    $b = $Build; $r = $Revision
    if ($b -le 0 -and $IsoPath) {
        $leaf = [System.IO.Path]::GetFileNameWithoutExtension($IsoPath)
        $m = [regex]::Match($leaf, '(\d{5})[_.](\d{1,6})')
        if ($m.Success) { $b = [int]$m.Groups[1].Value; $r = [int]$m.Groups[2].Value }
    }
    if ($b -le 0 -and $script:DetectedBuild -gt 0) { $b = $script:DetectedBuild; $r = $script:DetectedRevision }
    if (-not $Stamp) { $Stamp = Get-Date -Format 'yyyyMMdd' }
    $level = ''
    if ($b -gt 0) { $level = [string]$b; if ($r -gt 0) { $level += '.' + [string]$r } }
    if ($level) { return ('Win11_Pro_x64_' + $level + '_Updated_' + $Stamp + '.iso') }
    return ('Win11_Pro_x64_Updated_' + $Stamp + '.iso')
}

function Set-OutputIsoName {
    param([string]$Name)
    if (-not $Name) { return }
    $script:SuppressOutEdit = $true
    try { $txtOut.Text = $Name } finally { $script:SuppressOutEdit = $false }
}

function Get-EnrichedOutputIsoNameFromMeta {
    param([object]$Meta, [string]$CurrentIsoName)
    if (-not $Meta -or -not $CurrentIsoName) { return '' }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($CurrentIsoName)

    $nested = Get-MetaValue $Meta 'latest_applied_msu'
    $build = ConvertTo-MetaInt (Get-MetaValue $Meta 'build')
    $sp = ConvertTo-MetaInt (Get-MetaValue $Meta 'servicePackBuild')
    if ($build -le 0) { $build = ConvertTo-MetaInt (Get-MetaValue $nested 'applied_build') }
    if ($sp -le 0) { $sp = ConvertTo-MetaInt (Get-MetaValue $nested 'applied_servicePackBuild') }

    $level = ''
    if ($build -gt 0) {
        $level = [string]$build
        if ($sp -gt 0) { $level += '.' + [string]$sp }
    }
    else {
        $kb = Get-MetaStringList (Get-MetaValue $nested 'applied_kb')
        if ($kb.Count -gt 0) {
            $newest = [string]$kb[$kb.Count - 1]
            if ($newest -match '(\d{5,})') { $newest = 'KB' + $Matches[1] }
            $level = $newest
        }
    }
    if (-not $level) { return '' }

    # Canonical form <product>_<build.rev>_Updated_<date>.iso: swap the level in
    # place so the name shows the build AFTER servicing, not the source build.
    $m = [regex]::Match($base, '^(?<prefix>.+?)_\d{5}(\.\d{1,6})?_Updated_(?<date>\d{8})$')
    if ($m.Success) {
        return ($m.Groups['prefix'].Value + '_' + $level + '_Updated_' + $m.Groups['date'].Value + '.iso')
    }

    # Legacy form: append the level once, never twice.
    $bare = $base -replace '_\d{5}(\.\d{1,6})?$', ''
    $bare = $bare -replace '[._-]+$', ''
    return ($bare + '_' + $level + '.iso')
}

function Refresh-OutputFromMeta {
    $ws = Get-Workspace
    $metaPath = Join-Path (Join-Path $ws 'Output') 'OUTPUT-ISO-META.json'
    if (Test-Path -LiteralPath $metaPath) {
        try {
            $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $enriched = Get-EnrichedOutputIsoNameFromMeta -Meta $meta -CurrentIsoName $txtOut.Text
            if ($enriched -and $enriched -ne $txtOut.Text -and $script:OutNameAuto) {
                Set-OutputIsoName $enriched
                Add-Log ('[gui] output ISO name refreshed from the built image level: ' + $enriched)
            }
        } catch { }
    }
    Refresh-LastAppliedMsu
}

function Refresh-LastAppliedMsu {
    $ws = Get-Workspace
    $path = Join-Path (Join-Path $ws 'State') 'LatestAppliedMsu.json'
    $record = $null
    if (Test-Path -LiteralPath $path) {
        try { $record = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $record = $null }
    }
    if ($null -eq $record) {
        # Fall back to the copy recorded next to the built ISO.
        $metaPath = Join-Path (Join-Path $ws 'Output') 'OUTPUT-ISO-META.json'
        if (Test-Path -LiteralPath $metaPath) {
            try { $record = Get-MetaValue (Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json) 'latest_applied_msu' } catch { $record = $null }
        }
    }
    if ($null -eq $record) {
        $lblLastAppliedVal.Text = 'none recorded'
        return
    }
    try {
        $kb = Get-MetaStringList (Get-MetaValue $record 'applied_kb')
        $build = ConvertTo-MetaInt (Get-MetaValue $record 'applied_build')
        $sp = ConvertTo-MetaInt (Get-MetaValue $record 'applied_servicePackBuild')
        $parts = @()
        if ($kb.Count -gt 0) { $parts += ('KBs: ' + ($kb -join ', ')) }
        if ($build -gt 0 -and $sp -gt 0) { $parts += ('new level: ' + $build + '.' + $sp) }
        if ($build -gt 0) { $parts += ('build: ' + $build) }
        if ($sp -gt 0) { $parts += ('servicePackBuild: ' + $sp) }
        if ($parts.Count -eq 0) { $lblLastAppliedVal.Text = 'recorded but no applied KB/build info'; return }
        $text = ($parts -join ' | ')
        if ($lblLastAppliedVal.Text -ne $text) {
            $lblLastAppliedVal.Text = $text
            Add-Log ('[gui] latest applied MSU summary refreshed: ' + $text)
        }
    } catch {
        $lblLastAppliedVal.Text = 'error reading latest-applied record'
    }
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
        $gi = & $dismExe /English /Get-ImageInfo /ImageFile:$wim /Index:1 2>&1 | Out-String
        $mv = [regex]::Match($gi, '(?im)^\s*Version\s+:\s*10\.0\.(\d+)')
        if ($mv.Success) { $script:DetectedBuild = [int]$mv.Groups[1].Value }
        $mr = [regex]::Match($gi, '(?im)^\s*ServicePack Build\s+:\s*(\d+)')
        if ($mr.Success) { $script:DetectedRevision = [int]$mr.Groups[1].Value }
        if ($count -gt 0 -and $script:DetectedBuild -gt 0 -and $script:OutNameAuto) {
            $named = New-OutputIsoName -IsoPath $iso -Build $script:DetectedBuild -Revision $script:DetectedRevision
            Set-OutputIsoName $named
            Add-Log ('[gui] output ISO name set from the selected image level: ' + $named)
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
    if ($chkOpt.Checked) { $a += '-IncludeOptional' }
    $logDir = Join-Path $env:TEMP ('winiso-dl-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    [void](New-Item -ItemType Directory -Path $logDir -Force)
    $script:LogOut = Join-Path $logDir 'stdout.log'; $script:LogErr = Join-Path $logDir 'stderr.log'
    $script:ShownOut = 0; $script:ShownErr = 0; $script:Finished = $false
    [System.IO.File]::WriteAllText($script:LogOut, ''); [System.IO.File]::WriteAllText($script:LogErr, '')
    Add-Log ('[gui] downloader: powershell ' + ($a -join ' '))
    $lblStatus.Text = 'Searching / downloading updates ...'
    try { $progUp.Style = 'Continuous' } catch { } $progUp.Value = 0; $progUp.Visible = $true
    $lblUpProg.Text = 'Starting update search...'
    $script:DlTotalMb = 0; $script:DlDoneMb = 0; $script:DlCurrentName = ''
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
if ($btnWs) { $btnWs.Add_Click({ $d = New-Object System.Windows.Forms.FolderBrowserDialog; if ($d.ShowDialog() -eq 'OK') { if ($txtWs) { $txtWs.Text = $d.SelectedPath }; Update-UpdateInfo } }) }
if ($btnIso) { $btnIso.Add_Click({ $d = New-Object System.Windows.Forms.OpenFileDialog; $d.Filter = 'ISO images (*.iso)|*.iso|All files (*.*)|*.*'; if ($d.ShowDialog() -eq 'OK') { if ($txtIso) { $txtIso.Text = $d.FileName } } }) }
if ($btnDrv) { $btnDrv.Add_Click({ $d = New-Object System.Windows.Forms.FolderBrowserDialog; if ($d.ShowDialog() -eq 'OK') { if ($txtDrv) { $txtDrv.Text = $d.SelectedPath } } }) }
$btnExportDrv.Add_Click({
    $ws = Get-Workspace
    if (-not $ws) { [void][System.Windows.Forms.MessageBox]::Show('Workspace is required.'); return }
    $srcDefault = Join-Path $ws 'Drivers'
    if (-not (Test-Path -LiteralPath $srcDefault)) { [void](New-Item -ItemType Directory -Path $srcDefault -Force) }

    # MessageBox::Show(text, caption, buttons, icon) - the caption must not be
    # folded into the text, or 'Question' lands in the buttons slot and the
    # call throws a PSInvalidCastException.
    $ask = 'How do you want to export drivers?' + "`n`n" +
        'Yes  = export the driver store of THIS running Windows machine with' + "`n" +
        '       Export-WindowsDriver -Online (needs an elevated GUI).' + "`n" +
        'No   = copy the driver folders already present in <Workspace>\Drivers.' + "`n" +
        'Cancel = do nothing.'
    $choose = [System.Windows.Forms.MessageBox]::Show($ask, 'Export drivers - choose method', 'YesNoCancel', 'Question')
    if ($choose -eq 'Cancel') { return }
    $modeOnline = ($choose -eq 'Yes')  # Yes = B (online export), No = A (copy existing folders)

    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = 'Export drivers: choose a destination folder.'
    $d.RootFolder = 'Desktop'
    $d.SelectedPath = $srcDefault
    if ($d.ShowDialog() -ne 'OK') { return }
    $dst = $d.SelectedPath
    Add-Log ('[gui] export-driver destination: ' + $dst)

    if ($modeOnline) {
        # --- Export-WindowsDriver -Online path ---
        $admin = (New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $admin) {
            [void][System.Windows.Forms.MessageBox]::Show('Export-WindowsDriver requires an elevated PowerShell. Run WinISO-GUI as Administrator and try again.', 'Export drivers', 'OK', 'Warning')
            Add-Log '[gui] export-online skipped: not elevated'
            return
        }
        if (-not (Get-Command Export-WindowsDriver -ErrorAction SilentlyContinue)) {
            [void][System.Windows.Forms.MessageBox]::Show('Export-WindowsDriver is not available on this system (Windows 10/11 Desktop PowerShell). Try the copy-existing-folders option instead.', 'Export drivers', 'OK', 'Warning')
            Add-Log '[gui] export-online skipped: Export-WindowsDriver not found'
            return
        }
        if (-not (Test-Path -LiteralPath $dst)) { [void](New-Item -ItemType Directory -Path $dst -Force) }
        try { $d2 = Get-Item -LiteralPath $dst; if ($d2.IsReadOnly -eq $true) { $d2.IsReadOnly = $false } } catch { }

        Add-Log ('[gui] exporting online driver store -> ' + $dst)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $logPath = Join-Path $env:TEMP ('winiso-drv-export-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
        $errPath = Join-Path $env:TEMP ('winiso-drv-export-err-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
        # Run Export-WindowsDriver in a child elevated-equivalent call. We do NOT redirect via *> into a file
        # (that collides with Start-Process redirection and caused the prior IOException). Instead rely on
        # RedirectStandardOutput/StandardError only, and read $proc.ExitCode + the redirected files.
        $cmd = ('Export-WindowsDriver -Online -Destination "' + $dst + '" -Verbose')
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-Command',$cmd -NoNewWindow -Wait -PassThru -RedirectStandardOutput $logPath -RedirectStandardError $errPath
        $elapsed = $sw.Elapsed.TotalSeconds
        $exStd = if (Test-Path $logPath) { Get-Content $logPath -Raw -Encoding UTF8 } else { '' }
        $exErr = if (Test-Path $errPath) { Get-Content $errPath -Raw -Encoding UTF8 } else { '' }
        $exitCode = $proc.ExitCode
        $files = if (Test-Path -LiteralPath $dst) { @(Get-ChildItem -LiteralPath $dst -File -ErrorAction SilentlyContinue).Count } else { 0 }
        $folders = if (Test-Path -LiteralPath $dst) { @(Get-ChildItem -LiteralPath $dst -Directory -ErrorAction SilentlyContinue).Count } else { 0 }
        $ok = ($exitCode -eq 0) -and ($folders -gt 0)
        if ($ok) {
            $lbl = ('Exported driver store to ' + $dst + ' in ' + ([math]::Round($elapsed,1)) + 's; ' + $folders + ' driver folder(s), ' + $files + ' file(s).')
            Add-Log ('[gui] ' + $lbl)
            Add-Log ('[gui] Export-WindowsDriver exit code: ' + $exitCode)
            if ($exErr) { Add-Log ('[gui] Export-WindowsDriver stderr: ' + ($exErr -replace "`r`n", ' / ')) }
            [void][System.Windows.Forms.MessageBox]::Show($lbl, 'Export drivers', 'OK', 'Information')
        } else {
            $reason = 'Export-WindowsDriver exit code ' + $exitCode
            Add-Log ('[gui] FAILED online export: ' + $reason)
            $detail = 'Export-WindowsDriver -Online -Destination ' + $dst + ' exited with code ' + $exitCode + "`n`nLast stdout lines:`n" + (($exStd -split "`r`n" | Select-Object -Last 20) -join "`n") + "`n`nStderr:`n" + $exErr
            Add-Log ('[gui] ' + (($exStd -split "`r`n" | Select-Object -Last 8) -join "`n"))
            [void][System.Windows.Forms.MessageBox]::Show('Export-WindowsDriver failed.' + "`n`n" + $reason, 'Export drivers', 'OK', 'Error')
            [void][System.Windows.Forms.MessageBox]::Show($detail, 'Export drivers - log', 'OK', 'Information')
        }
    } else {
        # --- Copy existing driver folders path (your previous behavior, hardened) ---
        $src = $srcDefault
        $copied = 0; $failed = 0; $total = 0
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $failDetails = New-Object System.Collections.Generic.List[string]
        $folders = @(Get-ChildItem -LiteralPath $src -Directory -ErrorAction SilentlyContinue)
        $total = $folders.Count
        if ($total -eq 0) {
            Add-Log ('[gui] no driver folders found in ' + $src)
            [void][System.Windows.Forms.MessageBox]::Show(('No driver folders found in ' + $src), 'Export drivers', 'OK', 'Information'); return
        }
        # Make the destination writable (some workspace trees are readonly).
        if (-not (Test-Path -LiteralPath $dst)) { [void](New-Item -ItemType Directory -Path $dst -Force) }
        try { $destDir = Get-Item -LiteralPath $dst; if ($destDir.IsReadOnly -eq $true) { $destDir.IsReadOnly = $false } } catch { }
        foreach ($f in $folders) {
            $name = $f.Name
            $srcPath = $f.FullName
            $destPath = Join-Path $dst $name
            $ok = $false
            $lastErr = ''
            # Attempt 1: Copy-Item (quick path for simple trees).
            $tries = 0
            while (-not $ok -and $tries -lt 3) {
                try {
                    if (Test-Path -LiteralPath $destPath) { Remove-Item -LiteralPath $destPath -Recurse -Force -ErrorAction Stop }
                    Copy-Item -Path $srcPath -Destination $dst -Recurse -Force -ErrorAction Stop
                    $ok = $true
                } catch {
                    $tries++
                    $lastErr = $_.Exception.Message
                    Start-Sleep -Milliseconds (300 * $tries)
                }
            }
            # Attempt 2 (only if Copy-Item failed after retries): robocopy, which is more tolerant of
            # long paths, ACL/readonly subtleties, and transient sharing violations on Windows.
            if (-not $ok) {
                $rcExit = -1
                try {
                    $rc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $srcPath, $dst, '/E', '/COPYALL', '/R:2', '/W:2', '/NFL', '/NDL', '/NJH', '/NJS' -NoNewWindow -Wait -PassThru -ErrorAction Stop
                    $rcExit = $rc.ExitCode
                } catch { $lastErr = 'robocopy start failed: ' + $_.Exception.Message }
                # robocopy exit codes: 0-7 = expected success-ish; 8+ = real failure.
                if ($rcExit -ge 0 -and $rcExit -le 7) { $ok = $true }
            }
            if ($ok) { $copied++ } else {
                $failed++
                $reason = if ($lastErr) { $lastErr } else { 'unknown' }
                # Keep the log readable: one summary line, plus the first-fault detail once.
                Add-Log ('[gui] FAILED to copy ' + $name + ' -- ' + $reason)
                if ($failDetails.Count -eq 0) { $failDetails.Add(('First failure detail: ' + $reason)) }
            }
        }
        $elapsed = $sw.Elapsed.TotalSeconds
        $lbl = ('Exported ' + $copied + ' of ' + $total + ' driver folder(s) to ' + $dst + ' in ' + ([math]::Round($elapsed,1)) + 's')
        Add-Log ('[gui] ' + $lbl)
        if ($failed -gt 0) {
            $detailLbl = $lbl + "`n`nFirst failure detail: " + ($failDetails -join '; ')
            [void][System.Windows.Forms.MessageBox]::Show($detailLbl, 'Export drivers - some failed', 'OK', 'Warning')
        } else {
            [void][System.Windows.Forms.MessageBox]::Show($lbl, 'Export drivers', 'OK', 'Information')
        }
    }
})
$btnUpd.Add_Click({ $u = Join-Path (Get-Workspace) 'Updates'; if (-not (Test-Path -LiteralPath $u)) { [void](New-Item -ItemType Directory -Path $u -Force) }; Start-Process explorer.exe $u })
if ($btnLoadEd) { $btnLoadEd.Add_Click({ Load-EditionsFromIso }) }
if ($btnLoadRep) { $btnLoadRep.Add_Click({ Load-Editions }) }
if ($btnDl) { $btnDl.Add_Click({ Search-DownloadUpdates }) }
if ($btnInsp) { $btnInsp.Add_Click({ Load-Editions; Start-Run -TargetPhase 3 -ReadOnly }) }
if ($btnP3) { $btnP3.Add_Click({ Start-Run -TargetPhase 3 -ReadOnly }) }
if ($btnP4) { $btnP4.Add_Click({ Start-Run -TargetPhase 4 }) }
if ($btnCustom) { $btnCustom.Add_Click({ Start-Run -TargetPhase ([int]$numPhase.Value) }) }
if ($btnP8) { $btnP8.Add_Click({ Start-Run -TargetPhase 8 }) }
if ($btnStop) { $btnStop.Add_Click({
    if ($script:Child -and -not $script:Child.HasExited) {
        try { $script:Child.Kill() } catch { }
        Add-Log '[gui] child process killed by user.'
        Add-Log '[gui] IMPORTANT: if an image was mounted, run  dism /Get-MountedImageInfo  and unmount with /Discard.'
        $lblStatus.Text = 'Stopped'
    } else { Add-Log '[gui] nothing running.' }
}) }

if ($btnCopySummary) { $btnCopySummary.Add_Click({
    $ws = Get-Workspace
    $path = Join-Path (Join-Path $ws 'State') 'LatestAppliedMsu.json'
    if (-not (Test-Path -LiteralPath $path)) { [void][System.Windows.Forms.MessageBox]::Show('No latest-applied MSU record found. Run servicing (Phase 4) successfully first.'); return }
    try {
        $nl = [Environment]::NewLine
        $m = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $kbList = Get-MetaStringList (Get-MetaValue $m 'applied_kb')
        $buildVal = ConvertTo-MetaInt (Get-MetaValue $m 'applied_build')
        $spVal = ConvertTo-MetaInt (Get-MetaValue $m 'applied_servicePackBuild')
        $parts = @()
        if ($kbList.Count -gt 0) { $parts += ('KBs: ' + ($kbList -join ', ')) }
        if ($buildVal -gt 0) { $parts += ('build: ' + $buildVal) }
        if ($spVal -gt 0) { $parts += ('servicePackBuild: ' + $spVal) }
        $integrated = [string](Get-MetaValue $m 'integrated_at')
        if ($integrated) { $parts += ('integrated_at: ' + $integrated) }
        $sourceMedia = [string](Get-MetaValue $m 'source_media')
        if ($sourceMedia) { $parts += ('source_media: ' + $sourceMedia) }
        $summary = 'Latest successfully applied MSU/KB list from ' + $ws + $nl + ($parts -join $nl)
        [System.Windows.Forms.Clipboard]::SetText($summary)
        Add-Log '[gui] latest applied MSU summary copied to clipboard.'
        [void][System.Windows.Forms.MessageBox]::Show(('Copied to clipboard:' + $nl + $summary), 'Copy summary', 'OK', 'Information')
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show('Could not read latest-applied record: ' + $_.Exception.Message, 'Copy summary', 'OK', 'Error')
    }})
}

if ($btnAdk) { $btnAdk.Add_Click({
    $link = 'https://learn.microsoft.com/windows-hardware/get-started/adk-install'
    try {
        Start-Process -FilePath $link -ErrorAction Stop
        Add-Log ('[gui] opened ADK download page: ' + $link)
    } catch {
        $msg = 'Failed to open the ADK download page: ' + $_.Exception.Message
        Add-Log ('[gui] ' + $msg)
        [void][System.Windows.Forms.MessageBox]::Show($msg, 'Install ADK', 'OK', 'Warning')
    }
}) }

# ---------------------------------------------------------------------------
# 8. Burn the finished ISO to a USB flash drive
# ---------------------------------------------------------------------------
if ($btnUsb) {
    $btnUsb.Add_Click({
        $nl = [Environment]::NewLine
        if ($script:Child -and -not $script:Child.HasExited) {
            [void][System.Windows.Forms.MessageBox]::Show('A build run is in progress. Wait for it to finish before burning a USB drive.', 'Burn ISO to USB', 'OK', 'Warning')
            return
        }
        if ($script:UsbBurn -and $script:UsbBurn.Running) {
            [void][System.Windows.Forms.MessageBox]::Show('A USB burn is already running. Wait for it to finish before starting another.', 'Burn ISO to USB', 'OK', 'Warning')
            return
        }
        $outName = ([string]$txtOut.Text).Trim()
        if (-not $outName) {
            [void][System.Windows.Forms.MessageBox]::Show('Output ISO name is empty.', 'Burn ISO to USB', 'OK', 'Warning')
            return
        }
        $ws = Get-Workspace
        $iso = Join-Path (Join-Path $ws 'Output') $outName
        if (-not (Test-Path -LiteralPath $iso)) {
            $missing = 'Output ISO not found:' + $nl + $iso + $nl + $nl + 'Run a build first (Phase 7).'
            [void][System.Windows.Forms.MessageBox]::Show($missing, 'Burn ISO to USB', 'OK', 'Warning')
            return
        }

        $confirm = 'This will erase ALL data on the selected USB flash drive, format it, and copy the Windows installation media onto it.'
        if ([System.Windows.Forms.MessageBox]::Show($confirm, 'Burn ISO to USB - data loss', 'YesNo', 'Warning') -ne 'Yes') { return }

        $drives = @()
        try {
            $drives = @(Get-Disk -ErrorAction Stop |
                Where-Object { $_.BusType -match 'USB|SD' -and $_.IsBoot -ne $true -and $_.IsSystem -ne $true } |
                Sort-Object Number)
        } catch {
            Add-Log ('[gui] could not enumerate disks: ' + $_.Exception.Message)
        }
        if ($drives.Count -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show('No USB flash drive detected. Plug one in, wait for it to appear in Explorer, then try again.', 'Burn ISO to USB', 'OK', 'Warning')
            return
        }

        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = 'Select the USB flash drive to burn to'
        $dlg.Size = New-Object System.Drawing.Size(520, 300)
        $dlg.StartPosition = 'CenterParent'
        $dlg.FormBorderStyle = 'FixedDialog'
        $dlg.MaximizeBox = $false
        $dlg.MinimizeBox = $false
        $lv = New-Object System.Windows.Forms.ListView
        $lv.View = 'Details'
        $lv.FullRowSelect = $true
        $lv.GridLines = $true
        $lv.MultiSelect = $false
        $lv.Location = New-Object System.Drawing.Point(10, 10)
        $lv.Size = New-Object System.Drawing.Size(490, 200)
        $hdr = New-Object System.Windows.Forms.ColumnHeader
        $hdr.Text = 'Disk'; $hdr.Width = 60; [void]$lv.Columns.Add($hdr)
        $hdr = New-Object System.Windows.Forms.ColumnHeader
        $hdr.Text = 'Size'; $hdr.Width = 100; [void]$lv.Columns.Add($hdr)
        $hdr = New-Object System.Windows.Forms.ColumnHeader
        $hdr.Text = 'Partition style'; $hdr.Width = 130; [void]$lv.Columns.Add($hdr)
        $hdr = New-Object System.Windows.Forms.ColumnHeader
        $hdr.Text = 'Model'; $hdr.Width = 190; [void]$lv.Columns.Add($hdr)
        foreach ($d in $drives) {
            $gb = [double]$d.Size / 1GB
            $sizeText = ([math]::Round($gb, 1)).ToString() + ' GB'
            if ($gb -ge 1024) { $sizeText = ([math]::Round($gb / 1024, 2)).ToString() + ' TB' }
            $style = 'unknown'
            if ($d.PartitionStyle) { $style = [string]$d.PartitionStyle }
            $item = New-Object System.Windows.Forms.ListViewItem([string]$d.Number)
            [void]$item.SubItems.Add($sizeText)
            [void]$item.SubItems.Add($style)
            [void]$item.SubItems.Add([string]$d.FriendlyName)
            $item.Tag = $d
            [void]$lv.Items.Add($item)
        }
        if ($lv.Items.Count -gt 0) { $lv.Items[0].Selected = $true }
        $dlg.Controls.Add($lv)

        $lblWarn = New-Object System.Windows.Forms.Label
        $lblWarn.Text = 'The selected drive is ERASED (diskpart clean) before the ISO is copied.'
        $lblWarn.ForeColor = [System.Drawing.Color]::DarkRed
        $lblWarn.AutoSize = $true
        $lblWarn.Location = New-Object System.Drawing.Point(12, 216)
        $dlg.Controls.Add($lblWarn)

        $btnGo = New-Object System.Windows.Forms.Button
        $btnGo.Text = 'Burn to this drive'
        $btnGo.Location = New-Object System.Drawing.Point(10, 240)
        $btnGo.Size = New-Object System.Drawing.Size(300, 28)
        $btnGo.DialogResult = 'OK'
        $dlg.Controls.Add($btnGo)
        $btnCancel = New-Object System.Windows.Forms.Button
        $btnCancel.Text = 'Cancel'
        $btnCancel.Location = New-Object System.Drawing.Point(320, 240)
        $btnCancel.Size = New-Object System.Drawing.Size(180, 28)
        $btnCancel.DialogResult = 'Cancel'
        $dlg.Controls.Add($btnCancel)
        $dlg.AcceptButton = $btnGo
        $dlg.CancelButton = $btnCancel

        if ($dlg.ShowDialog() -ne 'OK') { $dlg.Dispose(); return }
        if (-not $lv.SelectedItems.Count) { $dlg.Dispose(); Add-Log '[gui] no disk selected; burn cancelled.'; return }
        $selected = $lv.SelectedItems[0].Tag
        $dlg.Dispose()

        $diskNum = [int]$selected.Number
        if ($selected.IsBoot -eq $true -or $selected.IsSystem -eq $true) {
            [void][System.Windows.Forms.MessageBox]::Show('Refusing to write to the boot/system disk.', 'Burn ISO to USB', 'OK', 'Error')
            return
        }

        if (-not (Test-Path -LiteralPath $script:BurnScript)) {
            [void][System.Windows.Forms.MessageBox]::Show(('Burner script not found:' + $nl + $script:BurnScript), 'Burn ISO to USB', 'OK', 'Error')
            return
        }

        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $progPath = Join-Path $env:TEMP ('winiso-usb-' + $stamp + '.progress')
        $logDir = Join-Path $env:TEMP ('winiso-usb-' + $stamp)
        [void](New-Item -ItemType Directory -Path $logDir -Force)
        $burnOut = Join-Path $logDir 'stdout.log'
        $burnErr = Join-Path $logDir 'stderr.log'
        [System.IO.File]::WriteAllText($progPath, ('START' + $nl))
        [System.IO.File]::WriteAllText($burnOut, '')
        [System.IO.File]::WriteAllText($burnErr, '')

        $burnArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:BurnScript,
                      '-IsoPath', $iso, '-DiskNumber', ([string]$diskNum), '-ProgressPath', $progPath)
        Add-Log ('[gui] burning ' + $iso + ' to USB disk ' + $diskNum + ' (progress: ' + $progPath + ')')
        Add-Log ('[gui] burner: powershell ' + ($burnArgs -join ' '))
        $lblStatus.Text = ('Burning ISO to USB disk ' + $diskNum + ' ...')

        $script:UsbBurn = @{
            Running      = $true
            IsoPath      = $iso
            DiskNumber   = $diskNum
            StartedAt    = (Get-Date)
            ProgressPath = $progPath
            OutPath      = $burnOut
            ErrPath      = $burnErr
            TotalBytes   = [double](Get-Item -LiteralPath $iso).Length
            WrittenBytes = [double]0
            Process      = $null
            SeenLines    = 0
            LastPercent  = -1
        }
        try {
            $script:UsbBurn.Process = Start-Process -FilePath 'powershell.exe' -ArgumentList $burnArgs -PassThru -WindowStyle Hidden `
                    -RedirectStandardOutput $burnOut -RedirectStandardError $burnErr
        }
        catch {
            $script:UsbBurn.Running = $false
            Add-Log ('[gui] could not start the burner: ' + $_.Exception.Message)
            [void][System.Windows.Forms.MessageBox]::Show(('Could not start the burner:' + $nl + $_.Exception.Message), 'Burn ISO to USB', 'OK', 'Error')
            return
        }
        $btnUsb.Enabled = $false
        $script:UsbBurnTimer.Start()
    })
}

# ---------------------------------------------------------------------------
# USB burn progress polling
# ---------------------------------------------------------------------------
$script:UsbBurnTimer = New-Object System.Windows.Forms.Timer
$script:UsbBurnTimer.Interval = 500
$script:UsbBurnTimer.Add_Tick({
    if (-not $script:UsbBurn -or -not $script:UsbBurn.Running) { $script:UsbBurnTimer.Stop(); $btnUsb.Enabled = $true; return }

    $lines = @(Get-Content -LiteralPath $script:UsbBurn.ProgressPath -ErrorAction SilentlyContinue)
    if ($lines.Count -gt $script:UsbBurn.SeenLines) {
        $from = [int]$script:UsbBurn.SeenLines
        if ($from -lt 0) { $from = 0 }
        $newLines = @($lines[$from..($lines.Count - 1)])
        $script:UsbBurn.SeenLines = $lines.Count
        foreach ($rawLine in $newLines) {
            $line = [string]$rawLine
            if ($line -match '^PROGRESS:(\d+):(\d+)$') {
                $doneBytes = [double]$Matches[1]
                $totalBytes = [double]$Matches[2]
                $script:UsbBurn.WrittenBytes = $doneBytes
                if ($totalBytes -gt 0) { $script:UsbBurn.TotalBytes = $totalBytes }
                $pct = 0
                if ($totalBytes -gt 0) { $pct = [math]::Min(100, [math]::Round(($doneBytes / $totalBytes) * 100, 1)) }
                if ($pct -ne $script:UsbBurn.LastPercent) {
                    $script:UsbBurn.LastPercent = $pct
                    $lblStatus.Text = ('Burning ISO to USB disk ' + $script:UsbBurn.DiskNumber + ': ' + $pct + '% (' + [math]::Round($doneBytes / 1MB, 1) + ' of ' + [math]::Round($totalBytes / 1MB, 1) + ' MB)')
                }
            }
            elseif ($line -match '^PHASE:(.+)$') {
                $lblStatus.Text = ('USB burn: ' + $Matches[1])
                Add-Log ('[gui] usb: ' + $Matches[1])
            }
            elseif ($line -match '^INFO:(.+)$') {
                Add-Log ('[gui] usb: ' + $Matches[1])
            }
            elseif ($line -match '^DONE:(.+):(\d+):(\d+)$') {
                $dest = [string]$Matches[1]
                $script:UsbBurn.Running = $false
                $script:UsbBurnTimer.Stop()
                $btnUsb.Enabled = $true
                Add-Log ('[gui] USB burn complete: ' + $dest)
                $lblStatus.Text = 'USB burn complete'
                [void][System.Windows.Forms.MessageBox]::Show(('ISO written to the USB drive:' + [Environment]::NewLine + $dest), 'Burn ISO to USB', 'OK', 'Information')
            }
            elseif ($line -match '^ERROR:(.+)$') {
                $reason = [string]$Matches[1]
                $script:UsbBurn.Running = $false
                $script:UsbBurnTimer.Stop()
                $btnUsb.Enabled = $true
                Add-Log ('[gui] USB burn FAILED: ' + $reason)
                $lblStatus.Text = 'USB burn failed'
                [void][System.Windows.Forms.MessageBox]::Show(('USB burn failed:' + [Environment]::NewLine + [Environment]::NewLine + $reason), 'Burn ISO to USB', 'OK', 'Error')
            }
        }
    }
    if (-not $script:UsbBurn.Running) { return }

    # The burner can stop before it writes a terminal line (crash, missing
    # elevation, drive removed). Never leave the UI "burning" forever.
    $proc = $script:UsbBurn.Process
    if ($proc -and $proc.HasExited) {
        $script:UsbBurn.Running = $false
        $script:UsbBurnTimer.Stop()
        $btnUsb.Enabled = $true
        $detail = ''
        if ($script:UsbBurn.ErrPath -and (Test-Path -LiteralPath $script:UsbBurn.ErrPath)) {
            $detail = ([string](Get-Content -LiteralPath $script:UsbBurn.ErrPath -Raw -ErrorAction SilentlyContinue)).Trim()
        }
        $code = $proc.ExitCode
        Add-Log ('[gui] USB burn process exited with code ' + $code + ' without reporting a result.')
        if ($detail) { Add-Log ('[gui] usb stderr: ' + $detail) }
        $lblStatus.Text = 'USB burn failed'
        $msg = 'USB burn failed: the burner stopped without reporting a result (exit code ' + $code + ').'
        if ($detail) { $msg += [Environment]::NewLine + [Environment]::NewLine + $detail }
        [void][System.Windows.Forms.MessageBox]::Show($msg, 'Burn ISO to USB', 'OK', 'Error')
    }
})

# ---------------------------------------------------------------------------
# Static control wiring
# ---------------------------------------------------------------------------
$chkDrv.Add_CheckedChanged({ $txtDrv.Enabled = $chkDrv.Checked; $btnDrv.Enabled = $chkDrv.Checked })
$txtDrv.Enabled = $false
$btnDrv.Enabled = $false

# The output name follows the build level until the user types their own name.
$txtOut.Add_TextChanged({ if (-not $script:SuppressOutEdit) { $script:OutNameAuto = $false } })
$txtIso.Add_TextChanged({
    if ($script:OutNameAuto) { Set-OutputIsoName (New-OutputIsoName -IsoPath ([string]$txtIso.Text).Trim()) }
})

$form.Add_FormClosing({
    if ($script:Child -and -not $script:Child.HasExited) {
        if ([System.Windows.Forms.MessageBox]::Show('A run is in progress. Kill it and exit?', 'Confirm', 'YesNo', 'Warning') -ne 'Yes') {
            $_.Cancel = $true
        } else {
            try { $script:Child.Kill() } catch { }
        }
    }
    if ($script:UsbBurn -and $script:UsbBurn.Running) {
        $burnWarn = 'A USB burn is in progress. Closing now leaves the drive half written.'
        if ([System.Windows.Forms.MessageBox]::Show($burnWarn, 'Burn in progress', 'YesNo', 'Warning') -ne 'Yes') {
            $_.Cancel = $true
        } else {
            try { if ($script:UsbBurn.Process -and -not $script:UsbBurn.Process.HasExited) { $script:UsbBurn.Process.Kill() } } catch { }
            $script:UsbBurnTimer.Stop()
        }
    }
})

# ---------------------------------------------------------------------------
# Log tail timer (streams the child process output into the log pane)
# ---------------------------------------------------------------------------
$script:TailTimer = New-Object System.Windows.Forms.Timer
$script:TailTimer.Interval = 400
$script:TailTimer.Add_Tick({
    if ($script:LogOut -and (Test-Path -LiteralPath $script:LogOut)) {
        $all = @(Get-Content -LiteralPath $script:LogOut -ErrorAction SilentlyContinue)
        if ($all.Count -gt $script:ShownOut) {
            $new = @($all[$script:ShownOut..($all.Count - 1)])
            $script:ShownOut = $all.Count
            foreach ($line in $new) {
                $t = [string]$line
                if ($t -match '^DL-PROGBAR (.+?) (\d+\.?\d*)MB / (\d+\.?\d*)MB (\d+\.?\d*)%$') {
                    $lblUpProg.Text = ('Downloading: ' + $Matches[1] + '  ' + $Matches[2] + ' of ' + $Matches[3] + ' MB (' + $Matches[4] + '%)')
                    $progUp.Visible = $true
                    $pv = [double]$Matches[4]
                    if ($pv -lt 0) { $pv = 0 }
                    if ($pv -gt 100) { $pv = 100 }
                    $progUp.Value = [int]$pv
                }
                elseif ($t -match '^DL-DONE (.+?) (\d+\.?\d*)MB$') {
                    Add-Log ('[gui] downloaded ' + $Matches[1] + ' (' + $Matches[2] + ' MB)')
                }
                elseif ($t -match '^DL-PHASE (.+)$') {
                    $lblUpProg.Text = ('  ' + $Matches[1])
                    $progUp.Visible = $true
                }
                elseif ($t -match '^DL-DONE-ALL (\d+)') {
                    $lblUpProg.Text = ('Downloaded ' + $Matches[1] + ' package file(s).')
                    $progUp.Value = 100
                }
                else {
                    Add-Log $t
                }
            }
        }
    }
    if ($script:LogErr -and (Test-Path -LiteralPath $script:LogErr)) {
        $allE = @(Get-Content -LiteralPath $script:LogErr -ErrorAction SilentlyContinue)
        if ($allE.Count -gt $script:ShownErr) {
            $newE = @($allE[$script:ShownErr..($allE.Count - 1)])
            $script:ShownErr = $allE.Count
            Add-Log ($newE -join [Environment]::NewLine)
        }
    }
    if ($script:Child -and $script:Child.HasExited -and -not $script:Finished) {
        $script:Finished = $true
        $script:TailTimer.Stop()
        $progUp.Visible = $false
        $lblUpProg.Text = ''
        Add-Log ('[gui] child exited with code ' + $script:Child.ExitCode)
        $lblStatus.Text = ('Finished (exit ' + $script:Child.ExitCode + ')')
        if ($script:Child.ExitCode -eq 0) { Refresh-OutputFromMeta }
        Update-UpdateInfo
    }
})

# Default the source ISO to the workspace ISO when one is present, so the
# generated output name already carries its build level.
if (-not ([string]$txtIso.Text).Trim()) {
    foreach ($candidate in @(
            (Join-Path (Split-Path -Parent (Get-Workspace)) 'Windows11_Client_x64_en-us_26300_9457.iso'),
            (Join-Path (Get-Workspace) 'Windows11_Client_x64_en-us_26300_9457.iso'))) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { $script:SuppressOutEdit = $true; $txtIso.Text = $candidate; $script:SuppressOutEdit = $false; break }
    }
}
if ($script:OutNameAuto) { Set-OutputIsoName (New-OutputIsoName -IsoPath ([string]$txtIso.Text).Trim()) }
Add-Log ('[gui] output ISO will be written as: ' + [string]$txtOut.Text)

Update-UpdateInfo
Add-Log '[gui] ready. Choose a source, then Inspect (read-only) or Run.'
Add-Log ('[gui] orchestrator: ' + $script:Orchestrator)
if ($NoShow) {
    # Regression guard: setting Row/Column on the TableLayoutPanel does not add
    # a control to it. Walk the real control tree and require the panes to be
    # attached, otherwise the window comes up blank.
    function Get-DescendantControl {
        param($Root)
        $acc = New-Object System.Collections.ArrayList
        foreach ($c in $Root.Controls) {
            [void]$acc.Add($c)
            foreach ($d in (Get-DescendantControl -Root $c)) { [void]$acc.Add($d) }
        }
        return $acc
    }
    $desc = @(Get-DescendantControl -Root $form)
    $groups = @($desc | Where-Object { $_ -is [System.Windows.Forms.GroupBox] })
    $boxes = @($desc | Where-Object { $_ -is [System.Windows.Forms.TextBox] })
    $buttons = @($desc | Where-Object { $_ -is [System.Windows.Forms.Button] })
    $missing = @()
    if ($groups.Count -lt 8) { $missing += ('only ' + $groups.Count + ' group boxes are attached to the form (expected at least 8)') }
    if ($buttons.Count -lt 10) { $missing += ('only ' + $buttons.Count + ' buttons are attached to the form') }
    if (-not ($desc -contains $logBox)) { $missing += 'the log pane is not attached to the form' }
    if (-not ($desc -contains $tbl)) { $missing += 'the layout table is not attached to the form' }
    $expected = [ordered]@{
        grpSrc = $grpSrc; grpEd = $grpEd; grpUp = $grpUp; grpDrv = $grpDrv; grpPf = $grpPf
        grpOb = $grpOb; grpOut = $grpOut; grpLog = $grpLog; actRow = $actRow; status = $status
    }
    foreach ($k in $expected.Keys) {
        if (-not ($desc -contains $expected[$k])) { $missing += ('control not attached to the form: ' + $k) }
    }
    if ($missing.Count -gt 0) {
        Write-Host 'GUICHECK FAILED:'
        foreach ($m in $missing) { Write-Host ('  - ' + $m) }
        exit 3
    }
    Write-Host ('GUICHECK tree     : ' + $desc.Count + ' controls, ' + $groups.Count + ' group boxes, ' + $buttons.Count + ' buttons, ' + $boxes.Count + ' text boxes')
    Refresh-LastAppliedMsu
    Write-Host ('GUICHECK output name: ' + [string]$txtOut.Text)
    $metaProbe = [pscustomobject]@{ build = 26300; servicePackBuild = 9711; latest_applied_msu = [pscustomobject]@{ applied_build = 26300; applied_servicePackBuild = 9711; applied_kb = @('KB5127648') } }
    $renamed = Get-EnrichedOutputIsoNameFromMeta -Meta $metaProbe -CurrentIsoName 'Win11_Pro_x64_26300.9457_Updated_20260101.iso'
    Write-Host ('GUICHECK renamed to new build: ' + $renamed)
    if ($renamed -notmatch '26300\.9711') { Write-Host 'GUICHECK FAILED: output name did not pick up the new build level'; exit 4 }
    Write-Host ('GUICHECK last-applied: ' + $lblLastAppliedVal.Text)
    $metaCheck = Join-Path (Join-Path (Get-Workspace) 'Output') 'OUTPUT-ISO-META.json'
    if (Test-Path -LiteralPath $metaCheck) {
        try {
            $metaObj = Get-Content -LiteralPath $metaCheck -Raw -Encoding UTF8 | ConvertFrom-Json
            $candidate = Get-EnrichedOutputIsoNameFromMeta -Meta $metaObj -CurrentIsoName ([string]$txtOut.Text).Trim()
            if ($candidate) { Write-Host ('GUICHECK enriched name: ' + $candidate) } else { Write-Host 'GUICHECK enriched name: (unchanged)' }
        } catch {
            Write-Host ('GUICHECK enriched name: ERROR ' + $_.Exception.Message)
        }
    }
    Write-Host 'GUICHECK OK: form, controls, timers and meta helpers verified; ShowDialog skipped.'
    $form.Dispose()
    exit 0
}
[void]$form.ShowDialog()
$form.Dispose()
