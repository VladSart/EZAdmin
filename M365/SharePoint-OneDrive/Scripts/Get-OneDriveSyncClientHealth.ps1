<#
.SYNOPSIS
    Diagnoses OneDrive / SharePoint sync client (ODC) health on the local Windows endpoint.

.DESCRIPTION
    Companion script to M365/SharePoint-OneDrive/Sync-Issues-A.md and -B.md. Runs the runbook's
    Validation Steps in a single pass: OneDrive process state, Entra ID join / PRT state (via
    dsregcmd — the silent WAM auth backbone that OneDrive depends on), sync account binding
    (detects the multiple-Business-account conflict pattern), recent OneDrive event log errors,
    path-length compliance (>256 chars silently fails to sync), and Known Folder Move (KFM)
    registry/tenant-GUID alignment.

    This script is read-only. It does not reset the sync client, re-authenticate the account, or
    change registry policy — see the runbook's Remediation Playbooks (Fix 1-5) for those actions.
    Must be run as the affected user (not SYSTEM/admin), since OneDrive state lives under HKCU and
    %LocalAppData%.

.PARAMETER PathLengthWarningThreshold
    File path length (characters) above which a warning is raised. Default: 256 (the documented
    SharePoint/OneDrive sync ceiling).

.PARAMETER SkipPathScan
    Skip the recursive path-length scan of the sync folder. Useful on very large sync roots where
    the recursive scan would be slow; all other checks still run.

.PARAMETER OutputPath
    Folder to write the CSV report to. Default: $env:TEMP.

.EXAMPLE
    .\Get-OneDriveSyncClientHealth.ps1
    Runs a full local OneDrive sync health check as the current user.

.EXAMPLE
    .\Get-OneDriveSyncClientHealth.ps1 -SkipPathScan -OutputPath C:\Temp\Evidence
    Skips the potentially slow recursive path-length scan and writes output to a custom folder.

.NOTES
    Requires: Run as the affected end user (not admin/SYSTEM) — OneDrive state is per-user (HKCU).
    Safe: Read-only. No sync reset, no re-authentication, no registry changes.
    Companion runbooks: M365/SharePoint-OneDrive/Sync-Issues-A.md (deep dive),
                         M365/SharePoint-OneDrive/Sync-Issues-B.md (hotfix triage).
#>
[CmdletBinding()]
param(
    [int]$PathLengthWarningThreshold = 256,
    [switch]$SkipPathScan,
    [string]$OutputPath = $env:TEMP
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$isSystem = ([Security.Principal.WindowsIdentity]::GetCurrent()).IsSystem
if ($isSystem) {
    Write-Status "Running as SYSTEM — OneDrive state is per-user (HKCU/%LocalAppData%). Re-run as the affected logged-in user for meaningful results." "WARN"
}

$findings = New-Object System.Collections.Generic.List[string]
$report = [ordered]@{ CheckedAt = (Get-Date); User = $env:USERNAME }

# ---- Detect: OneDrive process ----
Write-Status "Checking OneDrive process state..." "INFO"

$odProcess = Get-Process -Name OneDrive -ErrorAction SilentlyContinue
$report["OneDrive_Running"] = [bool]$odProcess
if ($odProcess) {
    $report["OneDrive_CPU"] = $odProcess[0].CPU
    Write-Status "OneDrive.exe is running (PID $($odProcess[0].Id))." "OK"
} else {
    Write-Status "OneDrive.exe is NOT running. Start with: Start-Process `"`$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe`"" "ERROR"
    $findings.Add("ONEDRIVE_NOT_RUNNING")
}

$odExePath = "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe"
if (Test-Path $odExePath) {
    $version = (Get-Item $odExePath).VersionInfo.ProductVersion
    $report["OneDrive_Version"] = $version
    Write-Status "OneDrive client version: $version" "INFO"
} else {
    Write-Status "OneDrive.exe not found at expected path: $odExePath" "WARN"
    $findings.Add("ONEDRIVE_EXE_NOT_FOUND")
}

# ---- Detect: Entra ID join / PRT state (silent WAM auth backbone) ----
Write-Status "Checking Entra ID join / PRT state via dsregcmd..." "INFO"

try {
    $dsregOutput = dsregcmd /status 2>&1
    $azureAdJoined = ($dsregOutput | Select-String "AzureAdJoined\s*:\s*YES")
    $workplaceJoined = ($dsregOutput | Select-String "WorkplaceJoined\s*:\s*YES")
    $prt = ($dsregOutput | Select-String "AzureAdPrt\s*:\s*YES")

    $report["AzureAdJoined_or_WorkplaceJoined"] = [bool]($azureAdJoined -or $workplaceJoined)
    $report["AzureAdPrt_Present"] = [bool]$prt

    if (-not ($azureAdJoined -or $workplaceJoined)) {
        Write-Status "Device is not Entra ID joined or workplace joined — OneDrive cannot silently authenticate a work/school account." "ERROR"
        $findings.Add("DEVICE_NOT_JOINED")
    } elseif (-not $prt) {
        Write-Status "Device is joined but has no Primary Refresh Token (PRT) — WAM cannot get a token silently. OneDrive will prompt for sign-in. Try: dsregcmd /refreshprt" "WARN"
        $findings.Add("NO_PRT")
    } else {
        Write-Status "Device is joined and has a valid PRT." "OK"
    }
} catch {
    Write-Status "dsregcmd /status failed: $($_.Exception.Message)" "ERROR"
    $findings.Add("DSREGCMD_FAILED")
}

# ---- Detect: sync account binding (multiple-account conflict pattern) ----
Write-Status "Checking sync account binding..." "INFO"

$settingsPath = "$env:LOCALAPPDATA\Microsoft\OneDrive\settings"
$accountFolders = @()
if (Test-Path $settingsPath) {
    $accountFolders = Get-ChildItem $settingsPath -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "Business*" }
    $report["Business_Account_Count"] = $accountFolders.Count

    if ($accountFolders.Count -gt 1) {
        Write-Status "$($accountFolders.Count) Business account folders found ($($accountFolders.Name -join ', ')) — multiple work/school accounts signed in can cause sync conflicts." "WARN"
        $findings.Add("MULTIPLE_BUSINESS_ACCOUNTS")
    } elseif ($accountFolders.Count -eq 1) {
        Write-Status "One Business account folder found ($($accountFolders.Name))." "OK"
    } else {
        Write-Status "No Business account folder found under $settingsPath — user may not be signed into a work/school account." "WARN"
        $findings.Add("NO_BUSINESS_ACCOUNT")
    }
} else {
    Write-Status "OneDrive settings path not found: $settingsPath" "WARN"
    $findings.Add("SETTINGS_PATH_NOT_FOUND")
}

# ---- Detect: recent OneDrive event log errors ----
Write-Status "Checking recent OneDrive event log entries..." "INFO"

try {
    $odEvents = Get-WinEvent -LogName "Microsoft-Windows-OneDrive*" -MaxEvents 50 -ErrorAction SilentlyContinue |
        Where-Object { $_.LevelDisplayName -in "Error", "Warning" }
    $report["Recent_ODC_ErrorWarning_Count"] = ($odEvents | Measure-Object).Count

    if ($odEvents) {
        Write-Status "$($odEvents.Count) Error/Warning event(s) found in the OneDrive event log — cross-reference error codes against Sync-Issues-A.md's Symptom -> Cause Map." "WARN"
        $findings.Add("ODC_EVENT_LOG_ERRORS")
    } else {
        Write-Status "No recent Error/Warning events in the OneDrive event log." "OK"
    }
} catch {
    Write-Status "Could not read OneDrive event log: $($_.Exception.Message)" "WARN"
}

# ---- Validate: path-length compliance ----
$syncRoot = $null
if ($accountFolders.Count -gt 0) {
    $firstAccount = $accountFolders[0].Name
    $syncRoot = (Get-ItemProperty "HKCU:\Software\Microsoft\OneDrive\Accounts\$firstAccount" -ErrorAction SilentlyContinue).UserFolder
}
$report["SyncRoot"] = $syncRoot

if ($syncRoot -and -not $SkipPathScan) {
    Write-Status "Scanning for paths exceeding $PathLengthWarningThreshold characters under '$syncRoot'..." "INFO"
    try {
        $longPaths = Get-ChildItem -Path $syncRoot -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName.Length -gt $PathLengthWarningThreshold }
        $report["LongPath_Count"] = ($longPaths | Measure-Object).Count

        if ($longPaths) {
            Write-Status "$($longPaths.Count) path(s) exceed $PathLengthWarningThreshold characters — these will fail to sync unless Long Path Support is enabled." "WARN"
            $findings.Add("LONG_PATHS_FOUND")
        } else {
            Write-Status "No paths exceed the $PathLengthWarningThreshold character threshold." "OK"
        }
    } catch {
        Write-Status "Path length scan failed: $($_.Exception.Message)" "WARN"
    }
} elseif ($SkipPathScan) {
    Write-Status "Path-length scan skipped (-SkipPathScan)." "INFO"
} else {
    Write-Status "No sync root resolved — skipping path-length scan." "INFO"
}

$longPathSupport = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "LongPathsEnabled" -ErrorAction SilentlyContinue).LongPathsEnabled
$report["LongPathsEnabled_SystemWide"] = $longPathSupport
if ($longPathSupport -ne 1) {
    Write-Status "System-wide Long Path Support is not enabled (LongPathsEnabled != 1)." "INFO"
}

# ---- Validate: KFM registry state ----
Write-Status "Checking Known Folder Move (KFM) registry state..." "INFO"

$kfmOptIn = (Get-ItemProperty "HKCU:\Software\Microsoft\OneDrive" -Name "KFMSilentOptIn" -ErrorAction SilentlyContinue).KFMSilentOptIn
$report["KFM_TenantGuidPolicy"] = $kfmOptIn

if ($kfmOptIn) {
    $shellFolders = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction SilentlyContinue
    $desktopRedirected   = $syncRoot -and $shellFolders.Desktop -like "$syncRoot*"
    $documentsRedirected = $syncRoot -and $shellFolders.Personal -like "$syncRoot*"

    $report["KFM_Desktop_Redirected"]   = [bool]$desktopRedirected
    $report["KFM_Documents_Redirected"] = [bool]$documentsRedirected

    if ($syncRoot -and (-not $desktopRedirected -or -not $documentsRedirected)) {
        Write-Status "KFM policy is present (tenant GUID: $kfmOptIn) but Desktop/Documents are not fully redirected to the OneDrive sync root. Check tenant GUID match and whether the user previously opted out." "WARN"
        $findings.Add("KFM_NOT_APPLIED")
    } elseif ($syncRoot) {
        Write-Status "KFM is applied — Desktop and Documents redirected to the OneDrive sync root." "OK"
    }
} else {
    Write-Status "No KFM policy (KFMSilentOptIn) found — KFM is not configured for this user, or policy has not yet applied." "INFO"
}

# ---- Report ----
Write-Status "Writing report..." "INFO"

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$csvPath = Join-Path $OutputPath "OneDriveSyncHealth-$timestamp.csv"

[PSCustomObject]$report | Export-Csv -Path $csvPath -NoTypeInformation -Force
Write-Status "Report written: $csvPath" "OK"

Write-Host ""
Write-Status "=== SUMMARY ===" "INFO"
if ($findings.Count -eq 0) {
    Write-Status "No issues flagged. OneDrive sync appears healthy." "OK"
} else {
    Write-Status "Flags raised: $($findings -join ', ')" "WARN"
}
Write-Host ""

[PSCustomObject]$report | Format-List
