<#
.SYNOPSIS
    Read-only drift and hygiene audit for one or more "shadow groups" — ordinary AD
    security groups whose membership is expected to be kept in sync with an OU (or an
    attribute filter) by an external scheduled task or tool.

.DESCRIPTION
    Matches the dependency stack documented in
    ActiveDirectory/Troubleshooting/ShadowGroups/ShadowGroups-A.md and -B.md.

    Active Directory has no native attribute marking a group as a "shadow group" and no
    native record of its defining criteria — this script requires that mapping to be
    supplied explicitly, either via -ConfigCsv (GroupName,SourceOU columns) or a single
    -GroupName/-SourceOU pair for an ad-hoc check. This is a deliberate design choice,
    not an oversight: any automatic guess (e.g., from a naming convention) would risk
    silently auditing the wrong criteria and reporting false drift.

    For each configured group, this script:
      1. Confirms the group is Security-scoped/Global-scoped (the requirement for both
         GPO security filtering and FGPP/PSO targeting — a shadow group with the wrong
         scope will silently fail to work for one or both consumers regardless of how
         well its membership is synced).
      2. Computes the actual-vs-expected membership diff against the supplied source OU,
         flagging STALE (should be removed) and MISSING (should be added) accounts —
         the additive-only sync bug described in ShadowGroups-A.md surfaces here as a
         persistent, non-empty STALE list.
      3. Reports the group's delegated permissions (via dsacls) so the sync account's
         access can be confirmed as narrowly scoped (member-attribute write) rather than
         over-privileged, without asserting a pass/fail — that judgment call belongs to
         the reviewing admin, since "correct" delegation depends on the specific sync
         account naming in each environment.
      4. Optionally (-CheckGPOReferences / -CheckPSOReferences) cross-references whether
         the group is currently referenced by any GPO's security filtering or any PSO's
         msDS-PSOAppliesTo, to help scope the blast radius of a membership change before
         it's made — best-effort, since GPO permission enumeration requires the
         GroupPolicy module (not always present outside a DC/RSAT host with GPMC tools).

    This script does NOT modify group membership, does NOT modify any delegated
    permission, and does NOT create or remove any scheduled task. It is a pure
    inventory/audit tool — see ShadowGroups-B.md Fix 2 for the corrected reconciliation
    pattern to apply the findings this script surfaces.

.PARAMETER ConfigCsv
    Path to a CSV with GroupName,SourceOU columns for auditing multiple shadow groups
    in one run. Takes precedence over -GroupName/-SourceOU if both are supplied.

.PARAMETER GroupName
    Single group name to audit (used with -SourceOU for an ad-hoc check).

.PARAMETER SourceOU
    Distinguished Name of the OU that defines this group's expected membership
    (used with -GroupName for an ad-hoc check). Attribute-filter-based shadow groups
    are not supported by this parameter set — use -ConfigCsv with a custom filter
    column if that pattern needs auditing; this script's OU-based path covers the
    large majority of real-world shadow group implementations.

.PARAMETER OutputPath
    Folder to write the CSV report to. Default: current directory.

.PARAMETER CheckGPOReferences
    Switch. Cross-references each audited group against every GPO's security filtering
    list. Requires the GroupPolicy PowerShell module.

.PARAMETER CheckPSOReferences
    Switch. Cross-references each audited group against every PSO's msDS-PSOAppliesTo.

.EXAMPLE
    .\Get-ShadowGroupDriftAudit.ps1 -GroupName "SG-Finance" -SourceOU "OU=Finance,DC=contoso,DC=com"
    Ad-hoc drift check for a single shadow group.

.EXAMPLE
    .\Get-ShadowGroupDriftAudit.ps1 -ConfigCsv "C:\Config\ShadowGroups.csv" -CheckGPOReferences -CheckPSOReferences
    Batch audit of every documented shadow group, including downstream reference checks.

.NOTES
    Requires: ActiveDirectory PowerShell module (RSAT), dsacls.exe.
              GroupPolicy module only if -CheckGPOReferences is used.
    Run-as: Any account with domain-wide read access is sufficient — no elevated rights
            required for the audit itself.
    Safe/Unsafe: 100% read-only. No group membership, permission, GPO, or PSO is
                 created, modified, or removed.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigCsv,

    [Parameter(Mandatory = $false)]
    [string]$GroupName,

    [Parameter(Mandatory = $false)]
    [string]$SourceOU,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".",

    [Parameter(Mandatory = $false)]
    [switch]$CheckGPOReferences,

    [Parameter(Mandatory = $false)]
    [switch]$CheckPSOReferences
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

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
try {
    Import-Module ActiveDirectory -ErrorAction Stop
} catch {
    Write-Status "ActiveDirectory module not available. Install RSAT: AD DS and AD LDS Tools, or run from a DC." "ERROR"
    throw
}

if (-not (Get-Command dsacls.exe -ErrorAction SilentlyContinue)) {
    Write-Status "dsacls.exe not found on PATH — delegated-permission reporting will be skipped for all groups." "WARN"
}

if ($CheckGPOReferences -and -not (Get-Module -ListAvailable -Name GroupPolicy)) {
    Write-Status "GroupPolicy module not available — -CheckGPOReferences will be skipped." "WARN"
    $CheckGPOReferences = $false
}

# ---------------------------------------------------------------------------
# Step 1 — Build the audit target list (this script cannot discover shadow
# groups on its own; AD has no native marker for this pattern)
# ---------------------------------------------------------------------------
$targets = [System.Collections.Generic.List[object]]::new()

if ($ConfigCsv) {
    if (-not (Test-Path $ConfigCsv)) {
        Write-Status "Config CSV not found: $ConfigCsv" "ERROR"
        throw "Cannot proceed without a valid -ConfigCsv path."
    }
    Import-Csv -Path $ConfigCsv | ForEach-Object {
        $targets.Add([PSCustomObject]@{ GroupName = $_.GroupName; SourceOU = $_.SourceOU })
    }
    Write-Status "Loaded $($targets.Count) shadow group definition(s) from $ConfigCsv." "INFO"
} elseif ($GroupName -and $SourceOU) {
    $targets.Add([PSCustomObject]@{ GroupName = $GroupName; SourceOU = $SourceOU })
} else {
    Write-Status "No audit target specified. Supply -ConfigCsv, or both -GroupName and -SourceOU." "ERROR"
    throw "Missing required parameters."
}

$results = [System.Collections.Generic.List[object]]::new()

# ---------------------------------------------------------------------------
# Step 2 — Per-group audit
# ---------------------------------------------------------------------------
foreach ($target in $targets) {
    Write-Status "Auditing shadow group: $($target.GroupName) (source: $($target.SourceOU))" "INFO"

    try {
        $group = Get-ADGroup -Identity $target.GroupName -Properties GroupCategory, GroupScope, Description, whenChanged -ErrorAction Stop
    } catch {
        Write-Status "  Could not find group '$($target.GroupName)': $($_.Exception.Message)" "ERROR"
        $results.Add([PSCustomObject]@{
            GroupName = $target.GroupName; SourceOU = $target.SourceOU
            ScopeOK = "N/A"; StaleCount = "N/A"; MissingCount = "N/A"
            StaleMembers = "GROUP NOT FOUND"; MissingMembers = ""
        })
        continue
    }

    $scopeOK = ($group.GroupCategory -eq "Security" -and $group.GroupScope -eq "Global")
    if (-not $scopeOK) {
        Write-Status "  Group scope is '$($group.GroupCategory)/$($group.GroupScope)' — NOT Security/Global. This will fail PSO targeting outright and may not behave as expected for GPO security filtering." "WARN"
    }

    try {
        $actual = @(Get-ADGroupMember -Identity $target.GroupName -ErrorAction Stop | Select-Object -ExpandProperty DistinguishedName)
    } catch {
        Write-Status "  Could not enumerate current membership: $($_.Exception.Message)" "ERROR"
        $actual = @()
    }

    try {
        $expected = @(Get-ADUser -SearchBase $target.SourceOU -Filter * -ErrorAction Stop | Select-Object -ExpandProperty DistinguishedName)
    } catch {
        Write-Status "  Could not query source OU '$($target.SourceOU)': $($_.Exception.Message)" "ERROR"
        $expected = @()
    }

    $stale   = @($actual   | Where-Object { $_ -notin $expected })
    $missing = @($expected | Where-Object { $_ -notin $actual })

    if ($stale.Count -gt 0) {
        Write-Status "  $($stale.Count) STALE member(s) — present in the group but no longer in the source OU. Possible additive-only sync bug — see ShadowGroups-B.md Fix 2." "WARN"
    }
    if ($missing.Count -gt 0) {
        Write-Status "  $($missing.Count) MISSING member(s) — in the source OU but not yet in the group. Check sync job last-run time." "WARN"
    }
    if ($stale.Count -eq 0 -and $missing.Count -eq 0) {
        Write-Status "  Membership is fully in sync with the source OU." "OK"
    }

    $delegationSummary = "dsacls unavailable"
    if (Get-Command dsacls.exe -ErrorAction SilentlyContinue) {
        try {
            $aclLines = & dsacls.exe "$($group.DistinguishedName)" 2>&1
            $memberGrants = @($aclLines | Select-String -Pattern "member")
            $delegationSummary = if ($memberGrants.Count -gt 0) { ($memberGrants -join " | ") } else { "No explicit 'member'-scoped ACE found in dsacls output — review full ACL manually" }
        } catch {
            $delegationSummary = "dsacls query failed: $($_.Exception.Message)"
        }
    }

    $results.Add([PSCustomObject]@{
        GroupName        = $target.GroupName
        SourceOU         = $target.SourceOU
        ScopeOK          = $scopeOK
        GroupCategory    = $group.GroupCategory
        GroupScope       = $group.GroupScope
        StaleCount       = $stale.Count
        MissingCount     = $missing.Count
        StaleMembers     = ($stale -join "; ")
        MissingMembers   = ($missing -join "; ")
        DelegationSummary = $delegationSummary
        WhenChanged      = $group.whenChanged
    })
}

# ---------------------------------------------------------------------------
# Step 3 — Optional downstream-reference cross-checks
# ---------------------------------------------------------------------------
if ($CheckGPOReferences) {
    Write-Status "Cross-referencing audited groups against GPO security filtering (best-effort)..." "INFO"
    try {
        Import-Module GroupPolicy -ErrorAction Stop
        $allGpos = Get-GPO -All
        foreach ($target in $targets) {
            $referencingGpos = @()
            foreach ($gpo in $allGpos) {
                $perms = Get-GPPermission -Guid $gpo.Id -All -ErrorAction SilentlyContinue
                if ($perms | Where-Object { $_.Trustee.Name -eq $target.GroupName }) {
                    $referencingGpos += $gpo.DisplayName
                }
            }
            if ($referencingGpos.Count -gt 0) {
                Write-Status "  '$($target.GroupName)' is referenced by GPO(s): $($referencingGpos -join ', ') — treat membership changes as having this blast radius." "WARN"
            }
        }
    } catch {
        Write-Status "  GPO reference check failed: $($_.Exception.Message)" "WARN"
    }
}

if ($CheckPSOReferences) {
    Write-Status "Cross-referencing audited groups against PSO msDS-PSOAppliesTo (best-effort)..." "INFO"
    try {
        $psos = Get-ADObject -Filter { objectClass -eq "msDS-PasswordSettings" } -Properties msDS-PSOAppliesTo, Name -ErrorAction Stop
        foreach ($target in $targets) {
            $groupDN = (Get-ADGroup -Identity $target.GroupName -ErrorAction SilentlyContinue).DistinguishedName
            if (-not $groupDN) { continue }
            $referencingPsos = @($psos | Where-Object { $_."msDS-PSOAppliesTo" -contains $groupDN } | Select-Object -ExpandProperty Name)
            if ($referencingPsos.Count -gt 0) {
                Write-Status "  '$($target.GroupName)' is referenced by PSO(s): $($referencingPsos -join ', ') — treat membership changes as having this blast radius." "WARN"
            }
        }
    } catch {
        Write-Status "  PSO reference check failed: $($_.Exception.Message)" "WARN"
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Status "----- Summary -----" "INFO"
$results | Format-Table GroupName, ScopeOK, StaleCount, MissingCount -AutoSize

$csvPath = Join-Path -Path $OutputPath -ChildPath "ShadowGroupDriftAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Status "Full results exported to: $csvPath" "OK"
