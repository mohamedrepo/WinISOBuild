$ErrorActionPreference = 'Continue'
$file = 'D:\WimMount\Updates\windows11.0-kb5127648-x64_2b88d2d308adc938fcd4d2876a68ee0b2a3c4c09.msu'
$url = 'https://catalog.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/4225b261-8248-43e5-a808-34f3faafe3f6/public/windows11.0-kb5127648-x64_2b88d2d308adc938fcd4d2876a68ee0b2a3c4c09.msu'
$target = [long]5308811935
$log = 'D:\WimMount\Logs\download-cu-task.log'
for ($i = 0; $i -lt 200; $i++) {
    $sz = 0
    if (Test-Path -LiteralPath $file) { $sz = (Get-Item -LiteralPath $file).Length }
    Add-Content -LiteralPath $log -Value ('[' + (Get-Date -Format 'HH:mm:ss') + '] have ' + $sz + ' of ' + $target)
    if ($sz -ge $target) { Add-Content -LiteralPath $log -Value 'COMPLETE'; exit 0 }
    & 'C:\Windows\System32\curl.exe' -sS -L -C - --retry 20 --retry-delay 5 --retry-all-errors -o $file $url 2>&1 |
        Add-Content -LiteralPath $log
    Start-Sleep -Seconds 5
}
Add-Content -LiteralPath $log -Value 'GAVE UP'
exit 1
