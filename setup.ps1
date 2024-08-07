# Define the path to the default documents folder
$documentsPath = [Environment]::GetFolderPath("MyDocuments")
$logFilePath = Join-Path -Path $documentsPath -ChildPath "InstallationLog.txt"

# Function to install applications silently and log output
function Install-ApplicationSilently($appName) {
    Write-Host "Installing $appName..."
    Start-Process -FilePath "powershell.exe" -ArgumentList "-Command choco install $appName -y --force --params /ALLUSERS" -NoNewWindow -Wait -RedirectStandardOutput "$logFilePath" -PassThru | Out-Null
    Write-Progress -Activity "Installing applications..." -Status "Installing $appName" -PercentComplete ([math]::Round((100 / $apps.Count)))
}

# Check if winget is installed, if not, install it silently
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "winget not found. Installing winget..."
    $wingetInstallUrl = 'https://aka.ms/getwinget'
    $wingetInstallerPath = [System.IO.Path]::GetTempFileName() + '.appxbundle'
    Invoke-WebRequest -Uri $wingetInstallUrl -OutFile $wingetInstallerPath
    Write-Host "Downloading winget installer..."
    Start-Process -FilePath $wingetInstallerPath -ArgumentList '/quiet' -NoNewWindow -Wait | Out-Null
    Write-Host "winget installed successfully."
    Remove-Item $wingetInstallerPath
}

# Set execution policy and install Chocolatey silently
Write-Host "Setting execution policy and installing Chocolatey..."
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')) | Out-File -FilePath "$logFilePath" -Append
Write-Host "Chocolatey installed successfully."

# Enable Chocolatey features for smoother installations
Write-Host "Enabling Chocolatey features..."
choco feature enable -n=useRememberedArgumentsForUpgrades
choco feature enable -n=allowGlobalConfirmation | Out-File -FilePath "$logFilePath" -Append
Write-Host "Chocolatey features enabled."

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

# Install applications silently and log output
foreach ($app in $apps) {
    Install-ApplicationSilently -appName $app
}

# Install and configure PSWindowsUpdate silently
Write-Host "Installing and configuring PSWindowsUpdate..."
Start-Process -FilePath "powershell.exe" -ArgumentList "-Command Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted; Install-Module -Name PSWindowsUpdate -Force -AllowClobber; Import-Module PSWindowsUpdate; Get-WindowsUpdate -Install -AcceptAll -IgnoreReboot" -NoNewWindow -Wait | Out-Null
Write-Host "PSWindowsUpdate installed and configured."

# Optional: Add a work or school account silently
Write-Host "Opening work or school account settings..."
Start-Process -FilePath "powershell.exe" -ArgumentList "-Command Start-Process -FilePath 'ms-settings:workplace' -Wait" -NoNewWindow -PassThru | Out-Null

Write-Host "Setup complete."
