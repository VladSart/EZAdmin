# Ensure script is running as Administrator
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "Please run this script as an Administrator!"
    Exit
}

# Set execution policy for this process
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process -Force

# Force install NuGet provider
Install-PackageProvider -Name NuGet -Force -Scope CurrentUser

# Install PSWindowsUpdate module if not already installed
if (!(Get-Module -ListAvailable -Name PSWindowsUpdate)) {
    Write-Host "Installing PSWindowsUpdate module..."
    Install-Module PSWindowsUpdate -Force -Scope CurrentUser
}

# Import the module
Import-Module PSWindowsUpdate

# Install Windows Updates
Write-Host "Checking for and installing Windows Updates..."
Get-WindowsUpdate -Install -AcceptAll -AutoReboot

Write-Host "Script completed. System may reboot if required."
