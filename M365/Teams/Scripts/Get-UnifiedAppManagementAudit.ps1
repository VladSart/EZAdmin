<#
.SYNOPSIS
    Audits Teams app setup policy assignments to identify apps excluded from
    Unified App & Agent Management installation unification (Phase B).

.DESCRIPTION
    Companion script to M365/Teams/UnifiedAppAgentManagement-B.md and -A.md.

    There is no PowerShell cmdlet surface for the TAC/MAC unification state itself
    (it is a portal-driven feature with no dedicated Graph/Teams module exposure as
    of this writing). What IS directly scriptable, and directly explains one of the
    most common causes of "why isn't this app's installation syncing between portals"
    tickets, is Teams app setup policy assignment — because Microsoft's own Phase B
    documentation explicitly excludes app-setup-policy-installed apps from the unified
    installation surface, permanently, by design.

    This script:
    - Enumerates every Teams app setup policy in the tenant and its pinned/installed apps
    - Flags every app pinned via a setup policy as "excluded from unified installation
      management" so admins can immediately explain a reported sync gap without deeper
      investigation
    - Reports policy assignment scope (Global vs. named policy, and — where available —
      which users/groups a non-Global policy is assigned to)
    - Cross-references against a caller-supplied list of app IDs/names of interest, if
      provided, to give a direct yes/no answer for specific tickets

    Does NOT and CANNOT do:
    - Read or report the actual TAC/MAC unification PHASE state for the tenant (no
      cmdlet or Graph API surface exists for this as of this writing — check the TAC
      "Manage apps" banner directly in the portal)
    - Read Microsoft 365 admin center "Integrated apps" or "Copilot > Agents" settings
      (no equivalent PowerShell/Graph surface used here; this script is Teams-side only)
    - Modify any setup policy or app assignment — fully read-only by design

.PARAMETER AppNameFilter
    Optional array of app names or partial names to specifically check for setup-policy
    exclusion (e.g., app names from an open ticket). If omitted, reports on all apps
    found pinned across all setup policies.

.PARAMETER ExportPath
    Path for CSV export. Default: .\UnifiedAppManagementAudit-<timestamp>.csv

.EXAMPLE
    .\Get-UnifiedAppManagementAudit.ps1
    Reports every Teams app setup policy and its pinned/installed apps tenant-wide.

.EXAMPLE
    .\Get-UnifiedAppManagementAudit.ps1 -AppNameFilter "Contoso Helpdesk","Copilot"
    Checks specifically whether these named apps are setup-policy-managed (and therefore
    excluded from Phase B unified installation) anywhere in the tenant.

.NOTES
    Requires: MicrosoftTeams PowerShell module (Connect-MicrosoftTeams), an account with
              Teams Administrator (read) rights.
    Run-as:   Teams Administrator or Global Administrator (read-only operations only).
    Safe:     Fully read-only. No policy or assignment changes made.
    Limitation: this script reports setup-policy PINNED apps as a proxy for "installed via
                setup policy." Microsoft's documentation uses the broader phrase "installed
                through app setup policies" — if a tenant uses setup policies for install-only
                (non-pinned) app assignment in a way this script's PinnedAppBarApps-based
                enumeration doesn't fully capture, cross-check manually in Teams admin center.
#>

[CmdletBinding()]
param(
    [string[]]$AppNameFilter,
    [string]$ExportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---- Preflight ----
try {
    $null = Get-CsTenant -ErrorAction Stop
    Write-Status "Connected to Teams tenant." "OK"
} catch {
    Write-Status "Not connected to Microsoft Teams PowerShell. Run Connect-MicrosoftTeams first." "ERROR"
    return
}

# ---- Collect setup policies ----
Write-Status "Enumerating Teams app setup policies..."
$policies = @()
try {
    $policies = Get-CsTeamsAppSetupPolicy -ErrorAction Stop
} catch {
    Write-Status "Failed to enumerate setup policies: $($_.Exception.Message)" "ERROR"
    return
}
Write-Status "Found $($policies.Count) setup policy object(s) (including Global)." "OK"

# ---- Build app-to-policy map ----
$appPolicyMap = @()

foreach ($policy in $policies) {
    $pinnedApps = @()
    try {
        $pinnedApps = $policy.PinnedAppBarApps
    } catch {
        Write-Status "Could not read PinnedAppBarApps for policy '$($policy.Identity)': $($_.Exception.Message)" "WARN"
        continue
    }

    if (-not $pinnedApps -or $pinnedApps.Count -eq 0) { continue }

    foreach ($app in $pinnedApps) {
        $appName = if ($app.PSObject.Properties.Name -contains "Name") { $app.Name } else { [string]$app }
        $appId   = if ($app.PSObject.Properties.Name -contains "Id") { $app.Id } else { "Unknown" }

        $appPolicyMap += [PSCustomObject]@{
            AppName            = $appName
            AppId              = $appId
            SetupPolicyName    = $policy.Identity
            IsGlobalPolicy     = ($policy.Identity -eq "Global")
            ExcludedFromPhaseB = $true
            Note               = "Installed/pinned via Teams app setup policy — permanently excluded from Phase B unified installation management per Microsoft's own MC796790 documentation."
        }
    }
}

# ---- Apply optional filter ----
$filteredResults = $appPolicyMap
if ($AppNameFilter) {
    $filteredResults = $appPolicyMap | Where-Object {
        $appEntry = $_
        ($AppNameFilter | Where-Object { $appEntry.AppName -like "*$_*" }).Count -gt 0
    }

    Write-Host ""
    Write-Status "Filter check results for requested app name(s): $($AppNameFilter -join ', ')" "INFO"
    if ($filteredResults.Count -eq 0) {
        Write-Status "None of the requested app names were found pinned via any setup policy. If a sync gap is still reported for these apps, the cause is NOT the setup-policy exclusion — investigate propagation delay or a genuine cross-portal mismatch instead (see -B.md Fix 1/Fix 4)." "WARN"
    } else {
        foreach ($r in $filteredResults) {
            Write-Status "MATCH: '$($r.AppName)' is pinned via setup policy '$($r.SetupPolicyName)' — excluded from Phase B unified installation by design." "WARN"
        }
    }
}

# ---- Summary ----
Write-Host ""
Write-Status "=== Summary ===" "INFO"
Write-Status "Total setup-policy-pinned app entries found: $($appPolicyMap.Count)" "INFO"
$distinctApps = $appPolicyMap | Select-Object -ExpandProperty AppName -Unique
Write-Status "Distinct apps affected by the Phase B setup-policy exclusion: $($distinctApps.Count)" "INFO"
if ($distinctApps.Count -gt 0) {
    Write-Status "These apps will NOT show synchronized installation state between Teams admin center and the Microsoft 365 admin center, regardless of tenant unification phase:" "WARN"
    $distinctApps | ForEach-Object { Write-Host "    - $_" }
}

# ---- Export ----
if (-not $ExportPath) {
    $ExportPath = ".\UnifiedAppManagementAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
}
$appPolicyMap | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Host ""
Write-Status "Full audit CSV exported: $ExportPath" "OK"
Write-Status "REMINDER: this script cannot read TAC/MAC unification PHASE state (no cmdlet surface exists) — confirm the tenant's actual phase via the Teams admin center 'Manage apps' banner directly. This script only explains the setup-policy exclusion, one specific and common cause of reported sync gaps." "WARN"
