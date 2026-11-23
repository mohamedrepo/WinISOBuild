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
[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 70)))   # 1. Source
[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 180)))  # 2. Editions + 3. Updates
[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 104)))  # 4. Drivers + 5. Profile
[void]$tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 100)))  # 6. OOBE
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
$lblWs = New-Object System.Windows.Forms.Label; $lblWs.Text = 'Workspace'; $lblWs.AutoSize = $true; $lblWs.Location = '14,24'
$txtWs = New-Object System.Windows.Forms.TextBox
$txtWs.Location = '104,21'; $txtWs.Size = New-Object System.Drawing.Size(500, 23)
$txtWs.Anchor = 'Top,Left,Right'; $txtWs.Text = 'D:\WimMount'
$btnWs = New-Object System.Windows.Forms.Button
$btnWs.Text = 'Browse...'; $btnWs.Size = New-Object System.Drawing.Size(88, 25); $btnWs.Anchor = 'Top,Right'
$lblIso = New-Object System.Windows.Forms.Label; $lblIso.Text = 'Source ISO'; $lblIso.AutoSize = $true; $lblIso.Location = '14,48'
$txtIso = New-Object System.Windows.Forms.TextBox
$txtIso.Location = '104,45'; $txtIso.Size = New-Object System.Drawing.Size(500, 23); $txtIso.Anchor = 'Top,Left,Right'
$btnIso = New-Object System.Windows.Forms.Button
$btnIso.Text = 'Browse...'; $btnIso.Size = New-Object System.Drawing.Size(88, 25); $btnIso.Anchor = 'Top,Right'; $btnIso.Location = '580,44'
$btnWs.Location = '580,20'
$grpSrc.Controls.AddRange(@($lblWs, $txtWs, $btnWs, $lblIso, $txtIso, $btnIso))
Add-Cell $grpSrc 0 0 2

# ===== ROW 1: 2. Editions (left) | 3. Updates (right) =====
$grpEd = New-Object System.Windows.Forms.GroupBox
$grpEd.Text = '2. Editions to service (-ImageIndexes; none checked = all)'; $grpEd.Dock = 'Fill'
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
$chkDrv = New-Object System.Windows.Forms.CheckBox
$chkDrv.Text = 'Inject drivers (DISM /Add-Driver /Recurse)'; $chkDrv.AutoSize = $true; $chkDrv.Location = '14,20'
$txtDrv = New-Object System.Windows.Forms.TextBox
$txtDrv.Text = 'D:\WimMount\Drivers'; $txtDrv.Location = '14,44'; $txtDrv.Size = New-Object System.Drawing.Size(420, 23)
$txtDrv.Anchor = 'Top,Left,Right'
$btnDrv = New-Object System.Windows.Forms.Button
$btnDrv.Text = 'Browse...'; $btnDrv.Size = New-Object System.Drawing.Size(88, 25); $btnDrv.Location = '440,42'; $btnDrv.Anchor = 'Top,Right'
$btnExportDrv = New-Object System.Windows.Forms.Button
$btnExportDrv.Text = 'Export all drivers to...'; $btnExportDrv.Size = New-Object System.Drawing.Size(190, 26); $btnExportDrv.Location = '14,72'
$lblExportDrv = New-Object System.Windows.Forms.Label
$lblExportDrv.Text = 'Copies every folder under <Workspace>\Drivers'; $lblExportDrv.AutoSize = $false
$lblExportDrv.Location = '212,76'; $lblExportDrv.Size = New-Object System.Drawing.Size(400, 20)
$grpDrv.Controls.AddRange(@($chkDrv, $txtDrv, $btnDrv, $btnExportDrv, $lblExportDrv))
Add-Cell $grpDrv 2 0

$grpPf = New-Object System.Windows.Forms.GroupBox
$grpPf.Text = '5. Customization profile'; $grpPf.Dock = 'Fill'
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
$lblOutName = New-Object System.Windows.Forms.Label; $lblOutName.Text = 'Output ISO name'; $lblOutName.AutoSize = $true; $lblOutName.Location = '14,22'
$txtOut = New-Object System.Windows.Forms.TextBox
$txtOut.Text = 'Win11_Updated.iso'; $txtOut.Location = '128,19'; $txtOut.Size = New-Object System.Drawing.Size(420, 23)
$lblOutHint = New-Object System.Windows.Forms.Label
$lblOutHint.Text = '(written under <Workspace>\Output)'; $lblOutHint.AutoSize = $true; $lblOutHint.Location = '562,22'
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
$btnAdk = New-Object System.Windows.Forms.Button
$btnAdk.Text = 'Install Windows ADK Deployment Tools'; $btnAdk.Size = New-Object System.Drawing.Size(290, 26); $btnAdk.Location = '14,22'
$lblAdk = New-Object System.Windows.Forms.Label
$lblAdk.Text = 'Required for the ISO rebuild (oscdimg.exe).'; $lblAdk.AutoSize = $false
$lblAdk.Location = '14,54'; $lblAdk.Size = New-Object System.Drawing.Size(320, 40)
$grpAdk.Controls.AddRange(@($btnAdk, $lblAdk))
$actRow.Controls.Add($grpAdk, 0, 0)

$grpUsb = New-Object System.Windows.Forms.GroupBox; $grpUsb.Dock = 'Fill'; $grpUsb.Text = 'USB'
$btnUsb = New-Object System.Windows.Forms.Button
$btnUsb.Text = 'Select USB flash drive and burn'; $btnUsb.Size = New-Object System.Drawing.Size(250, 26); $btnUsb.Location = '14,22'
$lblUsb = New-Object System.Windows.Forms.Label
$lblUsb.Text = 'Writes the output ISO to a USB drive (FAT32 under 4 GB, NTFS otherwise). Erases the drive.'; $lblUsb.AutoSize = $false
$lblUsb.Location = '14,54'; $lblUsb.Size = New-Object System.Drawing.Size(280, 46)
$grpUsb.Controls.AddRange(@($btnUsb, $lblUsb))
$actRow.Controls.Add($grpUsb, 1, 0)

$grpAc = New-Object System.Windows.Forms.GroupBox; $grpAc.Dock = 'Fill'; $grpAc.Text = 'Actions'
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
