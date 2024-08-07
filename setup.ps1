# Define the path to the default documents folder
$documentsPath = [Environment]::GetFolderPath("MyDocuments")
$logFilePath = Join-Path -Path $documentsPath -ChildPath "InstallationLog.txt"

# Function to install applications silently and log output
function Install-ApplicationSilently($appName) {
    Write-Host "Starting installation of $appName..."
    Start-Job -ScriptBlock {
        param($app)
        Start-Process -FilePath "powershell.exe" -ArgumentList "-Command choco install $app -y --force --params /ALLUSERS" -NoNewWindow -Wait -RedirectStandardOutput "$using:logFilePath"
    } -ArgumentList $appName -Name $appName | Out-Null
}

# Function to install Winget silently
function Install-WingetSilently {
    Write-Host "Starting Winget installation..."
    $wingetInstallerUrl = "https://aka.ms/winget-install"
    Invoke-WebRequest -Uri $wingetInstallerUrl -OutFile winget-installer.exe
    Start-Process -FilePath "./winget-installer.exe" -ArgumentList "/silent /accept-package-agreements /accept-msixjs-license" -Wait
    Remove-Item winget-installer.exe
}

# Function to install PSWindowsUpdate module silently
function Install-PSWindowsUpdateModuleSilently {
    Write-Host "Installing PSWindowsUpdate module..."
    Install-PackageProvider -Name NuGet -Force -Confirm:$false
    Install-Module -Name PSWindowsUpdate -Force -Confirm:$false
}

# Function to fetch and install Windows updates silently
function Install-WindowsUpdatesSilently {
    Write-Host "Fetching and installing Windows updates..."
    Import-Module PSWindowsUpdate
    Get-WindowsUpdate -AcceptAll -Install -AutoReboot
}

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

# Install Winget silently
Install-WingetSilently

# Install PSWindowsUpdate module silently
Install-PSWindowsUpdateModuleSilently

# Start installations concurrently using background jobs
foreach ($app in $apps) {
    Install-ApplicationSilently -appName $app
}

# Function to display progress based on completed jobs
function Show-Progress {
    param($totalJobs)
    $completedJobs = Get-Job | Where-Object { $_.State -eq 'Completed' } | Measure-Object | %{$_.Count}
    $progress = ($completedJobs / $totalJobs) * 100
    Write-Host "Overall Progress: $([math]::Round($progress))% completed."
}

# Periodically check and display progress
while ((Get-Job | Where-Object { $_.State -eq 'Running' }).Count -gt 0) {
    Show-Progress -totalJobs $apps.Count
    Start-Sleep -Seconds 30 # Adjust sleep duration based on preference
}

# Wait for all jobs to complete
Get-Job | Wait-Job

# Fetch and install Windows updates silently
Install-WindowsUpdatesSilently

# Receive job results (if needed)
# Get-Job | Receive-Job

Write-Host "All installations started. Please check the log file for details."

# Cleanup
Get-Job | Remove-Job
