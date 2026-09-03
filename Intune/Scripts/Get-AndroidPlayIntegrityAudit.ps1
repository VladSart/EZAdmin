<#
.SYNOPSIS
    Audits managed Android devices for exposure to the Google Play "Strong Integrity"
    security-patch-recency requirement that Microsoft Intune enforces starting 2026-10-31.

.DESCRIPTION
    Google redefined "Strong Integrity" for Android 13+ devices (May 2025 rollout) to require
    a security patch released within the trailing 12 months, in addition to hardware-backed
    key attestation. Microsoft Intune begins enforcing this stricter definition in compliance
    and app protection policy evaluation on October 31, 2026.

    This script is a READ-ONLY planning/triage tool. It does not change any policy or push any
    update. It enumerates managed Android devices via Microsoft Graph, flags Android 13+ devices
    whose on-device security patch level is already outside (or approaching) the trailing
    12-month window, and reports ownership type so remediation can be split between
    centrally-pushable corporate-owned devices and BYOD devices that require a user-notification
    campaign instead.

    It does NOT and cannot:
      - Query Google's own Play Integrity verdict directly (no supported Graph/Intune API
        surface exists for that; only the resulting compliance/setting state is visible).
      - Determine whether a specific device's hardware actually supports hardware-backed key
        attestation (this is an OEM hardware capability, not exposed via Graph device properties).
      - Push OS updates or modify compliance/app protection policies.

.PARAMETER WarningWindowMonths
    Devices with a security patch older than this many months are flagged as AT RISK.
    Default 10, giving a 2-month buffer ahead of the 12-month enforcement cutover.

.PARAMETER OutputPath
    CSV path for the full device-level report. Default .\AndroidPlayIntegrityAudit.csv

.EXAMPLE
    .\Get-AndroidPlayIntegrityAudit.ps1
    Runs with the default 10-month warning window and writes results to the default CSV.

.EXAMPLE
    .\Get-AndroidPlayIntegrityAudit.ps1 -WarningWindowMonths 12 -OutputPath .\out\android_audit.csv
    Flags only devices already past the full 12-month window (no buffer).

.NOTES
    Requires: Microsoft.Graph.DeviceManagement module, connected with at minimum
              DeviceManagementManagedDevices.Read.All.
    Safe/unsafe: fully read-only. Safe to run at any time, including in production, on a schedule.
#>
[CmdletBinding()]
param(
    [int]$WarningWindowMonths = 10,
    [string]$OutputPath = ".\AndroidPlayIntegrityAudit.csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---- Preflight ----
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.DeviceManagement)) {
    Write-Status "Microsoft.Graph.DeviceManagement module not found. Install with:`n    Install-Module Microsoft.Graph.DeviceManagement -Scope CurrentUser" "ERROR"
    return
}

try {
    $context = Get-MgContext
    if (-not $context) { throw "Not connected." }
    Write-Status "Connected to tenant $($context.TenantId) as $($context.Account)" "OK"
}
catch {
    Write-Status "Not connected to Microsoft Graph. Run: Connect-MgGraph -Scopes 'DeviceManagementManagedDevices.Read.All'" "ERROR"
    return
}

# ---- Detect: pull all managed Android devices ----
Write-Status "Retrieving managed Android devices (this can take a while on large fleets)..."
$androidDevices = Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'Android'" -All

if (-not $androidDevices -or $androidDevices.Count -eq 0) {
    Write-Status "No managed Android devices found in this tenant." "WARN"
    return
}
Write-Status "Retrieved $($androidDevices.Count) managed Android device(s)." "OK"

# ---- Execute: classify each device ----
$cutoverDate = Get-Date "2026-10-31"
$results = foreach ($d in $androidDevices) {
    $majorVersion = $null
    if ($d.OsVersion -match '^(\d+)') { $majorVersion = [int]$Matches[1] }

    $patchDate = $null
    $monthsSincePatch = $null
    if ($d.AndroidSecurityPatchLevel) {
        try {
            $patchDate = [datetime]$d.AndroidSecurityPatchLevel
            $monthsSincePatch = [math]::Round(((Get-Date) - $patchDate).Days / 30.0, 1)
        } catch {
            $patchDate = $null
        }
    }

    $inScope = ($majorVersion -ge 13)
    $status = "Not applicable (Android < 13, or version unknown)"
    if ($inScope) {
        if (-not $patchDate) {
            $status = "UNKNOWN — no patch date reported, verify manually"
        }
        elseif ($monthsSincePatch -ge 12) {
            $status = "AT RISK — already past 12-month strong-integrity window"
        }
        elseif ($monthsSincePatch -ge $WarningWindowMonths) {
            $status = "WARNING — approaching 12-month window before 2026-10-31 enforcement"
        }
        else {
            $status = "OK — patch within window"
        }
    }

    [pscustomobject]@{
        DeviceName           = $d.DeviceName
        UserPrincipalName    = $d.UserPrincipalName
        OwnerType            = $d.ManagedDeviceOwnerType   # company / personal
        ManagementAgent      = $d.ManagementAgent
        OSVersion            = $d.OsVersion
        AndroidMajorVersion  = $majorVersion
        SecurityPatchLevel   = if ($patchDate) { $patchDate.ToString('yyyy-MM-dd') } else { "Unknown" }
        MonthsSincePatch     = $monthsSincePatch
        ComplianceState      = $d.ComplianceState
        InScopeForChange     = $inScope
        Status               = $status
    }
}

# ---- Validate / summarize ----
$atRisk   = $results | Where-Object Status -like "AT RISK*"
$warning  = $results | Where-Object Status -like "WARNING*"
$unknown  = $results | Where-Object Status -like "UNKNOWN*"
$corpAtRisk = $atRisk | Where-Object OwnerType -eq 'company'
$byodAtRisk = $atRisk | Where-Object OwnerType -eq 'personal'

Write-Host ""
Write-Status "=== Play Integrity / Strong Integrity Exposure Summary ===" "INFO"
Write-Status "Enforcement date: 2026-10-31 (patch-recency requirement, Android 13+)" "INFO"
Write-Status "Total Android devices audited: $($results.Count)" "INFO"
Write-Status "AT RISK (already past 12mo window): $($atRisk.Count)  [$($corpAtRisk.Count) corporate-owned / $($byodAtRisk.Count) BYOD]" $(if ($atRisk.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "WARNING (approaching window, buffer=$WarningWindowMonths mo): $($warning.Count)" $(if ($warning.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "UNKNOWN (no patch date reported): $($unknown.Count)" $(if ($unknown.Count -gt 0) { "WARN" } else { "OK" })
Write-Host ""

if ($corpAtRisk.Count -gt 0) {
    Write-Status "Corporate-owned devices at risk can be centrally patched via an Android Enterprise system update policy." "INFO"
}
if ($byodAtRisk.Count -gt 0) {
    Write-Status "BYOD devices at risk require a Company Portal notification / grace-period campaign — Intune cannot force an OTA on personal hardware." "INFO"
}

# ---- Report: export full CSV ----
$results | Sort-Object Status, MonthsSincePatch -Descending | Export-Csv -Path $OutputPath -NoTypeInformation
Write-Status "Full device-level report exported to $OutputPath" "OK"
