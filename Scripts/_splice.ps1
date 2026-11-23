$ErrorActionPreference = 'Stop'
$gui = 'D:\WimMount\Scripts\WinISO-GUI.ps1'
$block = 'D:\WimMount\Scripts\_layout_new.ps1'
$lines = [System.IO.File]::ReadAllLines($gui)
$start = -1; $end = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($start -lt 0 -and $lines[$i] -match '^\$tbl = New-Object System\.Windows\.Forms\.TableLayoutPanel') { $start = $i }
    if ($start -ge 0 -and $lines[$i] -match '^Add-Cell \$status 7 0 2') { $end = $i; break }
}
if ($start -lt 0 -or $end -lt 0) { throw ('boundaries not found start=' + $start + ' end=' + $end) }
Write-Output ('replacing lines ' + ($start + 1) + '..' + ($end + 1) + ' of ' + $lines.Count)
$new = [System.IO.File]::ReadAllLines($block)
$out = @()
if ($start -gt 0) { $out += $lines[0..($start - 1)] }
$out += $new
if ($end + 1 -lt $lines.Count) { $out += $lines[($end + 1)..($lines.Count - 1)] }
$text = ($out -join "`r`n") + "`r`n"
$text = $text -replace '\$form\.Size = New-Object System\.Drawing\.Size\(1100, 880\)', '$form.Size = New-Object System.Drawing.Size(1180, 900)'
$text = $text -replace '\$form\.MinimumSize = New-Object System\.Drawing\.Size\(900, 700\)', '$form.MinimumSize = New-Object System.Drawing.Size(1040, 780)'
[System.IO.File]::WriteAllText($gui, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ('written, lines=' + $out.Count)
