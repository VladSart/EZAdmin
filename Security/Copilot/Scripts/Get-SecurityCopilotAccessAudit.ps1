<#
.SYNOPSIS
    Audits Microsoft Security Copilot's three-layer RBAC model for a specific user — Entra
    directory roles that auto-inherit Copilot Owner, Azure RBAC roles relevant to capacity
    management, and (optionally) SCU capacity resource presence in a given subscription.

.DESCRIPTION
    Most Security Copilot access tickets trace back to one of three independent gates that
    are easy to mistake for each other: the Security Copilot platform role itself (Owner/
    Contributor, not an Entra role), the Entra roles that automatically inherit Copilot
    Owner, and the dual Azure+Entra role requirement for managing SCU capacity. This script
    checks what can be verified from Microsoft Graph and Azure RBAC for a given user and
    reports findings against each gate.

    Checks performed:
      - Entra directory role memberships, flagging any that auto-inherit Security Copilot
        Owner (Global Administrator, Security Administrator, Billing Administrator, Intune
        Administrator, Entra Compliance Administrator, Purview Compliance Administrator,
        Purview Data Governance Administrator, Purview Organization Management)
      - Azure RBAC role assignments at the specified subscription scope, flagging whether
        Contributor/Owner is present (required, alongside an Entra security role, to manage
        SCU capacity)
      - Presence of Microsoft.SecurityCopilot/capacities resources in the specified
        subscription, as a sanity check that capacity has been provisioned at all

    Does NOT check the user's direct Security Copilot Owner/Contributor role assignment
    (not exposed via Graph or Az — verify in the Security Copilot portal's Role assignment
    page), does NOT check plugin-specific service RBAC (Sentinel/Intune/Defender XDR/Purview
    roles — those are plugin-specific and out of scope for a single generic script; see
    SecurityCopilot-A.md Remediation Playbook 2 for the per-plugin check pattern), and makes
    no changes of any kind. Read-only audit only.

.PARAMETER UserPrincipalName
    UPN of the user to audit (e.g. user@contoso.com). Mandatory.

.PARAMETER SubscriptionId
    Azure subscription ID to check for Azure RBAC assignments and capacity resources.
    Optional — if omitted, only the Entra directory role check is performed.

.PARAMETER ExportPath
    Path for the CSV export. Default: $env:TEMP\SecurityCopilotAccessAudit_<timestamp>.csv

.EXAMPLE
    .\Get-SecurityCopilotAccessAudit.ps1 -UserPrincipalName "jane.admin@contoso.com" -SubscriptionId "00000000-0000-0000-0000-000000000000"
    # Full audit: Entra roles + Azure RBAC + capacity resource check

.EXAMPLE
    .\Get-SecurityCopilotAccessAudit.ps1 -UserPrincipalName "jane.admin@contoso.com"
    # Entra directory role check only (no Azure subscription context)

.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement, and
              Az.Resources PowerShell modules; RoleManagement.Read.Directory + User.Read.All
              Graph scopes; Reader (or higher) on the target Azure subscription
    Run as:   Any account with the above read permissions — does not require elevation
    Safe/Unsafe: READ-ONLY — makes no changes to role assignments or capacity configuration
    Tested against: Security Copilot GA (2026), Microsoft.Graph SDK, Az.Resources
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $UserPrincipalName,
    [string] $SubscriptionId,
    [string] $ExportPath = "$env:TEMP\SecurityCopilotAccessAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) {
        "OK"     { "Green"  }
        "WARN"   { "Yellow" }
        "ERROR"  { "Red"    }
        "HEADER" { "Cyan"   }
        default  { "White"  }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

#region --- Preflight ---

Write-Status "Microsoft Security Copilot Access Audit" -Status "HEADER"
Write-Status "Target user: $UserPrincipalName  |  Run time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Status "INFO"

$findings = [System.Collections.Generic.List[string]]::new()

$ownerInheritingRoles = @(
    "Global Administrator",
    "Security Administrator",
    "Billing Administrator",
    "Intune Administrator",
    "Compliance Administrator",
    "Purview Compliance Administrator",
    "Purview Data Governance Administrator",
    "Purview Organization Management"
)

#endregion

#region --- Detect: Entra directory roles ---

Write-Status "Checking Entra directory role memberships..." -Status "INFO"
$userDirectoryRoles = @()
$inheritsCopilotOwner = $false

try {
    if (-not (Get-MgContext -ErrorAction SilentlyContinue)) {
        Connect-MgGraph -Scopes "RoleManagement.Read.Directory", "User.Read.All" -NoWelcome
    }

    $memberOf = Get-MgUserMemberOf -UserId $UserPrincipalName -All -ErrorAction Stop
    $userDirectoryRoles = $memberOf |
        Where-Object { $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.directoryRole' } |
        ForEach-Object { $_.AdditionalProperties.displayName }

    foreach ($role in $userDirectoryRoles) {
        if ($ownerInheritingRoles -contains $role) {
            $inheritsCopilotOwner = $true
        }
    }

    if (-not $inheritsCopilotOwner) {
        $findings.Add("User holds no Entra directory role that auto-inherits Security Copilot Owner. Verify their direct Copilot Owner/Contributor assignment in the Security Copilot portal's Role assignment page — this script cannot check that directly.")
    }
} catch {
    $findings.Add("Could not query Entra directory role memberships: $_")
}

#endregion

#region --- Detect: Azure RBAC + capacity resources (only if -SubscriptionId provided) ---

$azureContribOrOwner = $false
$capacityResourceCount = 0
$capacityResourceNames = @()

if ($SubscriptionId) {
    Write-Status "Checking Azure RBAC assignments and capacity resources in subscription $SubscriptionId..." -Status "INFO"
    try {
        if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
            Connect-AzAccount -Subscription $SubscriptionId | Out-Null
        } else {
            Set-AzContext -Subscription $SubscriptionId | Out-Null
        }

        $azAssignments = Get-AzRoleAssignment -SignInName $UserPrincipalName -Scope "/subscriptions/$SubscriptionId" -ErrorAction Stop
        $azureContribOrOwner = [bool]($azAssignments | Where-Object { $_.RoleDefinitionName -in @("Contributor", "Owner") })

        if (-not $azureContribOrOwner) {
            $findings.Add("User has no Contributor/Owner Azure RBAC role on subscription $SubscriptionId. If this user needs to manage SCU capacity, both this AND an Entra Security Administrator+ role are required simultaneously.")
        }

        $capacityResources = Get-AzResource -ResourceType "Microsoft.SecurityCopilot/capacities" -ErrorAction Stop
        $capacityResourceCount = @($capacityResources).Count
        $capacityResourceNames = $capacityResources | ForEach-Object { $_.Name }

        if ($capacityResourceCount -eq 0) {
            $findings.Add("No Microsoft.SecurityCopilot/capacities resource found in subscription $SubscriptionId. If this tenant isn't Microsoft 365 E5/E7-inclusion-eligible, capacity may never have been provisioned.")
        }
    } catch {
        $findings.Add("Could not query Azure RBAC/capacity resources: $_")
    }
} else {
    Write-Status "No -SubscriptionId provided; skipping Azure RBAC and capacity resource checks." -Status "INFO"
}

#endregion

#region --- Report ---

Write-Status "" -Status "INFO"
Write-Status "=== Summary ===" -Status "HEADER"

if ($findings.Count -eq 0) {
    Write-Status "No gaps found in the checks this script can perform. Remaining verification: direct Copilot Owner/Contributor role (portal) and plugin-specific service RBAC (per plugin in the ticket)." -Status "OK"
} else {
    Write-Status "Findings:" -Status "WARN"
    foreach ($f in $findings) { Write-Status "  $f" -Status "WARN" }
}

$exportRow = [pscustomobject]@{
    RunTime                  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    UserPrincipalName        = $UserPrincipalName
    EntraDirectoryRoles      = ($userDirectoryRoles -join '; ')
    InheritsCopilotOwner     = $inheritsCopilotOwner
    SubscriptionChecked      = $SubscriptionId
    AzureContributorOrOwner  = $azureContribOrOwner
    CapacityResourceCount    = $capacityResourceCount
    CapacityResourceNames    = ($capacityResourceNames -join '; ')
    FindingsCount            = $findings.Count
    Findings                 = ($findings -join " | ")
}

$exportRow | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Report exported: $ExportPath" -Status "OK"

#endregion
