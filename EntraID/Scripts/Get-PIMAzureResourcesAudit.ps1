<#
.SYNOPSIS
    Audits Microsoft Entra Privileged Identity Management (PIM) for Azure Resources
    across one or more subscriptions.

.DESCRIPTION
    This is the Azure-resource-role counterpart to Get-PIMReport.ps1 (which covers
    Entra directory roles / PIM for Groups only, via Microsoft Graph). PIM for Azure
    resources runs on a completely different API surface — Azure Resource Manager,
    via the Az.Resources module — so it requires its own script rather than an
    extension of the Graph-based one.

    For each subscription in scope, this script:
    - Confirms the MS-PIM service principal still holds User Access Administrator
      at the subscription (a scope-wide single point of failure if missing — flags
      MS_PIM_PERMISSION_MISSING)
    - Confirms the scope has at least one PIM policy assignment, i.e. has actually
      been onboarded/auto-managed (flags SCOPE_NOT_PIM_MANAGED as informational —
      this is not necessarily wrong, some subscriptions are deliberately left
      unmanaged)
    - Enumerates eligible role assignments tenant/fleet-wide and flags eligible
      assignments with no expiry (NO_EXPIRY_ELIGIBLE)
    - Enumerates active (PIM-tracked) role assignments and flags any nearing
      expiry within a configurable warning window (ACTIVE_EXPIRING_SOON)
    - Cross-references PIM-eligible principal+role+scope combinations against
      static (non-PIM) role assignments at the same principal+role+scope, flagging
      STATIC_DUPLICATES_ELIGIBLE — the "removed PIM eligibility but access
      persisted" root cause surfaced proactively instead of reactively

    Explicitly out of scope for this script (see PIMAzureResources-A.md's Evidence
    Pack instead for a single-principal, single-scope deep-dive): approval workflow
    history, activation request audit trail, and Conditional Access authentication
    context configuration — none of these are exposed via a fast fleet-wide Az
    cmdlet and are better pulled per-incident.

    Safe to run in any tenant — read-only Az.Resources/Az.Accounts calls only.

.PARAMETER SubscriptionId
    One or more subscription IDs to audit. If omitted, audits every subscription
    the authenticated principal can enumerate via Get-AzSubscription.

.PARAMETER ExpiringSoonDays
    Number of days used as the warning threshold for active assignments nearing
    expiry. Default: 14.

.PARAMETER OutputPath
    Path for the CSV reports. Default: current directory with timestamp.

.PARAMETER SkipStaticDuplicateCheck
    Skip the static-vs-eligible duplicate cross-reference, which is the slowest
    part of the script (one Get-AzRoleAssignment call per eligible principal).
    Use for a fast MS-PIM-health-only sweep across many subscriptions.

.EXAMPLE
    .\Get-PIMAzureResourcesAudit.ps1
    # Audits every subscription visible to the current context

.EXAMPLE
    .\Get-PIMAzureResourcesAudit.ps1 -SubscriptionId "aaaa0a0a-bb1b-cc2c-dd3d-eeeeee4e4e4e" -ExpiringSoonDays 30

.EXAMPLE
    .\Get-PIMAzureResourcesAudit.ps1 -SkipStaticDuplicateCheck -OutputPath "C:\Reports\PIM"

.NOTES
    Requires: Az.Resources, Az.Accounts modules (Install-Module Az -Scope CurrentUser)
    Permissions needed: Reader (minimum) on each audited subscription for role
        assignment/eligibility visibility; User Access Administrator or Owner is
        needed to see PIM policy assignment detail in some tenants.
    Safe: Read-only. No changes made to any tenant or subscription.
    Run as: Any user with at least Reader on the target subscription(s).
    Does NOT cover Entra directory-role or PIM-for-Groups auditing — use the
        companion script Get-PIMReport.ps1 (Microsoft Graph-based) for that surface.
#>
[CmdletBinding()]
param(
    [string[]]$SubscriptionId = @(),
    [int]$ExpiringSoonDays = 14,
    [string]$OutputPath = ".",
    [switch]$SkipStaticDuplicateCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

# ─── Preflight: module check ─────────────────────────────────────────────────

Write-Status "Checking for Az.Resources / Az.Accounts modules..."
foreach ($mod in @("Az.Accounts", "Az.Resources")) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Status "$mod not found. Installing..." "WARN"
        Install-Module -Name $mod -Scope CurrentUser -Force -Repository PSGallery -AllowClobber
    }
}
Import-Module Az.Accounts, Az.Resources -ErrorAction SilentlyContinue

# ─── Connect ─────────────────────────────────────────────────────────────────

if (-not (Get-AzContext)) {
    Write-Status "Connecting to Azure..."
    Connect-AzAccount | Out-Null
}
Write-Status "Connected as: $((Get-AzContext).Account.Id)" "OK"

# ─── Resolve subscriptions in scope ───────────────────────────────────────────

if ($SubscriptionId.Count -eq 0) {
    Write-Status "No -SubscriptionId supplied — enumerating all visible subscriptions..."
    $Subs = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" }
} else {
    $Subs = $SubscriptionId | ForEach-Object { Get-AzSubscription -SubscriptionId $_ }
}
Write-Status "Auditing $($Subs.Count) subscription(s)." "OK"

# ─── Resolve MS-PIM service principal once ────────────────────────────────────

Write-Status "Resolving MS-PIM service principal..."
$MsPim = Get-AzADServicePrincipal -DisplayName "MS-PIM" -ErrorAction SilentlyContinue
if (-not $MsPim) {
    Write-Status "MS-PIM service principal not found in this tenant. PIM for Azure resources may never have been onboarded here (legacy model), or this tenant is fully on the 2026 auto-managed experience which may not require it. Continuing — MS-PIM checks will report NOT_FOUND." "WARN"
}

# ─── Per-subscription audit ────────────────────────────────────────────────────

$MsPimFindings      = New-Object System.Collections.Generic.List[Object]
$ScopeFindings      = New-Object System.Collections.Generic.List[Object]
$EligibleFindings   = New-Object System.Collections.Generic.List[Object]
$ActiveFindings     = New-Object System.Collections.Generic.List[Object]
$DuplicateFindings  = New-Object System.Collections.Generic.List[Object]

foreach ($sub in $Subs) {
    Write-Status "── Subscription: $($sub.Name) ($($sub.Id)) ──" "INFO"
    try {
        Set-AzContext -Subscription $sub.Id -ErrorAction Stop | Out-Null
    } catch {
        Write-Status "Could not set context to $($sub.Id): $_" "ERROR"
        continue
    }
    $scope = "/subscriptions/$($sub.Id)"

    # --- MS-PIM permission check ---
    $msPimHealthy = $false
    if ($MsPim) {
        try {
            $msPimAssignment = Get-AzRoleAssignment -Scope $scope -ObjectId $MsPim.Id -ErrorAction SilentlyContinue |
                Where-Object { $_.RoleDefinitionName -eq "User Access Administrator" }
            $msPimHealthy = [bool]$msPimAssignment
        } catch {
            $msPimHealthy = $false
        }
    }
    $MsPimFindings.Add([PSCustomObject]@{
        Subscription  = $sub.Name
        SubscriptionId = $sub.Id
        MsPimFound    = [bool]$MsPim
        MsPimHealthy  = $msPimHealthy
        Flag          = if (-not $MsPim) { "MS_PIM_NOT_FOUND" }
                         elseif (-not $msPimHealthy) { "MS_PIM_PERMISSION_MISSING_CRITICAL" }
                         else { "OK" }
    })
    if ($MsPim -and -not $msPimHealthy) {
        Write-Status "  MS-PIM missing User Access Administrator at this scope — PIM is broken here for ALL users." "ERROR"
    }

    # --- Scope onboarding / policy check ---
    try {
        $policies = Get-AzRoleManagementPolicyAssignment -Scope $scope -ErrorAction Stop
    } catch {
        $policies = @()
    }
    $ScopeFindings.Add([PSCustomObject]@{
        Subscription   = $sub.Name
        SubscriptionId = $sub.Id
        PolicyCount    = $policies.Count
        Flag           = if ($policies.Count -eq 0) { "SCOPE_NOT_PIM_MANAGED_INFO" } else { "OK" }
    })

    # --- Eligible assignments at this scope ---
    try {
        $eligible = Get-AzRoleEligibilityScheduleInstance -Scope $scope -ErrorAction Stop
    } catch {
        Write-Status "  Could not retrieve eligible schedules: $_" "WARN"
        $eligible = @()
    }
    foreach ($e in $eligible) {
        $hasExpiry = -not [string]::IsNullOrEmpty($e.EndDateTime)
        $EligibleFindings.Add([PSCustomObject]@{
            Subscription    = $sub.Name
            SubscriptionId  = $sub.Id
            PrincipalId     = $e.PrincipalId
            PrincipalType   = $e.PrincipalType
            MemberType      = $e.MemberType
            RoleDefinitionId = $e.RoleDefinitionId
            Status          = $e.Status
            StartDateTime   = $e.StartDateTime
            EndDateTime     = $e.EndDateTime
            HasExpiry       = $hasExpiry
            Flag            = if (-not $hasExpiry) { "NO_EXPIRY_ELIGIBLE" } else { "OK" }
        })
    }

    # --- Active (PIM-tracked) assignments at this scope ---
    try {
        $active = Get-AzRoleAssignmentScheduleInstance -Scope $scope -ErrorAction Stop
    } catch {
        Write-Status "  Could not retrieve active schedules: $_" "WARN"
        $active = @()
    }
    foreach ($a in $active) {
        $hasExpiry = -not [string]::IsNullOrEmpty($a.EndDateTime)
        $daysToExpiry = if ($hasExpiry) { [math]::Round(([datetime]$a.EndDateTime - (Get-Date)).TotalDays, 1) } else { $null }
        $flag = "OK"
        if ($hasExpiry -and $daysToExpiry -le $ExpiringSoonDays -and $daysToExpiry -ge 0) { $flag = "ACTIVE_EXPIRING_SOON" }
        elseif ($hasExpiry -and $daysToExpiry -lt 0) { $flag = "ACTIVE_EXPIRED_STALE_RECORD" }

        $ActiveFindings.Add([PSCustomObject]@{
            Subscription    = $sub.Name
            SubscriptionId  = $sub.Id
            PrincipalId     = $a.PrincipalId
            PrincipalType   = $a.PrincipalType
            MemberType      = $a.MemberType
            RoleDefinitionId = $a.RoleDefinitionId
            AssignmentType  = $a.AssignmentType
            StartDateTime   = $a.StartDateTime
            EndDateTime     = $a.EndDateTime
            HasExpiry       = $hasExpiry
            DaysToExpiry    = $daysToExpiry
            Flag            = $flag
        })
    }

    # --- Static-vs-eligible duplicate cross-reference (opt-out, slowest check) ---
    if (-not $SkipStaticDuplicateCheck -and $eligible.Count -gt 0) {
        Write-Status "  Cross-referencing $($eligible.Count) eligible assignment(s) against static assignments..."
        $uniquePrincipals = $eligible | Select-Object -ExpandProperty PrincipalId -Unique
        foreach ($pid in $uniquePrincipals) {
            try {
                $staticAssignments = Get-AzRoleAssignment -Scope $scope -ObjectId $pid -ErrorAction SilentlyContinue
            } catch {
                $staticAssignments = @()
            }
            $principalEligibleRoles = $eligible | Where-Object { $_.PrincipalId -eq $pid } | Select-Object -ExpandProperty RoleDefinitionId -Unique
            foreach ($sa in $staticAssignments) {
                $saRoleDefId = $sa.RoleDefinitionId
                if ($principalEligibleRoles -contains $saRoleDefId) {
                    $DuplicateFindings.Add([PSCustomObject]@{
                        Subscription    = $sub.Name
                        SubscriptionId  = $sub.Id
                        PrincipalId     = $pid
                        RoleDefinitionName = $sa.RoleDefinitionName
                        RoleDefinitionId   = $saRoleDefId
                        StaticAssignmentScope = $sa.Scope
                        Flag            = "STATIC_DUPLICATES_ELIGIBLE"
                    })
                }
            }
        }
    }
}

# ─── Export reports ───────────────────────────────────────────────────────────

$Date = Get-Date -Format "yyyyMMdd-HHmm"
$OutDir = Resolve-Path $OutputPath

$MsPimCsv     = Join-Path $OutDir "PIMAzureResources-MsPimHealth-$Date.csv"
$ScopeCsv     = Join-Path $OutDir "PIMAzureResources-ScopeOnboarding-$Date.csv"
$EligibleCsv  = Join-Path $OutDir "PIMAzureResources-Eligible-$Date.csv"
$ActiveCsv    = Join-Path $OutDir "PIMAzureResources-Active-$Date.csv"
$DuplicateCsv = Join-Path $OutDir "PIMAzureResources-StaticDuplicates-$Date.csv"

if ($MsPimFindings.Count -gt 0)     { $MsPimFindings     | Export-Csv -Path $MsPimCsv     -NoTypeInformation -Encoding UTF8 }
if ($ScopeFindings.Count -gt 0)     { $ScopeFindings     | Export-Csv -Path $ScopeCsv     -NoTypeInformation -Encoding UTF8 }
if ($EligibleFindings.Count -gt 0)  { $EligibleFindings  | Export-Csv -Path $EligibleCsv  -NoTypeInformation -Encoding UTF8 }
if ($ActiveFindings.Count -gt 0)    { $ActiveFindings    | Export-Csv -Path $ActiveCsv    -NoTypeInformation -Encoding UTF8 }
if ($DuplicateFindings.Count -gt 0) { $DuplicateFindings | Export-Csv -Path $DuplicateCsv -NoTypeInformation -Encoding UTF8 }

# ─── Summary ─────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " PIM for Azure Resources — Fleet Audit Summary" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Subscriptions audited:        $($Subs.Count)"
Write-Host "  Eligible assignments found:   $($EligibleFindings.Count)"
Write-Host "  Active assignments found:     $($ActiveFindings.Count)"

$MsPimCritical = $MsPimFindings | Where-Object Flag -eq "MS_PIM_PERMISSION_MISSING_CRITICAL"
if ($MsPimCritical.Count -gt 0) {
    Write-Status "CRITICAL: $($MsPimCritical.Count) subscription(s) with MS-PIM permission missing — PIM is broken for every user at these scopes:" "ERROR"
    $MsPimCritical | Select-Object Subscription, SubscriptionId | Format-Table -AutoSize
}

$UnmanagedScopes = $ScopeFindings | Where-Object Flag -eq "SCOPE_NOT_PIM_MANAGED_INFO"
if ($UnmanagedScopes.Count -gt 0) {
    Write-Status "$($UnmanagedScopes.Count) subscription(s) show no PIM policy assignments (may be intentionally unmanaged — informational only)." "WARN"
}

$NoExpiry = $EligibleFindings | Where-Object Flag -eq "NO_EXPIRY_ELIGIBLE"
if ($NoExpiry.Count -gt 0) {
    Write-Status "$($NoExpiry.Count) eligible assignment(s) with no expiry set." "WARN"
}

$ExpiringSoon = $ActiveFindings | Where-Object Flag -eq "ACTIVE_EXPIRING_SOON"
if ($ExpiringSoon.Count -gt 0) {
    Write-Status "$($ExpiringSoon.Count) active assignment(s) expiring within $ExpiringSoonDays days." "WARN"
}

if (-not $SkipStaticDuplicateCheck -and $DuplicateFindings.Count -gt 0) {
    Write-Status "$($DuplicateFindings.Count) static assignment(s) duplicate a PIM-eligible assignment for the same principal+role — removing PIM eligibility alone will NOT revoke access for these:" "WARN"
    $DuplicateFindings | Select-Object Subscription, PrincipalId, RoleDefinitionName | Format-Table -AutoSize
}

Write-Host ""
Write-Status "Reports saved to: $OutDir" "OK"
Write-Host "  $MsPimCsv"
Write-Host "  $ScopeCsv"
Write-Host "  $EligibleCsv"
Write-Host "  $ActiveCsv"
if (-not $SkipStaticDuplicateCheck) { Write-Host "  $DuplicateCsv" }
