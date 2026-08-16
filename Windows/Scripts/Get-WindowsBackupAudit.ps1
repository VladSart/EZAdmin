<#
.SYNOPSIS
    Collects Windows Backup for Organizations (Windows settings backup and restore) readiness —
    join-type/build eligibility, backup policy state, the five silent companion-policy blockers,
    and restore policy configuration — for triage or escalation.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/WindowsBackup-B.md and WindowsBackup-A.md.
    Runs LOCALLY on the target device (this is a client-side feature with no fleet-wide Graph/Intune
    read surface for per-device backup/restore state) and gathers everything the runbooks' triage
    and diagnosis steps ask for:
    - Device join type (Entra joined / hybrid joined / registered-only) via dsregcmd
    - OS build, for manual cross-reference against the capability-specific minimum in WindowsBackup-A.md
      (backup / OOBE restore / first-sign-in restore each have a DIFFERENT minimum — this script
      reports the build only; the runbook table holds the authoritative current thresholds since
      they shift with cumulative update baselines)
    - Backup policy (SettingSync) applied state
    - ALL FIVE companion policies (EnableActivityFeed, PublishUserActivities, UploadUserActivities,
      EnableCDP, AllowConnectedDevices) with an explicit flag if ANY is set to Disabled — this is the
      single most common silent-failure root cause per the runbook
    - Post-enrollment restore policy (Settings Catalog "Enable Windows Restore") trace
      NOTE: the OOBE-restore ENROLLMENT policy is a tenant-wide Intune portal setting with NO local
      registry trace on an already-enrolled device — this script cannot detect it; check the Intune
      admin center directly (Devices > Enrollment > Windows Backup and Restore)
    - Recent MDM policy-application events filtered for Backup/SettingSync references

    Produces a console summary with pass/fail per check and exports full detail to CSV,
    so the output can be pasted directly into the runbook's Escalation Evidence template.

    Does NOT cover:
    - Fixing any detected issue (that's WindowsBackup-B.md Fix 1-9 / WindowsBackup-A.md Playbooks 1-3 —
      this script only detects)
    - Fleet-wide auditing across many devices — this is a single-device diagnostic script; there is no
      documented Graph/Intune API surface for per-device Windows Backup eligibility/state at scale
    - Graph-side backup DATA presence (whether the user actually has a backup profile) — that's a
      Graph `windowsSetting` GET call against the user object, not a device-side check; see
      WindowsBackup-A.md Playbook 3 for the Graph query
    - OneDrive Known Folder Move / file-level backup — a completely separate feature and script,
      not covered here at all

.PARAMETER ExportPath
    Path for CSV export. Default: .\WindowsBackupAudit-<timestamp>.csv

.EXAMPLE
    .\Get-WindowsBackupAudit.ps1
    Audits the local device's Windows Backup for Organizations readiness.

.NOTES
    Requires: Windows PowerShell 5.1+ or PowerShell 7+; local admin not strictly required for the
              read-only registry/dsregcmd/event log checks, but recommended for full event log access
    Run-as: Local session on the target device (this is not a remote-capable fleet audit script)
    Safe: Fully read-only. No policy, registry, or backup/restore state changes.
#>

[CmdletBinding()]
param(
    [string]$ExportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

#region ─── Preflight ──────────────────────────────────────────────────────────
$deviceName = $env:COMPUTERNAME
Write-Status "Get-WindowsBackupAudit — $deviceName — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\WindowsBackupAudit-$timestamp.csv"
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param([string]$Check, [string]$Status, [string]$Detail)
    $results.Add([PSCustomObject]@{
        Device    = $deviceName
        Check     = $Check
        Status    = $Status
        Detail    = $Detail
        CheckedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    })
    Write-Status "$Check — $Detail" $Status
}
#endregion

#region ─── 1. Join type ────────────────────────────────────────────────────────
try {
    $dsreg = dsregcmd /status 2>&1
    $azureAdJoined = ($dsreg | Select-String "AzureAdJoined\s*:\s*YES") -ne $null
    $domainJoined  = ($dsreg | Select-String "DomainJoined\s*:\s*YES") -ne $null
    $workplaceJoined = ($dsreg | Select-String "WorkplaceJoined\s*:\s*YES") -ne $null

    if ($azureAdJoined -and $domainJoined) {
        Add-Result "JoinType" "OK" "Microsoft Entra hybrid joined — eligible for Backup and first-sign-in restore; NOT eligible for OOBE restore (Entra-joined-only requirement)"
    } elseif ($azureAdJoined) {
        Add-Result "JoinType" "OK" "Microsoft Entra joined — eligible for Backup, OOBE restore, and first-sign-in restore"
    } elseif ($workplaceJoined) {
        Add-Result "JoinType" "ERROR" "Entra REGISTERED (Workplace Joined) only — NOT eligible for Windows Backup for Organizations at all. Requires Entra joined or Entra hybrid joined"
    } else {
        Add-Result "JoinType" "ERROR" "No Entra join state detected (not Azure AD joined, hybrid joined, or workplace joined) — device is not eligible for this feature"
    }
} catch {
    Add-Result "JoinType" "WARN" "Could not run dsregcmd /status: $_"
}
#endregion

#region ─── 2. OS build ─────────────────────────────────────────────────────────
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $buildInfo = "Caption=$($os.Caption), Version=$($os.Version), BuildNumber=$($os.BuildNumber)"
    Add-Result "OSBuild" "INFO" "$buildInfo — cross-reference against WindowsBackup-A.md's per-capability minimum build table (backup / OOBE restore / first-sign-in restore each have a DIFFERENT threshold that shifts with cumulative updates)"
} catch {
    Add-Result "OSBuild" "WARN" "Could not read OS build via CIM: $_"
}
#endregion

#region ─── 3. Backup policy state ──────────────────────────────────────────────
try {
    $backupPolicy = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\SettingSync" -ErrorAction SilentlyContinue
    if ($null -eq $backupPolicy) {
        Add-Result "BackupPolicy" "WARN" "No SettingSync policy key found — Windows Backup policy has not been applied to this device via GPO/CSP registry path (may still be Not Configured by design, or Windows 11 26H2's new default-on baseline may be governing this device instead — verify build/version)"
    } else {
        Add-Result "BackupPolicy" "OK" "SettingSync policy key present — inspect exported CSV for full value detail"
    }
} catch {
    Add-Result "BackupPolicy" "WARN" "Could not read backup policy registry key: $_"
}
#endregion

#region ─── 4. The five companion policies — silent backup blockers ────────────
$companionChecks = @(
    @{ Name = "EnableActivityFeed";    Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" }
    @{ Name = "PublishUserActivities"; Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" }
    @{ Name = "UploadUserActivities";  Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" }
    @{ Name = "EnableCdp";             Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GroupPolicy" }
    @{ Name = "AllowConnectedDevices"; Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Connectivity" }
)

$anyDisabled = $false
foreach ($chk in $companionChecks) {
    try {
        $val = (Get-ItemProperty -Path $chk.Path -Name $chk.Name -ErrorAction SilentlyContinue).$($chk.Name)
        if ($null -eq $val) {
            Add-Result "CompanionPolicy-$($chk.Name)" "INFO" "Not Configured (no explicit value) — fine, does not block backup"
        } elseif ($val -eq 0) {
            Add-Result "CompanionPolicy-$($chk.Name)" "ERROR" "DISABLED — this SILENTLY blocks Windows Backup from ever running, regardless of the main backup policy's own state. See WindowsBackup-B.md Fix 3"
            $anyDisabled = $true
        } else {
            Add-Result "CompanionPolicy-$($chk.Name)" "OK" "Enabled (value=$val)"
        }
    } catch {
        Add-Result "CompanionPolicy-$($chk.Name)" "WARN" "Could not read: $_"
    }
}

if ($anyDisabled) {
    Add-Result "CompanionPolicySummary" "ERROR" "At least one of the five companion policies is Disabled — this is the most likely root cause if backup policy shows Enabled but no backup has ever run"
} else {
    Add-Result "CompanionPolicySummary" "OK" "No companion policy is explicitly Disabled"
}
#endregion

#region ─── 5. Restore policy trace (post-enrollment path only) ────────────────
try {
    $restorePolicy = Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Backup" -ErrorAction SilentlyContinue
    if ($null -eq $restorePolicy) {
        Add-Result "RestorePolicy-PostEnrollment" "INFO" "No post-enrollment restore policy ('Enable Windows Restore') registry trace found. REMINDER: the SEPARATE OOBE-restore enrollment policy is a tenant-wide Intune portal setting (Devices > Enrollment > Windows Backup and Restore) with NO local trace on an already-enrolled device — check the Intune admin center directly, this script cannot detect it"
    } else {
        Add-Result "RestorePolicy-PostEnrollment" "OK" "Post-enrollment restore policy key present — inspect exported CSV for full value detail. Enables first-sign-in restore specifically, NOT OOBE restore (that's the separate enrollment-time tenant policy)"
    }
} catch {
    Add-Result "RestorePolicy-PostEnrollment" "WARN" "Could not read restore policy registry key: $_"
}
#endregion

#region ─── 6. Recent MDM policy-application events ────────────────────────────
try {
    $events = Get-WinEvent -LogName "Microsoft-Windows-DeviceManagement-Enterprise-Diagnostic-Provider/Admin" -MaxEvents 500 -ErrorAction Stop |
        Where-Object { $_.Message -match "Backup|SettingSync" }
    if ($events -and $events.Count -gt 0) {
        Add-Result "MDMBackupEvents" "INFO" "$($events.Count) MDM policy event(s) referencing Backup/SettingSync in the recent log window — see exported CSV for detail"
    } else {
        Add-Result "MDMBackupEvents" "INFO" "No recent MDM policy events referencing Backup/SettingSync found in the sampled window"
    }
} catch {
    $events = @()
    Add-Result "MDMBackupEvents" "WARN" "Could not read MDM diagnostic event log (may require elevation): $_"
}
#endregion

#region ─── Summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── Windows Backup for Organizations Readiness Summary ── ($deviceName)" -ForegroundColor Cyan
$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount  = ($results | Where-Object { $_.Status -eq "WARN" }).Count

Write-Host "  Checks run : $($results.Count)"
Write-Host "  Errors     : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Warnings   : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })

if ($errorCount -eq 0 -and $warnCount -eq 0) {
    Write-Host "  Overall: Device looks ready for Windows Backup for Organizations." -ForegroundColor Green
} else {
    Write-Host "  Overall: Issues found — see WindowsBackup-B.md fix paths matching the failed checks above." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  REMINDER: This device-side script cannot see (1) whether the tenant-wide OOBE restore" -ForegroundColor DarkGray
Write-Host "  enrollment policy is enabled, or (2) whether Graph backup data actually exists for the" -ForegroundColor DarkGray
Write-Host "  signed-in user. Check the Intune admin center and Graph 'windowsSetting' API separately." -ForegroundColor DarkGray
Write-Host ""
#endregion

#region ─── Export ──────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
if ($events -and $events.Count -gt 0) {
    $eventsExportPath = $ExportPath -replace '\.csv$', '-MDMEvents.csv'
    $events | Select-Object TimeCreated, Id, Message | Export-Csv -Path $eventsExportPath -NoTypeInformation -Encoding UTF8
    Write-Status "MDM events exported → $eventsExportPath" "OK"
}
Write-Status "Exported → $ExportPath" "OK"
Write-Status "Done — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
