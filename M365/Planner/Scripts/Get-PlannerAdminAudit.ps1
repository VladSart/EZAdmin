<#
.SYNOPSIS
    Audits a Microsoft 365 tenant's Microsoft Planner configuration posture across both Basic
    (classic Planner) and Premium (Dataverse-backed, formerly Project for the web) plans, plus a
    set of explicitly-flagged settings this script cannot read automatically.

.DESCRIPTION
    Microsoft Planner is a single brand covering two architecturally separate products with three
    independent admin surfaces: Basic-plan tenant settings (a non-standard, separately-downloaded
    PlannerTenantAdmin PowerShell module), Premium-plan org-wide enablement (Microsoft 365 admin
    center only, no PowerShell/Graph equivalent), and the Planner Loop component (Cloud Policy,
    covered by Get-LoopGovernanceAudit.ps1 in this repo instead). This script audits everything
    that IS readable via PowerShell and Microsoft Graph, and explicitly and loudly reports what it
    CANNOT read rather than silently omitting it, matching this repo's established "report gaps,
    don't mask them" convention.

    This script covers:
      - Basic-plan tenant configuration via Get-PlannerConfiguration: IsPlannerAllowed,
        AllowRosterCreation, AllowCalendarSharing
      - Microsoft 365 Group creation restriction posture (Entra ID Group.Unified directory
        setting), since Basic (Group-backed) plan creation is gated there, not inside Planner
      - Per-user Basic/Premium service-plan state for a supplied sample of users
        (PROJECTWORKMANAGEMENT / PROJECT_P1 / PROJECT_PROFESSIONAL), flagging cases where a
        service plan is disabled independently of its parent SKU
      - Per-user Planner user policy state (BlockDeleteTasksNotCreatedBySelf) for the same sample
      - An explicit reminder block listing every Planner governance/configuration setting this
        script cannot read (the Premium org-wide toggle, Dataverse environment "Enable D365 Apps"
        state and license-minimum posture, the Project Team Member Dataverse security role, the
        Roadmap Power Platform DLP connector state, and Roster-vs-Group plan container counts) so
        a reviewer knows to check these manually rather than assuming a clean report means full
        coverage

    This script does NOT cover:
      - The Premium (Project for the web) org-wide enablement toggle — no PowerShell/Graph/CLI
        read API exists for the Microsoft 365 admin center "Turn on Project for the web for your
        organization" / "Turn on Roadmap for your organization" checkboxes as of this writing
      - Power Platform/Dataverse environment-layer settings (Enable D365 Apps, environment license
        minimums, the Project Team Member security role) — these require Power Platform admin
        center access and are outside Planner's own PowerShell surface entirely
      - The Planner Loop component's Cloud Policy state — see Get-LoopGovernanceAudit.ps1 in
        M365/Loop/Scripts/ for that audit, since it shares Loop's Cloud Policy mechanism
      - Actual plan/task content, usage volume, or Dataverse-resident Premium plan data

.PARAMETER TenantName
    Friendly label for the tenant being audited, used only in console output and the exported
    report filename. Does not affect connection targeting.

.PARAMETER SampleUserUPNs
    Optional array of user principal names to run the per-user license/service-plan and user-policy
    checks against. If omitted, Phase 4 (per-user checks) is skipped and explicitly reported as
    skipped rather than silently producing an empty section.

.PARAMETER OutputPath
    Directory to write the CSV report to. Defaults to the current directory.

.EXAMPLE
    .\Get-PlannerAdminAudit.ps1 -TenantName "Contoso"

    Runs the tenant-wide Basic-plan configuration and Group-creation-policy audit only, skipping
    the per-user pass, and writes a timestamped CSV report to the current directory.

.EXAMPLE
    .\Get-PlannerAdminAudit.ps1 -TenantName "Contoso" -SampleUserUPNs "alice@contoso.com","bob@contoso.com"

    Runs the full audit including per-user Basic/Premium service-plan and user-policy checks for
    the two named users.

.NOTES
    Requires: the separately-downloaded PlannerTenantAdmin PowerShell module (with its MSAL.PS
    dependency) loaded and a Global Administrator session established for Get-PlannerConfiguration/
    Get-PlannerUserPolicy — see M365/Planner/Planner-A.md, Remediation Playbook 1, for setup steps.
    Also requires Microsoft Graph PowerShell (Connect-MgGraph, scopes: Directory.Read.All,
    User.Read.All) for the Group-creation-policy and per-user license checks. This script does not
    establish those connections itself, since credential/MFA handling should remain under the
    operator's control.

    Written for Windows PowerShell 5.1 compatibility (no ??/?. operators) per this repo's usual
    scripting convention.

    Read-only. No tenant settings, licenses, or policies are created, modified, or deleted by this
    script.

    The Premium-plan org-wide toggle and the Power Platform/Dataverse environment layer (Enable
    D365 Apps, license minimums, Project Team Member role) have NO PowerShell or Graph read API as
    of this script's writing. This is the single most important manual-verification gap this
    script cannot automate — a clean report from this script does NOT confirm Premium-plan
    configuration or Dataverse environment health, only that the Basic-plan PowerShell surface and
    Group-creation policy are as reported.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantName,

    [string[]]$SampleUserUPNs = @(),

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

Write-Status "=== Microsoft Planner Admin Audit: $TenantName ===" "INFO"

# ---------------------------------------------------------------------------
# Phase 1: Preflight — module/connection checks
# ---------------------------------------------------------------------------
Write-Status "Phase 1: Preflight checks" "INFO"

$plannerAdminReady = $false
try {
    $null = Get-Command Get-PlannerConfiguration -ErrorAction Stop
    $plannerAdminReady = $true
    Write-Status "PlannerTenantAdmin module commands available — OK" "OK"
    Add-Finding -Category "Preflight" -Object "PlannerTenantAdmin module" -Status "OK" -Detail "Get-PlannerConfiguration resolved."
}
catch {
    Write-Status "Get-PlannerConfiguration not found. This is NOT a standard PowerShell Gallery module — it ships as a separate downloadable ZIP requiring the MSAL.PS dependency, a manual file-unblock step, and Global Administrator sign-in. See M365/Planner/Planner-A.md Playbook 1. Basic-plan tenant configuration checks will be skipped." "ERROR"
    Add-Finding -Category "Preflight" -Object "PlannerTenantAdmin module" -Status "FAIL" `
        -Detail "Not loaded. Download from the official Microsoft Learn 'Prerequisites for making Planner changes in Windows PowerShell' article, install MSAL.PS, unblock the .psm1, and Import-Module by explicit path under a Global Administrator session."
}

$graphConnected = $false
try {
    $ctx = Get-MgContext -ErrorAction Stop
    if ($null -ne $ctx) {
        $graphConnected = $true
        Write-Status "Microsoft Graph PowerShell session active — OK" "OK"
        Add-Finding -Category "Preflight" -Object "Microsoft Graph session" -Status "OK" -Detail "Connected as $($ctx.Account)."
    }
    else {
        throw "No context"
    }
}
catch {
    Write-Status "No active Microsoft Graph PowerShell session detected. Run Connect-MgGraph first. Group-creation-policy and per-user license checks will be skipped." "WARN"
    Add-Finding -Category "Preflight" -Object "Microsoft Graph session" -Status "WARN" `
        -Detail "Not connected — run Connect-MgGraph -Scopes Directory.Read.All,User.Read.All to enable Phases 3-4."
}

Write-Status "REMINDER: The Premium (Project for the web) org-wide toggle and the entire Power Platform/Dataverse environment layer have NO PowerShell/Graph read API. This script cannot verify either — check manually." "WARN"
Add-Finding -Category "Preflight" -Object "Premium org-wide toggle + Dataverse environment layer" -Status "LIMITED" `
    -Detail "No PowerShell/Graph API exists to read the M365 admin center Project settings page or Power Platform admin center environment state. Verify manually: Settings > Org Settings > Project (M365 admin center), and Environments > [target] > Enable D365 Apps / license posture (Power Platform admin center)."

# ---------------------------------------------------------------------------
# Phase 2: Basic-plan tenant configuration
# ---------------------------------------------------------------------------
if ($plannerAdminReady) {
    Write-Status "Phase 2: Basic-plan tenant configuration (Set/Get-PlannerConfiguration)" "INFO"

    try {
        $config = Get-PlannerConfiguration -ErrorAction Stop

        $isPlannerAllowed = $config.IsPlannerAllowed
        $allowRoster = $config.AllowRosterCreation
        $allowCalendar = $config.AllowCalendarSharing

        Write-Status "  IsPlannerAllowed: $isPlannerAllowed" $(if ($isPlannerAllowed) { "OK" } else { "WARN" })
        Add-Finding -Category "BasicPlanConfig" -Object "IsPlannerAllowed" -Status $(if ($isPlannerAllowed) { "OK" } else { "WARN" }) `
            -Detail "Value=$isPlannerAllowed. Basic-plan master switch ONLY — has zero effect on Premium (Dataverse-backed) plans or the Planner Loop component."

        Write-Status "  AllowRosterCreation: $allowRoster" "INFO"
        Add-Finding -Category "BasicPlanConfig" -Object "AllowRosterCreation" -Status "INFO" `
            -Detail "Value=$allowRoster. Governs NEW Roster (groupless plan) creation only — not retroactive to existing Rosters, which self-delete only when their last member is removed."

        if ($allowCalendar) {
            Write-Status "  AllowCalendarSharing: $allowCalendar — unauthenticated iCalendar export links are enabled tenant-wide." "WARN"
        }
        else {
            Write-Status "  AllowCalendarSharing: $allowCalendar" "OK"
        }
        Add-Finding -Category "BasicPlanConfig" -Object "AllowCalendarSharing" -Status $(if ($allowCalendar) { "WARN" } else { "OK" }) `
            -Detail "Value=$allowCalendar. When enabled, 'Add My Tasks to Outlook calendar' iCalendar links carry NO authentication — anyone with the link can view synced task details."
    }
    catch {
        Write-Status "Unable to read Get-PlannerConfiguration: $($_.Exception.Message)" "ERROR"
        Add-Finding -Category "BasicPlanConfig" -Object "Get-PlannerConfiguration" -Status "ERROR" -Detail $_.Exception.Message
    }
}
else {
    Write-Status "Phase 2 skipped — PlannerTenantAdmin module not loaded." "WARN"
    Add-Finding -Category "BasicPlanConfig" -Object "N/A" -Status "SKIPPED" -Detail "PlannerTenantAdmin module not available in this session."
}

# ---------------------------------------------------------------------------
# Phase 3: Microsoft 365 Group creation policy (gates Basic/Group-backed plan creation)
# ---------------------------------------------------------------------------
if ($graphConnected) {
    Write-Status "Phase 3: Microsoft 365 Group creation policy (Basic-plan creation dependency)" "INFO"

    try {
        $groupSettings = Get-MgBetaDirectorySetting -ErrorAction Stop |
            Where-Object { $_.DisplayName -eq "Group.Unified" }

        if ($null -eq $groupSettings) {
            Write-Status "No tenant-level 'Group.Unified' directory setting found — default (unrestricted) Group creation applies, which means Basic-plan creation is effectively unrestricted for all users." "INFO"
            Add-Finding -Category "GroupCreationPolicy" -Object "Group.Unified" -Status "INFO" `
                -Detail "No custom directory setting present. Default behaviour: all users can create Microsoft 365 Groups, and therefore Basic-plan-backing Groups, without restriction."
        }
        else {
            $enableGroupCreation = ($groupSettings.Values | Where-Object Name -eq "EnableGroupCreation").Value
            $groupCreationAllowedGroupId = ($groupSettings.Values | Where-Object Name -eq "GroupCreationAllowedGroupId").Value

            Write-Status "  EnableGroupCreation: $enableGroupCreation" $(if ($enableGroupCreation -eq "True") { "INFO" } else { "WARN" })
            Add-Finding -Category "GroupCreationPolicy" -Object "EnableGroupCreation" -Status "INFO" `
                -Detail "Value=$enableGroupCreation. When False, Group (and therefore Basic-plan) creation is restricted to members of GroupCreationAllowedGroupId=$groupCreationAllowedGroupId. This is an Entra ID control, not a Planner setting — do not search for a Planner-native equivalent."
        }
    }
    catch {
        Write-Status "Unable to read Group.Unified directory setting: $($_.Exception.Message)" "ERROR"
        Add-Finding -Category "GroupCreationPolicy" -Object "Get-MgBetaDirectorySetting" -Status "ERROR" -Detail $_.Exception.Message
    }
}
else {
    Write-Status "Phase 3 skipped — no Microsoft Graph session." "WARN"
    Add-Finding -Category "GroupCreationPolicy" -Object "N/A" -Status "SKIPPED" -Detail "No active Microsoft Graph session."
}

# ---------------------------------------------------------------------------
# Phase 4: Per-user Basic/Premium service-plan and user-policy audit
# ---------------------------------------------------------------------------
if ($graphConnected -and $SampleUserUPNs.Count -gt 0) {
    Write-Status "Phase 4: Per-user service-plan and user-policy audit ($($SampleUserUPNs.Count) user(s))" "INFO"

    foreach ($upn in $SampleUserUPNs) {
        try {
            $licenseDetails = Get-MgUserLicenseDetail -UserId $upn -ErrorAction Stop
            $allServicePlans = $licenseDetails | ForEach-Object { $_.ServicePlans } | Where-Object {
                $_.ServicePlanName -match "PROJECTWORKMANAGEMENT|PROJECT_P1|PROJECT_PROFESSIONAL"
            }

            if ($allServicePlans.Count -eq 0) {
                Write-Status "  $upn : no Planner-relevant service plans found on any assigned license." "WARN"
                Add-Finding -Category "UserLicense" -Object $upn -Status "WARN" `
                    -Detail "No PROJECTWORKMANAGEMENT/PROJECT_P1/PROJECT_PROFESSIONAL service plan found across assigned licenses. User likely has no Planner (Basic or Premium) access at all."
            }
            else {
                foreach ($sp in $allServicePlans) {
                    $status = if ($sp.ProvisioningStatus -eq "Success") { "OK" } else { "WARN" }
                    Write-Status "  $upn : $($sp.ServicePlanName) = $($sp.ProvisioningStatus)" $status
                    Add-Finding -Category "UserLicense" -Object "$upn : $($sp.ServicePlanName)" -Status $status `
                        -Detail "ProvisioningStatus=$($sp.ProvisioningStatus). PROJECTWORKMANAGEMENT=Basic plans; PROJECT_P1/PROJECT_PROFESSIONAL=Premium (Dataverse-backed) plans. Check independently of parent SKU assignment — a service plan can be disabled while the SKU itself remains assigned."
                }
            }
        }
        catch {
            Write-Status "  $upn : unable to retrieve license detail — $($_.Exception.Message)" "ERROR"
            Add-Finding -Category "UserLicense" -Object $upn -Status "ERROR" -Detail $_.Exception.Message
        }

        if ($plannerAdminReady) {
            try {
                $userPolicy = Get-PlannerUserPolicy -UserAadIdOrPrincipalName $upn -ErrorAction Stop
                Write-Status "  $upn : BlockDeleteTasksNotCreatedBySelf = $($userPolicy.blockDeleteTasksNotCreatedBySelf)" "INFO"
                Add-Finding -Category "UserPolicy" -Object $upn -Status "INFO" `
                    -Detail "blockDeleteTasksNotCreatedBySelf=$($userPolicy.blockDeleteTasksNotCreatedBySelf). Applies to Basic plans only."
            }
            catch {
                Write-Status "  $upn : unable to retrieve Planner user policy — $($_.Exception.Message)" "WARN"
                Add-Finding -Category "UserPolicy" -Object $upn -Status "WARN" -Detail $_.Exception.Message
            }
        }
    }
}
elseif ($SampleUserUPNs.Count -eq 0) {
    Write-Status "Phase 4 skipped — no -SampleUserUPNs supplied." "INFO"
    Add-Finding -Category "UserLicense" -Object "N/A" -Status "SKIPPED" -Detail "No sample users supplied via -SampleUserUPNs. Re-run with specific UPNs to audit per-user Basic/Premium service-plan and user-policy state."
}
else {
    Write-Status "Phase 4 skipped — no Microsoft Graph session." "WARN"
    Add-Finding -Category "UserLicense" -Object "N/A" -Status "SKIPPED" -Detail "No active Microsoft Graph session."
}

# ---------------------------------------------------------------------------
# Phase 5: Explicit configuration/governance gaps this script cannot audit
# ---------------------------------------------------------------------------
Write-Status "Phase 5: Known gaps not covered by this script (reported explicitly, not silently omitted)" "INFO"

Add-Finding -Category "KnownGap" -Object "Premium (Project for the web) org-wide toggle" -Status "LIMITED" `
    -Detail "No PowerShell/Graph read API. Verify manually: Microsoft 365 admin center > Settings > Org Settings > Project > 'Turn on Project for the web for your organization' and 'Turn on Roadmap for your organization' (two separate checkboxes)."
Add-Finding -Category "KnownGap" -Object "Dataverse environment 'Enable D365 Apps' state" -Status "LIMITED" `
    -Detail "No PowerShell check in this script covers this reliably across all tenant configurations. Verify manually in the Power Platform admin center for any environment Premium Planner plans are expected to use — Project cannot deploy into an environment with this toggle on."
Add-Finding -Category "KnownGap" -Object "Dataverse environment license-minimum posture" -Status "LIMITED" `
    -Detail "1 Project license is sufficient for the Default Environment; Production environments require a minimum of 5. This script does not reconcile assigned Premium licenses against environment-provisioning targets — verify manually in the Power Platform admin center."
Add-Finding -Category "KnownGap" -Object "Project Team Member Dataverse security role" -Status "LIMITED" `
    -Detail "This customizable Dataverse role governs in-project access independent of Planner's own sharing model. No PowerShell check in this script reads its current configuration — verify manually in the Power Platform admin center if a Premium-plan access complaint doesn't resolve via license/environment checks alone."
Add-Finding -Category "KnownGap" -Object "Roadmap Power Platform DLP connector state" -Status "LIMITED" `
    -Detail "The Project Roadmap connector (shared_projectroadmap) does not reliably appear in the Power Platform DLP policy GUI and may need to be added via Add-CustomConnectorToPolicy (PowerApps Administrator module). This script does not check DLP policy connector membership — verify manually if Roadmap access is inconsistent despite the org-wide toggle being on."
Add-Finding -Category "KnownGap" -Object "Roster vs. Group-backed Basic plan inventory" -Status "LIMITED" `
    -Detail "This script does not enumerate individual plans or distinguish Roster-backed from Group-backed Basic plans tenant-wide — Microsoft Graph's Planner plan listing is not reliably enumerable without a starting Group/user/Roster ID. For a specific plan, use Get-MgPlannerPlan against a known container ID instead."

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Status "=== Audit Summary ===" "INFO"
$findings | Format-Table -AutoSize

$reportFile = Join-Path -Path $OutputPath -ChildPath "PlannerAdminAudit-$TenantName-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$findings | Export-Csv -Path $reportFile -NoTypeInformation
Write-Status "Report exported to: $reportFile" "OK"

$warnCount = ($findings | Where-Object { $_.Status -in @("WARN", "ERROR", "FAIL") }).Count
if ($warnCount -gt 0) {
    Write-Status "$warnCount finding(s) need attention — review the report, and remember to separately verify the Premium org-wide toggle and Dataverse environment layer manually before declaring this tenant's Planner configuration fully audited." "WARN"
}
else {
    Write-Status "No blocking findings detected in the PowerShell/Graph-readable settings — still verify the Premium org-wide toggle and Dataverse environment layer manually, since this script cannot read either." "OK"
}
