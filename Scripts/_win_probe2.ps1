$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class WP3 {
    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr hWnd, EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int c);
    [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, StringBuilder s, int c);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
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
$p = Start-Process -FilePath $exe -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','D:\WimMount\Scripts\WinISO-GUI.ps1','-NoElevate')
for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 500; $p.Refresh(); if ($p.MainWindowHandle -ne [IntPtr]::Zero) { break } }
Start-Sleep -Seconds 3
$h = $p.MainWindowHandle
$r = New-Object WP3+RECT
[void][WP3]::GetWindowRect($h, [ref]$r)
$c = New-Object WP3+RECT
[void][WP3]::GetClientRect($h, [ref]$c)
Write-Output ('window rect  : ' + ($r.Right-$r.Left) + 'x' + ($r.Bottom-$r.Top))
Write-Output ('client rect  : ' + ($c.Right-$c.Left) + 'x' + ($c.Bottom-$c.Top))
Write-Output ('dpi          : ' + [WP3]::GetDpiForWindow($h))
$all = [WP3]::All($h)
foreach ($n in $all) {
    if ($n.Txt -match '^\d\.|^ADK$|^USB$|^Actions$|^Log$') {
        Write-Output ('GROUP ' + $n.Txt + '  rect=' + ($n.R-$n.L) + 'x' + ($n.B-$n.T) + ' at ' + $n.L + ',' + $n.T)
        foreach ($k in ($all | Where-Object { $_.P -eq $n.H })) {
            Write-Output ('   child ' + ($k.R-$k.L) + 'x' + ($k.B-$k.T) + ' at ' + ($k.L-$n.L) + ',' + ($k.T-$n.T) + '  "' + $k.Txt + '"')
        }
    }
}
[void][WP3]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Seconds 2
try { if (-not $p.HasExited) { $p.Kill() } } catch { }
