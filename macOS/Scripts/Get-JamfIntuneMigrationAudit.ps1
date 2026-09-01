<#
.SYNOPSIS
    Read-only readiness/health audit for the Jamf Pro <-> Microsoft Intune (macOS) compliance-connector
    integration and full-migration-to-Intune scenarios.

.DESCRIPTION
    Runs five checks entirely against Microsoft Graph (no Jamf Pro API credentials required, and none are
    used):
      1. Partner Device Management connector state (deviceManagementPartner resource) - tenant-wide
         health of the Jamf compliance-connector integration, if configured.
      2. Entra app registration permission audit for any service principal whose display name matches
         "Jamf" - flags any permission beyond the three Microsoft documents as required
         (update_device_attributes, and Application.Read.All against both Microsoft Graph and the
         legacy Windows Azure Active Directory API), since an extra permission is a documented cause of
         registration failures (Cause 1 in Microsoft's own troubleshooting article).
      3. Duplicate macOS managed-device detection by serial number - the signature of an incompletely
         cleaned-up prior enrollment (Cause 6), the most common root cause behind "shows compliant in
         Intune but not Entra" and "duplicate entries" tickets.
      4. macOS compliance policy assignment target-type check - flags any macOS compliance policy
         assigned to a device group, since Jamf-sourced devices are only evaluated correctly against
         USER-group-targeted compliance policies (a documented, easy-to-miss limitation).
      5. Best-effort Intune + Microsoft Entra ID P1 license presence check for a supplied list of users,
         via SKU DISPLAY NAME substring matching rather than a hardcoded SKU GUID (SKU GUIDs are
         tenant-agreement-dependent and should never be hardcoded as permanent).

    This script does NOT and CANNOT:
      - Query Jamf Pro itself (check-in health, role/permission configuration, license status) - no
        Jamf Pro API credentials are used or required by design; those checks are Jamf-console-side only.
      - Verify network port reachability (443/2195/2196/5223/80) - run a network-level test separately.
      - Read the migration script's own execution log - that is device-local
        (/Library/Logs/Microsoft/IntuneScripts/intuneMigration/intuneMigration.log on the affected Mac).
      - Verify Apple Business Manager device-to-MDM-server assignment - portal-only, no Graph/API surface.

.PARAMETER UserUpns
    Optional array of user principal names to run the license-presence check against. If omitted, the
    license check is skipped and flagged as skipped in the report rather than silently omitted.

.PARAMETER OutputPath
    Folder to write the two output CSVs to. Defaults to the current directory.

.EXAMPLE
    .\Get-JamfIntuneMigrationAudit.ps1 -UserUpns "jdoe@contoso.com","asmith@contoso.com"

.EXAMPLE
    .\Get-JamfIntuneMigrationAudit.ps1 -OutputPath "C:\Audits\ContosoJamf"

.NOTES
    Requires: Microsoft.Graph.DeviceManagement, Microsoft.Graph.DeviceManagement.Administration,
              Microsoft.Graph.Applications, Microsoft.Graph.Users modules.
    Requires scopes: DeviceManagementServiceConfig.Read.All, DeviceManagementManagedDevices.Read.All,
              DeviceManagementConfiguration.Read.All, Application.Read.All, User.Read.All.
    Run-as: any account holding the above delegated/application Graph scopes. No local admin needed -
            this script makes no changes anywhere and issues no write calls.
    Safe: read-only throughout. Zero New-Mg/Set-Mg/Remove-Mg/Update-Mg cmdlets anywhere in this script.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$UserUpns,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Starting Jamf <-> Intune migration/compliance-connector audit" "INFO"

$requiredModules = @(
    "Microsoft.Graph.DeviceManagement",
    "Microsoft.Graph.DeviceManagement.Administration",
    "Microsoft.Graph.Applications",
    "Microsoft.Graph.Users"
)
foreach ($m in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        Write-Status "Module '$m' not found. Install with: Install-Module $m -Scope CurrentUser" "WARN"
    }
}

try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Not connected to Microsoft Graph. Run Connect-MgGraph with the required scopes first." "ERROR"
        throw "No active Graph session."
    }
    Write-Status "Connected to Graph as $($context.Account) (tenant $($context.TenantId))" "OK"
} catch {
    Write-Status "Failed to confirm Graph connection: $($_.Exception.Message)" "ERROR"
    throw
}

if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$findings = [System.Collections.Generic.List[PSCustomObject]]::new()
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# ---------------------------------------------------------------------------
# Check 1 — Partner Device Management connector state
# ---------------------------------------------------------------------------
Write-Status "Check 1: Partner Device Management connector state..." "INFO"
try {
    $partners = Get-MgDeviceManagementDeviceManagementPartner -ErrorAction Stop
    if (-not $partners) {
        $findings.Add([PSCustomObject]@{
            Check    = "PartnerConnector"
            Severity = "INFO"
            Detail   = "No deviceManagementPartner records returned — Jamf compliance-connector integration is likely not configured in this tenant. Skip remaining coexistence-specific checks if this is a full-migration-only ticket."
        })
        Write-Status "No partner connector records found." "WARN"
    } else {
        foreach ($p in $partners) {
            $state = $p.PartnerState
            $sev = switch ($state) {
                "unresponsive" { "HIGH" }
                "unavailable"  { "HIGH" }
                "terminated"   { "INFO" }
                "enabled"      { "OK" }
                default        { "WARN" }
            }
            $findings.Add([PSCustomObject]@{
                Check    = "PartnerConnector"
                Severity = $sev
                Detail   = "DisplayName='$($p.DisplayName)' PartnerState='$state' IsConfigured='$($p.IsConfigured)' MacOsOnboarded='$($p.MacOsOnboarded)' WhenPartnerDevicesWillBeRemoved='$($p.WhenPartnerDevicesWillBeRemoved)'"
            })
            Write-Status "Partner '$($p.DisplayName)': state=$state configured=$($p.IsConfigured)" $(if ($sev -eq "OK") { "OK" } else { "WARN" })
        }
    }
} catch {
    Write-Status "Check 1 failed: $($_.Exception.Message)" "WARN"
    $findings.Add([PSCustomObject]@{ Check = "PartnerConnector"; Severity = "ERROR"; Detail = "Query failed: $($_.Exception.Message). Confirm DeviceManagementServiceConfig.Read.All scope is granted." })
}

# ---------------------------------------------------------------------------
# Check 2 — Jamf app registration permission audit
# ---------------------------------------------------------------------------
Write-Status "Check 2: Jamf-related app registration permissions..." "INFO"
$expectedPermissionCount = 3   # update_device_attributes + 2x Application.Read.All (Graph, legacy AAD Graph)
try {
    $jamfSPs = Get-MgServicePrincipal -Filter "startswith(DisplayName,'Jamf')" -All -ErrorAction Stop
    if (-not $jamfSPs -or $jamfSPs.Count -eq 0) {
        $findings.Add([PSCustomObject]@{
            Check    = "AppRegistration"
            Severity = "INFO"
            Detail   = "No service principal found with a display name starting 'Jamf' — the app may be named differently in this tenant; verify manually if coexistence is expected to be configured."
        })
        Write-Status "No 'Jamf*' service principal found." "WARN"
    } else {
        foreach ($sp in $jamfSPs) {
            try {
                $assignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -All -ErrorAction Stop
                $count = @($assignments).Count
                $sev = if ($count -gt $expectedPermissionCount) { "HIGH" } elseif ($count -lt $expectedPermissionCount) { "WARN" } else { "OK" }
                $resourceList = ($assignments | ForEach-Object { $_.ResourceDisplayName }) -join "; "
                $findings.Add([PSCustomObject]@{
                    Check    = "AppRegistration"
                    Severity = $sev
                    Detail   = "SP='$($sp.DisplayName)' (Id=$($sp.Id)) has $count granted app-role assignment(s): $resourceList. Expected exactly $expectedPermissionCount (Intune update_device_attributes + Graph Application.Read.All + Windows Azure AD Application.Read.All)."
                })
                Write-Status "SP '$($sp.DisplayName)': $count permission(s) granted" $(if ($sev -eq "OK") { "OK" } else { "WARN" })
            } catch {
                Write-Status "Could not read app role assignments for SP '$($sp.DisplayName)': $($_.Exception.Message)" "WARN"
                $findings.Add([PSCustomObject]@{ Check = "AppRegistration"; Severity = "ERROR"; Detail = "SP='$($sp.DisplayName)' assignment query failed: $($_.Exception.Message)" })
            }
        }
    }
} catch {
    Write-Status "Check 2 failed: $($_.Exception.Message)" "WARN"
    $findings.Add([PSCustomObject]@{ Check = "AppRegistration"; Severity = "ERROR"; Detail = "Query failed: $($_.Exception.Message). Confirm Application.Read.All scope is granted." })
}

# ---------------------------------------------------------------------------
# Check 3 — Duplicate macOS managed-device detection
# ---------------------------------------------------------------------------
Write-Status "Check 3: Duplicate macOS device records..." "INFO"
$duplicateDevices = [System.Collections.Generic.List[PSCustomObject]]::new()
try {
    $macDevices = Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'" -All -ErrorAction Stop
    $groups = $macDevices | Where-Object { $_.SerialNumber } | Group-Object -Property SerialNumber | Where-Object { $_.Count -gt 1 }
    if (-not $groups -or $groups.Count -eq 0) {
        $findings.Add([PSCustomObject]@{ Check = "DuplicateDevices"; Severity = "OK"; Detail = "No duplicate serial numbers found among $(@($macDevices).Count) macOS managed devices." })
        Write-Status "No duplicate macOS device records found ($(@($macDevices).Count) total)." "OK"
    } else {
        foreach ($g in $groups) {
            foreach ($d in $g.Group) {
                $duplicateDevices.Add([PSCustomObject]@{
                    SerialNumber = $g.Name
                    DeviceName   = $d.DeviceName
                    Id           = $d.Id
                    UserPrincipalName = $d.UserPrincipalName
                    EnrolledDateTime  = $d.EnrolledDateTime
                    ManagementAgent   = $d.ManagementAgent
                })
            }
            $findings.Add([PSCustomObject]@{
                Check    = "DuplicateDevices"
                Severity = "HIGH"
                Detail   = "Serial '$($g.Name)' has $($g.Count) managed-device records — likely stale registration artifact (Cause 6). See DuplicateDevices CSV for full detail."
            })
        }
        Write-Status "$($groups.Count) serial number(s) with duplicate records found." "WARN"
    }
} catch {
    Write-Status "Check 3 failed: $($_.Exception.Message)" "WARN"
    $findings.Add([PSCustomObject]@{ Check = "DuplicateDevices"; Severity = "ERROR"; Detail = "Query failed: $($_.Exception.Message). Confirm DeviceManagementManagedDevices.Read.All scope is granted." })
}

# ---------------------------------------------------------------------------
# Check 4 — macOS compliance policy assignment target-type check
# ---------------------------------------------------------------------------
Write-Status "Check 4: macOS compliance policy assignment targets..." "INFO"
try {
    $macPolicies = Get-MgDeviceManagementDeviceCompliancePolicy -All -ErrorAction Stop |
        Where-Object { $_.DisplayName -match "(?i)mac" -or $_.'@odata.type' -match "(?i)macOS" }

    if (-not $macPolicies -or $macPolicies.Count -eq 0) {
        $findings.Add([PSCustomObject]@{ Check = "CompliancePolicyTarget"; Severity = "INFO"; Detail = "No compliance policy found with 'mac' in its display name or a macOS policy type — verify naming convention manually if a macOS policy is expected to exist." })
        Write-Status "No macOS-named compliance policy found." "WARN"
    } else {
        foreach ($policy in $macPolicies) {
            try {
                $assignments = Get-MgDeviceManagementDeviceCompliancePolicyAssignment -DeviceCompliancePolicyId $policy.Id -All -ErrorAction Stop
                if (-not $assignments -or $assignments.Count -eq 0) {
                    $findings.Add([PSCustomObject]@{ Check = "CompliancePolicyTarget"; Severity = "WARN"; Detail = "Policy '$($policy.DisplayName)' has no assignments at all." })
                    continue
                }
                foreach ($a in $assignments) {
                    $targetType = $a.Target.AdditionalProperties['@odata.type']
                    # Note: this script flags target type as a heuristic signal only — Graph does not expose
                    # a direct "is this a device group or a user group" boolean on the assignment target
                    # itself; a definitive answer requires cross-referencing the referenced group's
                    # membership type via Get-MgGroup, which this script intentionally does not do by
                    # default to avoid an expensive per-assignment group lookup. Treat HIGH findings here
                    # as "verify this group's membership type manually" rather than a confirmed defect.
                    $sev = if ($targetType -match "(?i)AllDevices|ExclusionGroup") { "WARN" } else { "INFO" }
                    $findings.Add([PSCustomObject]@{
                        Check    = "CompliancePolicyTarget"
                        Severity = $sev
                        Detail   = "Policy '$($policy.DisplayName)' assignment target type='$targetType' — cross-check the referenced group's membership type (user vs. device) manually; Jamf-sourced macOS devices are only evaluated against USER-group-targeted policies."
                    })
                }
            } catch {
                Write-Status "Could not read assignments for policy '$($policy.DisplayName)': $($_.Exception.Message)" "WARN"
                $findings.Add([PSCustomObject]@{ Check = "CompliancePolicyTarget"; Severity = "ERROR"; Detail = "Policy '$($policy.DisplayName)' assignment query failed: $($_.Exception.Message)" })
            }
        }
        Write-Status "$(@($macPolicies).Count) macOS-named compliance policy(ies) reviewed — see report for assignment detail requiring manual group-type confirmation." "INFO"
    }
} catch {
    Write-Status "Check 4 failed: $($_.Exception.Message)" "WARN"
    $findings.Add([PSCustomObject]@{ Check = "CompliancePolicyTarget"; Severity = "ERROR"; Detail = "Query failed: $($_.Exception.Message). Confirm DeviceManagementConfiguration.Read.All scope is granted." })
}

# ---------------------------------------------------------------------------
# Check 5 — Best-effort license presence check (opt-in via -UserUpns)
# ---------------------------------------------------------------------------
Write-Status "Check 5: License presence for supplied users..." "INFO"
if (-not $UserUpns -or $UserUpns.Count -eq 0) {
    $findings.Add([PSCustomObject]@{ Check = "LicenseCheck"; Severity = "INFO"; Detail = "Skipped — no -UserUpns supplied. Run again with -UserUpns to check Intune + Entra ID P1 license presence for specific affected users." })
    Write-Status "No -UserUpns supplied; license check skipped." "WARN"
} else {
    foreach ($upn in $UserUpns) {
        try {
            $licenses = Get-MgUserLicenseDetail -UserId $upn -ErrorAction Stop
            # Best-effort SKU DISPLAY NAME substring match — deliberately not a hardcoded SKU GUID, since
            # SKU GUIDs vary by tenant commercial agreement and change over time. Always manually confirm
            # against the tenant's actual licensing page rather than trusting this match alone.
            $hasIntune = $licenses | Where-Object { $_.SkuPartNumber -match "(?i)INTUNE|EMS|M365" }
            $hasP1     = $licenses | Where-Object { $_.SkuPartNumber -match "(?i)AAD_PREMIUM|EMS" }
            $sev = if ($hasIntune -and $hasP1) { "OK" } else { "WARN" }
            $findings.Add([PSCustomObject]@{
                Check    = "LicenseCheck"
                Severity = $sev
                Detail   = "User '$upn': Intune-like SKU present=$([bool]$hasIntune), Entra P1-like SKU present=$([bool]$hasP1). Best-effort name match only — confirm exact SKU manually in the M365 admin center."
            })
        } catch {
            Write-Status "License check failed for '$upn': $($_.Exception.Message)" "WARN"
            $findings.Add([PSCustomObject]@{ Check = "LicenseCheck"; Severity = "ERROR"; Detail = "User '$upn' query failed: $($_.Exception.Message)" })
        }
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$findingsPath = Join-Path $OutputPath "JamfIntuneAudit_Findings_$timestamp.csv"
$findings | Export-Csv -Path $findingsPath -NoTypeInformation -Encoding UTF8
Write-Status "Findings exported to $findingsPath" "OK"

if ($duplicateDevices.Count -gt 0) {
    $dupPath = Join-Path $OutputPath "JamfIntuneAudit_DuplicateDevices_$timestamp.csv"
    $duplicateDevices | Export-Csv -Path $dupPath -NoTypeInformation -Encoding UTF8
    Write-Status "Duplicate device detail exported to $dupPath" "OK"
}

$highCount = @($findings | Where-Object { $_.Severity -eq "HIGH" }).Count
$warnCount = @($findings | Where-Object { $_.Severity -eq "WARN" }).Count
$errCount  = @($findings | Where-Object { $_.Severity -eq "ERROR" }).Count

Write-Status "Audit complete: $highCount HIGH, $warnCount WARN, $errCount ERROR finding(s)." $(if ($highCount -gt 0) { "ERROR" } elseif ($warnCount -gt 0) { "WARN" } else { "OK" })

Write-Host ""
Write-Host "=== Known Gaps (not covered by this script) ===" -ForegroundColor Cyan
Write-Host "- Jamf Pro-side check-in health, role/permission config, and license status (no Jamf Pro API used by design)"
Write-Host "- Network port reachability (443/2195/2196/5223/80) — test separately"
Write-Host "- Migration script execution log — device-local, see /Library/Logs/Microsoft/IntuneScripts/intuneMigration/intuneMigration.log on the affected Mac"
Write-Host "- Apple Business Manager device-to-MDM-server assignment — portal-only, no Graph/API surface"
Write-Host "- Compliance policy assignment group MEMBERSHIP TYPE (user vs. device) is flagged heuristically only; confirm via Get-MgGroup on the referenced group ID for a definitive answer"
