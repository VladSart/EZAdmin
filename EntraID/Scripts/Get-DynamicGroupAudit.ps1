<#
.SYNOPSIS
    Tenant-wide dynamic group hygiene audit — paused processing, zero-member
    rules, and licensing prerequisite check in one pass.

.DESCRIPTION
    Implements DynamicGroups-A.md's Remediation Playbook 1 as a reusable,
    parameterized script (the runbook shows this inline; this is the
    standalone, exportable version referenced by the manifest's script-gap
    tracking) plus additional checks pulled from the same runbook's Symptom →
    Cause Map and Validation Steps:
    - Enumerates every dynamic group in the tenant (groupTypes contains
      DynamicMembership) and its MembershipRuleProcessingState
    - Flags groups with MembershipRuleProcessingState = Paused — per
      DynamicGroups-B.md Fix 1, this is "the most commonly missed check" and
      explains most "nothing is updating" tickets by itself
    - Flags groups with zero current members — a syntactically valid rule can
      still match nobody (DynamicGroups-A.md "How It Works" / Learning
      Pointers), and this never surfaces as an error to the admin
    - Confirms tenant-wide Entra ID P1/P2 licensing is present, since
      licensing lapses silently stop new evaluation without deleting the
      group or rule (DynamicGroups-A.md Symptom → Cause Map)
    - Surfaces the raw MembershipRule text for every flagged group so an
      operator can spot obvious typos/case issues without opening the portal

    Read-only — makes no changes to any group, rule, or processing state.
    Exports full results to CSV; recommended to run quarterly as a hygiene
    check per DynamicGroups-A.md Playbook 1's guidance.

    Does NOT cover:
    - Validating a rule against a SPECIFIC user's actual attributes — there is
      no Graph API equivalent to the portal's "Validate Rules" tab; see
      DynamicGroups-B.md Diagnosis Step 2/3 for that per-user, portal-only check
    - Device-attribute dynamic groups' device-specific attributes
      (deviceOSType, deviceOwnership) — included in the rule text output but
      not independently validated
    - Downstream consumer lag (CA token refresh timing, Intune check-in
      cadence) — see DynamicGroups-A.md Phase 4 for that, which is inherently
      per-consumer and not auditable from the group object alone

.PARAMETER FlagZeroMemberThresholdHours
    Only flag a zero-member group if it was created more than this many hours
    ago, to avoid false-positives on groups that are brand new and simply
    haven't been evaluated yet. Default: 24.

.PARAMETER OutputPath
    Path for the CSV export. Default: .\DynamicGroupAudit-<timestamp>.csv

.EXAMPLE
    .\Get-DynamicGroupAudit.ps1

    Runs the full tenant audit with default settings and exports to CSV.

.EXAMPLE
    .\Get-DynamicGroupAudit.ps1 -FlagZeroMemberThresholdHours 72 -OutputPath C:\Reports\DynGroups.csv

    Gives newly created groups 3 days of grace before flagging as
    zero-member, and writes the export to a specific path.

.NOTES
    Requires: Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement
              PowerShell SDK modules
    Scopes needed: Group.Read.All, GroupMember.Read.All, Organization.Read.All
    Run As: An account with Directory Reader or Global Reader role — does not
            require write permissions
    Safe: Read-only — no groups, rules, or processing states are changed
    Cross-references: EntraID/Troubleshooting/DynamicGroups-B.md (Fix 1-5) and
                       DynamicGroups-A.md (Playbook 1, Symptom → Cause Map)
#>

[CmdletBinding()]
param(
    [int]$FlagZeroMemberThresholdHours = 24,

    [string]$OutputPath = ".\DynamicGroupAudit-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---- Preflight ----
Write-Status "Checking Microsoft.Graph.Groups module..." "INFO"
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Groups)) {
    Write-Status "Microsoft.Graph.Groups module not found. Install with: Install-Module Microsoft.Graph.Groups -Scope CurrentUser" "ERROR"
    return
}

try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Not connected to Graph. Connecting with required scopes..." "WARN"
        Connect-MgGraph -Scopes "Group.Read.All", "GroupMember.Read.All", "Organization.Read.All" -NoWelcome
    }
    else {
        Write-Status "Connected to Graph as $($context.Account) [tenant: $($context.TenantId)]" "OK"
    }
}
catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    return
}

# ---- Detect: tenant licensing prerequisite ----
Write-Status "Checking tenant-wide Entra ID P1/P2 licensing..." "INFO"
$hasDynamicGroupLicense = $false
try {
    $skus = Get-MgSubscribedSku -ErrorAction Stop
    $hasDynamicGroupLicense = [bool]($skus | Where-Object { $_.SkuPartNumber -match "AAD_PREMIUM|SPE_E3|SPE_E5|M365_E3|M365_E5|ENTERPRISEPREMIUM|ENTERPRISEPACK" })
    if ($hasDynamicGroupLicense) {
        Write-Status "Tenant holds at least one SKU that includes Entra ID P1/P2 — dynamic groups feature should be unlocked." "OK"
    }
    else {
        Write-Status "No SKU found that clearly includes Entra ID P1/P2. Dynamic groups may fail to evaluate if licensing has lapsed. Verify manually." "WARN"
    }
}
catch {
    Write-Status "Failed to retrieve tenant SKUs: $($_.Exception.Message)" "WARN"
}

# ---- Detect: enumerate all dynamic groups ----
Write-Status "Retrieving all dynamic groups in the tenant..." "INFO"
$dynamicGroups = @()
try {
    $dynamicGroups = Get-MgGroup -All -Filter "groupTypes/any(c:c eq 'DynamicMembership')" `
        -Property "Id,DisplayName,GroupTypes,MembershipRule,MembershipRuleProcessingState,CreatedDateTime,SecurityEnabled,MailEnabled" `
        -ErrorAction Stop
    Write-Status "Retrieved $($dynamicGroups.Count) dynamic group(s)." "OK"
}
catch {
    Write-Status "Failed to retrieve dynamic groups: $($_.Exception.Message)" "ERROR"
    return
}

$results = [System.Collections.Generic.List[object]]::new()

foreach ($g in $dynamicGroups) {
    $memberCount = 0
    try {
        $memberCount = (Get-MgGroupMember -GroupId $g.Id -All -ErrorAction Stop).Count
    }
    catch {
        Write-Status "Could not retrieve members for group '$($g.DisplayName)': $($_.Exception.Message)" "WARN"
    }

    $ageHours = (New-TimeSpan -Start $g.CreatedDateTime -End (Get-Date).ToUniversalTime()).TotalHours
    $isPaused = $g.MembershipRuleProcessingState -eq "Paused"
    $isZeroMember = ($memberCount -eq 0) -and ($ageHours -ge $FlagZeroMemberThresholdHours)

    $flag = if ($isPaused -and $isZeroMember) { "PAUSED + ZERO MEMBERS" }
            elseif ($isPaused) { "PAUSED" }
            elseif ($isZeroMember) { "ZERO MEMBERS" }
            else { "OK" }

    $results.Add([PSCustomObject]@{
        DisplayName       = $g.DisplayName
        GroupId           = $g.Id
        ProcessingState   = $g.MembershipRuleProcessingState
        MemberCount       = $memberCount
        AgeHours          = [Math]::Round($ageHours, 1)
        SecurityEnabled   = $g.SecurityEnabled
        MailEnabled       = $g.MailEnabled
        Flag              = $flag
        MembershipRule    = $g.MembershipRule
    })
}

# ---- Report ----
Write-Host ""
Write-Host "=== Dynamic Group Audit Summary ===" -ForegroundColor Cyan
$pausedCount = ($results | Where-Object { $_.Flag -match "PAUSED" }).Count
$zeroCount = ($results | Where-Object { $_.Flag -match "ZERO MEMBERS" }).Count

Write-Status "$($results.Count) dynamic group(s) audited." "INFO"
Write-Status "$pausedCount group(s) have processing PAUSED — these will never update until resumed." $(if ($pausedCount -gt 0) { "ERROR" } else { "OK" })
Write-Status "$zeroCount group(s) have zero members and are older than $FlagZeroMemberThresholdHours hours — rule likely matches nobody." $(if ($zeroCount -gt 0) { "WARN" } else { "OK" })
if (-not $hasDynamicGroupLicense) {
    Write-Status "Licensing prerequisite could not be confirmed — verify P1/P2 coverage manually if groups are behaving unexpectedly tenant-wide." "WARN"
}
Write-Host ""

$results | Where-Object { $_.Flag -ne "OK" } | Format-Table DisplayName, ProcessingState, MemberCount, AgeHours, Flag -AutoSize
if (($results | Where-Object { $_.Flag -ne "OK" }).Count -eq 0) {
    Write-Status "No flagged groups — all dynamic groups are actively processing with non-zero membership." "OK"
}

$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Full results exported to $OutputPath" "OK"
