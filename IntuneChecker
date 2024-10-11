powershell -ExecutionPolicy Bypass -Command "& {
  function Write-Status {
    param([string]$Message)
    Write-Host $Message
  }

  Write-Status 'Checking Intune status...'

  # Force Intune sync
  $enrollmentID = (Get-ScheduledTask | Where-Object {$_.TaskPath -like '*Microsoft\Windows\EnterpriseMgmt\*'}).TaskName
  Start-Process -FilePath 'C:\Windows\System32\deviceenroller.exe' -ArgumentList '/c /AutoEnrollMDM' -Wait -WindowStyle Hidden

  # Check and install IntuneManagementExtension
  $ime = Get-Service -Name IntuneManagementExtension -ErrorAction SilentlyContinue
  if (-not $ime) {
    Write-Status 'Installing IntuneManagementExtension...'
    Start-Process -FilePath 'C:\Windows\System32\deviceenroller.exe' -ArgumentList '/c /AutoEnrollMDM' -Wait -WindowStyle Hidden
    Write-Status 'IntuneManagementExtension installed.'
  }

  # Fix common Intune issues
  $dmwappushService = Get-Service -Name dmwappushservice
  if ($dmwappushService.Status -ne 'Running') {
    Write-Status 'Fixing dmwappushservice...'
    Set-Service -Name dmwappushservice -StartupType Automatic
    Start-Service -Name dmwappushservice
    Write-Status 'dmwappushservice fixed.'
  }

  Write-Status 'Restarting IntuneManagementExtension...'
  Restart-Service -Name IntuneManagementExtension -Force

  Write-Status 'Triggering Intune sync...'
  Start-ScheduledTask -TaskName $enrollmentID

  Write-Status 'Intune sync and checks completed.'
}"
