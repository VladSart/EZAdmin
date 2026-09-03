<#
.SYNOPSIS
    Audits corporate-owned Android Enterprise devices for eSIM lifecycle eligibility
    (Activate/Remove device actions) against ownership-type-specific version floors.

.DESCRIPTION
    Intune's Android Enterprise eSIM actions (Activate eSIM, Remove eSIM) are gated by
    an ownership-type-specific Android version floor that is NOT uniform: Remove
    requires Android 15+ for corporate-owned fully managed (COBO) and corporate-owned
    dedicated (COSU) devices, but Android 17+ for corporate-owned work profile (COPE)
    devices — see AndroidESIM-A.md for full architecture. This script reads managed
    device inventory read-only and flags, per corporate-owned Android device:

    - Whether the device meets the Activate floor (Android 15+, uniform)
    - Whether the device meets the Remove floor for ITS SPECIFIC ownership type
      (15+ for COBO/COSU, 17+ for COPE)
    - Whether hardware inventory reporting itself is expected to be complete
      (EID requires Android 13+; full ICCID inventory requires Android 15+)
    - Personally owned (BYOD) Android Enterprise devices are explicitly excluded from
      eligibility scoring and reported separately as categorically unsupported

    This script explicitly CANNOT and does not attempt to: activate or remove any eSIM
    (no write action of any kind), confirm live carrier-side activation state, or
    determine current eSIM slot occupancy (Intune itself does not pre-check this before
    an Activate request — see AndroidESIM-B.md Fix 2 — so no read-only proxy for it
    exists here either).

.PARAMETER IncludeBYOD
    Switch. If set, personally owned Android Enterprise devices are included in the
    output (clearly flagged as categorically unsupported) rather than omitted entirely.
    Default: omitted from output.

.PARAMETER ExportPath
    Full path for CSV export. Defaults to
    $env:TEMP\AndroidESIMLifecycleAudit-<date>.csv.

.EXAMPLE
    .\Get-AndroidESIMLifecycleAudit.ps1
    Audits all corporate-owned Android Enterprise devices tenant-wide.

.EXAMPLE
    .\Get-AndroidESIMLifecycleAudit.ps1 -IncludeBYOD
    Also lists personally owned Android devices, flagged as unsupported, for a complete
    fleet inventory rather than a scoped eligibility report.

.NOTES
    Read-only, no remediation. Requires an interactive or app-only Microsoft Graph
    connection with at least DeviceManagementManagedDevices.Read.All (Connect-MgGraph is
    NOT called by this script — connect first with the scopes appropriate to your
    environment). Requires the Microsoft.Graph.DeviceManagement and
    Microsoft.Graph.Authentication modules. Android Enterprise ownership sub-type
    (COBO vs. COSU vs. COPE specifically, as opposed to the broader
    ManagedDeviceOwnerType 'company' vs. 'personal' split) is not exposed as a single
    clean Graph property on managedDevice as of this writing — this script infers the
    sub-type from AndroidDeviceOwnerType/enrollment-profile naming heuristics where
    available and explicitly flags devices where the sub-type could not be determined,
    since the Remove-action version floor depends on getting this right.
#>
[CmdletBinding()]
param(
    [switch]$IncludeBYOD,
    [string]$ExportPath = "$env:TEMP\AndroidESIMLifecycleAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-AndroidMajorVersion {
    param([string]$OSVersion)
    if ([string]::IsNullOrWhiteSpace($OSVersion)) { return $null }
    $match = [regex]::Match($OSVersion, '^\d+')
    if ($match.Success) { return [int]$match.Value }
    return $null
}

try {
    $context = Get-MgContext
    if (-not $context) {
        throw "Not connected to Microsoft Graph. Run Connect-MgGraph -Scopes 'DeviceManagementManagedDevices.Read.All' first."
    }
    Write-Status "Connected to tenant: $($context.TenantId)" "OK"
}
catch {
    Write-Status "Graph connection check failed: $_" "ERROR"
    throw
}

Write-Status "Enumerating managed Android devices..."
$androidDevices = @()
try {
    $androidDevices = Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'Android'" -All -ErrorAction Stop
}
catch {
    Write-Status "Failed to enumerate Android devices: $_" "ERROR"
    throw
}

Write-Status "Found $($androidDevices.Count) Android device(s) tenant-wide." "OK"

$results = @()
$byodCount = 0

foreach ($device in $androidDevices) {
    $isCorporate = $device.ManagedDeviceOwnerType -eq 'company'

    if (-not $isCorporate) {
        $byodCount++
        if ($IncludeBYOD) {
            $results += [PSCustomObject]@{
                DeviceName        = $device.DeviceName
                OwnerType         = $device.ManagedDeviceOwnerType
                InferredSubType   = "N/A (personally owned)"
                OSVersion         = $device.OSVersion
                ActivateEligible  = "UNSUPPORTED (BYOD)"
                RemoveEligible    = "UNSUPPORTED (BYOD)"
                HardwareInventoryComplete = "N/A"
                LastSyncDateTime  = $device.LastSyncDateTime
            }
        }
        continue
    }

    $majorVersion = Get-AndroidMajorVersion -OSVersion $device.OSVersion

    # Heuristic sub-type inference: Android Enterprise enrollment profile naming and
    # device enrollment type are the closest available signals; a clean, dedicated
    # COBO/COSU/COPE property is not exposed on managedDevice as of this writing.
    $enrollmentProfile = $device.EnrollmentProfileName
    $inferredSubType = "Unknown (verify manually)"
    if ($enrollmentProfile -match 'dedicated|COSU|kiosk') { $inferredSubType = "COSU (inferred)" }
    elseif ($enrollmentProfile -match 'work ?profile|COPE') { $inferredSubType = "COPE (inferred)" }
    elseif ($enrollmentProfile -match 'fully ?managed|COBO') { $inferredSubType = "COBO (inferred)" }

    $activateEligible = if ($majorVersion -ge 15) { "Yes" } elseif ($majorVersion) { "No (needs 15+)" } else { "Unknown (no OS version)" }

    $removeEligible = "Unknown (sub-type not confirmed — verify manually)"
    if ($majorVersion) {
        switch -Regex ($inferredSubType) {
            'COPE'          { $removeEligible = if ($majorVersion -ge 17) { "Yes" } else { "No (COPE needs 17+)" } }
            'COBO|COSU'     { $removeEligible = if ($majorVersion -ge 15) { "Yes" } else { "No (needs 15+)" } }
            default         { $removeEligible = "Cannot determine — confirm ownership sub-type manually, then check 15+ (COBO/COSU) or 17+ (COPE)" }
        }
    }

    $hwComplete = if ($majorVersion -ge 15) { "Full (EID+ICCID)" }
                  elseif ($majorVersion -ge 13) { "Partial (EID only)" }
                  elseif ($majorVersion) { "Minimal/none expected" }
                  else { "Unknown" }

    $results += [PSCustomObject]@{
        DeviceName                = $device.DeviceName
        OwnerType                 = $device.ManagedDeviceOwnerType
        InferredSubType           = $inferredSubType
        OSVersion                 = $device.OSVersion
        ActivateEligible          = $activateEligible
        RemoveEligible            = $removeEligible
        HardwareInventoryComplete = $hwComplete
        LastSyncDateTime          = $device.LastSyncDateTime
    }
}

Write-Host "`n=== Android Enterprise eSIM Lifecycle Eligibility ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize

$unknownSubType = ($results | Where-Object { $_.InferredSubType -match 'Unknown' }).Count
if ($unknownSubType -gt 0) {
    Write-Status "$unknownSubType corporate-owned device(s) have an unconfirmed COBO/COSU/COPE sub-type — Remove-action eligibility CANNOT be trusted from this script alone for these. Verify sub-type manually in the admin center before acting." "WARN"
}
if ($byodCount -gt 0) {
    $note = if ($IncludeBYOD) { "listed above, flagged UNSUPPORTED" } else { "excluded from output — rerun with -IncludeBYOD to list them" }
    Write-Status "$byodCount personally owned (BYOD) Android device(s) found — $note. eSIM actions are unconditionally unsupported for these." "WARN"
}

$results | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Full report exported to: $ExportPath" "OK"
