$ErrorActionPreference = 'Stop'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File D:\WimMount\Scripts\_dl_cu.ps1'
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(1)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 6)
Register-ScheduledTask -TaskName 'WinISO-CU-Download' -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName 'WinISO-CU-Download'
Start-Sleep -Seconds 5
Get-ScheduledTask -TaskName 'WinISO-CU-Download' | Select-Object TaskName, State | Format-Table -AutoSize | Out-String
