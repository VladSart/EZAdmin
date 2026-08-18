<#
.SYNOPSIS
    Audits the Graph-derivable subset of Surface Management Portal data: Surface-model device
    inventory/compliance/encryption/storage/Windows-11-eligibility, and role-assignment
    correctness for the Microsoft Hardware Warranty Administrator/Specialist + Global Reader
    co-requirement.

.DESCRIPTION
    Companion to SurfaceManagementPortal-A.md and SurfaceManagementPortal-B.md. The portal
    itself has no comprehensive Graph API for its warranty/coverage/support-request/service-order
    data — this script deliberately does NOT attempt to reproduce that. Instead it reports:

    - Inventory of every device with Model containing 'Surface': compliance state, encryption
      state, enrollment/last-sync timestamps (used to flag the "enrolled but never signed into"
      gap that explains an empty-looking portal entry per SurfaceManagementPortal-A.md's data
      population trigger).
    - NONCOMPLIANT_SURFACE_DEVICE — mirrors the portal's own "Devices not compliant" Insight card.
    - NOT_ENCRYPTED_SURFACE_DEVICE — mirrors "Devices not encrypted."
    - LOW_STORAGE_SURFACE_DEVICE — mirrors "Devices with less than 10% storage" (threshold
      configurable via -LowStoragePercentThreshold).
    - NO_FIRST_SIGNIN_SIGNAL — flags devices where LastSyncDateTime is at/near EnrolledDateTime,
      i.e. no meaningful post-enrollment check-in gap — the most common root cause of "portal
      shows this device with no data" tickets (SurfaceManagementPortal-B.md Fix 2). This is a
      proxy signal only; it cannot confirm actual end-user sign-in, only check-in cadence.
    - HARDWARE_WARRANTY_ROLE_MISSING_GLOBAL_READER — the headline finding from this topic's
      research: Microsoft Hardware Warranty Administrator/Specialist holders who do NOT also
      hold Global Reader, which silently leaves Surface Management Portal underpowered for that
      admin with no distinct error message (SurfaceManagementPortal-B.md Fix 1).
    - GLOBAL_ADMIN_USED_FOR_WARRANTY_TASK — informational flag for Global Admin holders who ALSO
      hold no scoped Hardware Warranty role, suggesting Global Admin may be the only path in use
      for this task — a least-privilege improvement candidate per Playbook 2, not a hard finding.

    Does NOT check: warranty/protection-plan coverage status, support-request or service-order
    state/history, Insights "Devices not registered" or "Devices eligible for optional coverage"
    (both require the portal's own warranty backend, no Graph equivalent exists), Security Copilot
    plugin enablement state (no Graph/PowerShell read exists for Security Copilot plugin state as
    of this writing), or Surface API Management Service entitlement data (separate product, out of
    scope). These gaps are enumerated explicitly in the summary output rather than silently omitted.

    Does NOT perform any remediation, role-assignment, or device configuration change —
    read-only audit only.

.PARAMETER LowStoragePercentThreshold
    Percentage of free storage below which a device is flagged LOW_STORAGE_SURFACE_DEVICE.
    Default: 10 — matches the portal's own documented "Devices with less than 10% storage" Insight.

.PARAMETER StaleSignalHours
    Hours of gap between EnrolledDateTime and LastSyncDateTime below which a device is flagged
    NO_FIRST_SIGNIN_SIGNAL (i.e., check-ins are too close together to represent real post-enrollment
    usage). Default: 24.

.PARAMETER ExportPath
    Directory to write CSV reports to. Default: current directory.

.EXAMPLE
    .\Get-SurfaceManagementPortalAudit.ps1
    Runs the full device + role-assignment audit with default thresholds and exports CSVs to the
    current directory.

.EXAMPLE
    .\Get-SurfaceManagementPortalAudit.ps1 -LowStoragePercentThreshold 15 -StaleSignalHours 48 -ExportPath "C:\Reports"
    Runs the audit with a wider storage-headroom threshold and a longer first-signin grace window.

.NOTES
    Requires: Microsoft.Graph.DeviceManagement, Microsoft.Graph.Identity.DirectoryManagement,
    Microsoft.Graph.Users modules.
    Requires scopes: DeviceManagementManagedDevices.Read.All, RoleManagement.Read.Directory,
    User.Read.All (for resolving role-holder display names/UPNs).
    Run as: Any account/service principal holding the scopes above — no elevated local rights
    needed, this is a Graph-only read operation.
    Safe: Yes — entirely read-only, makes no role, device, or configuration changes.
    Written for Windows PowerShell 5.1 compatibility (no PS7-only syntax used).
#>

#requires -Modules Microsoft.Graph.DeviceManagement, Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Users

[CmdletBinding()]
param(
    [int]$LowStoragePercentThreshold = 10,
    [int]$StaleSignalHours = 24,
    [string]$ExportPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Verifying Graph connection and scopes..."
$context = Get-MgContext
if (-not $context) {
    Write-Status "Not connected to Microsoft Graph. Run Connect-MgGraph first with scopes: DeviceManagementManagedDevices.Read.All, RoleManagement.Read.Directory, User.Read.All" "ERROR"
    throw "Not connected to Microsoft Graph."
}

$requiredScopes = @("DeviceManagementManagedDevices.Read.All", "RoleManagement.Read.Directory", "User.Read.All")
$missingScopes = $requiredScopes | Where-Object { $_ -notin $context.Scopes }
if ($missingScopes) {
    Write-Status "Missing recommended scopes: $($missingScopes -join ', '). Some checks may fail or return partial data." "WARN"
}

if (-not (Test-Path $ExportPath)) {
    New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null
}
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$findings = [System.Collections.Generic.List[object]]::new()

# ---------------------------------------------------------------------------
# Detect: Surface-model device inventory
# ---------------------------------------------------------------------------
Write-Status "Enumerating devices with Model containing 'Surface'..."
$surfaceDevices = Get-MgDeviceManagementManagedDevice -Filter "contains(model,'Surface')" -All

if (-not $surfaceDevices -or $surfaceDevices.Count -eq 0) {
    Write-Status "No Surface-model devices found in this tenant. Surface Management Portal will not appear in the Intune admin center until at least one enrolls (SurfaceManagementPortal-B.md Fix 1)." "WARN"
} else {
    Write-Status "Found $($surfaceDevices.Count) Surface-model device(s)." "OK"
}

# ---------------------------------------------------------------------------
# Execute: device-level Insights proxy checks
# ---------------------------------------------------------------------------
$deviceReport = [System.Collections.Generic.List[object]]::new()
$staleThreshold = New-TimeSpan -Hours $StaleSignalHours

foreach ($device in $surfaceDevices) {

    $isNonCompliant = $device.ComplianceState -ne "compliant"
    $isNotEncrypted = $device.IsEncrypted -eq $false
    $freeStoragePercent = $null
    if ($device.TotalStorageSpaceInBytes -and $device.TotalStorageSpaceInBytes -gt 0 -and $device.FreeStorageSpaceInBytes) {
        $freeStoragePercent = [math]::Round((($device.FreeStorageSpaceInBytes / $device.TotalStorageSpaceInBytes) * 100), 1)
    }
    $isLowStorage = $null -ne $freeStoragePercent -and $freeStoragePercent -lt $LowStoragePercentThreshold

    $noFirstSignin = $false
    if ($device.EnrolledDateTime -and $device.LastSyncDateTime) {
        $gap = $device.LastSyncDateTime - $device.EnrolledDateTime
        $noFirstSignin = $gap -lt $staleThreshold
    }

    if ($isNonCompliant) {
        $findings.Add([PSCustomObject]@{
            Finding    = "NONCOMPLIANT_SURFACE_DEVICE"
            DeviceName = $device.DeviceName
            SerialNumber = $device.SerialNumber
            DeviceId   = $device.Id
            Detail     = "ComplianceState is '$($device.ComplianceState)'. Mirrors the portal's own 'Devices not compliant' Insight card."
        })
    }
    if ($isNotEncrypted) {
        $findings.Add([PSCustomObject]@{
            Finding    = "NOT_ENCRYPTED_SURFACE_DEVICE"
            DeviceName = $device.DeviceName
            SerialNumber = $device.SerialNumber
            DeviceId   = $device.Id
            Detail     = "IsEncrypted = false. Mirrors the portal's own 'Devices not encrypted' Insight card."
        })
    }
    if ($isLowStorage) {
        $findings.Add([PSCustomObject]@{
            Finding    = "LOW_STORAGE_SURFACE_DEVICE"
            DeviceName = $device.DeviceName
            SerialNumber = $device.SerialNumber
            DeviceId   = $device.Id
            Detail     = "Free storage ~$freeStoragePercent% (threshold: <$LowStoragePercentThreshold%). Mirrors the portal's own 'Devices with less than 10% storage' Insight card (threshold configurable here via -LowStoragePercentThreshold)."
        })
    }
    if ($noFirstSignin) {
        $findings.Add([PSCustomObject]@{
            Finding    = "NO_FIRST_SIGNIN_SIGNAL"
            DeviceName = $device.DeviceName
            SerialNumber = $device.SerialNumber
            DeviceId   = $device.Id
            Detail     = "LastSyncDateTime is within $StaleSignalHours hours of EnrolledDateTime — no meaningful post-enrollment check-in gap detected. This is a PROXY signal for 'user has not signed in yet,' the most common cause of an empty-looking Surface Management Portal entry (SurfaceManagementPortal-B.md Fix 2) — it cannot confirm actual end-user sign-in, only check-in cadence."
        })
    }

    $deviceReport.Add([PSCustomObject]@{
        DeviceName          = $device.DeviceName
        SerialNumber        = $device.SerialNumber
        DeviceId            = $device.Id
        Model               = $device.Model
        ComplianceState     = $device.ComplianceState
        IsEncrypted         = $device.IsEncrypted
        FreeStoragePercent  = $freeStoragePercent
        EnrolledDateTime    = $device.EnrolledDateTime
        LastSyncDateTime    = $device.LastSyncDateTime
        UserPrincipalName   = $device.UserPrincipalName
        NonCompliant        = $isNonCompliant
        NotEncrypted        = $isNotEncrypted
        LowStorage          = $isLowStorage
        NoFirstSigninSignal = $noFirstSignin
    })
}

# ---------------------------------------------------------------------------
# Execute: role-assignment correctness — the Global Reader co-requirement
# ---------------------------------------------------------------------------
Write-Status "Checking Microsoft Hardware Warranty Administrator/Specialist + Global Reader co-assignment..."

# Verified template IDs (Microsoft Entra built-in roles reference, cross-checked live):
#   Global Administrator                       62e90394-69f5-4237-9190-012177145e10
#   Global Reader                              f2ef992c-3afb-46b9-b7cf-a126ee74c451
#   Microsoft Hardware Warranty Administrator   1501b917-7653-4ff9-a4b5-203eaf33784f
#   Microsoft Hardware Warranty Specialist      281fe777-fb20-4fbb-b7a3-ccebce5b0d96
$roleIds = @{
    GlobalAdministrator     = "62e90394-69f5-4237-9190-012177145e10"
    GlobalReader            = "f2ef992c-3afb-46b9-b7cf-a126ee74c451"
    HardwareWarrantyAdmin   = "1501b917-7653-4ff9-a4b5-203eaf33784f"
    HardwareWarrantySpec    = "281fe777-fb20-4fbb-b7a3-ccebce5b0d96"
}

function Get-RoleHolderIds {
    param([string]$RoleDefinitionId)
    try {
        Get-MgRoleManagementDirectoryRoleAssignment -Filter "roleDefinitionId eq '$RoleDefinitionId'" -All -ErrorAction Stop |
            Select-Object -ExpandProperty PrincipalId
    } catch {
        Write-Status "Could not enumerate holders of role $RoleDefinitionId — confirm RoleManagement.Read.Directory scope." "WARN"
        @()
    }
}

$globalReaderHolders  = Get-RoleHolderIds -RoleDefinitionId $roleIds.GlobalReader
$hwaHolders           = Get-RoleHolderIds -RoleDefinitionId $roleIds.HardwareWarrantyAdmin
$hwsHolders           = Get-RoleHolderIds -RoleDefinitionId $roleIds.HardwareWarrantySpec
$globalAdminHolders   = Get-RoleHolderIds -RoleDefinitionId $roleIds.GlobalAdministrator

$roleReport = [System.Collections.Generic.List[object]]::new()

foreach ($principalId in ($hwaHolders + $hwsHolders | Select-Object -Unique)) {
    $roleName = if ($hwaHolders -contains $principalId) { "Microsoft Hardware Warranty Administrator" } else { "Microsoft Hardware Warranty Specialist" }
    $hasGlobalReader = $globalReaderHolders -contains $principalId
    $upn = $null
    try { $upn = (Get-MgUser -UserId $principalId -ErrorAction Stop).UserPrincipalName } catch { $upn = "<could not resolve principal $principalId — may be a group or service principal>" }

    if (-not $hasGlobalReader) {
        $findings.Add([PSCustomObject]@{
            Finding    = "HARDWARE_WARRANTY_ROLE_MISSING_GLOBAL_READER"
            DeviceName = $null
            SerialNumber = $null
            DeviceId   = $principalId
            Detail     = "$upn holds '$roleName' without also holding Global Reader. On Surface Management Portal specifically, this combination is required — without it the portal will silently underperform (missing warranty/support visibility) rather than deny access outright (SurfaceManagementPortal-B.md Fix 1)."
        })
    }

    $roleReport.Add([PSCustomObject]@{
        PrincipalId    = $principalId
        UserPrincipalName = $upn
        Role           = $roleName
        HasGlobalReader = $hasGlobalReader
    })
}

foreach ($principalId in $globalAdminHolders) {
    if ($hwaHolders -notcontains $principalId -and $hwsHolders -notcontains $principalId) {
        $upn = $null
        try { $upn = (Get-MgUser -UserId $principalId -ErrorAction Stop).UserPrincipalName } catch { $upn = "<could not resolve principal $principalId — may be a group or service principal>" }
        $findings.Add([PSCustomObject]@{
            Finding    = "GLOBAL_ADMIN_USED_FOR_WARRANTY_TASK"
            DeviceName = $null
            SerialNumber = $null
            DeviceId   = $principalId
            Detail     = "$upn holds Global Administrator and no scoped Hardware Warranty role — informational only, may indicate Global Admin is being used for Surface warranty/service tasks where a narrower role would suffice (SurfaceManagementPortal-A.md Playbook 2). Not a hard finding; confirm actual usage before recommending a change."
        })
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Status "`n=== SUMMARY ===" "OK"
Write-Status "Surface-model devices enrolled: $($surfaceDevices.Count)"
Write-Status "Noncompliant: $(($deviceReport | Where-Object NonCompliant).Count)"
Write-Status "Not encrypted: $(($deviceReport | Where-Object NotEncrypted).Count)"
Write-Status "Low storage (<$LowStoragePercentThreshold%): $(($deviceReport | Where-Object LowStorage).Count)"
Write-Status "No first-signin signal (proxy): $(($deviceReport | Where-Object NoFirstSigninSignal).Count)"
Write-Status "Hardware Warranty role holders checked: $($roleReport.Count)"
Write-Status "Missing Global Reader co-assignment: $(($roleReport | Where-Object { -not $_.HasGlobalReader }).Count)"
Write-Status "Total findings: $($findings.Count)" $(if ($findings.Count -gt 0) { "WARN" } else { "OK" })

if ($findings.Count -gt 0) {
    Write-Status "`n=== FINDINGS ===" "WARN"
    $findings | Format-Table -AutoSize -Wrap
}

Write-Status "`nKNOWN GAP — not checked by this script (no Graph API exists):" "WARN"
Write-Status "  - Warranty / protection-plan coverage status (Expired/Covered/Expiring/Eligible)" "WARN"
Write-Status "  - Support-request state/history (Case IDs) and service-order state (replacement/repair)" "WARN"
Write-Status "  - 'Devices not registered' and 'Devices eligible for optional coverage' Insight cards" "WARN"
Write-Status "  - Security Copilot 'Surface Management Portal' plugin enablement state" "WARN"
Write-Status "  - Surface API Management Service entitlement data (separate product)" "WARN"
Write-Status "Verify these manually in the portal per SurfaceManagementPortal-A.md before treating this audit as complete." "WARN"

$deviceReportPath = Join-Path $ExportPath "SurfaceMgmtPortal_DeviceReport_$timestamp.csv"
$roleReportPath   = Join-Path $ExportPath "SurfaceMgmtPortal_RoleReport_$timestamp.csv"
$findingsPath     = Join-Path $ExportPath "SurfaceMgmtPortal_Findings_$timestamp.csv"

$deviceReport | Export-Csv -Path $deviceReportPath -NoTypeInformation
$roleReport   | Export-Csv -Path $roleReportPath -NoTypeInformation
$findings     | Export-Csv -Path $findingsPath -NoTypeInformation

Write-Status "`nReports written to:" "OK"
Write-Status "  $deviceReportPath"
Write-Status "  $roleReportPath"
Write-Status "  $findingsPath"
