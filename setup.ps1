# Define the URL of the main script on GitHub
$scriptUrl = 'https://github.com/username/repository/raw/main/setup.ps1'

# Check if winget is installed, if not, install it silently
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "winget not found. Installing winget..."
    $wingetInstallUrl = 'https://aka.ms/getwinget'
    $wingetInstallerPath = [System.IO.Path]::GetTempFileName() + '.appxbundle'
    Invoke-WebRequest -Uri $wingetInstallUrl -OutFile $wingetInstallerPath
    Start-Process -FilePath $wingetInstallerPath -ArgumentList '/quiet' -NoNewWindow -Wait
    Remove-Item $wingetInstallerPath
}

# Set execution policy and install Chocolatey
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

# Enable Chocolatey features for smoother installations
choco feature enable -n=useRememberedArgumentsForUpgrades
choco feature enable -n=allowGlobalConfirmation

# Define the applications to install
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

# Simulate progress bar for installations
$totalApps = $apps.Count
$progress = 0
 
Write-Host "Installing applications..."

foreach ($app in $apps) {
    Start-Process -FilePath "powershell.exe" -ArgumentList "-Command", "choco install $app -y --force --params ""/ALLUSERS""" -NoNewWindow -Wait
    $progress += [math]::Round((100 / $totalApps))
    Write-Progress -PercentComplete $progress -Status "Installing applications..." -CurrentOperation "Installing $app"
}

# Install and configure PSWindowsUpdate
Start-Process -FilePath "powershell.exe" -ArgumentList "-Command", "Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted; Install-Module -Name PSWindowsUpdate -Force -AllowClobber; Import-Module PSWindowsUpdate; Get-WindowsUpdate -Install -AcceptAll -IgnoreReboot" -NoNewWindow -Wait

# Optional: Add a work or school account
Start-Process -FilePath "powershell.exe" -ArgumentList "-Command", "Start-Process -FilePath 'ms-settings:workplace' -Wait" -NoNewWindow -Wait

Write-Host "Setup complete."
