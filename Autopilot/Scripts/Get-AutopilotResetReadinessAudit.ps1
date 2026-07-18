<#
.SYNOPSIS
    Fleet-wide audit of Windows Autopilot Reset eligibility via Graph — flags
    hybrid-joined/ineligible devices before a bulk reset is attempted, and
    surfaces staleness that would cause a remote reset command to silently
    never execute.

.DESCRIPTION
    Reset-A.md's Scope & Assumptions table and Symptom → Cause Map identify the
    two most common "why didn't this work" causes as things that are entirely
    knowable in advance, before anyone touches a device or issues a reset command:

    - Join type: Autopilot Reset hard-excludes Entra hybrid joined devices and
      Surface Hub. Attempting it anyway doesn't produce a clean error in every
      admin's workflow — it just silently fails or the action is unavailable.
      This script flags every hybrid-joined device in a target list up front.
    - Staleness: remote reset requires the device to be actively MDM-managed
      and check in to receive the command (Reset-A.md Phase 4). A device that's
      gone stale in Intune will still show the action as available in the
      portal but the command will queue indefinitely.

    This script does NOT and CANNOT check WinRE state (reagentc /info) or the
    local-reset CSP registry value remotely — those are local, device-side
    facts with no Graph-exposed equivalent. Run the Evidence Pack script from
    Reset-A.md on-device for those checks. This script is a pre-flight triage
    tool for the identity/management-state layer only, intended to catch bad
    device lists before a bulk operation (see Reset-A.md Playbook 2).

    Exports full results to CSV and prints a colour-coded console summary.

.PARAMETER DeviceNames
    Array of device names to audit. If omitted, audits all managed Windows
    devices in the tenant (can be slow/large — prefer a targeted list for
    day-to-day use).

.PARAMETER StaleSyncDays
    Number of days since last MDM sync beyond which a device is flagged as
    possibly unreachable for a remote reset command. Default: 7.

.PARAMETER OutputPath
    Path for CSV export. Default: C:\Temp\AutopilotResetReadiness-<timestamp>.csv

.EXAMPLE
    .\Get-AutopilotResetReadinessAudit.ps1 -DeviceNames @("CONTOSO-LT-001","CONTOSO-LT-002")

.EXAMPLE
    .\Get-AutopilotResetReadinessAudit.ps1
    # Audits every managed Windows device in the tenant

.NOTES
    Requires: Microsoft.Graph.DeviceManagement module
    Permissions: DeviceManagementManagedDevices.Read.All
    Safe: Read-only — issues no reset, wipe, or any write operation
    Cross-references: Autopilot/Troubleshooting/Reset-A.md and Reset-B.md
                       (Symptom → Cause Map, Phase 1, Phase 4, Playbook 2)
#>

[CmdletBinding()]
param(
    [string[]]$DeviceNames,

    [int]$StaleSyncDays = 7,

    [string]$OutputPath = "C:\Temp\AutopilotResetReadiness-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

# ── Preflight ────────────────────────────────────────────────────────────────
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.DeviceManagement)) {
    Write-Status "Microsoft.Graph.DeviceManagement module not found. Install with:" "ERROR"
    Write-Status "  Install-Module Microsoft.Graph.DeviceManagement -Scope CurrentUser" "ERROR"
    exit 1
}

try {
    $context = Get-MgContext -ErrorAction Stop
    if (-not $context) { throw "No active Graph session" }
    Write-Status "Using existing Graph session: $($context.Account)" "OK"
} catch {
    Write-Status "Connecting to Graph (DeviceManagementManagedDevices.Read.All)..." "INFO"
    Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All" -NoWelcome
}

# ── Step 1: Pull target device list ─────────────────────────────────────────
Write-Status "Pulling managed device records..." "INFO"
$allDevices = [System.Collections.Generic.List[object]]::new()

try {
    if ($DeviceNames -and $DeviceNames.Count -gt 0) {
        foreach ($name in $DeviceNames) {
            $dev = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$name' and operatingSystem eq 'Windows'" -All
            if ($dev) { $allDevices.Add($dev) }
            else { Write-Status "Device not found or not Windows: $name" "WARN" }
        }
    } else {
        Write-Status "No -DeviceNames supplied — auditing ALL managed Windows devices (this may take a while)." "WARN"
        $allDevices.AddRange(@(Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'Windows'" -All))
    }
    Write-Status "Retrieved $($allDevices.Count) device record(s)." "OK"
} catch {
    Write-Status "Failed to pull managed devices: $($_.Exception.Message)" "ERROR"
    exit 1
}

if ($allDevices.Count -eq 0) {
    Write-Status "No devices to audit. Exiting." "WARN"
    exit 0
}

# ── Step 2: Build per-device eligibility report ─────────────────────────────
$report = [System.Collections.Generic.List[PSCustomObject]]::new()
$staleCutoff = (Get-Date).AddDays(-$StaleSyncDays)

foreach ($dev in $allDevices) {
    $joinType   = $dev.JoinType
    $isHybrid   = $joinType -match "hybridAzureADJoined|hybrid"
    $isManaged  = $dev.ManagementState -eq "managed"
    $lastSync   = $dev.LastSyncDateTime
    $isStale    = $false
    if ($lastSync) {
        try { $isStale = ([datetime]$lastSync) -lt $staleCutoff } catch { }
    }

    $eligibility = if ($isHybrid) {
        "INELIGIBLE — hybrid joined, use full Wipe instead (Reset-A.md Playbook 1)"
    } elseif (-not $isManaged) {
        "BLOCKED — not actively MDM-managed, remote reset won't execute"
    } elseif ($isStale) {
        "AT RISK — MDM sync stale, remote reset command may queue indefinitely"
    } else {
        "ELIGIBLE (remote) — verify WinRE/local-reset CSP on-device before local reset"
    }

    $report.Add([PSCustomObject]@{
        DeviceName        = $dev.DeviceName
        DeviceId          = $dev.Id
        JoinType          = $joinType
        ManagementState   = $dev.ManagementState
        LastSyncDateTime  = $lastSync
        StaleSync         = $isStale
        Eligibility       = $eligibility
        OSVersion         = $dev.OsVersion
    })
}

# ── Export ────────────────────────────────────────────────────────────────
$outputDir = Split-Path $OutputPath
if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$report | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Full report exported to: $OutputPath" "OK"

# ── Console summary ─────────────────────────────────────────────────────────
$hybrid = $report | Where-Object { $_.Eligibility -like "INELIGIBLE*" }
if ($hybrid.Count -gt 0) {
    Write-Host "`n=== Hybrid-Joined Devices — NOT eligible for Autopilot Reset (Reset-A.md Playbook 1) ===" -ForegroundColor Red
    $hybrid | Format-Table DeviceName, JoinType, Eligibility -AutoSize
} else {
    Write-Status "No hybrid-joined devices found in the audited list." "OK"
}

$blocked = $report | Where-Object { $_.Eligibility -like "BLOCKED*" }
if ($blocked.Count -gt 0) {
    Write-Host "`n=== Devices Not Actively MDM-Managed ===" -ForegroundColor Red
    $blocked | Format-Table DeviceName, ManagementState -AutoSize
}

$atRisk = $report | Where-Object { $_.Eligibility -like "AT RISK*" }
if ($atRisk.Count -gt 0) {
    Write-Host "`n=== Devices With Stale MDM Sync (>$StaleSyncDays days) — remote reset may not execute ===" -ForegroundColor Yellow
    $atRisk | Format-Table DeviceName, LastSyncDateTime -AutoSize
}

$eligible = $report | Where-Object { $_.Eligibility -like "ELIGIBLE*" }
Write-Status "$($eligible.Count) of $($report.Count) device(s) look eligible for remote Autopilot Reset based on join type + sync recency." "OK"

Write-Host "`nNote: WinRE state and the local-reset CSP value cannot be checked remotely via Graph." -ForegroundColor DarkGray
Write-Host "Run the Evidence Pack script in Reset-A.md on-device to confirm those before a local reset." -ForegroundColor DarkGray
