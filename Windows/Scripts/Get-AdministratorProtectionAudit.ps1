<#
.SYNOPSIS
    Audits Windows 11 Administrator Protection eligibility, policy state, and elevation-model
    health on the local machine.

.DESCRIPTION
    Companion script to Windows/Troubleshooting/AdministratorProtection-B.md and -A.md.
    Runs in one pass everything the runbooks' triage and diagnosis steps ask for:
    - OS build eligibility (Windows 11 24H2/26100+) and KB5120998-or-later hotfix presence
    - UAC master switch (EnableLUA) — the most common silent blocker
    - Admin Approval Mode type as reported by gpresult (Legacy vs. Administrator protection)
    - Current user's token group membership (flags a still-classic split-token admin)
    - Shadow admin_<username> local account inventory
    - Recent System event log errors/warnings in the elevation-relevant window

    Produces a console summary with pass/fail/info per check and exports full detail to CSV,
    so the output can be pasted directly into the runbook's Escalation Evidence template.

    Does NOT cover:
    - Enabling, disabling, or reconfiguring Administrator Protection (that's -B.md Fix 1-6 /
      -A.md Playbooks 1-3)
    - Confirming the elevation-prompt-behavior setting (consent vs. credentials) via registry —
      no single reliable read was confirmed across builds as of this writing; the script flags
      this as a manual secpol.msc/gpresult verification item instead of guessing
    - Fleet-wide auditing — this is a single-machine diagnostic; Administrator Protection state
      is evaluated per-device/per-user, and there is no confirmed Graph/Intune API surface for
      shadow-account-level state at scale

.PARAMETER ExportPath
    Path for CSV export. Default: .\AdministratorProtectionAudit-<timestamp>.csv

.EXAMPLE
    .\Get-AdministratorProtectionAudit.ps1
    Audits local Administrator Protection eligibility, policy, and elevation-model state.

.EXAMPLE
    .\Get-AdministratorProtectionAudit.ps1 -ExportPath C:\Temp\ap-audit.csv
    Audits and exports results to a specific CSV path.

.NOTES
    Requires: Windows PowerShell 5.1+
    Run-as: Administrator recommended (HKLM policy reads and gpresult detail need elevation;
            token/group-membership check runs under the current user without elevation)
    Safe: Fully read-only. No policy changes, no account creation/deletion, no reboot triggered.
    Tested on: Windows 11 24H2 (build 26100) and later. Also safe to run on earlier builds or
               Windows 10 — will simply report ineligibility and skip downstream checks.
#>

[CmdletBinding()]
param(
    [string]$ExportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

if (-not $ExportPath) {
    $ExportPath = ".\AdministratorProtectionAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
}

$results = New-Object System.Collections.Generic.List[Object]

function Add-Result {
    param([string]$Check, [string]$Status, [string]$Detail)
    $results.Add([PSCustomObject]@{
        Check     = $Check
        Status    = $Status
        Detail    = $Detail
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    })
}

Write-Status "Starting Administrator Protection readiness and policy audit..." "INFO"
Write-Host ""

# ---------------------------------------------------------------------------
# 1. OS build eligibility and hotfix currency
# ---------------------------------------------------------------------------
Write-Status "Checking OS build eligibility..." "INFO"
$osVersion = [System.Environment]::OSVersion.Version
$buildNumber = $osVersion.Build
$eligible = $buildNumber -ge 26100

if ($eligible) {
    Add-Result -Check "OS Build Eligibility" -Status "OK" -Detail "Build $buildNumber (Windows 11 24H2 or later)"
    Write-Status "Build $buildNumber meets the 26100+ eligibility floor" "OK"
} else {
    Add-Result -Check "OS Build Eligibility" -Status "ERROR" -Detail "Build $buildNumber — below 26100, Administrator Protection is NOT available"
    Write-Status "Build $buildNumber is below the 26100 (24H2) eligibility floor — stopping downstream checks" "ERROR"
}

try {
    $kb = Get-HotFix -ErrorAction Stop | Where-Object { $_.HotFixID -eq "KB5120998" }
    if ($kb) {
        Add-Result -Check "KB5120998" -Status "OK" -Detail "Installed on $($kb.InstalledOn)"
        Write-Status "KB5120998 (broader Administrator Protection rollout) is installed" "OK"
    } else {
        Add-Result -Check "KB5120998" -Status "INFO" -Detail "Not found — may be superseded by a later cumulative update, or not yet installed"
        Write-Status "KB5120998 not found by exact ID — check for a later cumulative update if AP behavior seems inconsistent with documentation" "INFO"
    }
} catch {
    Add-Result -Check "KB5120998" -Status "WARN" -Detail "Could not query hotfix list: $($_.Exception.Message)"
}
Write-Host ""

if (-not $eligible) {
    Write-Status "Device is not eligible for Administrator Protection. Skipping remaining checks." "ERROR"
    $results | Export-Csv -Path $ExportPath -NoTypeInformation
    Write-Status "Results exported to: $ExportPath" "OK"
    return
}

# ---------------------------------------------------------------------------
# 2. UAC master switch (EnableLUA)
# ---------------------------------------------------------------------------
Write-Status "Checking UAC master switch (EnableLUA)..." "INFO"
try {
    $uac = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -ErrorAction Stop
    if ($uac.EnableLUA -eq 1) {
        Add-Result -Check "EnableLUA" -Status "OK" -Detail "1 — UAC enabled, Administrator Protection can function"
        Write-Status "EnableLUA = 1 — UAC is on" "OK"
    } else {
        Add-Result -Check "EnableLUA" -Status "ERROR" -Detail "0 or missing — UAC is OFF, Administrator Protection CANNOT function regardless of any AP-specific policy"
        Write-Status "EnableLUA is 0 or missing — UAC is disabled, this blocks Administrator Protection entirely" "ERROR"
    }
} catch {
    Add-Result -Check "EnableLUA" -Status "WARN" -Detail "Could not read UAC policy key: $($_.Exception.Message)"
    Write-Status "Could not read UAC policy key — re-run elevated" "WARN"
}
Write-Host ""

# ---------------------------------------------------------------------------
# 3. Admin Approval Mode type (via gpresult)
# ---------------------------------------------------------------------------
Write-Status "Checking applied Admin Approval Mode type via gpresult..." "INFO"
try {
    $gpResult = gpresult /r 2>&1 | Out-String
    if ($gpResult -match "Administrator protection") {
        Add-Result -Check "Admin Approval Mode Type" -Status "OK" -Detail "gpresult output references 'Administrator protection' — policy appears applied. Verify exact wording via secpol.msc for certainty."
        Write-Status "gpresult indicates an Administrator Protection-related setting is applied — verify exact state via secpol.msc" "OK"
    } else {
        Add-Result -Check "Admin Approval Mode Type" -Status "INFO" -Detail "No 'Administrator protection' reference found in gpresult output — likely still Legacy Admin Approval Mode, or policy not yet applied/synced"
        Write-Status "No Administrator Protection reference found in gpresult — check secpol.msc directly or confirm policy assignment/sync" "INFO"
    }
} catch {
    Add-Result -Check "Admin Approval Mode Type" -Status "WARN" -Detail "gpresult failed: $($_.Exception.Message)"
}
Write-Status "Manual verification: secpol.msc > Local Policies > Security Options > 'User Account Control: Configure type of Admin Approval Mode'" "INFO"
Write-Host ""

# ---------------------------------------------------------------------------
# 4. Current user token group membership (split-token admin flag)
# ---------------------------------------------------------------------------
Write-Status "Checking current user's token for classic split-token admin membership..." "INFO"
try {
    $whoamiGroups = whoami /groups 2>&1 | Out-String
    if ($whoamiGroups -match "S-1-5-32-544") {
        Add-Result -Check "Token Group Membership" -Status "WARN" -Detail "S-1-5-32-544 (local Administrators) present on current token — this user is still operating under a classic split-token admin model for this session, or is not the account Administrator Protection is intended to cover"
        Write-Status "Local Administrators SID present on current token — classic split-token behavior detected for this session" "WARN"
    } else {
        Add-Result -Check "Token Group Membership" -Status "OK" -Detail "No local Administrators SID found Enabled on current token — consistent with the standard-user-at-rest Administrator Protection model"
        Write-Status "No local Administrators SID on current token — consistent with Administrator Protection's standard-user-at-rest model" "OK"
    }
} catch {
    Add-Result -Check "Token Group Membership" -Status "WARN" -Detail "whoami /groups failed: $($_.Exception.Message)"
}
Write-Host ""

# ---------------------------------------------------------------------------
# 5. Shadow admin_<username> account inventory
# ---------------------------------------------------------------------------
Write-Status "Checking for shadow admin_<username> local account(s)..." "INFO"
try {
    $shadowAccounts = Get-LocalUser -ErrorAction Stop | Where-Object { $_.Name -like "admin_*" }
    if ($shadowAccounts) {
        foreach ($acct in $shadowAccounts) {
            Add-Result -Check "Shadow account: $($acct.Name)" -Status "INFO" -Detail "Enabled=$($acct.Enabled), LastLogon=$($acct.LastLogon)"
        }
        Write-Status "Found $($shadowAccounts.Count) shadow admin account(s) — see CSV for detail" "OK"
    } else {
        Add-Result -Check "Shadow admin accounts" -Status "INFO" -Detail "None found — either no elevation has been performed on this device yet under Administrator Protection, or AP is not enabled"
        Write-Status "No admin_<username> accounts found — normal if no elevation has occurred yet, or AP is not enabled" "INFO"
    }
} catch {
    Add-Result -Check "Shadow admin accounts" -Status "WARN" -Detail "Get-LocalUser failed: $($_.Exception.Message)"
}
Write-Host ""

# ---------------------------------------------------------------------------
# 6. Recent elevation-relevant System log errors/warnings
# ---------------------------------------------------------------------------
Write-Status "Checking recent System event log for elevation-relevant errors/warnings..." "INFO"
try {
    $recentEvents = Get-WinEvent -LogName System -MaxEvents 500 -ErrorAction Stop |
        Where-Object { $_.TimeCreated -gt (Get-Date).AddHours(-24) -and $_.LevelDisplayName -in "Error","Warning" }
    if ($recentEvents) {
        Add-Result -Check "Recent System log errors/warnings" -Status "INFO" -Detail "$($recentEvents.Count) event(s) in the last 24h — review manually for elevation/account-provisioning relevance, not all are AP-related"
        Write-Status "$($recentEvents.Count) System log error/warning event(s) in the last 24h — review CSV, not all will be Administrator Protection-related" "INFO"
    } else {
        Add-Result -Check "Recent System log errors/warnings" -Status "OK" -Detail "None in the last 24h"
        Write-Status "No System log errors/warnings in the last 24h" "OK"
    }
} catch {
    Add-Result -Check "Recent System log errors/warnings" -Status "WARN" -Detail "Get-WinEvent failed: $($_.Exception.Message)"
}
Write-Host ""

# ---------------------------------------------------------------------------
# Summary and export
# ---------------------------------------------------------------------------
$errorCount = ($results | Where-Object Status -eq "ERROR").Count
$warnCount  = ($results | Where-Object Status -eq "WARN").Count
$okCount    = ($results | Where-Object Status -eq "OK").Count

Write-Status "Audit complete: $okCount OK, $warnCount WARN, $errorCount ERROR" "INFO"

$results | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Results exported to: $ExportPath" "OK"

if ($errorCount -gt 0) {
    Write-Status "One or more checks indicate a blocking condition — see AdministratorProtection-B.md Common Fix Paths." "ERROR"
} elseif ($warnCount -gt 0) {
    Write-Status "One or more checks indicate a condition worth reviewing — see AdministratorProtection-B.md Triage table." "WARN"
} else {
    Write-Status "No blocking conditions detected." "OK"
}
