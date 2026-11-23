$ErrorActionPreference = 'Stop'
$out = 'D:\WimMount\Updates\windows11.0-kb5127648-x64_2b88d2d308adc938fcd4d2876a68ee0b2a3c4c09.msu'
$url = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/4225b261-8248-43e5-a808-34f3faafe3f6/public/windows11.0-kb5127648-x64_2b88d2d308adc938fcd4d2876a68ee0b2a3c4c09.msu'
$log = 'D:\WimMount\Logs\download-cu.log'
$have = (Get-Item -LiteralPath $out).Length
Write-Output ('resuming from ' + $have)
$p = Start-Process -FilePath 'C:\Windows\System32\curl.exe' -PassThru -WindowStyle Hidden `
    -ArgumentList @('-L', '-C', '-', '--retry', '10', '--retry-delay', '5', '--retry-all-errors',
                    '-o', ('"' + $out + '"'), ('"' + $url + '"')) `
    -RedirectStandardOutput $log -RedirectStandardError ($log + '.err')
Write-Output ('curl pid=' + $p.Id)
