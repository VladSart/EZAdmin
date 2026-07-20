<#
.SYNOPSIS
    Audits readiness for Microsoft Sentinel graph (both built-in and custom graphs) — data lake
    onboarding foundation and a given user's Entra ID directory role coverage for persisting
    custom graphs.

.DESCRIPTION
    Companion to SentinelGraph-A.md and SentinelGraph-B.md. "Sentinel graph" spans two products
    that share only the Sentinel data lake as a foundation: built-in embedded graphs (Blast Radius,
    Hunting graph), which auto-provision with zero configuration once the data lake is onboarded,
    and Custom graphs (preview), a code-first VS Code/PySpark/GQL authoring workflow gated by
    THREE independent permission systems that don't imply one another (per SentinelGraph-A.md's
    How It Works: XDR unified RBAC "data (manage)" to model, an Entra ID directory role to persist,
    and XDR unified RBAC "security data basics (read)" to query).

    This script is a read-only reconnaissance tool that checks what CAN be verified via Az
    PowerShell and Microsoft Graph:
      - Whether the tenant is onboarded to the Sentinel data lake at all (presence of the managed
        identity Microsoft creates during onboarding, always prefixed msg-resources-) — since both
        built-in graphs and custom graphs depend on this foundation, a missing managed identity
        means NEITHER graph capability is available yet, not a graph-specific fault
      - A specified user's Entra ID directory role membership, filtered to the three roles that
        satisfy the "persist a custom graph" permission requirement (Security Operator, Security
        Administrator, Global Administrator) — reported explicitly as ELIGIBLE or NOT ELIGIBLE to
        persist, since this is the one permission layer of the three with an actual Graph API
        surface to check

    It deliberately does NOT and CANNOT check (no stable Az/Graph/VS-Code-extension API surface
    for these as of this writing — verify from the Defender portal permissions blade and the VS
    Code Microsoft Sentinel extension's graph panel directly):
      - Custom Defender XDR unified RBAC role assignments ("data (manage)" / "security data basics
        (read)") — these are Defender-portal-only custom roles with no public Graph/Az cmdlet
      - Whether a user's Sentinel access is scoped (a hard, silent block on custom graph creation
        per SentinelGraph-A.md's How It Works) — no public API surfaces Sentinel scoping state
      - Per-table data access as it applies to a specific graph spec's referenced tables (missing
        access silently omits data from the built graph rather than erroring)
      - Any graph job's build status, schedule type (On demand vs. recurring), or retention state
      - Whether built-in graphs (Blast Radius/Hunting graph) are actually rendering correctly in
        the Defender portal for a given incident
    The script's console output and CSV both say so explicitly rather than silently omitting scope.

.PARAMETER DataLakeResourceGroup
    Resource group the data lake managed identity (msg-resources-<guid>) was provisioned into
    during onboarding. If not found here, the script also does a subscription-wide fallback
    search before concluding the tenant isn't onboarded.

.PARAMETER UserPrincipalName
    Optional. The user to check for Entra ID directory role eligibility to persist custom graphs.
    If omitted, the script only reports on data lake onboarding state.

.PARAMETER SkipGraphCheck
    Optional switch. Skip the Microsoft Graph-based Entra ID directory role lookup even if
    -UserPrincipalName is supplied — useful where Microsoft.Graph modules aren't available or
    Graph consent hasn't been granted.

.PARAMETER ExportPath
    Directory to write the CSV report to. Default: current directory.

.EXAMPLE
    .\Get-SentinelGraphReadinessAudit.ps1 -DataLakeResourceGroup "rg-sentinel-datalake" `
        -UserPrincipalName "analyst@contoso.com"
    Confirms data lake onboarding and reports whether analyst@contoso.com holds an Entra ID role
    eligible to persist custom Sentinel graphs.

.NOTES
    Requires: Az.Accounts, Az.Resources (Connect-AzAccount first).
    Optional: Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement
              (Connect-MgGraph -Scopes "RoleManagement.Read.Directory" first) for the Entra ID
              directory role check. Falls back gracefully with a WARN if Graph isn't connected.
    Safe / read-only. Exports findings to CSV in the export directory.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DataLakeResourceGroup,
    [string]$UserPrincipalName,
    [switch]$SkipGraphCheck,
    [string]$ExportPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmm"
$findings = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-Finding {
    param([string]$Category, [string]$Item, [string]$Result, [string]$Note)
    $findings.Add([pscustomobject]@{
        Category = $Category
        Item     = $Item
        Result   = $Result
        Note     = $Note
    })
}

$persistEligibleRoles = @("Security Operator", "Security Administrator", "Global Administrator")

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Starting Microsoft Sentinel graph readiness audit ($timestamp)"
try {
    $context = Get-AzContext
    if (-not $context) { throw "No active Az context." }
    Write-Status "Connected as $($context.Account.Id) against subscription $($context.Subscription.Name)" "OK"
} catch {
    Write-Status "Not connected to Azure. Run Connect-AzAccount first." "ERROR"
    throw
}

if (-not (Test-Path $ExportPath)) {
    New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null
}

# ---------------------------------------------------------------------------
# Detect: data lake onboarding (foundation for BOTH built-in and custom graphs)
# ---------------------------------------------------------------------------
Write-Status "Checking for Sentinel data lake managed identity in resource group '$DataLakeResourceGroup'..."
$managedIdentity = $null
try {
    $managedIdentity = Get-AzADServicePrincipal -DisplayNameBeginsWith "msg-resources-" -ErrorAction Stop |
        Where-Object { $_.Id } | Select-Object -First 1
} catch {
    Write-Status "Could not enumerate service principals directly — will rely on resource group scan." "WARN"
}

if (-not $managedIdentity) {
    Write-Status "Managed identity not found by name scan. Falling back to a subscription-wide search..." "WARN"
    try {
        $managedIdentity = Get-AzADServicePrincipal -ErrorAction Stop |
            Where-Object { $_.DisplayName -like "msg-resources-*" } | Select-Object -First 1
    } catch {
        Write-Status "Subscription-wide fallback search also failed. Confirm AAD read permissions." "WARN"
    }
}

if ($managedIdentity) {
    Write-Status "Data lake managed identity found: $($managedIdentity.DisplayName)" "OK"
    Add-Finding -Category "DataLakeFoundation" -Item "ManagedIdentity" -Result "FOUND" `
        -Note "Data lake appears onboarded. Both built-in graphs (Blast Radius/Hunting graph) and custom graphs (preview) depend on this foundation — this does NOT by itself confirm either graph capability is working, only that the prerequisite exists (SentinelGraph-A.md Dependency Stack)."
} else {
    Write-Status "No data lake managed identity found. Tenant likely NOT onboarded to the Sentinel data lake." "ERROR"
    Add-Finding -Category "DataLakeFoundation" -Item "ManagedIdentity" -Result "NOT_FOUND" `
        -Note "Neither built-in graphs nor custom graphs can work without data lake onboarding. See DataLake-B.md Fix 1/2 for onboarding failure triage (SentinelGraph-B.md Fix 1)."
}

# ---------------------------------------------------------------------------
# Execute: per-user Entra ID directory role check (persist-a-custom-graph layer)
# ---------------------------------------------------------------------------
if ($UserPrincipalName) {
    if ($SkipGraphCheck) {
        Write-Status "Skipping Entra ID directory role check (-SkipGraphCheck specified)." "WARN"
        Add-Finding -Category "PersistPermission" -Item $UserPrincipalName -Result "SKIPPED" `
            -Note "-SkipGraphCheck specified; Entra ID directory role eligibility to persist custom graphs not evaluated."
    } else {
        Write-Status "Checking Entra ID directory role membership for $UserPrincipalName..."
        try {
            $mgContext = Get-MgContext -ErrorAction Stop
            if (-not $mgContext) { throw "No active Microsoft Graph context." }

            $memberOf = Get-MgUserMemberOf -UserId $UserPrincipalName -All -ErrorAction Stop
            $matchedRoles = $memberOf | Where-Object {
                $_.AdditionalProperties.displayName -in $persistEligibleRoles
            } | ForEach-Object { $_.AdditionalProperties.displayName }

            if ($matchedRoles -and $matchedRoles.Count -gt 0) {
                Write-Status "$UserPrincipalName holds: $($matchedRoles -join ', ') — ELIGIBLE to persist custom graphs." "OK"
                Add-Finding -Category "PersistPermission" -Item $UserPrincipalName -Result "ELIGIBLE" `
                    -Note "Holds one or more of: $($matchedRoles -join ', '). This is ONLY the 'persist a graph' permission layer — modeling (XDR RBAC 'data (manage)') and querying (XDR RBAC 'security data basics (read)') are separate, unrelated permission grants not checkable from this script (SentinelGraph-A.md permission model table)."
            } else {
                Write-Status "$UserPrincipalName does NOT hold Security Operator, Security Administrator, or Global Administrator — NOT ELIGIBLE to persist custom graphs." "WARN"
                Add-Finding -Category "PersistPermission" -Item $UserPrincipalName -Result "NOT_ELIGIBLE" `
                    -Note "Missing all three Entra ID roles that satisfy the persist-a-custom-graph requirement. This does NOT mean the user cannot model or query graphs — those use a completely separate XDR unified RBAC permission system (SentinelGraph-B.md Fix 2)."
            }
        } catch {
            Write-Status "Could not complete Entra ID directory role check — confirm Connect-MgGraph with RoleManagement.Read.Directory scope. Error: $($_.Exception.Message)" "WARN"
            Add-Finding -Category "PersistPermission" -Item $UserPrincipalName -Result "CHECK_FAILED" `
                -Note "Graph connection/scope issue prevented this check. Retry with Connect-MgGraph -Scopes 'RoleManagement.Read.Directory' or use -SkipGraphCheck to suppress this attempt."
        }
    }
} else {
    Write-Status "No -UserPrincipalName supplied — skipping per-user persist-eligibility check." "INFO"
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Status "`n=== SUMMARY ===" "OK"
Write-Status "Findings: $($findings.Count)"
$findings | Format-Table -AutoSize -Wrap

Write-Status "`nNOTE: This script cannot check XDR unified RBAC role assignments (the 'data (manage)' /" "WARN"
Write-Status "'security data basics (read)' permissions needed to model/query graphs), Sentinel scoping" "WARN"
Write-Status "state, per-table data access as it applies to a specific graph spec, or any graph job's" "WARN"
Write-Status "build status/schedule/retention. Verify these manually in the Defender portal permissions" "WARN"
Write-Status "blade and the VS Code Microsoft Sentinel extension's graph panel before treating any" "WARN"
Write-Status "finding above as a complete readiness picture." "WARN"

$reportPath = Join-Path $ExportPath "SentinelGraph_ReadinessAudit_$timestamp.csv"
$findings | Export-Csv -Path $reportPath -NoTypeInformation
Write-Status "`nReport written to: $reportPath" "OK"
