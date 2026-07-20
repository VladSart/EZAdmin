<#
.SYNOPSIS
    Audits access and network readiness for Microsoft Sentinel Jupyter Notebooks (MSTICPy / Azure Machine Learning).

.DESCRIPTION
    Sentinel notebooks run on a SEPARATE Azure Machine Learning (AML) workspace, gated by two
    independent RBAC systems (Sentinel workspace RBAC and AML workspace RBAC) plus the AML
    workspace's storage-account network posture. This script is a read-only reconnaissance tool
    that checks what CAN be verified via Az PowerShell:
      - Sentinel role assignments at the Log Analytics workspace scope
      - AML workspace discovery and role assignments at the AML workspace scope
      - The AML workspace's default storage account PublicNetworkAccess / firewall rules
        (the setting that silently blocks direct "Launch notebook" from Sentinel)
      - Compute instances present in the AML workspace and their provisioning state

    It deliberately does NOT and CANNOT check (these require a live notebook/Jupyter session or
    the AML Studio portal, not an Az PowerShell/API surface):
      - msticpyconfig.yaml contents, validity, or location
      - MSTICPy query-provider authentication state or active workspace alias
      - External data provider (VirusTotal, MaxMind GeoLite2) key configuration
      - Individual notebook cell contents, kernel state, or which notebooks use MSTICPy at all
    The script's console output says so explicitly rather than silently omitting this scope.

.PARAMETER SentinelResourceGroup
    Resource group containing the Sentinel (Log Analytics) workspace.

.PARAMETER SentinelWorkspaceName
    Name of the Sentinel-enabled Log Analytics workspace.

.PARAMETER AMLResourceGroup
    Resource group containing the Azure Machine Learning workspace used for Sentinel notebooks.
    If omitted, the script only reports on the Sentinel-side RBAC and skips AML checks.

.PARAMETER AMLWorkspaceName
    Name of the Azure Machine Learning workspace. If omitted but -AMLResourceGroup is supplied,
    the script lists all AML workspaces found in that resource group.

.PARAMETER UserPrincipalName
    Optional. Filter role-assignment results to a specific user for a targeted "why can't this
    person launch a notebook" investigation. If omitted, all role assignments are returned.

.EXAMPLE
    .\Get-SentinelNotebookReadinessAudit.ps1 -SentinelResourceGroup "rg-sentinel" -SentinelWorkspaceName "law-sentinel-prod" `
        -AMLResourceGroup "rg-sentinel-ml" -AMLWorkspaceName "aml-sentinel-notebooks" -UserPrincipalName "analyst@contoso.com"

.NOTES
    Requires: Az.Accounts, Az.OperationalInsights, Az.Resources, Az.Storage (Connect-AzAccount first).
    Safe / read-only. Exports findings to CSV/JSON in the current directory.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SentinelResourceGroup,
    [Parameter(Mandatory)][string]$SentinelWorkspaceName,
    [string]$AMLResourceGroup,
    [string]$AMLWorkspaceName,
    [string]$UserPrincipalName
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

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
Write-Status "Starting Sentinel Notebooks readiness audit ($timestamp)"
try {
    $context = Get-AzContext
    if (-not $context) { throw "No active Az context." }
    Write-Status "Connected as $($context.Account.Id) against subscription $($context.Subscription.Name)" "OK"
} catch {
    Write-Status "Not connected to Azure. Run Connect-AzAccount first." "ERROR"
    throw
}

# ---------------------------------------------------------------------------
# 1. Sentinel-side RBAC
# ---------------------------------------------------------------------------
Write-Status "Checking Sentinel workspace RBAC..."
try {
    $sentinelWs = Get-AzOperationalInsightsWorkspace -ResourceGroupName $SentinelResourceGroup -Name $SentinelWorkspaceName
    $sentinelRoles = Get-AzRoleAssignment -Scope $sentinelWs.ResourceId | Where-Object { $_.RoleDefinitionName -like "*Sentinel*" }
    if ($UserPrincipalName) {
        $sentinelRoles = $sentinelRoles | Where-Object { $_.SignInName -eq $UserPrincipalName }
    }

    if ($sentinelRoles) {
        foreach ($r in $sentinelRoles) {
            Add-Finding -Category "Sentinel RBAC" -Item $r.SignInName -Result $r.RoleDefinitionName -Note "OK"
        }
        Write-Status "Found $($sentinelRoles.Count) Sentinel role assignment(s)." "OK"
    } else {
        $note = if ($UserPrincipalName) { "No Sentinel role found for $UserPrincipalName — cannot save/launch notebook templates." } else { "No Sentinel roles found at all in this scope — verify workspace name/RG." }
        Add-Finding -Category "Sentinel RBAC" -Item ($UserPrincipalName ?? "ALL") -Result "MISSING" -Note $note
        Write-Status $note "WARN"
    }
} catch {
    Write-Status "Failed to query Sentinel workspace: $($_.Exception.Message)" "ERROR"
    Add-Finding -Category "Sentinel RBAC" -Item $SentinelWorkspaceName -Result "ERROR" -Note $_.Exception.Message
}

# ---------------------------------------------------------------------------
# 2. AML workspace discovery + RBAC
# ---------------------------------------------------------------------------
if (-not $AMLResourceGroup) {
    Write-Status "No -AMLResourceGroup supplied — skipping AML workspace, network, and compute checks. Sentinel-side RBAC alone does not confirm notebook launch will work." "WARN"
    Add-Finding -Category "AML Workspace" -Item "N/A" -Result "SKIPPED" -Note "AMLResourceGroup not provided"
} else {
    Write-Status "Checking Azure Machine Learning workspace(s) in $AMLResourceGroup..."
    try {
        $amlWorkspaces = Get-AzResource -ResourceType "Microsoft.MachineLearningServices/workspaces" -ResourceGroupName $AMLResourceGroup
        if ($AMLWorkspaceName) {
            $amlWorkspaces = $amlWorkspaces | Where-Object { $_.Name -eq $AMLWorkspaceName }
        }

        if (-not $amlWorkspaces) {
            Write-Status "No AML workspace found matching the given parameters. Notebooks cannot be launched until one is created (Notebooks > Configure Azure Machine Learning)." "WARN"
            Add-Finding -Category "AML Workspace" -Item ($AMLWorkspaceName ?? "ALL") -Result "NOT FOUND" -Note "No AML workspace exists in $AMLResourceGroup"
        }

        foreach ($amlWs in $amlWorkspaces) {
            Write-Status "Found AML workspace: $($amlWs.Name)" "OK"
            Add-Finding -Category "AML Workspace" -Item $amlWs.Name -Result "FOUND" -Note $amlWs.ResourceId

            # --- 2a. AML RBAC ---
            $amlRoles = Get-AzRoleAssignment -Scope $amlWs.ResourceId
            if ($UserPrincipalName) { $amlRoles = $amlRoles | Where-Object { $_.SignInName -eq $UserPrincipalName } }

            if ($amlRoles) {
                foreach ($r in $amlRoles) {
                    Add-Finding -Category "AML RBAC" -Item "$($amlWs.Name) / $($r.SignInName)" -Result $r.RoleDefinitionName -Note "OK"
                }
            } else {
                $note = if ($UserPrincipalName) { "$UserPrincipalName has a Sentinel role but NO role on AML workspace '$($amlWs.Name)' — this is the #1 real-world 'access looks fine but launch fails' root cause." } else { "No role assignments found on this AML workspace." }
                Add-Finding -Category "AML RBAC" -Item "$($amlWs.Name) / $($UserPrincipalName ?? 'ALL')" -Result "MISSING" -Note $note
                Write-Status $note "WARN"
            }

            # --- 2b. Storage account network posture ---
            try {
                $amlWsFull = Get-AzResource -ResourceId $amlWs.ResourceId -ExpandProperties
                $storageAccountId = $amlWsFull.Properties.storageAccount
                if ($storageAccountId) {
                    $storageParts = $storageAccountId -split "/"
                    $storageRg   = $storageParts[4]
                    $storageName = $storageParts[-1]
                    $storageAcct = Get-AzStorageAccount -ResourceGroupName $storageRg -Name $storageName -ErrorAction Stop

                    $publicAccess = $storageAcct.PublicNetworkAccess
                    $defaultAction = $storageAcct.NetworkRuleSet.DefaultAction

                    if ($publicAccess -eq "Disabled" -or $defaultAction -eq "Deny") {
                        $note = "PublicNetworkAccess=$publicAccess, DefaultAction=$defaultAction. Direct 'Launch notebook' from Sentinel WILL FAIL for this workspace by design — use the manual template copy/upload workaround into AML Studio."
                        Add-Finding -Category "AML Network" -Item $storageName -Result "RESTRICTED" -Note $note
                        Write-Status $note "WARN"
                    } else {
                        Add-Finding -Category "AML Network" -Item $storageName -Result "OPEN" -Note "PublicNetworkAccess=$publicAccess, DefaultAction=$defaultAction"
                        Write-Status "AML storage account network posture looks unrestricted." "OK"
                    }
                } else {
                    Add-Finding -Category "AML Network" -Item $amlWs.Name -Result "UNKNOWN" -Note "Could not resolve default storage account from workspace properties."
                }
            } catch {
                Write-Status "Could not evaluate AML storage network posture: $($_.Exception.Message)" "WARN"
                Add-Finding -Category "AML Network" -Item $amlWs.Name -Result "ERROR" -Note $_.Exception.Message
            }

            # --- 2c. Compute instances ---
            try {
                $computes = Get-AzResource -ResourceType "Microsoft.MachineLearningServices/workspaces/computes" -ResourceGroupName $AMLResourceGroup |
                    Where-Object { $_.Name -like "$($amlWs.Name)/*" }
                if ($computes) {
                    foreach ($c in $computes) {
                        Add-Finding -Category "AML Compute" -Item $c.Name -Result "FOUND" -Note "Verify running/stopped state in AML Studio — provisioning state is not always reflected via Get-AzResource."
                    }
                } else {
                    Add-Finding -Category "AML Compute" -Item $amlWs.Name -Result "NONE FOUND" -Note "No compute instances exist yet — notebook cells cannot execute until one is created."
                    Write-Status "No compute instances found for $($amlWs.Name)." "WARN"
                }
            } catch {
                Write-Status "Could not enumerate compute instances: $($_.Exception.Message)" "WARN"
                Add-Finding -Category "AML Compute" -Item $amlWs.Name -Result "ERROR" -Note $_.Exception.Message
            }
        }
    } catch {
        Write-Status "Failed to query AML workspace(s): $($_.Exception.Message)" "ERROR"
        Add-Finding -Category "AML Workspace" -Item $AMLResourceGroup -Result "ERROR" -Note $_.Exception.Message
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
$csvPath = "SentinelNotebookReadiness_$timestamp.csv"
$findings | Export-Csv -Path $csvPath -NoTypeInformation
Write-Status "Findings exported to $csvPath" "OK"

Write-Host ""
Write-Host "=== SCOPE NOTE ===" -ForegroundColor Magenta
Write-Host "This script cannot verify: msticpyconfig.yaml contents/validity, MSTICPy query-provider" -ForegroundColor Magenta
Write-Host "auth state, VirusTotal/MaxMind key configuration, notebook cell contents, or kernel state." -ForegroundColor Magenta
Write-Host "Capture those manually from the failing notebook session (see Notebooks-A.md Evidence Pack)." -ForegroundColor Magenta

$findings | Format-Table -AutoSize
