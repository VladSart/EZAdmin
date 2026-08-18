<#
.SYNOPSIS
    Read-only Entra Connect Sync -> Entra Cloud Sync migration readiness audit —
    the scale, device-sync, and sync-rule checks CloudSyncMigration-A.md and
    CloudSyncMigration-B.md describe, scored against Microsoft's own three-tier
    readiness model (Ready Now / Plan Near-Term / Evaluate Future).

.DESCRIPTION
    Intended to run on (or from a management session with line-of-sight to) the
    Microsoft Entra Connect Sync server, with the ActiveDirectory RSAT module,
    the ADSync module, and an active Microsoft Graph connection
    (Connect-MgGraph -Scopes "Device.Read.All,Domain.Read.All,Organization.Read.All")
    all available. Each check runs independently and is skipped with a WARN if
    its prerequisite module/connection isn't present, rather than aborting the
    whole audit.

    Performs six checks:

    1. AD OBJECT SCALE — combined User+Group+Contact count via the ActiveDirectory
       module, compared against Cloud Sync's documented 150,000-objects-per-domain
       limit. Flags SCALE_EXCEEDS_OBJECT_LIMIT if over.

    2. LARGEST GROUP SIZE — opt-in only (see -IncludeGroupSizeScan), since walking
       every AD group's full membership can be slow on a large directory. When run,
       flags SCALE_EXCEEDS_GROUP_LIMIT for any group at or above Cloud Sync's
       50,000-member cap (also the Group Provisioning to AD DS cap).

    3. HYBRID AZURE AD JOIN DEPENDENCY — queries Microsoft Graph for devices with
       trustType 'ServerAd' (the documented value for Hybrid Azure AD joined
       devices). Any non-zero count flags HYBRID_JOIN_DEPENDENCY, since Cloud Sync
       has no device-sync equivalent — this is the most common near-term blocker.

    4. ADVANCED SYNC RULES — enumerates non-default Connect Sync rules via
       Get-ADSyncRule. A non-zero count flags ADVANCED_SYNC_RULES_PRESENT as a
       MEDIUM-risk finding requiring manual review against the current Cloud Sync
       feature-comparison table — this script cannot determine whether a given
       custom rule has a Cloud Sync equivalent.

    5. PTA / ADFS FEDERATION — informational only, NOT a migration blocker. Checks
       for the PTA agent service locally and federated domains via Microsoft Graph.
       Both remain independently configured and functional after a Cloud Sync
       migration per Microsoft's own migration FAQ.

    6. LICENSE — best-effort SubscribedSku SkuPartNumber name-matching for an
       Entra ID P1-or-higher SKU (AAD_PREMIUM/AAD_PREMIUM_P2/ENTERPRISEPREMIUM-
       family name fragments), explicitly framed as needing manual verification —
       consistent with this repo's standing discipline of never hardcoding a SKU
       GUID as if it were universal across tenants/clouds.

    Computes an overall readiness classification (READY_NOW / PLAN_NEAR_TERM /
    EVALUATE_FUTURE) mirroring Microsoft's own three-tier decision framework, based
    on which HIGH-risk findings are present. This classification is a starting
    point for a human decision, not a final answer — always cross-reference the
    live decision guide before committing to a migration timeline.

    Read-only throughout. Makes no changes to Active Directory, Microsoft Entra ID,
    or the Connect Sync configuration. Does NOT create the cloudNoFlow sync rule
    pair, does NOT install the Cloud Sync agent, and does NOT stop/start the
    Connect Sync scheduler. Exports a single summary row plus a per-finding CSV.

    Does NOT cover (see CloudSyncMigration-A.md "Does not cover"):
    - Whether a specific custom sync rule has a Cloud Sync expression-builder
      equivalent — that requires reading each rule's actual transform logic
    - Cross-forest / disconnected-forest topology classification — reported as a
      Known Gap, confirm manually against the AD Sites and Services / forest trust
      configuration
    - Entra Connect Sync's own version/EOL status — see
      Get-ConnectSyncVersionAudit.ps1 for that separate check
    - Actually performing any part of the migration — this script is
      assessment-only, see CloudSyncMigration-B.md for the fix/playbook steps

.PARAMETER IncludeGroupSizeScan
    Switch. When set, walks every AD group's membership count to find the
    largest group (Check 2). Off by default because this can be slow on a large
    directory — opt in deliberately when group scale is a live concern.

.PARAMETER ObjectScaleLimit
    The per-domain object count Cloud Sync is documented to support. Defaults to
    150000. Exposed as a parameter since this is a published limit that could
    change in a future Cloud Sync update — re-verify against the current decision
    guide before trusting the default indefinitely.

.PARAMETER GroupMemberLimit
    The per-group member count Cloud Sync is documented to support. Defaults to
    50000. Same re-verification caveat as -ObjectScaleLimit.

.PARAMETER OutputPath
    Folder where the CSV reports are written. Defaults to
    $env:TEMP\CloudSyncMigrationReadiness-<timestamp>.

.EXAMPLE
    .\Get-CloudSyncMigrationReadiness.ps1

    Standard readiness audit against the local domain, skipping the group-size
    scan by default.

.EXAMPLE
    .\Get-CloudSyncMigrationReadiness.ps1 -IncludeGroupSizeScan -GroupMemberLimit 40000

    Full audit including group-size scan, with a tighter 40,000-member warning
    threshold for an MSP wanting headroom before the documented 50,000 cap.

.NOTES
    Requires: ActiveDirectory RSAT module (Checks 1-2); ADSync module, present on
              any Connect Sync server (Check 4); an active Microsoft Graph
              connection with Device.Read.All, Domain.Read.All, and
              Organization.Read.All (Checks 3, 5, 6). Any missing prerequisite
              causes that specific check to be skipped with a WARN, not a script
              abort.
    Run As:   Any account with AD read access and Graph read-only delegated/app
              permissions for the scopes above. No elevated AD or Entra role is
              required for these read-only checks.
    Safe:     Fully read-only — no New-/Set-/Remove- cmdlets against AD, Entra ID,
              or the Connect Sync configuration anywhere in this script.
    Cross-references: EntraID/Troubleshooting/CloudSyncMigration-B.md (Triage,
                       Fix 1-4) and CloudSyncMigration-A.md (Playbook 1 readiness
                       assessment, feature-comparison table).
    Compatible with Windows PowerShell 5.1 and PowerShell 7+.
#>

[CmdletBinding()]
param(
    [switch]$IncludeGroupSizeScan,

    [ValidateRange(1000, 1000000)]
    [int]$ObjectScaleLimit = 150000,

    [ValidateRange(1000, 500000)]
    [int]$GroupMemberLimit = 50000,

    [string]$OutputPath = "$env:TEMP\CloudSyncMigrationReadiness-$(Get-Date -Format 'yyyyMMdd-HHmm')"
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

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$findings = [System.Collections.Generic.List[object]]::new()

# =====================================================================
# CHECK 1 — AD object scale per domain
# =====================================================================
Write-Status "Checking AD object scale (users + groups + contacts)..." "INFO"
$domainObjectCount = $null
try {
    $userCount    = (Get-ADUser -Filter * -ResultSetSize $null -ErrorAction Stop).Count
    $groupCount   = (Get-ADGroup -Filter * -ResultSetSize $null -ErrorAction Stop).Count
    $contactCount = (Get-ADObject -Filter 'objectClass -eq "contact"' -ResultSetSize $null -ErrorAction Stop).Count
    $domainObjectCount = $userCount + $groupCount + $contactCount

    if ($domainObjectCount -gt $ObjectScaleLimit) {
        $findings.Add([PSCustomObject]@{
            Category = "Scale"; Flag = "SCALE_EXCEEDS_OBJECT_LIMIT"
            Detail = "Combined object count ($domainObjectCount: $userCount users, $groupCount groups, $contactCount contacts) exceeds Cloud Sync's documented $ObjectScaleLimit-object-per-domain limit. Per Microsoft's decision guide, this places the tenant in 'Evaluate for future migration' unless the migration is segmented by domain/OU. See CloudSyncMigration-B.md Fix 1."
            RiskLevel = "HIGH"
        })
        Write-Status "Object count ($domainObjectCount) exceeds the $ObjectScaleLimit limit." "ERROR"
    }
    else {
        Write-Status "Object count ($domainObjectCount) is within the $ObjectScaleLimit limit." "OK"
    }
}
catch {
    Write-Status "Could not enumerate AD objects (ActiveDirectory module unavailable or access denied): $($_.Exception.Message)" "WARN"
}

# =====================================================================
# CHECK 2 — Largest group size (opt-in)
# =====================================================================
if ($IncludeGroupSizeScan) {
    Write-Status "Scanning AD group membership sizes (this can take a while on a large directory)..." "INFO"
    try {
        $largestGroups = Get-ADGroup -Filter * -Properties Members -ErrorAction Stop |
            Select-Object Name, @{N = 'MemberCount'; E = { $_.Members.Count } } |
            Sort-Object MemberCount -Descending |
            Select-Object -First 10

        $overLimit = $largestGroups | Where-Object { $_.MemberCount -ge $GroupMemberLimit }
        if ($overLimit) {
            foreach ($g in $overLimit) {
                $findings.Add([PSCustomObject]@{
                    Category = "Scale"; Flag = "SCALE_EXCEEDS_GROUP_LIMIT"
                    Detail = "Group '$($g.Name)' has $($g.MemberCount) members, at or above Cloud Sync's $GroupMemberLimit-member cap (also the Group Provisioning to AD DS cap). See CloudSyncMigration-B.md Fix 4."
                    RiskLevel = "HIGH"
                })
            }
            Write-Status "$($overLimit.Count) group(s) at or above the $GroupMemberLimit-member cap." "ERROR"
        }
        else {
            Write-Status "No groups found at or above the $GroupMemberLimit-member cap (top group: $($largestGroups[0].MemberCount) members)." "OK"
        }
    }
    catch {
        Write-Status "Could not scan group membership sizes: $($_.Exception.Message)" "WARN"
    }
}
else {
    Write-Status "Group-size scan skipped (default). Re-run with -IncludeGroupSizeScan if group scale is a live concern." "INFO"
}

# =====================================================================
# CHECK 3 — Hybrid Azure AD Join device dependency
# =====================================================================
Write-Status "Checking for Hybrid Azure AD Join device sync dependency (via Microsoft Graph)..." "INFO"
$hybridJoinCount = $null
try {
    $hybridDevices = Get-MgDevice -Filter "trustType eq 'ServerAd'" -All -ErrorAction Stop
    $hybridJoinCount = ($hybridDevices | Measure-Object).Count

    if ($hybridJoinCount -gt 0) {
        $findings.Add([PSCustomObject]@{
            Category = "DeviceSync"; Flag = "HYBRID_JOIN_DEPENDENCY"
            Detail = "$hybridJoinCount device(s) found with trustType 'ServerAd' (Hybrid Azure AD Joined). Cloud Sync has no device-sync equivalent — plan a Cloud Kerberos Trust transition before or alongside migrating any OU containing these devices' users. See CloudSyncMigration-B.md Fix 2."
            RiskLevel = "HIGH"
        })
        Write-Status "$hybridJoinCount Hybrid Azure AD Joined device(s) found — Cloud Sync migration blocker until Cloud Kerberos Trust is in place." "ERROR"
    }
    else {
        Write-Status "No Hybrid Azure AD Joined devices found." "OK"
    }
}
catch {
    Write-Status "Could not query Microsoft Graph for device trustType (no Graph connection, or missing Device.Read.All scope): $($_.Exception.Message)" "WARN"
}

# =====================================================================
# CHECK 4 — Advanced/custom Connect Sync rules
# =====================================================================
Write-Status "Checking for non-default (custom/advanced) Connect Sync rules..." "INFO"
$customRuleCount = $null
try {
    Import-Module ADSync -ErrorAction Stop
    $customRules = Get-ADSyncRule -ErrorAction Stop | Where-Object { -not $_.IsDefault }
    $customRuleCount = ($customRules | Measure-Object).Count

    if ($customRuleCount -gt 0) {
        $ruleNames = ($customRules | Select-Object -First 10 -ExpandProperty Name) -join '; '
        $findings.Add([PSCustomObject]@{
            Category = "SyncRules"; Flag = "ADVANCED_SYNC_RULES_PRESENT"
            Detail = "$customRuleCount non-default sync rule(s) found (first 10: $ruleNames). Cloud Sync has no equivalent sync-rule engine — each rule needs manual review against the current feature-comparison table to determine whether its logic has a Cloud Sync expression-builder equivalent, is unsupported (redesign or defer), or is itself a prior cloudNoFlow migration artifact. See CloudSyncMigration-B.md Fix 3."
            RiskLevel = "MEDIUM"
        })
        Write-Status "$customRuleCount non-default sync rule(s) found — requires manual feature-parity review." "WARN"
    }
    else {
        Write-Status "No non-default sync rules found." "OK"
    }
}
catch {
    Write-Status "Could not read Connect Sync rules (ADSync module unavailable — not running on a Connect Sync server?): $($_.Exception.Message)" "WARN"
}

# =====================================================================
# CHECK 5 — PTA / ADFS federation (informational only)
# =====================================================================
Write-Status "Checking PTA agent presence and federated domain count (informational, not a blocker)..." "INFO"
try {
    $ptaService = Get-Service -Name AzureADConnectAuthenticationAgentService -ErrorAction SilentlyContinue
    $federatedDomains = Get-MgDomain -All -ErrorAction SilentlyContinue | Where-Object { $_.AuthenticationType -eq 'Federated' }

    if ($ptaService -or ($federatedDomains | Measure-Object).Count -gt 0) {
        $findings.Add([PSCustomObject]@{
            Category = "Authentication"; Flag = "PTA_OR_ADFS_IN_USE"
            Detail = "PTA agent service present: $([bool]$ptaService). Federated domain count: $(($federatedDomains | Measure-Object).Count). NOT a migration blocker — both PTA and ADFS are configured independently of the sync tool and remain functional after a Cloud Sync migration — informational only, flagged so this isn't confused with a sync-related change."
            RiskLevel = "LOW"
        })
        Write-Status "PTA and/or ADFS federation detected — informational, not a blocker." "INFO"
    }
    else {
        Write-Status "No PTA agent or federated domains detected (likely Password Hash Sync only)." "OK"
    }
}
catch {
    Write-Status "Could not check PTA service or federated domains: $($_.Exception.Message)" "WARN"
}

# =====================================================================
# CHECK 6 — License (best-effort SKU name match, never a hardcoded GUID)
# =====================================================================
Write-Status "Checking for an Entra ID P1-or-higher SKU (best-effort name match)..." "INFO"
try {
    $skus = Get-MgSubscribedSku -All -ErrorAction Stop
    $p1OrHigher = $skus | Where-Object { $_.SkuPartNumber -match 'AAD_PREMIUM|ENTERPRISEPREMIUM|SPE_E|EMSPREMIUM' }

    if (-not $p1OrHigher) {
        $findings.Add([PSCustomObject]@{
            Category = "Licensing"; Flag = "LICENSE_VERIFICATION_NEEDED"
            Detail = "No SubscribedSku with a SkuPartNumber matching common Entra ID P1-or-higher name patterns (AAD_PREMIUM/ENTERPRISEPREMIUM/SPE_E/EMSPREMIUM family) was found. This is a best-effort NAME match, not a guaranteed check — manually verify actual licensing before assuming this is a blocker, since SKU naming varies and this script deliberately does not hardcode a SKU GUID."
            RiskLevel = "MEDIUM"
        })
        Write-Status "No obvious P1-or-higher SKU found by name match — verify licensing manually." "WARN"
    }
    else {
        Write-Status "Found a likely Entra ID P1-or-higher SKU: $(($p1OrHigher | Select-Object -ExpandProperty SkuPartNumber) -join ', ')" "OK"
    }
}
catch {
    Write-Status "Could not query SubscribedSku (no Graph connection, or missing Organization.Read.All scope): $($_.Exception.Message)" "WARN"
}

# =====================================================================
# Overall readiness classification
# =====================================================================
$highFindings = $findings | Where-Object { $_.RiskLevel -eq "HIGH" }
$medFindings  = $findings | Where-Object { $_.RiskLevel -eq "MEDIUM" }

$classification = if ($highFindings.Count -gt 0) {
    "EVALUATE_FUTURE"
}
elseif ($medFindings.Count -gt 0) {
    "PLAN_NEAR_TERM"
}
else {
    "READY_NOW"
}

# =====================================================================
# Report
# =====================================================================
Write-Host ""
Write-Host "=== Entra Connect Sync -> Cloud Sync Migration Readiness Summary ===" -ForegroundColor Cyan
Write-Status "Overall classification: $classification" $(switch ($classification) { "READY_NOW" { "OK" } "PLAN_NEAR_TERM" { "WARN" } default { "ERROR" } })
Write-Status "$($highFindings.Count) HIGH-risk finding(s), $($medFindings.Count) MEDIUM-risk finding(s)." $(if ($highFindings.Count -gt 0) { "ERROR" } elseif ($medFindings.Count -gt 0) { "WARN" } else { "OK" })

if ($findings.Count -gt 0) {
    Write-Host ""
    Write-Host "--- Findings ---" -ForegroundColor Yellow
    $findings | Select-Object Category, Flag, RiskLevel, Detail | Format-Table -AutoSize -Wrap
}

Write-Host ""
Write-Host "KNOWN GAPS (not covered by this script — see .DESCRIPTION and CloudSyncMigration-A.md):" -ForegroundColor DarkGray
Write-Host " - Whether a specific custom sync rule has a Cloud Sync expression-builder equivalent — requires manual review of each rule's transform logic" -ForegroundColor DarkGray
Write-Host " - Cross-forest / disconnected-forest topology classification — confirm manually" -ForegroundColor DarkGray
Write-Host " - Connect Sync server version/EOL status — see Get-ConnectSyncVersionAudit.ps1" -ForegroundColor DarkGray
Write-Host " - This script is assessment-only — it does not create the cloudNoFlow rule pair, install the Cloud Sync agent, or change any scheduler state" -ForegroundColor DarkGray

$reportPath = Join-Path $OutputPath "CloudSyncMigrationReadiness_$(Get-Date -Format yyyyMMdd).csv"
[PSCustomObject]@{
    DomainObjectCount        = $domainObjectCount
    ObjectScaleLimit         = $ObjectScaleLimit
    HybridJoinDeviceCount    = $hybridJoinCount
    NonDefaultSyncRuleCount  = $customRuleCount
    OverallClassification    = $classification
    HighRiskFindingCount     = $highFindings.Count
    MediumRiskFindingCount   = $medFindings.Count
    CollectedAt              = Get-Date
} | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8

$findingsPath = Join-Path $OutputPath "Findings.csv"
$findings | Export-Csv -Path $findingsPath -NoTypeInformation -Encoding UTF8

Write-Status "Summary report exported to $reportPath" "OK"
Write-Status "Findings exported to $findingsPath" "OK"
