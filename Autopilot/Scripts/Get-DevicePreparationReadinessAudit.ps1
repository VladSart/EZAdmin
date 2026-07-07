<#
.SYNOPSIS
    Audits Windows Autopilot device preparation (APDP) prerequisites tenant-wide or for a
    specific list of device security groups — ownership, eligibility, and classic-Autopilot
    shadowing risk.

.DESCRIPTION
    Windows Autopilot device preparation depends on a strict set of Entra-side prerequisites
    that fail silently or with generic portal errors when misconfigured (see
    Troubleshooting/DevicePreparation-B.md and -A.md for the full dependency chain). This
    script performs read-only checks against those prerequisites so they can be validated
    in bulk, before or during an incident, rather than clicking through each group in the
    Entra/Intune admin centers one at a time.

    Checks performed, per supplied device group:
      - NO_PROVISIONING_CLIENT_OWNER : Intune Provisioning Client (or its tenant-specific
        display name "Intune Autopilot ConfidentialClient") is NOT an owner of the group.
        This is the #1 documented cause of "problem with the device security group" /
        "0 groups assigned" errors.
      - GROUP_IS_DYNAMIC : group has a membership rule (dynamic), which is incompatible
        with Enrollment Time Grouping's direct-membership-write mechanism.
      - GROUP_ROLE_ASSIGNABLE : group has isAssignableToRole = true, which blocks the
        Intune Provisioning Client service principal from adding members to it (a hard
        Entra Privileged Role Administration platform constraint, not a device-prep-only rule).
      - SERVICE_PRINCIPAL_MISSING : the Intune Provisioning Client service principal
        (AppID f1346770-5b25-470b-88bd-d5744ab7952c) does not exist anywhere in the tenant
        yet — a one-time tenant provisioning step that must happen before any group ownership
        fix can work.

    Also, given a list of device serial numbers (-CheckSerialShadowing), flags:
      - CLASSIC_AUTOPILOT_SHADOW : the serial is already registered as a classic Windows
        Autopilot device and/or has a classic deployment profile assigned. Classic Autopilot
        ALWAYS takes precedence over a device preparation policy, so these devices will never
        go through device prep until deregistered — this is the single most common reason a
        "device prep isn't launching" ticket turns out to be a false alarm.

    This script does NOT and cannot read the device preparation POLICY object itself (user
    group targeting, allowed apps/scripts, priority, account-type setting) — at time of
    writing, device preparation policies are not exposed via a documented, stable Graph
    endpoint; they are only configurable/readable through the Intune admin center UI (and an
    undocumented beta surface not suitable for a supported automation script). That gap is
    explicitly out of scope here, not silently omitted — cross-reference the Intune admin
    center's Device preparation policy list and Monitor tab for anything policy-level.

    Read-only throughout. No group membership, ownership, or policy changes are made.

.PARAMETER DeviceGroupObjectId
    One or more Entra group Object IDs to audit as device-preparation device groups.

.PARAMETER CheckSerialShadowing
    One or more device serial numbers to check against the classic Windows Autopilot
    devices list for precedence-shadowing risk.

.PARAMETER AdminUpn
    Optional. If supplied, lists directory role assignments for this admin so the operator
    can manually cross-check for "Enrollment time device membership assignment" and
    "Device configurations: Assign" against the role definition permissions in the Entra
    admin center. This script does not attempt automated permission-string matching, since
    custom role definitions vary per tenant and a false negative here is worse than requiring
    a manual look.

.EXAMPLE
    .\Get-DevicePreparationReadinessAudit.ps1 -DeviceGroupObjectId "11111111-2222-3333-4444-555555555555"

.EXAMPLE
    .\Get-DevicePreparationReadinessAudit.ps1 `
        -DeviceGroupObjectId "11111111-2222-3333-4444-555555555555","66666666-7777-8888-9999-000000000000" `
        -CheckSerialShadowing "PF3ABCDE","PF3XYZ12" `
        -AdminUpn "helpdesk-admin@contoso.com" |
        Export-Csv -Path C:\Reports\APDP-Readiness.csv -NoTypeInformation

.NOTES
    Requires: Microsoft.Graph.Groups, Microsoft.Graph.Applications, Microsoft.Graph.Identity.DirectoryManagement,
              Microsoft.Graph.DeviceManagement.Enrollment (for classic Autopilot device lookups), Microsoft.Graph.Users modules.
    Scopes required: Group.Read.All, Application.Read.All, RoleManagement.Read.Directory,
                      DeviceManagementServiceConfig.Read.All, User.Read.All
    Run-as: any account with the above Graph delegated/app permissions — no local admin needed,
            this is a cloud-only audit script (no device-local checks).
    Safe/unsafe: fully read-only. Makes no New-/Set-/Remove-/Update- calls of any kind.
#>
[CmdletBinding()]
param(
    [string[]]$DeviceGroupObjectId,
    [string[]]$CheckSerialShadowing,
    [string]$AdminUpn
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" {"Green"} "WARN" {"Yellow"} "ERROR" {"Red"} default {"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$requiredScopes = @(
    "Group.Read.All",
    "Application.Read.All",
    "RoleManagement.Read.Directory",
    "DeviceManagementServiceConfig.Read.All",
    "User.Read.All"
)

try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "No active Graph session — connecting..." "INFO"
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome
    }
} catch {
    Write-Status "Failed to establish Graph connection: $($_.Exception.Message)" "ERROR"
    throw
}

$results = [System.Collections.Generic.List[object]]::new()
$spAppId = "f1346770-5b25-470b-88bd-d5744ab7952c"

Write-Status "Checking for Intune Provisioning Client service principal (AppID $spAppId)..." "INFO"
$sp = $null
try {
    $sp = Get-MgServicePrincipal -Filter "appId eq '$spAppId'" -ErrorAction Stop
} catch {
    Write-Status "Service principal lookup failed: $($_.Exception.Message)" "WARN"
}

if (-not $sp) {
    Write-Status "SERVICE_PRINCIPAL_MISSING — Intune Provisioning Client / Intune Autopilot ConfidentialClient does not exist in this tenant. No device group ownership fix will work until this is provisioned (see MS Learn: 'Adding the Intune Provisioning Client service principal')." "ERROR"
} else {
    Write-Status "Service principal found: $($sp.DisplayName) ($($sp.Id))" "OK"
}

foreach ($groupId in $DeviceGroupObjectId) {
    Write-Status "Auditing device group $groupId..." "INFO"
    $findings = [System.Collections.Generic.List[string]]::new()

    try {
        $group = Get-MgGroup -GroupId $groupId -Property "id,displayName,groupTypes,isAssignableToRole,membershipRule" -ErrorAction Stop
    } catch {
        $results.Add([pscustomobject]@{
            GroupObjectId  = $groupId
            GroupName      = "<lookup failed>"
            Findings       = "GROUP_LOOKUP_FAILED: $($_.Exception.Message)"
            OwnerConfirmed = $false
        })
        continue
    }

    if ($group.MembershipRule) {
        $findings.Add("GROUP_IS_DYNAMIC")
    }
    if ($group.IsAssignableToRole) {
        $findings.Add("GROUP_ROLE_ASSIGNABLE")
    }

    $ownerConfirmed = $false
    try {
        $owners = Get-MgGroupOwner -GroupId $groupId -All -ErrorAction Stop
        if ($sp) {
            $ownerConfirmed = [bool]($owners | Where-Object { $_.Id -eq $sp.Id })
        }
        if (-not $ownerConfirmed) {
            $findings.Add("NO_PROVISIONING_CLIENT_OWNER")
        }
    } catch {
        $findings.Add("OWNER_LOOKUP_FAILED: $($_.Exception.Message)")
    }

    $results.Add([pscustomobject]@{
        GroupObjectId  = $groupId
        GroupName      = $group.DisplayName
        Findings       = if ($findings.Count -gt 0) { $findings -join "; " } else { "OK" }
        OwnerConfirmed = $ownerConfirmed
    })

    if ($findings.Count -eq 0) {
        Write-Status "  $($group.DisplayName): OK" "OK"
    } else {
        Write-Status "  $($group.DisplayName): $($findings -join '; ')" "WARN"
    }
}

if ($CheckSerialShadowing) {
    Write-Status "Checking $($CheckSerialShadowing.Count) serial(s) for classic Autopilot precedence shadowing..." "INFO"
    foreach ($serial in $CheckSerialShadowing) {
        try {
            $identity = Get-MgDeviceManagementWindowAutopilotDeviceIdentity -Filter "contains(serialNumber,'$serial')" -ErrorAction Stop
        } catch {
            Write-Status "  $serial : lookup failed ($($_.Exception.Message)) — check manually in Intune admin center." "WARN"
            continue
        }

        if ($identity) {
            $profileAssigned = $identity.DeploymentProfileAssignmentStatus -and
                               $identity.DeploymentProfileAssignmentStatus -ne "notAssigned"
            $shadowFinding = if ($profileAssigned) {
                "CLASSIC_AUTOPILOT_SHADOW: registered AND has a classic deployment profile assigned (status: $($identity.DeploymentProfileAssignmentStatus)) — device prep will NEVER fire for this device until deregistered."
            } else {
                "CLASSIC_AUTOPILOT_SHADOW: registered as classic Autopilot device but no profile currently assigned — lower risk, but still takes precedence if a profile is later assigned."
            }
            Write-Status "  $serial : $shadowFinding" "WARN"
            $results.Add([pscustomobject]@{
                GroupObjectId  = "<n/a — serial check>"
                GroupName      = $serial
                Findings       = $shadowFinding
                OwnerConfirmed = $null
            })
        } else {
            Write-Status "  $serial : not registered as classic Autopilot device — clear for device prep." "OK"
        }
    }
}

if ($AdminUpn) {
    Write-Status "Listing directory role assignments for $AdminUpn (manually cross-check for 'Enrollment time device membership assignment' + 'Device configurations: Assign' permissions in the Entra admin center — this script does not auto-match permission strings across custom role definitions)..." "INFO"
    try {
        $user = Get-MgUser -UserId $AdminUpn -ErrorAction Stop
        $assignments = Get-MgRoleManagementDirectoryRoleAssignment -Filter "principalId eq '$($user.Id)'" -ErrorAction Stop
        foreach ($assignment in $assignments) {
            $roleDef = Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId $assignment.RoleDefinitionId -ErrorAction SilentlyContinue
            Write-Status "  Assigned role: $($roleDef.DisplayName)" "INFO"
        }
    } catch {
        Write-Status "  Role assignment lookup failed: $($_.Exception.Message)" "WARN"
    }
}

$exportPath = Join-Path -Path (Get-Location) -ChildPath "APDP-ReadinessAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$results | Export-Csv -Path $exportPath -NoTypeInformation
Write-Status "Report exported to $exportPath" "OK"
Write-Status "Audit complete. $(($results | Where-Object { $_.Findings -ne 'OK' }).Count) group(s)/serial(s) flagged out of $($results.Count) checked." "INFO"
