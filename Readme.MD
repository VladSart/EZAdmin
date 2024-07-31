# This gets a new machine up and going with apps most client machines need


## How to use this?
1. Run a Admin Powershell session, preferably as an admin user (local user or domain admin signed-in)
2. Copy and Paste
3. Profit

## How to add more packages
On the apps list create a new ("xxxx",) without the "()" and replace the xxxx with a name of the package in https://community.chocolatey.org/packages?q=

## Script

```

# Set execution policy and install Chocolatey
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

# Enable Chocolatey features for smoother installations
choco feature enable -n=useRememberedArgumentsForUpgrades
choco feature enable -n=allowGlobalConfirmation

# Install required applications without specifying versions
$apps = @(
    "office365business",
    "adobereader",
    "googlechrome",
    "firefox",
    "vcredist140",
    "zoom",
    "vcredist2015",
    "7zip.install",
    "7zip",
    "citrix-workspace",
    "forticlientvpn",
    "microsoft-teams-new-bootstrapper"
)

foreach ($app in $apps) {
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList "-Command", "choco install $app -y --force --params ""/ALLUSERS"""
}

# Install and configure PSWindowsUpdate
Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList "-Command", "Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted; Install-Module -Name PSWindowsUpdate -Force -AllowClobber; Import-Module PSWindowsUpdate; Get-WindowsUpdate -Install -AcceptAll -IgnoreReboot"

# Optional: Add a work or school account
Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList "-Command", "Start-Process -FilePath 'ms-settings:workplace' -Wait"

```
