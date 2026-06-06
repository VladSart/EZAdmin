Start-Transcript -Path "$env:USERPROFILE\Desktop\IntuneLogs.txt"
Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostic-Provider/Admin" | Where-Object {$_.Id -in 75,76,100,101,102} | Format-List
Stop-Transcript
