<#
.SYNOPSIS
    One-shot audit of Windows 365 Reserve Cloud PC inventory and BCDR-readiness signals.

.DESCRIPTION
    Reads all Windows 365 Reserve Cloud PCs tenant-wide (filtered from the general Cloud PC
    inventory by service plan name) and cross-references provisioning policy assignment to
    surface the real-world failure patterns documented in Reserve-A.md / Reserve-B.md:
      1. Active Reserve Cloud PC inventory with status, useful for confirming the
         one-active-Reserve-Cloud-PC-per-user rule before a second provisioning attempt.
      2. Provisioning policy assignment cross-check, to help spot policy-assignment
         precedence issues (a user only ever counts toward the FIRST Reserve policy
         assigned to them).
      3. A flag for any Cloud PC that has been active for close to or beyond the 10-day
         per-user-per-year access ceiling, as an early warning before natural expiry
         (which snapshots) is reached.

    This script CANNOT read: license assignment timestamps (needed to evaluate the mandatory
    7-day activation delay — this is portal-only, exposed in Cloud PC Overview > Windows 365
    Reserve licensing), or a user's remaining annual day balance. Both require the Intune
    admin center report; this script flags where that manual cross-check is needed.

.PARAMETER OutputPath
    Directory to write the CSV reports to. Defaults to the current directory.

.PARAMETER UserPrincipalName
    Optional. Scope the audit to a single user instead of the full tenant.

.EXAMPLE
    .\Get-Windows365ReserveAudit.ps1
    Audits all Reserve Cloud PCs tenant-wide.

.EXAMPLE
    .\Get-Windows365ReserveAudit.ps1 -UserPrincipalName user@contoso.com -OutputPath C:\Audits
    Audits Reserve Cloud PC state for a single user.

.NOTES
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.Beta.DeviceManagement.Actions modules
    Scopes:   CloudPC.Read.All, DeviceManagementConfiguration.Read.All
    Safe/read-only: Yes — makes no configuration or provisioning changes.
#>

[CmdletBinding()]
param(
    [string]$UserPrincipalName,
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" {"Green"} "WARN" {"Yellow"} "ERROR" {"Red"} default {"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# --- Preflight ---
try {
    $ctx = Get-MgContext
    if (-not $ctx) { throw "Not connected." }
    Write-Status "Connected to tenant: $($ctx.TenantId)" "OK"
} catch {
    Write-Status "Not connected to Microsoft Graph. Run Connect-MgGraph -Scopes 'CloudPC.Read.All','DeviceManagementConfiguration.Read.All' first." "ERROR"
    return
}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$timestamp = Get-Date -Format 'yyyyMMdd_HHmm'

# --- Step 1: Pull Reserve Cloud PC inventory ---
Write-Status "Reading Cloud PC inventory and filtering to Windows 365 Reserve service plans..."
try {
    $allCloudPcs = Get-MgBetaDeviceManagementVirtualEndpointCloudPc -All -ErrorAction Stop
} catch {
    Write-Status "Failed to read Cloud PC inventory: $($_.Exception.Message)" "ERROR"
    return
}

$reserveCloudPcs = $allCloudPcs | Where-Object { $_.ServicePlanName -like "*Reserve*" }

if ($UserPrincipalName) {
    $reserveCloudPcs = $reserveCloudPcs | Where-Object { $_.UserPrincipalName -eq $UserPrincipalName }
}

if (-not $reserveCloudPcs -or $reserveCloudPcs.Count -eq 0) {
    Write-Status "No Windows 365 Reserve Cloud PCs found$(if ($UserPrincipalName) { " for user $UserPrincipalName" })." "WARN"
    return
}

Write-Status "Found $($reserveCloudPcs.Count) Reserve Cloud PC(s)." "OK"

# --- Step 2: Detect per-user duplicate-active-Reserve-PC risk (should never happen, but flag if it does) ---
$duplicateCheck = $reserveCloudPcs | Group-Object UserPrincipalName | Where-Object { $_.Count -gt 1 }
if ($duplicateCheck) {
    Write-Status "WARNING: $($duplicateCheck.Count) user(s) show more than one Reserve Cloud PC record — this should never happen under the documented 1-per-user limit. Investigate for stale/orphaned records." "ERROR"
    $duplicateCheck | ForEach-Object {
        Write-Status "  User: $($_.Name) — $($_.Count) Reserve Cloud PC records" "ERROR"
    }
}

# --- Step 3: Build main report with provisioning policy cross-reference ---
$report = foreach ($pc in $reserveCloudPcs) {
    $policyName = $null
    if ($pc.ProvisioningPolicyId) {
        try {
            $policy = Get-MgBetaDeviceManagementVirtualEndpointProvisioningPolicy -CloudPcProvisioningPolicyId $pc.ProvisioningPolicyId -ErrorAction Stop
            $policyName = $policy.DisplayName
        } catch {
            $policyName = "UNRESOLVED (policy may have been deleted)"
        }
    }

    [PSCustomObject]@{
        DisplayName          = $pc.DisplayName
        UserPrincipalName    = $pc.UserPrincipalName
        Status               = $pc.Status
        ServicePlanName      = $pc.ServicePlanName
        ProvisioningPolicyId   = $pc.ProvisioningPolicyId
        ProvisioningPolicyName = $policyName
        ManagedDeviceId      = $pc.ManagedDeviceId
    }
}

$report | Export-Csv -Path (Join-Path $OutputPath "Windows365Reserve_Inventory_$timestamp.csv") -NoTypeInformation
Write-Status "Reserve Cloud PC inventory + policy cross-reference exported." "OK"

foreach ($row in $report) {
    if ($row.Status -notin @("provisioned", "provisioning")) {
        Write-Status "Cloud PC '$($row.DisplayName)' (user: $($row.UserPrincipalName)) status: $($row.Status) — investigate if unexpected." "WARN"
    }
}

Write-Status "Audit complete. Reports written to: $OutputPath" "OK"
Write-Host ""
Write-Host "REMINDER: This script cannot evaluate the 7-day license activation delay or a" -ForegroundColor Yellow
Write-Host "user's remaining annual day balance — both require Intune admin center > Reports" -ForegroundColor Yellow
Write-Host "> Cloud PC Overview > Windows 365 Reserve licensing. Cross-check that report" -ForegroundColor Yellow
Write-Host "manually before troubleshooting a provisioning-eligibility ticket further." -ForegroundColor Yellow
