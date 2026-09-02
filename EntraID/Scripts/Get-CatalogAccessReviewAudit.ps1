<#
.SYNOPSIS
    Read-only audit of Microsoft Entra ID Governance Catalog / User-centric
    Access Reviews (UAR): licensing, catalog resource-type inventory, which
    access review definitions are catalog-scoped, instance lifecycle health,
    and — the highest-value check — Custom Data Provided Resource decisions
    stuck unapplied in the Applying stage.

.DESCRIPTION
    Catalog/UAR reviews (GA September 2026) have failure modes that don't
    exist for standard, single-resource access reviews and are easy to miss
    because they're silent: a review can sit in "Initializing" past its
    2-hour custom-data upload window with no error, or sit in "Applying"
    indefinitely because nobody wired up the required PATCH-back loop for
    Custom Data Provided Resource (CDPR) decisions. This script walks every
    catalog-scoped review definition in the tenant and flags exactly where
    each one stands against those known failure points.

    Analysis flags applied:
      NO_UAR_LICENSE            - Neither an Entra ID Governance nor Entra
                                   Suite service plan was found enabled.
                                   Catalog/UAR reviews have no P1/P2-only
                                   fallback tier, unlike several base Access
                                   Reviews capabilities.
      CATALOG_NO_RESOURCES      - A catalog exists but has zero resources of
                                   a supported type (Group/Team, Application,
                                   Custom Data Provided Resource) attached.
                                   Any review created from it will have
                                   nothing to certify.
      INSTANCE_INITIALIZING_STALE - A CDPR-containing instance has been in
                                   "Initializing" for longer than the
                                   documented 2-hour upload window — that
                                   resource almost certainly has zero
                                   reviewable items for this cycle.
      INSTANCE_APPLYING_STALE   - An instance has been in "Applying" for an
                                   extended period (default threshold: 5
                                   days) — approaching or past the documented
                                   30-day ceiling before it should be treated
                                   as a stuck review, not "still processing."
      CDPR_DECISIONS_UNAPPLIED  - One or more Custom Data Provided Resource
                                   decisions in an Applying-stage instance
                                   have not been PATCHed with a terminal
                                   applyResult. This is the #1 root cause of
                                   a catalog review that never reaches
                                   Applied — remediation for CDPR decisions
                                   is NOT automatic.
      REVIEWER_MISMATCH_CDPR    - A catalog review contains a Custom Data
                                   Provided Resource but its reviewer
                                   settings do not resolve to a single-stage,
                                   manager-only configuration (the only
                                   supported model for that resource type as
                                   of GA) — surfaced for manual verification,
                                   since the schema for this check is still
                                   evolving on the beta surface.

    Read-only. Makes no changes to any catalog, review definition, instance,
    or decision. Does NOT PATCH decisions or remove any access — see
    CatalogAccessReviews-A.md Remediation Playbook 1 for that manual
    (deliberately manual) remediation loop.

    Does NOT cover:
    - Standard, single-resource access review health — see
      Get-AccessReviewAudit.ps1 for that surface
    - Catalog resource membership management (add/remove groups, apps,
      CDPR entries) — portal or EntitlementManagement.ReadWrite.All only
    - Actual removal of access for denied CDPR decisions — this script only
      reports which decisions are outstanding; the calling organization's
      own remediation-in-source-system step is out of scope by design (Entra
      has no connection to the disconnected system to act on its behalf)

.PARAMETER InitializingStaleHours
    Hours after which a CDPR-containing instance still in "Initializing" is
    flagged as having likely missed its custom-data upload window.
    Default: 2 (matches the documented upload window exactly — flags the
    instant it's theoretically expired).

.PARAMETER ApplyingStaleDays
    Days an instance may sit in "Applying" before being flagged for
    escalation triage. Default: 5 (well under the documented 30-day ceiling,
    intended as an early-warning threshold, not the hard limit itself).

.PARAMETER OutputPath
    Directory where CSV/JSON reports will be written.
    Default: .\CatalogAccessReview-Audit-<timestamp>\

.EXAMPLE
    .\Get-CatalogAccessReviewAudit.ps1

    Full tenant-wide catalog/UAR posture audit with default thresholds.

.EXAMPLE
    .\Get-CatalogAccessReviewAudit.ps1 -ApplyingStaleDays 10 -InitializingStaleHours 3

    Looser thresholds for a tenant with known network/process latency in its
    CDPR upload pipeline.

.NOTES
    Requires: Microsoft.Graph.Beta PowerShell SDK, or Microsoft.Graph with
              Invoke-MgGraphRequest available
              (Install-Module Microsoft.Graph.Beta -Scope CurrentUser)
    Scopes needed: EntitlementManagement.Read.All, AccessReview.Read.All
    Run As: Identity Governance Administrator, Global Reader, or Global
            Administrator (read only)
    Safe: Read-only — no catalogs, review definitions, instances, or
          decisions are changed. No access is removed by this script.
    Cross-references: EntraID/Troubleshooting/CatalogAccessReviews-A.md
                       (Dependency Stack, Symptom -> Cause Map, Validation
                       Steps, Remediation Playbook 1), CatalogAccessReviews-B.md
                       (Triage, Fix 1-7), Get-AccessReviewAudit.ps1 (run
                       alongside this script for standard single-resource
                       review health in the same tenant)
#>

[CmdletBinding()]
param(
    [double]$InitializingStaleHours = 2,

    [int]$ApplyingStaleDays = 5,

    [string]$OutputPath = ".\CatalogAccessReview-Audit-$(Get-Date -Format 'yyyyMMdd-HHmm')"
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

function Invoke-GraphGetAll {
    <# Minimal @odata.nextLink-following GET wrapper #>
    param([string]$Uri)
    $results = New-Object System.Collections.Generic.List[object]
    $next = $Uri
    while ($next) {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $next -ErrorAction Stop
        if ($resp.value) { $results.AddRange([object[]]$resp.value) }
        $next = $resp.'@odata.nextLink'
    }
    return $results
}

# --- Connect ---
try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Connecting to Microsoft Graph (beta)..." "INFO"
        Connect-MgGraph -Scopes "EntitlementManagement.Read.All", "AccessReview.Read.All" -NoWelcome
    }
} catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    return
}

if (-not (Get-Command Invoke-MgGraphRequest -EA SilentlyContinue)) {
    Write-Status "Microsoft.Graph(.Beta) module not found. Install with:" "ERROR"
    Write-Status "  Install-Module Microsoft.Graph.Beta -Scope CurrentUser" "ERROR"
    return
}

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

$findings = New-Object System.Collections.Generic.List[object]

# --- 1. Licensing ---
Write-Status "Checking Entra ID Governance / Entra Suite licensing..." "INFO"
$hasLicense = $false
try {
    $skus = Get-MgSubscribedSku -ErrorAction Stop
    $govSkus = $skus | Where-Object { $_.ServicePlans.ServicePlanName -match "GOVERNANCE|Entra_Suite" -and $_.PrepaidUnits.Enabled -gt 0 }
    $hasLicense = [bool]$govSkus
} catch {
    Write-Status "Could not read subscribed SKUs (Organization.Read.All may be missing): $($_.Exception.Message)" "WARN"
}

if (-not $hasLicense) {
    $findings.Add([pscustomobject]@{
        Flag = "NO_UAR_LICENSE"; Severity = "CRITICAL"
        Object = "(tenant)"
        Detail = "No enabled Entra ID Governance or Entra Suite service plan found. Catalog/UAR reviews have no P1/P2-only fallback — this feature is entirely unavailable until licensing is confirmed/added."
    })
    Write-Status "No Governance/Entra Suite license detected." "WARN"
} else {
    Write-Status "Governance/Entra Suite licensing confirmed." "OK"
}

# --- 2. Catalogs and resource-type inventory ---
Write-Status "Retrieving entitlement management catalogs..." "INFO"
$catalogs = @()
try {
    $catalogs = Invoke-GraphGetAll -Uri "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/catalogs"
} catch {
    Write-Status "Failed to retrieve catalogs: $($_.Exception.Message)" "ERROR"
}
Write-Status "Found $($catalogs.Count) catalog(s)." "INFO"

$catalogResourceResults = foreach ($cat in $catalogs) {
    $resources = @()
    try {
        $resources = Invoke-GraphGetAll -Uri "https://graph.microsoft.com/beta/identityGovernance/entitlementManagement/catalogs/$($cat.id)/resources"
    } catch {
        Write-Status "  Could not read resources for catalog '$($cat.displayName)': $($_.Exception.Message)" "WARN"
    }

    if (-not $resources -or $resources.Count -eq 0) {
        $findings.Add([pscustomobject]@{
            Flag = "CATALOG_NO_RESOURCES"; Severity = "INFO"
            Object = $cat.displayName
            Detail = "Catalog '$($cat.displayName)' (id: $($cat.id)) has zero resources attached. Any catalog review created from this catalog will have nothing to certify until Groups/Teams, Applications, or Custom Data Provided Resources are added."
        })
    }

    $hasCdpr = @($resources | Where-Object { $_.resourceType -match "Custom|CustomData" }).Count -gt 0

    [pscustomobject]@{
        CatalogId     = $cat.id
        CatalogName   = $cat.displayName
        ResourceCount = @($resources).Count
        HasGroups     = @($resources | Where-Object { $_.resourceType -match "Group" }).Count -gt 0
        HasApps       = @($resources | Where-Object { $_.resourceType -match "Application|ServicePrincipal" }).Count -gt 0
        HasCustomData = $hasCdpr
    }
}
if ($catalogResourceResults) {
    $catalogResourceResults | Export-Csv "$OutputPath\catalog_resource_inventory.csv" -NoTypeInformation
}

# --- 3. Access review definitions — identify catalog-scoped reviews ---
Write-Status "Retrieving access review definitions..." "INFO"
$definitions = @()
try {
    $definitions = Invoke-GraphGetAll -Uri "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions"
} catch {
    Write-Status "Failed to retrieve access review definitions: $($_.Exception.Message)" "ERROR"
}

$catalogDefs = $definitions | Where-Object {
    $scopeJson = ($_.scope | ConvertTo-Json -Depth 6 -Compress -ErrorAction SilentlyContinue)
    $scopeJson -match "catalogs|entitlementManagement" -or $_.scope.'@odata.type' -match "catalog" -or $_.scope.query -match "catalogs"
}
Write-Status "Found $($definitions.Count) total review definition(s); $($catalogDefs.Count) appear catalog-scoped." "INFO"

# --- 4. Per-definition instance lifecycle audit ---
$instanceResults = New-Object System.Collections.Generic.List[object]

foreach ($def in $catalogDefs) {
    $instances = @()
    try {
        $instances = Invoke-GraphGetAll -Uri "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions/$($def.id)/instances"
    } catch {
        Write-Status "  Could not read instances for definition '$($def.displayName)': $($_.Exception.Message)" "WARN"
        continue
    }

    # Best-effort reviewer-model check for CDPR presence in this catalog
    $catInfo = $catalogResourceResults | Where-Object { $def.scope -match $_.CatalogId }
    $catalogHasCdpr = $false
    if ($catInfo) { $catalogHasCdpr = $catInfo.HasCustomData }

    if ($catalogHasCdpr) {
        $reviewerJson = ($def.settings.reviewers | ConvertTo-Json -Depth 5 -Compress -ErrorAction SilentlyContinue)
        $looksSingleStageManager = ($reviewerJson -match "manager" -and -not ($def.settings.PSObject.Properties.Name -contains "reviewerSecondStage"))
        if (-not $looksSingleStageManager) {
            $findings.Add([pscustomobject]@{
                Flag = "REVIEWER_MISMATCH_CDPR"; Severity = "WARN"
                Object = $def.displayName
                Detail = "Catalog for definition '$($def.displayName)' contains a Custom Data Provided Resource, but reviewer settings don't clearly resolve to the only supported model (single-stage, manager-only) for that resource type. Verify manually in the portal — this check is best-effort against an evolving beta schema."
            })
        }
    }

    foreach ($inst in $instances) {
        $ageInStatus = $null
        $refDate = $inst.startDateTime
        if ($inst.status -eq "Applying" -and $inst.endDateTime) { $refDate = $inst.endDateTime }
        if ($refDate) {
            try { $ageInStatus = ((Get-Date) - [datetime]$refDate).TotalHours } catch {}
        }

        if ($inst.status -eq "Initializing" -and $ageInStatus -ne $null -and $ageInStatus -ge $InitializingStaleHours) {
            $findings.Add([pscustomobject]@{
                Flag = "INSTANCE_INITIALIZING_STALE"; Severity = "WARN"
                Object = "$($def.displayName) / instance $($inst.id)"
                Detail = "Instance has been in 'Initializing' for $([math]::Round($ageInStatus,1))h (upload window threshold: ${InitializingStaleHours}h). Custom Data Provided Resource access data for this cycle was likely never uploaded — that resource will show zero reviewable items."
            })
        }

        if ($inst.status -eq "Applying" -and $ageInStatus -ne $null -and $ageInStatus -ge ($ApplyingStaleDays * 24)) {
            $findings.Add([pscustomobject]@{
                Flag = "INSTANCE_APPLYING_STALE"; Severity = "CRITICAL"
                Object = "$($def.displayName) / instance $($inst.id)"
                Detail = "Instance has been in 'Applying' for $([math]::Round($ageInStatus/24,1)) day(s) since its end date (threshold: $ApplyingStaleDays day(s); documented ceiling: 30 days). Almost certainly means Custom Data Provided Resource decisions were never PATCHed with a terminal applyResult — see Remediation Playbook 1 in CatalogAccessReviews-A.md."
            })

            # Pull decisions and check for outstanding CDPR items
            try {
                $decisions = Invoke-GraphGetAll -Uri "https://graph.microsoft.com/beta/identityGovernance/accessReviews/definitions/$($def.id)/instances/$($inst.id)/decisions"
                $outstanding = $decisions | Where-Object { -not $_.applyResult -or $_.applyResult -eq "New" }
                if ($outstanding -and $outstanding.Count -gt 0) {
                    $findings.Add([pscustomobject]@{
                        Flag = "CDPR_DECISIONS_UNAPPLIED"; Severity = "CRITICAL"
                        Object = "$($def.displayName) / instance $($inst.id)"
                        Detail = "$($outstanding.Count) of $($decisions.Count) decision(s) have no terminal applyResult. This instance cannot reach 'Applied' until every decision item — including any Custom Data Provided Resource items — is PATCHed with AppliedSuccessfully or AppliedWithFailure."
                    })
                }
            } catch {
                Write-Status "    Could not read decisions for instance $($inst.id): $($_.Exception.Message)" "WARN"
            }
        }

        $instanceResults.Add([pscustomobject]@{
            DefinitionName = $def.displayName
            DefinitionId   = $def.id
            InstanceId     = $inst.id
            Status         = $inst.status
            StartDateTime  = $inst.startDateTime
            EndDateTime    = $inst.endDateTime
            CatalogHasCdpr = $catalogHasCdpr
            HoursInCurrentStatus = if ($ageInStatus -ne $null) { [math]::Round($ageInStatus,1) } else { $null }
        })
    }
}

if ($instanceResults.Count -gt 0) {
    $instanceResults | Export-Csv "$OutputPath\catalog_review_instances.csv" -NoTypeInformation
}

$findings | Export-Csv "$OutputPath\findings.csv" -NoTypeInformation

# --- Summary ---
Write-Host ""
Write-Status "=== Catalog / User-centric Access Reviews (UAR) Posture Summary ===" "INFO"
$critical = @($findings | Where-Object Severity -eq "CRITICAL").Count
$warn     = @($findings | Where-Object Severity -eq "WARN").Count
$info     = @($findings | Where-Object Severity -eq "INFO").Count

Write-Status "Catalogs found: $($catalogs.Count)" "INFO"
Write-Status "Catalog-scoped review definitions found: $($catalogDefs.Count)" "INFO"
Write-Status "Instances audited: $($instanceResults.Count)" "INFO"
Write-Status "Critical findings (blocks Applied / feature entirely unavailable): $critical" $(if ($critical -gt 0) { "ERROR" } else { "OK" })
Write-Status "Warnings (stale states / configuration risk): $warn" $(if ($warn -gt 0) { "WARN" } else { "OK" })
Write-Status "Informational findings: $info" "INFO"
Write-Status "Reports written to: $OutputPath" "INFO"

if ($critical -eq 0 -and $warn -eq 0) {
    Write-Status "Catalog/UAR posture looks healthy across all checked dimensions." "OK"
}
