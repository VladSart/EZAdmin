<#
.SYNOPSIS
    Audits Windows 365 for Agents provisioning policies, Cloud PC agent pools, and
    enrolled CPCA-* devices for health, capacity, and configuration-drift signals.

.DESCRIPTION
    Windows 365 for Agents is managed at the pool level (see Agents-A.md/Agents-B.md for
    full architecture), not per-device, which makes routine device-centric Intune
    reporting a poor fit for this workload. This script queries Microsoft Graph
    read-only and reports, per provisioning policy (agents):

    - Pool identity and provisioning type
    - Enrolled CPCA-* device count, and how many have NOT synced within a configurable
      staleness window (a proxy for pool devices that may be stuck rather than simply
      idle in the pool)
    - Device model/enrollment-profile consistency (flags any device matching the naming
      prefix but NOT carrying the expected "Cloud PC for Agents" model, which would
      indicate a naming collision with a non-agent device rather than a real pool member)
    - A read-only reminder of session accounting fields (Active/Available sessions vs.
      Always available Cloud PCs count) that are NOT exposed via a single stable GA
      Graph property as of this writing — this script surfaces the CloudPc collection's
      Status field distribution as the closest read-only proxy, and prints an explicit
      reminder to cross-check the authoritative session view in the Intune admin center's
      Provisioning policies (Agents) blade rather than treating this script's counts as
      the authoritative session ceiling.

    This script explicitly CANNOT and does not attempt to: change any pool's Always
    Available Cloud PCs count, trigger a reprovision, edit a partner-owned (Copilot
    Studio / Project Opal / Researcher) provisioning policy, or read live check-out/
    check-in session state (an ephemeral runtime concept not exposed via a dedicated
    read-only Graph report resource as of this writing).

.PARAMETER StaleSyncDays
    Number of days since last sync beyond which a CPCA-* device is flagged as
    potentially stuck rather than simply idle-in-pool. Default: 3.

.PARAMETER ExportPath
    Full path for CSV export. Defaults to
    $env:TEMP\Windows365AgentsAudit-<date>.csv.

.EXAMPLE
    .\Get-Windows365AgentsAudit.ps1
    Audits all Windows 365 for Agents provisioning policies and devices tenant-wide.

.EXAMPLE
    .\Get-Windows365AgentsAudit.ps1 -StaleSyncDays 1
    Uses a tighter staleness window for a pool expected to see frequent turnover.

.NOTES
    Read-only. Requires an interactive or app-only Microsoft Graph connection with at
    least CloudPC.Read.All and DeviceManagementManagedDevices.Read.All scopes
    (Connect-MgGraph is NOT called by this script — connect first with the scopes
    appropriate to your environment). Requires the Microsoft.Graph.DeviceManagement,
    Microsoft.Graph.DeviceManagement.Actions, and Microsoft.Graph.Authentication
    modules, plus Graph beta cmdlets for the virtual endpoint (Cloud PC) resources.
    Cloud PC agent pool status (Creating/Available/Updating/Available with
    warning/Failed/Deleting) and exact session counts are portal-authoritative as of
    this writing — this script's device-count-based proxies are a supplement to, not a
    replacement for, the Provisioning policies (Agents) admin center view.
#>
[CmdletBinding()]
param(
    [int]$StaleSyncDays = 3,
    [string]$ExportPath = "$env:TEMP\Windows365AgentsAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

try {
    $context = Get-MgContext
    if (-not $context) {
        throw "Not connected to Microsoft Graph. Run Connect-MgGraph -Scopes 'CloudPC.Read.All','DeviceManagementManagedDevices.Read.All' first."
    }
    Write-Status "Connected to tenant: $($context.TenantId)" "OK"
}
catch {
    Write-Status "Graph connection check failed: $_" "ERROR"
    throw
}

# --- Preflight: locate provisioning policies (agents) ---
Write-Status "Enumerating provisioning policies..."
$allPolicies = @()
try {
    $allPolicies = Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -All -ErrorAction Stop
}
catch {
    Write-Status "Failed to enumerate provisioning policies via Graph beta cmdlet: $_" "ERROR"
    throw
}

# Agents pools are identified heuristically: ProvisioningType containing 'agent' (case-
# insensitive) OR a CloudPcNamingTemplate starting with the documented CPCA- prefix.
# There is no single, stable, documented enum value guaranteed across tenants as of this
# writing — this script flags both signals independently rather than assuming one.
$agentPolicies = $allPolicies | Where-Object {
    ($_.ProvisioningType -match 'agent') -or ($_.CloudPcNamingTemplate -match '^CPCA-')
}

if (-not $agentPolicies -or $agentPolicies.Count -eq 0) {
    Write-Status "No Windows 365 for Agents provisioning policies detected in this tenant (by ProvisioningType or CPCA- naming template heuristic)." "WARN"
}
else {
    Write-Status "Found $($agentPolicies.Count) candidate Windows 365 for Agents provisioning polic(y/ies)." "OK"
}

# --- Detect: CPCA-* devices ---
Write-Status "Enumerating CPCA-* managed devices..."
$cpcaDevices = @()
try {
    $cpcaDevices = Get-MgDeviceManagementManagedDevice -Filter "startswith(deviceName,'CPCA-')" -All -ErrorAction Stop
}
catch {
    Write-Status "Failed to enumerate CPCA-* devices: $_" "ERROR"
}

$staleThreshold = (Get-Date).AddDays(-$StaleSyncDays)
$results = @()

foreach ($device in $cpcaDevices) {
    $isStale = $device.LastSyncDateTime -lt $staleThreshold
    $modelMismatch = $device.Model -notmatch 'Cloud PC for Agents'

    $results += [PSCustomObject]@{
        DeviceName            = $device.DeviceName
        Model                 = $device.Model
        ModelMismatchFlag     = $modelMismatch
        EnrolledDateTime      = $device.EnrolledDateTime
        LastSyncDateTime      = $device.LastSyncDateTime
        StaleSyncFlag         = $isStale
        ManagementAgent       = $device.ManagementAgent
        EnrollmentProfileName = $device.EnrollmentProfileName
    }
}

# --- Cloud PCs (per policy) status distribution — closest read-only session proxy ---
Write-Status "Enumerating Cloud PC for Agents status distribution (proxy for session pressure)..."
$cloudPcStatusSummary = @()
foreach ($policy in $agentPolicies) {
    try {
        $pcs = Get-MgBetaDeviceManagementVirtualEndpointCloudPc -Filter "provisioningPolicyId eq '$($policy.Id)'" -All -ErrorAction Stop
        $statusGroups = $pcs | Group-Object Status
        $cloudPcStatusSummary += [PSCustomObject]@{
            PolicyName    = $policy.DisplayName
            PolicyId      = $policy.Id
            TotalCloudPCs = $pcs.Count
            StatusBreakdown = ($statusGroups | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join '; '
        }
    }
    catch {
        Write-Status "Could not enumerate Cloud PCs for policy '$($policy.DisplayName)': $_" "WARN"
    }
}

# --- Report ---
Write-Host "`n=== Windows 365 for Agents Provisioning Policies ===" -ForegroundColor Cyan
$agentPolicies | Select-Object DisplayName, Id, ProvisioningType, CloudPcNamingTemplate | Format-Table -AutoSize

Write-Host "`n=== Cloud PC Status Distribution by Policy (session-pressure proxy only) ===" -ForegroundColor Cyan
$cloudPcStatusSummary | Format-Table -AutoSize
Write-Status "Reminder: this status breakdown is NOT the authoritative Active/Available session count. Cross-check the Provisioning policies (Agents) admin center view for the true session ceiling (Always available Cloud PCs count) before making capacity decisions." "WARN"

Write-Host "`n=== CPCA-* Device Inventory ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize

$staleCount = ($results | Where-Object { $_.StaleSyncFlag }).Count
$mismatchCount = ($results | Where-Object { $_.ModelMismatchFlag }).Count

if ($staleCount -gt 0) {
    Write-Status "$staleCount device(s) have not synced in over $StaleSyncDays day(s) — investigate as potentially stuck rather than assuming normal pool idle time." "WARN"
}
if ($mismatchCount -gt 0) {
    Write-Status "$mismatchCount device(s) match the CPCA- naming prefix but do NOT carry the 'Cloud PC for Agents' model string — verify these are not a naming collision with an unrelated device." "WARN"
}
if ($staleCount -eq 0 -and $mismatchCount -eq 0 -and $results.Count -gt 0) {
    Write-Status "No staleness or model-mismatch anomalies detected across $($results.Count) CPCA-* device(s)." "OK"
}

$results | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Full device inventory exported to: $ExportPath" "OK"
