<#
.SYNOPSIS
    Tenant-wide fleet report identifying devices at elevated risk of Primary Refresh
    Token (PRT) acquisition failure, based on Entra device object state.

.DESCRIPTION
    Connects to Microsoft Graph and retrieves all device objects, then flags devices
    that are likely to be experiencing or about to experience PRT problems:
    - DISABLED:        Device object is disabled in Entra — PRT acquisition will fail
                        outright (dsregcmd shows AzureAdPrt: NO)
    - STALE_SIGNIN:     No sign-in activity beyond StaleThresholdDays — PRT may have
                        expired past its 14-day rolling renewal window with no activity
                        to refresh it
    - HYBRID_NO_RECENT: Hybrid Azure AD Joined device with stale sign-in — the most
                        common combination behind "SSO suddenly stopped working" tickets,
                        since Hybrid PRT depends on both cloud and on-prem Kerberos paths
                        staying healthy simultaneously
    - NEVER_SIGNED_IN:  Device registered but has never completed a sign-in — usually
                        an incomplete Autopilot/Hybrid join that never got as far as
                        PRT issuance

    This is a fleet-level triage tool: it tells you WHICH devices are worth pulling
    dsregcmd evidence from, before you spend time chasing tickets one at a time.

    Exports results to CSV and prints a colour-coded console summary, grouped by risk
    flag. Read-only — makes no changes to device objects.

    Does NOT cover:
    - Per-device root-cause diagnosis (TPM state, device certificate validity, network
      connectivity to Entra endpoints, AAD operational event log) — see
      EntraID/Troubleshooting/PRT-Issues-A.md Validation Steps and Evidence Pack, which
      must be run ON the affected device
    - AzureADKerberos server object health (on-prem AD object, not visible via Graph) —
      see PRT-Issues-A.md Validation Step 6 and Playbook 3

.PARAMETER StaleThresholdDays
    Number of days without sign-in before a device is flagged as a PRT staleness risk.
    Default: 21 (comfortably beyond the 14-day PRT rolling renewal window).

.PARAMETER HybridOnly
    Only report on Hybrid Azure AD Joined devices (TrustType = ServerAd). Use this to
    focus a triage pass specifically on the on-prem+cloud dependency chain.

.PARAMETER OutputPath
    Path for the CSV export. Default: .\PRT-Fleet-Risk-<timestamp>.csv

.EXAMPLE
    .\Get-PRTFleetRisk.ps1

    Reports on all devices tenant-wide with the default 21-day staleness threshold.

.EXAMPLE
    .\Get-PRTFleetRisk.ps1 -HybridOnly -StaleThresholdDays 14

    Focuses on Hybrid Joined devices only, using a tighter 14-day threshold.

.NOTES
    Requires: Microsoft.Graph PowerShell SDK
    Scopes needed: Device.Read.All
    Run As: An account with Reports Reader, Global Reader, or Cloud Device Administrator
            (read) role — does not require write permissions
    Safe: Read-only — no device objects are changed
    Cross-references: EntraID/Troubleshooting/PRT-Issues-A.md (Symptom -> Cause Map,
                       Validation Steps, Playbook 1 for re-enabling disabled devices)

    Known limitation: Entra device objects do not directly expose PRT state — that lives
    only in dsregcmd output on the device itself. This script infers RISK from proxy
    signals (enabled/disabled, sign-in recency, join type). A device flagged here is a
    candidate for evidence collection, not a confirmed PRT failure.
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 365)]
    [int]$StaleThresholdDays = 21,

    [switch]$HybridOnly,

    [string]$OutputPath = ".\PRT-Fleet-Risk-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
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

function Get-JoinTypeFriendly {
    param([string]$TrustType)
    switch ($TrustType) {
        "ServerAd"  { return "HybridJoined" }
        "AzureAd"   { return "EntraJoined" }
        "Workplace" { return "EntraRegistered" }
        default     { return "Unknown" }
    }
}

# ─── Connect ───
try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Connecting to Microsoft Graph..." "INFO"
        Connect-MgGraph -Scopes "Device.Read.All" -NoWelcome
    }
} catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    return
}

# ─── Retrieve devices ───
Write-Status "Retrieving device objects from Entra..." "INFO"

$selectProps = @(
    "id","displayName","deviceId","trustType","accountEnabled",
    "approximateLastSignInDateTime","operatingSystem","operatingSystemVersion",
    "registrationDateTime"
)

try {
    $allDevices = Get-MgDevice -All -Property ($selectProps -join ",") -EA Stop
    Write-Status "Retrieved $($allDevices.Count) device object(s)" "OK"
} catch {
    Write-Status "Failed to retrieve devices: $($_.Exception.Message)" "ERROR"
    return
}

if ($HybridOnly) {
    $allDevices = $allDevices | Where-Object { $_.TrustType -eq "ServerAd" }
    Write-Status "Filtered to Hybrid Azure AD Joined devices only: $($allDevices.Count) device(s)" "INFO"
}

if (-not $allDevices -or $allDevices.Count -eq 0) {
    Write-Status "No devices to process." "WARN"
    return
}

# ─── Analyse ───
$staleCutoff = (Get-Date).AddDays(-$StaleThresholdDays)
$allResults  = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($device in $allDevices) {
    $joinType   = Get-JoinTypeFriendly -TrustType $device.TrustType
    $lastSignIn = $device.ApproximateLastSignInDateTime
    $neverSignedIn = ($null -eq $lastSignIn)
    $isStale       = (-not $neverSignedIn) -and ($lastSignIn -lt $staleCutoff)

    $daysSince = if ($lastSignIn) { [math]::Round(((Get-Date) - $lastSignIn).TotalDays, 0) } else { $null }

    $flags = [System.Collections.Generic.List[string]]::new()
    if (-not $device.AccountEnabled) { $flags.Add("DISABLED") }
    if ($neverSignedIn)              { $flags.Add("NEVER_SIGNED_IN") }
    if ($isStale)                    { $flags.Add("STALE_SIGNIN") }
    if ($joinType -eq "HybridJoined" -and ($isStale -or $neverSignedIn)) { $flags.Add("HYBRID_NO_RECENT") }

    $riskLevel = if ($flags.Contains("DISABLED")) { "HIGH" }
                 elseif ($flags.Contains("HYBRID_NO_RECENT")) { "HIGH" }
                 elseif ($flags.Contains("NEVER_SIGNED_IN")) { "MEDIUM" }
                 elseif ($flags.Contains("STALE_SIGNIN")) { "MEDIUM" }
                 else { "LOW" }

    $allResults.Add([PSCustomObject]@{
        DisplayName                   = $device.DisplayName
        DeviceObjectId                 = $device.Id
        DeviceId                       = $device.DeviceId
        JoinType                       = $joinType
        AccountEnabled                 = $device.AccountEnabled
        OperatingSystem                = $device.OperatingSystem
        OperatingSystemVersion         = $device.OperatingSystemVersion
        ApproximateLastSignInDateTime  = if ($lastSignIn) { $lastSignIn.ToString("yyyy-MM-dd HH:mm:ss") } else { "Never" }
        DaysSinceLastSignIn            = if ($null -ne $daysSince) { $daysSince } else { "N/A" }
        RegistrationDateTime           = if ($device.RegistrationDateTime) { $device.RegistrationDateTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "" }
        RiskFlags                      = if ($flags.Count -gt 0) { $flags -join "|" } else { "" }
        RiskLevel                      = $riskLevel
    })
}

# ─── Console summary ───
Write-Host "`n=== PRT Fleet Risk Summary ===" -ForegroundColor Cyan

$highRisk   = $allResults | Where-Object RiskLevel -eq "HIGH"
$mediumRisk = $allResults | Where-Object RiskLevel -eq "MEDIUM"

Write-Status "Total devices assessed: $($allResults.Count)" "INFO"
Write-Status "  HIGH risk:   $($highRisk.Count)" $(if ($highRisk.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "  MEDIUM risk: $($mediumRisk.Count)" $(if ($mediumRisk.Count -gt 0) { "WARN" } else { "OK" })

if ($highRisk.Count -gt 0) {
    Write-Host "`n=== HIGH RISK DEVICES ===" -ForegroundColor Red
    $highRisk | Sort-Object JoinType, DisplayName |
        Select-Object DisplayName, JoinType, AccountEnabled, ApproximateLastSignInDateTime, DaysSinceLastSignIn, RiskFlags |
        Format-Table -AutoSize
}

if ($mediumRisk.Count -gt 0) {
    Write-Host "`n=== MEDIUM RISK DEVICES ===" -ForegroundColor Yellow
    $mediumRisk | Sort-Object DaysSinceLastSignIn -Descending |
        Select-Object DisplayName, JoinType, ApproximateLastSignInDateTime, DaysSinceLastSignIn, RiskFlags |
        Format-Table -AutoSize
}

# ─── Export ───
$outputDir = Split-Path $OutputPath -Parent
if ($outputDir -and -not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }

$allResults | Sort-Object @{Expression = { switch ($_.RiskLevel) { "HIGH" {0} "MEDIUM" {1} default {2} } }}, DisplayName |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "`nResults exported to: $OutputPath" "OK"

if ($highRisk.Count -gt 0) {
    Write-Status "Next step for HIGH risk devices: pull the Evidence Pack from EntraID/Troubleshooting/PRT-Issues-A.md ON the affected device to confirm actual PRT state via dsregcmd." "WARN"
}
