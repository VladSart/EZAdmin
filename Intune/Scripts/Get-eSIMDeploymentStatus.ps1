<#
.SYNOPSIS
    Audits Windows Connected PC eSIM cellular profile deployment status across both
    Intune bulk-deployment methods: CSV activation-code import and eSIM download server.

.DESCRIPTION
    Microsoft Intune supports two distinct, mutually-independent bulk eSIM deployment
    methods for Windows Connected PCs (see eSIM-A.md / eSIM-B.md for full architecture):

    - CSV activation-code import (public preview; Windows 10/11), tracked via the
      Graph beta resource deviceManagement/embeddedSIMActivationCodePools.
    - eSIM download server (SM-DP+ FQDN, recommended; Windows 11 only), delivered as an
      ordinary Settings Catalog configuration policy — identified here by name match
      ("eSIM"/"eUICC") since there is no dedicated typed Graph resource distinguishing
      it from any other Settings Catalog policy.

    This script queries both surfaces read-only and reports, per managed device: which
    method (if any) appears to be assigned, Intune-side delivery/assignment status, and
    basic device eligibility facts (OS version, model, last sync).

    It explicitly CANNOT and does not attempt to: confirm actual eSIM profile presence
    or activation state on the device's eUICC (this is only observable locally on the
    device, under Settings > Network & Internet > Cellular > Manage eSIM profiles, or
    via the mobile operator) or perform any write/remediation action. This is a strict
    read-only delivery-status diagnostic, not an activation-state or connectivity check.

.PARAMETER DeviceName
    Optional. Filters results to a single device by name. If omitted, audits all
    managed Windows devices returned by the tenant (subject to Graph paging).

.PARAMETER ExportPath
    Full path for CSV export. Defaults to
    $env:TEMP\eSIM-DeploymentStatus-<date>.csv.

.EXAMPLE
    .\Get-eSIMDeploymentStatus.ps1
    Audits all managed Windows devices for eSIM policy/pool assignment.

.EXAMPLE
    .\Get-eSIMDeploymentStatus.ps1 -DeviceName "SURFACE-LTE-042"
    Audits a single device.

.NOTES
    Read-only. Requires an interactive or app-only Microsoft Graph connection with at
    least DeviceManagementManagedDevices.Read.All and
    DeviceManagementConfiguration.Read.All scopes (Connect-MgGraph is NOT called by
    this script — connect first with the scopes appropriate to your environment).
    Requires the Microsoft.Graph.DeviceManagement and Microsoft.Graph.Authentication
    modules. The embeddedSIMActivationCodePools resource is a Graph BETA endpoint —
    subject to change without notice; re-verify against current Microsoft Learn/Graph
    documentation if this script starts returning unexpected results.
#>
[CmdletBinding()]
param(
    [string]$DeviceName,
    [string]$ExportPath = "$env:TEMP\eSIM-DeploymentStatus-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

try {
    $ctx = Get-MgContext -EA Stop
    if (-not $ctx) { throw "No active Graph context." }
}
catch {
    Write-Status "No active Microsoft Graph connection found. Run Connect-MgGraph with DeviceManagementManagedDevices.Read.All and DeviceManagementConfiguration.Read.All before running this script." "ERROR"
    return
}

Write-Status "Starting eSIM deployment status audit..." "INFO"

# ---------------------------------------------------------------------------
# 1. Pull managed Windows devices (optionally filtered to one device)
# ---------------------------------------------------------------------------
try {
    if ($DeviceName) {
        $devices = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$DeviceName' and operatingSystem eq 'Windows'" -EA Stop
    }
    else {
        $devices = Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'Windows'" -All -EA Stop
    }
}
catch {
    Write-Status "Failed to retrieve managed devices: $($_.Exception.Message)" "ERROR"
    return
}

if (-not $devices -or $devices.Count -eq 0) {
    Write-Status "No matching Windows managed devices found." "WARN"
    return
}
Write-Status "Retrieved $($devices.Count) Windows managed device(s)." "OK"

# ---------------------------------------------------------------------------
# 2. Pull eSIM-related Settings Catalog policies (download-server method) —
#    identified by name match, since no dedicated typed resource exists for this.
# ---------------------------------------------------------------------------
$eSimPolicies = [System.Collections.Generic.List[object]]::new()
try {
    $allPolicies = Get-MgDeviceManagementConfigurationPolicy -All -EA Stop
    $eSimPolicies.AddRange(@($allPolicies | Where-Object { $_.Name -match "eSIM|eUICC" }))
    Write-Status "Found $($eSimPolicies.Count) Settings Catalog policy(ies) matching 'eSIM'/'eUICC' by name." "INFO"
}
catch {
    Write-Status "Failed to enumerate Settings Catalog policies: $($_.Exception.Message)" "WARN"
}

$eSimPolicyAssignments = @{}
foreach ($p in $eSimPolicies) {
    try {
        $assign = Get-MgDeviceManagementConfigurationPolicyAssignment -DeviceManagementConfigurationPolicyId $p.Id -EA SilentlyContinue
        $eSimPolicyAssignments[$p.Id] = $assign
    }
    catch {
        Write-Status "Could not read assignments for policy '$($p.Name)': $($_.Exception.Message)" "WARN"
    }
}

# ---------------------------------------------------------------------------
# 3. Pull CSV activation-code pools (beta resource) — best-effort, since this
#    is a Graph BETA endpoint and may not be available/stable in all tenants.
# ---------------------------------------------------------------------------
$activationPools = $null
try {
    $uri = "https://graph.microsoft.com/beta/deviceManagement/embeddedSIMActivationCodePools"
    $resp = Invoke-MgGraphRequest -Method GET -Uri $uri -EA Stop
    $activationPools = $resp.value
    Write-Status "Found $($activationPools.Count) CSV activation-code pool(s) via beta Graph endpoint." "INFO"
}
catch {
    Write-Status "Could not query embeddedSIMActivationCodePools (beta endpoint) — this is expected if the tenant has no CSV-method pools configured, or if beta access is restricted. Continuing with Settings Catalog data only. Detail: $($_.Exception.Message)" "WARN"
}

# ---------------------------------------------------------------------------
# 4. Build per-device report
# ---------------------------------------------------------------------------
$results = [System.Collections.Generic.List[object]]::new()

foreach ($d in $devices) {
    $result = [PSCustomObject]@{
        DeviceName              = $d.DeviceName
        DeviceId                = $d.Id
        Model                   = $d.Model
        Manufacturer             = $d.Manufacturer
        OSVersion                = $d.OsVersion
        LastSyncDateTime         = $d.LastSyncDateTime
        LikelyEligible_DownloadServerMethod = $false
        DownloadServerPolicyAssigned        = $false
        DownloadServerPolicyName            = ""
        DownloadServerAssignmentStatus      = "Not assigned / unknown"
        CSVPoolDataAvailable                = [bool]$activationPools
        Notes                                = ""
    }

    # Windows 11 heuristic check (download-server method requires Windows 11)
    if ($d.OsVersion -and $d.OsVersion -match "^(11\.|10\.0\.2[2-9]\d{3})") {
        $result.LikelyEligible_DownloadServerMethod = $true
    }
    else {
        $result.Notes += "OS version does not clearly indicate Windows 11 — download-server method requires Windows 11. "
    }

    # Cross-reference eSIM Settings Catalog policy assignment against this device's
    # Azure AD device ID indirectly is not reliably resolvable via group membership
    # from this script alone (group membership resolution is out of scope for a
    # lightweight read-only audit) — report policy existence/assignment target type
    # instead, and flag for manual group-membership cross-check where relevant.
    foreach ($p in $eSimPolicies) {
        $assignments = $eSimPolicyAssignments[$p.Id]
        if ($assignments) {
            $result.DownloadServerPolicyAssigned = $true
            $result.DownloadServerPolicyName = $p.Name
            $result.DownloadServerAssignmentStatus = "Policy has $($assignments.Count) assignment(s) — cross-check target group membership manually for this device"
        }
    }

    if (-not $result.LikelyEligible_DownloadServerMethod -and $result.DownloadServerPolicyAssigned) {
        $result.Notes += "WARNING: eSIM download-server policy exists in tenant but this device does not appear to be Windows 11 — confirm this device isn't incorrectly targeted (see eSIM-B.md Fix 5). "
    }

    $results.Add($result)
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
$results | Format-Table DeviceName, OSVersion, LikelyEligible_DownloadServerMethod, DownloadServerPolicyAssigned, LastSyncDateTime -AutoSize
$results | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Exported $($results.Count) device result(s) to $ExportPath" "OK"

$flagged = ($results | Where-Object { $_.Notes -match "WARNING" }).Count
if ($flagged -gt 0) {
    Write-Status "$flagged device(s) flagged with a possible OS-version/method mismatch — review Notes column." "WARN"
}

Write-Status "Reminder: this script confirms Intune-side policy/pool delivery status only. It cannot confirm actual eSIM profile activation on the device's eUICC — that is only observable locally on the device (Settings > Network & Internet > Cellular > Manage eSIM profiles) or via the mobile operator. See eSIM-A.md Layer 4/5 for why this boundary exists." "INFO"
