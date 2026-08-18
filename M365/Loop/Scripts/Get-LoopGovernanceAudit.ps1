<#
.SYNOPSIS
    Audits a Microsoft 365 tenant's Microsoft Loop configuration and governance posture: the
    Teams-side (SharePoint) policy settings, OWA mailbox policy gates, SharePoint Embedded
    container inventory (including ownerless workspaces), and a set of explicitly-flagged
    limitations this script cannot read automatically.

.DESCRIPTION
    Microsoft Loop is controlled by two independent admin policy tools — Cloud Policy
    (config.office.com, no PowerShell equivalent) and SharePoint PowerShell (Set-SPOTenant,
    Teams-only) — plus a separate OWA mailbox policy gate for web Outlook/new Outlook. This
    script audits everything that IS readable via PowerShell, and explicitly and loudly reports
    what it CANNOT read (Cloud Policy state chief among them) rather than silently omitting it,
    matching this repo's established "report gaps, don't mask them" convention.

    This script covers:
      - SharePoint tenant-level Loop settings: IsLoopEnabled (Teams chat/channel components) and
        IsCollabMeetingNotesFluidEnabled (Teams classic-calendar collaborative meeting notes)
      - OWA mailbox policy audit across every policy in the tenant, flagging any policy where the
        four Loop-relevant booleans are inconsistent with each other (a common half-configured
        state) or set to $false
      - SharePoint Embedded container inventory for the Loop application identity (which also
        covers Copilot Pages and Copilot Notebooks, since all three share one application ID):
        user-owned container count, and every ownerless tenant-owned shared workspace
      - An explicit reminder block listing every Loop governance setting this script cannot read
        (Cloud Policy state, per-object retention label state, Information Barriers scope,
        eDiscovery custodian-picker rollout status) so a reviewer knows to check these manually
        rather than assuming a clean report means full coverage

    This script does NOT cover:
      - Cloud Policy state (config.office.com) — no PowerShell/Graph read API exists for this as
        of this script's writing; must be checked manually and is called out explicitly below
      - Actual Loop component/workspace usage volume or content inspection
      - Copilot Pages/Copilot Notebooks feature-level settings beyond the container inventory
        they share with Loop My workspace

.PARAMETER TenantName
    Friendly label for the tenant being audited, used only in console output and the exported
    report filename. Does not affect connection targeting.

.PARAMETER SkipOwaPolicyAudit
    Skip the OWA mailbox policy pass. Use this for tenants with a very large number of OWA
    mailbox policies where the full enumeration would be slow; the rest of the audit still runs.

.PARAMETER OutputPath
    Directory to write the CSV/summary report to. Defaults to the current directory.

.EXAMPLE
    .\Get-LoopGovernanceAudit.ps1 -TenantName "Contoso"

    Runs a full audit against the currently connected tenant and writes a timestamped report to
    the current directory.

.EXAMPLE
    .\Get-LoopGovernanceAudit.ps1 -TenantName "Contoso" -SkipOwaPolicyAudit

    Runs the audit without the OWA mailbox policy pass, for faster execution on tenants with many
    OWA mailbox policies.

.NOTES
    Requires: SharePoint Online Management Shell (Connect-SPOService) for all Get-SPOTenant/
    Get-SPOContainer calls, and Exchange Online PowerShell (Connect-ExchangeOnline) for the OWA
    mailbox policy pass. This script does not establish those connections itself, since
    credential/MFA handling should remain under the operator's control.

    Written for Windows PowerShell 5.1 compatibility (no ??/?. operators) per this repo's usual
    scripting convention — unlike Microsoft Places, Loop's SharePoint/Exchange PowerShell modules
    have no PS7-only requirement.

    Read-only. No tenant settings, containers, or policies are created, modified, or deleted by
    this script.

    Cloud Policy (config.office.com) state has NO PowerShell or Graph read API as of this
    script's writing. This is the single most important manual-verification step this script
    cannot automate — a clean report from this script does NOT confirm Cloud Policy is correctly
    configured, only that the SharePoint- and Exchange-side settings are.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantName,

    [switch]$SkipOwaPolicyAudit,

    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$findings = New-Object System.Collections.Generic.List[pscustomobject]

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

$LoopWebAppId = 'a187e399-0c36-4b98-8f04-1edc167a0996'
$LoopMobileAppId = '0922ef46-e1b9-4f7e-9134-9ad00547eb41'

Write-Status "=== Microsoft Loop Governance Audit: $TenantName ===" "INFO"

# ---------------------------------------------------------------------------
# Phase 1: Preflight — module/connection checks
# ---------------------------------------------------------------------------
Write-Status "Phase 1: Preflight checks" "INFO"

$spoConnected = $false
try {
    $null = Get-SPOTenant -ErrorAction Stop
    $spoConnected = $true
    Write-Status "SharePoint Online Management Shell session active — OK" "OK"
    Add-Finding -Category "Preflight" -Object "SPO session" -Status "OK" -Detail "Connected"
}
catch {
    Write-Status "No active SharePoint Online Management Shell session. Run Connect-SPOService first. Aborting SPO-dependent phases." "ERROR"
    Add-Finding -Category "Preflight" -Object "SPO session" -Status "FAIL" -Detail "Not connected — Connect-SPOService required."
}

$exoConnected = $false
try {
    $null = Get-ConnectionInformation -ErrorAction Stop
    $exoConnected = $true
    Write-Status "Exchange Online session active — OK" "OK"
    Add-Finding -Category "Preflight" -Object "Exchange Online session" -Status "OK" -Detail "Connected"
}
catch {
    Write-Status "No active Exchange Online session detected. OWA mailbox policy checks will be skipped." "WARN"
    Add-Finding -Category "Preflight" -Object "Exchange Online session" -Status "WARN" `
        -Detail "Not connected — run Connect-ExchangeOnline to enable the OWA mailbox policy pass."
}

Write-Status "REMINDER: Cloud Policy (config.office.com) state has NO PowerShell/Graph read API. This script cannot verify it — check manually." "WARN"
Add-Finding -Category "Preflight" -Object "Cloud Policy (config.office.com)" -Status "LIMITED" `
    -Detail "No PowerShell/Graph API exists to read Cloud Policy state. Verify manually: 'Create Loop workspaces in Loop', 'Create and view Loop files in Microsoft apps that support Loop', and 'Create and view Loop files in Outlook'."

# ---------------------------------------------------------------------------
# Phase 2: SharePoint tenant-level Loop settings (Teams-side)
# ---------------------------------------------------------------------------
if ($spoConnected) {
    Write-Status "Phase 2: SharePoint tenant Loop settings (Teams-side)" "INFO"

    try {
        $tenant = Get-SPOTenant -ErrorAction Stop
        $isLoopEnabled = $tenant.IsLoopEnabled
        $isCollabNotesEnabled = $tenant.IsCollabMeetingNotesFluidEnabled

        if ($isLoopEnabled) {
            Write-Status "IsLoopEnabled: $isLoopEnabled — Loop components in Teams chat/channels are ON tenant-wide — OK" "OK"
        }
        else {
            Write-Status "IsLoopEnabled: $isLoopEnabled — Loop components in Teams chat/channels are OFF tenant-wide." "WARN"
        }
        Add-Finding -Category "TenantSetting" -Object "IsLoopEnabled" -Status $(if ($isLoopEnabled) { "OK" } else { "WARN" }) `
            -Detail "Value=$isLoopEnabled. This setting is tenant-wide only; cannot be scoped per-user. Multi-region tenants: confirm consistency across every organization URL."

        if ($isCollabNotesEnabled) {
            Write-Status "IsCollabMeetingNotesFluidEnabled: $isCollabNotesEnabled — Teams classic-calendar collaborative meeting notes ON — OK" "OK"
        }
        else {
            Write-Status "IsCollabMeetingNotesFluidEnabled: $isCollabNotesEnabled — Teams classic-calendar collaborative meeting notes OFF." "WARN"
        }
        Add-Finding -Category "TenantSetting" -Object "IsCollabMeetingNotesFluidEnabled" -Status $(if ($isCollabNotesEnabled) { "OK" } else { "WARN" }) `
            -Detail "Value=$isCollabNotesEnabled. Does NOT apply to Teams New Calendar meeting notes — that surface checks Cloud Policy instead."
    }
    catch {
        Write-Status "Unable to read Get-SPOTenant: $($_.Exception.Message)" "ERROR"
        Add-Finding -Category "TenantSetting" -Object "Get-SPOTenant" -Status "ERROR" -Detail $_.Exception.Message
    }
}
else {
    Write-Status "Phase 2 skipped — no SPO session." "WARN"
    Add-Finding -Category "TenantSetting" -Object "N/A" -Status "SKIPPED" -Detail "No active SPO session."
}

# ---------------------------------------------------------------------------
# Phase 3: OWA mailbox policy audit
# ---------------------------------------------------------------------------
if (-not $SkipOwaPolicyAudit -and $exoConnected) {
    Write-Status "Phase 3: OWA mailbox policy audit" "INFO"

    try {
        $owaPolicies = Get-OwaMailboxPolicy -ErrorAction Stop
        Write-Status "Found $($owaPolicies.Count) OWA mailbox policy/policies." "OK"

        foreach ($policy in $owaPolicies) {
            $privateOk = $policy.DirectFileAccessOnPrivateComputersEnabled -and $policy.WacViewingOnPrivateComputersEnabled
            $publicOk = $policy.DirectFileAccessOnPublicComputersEnabled -and $policy.WacViewingOnPublicComputersEnabled

            if ($privateOk) {
                Add-Finding -Category "OwaMailboxPolicy" -Object "$($policy.Identity) [Private]" -Status "OK" `
                    -Detail "DirectFileAccess+WacViewing both enabled for private sessions."
            }
            else {
                Write-Status "  $($policy.Identity): Private-session Loop access blocked (one or both booleans false)." "WARN"
                Add-Finding -Category "OwaMailboxPolicy" -Object "$($policy.Identity) [Private]" -Status "WARN" `
                    -Detail "DirectFileAccessOnPrivateComputersEnabled=$($policy.DirectFileAccessOnPrivateComputersEnabled), WacViewingOnPrivateComputersEnabled=$($policy.WacViewingOnPrivateComputersEnabled) — Loop will not function in web Outlook/new Outlook for private sessions under this policy."
            }

            if ($publicOk) {
                Add-Finding -Category "OwaMailboxPolicy" -Object "$($policy.Identity) [Public]" -Status "OK" `
                    -Detail "DirectFileAccess+WacViewing both enabled for public sessions."
            }
            else {
                Add-Finding -Category "OwaMailboxPolicy" -Object "$($policy.Identity) [Public]" -Status "INFO" `
                    -Detail "DirectFileAccessOnPublicComputersEnabled=$($policy.DirectFileAccessOnPublicComputersEnabled), WacViewingOnPublicComputersEnabled=$($policy.WacViewingOnPublicComputersEnabled) — public-session restriction may be intentional; confirm with tenant policy owner before treating as a gap."
            }
        }
    }
    catch {
        Write-Status "OWA mailbox policy audit failed: $($_.Exception.Message)" "ERROR"
        Add-Finding -Category "OwaMailboxPolicy" -Object "Get-OwaMailboxPolicy" -Status "ERROR" -Detail $_.Exception.Message
    }
}
elseif ($SkipOwaPolicyAudit) {
    Write-Status "Phase 3: OWA mailbox policy audit skipped (-SkipOwaPolicyAudit)." "INFO"
    Add-Finding -Category "OwaMailboxPolicy" -Object "N/A" -Status "SKIPPED" -Detail "Skipped by parameter."
}
else {
    Write-Status "Phase 3: OWA mailbox policy audit skipped — no Exchange Online session." "WARN"
    Add-Finding -Category "OwaMailboxPolicy" -Object "N/A" -Status "SKIPPED" -Detail "No active Exchange Online session."
}

# ---------------------------------------------------------------------------
# Phase 4: SharePoint Embedded container inventory (Loop application identity)
# ---------------------------------------------------------------------------
if ($spoConnected) {
    Write-Status "Phase 4: SharePoint Embedded container inventory (Loop application identity)" "INFO"
    Write-Status "Note: this application identity also covers Copilot Pages and Copilot Notebooks user-owned containers — there is no separate identity to filter on." "INFO"

    try {
        $loopContainers = Get-SPOContainer -OwningApplicationId $LoopWebAppId -ErrorAction Stop
        Write-Status "Retrieved $($loopContainers.Count) container(s) under the Loop application identity." "OK"
        Add-Finding -Category "ContainerInventory" -Object "Total containers" -Status "INFO" -Detail "$($loopContainers.Count) container(s) found."

        $userOwned = $loopContainers | Where-Object { $_.OwnershipType -eq 'UserOwned' }
        Write-Status "  User-owned (My workspace / Copilot Pages / Copilot Notebooks): $($userOwned.Count)" "INFO"
        Add-Finding -Category "ContainerInventory" -Object "User-owned containers" -Status "INFO" -Detail "$($userOwned.Count) — one per user who has used Loop My workspace, Copilot Pages, or Copilot Notebooks."

        $tenantOwned = $loopContainers | Where-Object { $_.OwnershipType -eq 'TenantOwned' }
        $groupOwned = $loopContainers | Where-Object { $_.OwnershipType -eq 'GroupOwned' }
        Write-Status "  Tenant-owned shared workspaces: $($tenantOwned.Count)" "INFO"
        Write-Status "  Group-owned shared workspaces (e.g. Teams channel workspaces): $($groupOwned.Count)" "INFO"
        Add-Finding -Category "ContainerInventory" -Object "Tenant-owned workspaces" -Status "INFO" -Detail "$($tenantOwned.Count) — roster-permissioned shared workspaces."
        Add-Finding -Category "ContainerInventory" -Object "Group-owned workspaces" -Status "INFO" -Detail "$($groupOwned.Count) — lifecycle tied to the owning Microsoft 365 Group."

        $ownerless = $tenantOwned | Where-Object { $_.OwnersCount -eq 0 }
        if ($ownerless.Count -gt 0) {
            Write-Status "$($ownerless.Count) tenant-owned workspace(s) are OWNERLESS — all owners have left the organization, and members cannot self-service management." "WARN"
            foreach ($o in $ownerless) {
                Add-Finding -Category "OwnerlessWorkspace" -Object $o.DisplayName -Status "WARN" `
                    -Detail "OwnersCount=0. Requires a SharePoint Embedded administrator to add a new Owner before this workspace can be managed or deleted."
            }
        }
        else {
            Write-Status "No ownerless tenant-owned workspaces found — OK" "OK"
            Add-Finding -Category "OwnerlessWorkspace" -Object "All tenant-owned workspaces" -Status "OK" -Detail "Every tenant-owned workspace has at least one active Owner."
        }
    }
    catch {
        Write-Status "Unable to retrieve containers via Get-SPOContainer: $($_.Exception.Message)" "ERROR"
        Add-Finding -Category "ContainerInventory" -Object "Get-SPOContainer" -Status "ERROR" -Detail $_.Exception.Message
    }
}
else {
    Write-Status "Phase 4 skipped — no SPO session." "WARN"
    Add-Finding -Category "ContainerInventory" -Object "N/A" -Status "SKIPPED" -Detail "No active SPO session."
}

# ---------------------------------------------------------------------------
# Phase 5: Explicit governance/coverage gaps this script cannot audit
# ---------------------------------------------------------------------------
Write-Status "Phase 5: Known governance gaps not covered by this script (reported explicitly, not silently omitted)" "INFO"

Add-Finding -Category "KnownGap" -Object "Cloud Policy state" -Status "LIMITED" `
    -Detail "No PowerShell/Graph read API. Verify manually at https://config.office.com under Customization > Policy Management."
Add-Finding -Category "KnownGap" -Object "Per-container creation date (legacy roster check)" -Status "LIMITED" `
    -Detail "Tenant-owned workspaces created before April 2025 use a legacy in-app roster model not fully manageable from the SharePoint admin center. This script does not reliably determine per-container creation date; verify manually via the SharePoint admin center container details panel before assuming admin-center membership management will work for a specific older workspace."
Add-Finding -Category "KnownGap" -Object "Retention label application state" -Status "LIMITED" `
    -Detail "Retention labels on Loop components have no bulk-readable state via this script; labels can only be applied/viewed from inside the Loop app on the underlying file, not the embedded component."
Add-Finding -Category "KnownGap" -Object "eDiscovery custodian-picker rollout status" -Status "LIMITED" `
    -Detail "The custodian picker for the personal container began rolling out in early August 2026; whether a specific tenant already has it is a Purview eDiscovery UI check, not a PowerShell-readable setting."
Add-Finding -Category "KnownGap" -Object "Information Barriers scope" -Status "INFO" `
    -Detail "By design, not a script limitation: Information Barriers do not cover SharePoint Embedded content (Loop workspaces, My workspace) at all — only OneDrive/SharePoint-stored Loop content. No PowerShell check applies because there is nothing to enable here."

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Status "=== Audit Summary ===" "INFO"
$findings | Format-Table -AutoSize

$reportFile = Join-Path -Path $OutputPath -ChildPath "LoopGovernanceAudit-$TenantName-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$findings | Export-Csv -Path $reportFile -NoTypeInformation
Write-Status "Report exported to: $reportFile" "OK"

$warnCount = ($findings | Where-Object { $_.Status -in @("WARN", "ERROR") }).Count
if ($warnCount -gt 0) {
    Write-Status "$warnCount finding(s) need attention — review the report, and remember to separately verify Cloud Policy state manually before declaring this tenant's Loop configuration fully audited." "WARN"
}
else {
    Write-Status "No blocking findings detected in the PowerShell-readable settings — still verify Cloud Policy manually, since this script cannot read it." "OK"
}
