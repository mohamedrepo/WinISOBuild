$ErrorActionPreference = 'Stop'
$mod = 'D:\WimMount\Scripts\WinISOService.psm1'
$new = [System.IO.File]::ReadAllLines('D:\WimMount\Scripts\_qpatch_new.txt')
$lines = [System.IO.File]::ReadAllLines($mod)
$start = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -like '*$argString = ($ArgumentList*') { $start = $i; break }
}
if ($start -lt 0) { throw 'argString block not found' }
$end = -1
for ($j = $start; $j -lt $lines.Count; $j++) {
    if ($lines[$j] -match "^\s*\}\) -join ' '") { $end = $j; break }
}
if ($end -lt 0) { throw 'end of argString block not found' }
Write-Output ('replacing lines ' + ($start + 1) + '..' + ($end + 1))
$out = @()
if ($start -gt 0) { $out += $lines[0..($start - 1)] }
$out += $new
if ($end + 1 -lt $lines.Count) { $out += $lines[($end + 1)..($lines.Count - 1)] }
[System.IO.File]::WriteAllText($mod, (($out -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
Write-Output 'patched'
