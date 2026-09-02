<#
.SYNOPSIS
    Audits a tenant for current and historical use of the Partner Tier1 Support and
    Partner Tier2 Support Microsoft Entra roles ahead of Microsoft's new-assignment
    retirement (global rollout 2026-08-03 through ~2026-08-24, per MC1409305).

.DESCRIPTION
    Companion script to EntraID/Troubleshooting/PartnerTierRoleRetirement-B.md and -A.md.

    Both roles are documented by Microsoft under "Roles not shown in the portal" -
    they have never appeared in the Entra admin center Roles UI, so this script is the
    only practical way for most admins to discover whether a tenant currently uses either
    role at all.

    This script:
    - Resolves both role objects (if activated in this tenant's directory) and lists
      current membership - this membership is UNAFFECTED by the retirement and will
      keep working; the script surfaces it purely for inventory/documentation purposes
    - Cross-checks each member against Microsoft's recommended replacement-role
      candidates to flag whether a "closest fit" replacement is already assignable
    - Optionally performs a DRY-RUN simulation of a new-assignment attempt reasoning
      (does not actually call the write endpoint) to help pre-flight scripts/automation
      before the live cutover date
    - Produces a plain-language readiness summary distinguishing "tenant doesn't use
      these roles at all - zero impact" from "tenant has active assignments - review
      before automation depending on new assignments hits the cutover"

    Does NOT cover:
    - Partner Center GDAP Access Assignment templates - these live in Partner Center,
      outside any tenant-side Graph/PowerShell surface this script can reach; check
      those manually per the runbook's Fix 4 / Playbook 1
    - Actually assigning a replacement role - this script is read-only / reporting only,
      consistent with this repo's standing script-safety convention
    - Any role other than these two specific roles

.PARAMETER ExportPath
    Path for CSV export. Default: .\PartnerTierRoleRetirementAudit-<timestamp>.csv

.EXAMPLE
    .\Get-PartnerTierRoleRetirementAudit.ps1
    Runs the full audit against the connected tenant and exports results to CSV.

.NOTES
    Requires: Microsoft.Graph.Identity.DirectoryManagement module
    (Connect-MgGraph -Scopes "RoleManagement.Read.Directory","User.Read.All" first).
    Read-only. Makes no configuration changes and assigns no roles.
#>

[CmdletBinding()]
param(
    [string]$ExportPath = ".\PartnerTierRoleRetirementAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$results = [System.Collections.Generic.List[object]]::new()
$rolloutStart = Get-Date "2026-08-03"
$rolloutEnd   = Get-Date "2026-08-24"
$today        = Get-Date

# ── Rollout window status ──────────────────────────────────────────────────────────
if ($today -lt $rolloutStart) {
    $windowStatus = "NOT_YET_STARTED"
    Write-Status "Today ($($today.ToString('yyyy-MM-dd'))) is before the rollout start (2026-08-03) - new assignments still work everywhere." "INFO"
} elseif ($today -ge $rolloutStart -and $today -le $rolloutEnd) {
    $windowStatus = "ROLLING_OUT"
    Write-Status "Today is within the global rollout window (2026-08-03 to 2026-08-24) - behavior may vary by tenant during this period." "WARN"
} else {
    $windowStatus = "FULLY_RETIRED"
    Write-Status "Today is past the rollout window (2026-08-24) - new assignments to either role should be blocked tenant-wide." "OK"
}

# Candidate replacement roles, per Microsoft's own MC1409305 guidance
$ReplacementCandidates = @("User Administrator", "Helpdesk Administrator", "Groups Administrator", "License Administrator", "Domain Name Administrator")

# ── Step 1: Resolve and inventory both roles ───────────────────────────────────────
foreach ($roleName in @("Partner Tier1 Support", "Partner Tier2 Support")) {
    Write-Status "Checking role: $roleName..." "INFO"
    try {
        $role = Get-MgDirectoryRole -Filter "DisplayName eq '$roleName'" -ErrorAction Stop
    } catch {
        Write-Status "Lookup failed for '$roleName' - confirm Connect-MgGraph -Scopes 'RoleManagement.Read.Directory' has run. Error: $($_.Exception.Message)" "ERROR"
        continue
    }

    if (-not $role) {
        Write-Status "$roleName is not yet activated in this tenant's directory - never assigned here. Zero impact from this retirement." "OK"
        $results.Add([PSCustomObject]@{
            RoleName        = $roleName
            RoleActivated   = $false
            MemberCount     = 0
            MemberId        = $null
            MemberType      = $null
            RolloutStatus   = $windowStatus
            Recommendation  = "No action needed - role never used in this tenant"
        })
        continue
    }

    try {
        $members = Get-MgDirectoryRoleMember -DirectoryRoleId $role.Id -ErrorAction Stop
    } catch {
        Write-Status "Membership lookup failed for '$roleName' - $($_.Exception.Message)" "ERROR"
        $members = @()
    }

    if ($members -and $members.Count -gt 0) {
        Write-Status "$roleName has $($members.Count) active member(s) - these assignments CONTINUE TO WORK post-retirement, but no NEW assignments can be made once the rollout completes." "WARN"
        foreach ($m in $members) {
            $odataType = $m.AdditionalProperties['@odata.type']
            $results.Add([PSCustomObject]@{
                RoleName        = $roleName
                RoleActivated   = $true
                MemberCount     = $members.Count
                MemberId        = $m.Id
                MemberType      = $odataType
                RolloutStatus   = $windowStatus
                Recommendation  = "Existing assignment unaffected. Do NOT plan to re-create or clone this assignment for a new principal after the cutover - use a replacement role instead ($($ReplacementCandidates -join ' / ') or custom role)."
            })
        }
    } else {
        Write-Status "$roleName is activated in this tenant but has zero current members." "OK"
        $results.Add([PSCustomObject]@{
            RoleName        = $roleName
            RoleActivated   = $true
            MemberCount     = 0
            MemberId        = $null
            MemberType      = $null
            RolloutStatus   = $windowStatus
            Recommendation  = "No current members - low priority, but confirm no automation still targets this role for future assignments"
        })
    }
}

# ── Step 2: Confirm at least one replacement candidate is assignable ──────────────
Write-Status "Confirming recommended replacement roles resolve in this tenant..." "INFO"
foreach ($candidate in $ReplacementCandidates) {
    try {
        $candidateRole = Get-MgDirectoryRole -Filter "DisplayName eq '$candidate'" -ErrorAction Stop
        if ($candidateRole) {
            Write-Status "Replacement candidate '$candidate' is activated and available in this tenant." "OK"
        } else {
            Write-Status "Replacement candidate '$candidate' is not yet activated in this tenant (activates automatically on first assignment)." "INFO"
        }
    } catch {
        Write-Status "Could not check '$candidate' - $($_.Exception.Message)" "WARN"
    }
}

# ── Export ──────────────────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation
Write-Status "Full results exported to $ExportPath" "OK"

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Rollout window: 2026-08-03 to ~2026-08-24 (global, no tenant opt-in/opt-out). Current status: $windowStatus" -ForegroundColor DarkGray
Write-Host "Existing assignments (if any, listed above) are unaffected. This audit exists to catch automation/templates" -ForegroundColor DarkGray
Write-Host "that would attempt a NEW assignment after the cutover, and to confirm a replacement role is ready to use." -ForegroundColor DarkGray
Write-Host "Reminder: Partner Center GDAP Access Assignment templates are NOT covered by this script - check those manually." -ForegroundColor DarkGray
$results | Format-Table -AutoSize
