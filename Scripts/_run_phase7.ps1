param([int]$TargetPhase = 7, [switch]$Force)
$ErrorActionPreference = 'Stop'
$ws = 'D:\WimMount'
$logDir = Join-Path $ws 'Logs'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$out = Join-Path $logDir ('orchestrator-' + $stamp + '.out.log')
$err = Join-Path $logDir ('orchestrator-' + $stamp + '.err.log')
$args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $ws 'Scripts\Invoke-WinISOService.ps1'),
          '-Workspace', $ws, '-TargetPhase', [string]$TargetPhase)
if ($Force) { $args += '-Force' }
$p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
    -ArgumentList $args -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $out -RedirectStandardError $err
Set-Content -LiteralPath (Join-Path $ws 'State\ORCH-PID.txt') -Value ([string]$p.Id) -Encoding ASCII
Write-Output ('started pid=' + $p.Id)
Write-Output ('stdout=' + $out)
Write-Output ('stderr=' + $err)
