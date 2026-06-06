# Elevate to admin privileges if not already running as admin
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) 
{ 
    $arguments = "& '" + $myinvocation.mycommand.definition + "'"
    Start-Process powershell -Verb runAs -ArgumentList $arguments
    Exit
}

# ASCII art introduction
$asciiArt = @"
 _   _ ____  ____    ____  _                           _   _      
| | | / ___|| __ )  |  _ \(_) __ _  __ _ _ __   ___  | |_(_) ___ 
| | | \___ \|  _ \  | | | | |/ _` |/ _` | '_ \ / _ \ | __| |/ __|
| |_| |___) | |_) | | |_| | | (_| | (_| | | | | (_) || |_| | (__ 
 \___/|____/|____/  |____/|_|\__,_|\__, |_| |_|\___/  \__|_|\___|
                                   |___/                         
"@

Clear-Host
Write-Host $asciiArt -ForegroundColor Cyan

# Create a wider table-like structure for user instructions with more space in the middle
$userInstructions = @"
+----------------------------------+          +----------------------------------+
|            For Users             |          |           For IT Pros            |
+----------------------------------+          +----------------------------------+
| - Resets USB devices             |          | - Admin privileges required      |
| - Confirm if device stopped      |          | - Registry cleanup performed     |
| - Answer Y (Yes) or N (No)       |          | - Logs saved in:                 |
| - 3 second timeout for response  |          |   C:\USB-Troubleshooting         |
|                                  |          | - Registry backup:               |
|                                  |          |   HKLM\SYSTEM\CurrentControlSet\ |
|                                  |          |   Enum\USBStor                   |
+----------------------------------+          +----------------------------------+
"@

Write-Host $userInstructions -ForegroundColor Yellow

Write-Host @"

This script will attempt to restart all USB devices on your system.

IMPORTANT INSTRUCTIONS:
1. Device names might not be recognizable - this is normal.
2. As each device is processed, use it normally.
3. If a device stops responding, press 'Y' immediately.
4. If the device continues to work, press 'N'.
5. If you don't respond within 3 seconds, the script will attempt to restart the device.
6. All devices that you marked with 'Y' will be logged for further diagnosis.

The goal is to identify and restart problematic USB devices.
Just use your devices as you normally would and respond when prompted.

"@ -ForegroundColor Green

Write-Host "Made by Vladimir Sartini" -ForegroundColor Cyan
Write-Host "Github.com/VladSart/EzAdmin" -ForegroundColor Cyan

Read-Host "Press Enter to start the USB device reset process"

# Create log folder in C: drive
$logFolder = "C:\USB-Troubleshooting"
if (!(Test-Path $logFolder)) {
    New-Item -Path $logFolder -ItemType Directory -Force | Out-Null
}

$logFile = Join-Path $logFolder "usb_diagnostic_log.txt"

# Clear previous log and add introduction
$logIntro = @"
USB Diagnostic Tool Log
-----------------------
This log file contains information about the USB device reset process.
Use Ctrl+F to search for specific entries:
- #SUC# indicates a successful operation
- #ERR# indicates an error or failed operation

"@
Set-Content -Path $logFile -Value $logIntro

# Function to log information
function Log-Info($message, $type) {
    $logEntry = "$(Get-Date) - #$type# $message"
    Add-Content -Path $logFile -Value $logEntry
}

# Function to show progress bar
function Show-Progress {
    param (
        [int]$PercentComplete
    )
    Write-Progress -Activity "Cleaning up registry" -Status "$PercentComplete% Complete:" -PercentComplete $PercentComplete
}

# Function to display animated "Working on it . . ." message
function Show-WorkingMessage {
    param (
        [int]$Duration
    )
    $dots = 1
    $startTime = Get-Date
    while ((Get-Date) - $startTime -lt [TimeSpan]::FromSeconds($Duration)) {
        Write-Host "`rWorking on it " -NoNewline
        Write-Host ("." * $dots) -NoNewline
        $dots = ($dots % 3) + 1
        Start-Sleep -Milliseconds 500
    }
    Write-Host "`r                     `r" -NoNewline
}

# Backup and clear registry entries for disconnected USB devices
Write-Host "Backing up registry and removing old entries..." -ForegroundColor Green
Log-Info "Starting registry backup and cleanup" "SUC"

$backupPath = Join-Path $logFolder "USBStor_Backup.reg"
$removedEntriesLog = Join-Path $logFolder "RemovedRegistryEntries.log"

# Backup the USBStor key
reg export "HKLM\SYSTEM\CurrentControlSet\Enum\USBStor" $backupPath /y | Out-Null
Log-Info "Registry backup saved to: $backupPath" "SUC"

$usbStorKey = "HKLM:\SYSTEM\CurrentControlSet\Enum\USBStor"
$subKeys = Get-ChildItem -Path $usbStorKey -ErrorAction SilentlyContinue

$totalKeys = $subKeys.Count
$processedKeys = 0

foreach ($key in $subKeys) {
    $device = Get-PnpDevice -InstanceId $key.PSChildName -ErrorAction SilentlyContinue
    if (-not $device) {
        Remove-Item -Path $key.PSPath -Recurse -Force -ErrorAction SilentlyContinue
        Add-Content -Path $removedEntriesLog -Value $key.PSPath
        Log-Info "Removed registry entry: $($key.PSPath)" "SUC"
    }
    $processedKeys++
    $percentComplete = [math]::Round(($processedKeys / $totalKeys) * 100)
    Show-Progress -PercentComplete $percentComplete
}

Write-Host "Registry cleanup completed. Removed entries logged to: $removedEntriesLog" -ForegroundColor Green
Log-Info "Registry cleanup completed" "SUC"

# Restart the Plug and Play service
try {
    Restart-Service -Name PlugPlay -Force
    Log-Info "PlugPlay service restarted successfully" "SUC"
} catch {
    Log-Info "Failed to restart PlugPlay service: $_" "ERR"
}

# Get all connected USB devices, including HID devices, but excluding mice
$usbDevices = Get-PnpDevice | Where-Object { ($_.Class -eq "USB" -or $_.Class -eq "HIDClass") -and $_.Status -eq "OK" } | Sort-Object -Property InstanceId -Unique

foreach ($device in $usbDevices) {
    Clear-Host
    Write-Host "`n`n`n`n`n`n`n"  # Add 7 blank lines to move content down
    Write-Host "Processing device: $($device.FriendlyName)" -ForegroundColor Cyan
    Write-Host "Use this device normally now. If it stops responding, press 'Y' immediately." -ForegroundColor Yellow
    Write-Host "Did the device stop working? Y for Yes and N for No (3 seconds to respond)" -ForegroundColor Yellow
    
    $response = $null
    $timeout = New-TimeSpan -Seconds 3
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    while ($stopwatch.Elapsed -lt $timeout -and $response -notin @("Y", "N")) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq "Y" -or $key.Key -eq "N") {
                $response = $key.KeyChar.ToString().ToUpper()
                Write-Host $response
            }
        }
        Start-Sleep -Milliseconds 50
    }

    if ($response -eq "N") {
        Write-Host "Device is working fine. Moving to next device." -ForegroundColor Green
        Log-Info "User indicated device is working: $($device.FriendlyName)" "SUC"
        continue
    }

    if ($response -eq $null) {
        Write-Host "No response received. Attempting to reset device as a precaution." -ForegroundColor Yellow
        Log-Info "No user response. Attempting reset: $($device.FriendlyName)" "SUC"
    }

    $resetMethods = @(
        { Disable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false -ErrorAction SilentlyContinue },
        { & devcon disable "$($device.InstanceId)" 2>$null },
        { & pnputil /disable-device "$($device.InstanceId)" 2>$null }
    )

    $deviceDisabled = $false
    foreach ($method in $resetMethods) {
        try {
            Show-WorkingMessage -Duration 3
            & $method
            $deviceDisabled = $true
            Log-Info "Successfully disabled device: $($device.FriendlyName)" "SUC"
            break
        }
        catch {
            Log-Info "Failed to disable device $($device.FriendlyName): $_" "ERR"
        }
    }

    if (-not $deviceDisabled) {
        Write-Host "Failed to disable device. Moving to next device..." -ForegroundColor Red
        Log-Info "Failed to disable device: $($device.FriendlyName)" "ERR"
        continue
    }

    Show-WorkingMessage -Duration 5

    $enableMethods = @(
        { Enable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false -ErrorAction SilentlyContinue },
        { & devcon enable "$($device.InstanceId)" 2>$null },
        { & pnputil /enable-device "$($device.InstanceId)" 2>$null }
    )

    $deviceEnabled = $false
    foreach ($method in $enableMethods) {
        try {
            Show-WorkingMessage -Duration 3
            & $method
            $deviceEnabled = $true
            Log-Info "Successfully enabled device: $($device.FriendlyName)" "SUC"
            break
        }
        catch {
            Log-Info "Failed to enable device $($device.FriendlyName): $_" "ERR"
        }
    }

    if (-not $deviceEnabled) {
        Write-Host "Failed to enable device. Please check the device manually." -ForegroundColor Red
        Log-Info "Failed to enable device: $($device.FriendlyName)" "ERR"
    }

    $deviceInfo = @"
Device Reset Attempt:
FriendlyName: $($device.FriendlyName)
InstanceId: $($device.InstanceId)
DeviceId: $($device.DeviceId)
Class: $($device.Class)
Service: $($device.Service)
Manufacturer: $($device.Manufacturer)
Driver: $($device.Driver)
Status: $($device.Status)
ProblemCode: $($device.ProblemCode)
ConfigManagerErrorCode: $($device.ConfigManagerErrorCode)
--------------------------
"@
    Add-Content -Path $logFile -Value $deviceInfo

    Write-Host "Device reset attempt completed for: $($device.FriendlyName)" -ForegroundColor Green
    Start-Sleep -Seconds 2
}

Write-Host "`n`n`n`n`n`n`n"  # Add 7 blank lines to move content down
Write-Host "USB device reset process completed. Check the log file for details." -ForegroundColor Cyan
Write-Host "Log file is located at: $logFile" -ForegroundColor Yellow
Write-Host "Please provide this log file to your IT support for further diagnosis if issues persist." -ForegroundColor Yellow
