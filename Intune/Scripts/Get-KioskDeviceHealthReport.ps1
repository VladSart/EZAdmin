<#
.SYNOPSIS
    Collects a full local health snapshot of an Intune-managed Windows Kiosk /
    Assigned Access device — the on-device equivalent of the Evidence Pack in
    Kiosk-A.md, runnable standalone for quick triage.

.DESCRIPTION
    Companion diagnostic for Intune/Troubleshooting/Kiosk-B.md and Kiosk-A.md.

    Kiosk failures are almost always diagnosed locally, not via Graph — the
    AssignedAccess CSP writes its state to the registry and event log on the
    device itself (Kiosk-A.md Validation Steps 3, 6, 7; Kiosk-B.md Triage).
    This script automates that whole checklist in one pass instead of running
    six separate commands by hand:

      1. Windows edition / SKU        — Multi-App and Shell Launcher require
                                         Enterprise/Education (Kiosk-A.md Step 1)
      2. MDM enrollment state          — dsregcmd /status (Kiosk-B.md Triage #2)
      3. AssignedAccess CSP registry   — is a config actually present? (Step 3)
      4. Kiosk account state           — exists, enabled, password not expired
                                         (Step 4)
      5. AssignedAccess event log      — Event ID 31000 (success) vs 31001/31002
                                         (failure) in the last 20 events (Step 6)
      6. Winlogon auto-logon keys      — AutoAdminLogon / DefaultUserName (Step 7)
      7. Shell Launcher feature + WMI  — for non-UWP kiosk types (Phase 4)

    Each check prints a clear GOOD/BAD verdict inline (matching each runbook's
    "Expected good output" / "Bad output" pairs) and the full data is also
    exported to CSV for attaching to an escalation.

.PARAMETER KioskAccountName
    The local (or UPN, for AAD accounts) username configured for kiosk auto-logon.
    Optional — if omitted, account-specific checks are skipped.

.PARAMETER OutputPath
    Folder to write the CSV/evidence files to. Default: C:\Temp.

.EXAMPLE
    .\Get-KioskDeviceHealthReport.ps1 -KioskAccountName "KioskUser01"
    Runs the full local health check including kiosk account validation.

.EXAMPLE
    .\Get-KioskDeviceHealthReport.ps1
    Runs all device-level checks, skipping the account-specific step.

.NOTES
    Requires: Run locally on the kiosk device (or via Remote Help / PS remoting),
              as Administrator for full registry and event log access.
    Safe/Unsafe: Fully read-only. Makes no configuration changes.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$KioskAccountName,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "C:\Temp"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$results = [ordered]@{}

Write-Status "=== Intune Kiosk / Assigned Access — Local Health Report ===" "INFO"
Write-Host ""

# ---------------------------------------------------------------------------
# 1. Windows edition / SKU
# ---------------------------------------------------------------------------
Write-Status "1. Windows edition check..." "INFO"
$os = Get-WmiObject Win32_OperatingSystem
$results["OSCaption"] = $os.Caption
$results["OSSku"] = $os.OperatingSystemSKU
if ($os.Caption -match "Enterprise|Education") {
    Write-Status "   $($os.Caption) — supports Multi-App Kiosk and Shell Launcher." "OK"
}
else {
    Write-Status "   $($os.Caption) — Pro/Home only supports Single-App UWP kiosk. Multi-App and Shell Launcher WILL FAIL on this SKU (Kiosk-A.md Step 1)." "WARN"
}

# ---------------------------------------------------------------------------
# 2. MDM enrollment state
# ---------------------------------------------------------------------------
Write-Status "2. MDM enrollment state..." "INFO"
$dsreg = dsregcmd /status
$mdmLine = $dsreg | Select-String "MdmEnrolled"
$aadLine = $dsreg | Select-String "AzureAdJoined"
$results["MdmEnrolled"] = ($mdmLine -replace ".*:\s*", "").Trim()
$results["AzureAdJoined"] = ($aadLine -replace ".*:\s*", "").Trim()
if ($results["MdmEnrolled"] -eq "YES" -and $results["AzureAdJoined"] -eq "YES") {
    Write-Status "   MdmEnrolled: YES, AzureAdJoined: YES." "OK"
}
else {
    Write-Status "   MdmEnrolled=$($results['MdmEnrolled']) AzureAdJoined=$($results['AzureAdJoined']) — fix enrollment before troubleshooting kiosk config further." "ERROR"
}

# ---------------------------------------------------------------------------
# 3. AssignedAccess CSP registry state
# ---------------------------------------------------------------------------
Write-Status "3. AssignedAccess CSP registry state..." "INFO"
$cfg = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\AssignedAccess" -Name "Configuration" -ErrorAction SilentlyContinue
if ($cfg) {
    Write-Status "   Configuration XML present in registry." "OK"
    $results["AssignedAccessConfigPresent"] = $true
    $cfg.Configuration | Out-File (Join-Path $OutputPath "AssignedAccessConfig-$timestamp.xml")
}
else {
    Write-Status "   No configuration present — policy has not reached the CSP. Check Intune sync / assignment (Kiosk-B.md Fix 1)." "ERROR"
    $results["AssignedAccessConfigPresent"] = $false
}

# ---------------------------------------------------------------------------
# 4. Kiosk account state
# ---------------------------------------------------------------------------
if ($KioskAccountName) {
    Write-Status "4. Kiosk account state ($KioskAccountName)..." "INFO"
    $acct = Get-LocalUser -Name $KioskAccountName -ErrorAction SilentlyContinue
    if ($acct) {
        $results["KioskAccountEnabled"] = $acct.Enabled
        $results["KioskAccountPasswordExpires"] = $acct.PasswordExpires
        if ($acct.Enabled) {
            Write-Status "   Account exists and is Enabled." "OK"
        }
        else {
            Write-Status "   Account exists but is DISABLED (Kiosk-B.md Fix 2)." "ERROR"
        }
        if ($acct.PasswordExpires) {
            Write-Status "   PasswordExpires is set ($($acct.PasswordExpires)) — kiosk accounts should use PasswordNeverExpires (Kiosk-B.md Learning Pointers)." "WARN"
        }
    }
    else {
        Write-Status "   Account '$KioskAccountName' NOT FOUND locally — if this is an AAD account, check sign-in state in Entra admin center instead (Kiosk-B.md Fix 2)." "ERROR"
        $results["KioskAccountEnabled"] = "NOT FOUND (local)"
    }
}
else {
    Write-Status "4. Kiosk account state — skipped (-KioskAccountName not supplied)." "INFO"
}

# ---------------------------------------------------------------------------
# 5. AssignedAccess event log
# ---------------------------------------------------------------------------
Write-Status "5. AssignedAccess event log (last 20 events)..." "INFO"
try {
    $events = Get-WinEvent -LogName "Microsoft-Windows-AssignedAccess/Admin" -MaxEvents 20 -ErrorAction Stop
    $success = $events | Where-Object Id -eq 31000 | Select-Object -First 1
    $failure = $events | Where-Object { $_.Id -in @(31001, 31002) }
    $events | Select-Object TimeCreated, Id, Message | Export-Csv (Join-Path $OutputPath "AssignedAccessEvents-$timestamp.csv") -NoTypeInformation

    if ($success) {
        Write-Status "   Event ID 31000 (config applied) found at $($success.TimeCreated)." "OK"
    }
    if ($failure) {
        Write-Status "   $($failure.Count) failure event(s) (31001/31002) found — decode the error code in the message per Kiosk-A.md Phase 2." "ERROR"
    }
    if (-not $success -and -not $failure) {
        Write-Status "   No 31000/31001/31002 events in the last 20 — config may never have been pushed, or log has rolled over (default size is only 1MB per Kiosk-A.md Learning Pointers)." "WARN"
    }
}
catch {
    Write-Status "   Could not read AssignedAccess event log: $($_.Exception.Message)" "WARN"
}

# ---------------------------------------------------------------------------
# 6. Winlogon auto-logon keys
# ---------------------------------------------------------------------------
Write-Status "6. Winlogon auto-logon keys..." "INFO"
$wl = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -ErrorAction SilentlyContinue
$results["AutoAdminLogon"] = $wl.AutoAdminLogon
$results["DefaultUserName"] = $wl.DefaultUserName
if ($wl.AutoAdminLogon -eq "1") {
    Write-Status "   AutoAdminLogon=1, DefaultUserName=$($wl.DefaultUserName)." "OK"
}
else {
    Write-Status "   AutoAdminLogon is not '1' — device will not auto-login to the kiosk account. If Credential Guard/VBS is enabled, this can silently block auto-logon configuration (Kiosk-A.md Learning Pointers)." "WARN"
}

# ---------------------------------------------------------------------------
# 7. Shell Launcher feature + WMI (non-UWP kiosk types only)
# ---------------------------------------------------------------------------
Write-Status "7. Shell Launcher feature state..." "INFO"
$feature = Get-WindowsOptionalFeature -Online -FeatureName "Client-EmbeddedShellLauncher" -ErrorAction SilentlyContinue
if ($feature) {
    $results["ShellLauncherFeatureState"] = $feature.State
    Write-Status "   Client-EmbeddedShellLauncher: $($feature.State)." $(if ($feature.State -eq "Enabled") { "OK" } else { "INFO" })
    try {
        $wmi = Get-WmiObject -Namespace "root\standardcimv2\embedded" -Class WESL_UserSetting -ErrorAction Stop
        $wmi | Select-Object Sid, Shell, Enabled | Export-Csv (Join-Path $OutputPath "ShellLauncherConfig-$timestamp.csv") -NoTypeInformation
        Write-Status "   Shell Launcher WMI config exported." "OK"
    }
    catch {
        Write-Status "   Shell Launcher WMI class not available — not configured, or this is a Single-App/Multi-App kiosk (not Shell Launcher)." "INFO"
    }
}
else {
    Write-Status "   Client-EmbeddedShellLauncher feature not found on this SKU (requires Enterprise/Education)." "INFO"
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$summaryFile = Join-Path $OutputPath "KioskHealthSummary-$timestamp.csv"
[PSCustomObject]$results | Export-Csv -Path $summaryFile -NoTypeInformation

Write-Host ""
Write-Status "Summary exported to: $summaryFile" "OK"
Write-Status "Full evidence files (XML config, event log, Shell Launcher config) written to: $OutputPath" "OK"
Write-Status "If everything above is GOOD but the kiosk still doesn't launch the app, move to Kiosk-A.md Phase 3 (app provisioning/context) — that's the next most common failure layer." "INFO"
