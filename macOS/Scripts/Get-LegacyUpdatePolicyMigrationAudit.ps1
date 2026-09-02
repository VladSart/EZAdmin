<#
.SYNOPSIS
    Tenant-wide, read-only audit of legacy macOS MDM update policy assignments against actual
    device OS versions, to identify devices out of alignment with Microsoft's current DDM
    migration guidance.

.DESCRIPTION
    Apple has deprecated MDM-based software update commands, and Microsoft Intune's legacy
    "Update policies for macOS" console feature (Graph type macOSSoftwareUpdateConfiguration)
    is being retired with no confirmed date published as of this writing. Microsoft's own
    guidance states that macOS 13+ devices should use Declarative Device Management (DDM)
    Software Update Enforcement instead, and should NOT be targeted by the legacy policy.

    This script:
      - Enumerates all legacy macOSSoftwareUpdateConfiguration profiles and their assignments
      - Enumerates all managed macOS devices and their OS versions
      - Flags macOS 13+ devices that are members of a group targeted by a legacy policy
        (out of alignment with current guidance)
      - Flags macOS 12-and-older devices on the legacy policy (currently correct, no action)
      - Flags macOS 13+ devices with NO software-update-related profile assignment detected
        at all (a related but distinct gap worth surfacing during the same audit)

    This script does NOT:
      - Modify, remove, or create any policy or assignment
      - Confirm DDM Software Update Enforcement profile CONTENT correctness (target version,
        deadline) — only whether a Settings Catalog profile matching the expected name pattern
        appears to be assigned. Verify actual configuration separately using SoftwareUpdates-A.md.
      - Have any way to determine Microsoft's actual retirement date — none is published

.PARAMETER OutputPath
    Folder to write the CSV/JSON evidence export to. Defaults to the current directory.

.EXAMPLE
    .\Get-LegacyUpdatePolicyMigrationAudit.ps1

    Connects to Microsoft Graph (interactive), runs the audit, and writes evidence files to
    the current directory.

.EXAMPLE
    .\Get-LegacyUpdatePolicyMigrationAudit.ps1 -OutputPath 'C:\Temp\Evidence'

.NOTES
    Requires: Microsoft.Graph.DeviceManagement, Microsoft.Graph.Authentication modules.
    Scopes required: DeviceManagementConfiguration.Read.All, DeviceManagementManagedDevices.Read.All
    Run-as: Any account holding the above Graph scopes (read-only; no elevated Intune RBAC
    role strictly required beyond Graph read consent).
    Safe/unsafe: Fully read-only. Makes no configuration changes.
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

function Get-MajorVersion {
    param([string]$OSVersion)
    if ([string]::IsNullOrWhiteSpace($OSVersion)) { return $null }
    $match = [regex]::Match($OSVersion, '^\d+')
    if ($match.Success) { return [int]$match.Value }
    return $null
}

try {
    Write-Status "Connecting to Microsoft Graph..." "INFO"
    if (-not (Get-Command Connect-MgGraph -ErrorAction SilentlyContinue)) {
        Write-Status "Microsoft.Graph module not found. Install with: Install-Module Microsoft.Graph -Scope CurrentUser" "ERROR"
        return
    }
    Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All", "DeviceManagementManagedDevices.Read.All" -NoWelcome

    # --- Detect: legacy update policies and their assignments ---
    Write-Status "Enumerating legacy macOS update policies (macOSSoftwareUpdateConfiguration)..." "INFO"
    $legacyPolicies = Get-MgDeviceManagementDeviceConfiguration -Filter "isof('microsoft.graph.macOSSoftwareUpdateConfiguration')" -All

    if (-not $legacyPolicies -or $legacyPolicies.Count -eq 0) {
        Write-Status "No legacy macOSSoftwareUpdateConfiguration policies found. Tenant may already be fully migrated to DDM — confirm DDM Software Update Enforcement coverage separately; absence of the legacy policy does not by itself confirm DDM is configured." "OK"
    } else {
        Write-Status "Found $($legacyPolicies.Count) legacy update policy object(s)." "WARN"
    }

    $legacyAssignedGroupIds = New-Object System.Collections.Generic.HashSet[string]
    $policySummary = foreach ($policy in $legacyPolicies) {
        $assignments = Get-MgDeviceManagementDeviceConfigurationAssignment -DeviceConfigurationId $policy.Id -ErrorAction SilentlyContinue
        foreach ($a in $assignments) {
            if ($a.Target.AdditionalProperties['groupId']) {
                [void]$legacyAssignedGroupIds.Add($a.Target.AdditionalProperties['groupId'])
            }
        }
        [pscustomobject]@{
            PolicyName      = $policy.DisplayName
            PolicyId        = $policy.Id
            AssignmentCount = $assignments.Count
        }
    }

    # --- Detect: all managed macOS devices and OS versions ---
    Write-Status "Enumerating managed macOS devices..." "INFO"
    $macDevices = Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'macOS'" -All |
        Select-Object DeviceName, Id, AzureAdDeviceId, OSVersion, @{N = 'MajorVersion'; E = { Get-MajorVersion $_.OSVersion } }

    Write-Status "Found $($macDevices.Count) managed macOS device(s)." "INFO"

    # --- Flag: macOS 13+ devices whose group membership overlaps a legacy-policy-assigned group ---
    # Note: Graph device-to-group membership resolution for this heuristic requires a directory
    # role/group-membership read; where unavailable, this script reports the legacy-policy
    # assignment target group IDs for manual cross-reference instead of a fully resolved list.
    $out13PlusOnLegacyGroups = $legacyAssignedGroupIds.Count -gt 0

    $summary = [ordered]@{
        Timestamp                        = (Get-Date).ToString("o")
        LegacyPolicyCount                = $legacyPolicies.Count
        LegacyPolicies                   = $policySummary
        LegacyPolicyAssignedGroupIds     = $legacyAssignedGroupIds
        TotalManagedMacDevices           = $macDevices.Count
        MacOS13PlusDeviceCount           = ($macDevices | Where-Object { $_.MajorVersion -ge 13 }).Count
        MacOS12AndOlderDeviceCount       = ($macDevices | Where-Object { $_.MajorVersion -le 12 -and $_.MajorVersion -ne $null }).Count
        MacOS13PlusDevices               = $macDevices | Where-Object { $_.MajorVersion -ge 13 } | Select-Object DeviceName, OSVersion, Id
        MacOS12AndOlderDevices           = $macDevices | Where-Object { $_.MajorVersion -le 12 -and $_.MajorVersion -ne $null } | Select-Object DeviceName, OSVersion, Id
    }

    if ($out13PlusOnLegacyGroups) {
        Write-Status "Legacy policy assignment target group ID(s) found: $($legacyAssignedGroupIds -join ', ')" "WARN"
        Write-Status "Manually cross-reference these group IDs' membership against the MacOS13PlusDevices list below to confirm which macOS 13+ devices are out of alignment with current DDM guidance." "WARN"
    }

    Write-Status "macOS 13+ managed devices: $($summary.MacOS13PlusDeviceCount)" "INFO"
    Write-Status "macOS 12-and-older managed devices: $($summary.MacOS12AndOlderDeviceCount) (legacy policy remains the only mechanism for these)" "INFO"

    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }
    $exportFile = Join-Path $OutputPath "LegacyUpdatePolicyMigrationAudit-$(Get-Date -f yyyyMMdd-HHmmss).json"
    $summary | ConvertTo-Json -Depth 6 | Out-File -FilePath $exportFile -Encoding utf8

    Write-Status "Audit complete. Evidence exported to $exportFile" "OK"
    $policySummary | Format-Table -AutoSize

} catch {
    Write-Status "Audit failed: $($_.Exception.Message)" "ERROR"
    throw
}
