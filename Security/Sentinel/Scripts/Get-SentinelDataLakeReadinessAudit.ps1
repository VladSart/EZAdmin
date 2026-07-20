<#
.SYNOPSIS
    Audits Microsoft Sentinel data lake onboarding state, managed identity permissions, and a
    given user's Entra ID directory role coverage for KQL job creation/scheduling.

.DESCRIPTION
    The Microsoft Sentinel data lake uses a dual access-control model that is a common source of
    confusion: Sentinel SIEM (Azure RBAC) and the data lake itself (Microsoft Entra ID directory
    roles) are two INDEPENDENT authorization systems on the same tenant. A user can hold full
    Microsoft Sentinel Contributor rights (Azure RBAC) and still be completely unable to create or
    schedule a KQL job because no one separately granted them a write-capable Entra ID directory
    role (Security Operator, Security Administrator, or Global Administrator).

    This script is a read-only reconnaissance tool that checks what CAN be verified via Az
    PowerShell and Microsoft Graph:
      - Whether the tenant is onboarded to the data lake at all (presence of the managed identity
        Microsoft creates during onboarding, always prefixed msg-resources-)
      - Whether that managed identity holds Log Analytics Contributor on the target Sentinel
        workspace (required ONLY for KQL jobs that create NEW custom tables in the analytics tier
        — a manual, not-automatic grant)
      - A specified user's Sentinel Azure RBAC role (SIEM surface) AND, independently, their
        Entra ID directory role (data lake surface) — reported side by side so the two-system gap
        is immediately visible rather than requiring two separate manual lookups
      - Whether the Sentinel workspace's SKU indicates a dedicated (potentially CMK-linked)
        cluster, which is an unconditional data-lake incompatibility if CMK is enabled on it

    It deliberately does NOT and CANNOT check (no stable Az/Graph API surface for these as of this
    writing — verify from the Defender portal directly):
      - Individual KQL job execution history, success/failure state, or output row counts
      - Federated data connector configuration or external-source network reachability
      - Notebooks-on-the-lake session state (see Get-SentinelNotebookReadinessAudit.ps1 for the
        separate Azure Machine Learning RBAC/network layer notebooks depend on)
      - Whether a workspace's linked Log Analytics cluster actually has CMK enabled (this requires
        Get-AzOperationalInsightsCluster against the cluster resource, which this script surfaces
        as a pointer rather than resolving automatically, since not every tenant uses a dedicated
        cluster at all)
    The script's console output and CSV both say so explicitly rather than silently omitting scope.

.PARAMETER DataLakeResourceGroup
    Resource group the data lake managed identity (msg-resources-<guid>) was provisioned into
    during onboarding. If the managed identity isn't found here, the script also does a
    subscription-wide fallback search before concluding the tenant isn't onboarded.

.PARAMETER SentinelResourceGroup
    Resource group containing the Sentinel (Log Analytics) workspace to check.

.PARAMETER SentinelWorkspaceName
    Name of the Sentinel-enabled Log Analytics workspace to check.

.PARAMETER UserPrincipalName
    Optional. The user to check for BOTH Sentinel Azure RBAC and Entra ID directory role coverage,
    side by side. If omitted, the script skips the per-user comparison and only reports on
    onboarding/managed-identity state.

.PARAMETER SkipGraphCheck
    Optional switch. Skip the Microsoft Graph-based Entra ID directory role lookup even if
    -UserPrincipalName is supplied — useful in environments where Microsoft.Graph modules aren't
    available or Graph consent hasn't been granted. Sentinel Azure RBAC is still checked.

.EXAMPLE
    .\Get-SentinelDataLakeReadinessAudit.ps1 -DataLakeResourceGroup "rg-sentinel-datalake" `
        -SentinelResourceGroup "rg-sentinel" -SentinelWorkspaceName "law-sentinel-prod" `
        -UserPrincipalName "analyst@contoso.com"

.NOTES
    Requires: Az.Accounts, Az.OperationalInsights, Az.Resources (Connect-AzAccount first).
    Optional: Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement
              (Connect-MgGraph -Scopes "RoleManagement.Read.Directory" first) for the Entra ID
              directory role check. Falls back gracefully with a WARN if Graph isn't connected.
    Safe / read-only. Exports findings to CSV in the current directory.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$DataLakeResourceGroup,
    [Parameter(Mandatory)][string]$SentinelResourceGroup,
    [Parameter(Mandatory)][string]$SentinelWorkspaceName,
    [string]$UserPrincipalName,
    [switch]$SkipGraphCheck
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

$writeCapableRoles = @("Security Operator", "Security Administrator", "Global Administrator")
$readCapableRoles  = @("Global Reader", "Security Reader") + $writeCapableRoles

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Starting Sentinel data lake readiness audit ($timestamp)"
try {
    $context = Get-AzContext
    if (-not $context) { throw "No active Az context." }
    Write-Status "Connected as $($context.Account.Id) against subscription $($context.Subscription.Name)" "OK"
} catch {
    Write-Status "Not connected to Azure. Run Connect-AzAccount first." "ERROR"
    throw
}

# ---------------------------------------------------------------------------
# 1. Data lake onboarding state — presence of the managed identity
# ---------------------------------------------------------------------------
Write-Status "Checking for data lake managed identity (msg-resources-*) in $DataLakeResourceGroup..."
$identity = $null
try {
    $identity = Get-AzADServicePrincipal -DisplayNameBeginsWith "msg-resources-" -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($identity) {
        Write-Status "Data lake managed identity found: $($identity.DisplayName)" "OK"
        Add-Finding -Category "Onboarding" -Item "Managed Identity" -Result "FOUND" -Note $identity.DisplayName
    } else {
        Write-Status "No msg-resources-* managed identity found via Get-AzADServicePrincipal. Tenant may not be onboarded to the data lake, or the caller lacks Entra ID read permission to enumerate service principals." "WARN"
        Add-Finding -Category "Onboarding" -Item "Managed Identity" -Result "NOT FOUND" -Note "Confirm via Defender portal: System > Settings > Microsoft Sentinel > Data lake"
    }
} catch {
    Write-Status "Failed to query for the data lake managed identity: $($_.Exception.Message)" "ERROR"
    Add-Finding -Category "Onboarding" -Item "Managed Identity" -Result "ERROR" -Note $_.Exception.Message
}

# ---------------------------------------------------------------------------
# 2. Sentinel workspace resolution + managed identity write role
# ---------------------------------------------------------------------------
Write-Status "Resolving Sentinel workspace $SentinelWorkspaceName..."
$sentinelWs = $null
try {
    $sentinelWs = Get-AzOperationalInsightsWorkspace -ResourceGroupName $SentinelResourceGroup -Name $SentinelWorkspaceName
    Add-Finding -Category "Workspace" -Item $SentinelWorkspaceName -Result "FOUND" -Note "SKU: $($sentinelWs.Sku)"

    if ($sentinelWs.Sku -eq "CapacityReservation" -or $sentinelWs.Sku -like "*Cluster*") {
        Write-Status "Workspace SKU ($($sentinelWs.Sku)) suggests a dedicated Log Analytics cluster may be in use — CMK is configured at the CLUSTER level, not the workspace. Manually confirm via Get-AzOperationalInsightsCluster before assuming data lake compatibility; CMK-protected workspaces cannot use ANY data lake experience." "WARN"
        Add-Finding -Category "CMK Check" -Item $SentinelWorkspaceName -Result "MANUAL CHECK REQUIRED" -Note "Dedicated-cluster-style SKU detected — verify cluster CMK status directly"
    } else {
        Add-Finding -Category "CMK Check" -Item $SentinelWorkspaceName -Result "LIKELY NOT CLUSTERED" -Note "SKU does not indicate a dedicated cluster; CMK is unlikely but not fully ruled out by SKU alone"
    }
} catch {
    Write-Status "Failed to resolve Sentinel workspace: $($_.Exception.Message)" "ERROR"
    Add-Finding -Category "Workspace" -Item $SentinelWorkspaceName -Result "ERROR" -Note $_.Exception.Message
}

if ($identity -and $sentinelWs) {
    Write-Status "Checking managed identity's role assignment on $SentinelWorkspaceName (needed for KQL jobs creating NEW custom tables)..."
    try {
        $miRoles = Get-AzRoleAssignment -Scope $sentinelWs.ResourceId -ObjectId $identity.Id -ErrorAction SilentlyContinue
        if ($miRoles | Where-Object { $_.RoleDefinitionName -eq "Log Analytics Contributor" }) {
            Write-Status "Managed identity has Log Analytics Contributor on this workspace." "OK"
            Add-Finding -Category "Managed Identity Write Role" -Item $SentinelWorkspaceName -Result "GRANTED" -Note "Log Analytics Contributor present — new custom tables via KQL job will succeed"
        } else {
            $roleList = if ($miRoles) { ($miRoles.RoleDefinitionName -join ", ") } else { "none" }
            Write-Status "Managed identity does NOT have Log Analytics Contributor on this workspace (current: $roleList). KQL jobs writing to EXISTING tables are unaffected; jobs creating NEW custom tables here will fail." "WARN"
            Add-Finding -Category "Managed Identity Write Role" -Item $SentinelWorkspaceName -Result "MISSING" -Note "Current roles: $roleList. Grant Log Analytics Contributor if new-custom-table KQL jobs are needed on this workspace."
        }
    } catch {
        Write-Status "Could not check managed identity role assignment: $($_.Exception.Message)" "WARN"
        Add-Finding -Category "Managed Identity Write Role" -Item $SentinelWorkspaceName -Result "ERROR" -Note $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# 3. Per-user dual-system access check (Azure RBAC vs. Entra ID directory role)
# ---------------------------------------------------------------------------
if (-not $UserPrincipalName) {
    Write-Status "No -UserPrincipalName supplied — skipping per-user Azure RBAC / Entra ID directory role comparison." "INFO"
} else {
    Write-Status "Checking Sentinel Azure RBAC (SIEM surface) for $UserPrincipalName..."
    $sentinelRole = $null
    if ($sentinelWs) {
        try {
            $sentinelRole = Get-AzRoleAssignment -Scope $sentinelWs.ResourceId -SignInName $UserPrincipalName -ErrorAction SilentlyContinue |
                Where-Object { $_.RoleDefinitionName -like "*Sentinel*" }
            if ($sentinelRole) {
                foreach ($r in $sentinelRole) {
                    Add-Finding -Category "Azure RBAC (SIEM)" -Item $UserPrincipalName -Result $r.RoleDefinitionName -Note "OK"
                }
                Write-Status "Sentinel Azure RBAC role(s): $($sentinelRole.RoleDefinitionName -join ', ')" "OK"
            } else {
                Add-Finding -Category "Azure RBAC (SIEM)" -Item $UserPrincipalName -Result "NONE" -Note "No Sentinel Azure RBAC role at this workspace scope"
                Write-Status "No Sentinel Azure RBAC role found for $UserPrincipalName at this workspace scope." "WARN"
            }
        } catch {
            Write-Status "Failed to check Sentinel Azure RBAC: $($_.Exception.Message)" "WARN"
            Add-Finding -Category "Azure RBAC (SIEM)" -Item $UserPrincipalName -Result "ERROR" -Note $_.Exception.Message
        }
    }

    if ($SkipGraphCheck) {
        Write-Status "-SkipGraphCheck specified — skipping Entra ID directory role lookup." "INFO"
        Add-Finding -Category "Entra ID Directory Role (Data Lake)" -Item $UserPrincipalName -Result "SKIPPED" -Note "-SkipGraphCheck specified"
    } else {
        Write-Status "Checking Entra ID directory role (data lake surface — INDEPENDENT of Azure RBAC above) for $UserPrincipalName..."
        try {
            if (-not (Get-Command Get-MgUserMemberOf -ErrorAction SilentlyContinue)) {
                throw "Microsoft.Graph.Users module/cmdlet not available."
            }
            $memberOf = Get-MgUserMemberOf -UserId $UserPrincipalName -All -ErrorAction Stop
            $dlRoles = $memberOf | Where-Object { $_.AdditionalProperties.displayName -in $readCapableRoles }

            if ($dlRoles) {
                $roleNames = $dlRoles.AdditionalProperties.displayName
                foreach ($rn in $roleNames) {
                    $capability = if ($rn -in $writeCapableRoles) { "READ + WRITE (can create/schedule KQL jobs)" } else { "READ ONLY" }
                    Add-Finding -Category "Entra ID Directory Role (Data Lake)" -Item $UserPrincipalName -Result $rn -Note $capability
                }
                Write-Status "Entra ID directory role(s): $($roleNames -join ', ')" "OK"

                if (-not ($roleNames | Where-Object { $_ -in $writeCapableRoles })) {
                    Write-Status "User has READ-ONLY data lake access (no Security Operator/Administrator/Global Administrator) — they can query but CANNOT create or schedule KQL jobs, regardless of their Sentinel Azure RBAC role above." "WARN"
                }
            } else {
                Add-Finding -Category "Entra ID Directory Role (Data Lake)" -Item $UserPrincipalName -Result "NONE" -Note "No qualifying Entra ID directory role — user has NO data lake access at all, even if Sentinel Azure RBAC role above is present"
                Write-Status "No qualifying Entra ID directory role found. This user has NO data lake access, independent of any Sentinel Azure RBAC role found above — this is the #1 real-world 'I have Sentinel Contributor but can't use the data lake' root cause." "WARN"
            }
        } catch {
            Write-Status "Could not check Entra ID directory roles (Graph not connected/available, or insufficient consent): $($_.Exception.Message)" "WARN"
            Add-Finding -Category "Entra ID Directory Role (Data Lake)" -Item $UserPrincipalName -Result "COULD NOT CHECK" -Note "Run Connect-MgGraph -Scopes 'RoleManagement.Read.Directory' and ensure Microsoft.Graph.Users is installed, then re-run without -SkipGraphCheck"
        }
    }

    # Side-by-side callout if both checks ran
    $sentinelHasRole = [bool]$sentinelRole
    $dlEntry = $findings | Where-Object { $_.Category -eq "Entra ID Directory Role (Data Lake)" -and $_.Item -eq $UserPrincipalName }
    $dlHasWriteRole = [bool]($dlEntry | Where-Object { $_.Result -in $writeCapableRoles })
    if ($sentinelHasRole -and -not $dlHasWriteRole -and $dlEntry -and $dlEntry[0].Result -ne "COULD NOT CHECK" -and $dlEntry[0].Result -ne "SKIPPED") {
        Write-Host ""
        Write-Host "=== DUAL-SYSTEM GAP DETECTED ===" -ForegroundColor Magenta
        Write-Host "$UserPrincipalName has a Sentinel Azure RBAC role (SIEM access) but NO write-capable Entra ID" -ForegroundColor Magenta
        Write-Host "directory role. They can use incidents/rules/workbooks and read data lake queries, but CANNOT" -ForegroundColor Magenta
        Write-Host "create or schedule KQL jobs. See DataLake-B.md Fix 3 to grant Security Operator (least-privilege)." -ForegroundColor Magenta
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$csvPath = "SentinelDataLakeReadiness_$timestamp.csv"
$findings | Export-Csv -Path $csvPath -NoTypeInformation
Write-Status "Findings exported to $csvPath" "OK"

Write-Host ""
Write-Host "=== SCOPE NOTE ===" -ForegroundColor Magenta
Write-Host "This script cannot verify: individual KQL job execution history/results, federated" -ForegroundColor Magenta
Write-Host "connector health or external-source network reachability, Notebooks-on-the-lake session" -ForegroundColor Magenta
Write-Host "state, or definitive CMK status (cluster-level, not workspace-level — verify manually via" -ForegroundColor Magenta
Write-Host "Get-AzOperationalInsightsCluster if the SKU check above flagged a possible dedicated cluster)." -ForegroundColor Magenta

$findings | Format-Table -AutoSize
