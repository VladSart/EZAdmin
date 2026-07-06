<#
.SYNOPSIS
    Audits Conditional Access policies tenant-wide for the design-safety issues CA-Design-A/B.md
    flag as the recurring causes of mass-lockout incidents.

.DESCRIPTION
    Runs a single-pass, read-only audit across every Conditional Access policy in the tenant and
    flags:

    - MISSING_BREAKGLASS_EXCLUSION — an enabled (or report-only) policy does not exclude one or
      more of the supplied break-glass account UPNs. CA-Design-B.md Fix 3 / CA-Design-A.md
      Learning Pointers calls this "the single most common cause of mass lockout incidents" and
      notes exclusions must be added manually to every new policy — it is never automatic.
    - BROAD_SCOPE_NO_PILOT — a policy targets "All users" (no group/user scoping) with zero
      excluded groups, i.e. it was never run through a pilot-group phase (CA-Design-B.md Fix 2).
    - LEGACY_AUTH_GAP — a policy with an MFA or Block grant control does not include
      "exchangeActiveSync" and "other" in its Client App Types, meaning legacy auth protocols
      bypass it entirely (CA-Design-B.md Fix 4).
    - RECENTLY_ENABLED — a policy's State is "enabled" and it was created or last modified within
      the lookback window, i.e. a change that has NOT had a meaningful observation period. This is
      a heuristic proxy for "skipped Report-only" since Graph does not expose a policy's full
      state-transition history (CA-Design-A.md Dependency Stack's "Report-only First" interlock).
    - POTENTIAL_GRANT_CONFLICT — two enabled policies both match overlapping Users/Groups AND
      overlapping Applications but require different, potentially mutually-exclusive device-state
      grant controls (hybridAzureADJoined vs. compliantDevice) — the BYOD-can-satisfy-neither
      scenario from CA-Design-B.md Fix 5.

    Read-only. Makes no changes to any policy. Companion to the manual Triage/Diagnosis steps in
    CA-Design-B.md and CA-Design-A.md — this script automates all four in one pass instead of a
    per-policy manual walkthrough.

.PARAMETER BreakGlassUpns
    Array of break-glass account UPNs that must be excluded from every policy.
    Example: -BreakGlassUpns "breakglass1@contoso.com","breakglass2@contoso.com"

.PARAMETER RecentChangeHours
    Window (in hours) within which an enabled policy's CreatedDateTime/ModifiedDateTime is
    considered "recently enabled" for the RECENTLY_ENABLED heuristic. Default: 24.

.PARAMETER OutputPath
    Path to export CSV reports. Default: C:\Temp\CAPolicyDesignAudit-<timestamp>

.EXAMPLE
    .\Get-CAPolicyDesignAudit.ps1 -BreakGlassUpns "breakglass1@contoso.com","breakglass2@contoso.com"

.EXAMPLE
    # Widen the "recently changed" window to 72 hours after a busy change week
    .\Get-CAPolicyDesignAudit.ps1 -BreakGlassUpns "bg1@contoso.com" -RecentChangeHours 72

.NOTES
    Requires: Microsoft.Graph.Identity.SignIns, Microsoft.Graph.Users, Microsoft.Graph.Groups modules
    Install:  Install-Module Microsoft.Graph -Scope CurrentUser
    Auth:     Connect-MgGraph -Scopes "Policy.Read.All","Directory.Read.All"
    Permissions: Conditional Access Administrator (read) or Global Reader
    Grant-conflict detection is a heuristic based on overlapping scope + known-conflicting
    built-in controls (hybridAzureADJoined vs. compliantDevice) — always confirm with the portal
    What If tool before treating a flagged pair as a confirmed conflict (no Graph/PowerShell
    equivalent to What If exists as of 2026, per CA-Design-A.md Validation Step 5).
    Companion runbooks: Security/ConditionalAccess/CA-Design-A.md and CA-Design-B.md
#>

[CmdletBinding()]
param(
    [Parameter()][string[]]$BreakGlassUpns = @(),
    [Parameter()][int]$RecentChangeHours = 24,
    [Parameter()][string]$OutputPath = "C:\Temp\CAPolicyDesignAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $Colour = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        default { "Cyan" }
    }
    Write-Host "[$Status] $Message" -ForegroundColor $Colour
}

# ─── Preflight ────────────────────────────────────────────────────────────────

Write-Status "Checking for required Microsoft Graph modules..."
foreach ($Mod in @("Microsoft.Graph.Identity.SignIns","Microsoft.Graph.Users")) {
    if (-not (Get-Module -ListAvailable -Name $Mod)) {
        Write-Status "$Mod not found. Installing..." "WARN"
        Install-Module $Mod -Scope CurrentUser -Force -AllowClobber
    }
}

Write-Status "Connecting to Microsoft Graph..."
Connect-MgGraph -Scopes "Policy.Read.All","Directory.Read.All" -NoWelcome

if (-not (Get-MgContext)) {
    Write-Status "Graph connection failed." "ERROR"
    exit 1
}

# Resolve break-glass UPNs to object IDs up front
$BreakGlassIds = @{}
foreach ($Upn in $BreakGlassUpns) {
    try {
        $U = Get-MgUser -UserId $Upn -ErrorAction Stop
        $BreakGlassIds[$Upn] = $U.Id
    } catch {
        Write-Status "Could not resolve break-glass UPN '$Upn' — skipping exclusion check for this account: $_" "WARN"
    }
}
if ($BreakGlassUpns.Count -eq 0) {
    Write-Status "No -BreakGlassUpns supplied — MISSING_BREAKGLASS_EXCLUSION checks will be skipped." "WARN"
}

# ─── Detect: pull every policy ────────────────────────────────────────────────

Write-Status "Retrieving all Conditional Access policies..."
$AllPolicies = Get-MgIdentityConditionalAccessPolicy -All
$ActivePolicies = $AllPolicies | Where-Object { $_.State -in @("enabled","enabledForReportingButNotEnforced") }

Write-Status "Found $($AllPolicies.Count) total policies ($($ActivePolicies.Count) enabled or report-only)." "OK"

$Findings = [System.Collections.Generic.List[PSCustomObject]]::new()
$Since = (Get-Date).ToUniversalTime().AddHours(-$RecentChangeHours)

# ─── Execute: per-policy checks ────────────────────────────────────────────────

foreach ($Policy in $ActivePolicies) {
    $Flags = [System.Collections.Generic.List[string]]::new()

    $ExcludeUsers  = @($Policy.Conditions.Users.ExcludeUsers)
    $IncludeUsers  = @($Policy.Conditions.Users.IncludeUsers)
    $ExcludeGroups = @($Policy.Conditions.Users.ExcludeGroups)
    $ClientAppTypes = @($Policy.Conditions.ClientAppTypes)
    $GrantControls  = @($Policy.GrantControls.BuiltInControls)

    # --- MISSING_BREAKGLASS_EXCLUSION ---
    if ($BreakGlassIds.Count -gt 0) {
        $Missing = $BreakGlassIds.GetEnumerator() | Where-Object { $_.Value -notin $ExcludeUsers }
        if ($Missing) {
            $Flags.Add("MISSING_BREAKGLASS_EXCLUSION")
        }
    }

    # --- BROAD_SCOPE_NO_PILOT ---
    if ($IncludeUsers -contains "All" -and $ExcludeGroups.Count -eq 0) {
        $Flags.Add("BROAD_SCOPE_NO_PILOT")
    }

    # --- LEGACY_AUTH_GAP ---
    $HasMfaOrBlock = ($GrantControls -contains "mfa") -or ($GrantControls -contains "block")
    $CoversLegacyAuth = ($ClientAppTypes -contains "exchangeActiveSync") -and ($ClientAppTypes -contains "other")
    if ($HasMfaOrBlock -and $ClientAppTypes.Count -gt 0 -and -not $CoversLegacyAuth -and $ClientAppTypes -notcontains "all") {
        $Flags.Add("LEGACY_AUTH_GAP")
    }

    # --- RECENTLY_ENABLED (heuristic) ---
    if ($Policy.State -eq "enabled") {
        $Created  = $Policy.CreatedDateTime
        $Modified = $Policy.ModifiedDateTime
        $MostRecent = @($Created, $Modified) | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1
        if ($MostRecent -and [datetime]$MostRecent -ge $Since) {
            $Flags.Add("RECENTLY_ENABLED")
        }
    }

    $Findings.Add([PSCustomObject]@{
        DisplayName    = $Policy.DisplayName
        PolicyId       = $Policy.Id
        State          = $Policy.State
        CreatedDateTime  = $Policy.CreatedDateTime
        ModifiedDateTime = $Policy.ModifiedDateTime
        IncludeUsers   = ($IncludeUsers -join ", ")
        ExcludeGroupCount = $ExcludeGroups.Count
        ClientAppTypes = ($ClientAppTypes -join ", ")
        GrantControls  = ($GrantControls -join ", ")
        Flags          = ($Flags -join "; ")
    })
}

# --- POTENTIAL_GRANT_CONFLICT: pairwise scope-overlap check ---
$ConflictPairs = [System.Collections.Generic.List[PSCustomObject]]::new()
$ConflictingControlSets = @(
    @("hybridAzureADJoined","compliantDevice")
)

for ($i = 0; $i -lt $ActivePolicies.Count; $i++) {
    for ($j = $i + 1; $j -lt $ActivePolicies.Count; $j++) {
        $P1 = $ActivePolicies[$i]
        $P2 = $ActivePolicies[$j]

        $P1Apps = @($P1.Conditions.Applications.IncludeApplications)
        $P2Apps = @($P2.Conditions.Applications.IncludeApplications)
        $AppsOverlap = ($P1Apps -contains "All") -or ($P2Apps -contains "All") -or (($P1Apps | Where-Object { $_ -in $P2Apps }).Count -gt 0)

        $P1Users = @($P1.Conditions.Users.IncludeUsers) + @($P1.Conditions.Users.IncludeGroups)
        $P2Users = @($P2.Conditions.Users.IncludeUsers) + @($P2.Conditions.Users.IncludeGroups)
        $UsersOverlap = ($P1Users -contains "All") -or ($P2Users -contains "All") -or (($P1Users | Where-Object { $_ -in $P2Users }).Count -gt 0)

        if (-not ($AppsOverlap -and $UsersOverlap)) { continue }

        $P1Controls = @($P1.GrantControls.BuiltInControls)
        $P2Controls = @($P2.GrantControls.BuiltInControls)

        foreach ($Pair in $ConflictingControlSets) {
            if (($P1Controls -contains $Pair[0] -and $P2Controls -contains $Pair[1]) -or
                ($P1Controls -contains $Pair[1] -and $P2Controls -contains $Pair[0])) {
                $ConflictPairs.Add([PSCustomObject]@{
                    PolicyA        = $P1.DisplayName
                    PolicyB        = $P2.DisplayName
                    ConflictingControls = "$($Pair[0]) vs $($Pair[1])"
                })
            }
        }
    }
}

if ($ConflictPairs.Count -gt 0) {
    foreach ($Row in $Findings) {
        $Matches = $ConflictPairs | Where-Object { $_.PolicyA -eq $Row.DisplayName -or $_.PolicyB -eq $Row.DisplayName }
        if ($Matches) {
            $Existing = if ($Row.Flags) { "$($Row.Flags); " } else { "" }
            $Row.Flags = "$Existing" + "POTENTIAL_GRANT_CONFLICT"
        }
    }
}

# ─── Validate / Report ────────────────────────────────────────────────────────

Write-Status "`n═══════════════════════════════════════════════" "OK"
Write-Status "CA POLICY DESIGN AUDIT SUMMARY" "OK"
Write-Status "Policies evaluated (enabled + report-only): $($ActivePolicies.Count)"

$MissingBg   = $Findings | Where-Object { $_.Flags -match "MISSING_BREAKGLASS_EXCLUSION" }
$BroadNoPilot = $Findings | Where-Object { $_.Flags -match "BROAD_SCOPE_NO_PILOT" }
$LegacyGap   = $Findings | Where-Object { $_.Flags -match "LEGACY_AUTH_GAP" }
$Recent      = $Findings | Where-Object { $_.Flags -match "RECENTLY_ENABLED" }
$Conflicts   = $Findings | Where-Object { $_.Flags -match "POTENTIAL_GRANT_CONFLICT" }

Write-Status "MISSING_BREAKGLASS_EXCLUSION : $($MissingBg.Count)" $(if ($MissingBg.Count -gt 0) { "ERROR" } else { "OK" })
Write-Status "BROAD_SCOPE_NO_PILOT         : $($BroadNoPilot.Count)" $(if ($BroadNoPilot.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "LEGACY_AUTH_GAP              : $($LegacyGap.Count)" $(if ($LegacyGap.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "RECENTLY_ENABLED (<$RecentChangeHours`h)     : $($Recent.Count)" $(if ($Recent.Count -gt 0) { "WARN" } else { "OK" })
Write-Status "POTENTIAL_GRANT_CONFLICT     : $($Conflicts.Count)" $(if ($Conflicts.Count -gt 0) { "WARN" } else { "OK" })

if ($MissingBg.Count -gt 0) {
    Write-Status "`nHighest priority — policies missing break-glass exclusion:" "ERROR"
    $MissingBg | ForEach-Object { Write-Host "  - $($_.DisplayName)" -ForegroundColor Red }
}

$Findings | Sort-Object Flags -Descending | Export-Csv -Path "$OutputPath-Policies.csv" -NoTypeInformation
if ($ConflictPairs.Count -gt 0) {
    $ConflictPairs | Export-Csv -Path "$OutputPath-GrantConflicts.csv" -NoTypeInformation
}

Write-Status "`nReports exported to: $OutputPath-*.csv" "OK"
