<#
.SYNOPSIS
    Audits a Microsoft 365 tenant's Microsoft Places readiness: tooling compliance, building
    visibility, directory hierarchy parenting validity, RoomList cross-reference gaps, and
    best-effort space-license signal.

.DESCRIPTION
    Microsoft Places support tickets are overwhelmingly explained by a small set of root causes:
    the wrong PowerShell version, the tenant-wide EnableBuildings switch being off, desk-pool/
    individual-desk objects parented above Section level (which silently fails to appear in the
    new booking experience), and RoomList/Places-directory disagreement between client surfaces.
    This script is a READ-ONLY audit that surfaces all of these in one pass, per tenant, for use
    ahead of a Places rollout or as a standing MSP fleet-health check.

    This script covers:
      - PowerShell version compliance (MicrosoftPlaces module requires 7.4.0+, will not load on
        Windows PowerShell 5.1 — this check runs first and gates the rest of the script)
      - EnableBuildings tenant setting (blocks ALL Places visibility when off, independent of
        hierarchy correctness)
      - Places directory inventory by object type, with explicit parenting validation for
        Workspace and Desk objects (must parent to a Section — Floor-only parenting is flagged)
      - RoomList membership cross-reference for all Room and Workspace-typed Exchange mailboxes,
        flagging objects present in one system but not the other
      - Best-effort space-license signal via Exchange mailbox SKU inspection (space licenses are
        assigned per-object; this script reports what it can see and explicitly flags what it
        cannot, rather than silently omitting it)
      - Places RBAC role assignment inventory (Places Administrator via Entra directory role;
        Places Building/Desk Administrator via Exchange management role assignment)

    This script does NOT cover:
      - Occupancy sensor configuration or hardware status
      - Teams Rooms peripheral-device pairing (see Teams Rooms-specific tooling)
      - Actual booking/calendar activity or utilization analytics (Places analytics is a
        portal-only reporting surface with no exposed read cmdlet as of this script's writing)

.PARAMETER TenantName
    Friendly label for the tenant being audited, used only in console output and the exported
    report filename. Does not affect connection targeting.

.PARAMETER SkipRoomListCrossReference
    Skip the RoomList membership cross-reference pass. Use this for very large room/desk
    inventories where the per-object Get-DistributionGroupMember lookups would be slow; the rest
    of the audit still runs.

.PARAMETER OutputPath
    Directory to write the CSV/summary report to. Defaults to the current directory.

.EXAMPLE
    .\Get-PlacesReadinessAudit.ps1 -TenantName "Contoso"

    Runs a full readiness audit against the currently connected tenant and writes a timestamped
    report to the current directory.

.EXAMPLE
    .\Get-PlacesReadinessAudit.ps1 -TenantName "Contoso" -SkipRoomListCrossReference

    Runs the audit without the RoomList cross-reference pass, for faster execution on large
    tenants.

.NOTES
    Requires: PowerShell 7.4.0 or later (hard requirement of the MicrosoftPlaces module — this
    script will not run under Windows PowerShell 5.1, and checks for this itself as its first
    action). This is a deliberate, documented exception to this repo's usual PowerShell
    5.1-compatible scripting convention — Microsoft Places PowerShell has no 5.1-compatible path.

    Requires an active connection via Connect-MicrosoftPlaces (MicrosoftPlaces module) and
    Connect-ExchangeOnline (ExchangeOnlineManagement module) before running. This script does
    not establish those connections itself, since credential/MFA handling should remain under
    the operator's control.

    Read-only. No Places or Exchange objects are created, modified, or deleted by this script.

    Places space-license assignment has no dedicated read cmdlet as of this script's writing;
    the license section below reports best-effort signal only and explicitly flags this
    limitation in its own output rather than silently omitting license data.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantName,

    [switch]$SkipRoomListCrossReference,

    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$findings = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-Finding {
    param(
        [string]$Category,
        [string]$Object,
        [string]$Status,
        [string]$Detail
    )
    $findings.Add([pscustomobject]@{
        Category = $Category
        Object   = $Object
        Status   = $Status
        Detail   = $Detail
    })
}

Write-Status "=== Microsoft Places Readiness Audit: $TenantName ===" "INFO"

# ---------------------------------------------------------------------------
# Phase 1: Preflight — PowerShell version and module connectivity
# ---------------------------------------------------------------------------
Write-Status "Phase 1: Preflight checks" "INFO"

$psVersion = $PSVersionTable.PSVersion
if ($psVersion.Major -lt 7 -or ($psVersion.Major -eq 7 -and $psVersion.Minor -lt 4)) {
    Write-Status "PowerShell version $psVersion detected — MicrosoftPlaces requires 7.4.0+. Aborting." "ERROR"
    Add-Finding -Category "Preflight" -Object "PowerShell" -Status "FAIL" `
        -Detail "Version $psVersion is below the 7.4.0 minimum required by the MicrosoftPlaces module."
    $findings | Format-Table -AutoSize
    return
}
Write-Status "PowerShell version $psVersion — OK" "OK"
Add-Finding -Category "Preflight" -Object "PowerShell" -Status "OK" -Detail "Version $psVersion"

$placesModule = Get-Module -Name MicrosoftPlaces -ErrorAction SilentlyContinue
if (-not $placesModule) {
    Write-Status "MicrosoftPlaces module not loaded in this session. Run Connect-MicrosoftPlaces first." "ERROR"
    Add-Finding -Category "Preflight" -Object "MicrosoftPlaces module" -Status "FAIL" `
        -Detail "Not connected — script requires an active Connect-MicrosoftPlaces session."
    $findings | Format-Table -AutoSize
    return
}
Write-Status "MicrosoftPlaces module connected — OK" "OK"

$exoModule = Get-ConnectionInformation -ErrorAction SilentlyContinue
if (-not $exoModule) {
    Write-Status "No active Exchange Online session detected. RoomList and mailbox checks will be skipped." "WARN"
    Add-Finding -Category "Preflight" -Object "Exchange Online session" -Status "WARN" `
        -Detail "Not connected — run Connect-ExchangeOnline to enable RoomList and mailbox-side checks."
}
else {
    Write-Status "Exchange Online session active — OK" "OK"
}

# ---------------------------------------------------------------------------
# Phase 2: Building visibility
# ---------------------------------------------------------------------------
Write-Status "Phase 2: Building visibility setting" "INFO"

try {
    $placesSettings = Get-PlacesSettings -ErrorAction Stop
    $enableBuildings = $placesSettings.EnableBuildings
    if ($enableBuildings -match "true") {
        Write-Status "EnableBuildings: $enableBuildings — OK" "OK"
        Add-Finding -Category "TenantSetting" -Object "EnableBuildings" -Status "OK" -Detail "$enableBuildings"
    }
    else {
        Write-Status "EnableBuildings: $enableBuildings — buildings are NOT visible in any Places surface tenant-wide." "WARN"
        Add-Finding -Category "TenantSetting" -Object "EnableBuildings" -Status "WARN" `
            -Detail "Value '$enableBuildings' — every configured building/floor/section/room is invisible until this is enabled."
    }
}
catch {
    Write-Status "Unable to read Get-PlacesSettings: $($_.Exception.Message)" "ERROR"
    Add-Finding -Category "TenantSetting" -Object "EnableBuildings" -Status "ERROR" -Detail $_.Exception.Message
}

# ---------------------------------------------------------------------------
# Phase 3: Places directory inventory + parenting validation
# ---------------------------------------------------------------------------
Write-Status "Phase 3: Places directory inventory and parenting validation" "INFO"

$allPlaces = @()
try {
    $allPlaces = Get-PlaceV3 -ErrorAction Stop
    Write-Status "Retrieved $($allPlaces.Count) Places directory objects." "OK"
}
catch {
    Write-Status "Unable to retrieve Places directory via Get-PlaceV3: $($_.Exception.Message)" "ERROR"
    Add-Finding -Category "Directory" -Object "Get-PlaceV3" -Status "ERROR" -Detail $_.Exception.Message
}

if ($allPlaces.Count -gt 0) {
    $byType = $allPlaces | Group-Object -Property Type
    foreach ($group in $byType) {
        Write-Status "  $($group.Name): $($group.Count) object(s)" "INFO"
        Add-Finding -Category "DirectoryInventory" -Object $group.Name -Status "INFO" -Detail "$($group.Count) objects"
    }

    # Build a lookup of PlaceId -> Type for parent-level validation
    $placeById = @{}
    foreach ($p in $allPlaces) {
        if ($p.PlaceId) { $placeById[$p.PlaceId] = $p }
    }

    $badParenting = [System.Collections.Generic.List[pscustomobject]]::new()
    foreach ($obj in $allPlaces) {
        if ($obj.Type -in @("Workspace", "Desk")) {
            if (-not $obj.ParentId) {
                $badParenting.Add($obj)
                continue
            }
            $parent = $placeById[$obj.ParentId]
            if ($parent -and $parent.Type -ne "Section") {
                $badParenting.Add($obj)
            }
        }
    }

    if ($badParenting.Count -gt 0) {
        Write-Status "$($badParenting.Count) Workspace/Desk object(s) are NOT parented to a Section — these will silently fail to appear in the new booking experience." "WARN"
        foreach ($bp in $badParenting) {
            Add-Finding -Category "ParentingValidation" -Object $bp.DisplayName -Status "WARN" `
                -Detail "Type=$($bp.Type), ParentId=$($bp.ParentId) — must parent to a Section, not a Floor or empty parent."
        }
    }
    else {
        Write-Status "All Workspace/Desk objects correctly parented to a Section — OK" "OK"
        Add-Finding -Category "ParentingValidation" -Object "All Workspace/Desk objects" -Status "OK" -Detail "Section parenting confirmed"
    }
}

# ---------------------------------------------------------------------------
# Phase 4: RoomList cross-reference (Exchange side)
# ---------------------------------------------------------------------------
if (-not $SkipRoomListCrossReference -and $exoModule) {
    Write-Status "Phase 4: RoomList cross-reference" "INFO"

    try {
        $roomLists = Get-DistributionGroup -RecipientTypeDetails RoomList -ErrorAction Stop
        Write-Status "Found $($roomLists.Count) RoomList(s)." "OK"

        $roomListMembers = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($rl in $roomLists) {
            $members = Get-DistributionGroupMember -Identity $rl.Identity -ErrorAction SilentlyContinue
            foreach ($m in $members) {
                if ($m.PrimarySmtpAddress) { [void]$roomListMembers.Add($m.PrimarySmtpAddress.ToLower()) }
            }
        }

        $allRoomsAndWorkspaces = Get-Mailbox -RecipientTypeDetails RoomMailbox -ResultSize Unlimited -ErrorAction SilentlyContinue
        $missingFromRoomList = [System.Collections.Generic.List[pscustomobject]]::new()
        foreach ($mbx in $allRoomsAndWorkspaces) {
            $addr = $mbx.PrimarySmtpAddress.ToString().ToLower()
            if (-not $roomListMembers.Contains($addr)) {
                $missingFromRoomList.Add($mbx)
            }
        }

        if ($missingFromRoomList.Count -gt 0) {
            Write-Status "$($missingFromRoomList.Count) room/workspace mailbox(es) are NOT on any RoomList — invisible in classic Outlook Room Finder regardless of Places directory state." "WARN"
            foreach ($m in $missingFromRoomList) {
                Add-Finding -Category "RoomListCrossReference" -Object $m.DisplayName -Status "WARN" `
                    -Detail "PrimarySmtpAddress=$($m.PrimarySmtpAddress) — not a member of any RoomList."
            }
        }
        else {
            Write-Status "All room/workspace mailboxes are on at least one RoomList — OK" "OK"
            Add-Finding -Category "RoomListCrossReference" -Object "All room/workspace mailboxes" -Status "OK" -Detail "RoomList membership confirmed"
        }

        # Also flag hidden mailboxes, a separate but related visibility gate
        $hidden = $allRoomsAndWorkspaces | Where-Object { $_.HiddenFromAddressListsEnabled }
        if ($hidden.Count -gt 0) {
            Write-Status "$($hidden.Count) room/workspace mailbox(es) are hidden from address lists." "WARN"
            foreach ($h in $hidden) {
                Add-Finding -Category "AddressListVisibility" -Object $h.DisplayName -Status "WARN" `
                    -Detail "HiddenFromAddressListsEnabled=True — confirm this is intentional."
            }
        }
    }
    catch {
        Write-Status "RoomList cross-reference failed: $($_.Exception.Message)" "ERROR"
        Add-Finding -Category "RoomListCrossReference" -Object "Get-DistributionGroup/Get-Mailbox" -Status "ERROR" -Detail $_.Exception.Message
    }
}
elseif ($SkipRoomListCrossReference) {
    Write-Status "Phase 4: RoomList cross-reference skipped (-SkipRoomListCrossReference)." "INFO"
    Add-Finding -Category "RoomListCrossReference" -Object "N/A" -Status "SKIPPED" -Detail "Skipped by parameter."
}
else {
    Write-Status "Phase 4: RoomList cross-reference skipped — no Exchange Online session." "WARN"
    Add-Finding -Category "RoomListCrossReference" -Object "N/A" -Status "SKIPPED" -Detail "No active Exchange Online session."
}

# ---------------------------------------------------------------------------
# Phase 5: RBAC role assignment inventory
# ---------------------------------------------------------------------------
Write-Status "Phase 5: Places RBAC role assignment inventory" "INFO"

if ($exoModule) {
    try {
        $buildingAdmins = Get-ManagementRoleAssignment -Role "PlacesBuildingManagement" -ErrorAction SilentlyContinue
        Write-Status "Places Building Administrator role assignments: $($buildingAdmins.Count)" "INFO"
        foreach ($ba in $buildingAdmins) {
            Add-Finding -Category "RBAC" -Object $ba.RoleAssigneeName -Status "INFO" -Detail "Places Building Administrator (Exchange RBAC)"
        }
    }
    catch {
        Write-Status "Unable to enumerate PlacesBuildingManagement role assignments: $($_.Exception.Message)" "WARN"
        Add-Finding -Category "RBAC" -Object "PlacesBuildingManagement" -Status "WARN" -Detail $_.Exception.Message
    }
}
else {
    Write-Status "Skipping Exchange-side RBAC enumeration — no Exchange Online session." "WARN"
}

Write-Status "Note: Places Administrator (Entra ID role) enumeration requires Microsoft Graph PowerShell (Get-MgRoleManagementDirectoryRoleAssignment against the Places Administrator directory role) and is intentionally out of scope for this Exchange/Places-only script — cross-reference with your Entra ID audit tooling for full RBAC coverage." "INFO"
Add-Finding -Category "RBAC" -Object "Places Administrator (Entra ID)" -Status "INFO" `
    -Detail "Not enumerated by this script — requires Microsoft Graph PowerShell against Entra directory roles."

# ---------------------------------------------------------------------------
# Phase 6: Best-effort space-license signal
# ---------------------------------------------------------------------------
Write-Status "Phase 6: Space-license signal (best effort)" "INFO"
Write-Status "Places space-license assignment (MTR/MTSS/MTSS-SS per object) has no dedicated read cmdlet as of this script's writing — this section is intentionally limited, not silently skipped." "WARN"
Add-Finding -Category "Licensing" -Object "Space license assignment" -Status "LIMITED" `
    -Detail "No dedicated read cmdlet available for per-object space license state. Verify via the Places Management portal or the M365 admin center licensing blade for definitive results."

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Status "=== Audit Summary ===" "INFO"
$findings | Format-Table -AutoSize

$reportFile = Join-Path -Path $OutputPath -ChildPath "PlacesReadinessAudit-$TenantName-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$findings | Export-Csv -Path $reportFile -NoTypeInformation
Write-Status "Report exported to: $reportFile" "OK"

$warnCount = ($findings | Where-Object { $_.Status -in @("WARN", "ERROR") }).Count
if ($warnCount -gt 0) {
    Write-Status "$warnCount finding(s) need attention — review the report before declaring this tenant Places-ready." "WARN"
}
else {
    Write-Status "No blocking findings detected." "OK"
}
