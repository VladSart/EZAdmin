<#
.SYNOPSIS
    Audits Windows Autopilot deployment profile assignment for one device or the whole tenant.

.DESCRIPTION
    Graph-based audit built from Autopilot/Troubleshooting/Profile-Not-Assigned-A.md's dependency
    chain: hardware hash registration -> Entra ID device object (devicePhysicalIds) -> dynamic
    group membership -> deployment profile assignment. Covers the runbook's Validation Steps 1-6
    in a single pass.

    Single-device mode (-SerialNumber) walks the full chain for one device and reports exactly
    where assignment is breaking down. Fleet mode (no -SerialNumber, or -All) scans every
    registered Autopilot device and flags devices stuck in notAssigned state, plus tenant-wide
    hygiene issues: duplicate serial registrations and dynamic groups whose devicePhysicalIds
    rule syntax uses the incorrect "[OrderId]" casing (must be "[OrderID]" — see Learning
    Pointers in Profile-Not-Assigned-A.md).

    Read-only. Makes no changes to Group Tags, group membership, or profile assignments — for
    those actions see the Remediation Playbooks in Profile-Not-Assigned-A.md.

.PARAMETER SerialNumber
    Audit a single device by serial number. Walks device -> Entra object -> groups -> profile.

.PARAMETER StaleAfterMinutes
    Devices registered longer ago than this with DeploymentProfileAssignmentStatus still
    "notAssigned" are flagged as STALE_UNASSIGNED. Default 90 (matches the runbook's documented
    end-to-end replication window).

.EXAMPLE
    .\Get-AutopilotProfileAssignmentAudit.ps1 -SerialNumber "PF3ABCDE"

    Diagnoses why a specific device isn't receiving its Autopilot profile.

.EXAMPLE
    .\Get-AutopilotProfileAssignmentAudit.ps1

    Runs a tenant-wide sweep for stale/unassigned devices, duplicates, and bad Group Tag rules.

.NOTES
    Requires: Microsoft.Graph.DeviceManagement, Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement modules.
    Scopes: DeviceManagementServiceConfig.Read.All, Device.Read.All, Group.Read.All
    Companion runbook: Autopilot/Troubleshooting/Profile-Not-Assigned-A.md and Profile-Not-Assigned-B.md
#>

[CmdletBinding()]
param(
    [string]$SerialNumber,
    [int]$StaleAfterMinutes = 90
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
$requiredModules = @("Microsoft.Graph.DeviceManagement", "Microsoft.Graph.Groups", "Microsoft.Graph.Identity.DirectoryManagement")
foreach ($m in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        Write-Status "Required module not installed: $m — run: Install-Module $m -Scope CurrentUser" "ERROR"
        throw "Missing module: $m"
    }
}

if (-not (Get-MgContext)) {
    Write-Status "Connecting to Microsoft Graph..."
    Connect-MgGraph -Scopes "DeviceManagementServiceConfig.Read.All", "Device.Read.All", "Group.Read.All" | Out-Null
}
Write-Status "Connected as: $((Get-MgContext).Account)"

$findings = [System.Collections.Generic.List[object]]::new()
function Add-Finding {
    param([string]$Target, [string]$Flag, [string]$Detail)
    $findings.Add([PSCustomObject]@{ Target = $Target; Flag = $Flag; Detail = $Detail })
}

# ---------------------------------------------------------------------------
# Single-device mode
# ---------------------------------------------------------------------------
if ($SerialNumber) {
    Write-Status "Auditing profile assignment for serial: $SerialNumber"

    $apDevices = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -Filter "contains(serialNumber,'$SerialNumber')" -All
    if (-not $apDevices) {
        Add-Finding $SerialNumber "NOT_REGISTERED" "No Autopilot record found for this serial — hash not uploaded, or uploaded to a different tenant"
        Write-Status "Device not found in Autopilot service" "ERROR"
        $findings | Format-Table -AutoSize
        return
    }

    if (@($apDevices).Count -gt 1) {
        Add-Finding $SerialNumber "DUPLICATE_REGISTRATION" "$(@($apDevices).Count) registrations found for this serial — resolution may be inconsistent"
        Write-Status "$(@($apDevices).Count) duplicate registrations found" "WARN"
    }

    $apDevice = @($apDevices)[0]
    Write-Host "`nGroupTag                : $($apDevice.GroupTag)"
    Write-Host "EnrollmentState         : $($apDevice.EnrollmentState)"
    Write-Host "ProfileAssignmentStatus : $($apDevice.DeploymentProfileAssignmentStatus)"
    Write-Host "AzureADDeviceId         : $($apDevice.AzureActiveDirectoryDeviceId)"

    if ($apDevice.DeploymentProfileAssignmentStatus -ne "assigned") {
        Add-Finding $SerialNumber "PROFILE_NOT_ASSIGNED" "DeploymentProfileAssignmentStatus = $($apDevice.DeploymentProfileAssignmentStatus)"

        if (-not $apDevice.AzureActiveDirectoryDeviceId) {
            Add-Finding $SerialNumber "NO_ENTRA_DEVICE_OBJECT" "No Entra ID device object linked yet — allow up to 20-30 min after hash upload (replication lag)"
        } else {
            $entraDevice = Get-MgDevice -Filter "deviceId eq '$($apDevice.AzureActiveDirectoryDeviceId)'" -ErrorAction SilentlyContinue
            if ($entraDevice) {
                $memberships = Get-MgDeviceMemberOf -DeviceId $entraDevice.Id -ErrorAction SilentlyContinue
                if (-not $memberships) {
                    Add-Finding $SerialNumber "NO_GROUP_MEMBERSHIP" "Entra device object exists but is not a member of any group — dynamic group rule hasn't matched, or Group Tag mismatch"
                } else {
                    $groupNames = ($memberships | ForEach-Object { $_.AdditionalProperties['displayName'] }) -join ', '
                    Add-Finding $SerialNumber "GROUP_MEMBERSHIP_FOUND" "Member of: $groupNames — verify one of these groups has a profile assigned"
                }
            }
        }

        if ($apDevice.GroupTag) {
            $tagGroups = Get-MgGroup -All -ErrorAction SilentlyContinue |
                Where-Object { $_.MembershipRule -match "devicePhysicalIds" -and $_.MembershipRule -match [regex]::Escape($apDevice.GroupTag) }
            if (-not $tagGroups) {
                Add-Finding $SerialNumber "GROUP_TAG_NO_MATCHING_RULE" "GroupTag '$($apDevice.GroupTag)' does not appear in any dynamic group rule — check for typos or case mismatch (case-sensitive)"
            }
        } else {
            Add-Finding $SerialNumber "NO_GROUP_TAG" "Device has no Group Tag set — profile assignment relies on Assigned User or static/'All Devices' group instead"
        }
    } else {
        Write-Status "Profile is assigned — if OOBE still fails, check ESP-Stuck-A.md instead" "OK"
    }
}
# ---------------------------------------------------------------------------
# Fleet mode
# ---------------------------------------------------------------------------
else {
    Write-Status "Running tenant-wide Autopilot profile assignment sweep..."

    $allDevices = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -All
    Write-Status "Retrieved $($allDevices.Count) Autopilot device records"

    # Duplicate serials
    $dupes = $allDevices | Group-Object SerialNumber | Where-Object { $_.Count -gt 1 }
    foreach ($d in $dupes) {
        Add-Finding $d.Name "DUPLICATE_REGISTRATION" "$($d.Count) registrations for this serial"
    }

    # Stale unassigned devices
    $now = Get-Date
    $unassigned = $allDevices | Where-Object { $_.DeploymentProfileAssignmentStatus -ne "assigned" }
    foreach ($u in $unassigned) {
        $lastContact = $u.LastContactedDateTime
        $ageMin = if ($lastContact) { [math]::Round(($now - $lastContact).TotalMinutes, 0) } else { $null }
        if ($ageMin -and $ageMin -gt $StaleAfterMinutes) {
            Add-Finding $u.SerialNumber "STALE_UNASSIGNED" "notAssigned for ~$ageMin min (threshold $StaleAfterMinutes) — GroupTag: '$($u.GroupTag)'"
        }
    }
    Write-Status "$($unassigned.Count) device(s) currently not assigned a profile ($(($unassigned | Where-Object {$_ -in ($allDevices | Where-Object {$_}) }).Count) total checked)"

    # Dynamic groups with case-mismatched [OrderId] vs [OrderID]
    $apGroups = Get-MgGroup -All | Where-Object { $_.MembershipRule -match "devicePhysicalIds" }
    foreach ($g in $apGroups) {
        if ($g.MembershipRule -match "\[OrderId\]" -and $g.MembershipRule -notmatch "\[OrderID\]") {
            Add-Finding $g.DisplayName "GROUP_TAG_CASE_MISMATCH" "Rule uses '[OrderId]' instead of the required '[OrderID]' — rule will never match: $($g.MembershipRule)"
        }
        if ($g.MembershipRuleProcessingState -eq "Paused") {
            Add-Finding $g.DisplayName "GROUP_PROCESSING_PAUSED" "Dynamic group rule processing is Paused — likely too many members; contact Microsoft Support to resume"
        }
    }

    # Profiles with zero assignments
    $profiles = Get-MgDeviceManagementWindowsAutopilotDeploymentProfile -All
    foreach ($p in $profiles) {
        $assignments = Get-MgDeviceManagementWindowsAutopilotDeploymentProfileAssignment -WindowsAutopilotDeploymentProfileId $p.Id -ErrorAction SilentlyContinue
        if (-not $assignments) {
            Add-Finding $p.DisplayName "PROFILE_NO_ASSIGNMENT" "Deployment profile exists but is not assigned to any group"
        }
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Host "`n=== AUTOPILOT PROFILE ASSIGNMENT AUDIT ===" -ForegroundColor Cyan
if ($findings.Count -eq 0) {
    Write-Status "No issues flagged" "OK"
} else {
    $findings | Format-Table -Wrap -AutoSize
    $outFile = "$env:TEMP\AutopilotProfileAudit_$(Get-Date -Format yyyyMMdd_HHmmss).csv"
    $findings | Export-Csv $outFile -NoTypeInformation
    Write-Host "`nFull results: $outFile" -ForegroundColor Green
}
Write-Host "See Autopilot/Troubleshooting/Profile-Not-Assigned-B.md for fix paths matching these flags." -ForegroundColor Cyan
