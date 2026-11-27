param(
    [string]$SourceIso = 'D:\Windows11_Client_x64_en-us_26300_9457.iso',
    [int]$Index = 6,
    [string]$Drivers = 'D:\WimMount\Drivers',
    [string[]]$Packages = @(
        'D:\WimMount\Updates\windows11.0-kb5127648-x64_2b88d2d308adc938fcd4d2876a68ee0b2a3c4c09.msu',
        'D:\WimMount\Updates\windows11.0-kb5127694-x64-ndp481_a1a6f6d3c61e46a77278881fc5f7245bcf09ce3f.msu'
    ),
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
$ws = 'D:\WimMount'
$logDir = Join-Path $ws 'Logs'
if (-not (Test-Path $logDir)) { [void](New-Item -ItemType Directory -Path $logDir -Force) }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outLog = Join-Path $logDir ('build-console-' + $stamp + '.out.log')
$errLog = Join-Path $logDir ('build-console-' + $stamp + '.err.log')

$psArgs = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass',
    '-File', (Join-Path $ws 'Scripts\Build-WinISOUpdated.ps1'),
    '-SourceIso', $SourceIso,
    '-Index', [string]$Index,
    '-Drivers', $Drivers,
    '-Packages', ($Packages -join ','),
    '-WorkDir', (Join-Path $ws 'Work'),
    '-OutDir', (Join-Path $ws 'Output'),
    '-Workspace', $ws
)
if ($Force) { $psArgs += '-Force' }

$exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$p = Start-Process -FilePath $exe -ArgumentList $psArgs -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $outLog -RedirectStandardError $errLog
Set-Content -LiteralPath (Join-Path $ws 'State\BUILD-PID.txt') -Value ([string]$p.Id) -Encoding ASCII
Write-Output ('started pid=' + $p.Id)
Write-Output ('stdout=' + $outLog)
Write-Output ('stderr=' + $errLog)
