$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class WinProbe2 {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr hWnd, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int c);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, StringBuilder s, int c);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    public struct RECT { public int Left, Top, Right, Bottom; }
    public class Node { public IntPtr H; public IntPtr P; public string Cls; public string Txt; public int L,T,R,B; }
    public static List<Node> All(IntPtr root) {
        List<Node> list = new List<Node>();
        EnumChildWindows(root, delegate(IntPtr h, IntPtr l) {
            StringBuilder c = new StringBuilder(256); GetClassName(h, c, 256);
            StringBuilder t = new StringBuilder(256); GetWindowText(h, t, 256);
            RECT r; GetWindowRect(h, out r);
            Node n = new Node(); n.H = h; n.P = GetParent(h); n.Cls = c.ToString(); n.Txt = t.ToString();
            n.L = r.Left; n.T = r.Top; n.R = r.Right; n.B = r.Bottom;
            list.Add(n); return true;
        }, IntPtr.Zero);
        return list;
    }
}
'@

$exe = (Get-Process -Id $PID).Path
$p = Start-Process -FilePath $exe -PassThru -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'D:\WimMount\Scripts\WinISO-GUI.ps1', '-NoElevate')
for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 500; $p.Refresh(); if ($p.MainWindowHandle -ne [IntPtr]::Zero) { break } }
Start-Sleep -Seconds 3
$p.Refresh()
if ($p.MainWindowHandle -eq [IntPtr]::Zero) { Write-Output 'NO WINDOW'; try { $p.Kill() } catch { }; exit 1 }
Write-Output ('window: ' + $p.MainWindowTitle + '  size=' + (Get-Process -Id $p.Id).MainWindowHandle)

$all = [WinProbe2]::All($p.MainWindowHandle)
Write-Output ('child windows: ' + $all.Count)

# overlaps between siblings (same parent, both visible, non-trivial size)
$byParent = @{}
foreach ($n in $all) {
    if (-not $byParent.ContainsKey($n.P)) { $byParent[$n.P] = New-Object System.Collections.ArrayList }
    [void]$byParent[$n.P].Add($n)
}
$overlaps = New-Object System.Collections.ArrayList
foreach ($key in $byParent.Keys) {
    $siblings = @($byParent[$key])
    for ($i = 0; $i -lt $siblings.Count; $i++) {
        for ($j = $i + 1; $j -lt $siblings.Count; $j++) {
            $a = $siblings[$i]; $b = $siblings[$j]
            $wa = $a.R - $a.L; $ha = $a.B - $a.T; $wb = $b.R - $b.L; $hb = $b.B - $b.T
            if ($wa -le 4 -or $ha -le 4 -or $wb -le 4 -or $hb -le 4) { continue }
            $ox = [math]::Min($a.R, $b.R) - [math]::Max($a.L, $b.L)
            $oy = [math]::Min($a.B, $b.B) - [math]::Max($a.T, $b.T)
            if ($ox -gt 2 -and $oy -gt 2) {
                [void]$overlaps.Add(('"' + $a.Txt + '"(' + $wa + 'x' + $ha + ') overlaps "' + $b.Txt + '"(' + $wb + 'x' + $hb + ') by ' + $ox + 'x' + $oy))
            }
        }
    }
}
Write-Output ('overlaps: ' + $overlaps.Count)
foreach ($o in $overlaps) { Write-Output ('  ' + $o) }

# controls clipped by their parent group
$clipped = New-Object System.Collections.ArrayList
foreach ($n in $all) {
    if ($n.R - $n.L -le 4 -or $n.B - $n.T -le 4) { continue }
    $par = $all | Where-Object { $_.H -eq $n.P } | Select-Object -First 1
    if (-not $par) { continue }
    if ($par.Txt -match '^\d\.|ADK|USB|Actions|Log') {
        if ($n.R -gt $par.R - 2 -or $n.B -gt $par.B - 4 -or $n.L -lt $par.L -or $n.T -lt $par.T) {
            [void]$clipped.Add(('"' + $n.Txt + '" ' + ($n.R - $n.L) + 'x' + ($n.B - $n.T) + ' escapes ' + $par.Txt))
        }
    }
}
Write-Output ('clipped: ' + $clipped.Count)
foreach ($c in $clipped) { Write-Output ('  ' + $c) }

[void][WinProbe2]::PostMessage($p.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Milliseconds 300; $p.Refresh(); if ($p.HasExited) { break } }
if ($p.HasExited) { Write-Output ('closed gracefully exit=' + $p.ExitCode) } else { Write-Output 'DID NOT CLOSE'; try { $p.Kill() } catch { } }
