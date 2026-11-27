$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class Shot {
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
$out = 'D:\WimMount\Reports\gui-window.png'
$exe = (Get-Process -Id $PID).Path
$p = Start-Process -FilePath $exe -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','D:\WimMount\Scripts\WinISO-GUI.ps1','-NoElevate')
for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 500; $p.Refresh(); if ($p.MainWindowHandle -ne [IntPtr]::Zero) { break } }
Start-Sleep -Seconds 4
$h = $p.MainWindowHandle
if ($h -eq [IntPtr]::Zero) { Write-Output 'NO WINDOW'; exit 1 }
$r = New-Object Shot+RECT
[void][Shot]::GetWindowRect($h, [ref]$r)
$w = $r.Right - $r.Left; $ht = $r.Bottom - $r.Top
$bmp = New-Object System.Drawing.Bitmap($w, $ht)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
$ok = [Shot]::PrintWindow($h, $hdc, 2)
$g.ReleaseHdc($hdc)
Write-Output ('printwindow=' + $ok + ' size=' + $w + 'x' + $ht)
$bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Output ('saved ' + $out + ' bytes=' + (Get-Item $out).Length)
[void][Shot]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Seconds 2
try { if (-not $p.HasExited) { $p.Kill() } } catch { }
