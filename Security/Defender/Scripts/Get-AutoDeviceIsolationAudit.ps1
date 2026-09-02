<#
.SYNOPSIS
    Audits Microsoft Defender for Endpoint devices for automatic attack-disruption
    isolation state, recent isolate/release action history, and related active
    incidents tagged AttackDisruption.

.DESCRIPTION
    Automatic device isolation (Preview) lets Defender XDR isolate a compromised
    end-user workstation without waiting for human approval, as part of automatic
    attack disruption. This script gives read-only visibility into:
    - Current isolation state per device (via api.securitycenter.microsoft.com/api/machines)
    - Recent Isolate/Unisolate machine-action history, including requestor (system vs.
      named admin), to distinguish automatic from manual isolation
    - Active incidents tagged AttackDisruption that could be the trigger
    - Device tag membership, to help cross-reference against Automatic attack disruption
      exclusion rules configured in the Defender portal (those exclusion RULES are
      portal-only and NOT readable via any documented API as of this writing — this
      script surfaces tag membership only, not the exclusion policy itself)

    This script does NOT and CANNOT:
    - Read or modify Selective isolation exclusion rules or Automatic attack disruption
      exclusion policy configuration (portal-only, no documented Graph/REST surface)
    - Isolate or release devices (see -Unisolate switch for a guarded, explicit release
      action; isolation itself is intentionally not exposed here to avoid accidental
      containment from an audit script)
    - Distinguish Full vs. Selective isolation type from the machine record alone;
      cross-reference with exclusion configuration in the portal if this matters

.PARAMETER DeviceName
    Filter by device display name (partial match).

.PARAMETER IsolatedOnly
    Return only devices currently in an isolated state.

.PARAMETER LookbackDays
    How many days of machine-action history to pull per device. Default: 14.

.PARAMETER Unisolate
    When combined with -DeviceName resolving to exactly one device, releases that
    device from isolation after an explicit confirmation prompt. Omit this switch
    to run in pure read-only audit mode (the default and recommended usage).

.PARAMETER ExportPath
    Full path for CSV export. Defaults to $env:TEMP\AutoDeviceIsolation-Audit-<date>.csv.

.EXAMPLE
    # Audit all devices for isolation state and recent action history
    .\Get-AutoDeviceIsolationAudit.ps1

.EXAMPLE
    # Show only currently isolated devices
    .\Get-AutoDeviceIsolationAudit.ps1 -IsolatedOnly

.EXAMPLE
    # Investigate one device's isolation history over the last 30 days
    .\Get-AutoDeviceIsolationAudit.ps1 -DeviceName "DESKTOP-CORP01" -LookbackDays 30

.EXAMPLE
    # Release a confirmed-remediated device from isolation (prompts for confirmation)
    .\Get-AutoDeviceIsolationAudit.ps1 -DeviceName "DESKTOP-CORP01" -Unisolate

.NOTES
    Requires: Microsoft.Graph.Authentication PowerShell module (Connect-MgGraph)
    Permissions needed (Graph/MDE): Machine.Read.All (read-only mode);
      Machine.ReadWrite.All also required if -Unisolate is used.
    Recommended role: Security Reader (read-only) or Security Operator (for -Unisolate).
    Default mode (no -Unisolate) is fully read-only and safe to run in production.
    -Unisolate performs a real, immediate containment change — use deliberately, not
    as part of a scheduled/unattended run.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [Parameter()]
    [string]$DeviceName,

    [Parameter()]
    [switch]$IsolatedOnly,

    [Parameter()]
    [int]$LookbackDays = 14,

    [Parameter()]
    [switch]$Unisolate,

    [Parameter()]
    [string]$ExportPath = "$env:TEMP\AutoDeviceIsolation-Audit-$(Get-Date -Format yyyyMMdd-HHmmss).csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param(
        [string]$Message,
        [ValidateSet("INFO", "OK", "WARN", "ERROR", "SECTION")]
        [string]$Status = "INFO"
    )
    $colour = switch ($Status) {
        "OK"      { "Green" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "SECTION" { "Cyan" }
        default   { "White" }
    }
    $prefix = if ($Status -eq "SECTION") { "`n====" } else { "[$Status]" }
    Write-Host "$prefix $Message" -ForegroundColor $colour
}

#region Prerequisites
Write-Status "Checking prerequisites..." -Status SECTION

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Status "Microsoft.Graph.Authentication module not found. Install with: Install-Module Microsoft.Graph.Authentication" -Status ERROR
    exit 1
}

try {
    $ctx = Get-MgContext
    if (-not $ctx) {
        $scopes = if ($Unisolate) { @("Machine.ReadWrite.All") } else { @("Machine.Read.All") }
        Write-Status "Connecting to Microsoft Graph (scopes: $($scopes -join ', '))..." -Status INFO
        Connect-MgGraph -Scopes $scopes -NoWelcome
    }
    Write-Status "Connected as $((Get-MgContext).Account)" -Status OK
}
catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" -Status ERROR
    exit 1
}
#endregion

#region Fetch machines
Write-Status "Retrieving MDE device inventory..." -Status SECTION

$machinesUri = "https://api.securitycenter.microsoft.com/api/machines"
try {
    $allMachines = (Invoke-MgGraphRequest -Method GET -Uri $machinesUri).value
}
catch {
    Write-Status "Failed to query machines API. Confirm Machine.Read.All is granted and admin-consented. Error: $($_.Exception.Message)" -Status ERROR
    exit 1
}

if ($DeviceName) {
    $allMachines = $allMachines | Where-Object { $_.computerDnsName -like "*$DeviceName*" }
}
if ($IsolatedOnly) {
    $allMachines = $allMachines | Where-Object { $_.isolationState -and $_.isolationState -ne "NotIsolated" }
}

Write-Status "Found $($allMachines.Count) matching device(s)." -Status INFO
#endregion

#region Fetch related active AttackDisruption incidents (once, shared across devices)
Write-Status "Pulling active incidents tagged AttackDisruption..." -Status SECTION

$attackDisruptionIncidents = @()
try {
    $incUri = "https://graph.microsoft.com/v1.0/security/incidents?`$filter=status eq 'active'&`$top=100"
    $incidents = (Invoke-MgGraphRequest -Method GET -Uri $incUri).value
    $attackDisruptionIncidents = $incidents | Where-Object { $_.systemTags -and ($_.systemTags -contains "AttackDisruption") }
    Write-Status "Found $($attackDisruptionIncidents.Count) active AttackDisruption-tagged incident(s)." -Status INFO
}
catch {
    Write-Status "Could not query incidents (SecurityIncident.Read.All may be missing). Continuing without incident cross-reference." -Status WARN
}
#endregion

#region Per-device action history + report
Write-Status "Building per-device report..." -Status SECTION

$report = foreach ($m in $allMachines) {

    $actionsUri = "https://api.securitycenter.microsoft.com/api/machineactions?`$filter=machineId eq '$($m.id)'&`$orderby=creationDateTimeUtc desc&`$top=10"
    $recentActions = @()
    try {
        $recentActions = (Invoke-MgGraphRequest -Method GET -Uri $actionsUri).value |
            Where-Object { [datetime]$_.creationDateTimeUtc -ge (Get-Date).AddDays(-$LookbackDays) }
    }
    catch {
        Write-Status "Could not pull action history for $($m.computerDnsName): $($_.Exception.Message)" -Status WARN
    }

    $lastIsolate = $recentActions | Where-Object { $_.type -eq "Isolate" } | Select-Object -First 1
    $lastUnisolate = $recentActions | Where-Object { $_.type -eq "Unisolate" } | Select-Object -First 1

    $triggerType = if ($lastIsolate) {
        if ($lastIsolate.requestor -match "System|Automation|AttackDisruption|SecurityOperator") { "Likely Automatic" } else { "Likely Manual" }
    } else { "N/A" }

    $relatedIncident = $attackDisruptionIncidents | Where-Object {
        $_.deviceStates -and ($_.deviceStates | Where-Object { $_.deviceId -eq $m.id })
    } | Select-Object -First 1

    $colour = switch ($m.isolationState) {
        "Isolated"        { "Yellow" }
        "ReverseIsolated" { "Yellow" }
        default           { "Green" }
    }
    Write-Status "$($m.computerDnsName): isolationState=$($m.isolationState) lastAction=$($lastIsolate.type)/$($lastIsolate.requestor)" -Status $(if ($m.isolationState -eq "Isolated") { "WARN" } else { "OK" })

    [PSCustomObject]@{
        DeviceName          = $m.computerDnsName
        MachineId           = $m.id
        IsolationState      = $m.isolationState
        HealthStatus        = $m.healthStatus
        LastSeen            = $m.lastSeen
        OSPlatform          = $m.osPlatform
        MachineTags         = ($m.machineTags -join "; ")
        LastIsolateAction   = if ($lastIsolate) { $lastIsolate.creationDateTimeUtc } else { $null }
        LastIsolateStatus   = $lastIsolate.status
        LastIsolateRequestor= $lastIsolate.requestor
        TriggerTypeGuess    = $triggerType
        LastUnisolateAction = if ($lastUnisolate) { $lastUnisolate.creationDateTimeUtc } else { $null }
        RelatedIncidentId   = $relatedIncident.id
        RelatedIncidentName = $relatedIncident.displayName
        RelatedIncidentSev  = $relatedIncident.severity
    }
}
#endregion

#region Optional guarded release
if ($Unisolate) {
    if ($allMachines.Count -ne 1) {
        Write-Status "-Unisolate requires -DeviceName to resolve to exactly one device. Matched: $($allMachines.Count). Aborting release." -Status ERROR
    }
    else {
        $target = $allMachines[0]
        if ($target.isolationState -eq "NotIsolated") {
            Write-Status "$($target.computerDnsName) is not currently isolated. Nothing to release." -Status INFO
        }
        elseif ($PSCmdlet.ShouldProcess($target.computerDnsName, "Release from isolation (unisolate)")) {
            $confirmText = Read-Host "Type the device name '$($target.computerDnsName)' to confirm release from isolation"
            if ($confirmText -eq $target.computerDnsName) {
                $body = @{ Comment = "Released via Get-AutoDeviceIsolationAudit.ps1 by $((Get-MgContext).Account)" } | ConvertTo-Json
                try {
                    Invoke-MgGraphRequest -Method POST -Uri "https://api.securitycenter.microsoft.com/api/machines/$($target.id)/unisolate" -Body $body -ContentType "application/json" | Out-Null
                    Write-Status "Release request submitted for $($target.computerDnsName). Verify status via the machineactions endpoint or Action center." -Status OK
                }
                catch {
                    Write-Status "Release request failed: $($_.Exception.Message)" -Status ERROR
                }
            }
            else {
                Write-Status "Confirmation text did not match device name. Release aborted." -Status WARN
            }
        }
    }
}
#endregion

#region Export
Write-Status "Exporting report..." -Status SECTION
$report | Sort-Object IsolationState -Descending | Format-Table DeviceName, IsolationState, TriggerTypeGuess, LastIsolateAction, RelatedIncidentName -AutoSize
$report | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Report exported to $ExportPath" -Status OK

$isolatedCount = ($report | Where-Object { $_.IsolationState -eq "Isolated" }).Count
if ($isolatedCount -gt 0) {
    Write-Status "$isolatedCount device(s) currently isolated. Review RelatedIncidentName/TriggerTypeGuess columns before taking any release action." -Status WARN
}
else {
    Write-Status "No devices currently isolated among matched results." -Status OK
}
#endregion
