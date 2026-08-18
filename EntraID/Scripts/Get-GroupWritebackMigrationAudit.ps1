<#
.SYNOPSIS
    Read-only audit of Microsoft Entra Connect Sync Group Writeback v2 migration
    readiness — the scope, reference-attribute, and prerequisite checks
    GroupWritebackMigration-A.md and GroupWritebackMigration-B.md describe,
    ahead of migrating to Microsoft Entra Cloud Sync's Group Provisioning to
    Active Directory feature.

.DESCRIPTION
    Intended to run ON the Microsoft Entra Connect Sync server, with the
    ActiveDirectory RSAT module and the ADSync module available. Each check
    runs independently and is skipped with a WARN if its prerequisite
    module/connection isn't present, rather than aborting the whole audit.

    Performs five checks:

    1. FEATURE STATUS — reads GroupWritebackV2 from Get-ADSyncAADCompanyFeature.
       If disabled, most other checks are still useful for verifying a
       completed or in-progress migration, so the script continues rather
       than exiting early.

    2. SCOPE CLASSIFICATION — for every group in the supplied Group Writeback
       target OU, separates cloud-created security groups with universal
       scope (the ONLY category this migration path supports) from
       mail-enabled groups/DLs and non-universal-scope groups (out of scope,
       continue on Group Writeback v1 behavior instead). Flags
       OUT_OF_SCOPE_GROUPS_PRESENT as informational, not a blocker.

    3. REFERENCE ATTRIBUTE READINESS — compares adminDescription against
       msDS-ExternalDirectoryObjectID for every in-scope group. A mismatch
       here is the single most common root cause of "migrated but membership
       is broken" tickets, since Cloud Sync validates group membership
       references against msDS-ExternalDirectoryObjectID via the AD global
       catalog. Flags REFERENCE_ATTRIBUTE_NOT_COPIED as HIGH risk.

    4. PROVISIONING AGENT VERSION — reads the installed Cloud Sync provisioning
       agent version from the registry and compares against the documented
       minimums (1.1.1367.0 for the migration procedure itself; 1.1.1373.0 for
       the Group Provisioning to AD DS feature). Flags AGENT_VERSION_TOO_LOW
       if below the migration-procedure minimum.

    5. COEXISTENCE RULE PAIR — checks for an existing cloudNoFlow-named sync
       rule pair via Get-ADSyncRule, and reports whether both an inbound and
       an outbound half are present. Informational — a mid-migration state,
       not itself a pass/fail finding.

    Computes an overall readiness classification (READY_TO_MIGRATE /
    PREREQUISITES_INCOMPLETE / ALREADY_MIGRATED) based on which findings are
    present. This classification is a starting point for a human decision,
    not a final answer.

    Read-only throughout. Makes no changes to Active Directory, Microsoft
    Entra ID, or the Connect Sync configuration. Does NOT create the
    cloudNoFlow sync rule pair, does NOT run the adminDescription copy step,
    does NOT flip the GroupWritebackV2 feature switch, and does NOT install
    or configure the Cloud Sync agent. Exports a single summary row plus a
    per-finding CSV.

    Does NOT cover (see GroupWritebackMigration-A.md "Does not cover"):
    - Group Writeback v1 status or configuration — a separate, still-supported
      feature this migration does not touch
    - Cloud Sync Group Provisioning to AD DS job configuration or scale
      compliance once installed — see Get-CloudSyncHealth.ps1 and
      Get-CloudSyncMigrationReadiness.ps1 for general Cloud Sync agent checks
    - Whether AD DS domain controllers actually run Server 2016+ (the
      msDS-ExternalDirectoryObjectId schema prerequisite) — reported as a
      Known Gap, confirm manually via Get-ADDomainController
    - P1 licensing verification — see Get-CloudSyncMigrationReadiness.ps1's
      Check 6 for the same best-effort SKU name-match pattern, not duplicated
      here to avoid two scripts drifting out of sync on SKU name lists

.PARAMETER GroupWritebackOU
    Mandatory. The DistinguishedName of the Group Writeback target OU on the
    on-premises Active Directory side (e.g. 'OU=Groups,DC=Contoso,DC=com').

.PARAMETER MinAgentVersionForMigration
    The minimum Cloud Sync provisioning agent version documented as required
    for the migration procedure itself. Defaults to '1.1.1367.0'. Exposed as
    a parameter since this is a published minimum that could change in a
    future Cloud Sync release — re-verify against the current migration guide
    before trusting the default indefinitely.

.PARAMETER MinAgentVersionForFeature
    The minimum Cloud Sync provisioning agent version documented as required
    for the Group Provisioning to AD DS feature itself (higher than the
    migration-procedure minimum). Defaults to '1.1.1373.0'.

.PARAMETER OutputPath
    Folder where the CSV reports are written. Defaults to
    $env:TEMP\GroupWritebackMigrationAudit-<timestamp>.

.EXAMPLE
    .\Get-GroupWritebackMigrationAudit.ps1 -GroupWritebackOU 'OU=Groups,DC=Contoso,DC=com'

    Standard readiness audit against the specified Group Writeback target OU.

.EXAMPLE
    .\Get-GroupWritebackMigrationAudit.ps1 -GroupWritebackOU 'OU=Groups,DC=Contoso,DC=com' -MinAgentVersionForFeature '1.1.1400.0'

    Audit with a tighter agent-version floor, if a newer minimum has since
    been published and the default hasn't been updated yet.

.NOTES
    Requires: ActiveDirectory RSAT module (Checks 2-3); ADSync module, present
              on any Connect Sync server (Checks 1, 5). Any missing
              prerequisite causes that specific check to be skipped with a
              WARN, not a script abort.
    Run As:   Any account with AD read access to the specified OU. Reading
              GroupWritebackV2 status and sync rules typically requires local
              admin on the Connect Sync server (standard ADSync module
              behavior) — no elevated Entra role is required for these
              read-only checks.
    Safe:     Fully read-only — no New-/Set-/Remove- cmdlets against AD, Entra
              ID, or the Connect Sync configuration anywhere in this script.
    Cross-references: EntraID/Troubleshooting/GroupWritebackMigration-B.md
                       (Triage, Fix 1-8) and GroupWritebackMigration-A.md
                       (Playbook 1 readiness assessment, Validation Steps).
    Compatible with Windows PowerShell 5.1 and PowerShell 7+.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$GroupWritebackOU,

    [string]$MinAgentVersionForMigration = '1.1.1367.0',

    [string]$MinAgentVersionForFeature = '1.1.1373.0',

    [string]$OutputPath = "$env:TEMP\GroupWritebackMigrationAudit-$(Get-Date -Format 'yyyyMMdd-HHmm')"
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

function Compare-AgentVersion {
    param([string]$Installed, [string]$Minimum)
    try {
        return ([version]$Installed) -ge ([version]$Minimum)
    }
    catch {
        return $null
    }
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$findings = [System.Collections.Generic.List[object]]::new()

# =====================================================================
# CHECK 1 — GroupWritebackV2 feature status
# =====================================================================
Write-Status "Checking GroupWritebackV2 feature status..." "INFO"
$gwbV2Enabled = $null
try {
    Import-Module ADSync -ErrorAction Stop
    $gwbV2Enabled = (Get-ADSyncAADCompanyFeature -ErrorAction Stop).GroupWritebackV2

    if ($gwbV2Enabled) {
        Write-Status "GroupWritebackV2 is currently ENABLED — migration not yet started or in progress." "INFO"
    }
    else {
        Write-Status "GroupWritebackV2 is currently DISABLED — migration already completed, or the feature was never enabled on this tenant." "OK"
        $findings.Add([PSCustomObject]@{
            Category = "FeatureStatus"; Flag = "GWB_V2_ALREADY_DISABLED"
            Detail = "GroupWritebackV2 is already disabled. If this is unexpected, confirm whether the migration to Cloud Sync Group Provisioning to AD was actually completed, or whether the feature was simply never turned on for this tenant."
            RiskLevel = "INFO"
        })
    }
}
catch {
    Write-Status "Could not read GroupWritebackV2 status (ADSync module unavailable — not running on a Connect Sync server?): $($_.Exception.Message)" "WARN"
}

# =====================================================================
# CHECK 2 — Scope classification (in-scope vs. out-of-scope groups)
# =====================================================================
Write-Status "Classifying groups in '$GroupWritebackOU' by migration scope..." "INFO"
$inScopeGroups = @()
$outOfScopeGroups = @()
try {
    $props = @('mail', 'GroupScope', 'adminDescription')
    $allGroups = Get-ADGroup -Filter * -SearchBase $GroupWritebackOU -Properties $props -ErrorAction Stop

    $inScopeGroups    = $allGroups | Where-Object { -not $_.mail -and $_.GroupScope -eq 'Universal' }
    $outOfScopeGroups = $allGroups | Where-Object { $_.mail -or $_.GroupScope -ne 'Universal' }

    Write-Status "$($inScopeGroups.Count) in-scope group(s) (cloud-created security, universal scope). $($outOfScopeGroups.Count) out-of-scope group(s) (mail-enabled/DL or non-universal scope — stay on Group Writeback v1)." "OK"

    if ($outOfScopeGroups.Count -gt 0) {
        $names = ($outOfScopeGroups | Select-Object -First 10 -ExpandProperty Name) -join '; '
        $findings.Add([PSCustomObject]@{
            Category = "Scope"; Flag = "OUT_OF_SCOPE_GROUPS_PRESENT"
            Detail = "$($outOfScopeGroups.Count) group(s) found that are mail-enabled or non-universal scope (first 10: $names). NOT a blocker — these are expected to remain on Group Writeback v1 behavior and are excluded from this migration procedure by design. See GroupWritebackMigration-B.md Fix 2."
            RiskLevel = "INFO"
        })
    }
}
catch {
    Write-Status "Could not enumerate groups in the specified OU (ActiveDirectory module unavailable, bad OU path, or access denied): $($_.Exception.Message)" "WARN"
}

# =====================================================================
# CHECK 3 — Reference attribute readiness (adminDescription -> msDS-ExternalDirectoryObjectID)
# =====================================================================
Write-Status "Checking adminDescription / msDS-ExternalDirectoryObjectID alignment for in-scope groups..." "INFO"
try {
    if ($inScopeGroups.Count -gt 0) {
        $inScopeWithExtId = Get-ADGroup -Filter * -SearchBase $GroupWritebackOU -Properties adminDescription, msDS-ExternalDirectoryObjectID -ErrorAction Stop |
            Where-Object { $_.DistinguishedName -in $inScopeGroups.DistinguishedName }

        $mismatched = $inScopeWithExtId | Where-Object { $_.adminDescription -ne $_.'msDS-ExternalDirectoryObjectID' }

        if ($mismatched.Count -gt 0) {
            $names = ($mismatched | Select-Object -First 10 -ExpandProperty Name) -join '; '
            $findings.Add([PSCustomObject]@{
                Category = "ReferenceAttribute"; Flag = "REFERENCE_ATTRIBUTE_NOT_COPIED"
                Detail = "$($mismatched.Count) in-scope group(s) have a mismatched or missing msDS-ExternalDirectoryObjectID vs. adminDescription (first 10: $names). Cloud Sync validates group membership references against msDS-ExternalDirectoryObjectID via the AD global catalog — without this copy step completed, migrated groups will show empty or broken membership. See GroupWritebackMigration-B.md Fix 3 for the copy script."
                RiskLevel = "HIGH"
            })
            Write-Status "$($mismatched.Count) in-scope group(s) are missing the reference-attribute copy — HIGH risk, run the copy script before migrating." "ERROR"
        }
        else {
            Write-Status "All in-scope groups have a matching msDS-ExternalDirectoryObjectID value." "OK"
        }
    }
    else {
        Write-Status "No in-scope groups to check (see Check 2)." "INFO"
    }
}
catch {
    Write-Status "Could not compare reference attributes: $($_.Exception.Message)" "WARN"
}

# =====================================================================
# CHECK 4 — Provisioning agent version
# =====================================================================
Write-Status "Checking installed Cloud Sync provisioning agent version..." "INFO"
$agentVersion = $null
try {
    $agentVersion = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Azure AD Connect Provisioning Agent' -ErrorAction Stop).DisplayVersion

    if ($agentVersion) {
        $meetsMigrationMin = Compare-AgentVersion -Installed $agentVersion -Minimum $MinAgentVersionForMigration
        $meetsFeatureMin   = Compare-AgentVersion -Installed $agentVersion -Minimum $MinAgentVersionForFeature

        if ($meetsMigrationMin -eq $false) {
            $findings.Add([PSCustomObject]@{
                Category = "AgentVersion"; Flag = "AGENT_VERSION_TOO_LOW"
                Detail = "Installed provisioning agent version ($agentVersion) is below the documented migration-procedure minimum ($MinAgentVersionForMigration). Upgrade before proceeding. See GroupWritebackMigration-B.md Fix 4."
                RiskLevel = "HIGH"
            })
            Write-Status "Agent version $agentVersion is below the migration minimum ($MinAgentVersionForMigration)." "ERROR"
        }
        elseif ($meetsFeatureMin -eq $false) {
            $findings.Add([PSCustomObject]@{
                Category = "AgentVersion"; Flag = "AGENT_BELOW_FEATURE_MINIMUM"
                Detail = "Installed provisioning agent version ($agentVersion) meets the migration-procedure minimum ($MinAgentVersionForMigration) but is below the Group Provisioning to AD DS feature minimum ($MinAgentVersionForFeature). Upgrade before configuring the Cloud Sync group-provisioning job."
                RiskLevel = "MEDIUM"
            })
            Write-Status "Agent version $agentVersion meets the migration minimum but is below the feature minimum ($MinAgentVersionForFeature)." "WARN"
        }
        else {
            Write-Status "Agent version $agentVersion meets both the migration and feature minimums." "OK"
        }
    }
}
catch {
    Write-Status "Could not read provisioning agent version from the registry (agent not installed on this host, or registry path changed): $($_.Exception.Message)" "WARN"
}

# =====================================================================
# CHECK 5 — cloudNoFlow coexistence rule pair (informational)
# =====================================================================
Write-Status "Checking for an existing cloudNoFlow coexistence rule pair..." "INFO"
try {
    Import-Module ADSync -ErrorAction Stop
    $cloudNoFlowRules = Get-ADSyncRule -ErrorAction Stop | Where-Object { $_.Name -match 'cloudNoFlow' }
    $inbound  = $cloudNoFlowRules | Where-Object { $_.Direction -eq 'Inbound' }
    $outbound = $cloudNoFlowRules | Where-Object { $_.Direction -eq 'Outbound' }

    if ($cloudNoFlowRules.Count -eq 0) {
        Write-Status "No cloudNoFlow rules found — migration not yet started, or coexistence rules use different naming." "INFO"
    }
    elseif ($inbound.Count -gt 0 -and $outbound.Count -gt 0) {
        Write-Status "Both inbound and outbound cloudNoFlow rules found — migration appears to be in progress or complete." "OK"
        $findings.Add([PSCustomObject]@{
            Category = "CoexistenceRules"; Flag = "COEXISTENCE_RULE_PAIR_PRESENT"
            Detail = "Found $($inbound.Count) inbound and $($outbound.Count) outbound rule(s) matching 'cloudNoFlow'. Verify the scope conditions match the documented pattern (inbound: cloudMastered=true AND mail=ISNULL; outbound: cloudNoFlow=true) rather than assuming naming alone confirms correct configuration."
            RiskLevel = "INFO"
        })
    }
    else {
        $findings.Add([PSCustomObject]@{
            Category = "CoexistenceRules"; Flag = "COEXISTENCE_RULE_PAIR_INCOMPLETE"
            Detail = "Found $($inbound.Count) inbound and $($outbound.Count) outbound rule(s) matching 'cloudNoFlow' — only one half of the pair is present. Migration may be mid-configuration; complete the missing half before proceeding. See GroupWritebackMigration-B.md Diagnosis step 4."
            RiskLevel = "MEDIUM"
        })
        Write-Status "Only one half of the cloudNoFlow rule pair found — incomplete coexistence configuration." "WARN"
    }
}
catch {
    Write-Status "Could not read Connect Sync rules (ADSync module unavailable — not running on a Connect Sync server?): $($_.Exception.Message)" "WARN"
}

# =====================================================================
# Overall readiness classification
# =====================================================================
$highFindings = $findings | Where-Object { $_.RiskLevel -eq "HIGH" }
$medFindings  = $findings | Where-Object { $_.RiskLevel -eq "MEDIUM" }

$classification = if ($gwbV2Enabled -eq $false -and $highFindings.Count -eq 0) {
    "ALREADY_MIGRATED"
}
elseif ($highFindings.Count -gt 0 -or $medFindings.Count -gt 0) {
    "PREREQUISITES_INCOMPLETE"
}
else {
    "READY_TO_MIGRATE"
}

# =====================================================================
# Report
# =====================================================================
Write-Host ""
Write-Host "=== Group Writeback v2 -> Cloud Sync Migration Readiness Summary ===" -ForegroundColor Cyan
Write-Status "Overall classification: $classification" $(switch ($classification) { "READY_TO_MIGRATE" { "OK" } "ALREADY_MIGRATED" { "OK" } "PREREQUISITES_INCOMPLETE" { "WARN" } default { "INFO" } })
Write-Status "$($highFindings.Count) HIGH-risk finding(s), $($medFindings.Count) MEDIUM-risk finding(s)." $(if ($highFindings.Count -gt 0) { "ERROR" } elseif ($medFindings.Count -gt 0) { "WARN" } else { "OK" })

if ($findings.Count -gt 0) {
    Write-Host ""
    Write-Host "--- Findings ---" -ForegroundColor Yellow
    $findings | Select-Object Category, Flag, RiskLevel, Detail | Format-Table -AutoSize -Wrap
}

Write-Host ""
Write-Host "KNOWN GAPS (not covered by this script — see .DESCRIPTION and GroupWritebackMigration-A.md):" -ForegroundColor DarkGray
Write-Host " - Group Writeback v1 status/configuration — a separate, still-supported feature, not audited here" -ForegroundColor DarkGray
Write-Host " - Cloud Sync Group Provisioning to AD DS job configuration/scale once installed — see Get-CloudSyncHealth.ps1 and Get-CloudSyncMigrationReadiness.ps1" -ForegroundColor DarkGray
Write-Host " - Domain controller OS version (Server 2016+ required for msDS-ExternalDirectoryObjectId) — confirm manually via Get-ADDomainController" -ForegroundColor DarkGray
Write-Host " - Entra ID P1 licensing verification — see Get-CloudSyncMigrationReadiness.ps1 Check 6" -ForegroundColor DarkGray
Write-Host " - This script is assessment-only — it does not copy adminDescription, create the cloudNoFlow rule pair, or flip the GroupWritebackV2 switch" -ForegroundColor DarkGray

$reportPath = Join-Path $OutputPath "GroupWritebackMigrationAudit_$(Get-Date -Format yyyyMMdd).csv"
[PSCustomObject]@{
    GroupWritebackV2Enabled      = $gwbV2Enabled
    InScopeGroupCount            = $inScopeGroups.Count
    OutOfScopeGroupCount         = $outOfScopeGroups.Count
    ProvisioningAgentVersion     = $agentVersion
    OverallClassification        = $classification
    HighRiskFindingCount         = $highFindings.Count
    MediumRiskFindingCount       = $medFindings.Count
    CollectedAt                  = Get-Date
} | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8

$findingsPath = Join-Path $OutputPath "Findings.csv"
$findings | Export-Csv -Path $findingsPath -NoTypeInformation -Encoding UTF8

Write-Status "Summary report exported to $reportPath" "OK"
Write-Status "Findings exported to $findingsPath" "OK"
