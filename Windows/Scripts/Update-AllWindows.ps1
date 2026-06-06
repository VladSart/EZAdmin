# Install and import PSWindowsUpdate module
Install-Module -Name PSWindowsUpdate -Force
Import-Module PSWindowsUpdate

# Install all available Windows updates without auto reboot
Install-WindowsUpdate -AcceptAll -IgnoreReboot

# Run Intune sync job
$Shell = New-Object -ComObject Shell.Application
$Shell.Open("intunemanagementextension://syncapp")

# Wait for sync to complete (adjust timeout as needed)
Start-Sleep -Seconds 60

# Get the current user's Documents folder path
$documentsPath = [Environment]::GetFolderPath("MyDocuments")

# Get the last Intune sync time from the registry
$lastSyncTime = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts\*\Protected\ConnInfo" -Name "ServerLastSuccessTime" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ServerLastSuccessTime

# Create the dump file content
$dumpContent = "Last Intune Sync Time: $lastSyncTime`nCurrent Date and Time: $(Get-Date)"

# Create the dump file in the Documents folder
$dumpFilePath = Join-Path $documentsPath "Intune Sync Time and Date.txt"
$dumpContent | Out-File -FilePath $dumpFilePath -Force

Write-Host "Dump file created at: $dumpFilePath"
