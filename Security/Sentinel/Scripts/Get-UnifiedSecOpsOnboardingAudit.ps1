<#
.SYNOPSIS
    Audits a subscription/tenant's readiness and current state for onboarding (or
    already onboarded via) the Microsoft Sentinel + Defender XDR unified security
    operations platform in the Defender portal.

.DESCRIPTION
    Read-only audit against Azure Resource Manager. Reports:
      - Owner role assignments and whether each is UNCONDITIONAL at the target
        subscription scope (the most common silent onboarding blocker)
      - Sentinel-enabled Log Analytics workspaces in the subscription
      - A readiness summary flagging whether at least one account satisfies the
        documented onboarding permission model (Entra ID Security Administrator +
        unconditional Owner, OR User Access Administrator + Microsoft Sentinel
        Contributor)
    Does NOT read primary/secondary workspace designation or standalone connector
    state — those are Defender-portal-managed settings with no stable, documented
    ARM/Graph read surface as of this writing. Capture that page manually
    (System > Settings > Microsoft Sentinel > Workspaces) to complete an evidence
    pack alongside this script's output.
    Does NOT change any role assignment, connect/disconnect any workspace, or
    modify any connector.

.PARAMETER SubscriptionId
    Subscription to audit. Defaults to the current Az context's subscription.

.PARAMETER OutputPath
    Folder to write the CSV export to. Default: current directory.

.EXAMPLE
    .\Get-UnifiedSecOpsOnboardingAudit.ps1
    Audits the current Az context's subscription.

.EXAMPLE
    .\Get-UnifiedSecOpsOnboardingAudit.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000" -OutputPath C:\Evidence

.NOTES
    Requires: Az.Accounts, Az.Resources, Az.OperationalInsights PowerShell modules.
    Run-as: an account with at least Reader on the target subscription and
    Microsoft.Authorization/roleAssignments/read permission.
    Safe/unsafe: fully read-only. Safe to run at any time.
#>

#Requires -Modules Az.Accounts, Az.Resources, Az.OperationalInsights

[CmdletBinding()]
param(
    [string]$SubscriptionId,
    [string]$OutputPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------- Preflight ----------
try {
    $context = Get-AzContext
    if (-not $context) {
        Write-Status "No active Az session — run Connect-AzAccount first." "ERROR"
        throw "No Az context"
    }
} catch {
    Write-Status "Az PowerShell not authenticated: $($_.Exception.Message)" "ERROR"
    throw
}

if ($SubscriptionId) {
    Write-Status "Switching context to subscription $SubscriptionId..."
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
} else {
    $SubscriptionId = (Get-AzContext).Subscription.Id
}
Write-Status "Auditing subscription: $SubscriptionId"

if (-not (Test-Path $OutputPath)) {
    Write-Status "OutputPath '$OutputPath' does not exist, creating it." "WARN"
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

# ---------- Detect: Owner role assignments and condition state ----------
Write-Status "Enumerating Owner role assignments at subscription scope..."
$subScope = "/subscriptions/$SubscriptionId"
$ownerAssignments = Get-AzRoleAssignment -Scope $subScope |
    Where-Object { $_.RoleDefinitionName -eq 'Owner' -and $_.Scope -eq $subScope }

$uaaAssignments = Get-AzRoleAssignment -Scope $subScope |
    Where-Object { $_.RoleDefinitionName -eq 'User Access Administrator' -and $_.Scope -eq $subScope }

$sentinelContribAssignments = Get-AzRoleAssignment |
    Where-Object { $_.RoleDefinitionName -eq 'Microsoft Sentinel Contributor' }

$ownerReport = $ownerAssignments | ForEach-Object {
    [PSCustomObject]@{
        DisplayName    = $_.DisplayName
        SignInName     = $_.SignInName
        ObjectType     = $_.ObjectType
        Scope          = $_.Scope
        Condition      = if ($_.PSObject.Properties['Condition'] -and $_.Condition) { $_.Condition } else { 'None (unconditional)' }
        MeetsOnboardingBar = -not ($_.PSObject.Properties['Condition'] -and $_.Condition)
    }
}

$anyUnconditionalOwner = ($ownerReport | Where-Object MeetsOnboardingBar).Count -gt 0
$uaaPlusSentinelContrib = ($uaaAssignments.Count -gt 0) -and ($sentinelContribAssignments.Count -gt 0)

if ($anyUnconditionalOwner) {
    Write-Status "At least one unconditional Owner assignment found — onboarding permission bar (Owner path) is satisfied." "OK"
} elseif ($uaaPlusSentinelContrib) {
    Write-Status "No unconditional Owner found, but User Access Administrator + Microsoft Sentinel Contributor combination exists — alternate onboarding path satisfied." "OK"
} else {
    Write-Status "NO account satisfies the onboarding permission model (unconditional Owner, or UAA+Sentinel Contributor). Onboarding will fail for everyone until this is fixed. Entra ID Security Administrator is ALSO independently required and not checked by this script (Graph-based, separate permission system)." "WARN"
}

# ---------- Detect: Sentinel-enabled workspaces ----------
Write-Status "Enumerating Log Analytics workspaces in the subscription..."
$workspaces = Get-AzOperationalInsightsWorkspace

$workspaceReport = $workspaces | ForEach-Object {
    [PSCustomObject]@{
        WorkspaceName  = $_.Name
        ResourceGroup  = $_.ResourceGroupName
        Location       = $_.Location
        Sku            = $_.Sku
        # Sentinel-enabled state and primary/secondary designation are not reliably
        # exposed via this cmdlet alone — flagged for manual confirmation in the portal
        Note           = "Confirm Sentinel-enabled and primary/secondary status manually in the Defender portal (System > Settings > Microsoft Sentinel > Workspaces)"
    }
}

# ---------- Report ----------
$summary = [PSCustomObject]@{
    GeneratedAt                    = Get-Date
    SubscriptionId                 = $SubscriptionId
    UnconditionalOwnerFound        = $anyUnconditionalOwner
    UAAPlusSentinelContribFound    = $uaaPlusSentinelContrib
    OnboardingPermissionBarMet     = ($anyUnconditionalOwner -or $uaaPlusSentinelContrib)
    WorkspaceCount                 = $workspaces.Count
    ReminderEntraIDSecurityAdminRequired = "Independently required, Graph-based — not checked by this ARM-only script"
}

$summaryPath = Join-Path $OutputPath "UnifiedSecOps-Readiness-Summary.csv"
$ownerPath = Join-Path $OutputPath "UnifiedSecOps-OwnerAssignments.csv"
$workspacePath = Join-Path $OutputPath "UnifiedSecOps-Workspaces.csv"

$summary | Export-Csv -Path $summaryPath -NoTypeInformation
$ownerReport | Export-Csv -Path $ownerPath -NoTypeInformation
$workspaceReport | Export-Csv -Path $workspacePath -NoTypeInformation

Write-Status "Summary written to $summaryPath" "OK"
Write-Status "Owner assignment detail written to $ownerPath" "OK"
Write-Status "Workspace inventory written to $workspacePath" "OK"
Write-Status "REMINDER: primary/secondary workspace designation and standalone connector state are Defender-portal-managed — confirm manually to complete an evidence pack." "WARN"

$summary | Format-List
$ownerReport | Format-Table -AutoSize
