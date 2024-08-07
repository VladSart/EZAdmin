# Define the path to the default documents folder
$documentsPath = [Environment]::GetFolderPath("MyDocuments")
$logFilePath = Join-Path -Path $documentsPath -ChildPath "InstallationLog.txt"

# Function to install applications silently and log output
function Install-ApplicationSilently($appName) {
    Write-Host "Starting installation of $appName..."
    Start-Job -ScriptBlock {
        param($app)
        Start-Process -FilePath "powershell.exe" -ArgumentList "-Command choco install $app -y --force --params /ALLUSERS" -NoNewWindow -Wait -RedirectStandardOutput "$using:logFilePath"
    } -ArgumentList $appName | Out-Null
}

# Define the applications to install
$apps = @(
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

# Start Office365Business installation separately
Write-Host "Starting Office365Business installation..."
Start-Job -ScriptBlock {
    Start-Process -FilePath "powershell.exe" -ArgumentList "-Command choco upgrade office365business -y" -NoNewWindow -Wait -RedirectStandardOutput "$using:logFilePath"
} | Out-Null

# Start installations concurrently using background jobs for the rest of the apps
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

# Receive job results (if needed)
# Get-Job | Receive-Job

Write-Host "All installations started. Please check the log file for details."

# Cleanup
Get-Job | Remove-Job
