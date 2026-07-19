<#
.SYNOPSIS
    Audits Fine-Grained Password Policies (FGPP / Password Settings Objects) for the two most
    common real-world misconfigurations: invalid OU targeting and precedence collisions.

.DESCRIPTION
    Read-only diagnostic script matching the architecture documented in
    ActiveDirectory/Troubleshooting/FineGrainedPasswordPolicies/FGPP-A.md and FGPP-B.md.
    Performs, in order:
      1. Domain functional level check (FGPP requires Windows Server 2012+)
      2. Inventories every PSO in the domain with its precedence value
      3. For each PSO, resolves msDS-PSOAppliesTo targets and flags INVALID_TARGET_TYPE for
         anything that isn't a user or a Global Security group (the #1 real-world misconfiguration
         — a PSO scripted/attribute-set against an OU silently applies to nobody)
      4. Flags PRECEDENCE_COLLISION for any two-or-more PSOs sharing the same precedence value
      5. Flags WRONG_GROUP_SCOPE for any targeted group that isn't Global Security scope
      6. Optionally, for a supplied -UserName, runs Get-ADUserResultantPasswordPolicy and reports
         whether a direct-linked PSO exists that would override any group-based expectation

    This script does NOT create, modify, or remove any PSO or group. It is a diagnostic-only
    companion to the FGPP-A/B runbooks.

.PARAMETER UserName
    Optional. A specific user's SamAccountName to check the resultant password policy for,
    including a check for a directly-linked PSO that would override group-based expectations.

.PARAMETER OutputPath
    Folder to write the CSV summary to. Default: current directory.

.EXAMPLE
    .\Get-FGPPAudit.ps1
    Audits every PSO in the domain for invalid targeting and precedence collisions.

.EXAMPLE
    .\Get-FGPPAudit.ps1 -UserName "jsmith"
    Runs the domain-wide PSO audit and additionally reports the resultant policy and any
    direct-linked PSO override for the user jsmith.

.NOTES
    Requires: ActiveDirectory PowerShell module (RSAT).
    Run-as: Any account with read access to the Password Settings Container and PSO objects
            is sufficient — no elevated rights required for this read-only audit.
    Safe/Unsafe: 100% read-only. No PSOs, groups, or user objects are created, modified, or removed.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$UserName,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "."
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

# ---------------------------------------------------------------------------
# Part 1 — Domain functional level
# ---------------------------------------------------------------------------
Write-Status "Checking domain functional level..."

$domain = Get-ADDomain
$supportedModes = @("Windows2012Domain", "Windows2012R2Domain", "Windows2016Domain")
if ($domain.DomainMode -notin $supportedModes -and $domain.DomainMode -notlike "*2012*" -and $domain.DomainMode -notlike "*2016*" -and $domain.DomainMode -notlike "*2025*") {
    Write-Status "Domain mode is '$($domain.DomainMode)'. FGPP requires Windows Server 2012 domain functional level or higher — confirm this manually if the mode name is unfamiliar (newer functional levels not in this script's known-good list)." "WARN"
} else {
    Write-Status "Domain mode: $($domain.DomainMode) — FGPP is supported." "OK"
}

# ---------------------------------------------------------------------------
# Part 2 — PSO inventory + precedence
# ---------------------------------------------------------------------------
Write-Status "Enumerating Password Settings Objects (PSOs)..."

$psoList = @(Get-ADFineGrainedPasswordPolicy -Filter * -Properties msDS-PasswordSettingsPrecedence, `
    ComplexityEnabled, MinPasswordLength, MaxPasswordAge, LockoutThreshold)

if ($psoList.Count -eq 0) {
    Write-Status "No PSOs found in this domain. Nothing further to audit." "WARN"
} else {
    Write-Status "$($psoList.Count) PSO(s) found." "OK"
}

$psoResults = [System.Collections.Generic.List[object]]::new()

foreach ($pso in $psoList) {

    $findings = [System.Collections.Generic.List[string]]::new()
    $targetDetail = [System.Collections.Generic.List[string]]::new()

    try {
        $subjects = @(Get-ADFineGrainedPasswordPolicySubject -Identity $pso.Name -ErrorAction Stop)
    } catch {
        $findings.Add("SUBJECT_LOOKUP_FAILED")
        $subjects = @()
    }

    if ($subjects.Count -eq 0) {
        $findings.Add("NO_TARGETS_APPLIED")
    }

    foreach ($subj in $subjects) {
        switch ($subj.ObjectClass) {
            "user" {
                $targetDetail.Add("User: $($subj.Name)")
            }
            "group" {
                try {
                    $grp = Get-ADGroup -Identity $subj.DistinguishedName -Properties GroupScope, GroupCategory -ErrorAction Stop
                    if ($grp.GroupScope -ne "Global" -or $grp.GroupCategory -ne "Security") {
                        $findings.Add("WRONG_GROUP_SCOPE:$($subj.Name)($($grp.GroupScope)/$($grp.GroupCategory))")
                        $targetDetail.Add("Group (INVALID SCOPE — $($grp.GroupScope)/$($grp.GroupCategory)): $($subj.Name)")
                    } else {
                        $targetDetail.Add("Group (Global Security, OK): $($subj.Name)")
                    }
                } catch {
                    $targetDetail.Add("Group (could not verify scope): $($subj.Name)")
                }
            }
            "organizationalUnit" {
                $findings.Add("INVALID_TARGET_TYPE:OU:$($subj.Name)")
                $targetDetail.Add("*** INVALID — Organizational Unit: $($subj.Name) (PSO applies to NOBODY) ***")
            }
            default {
                $findings.Add("INVALID_TARGET_TYPE:$($subj.ObjectClass):$($subj.Name)")
                $targetDetail.Add("*** UNSUPPORTED TARGET TYPE ($($subj.ObjectClass)): $($subj.Name) ***")
            }
        }
    }

    if ($findings.Count -eq 0) { $findings.Add("OK") }

    $psoResults.Add([PSCustomObject]@{
        PSOName            = $pso.Name
        Precedence         = $pso."msDS-PasswordSettingsPrecedence"
        ComplexityEnabled  = $pso.ComplexityEnabled
        MinPasswordLength  = $pso.MinPasswordLength
        LockoutThreshold   = $pso.LockoutThreshold
        TargetCount        = $subjects.Count
        TargetDetail       = ($targetDetail -join "; ")
        Findings           = ($findings -join ", ")
    })
}

# ---------------------------------------------------------------------------
# Part 3 — Precedence collision check (domain-wide, cross-PSO)
# ---------------------------------------------------------------------------
Write-Status "Checking for precedence collisions..."

$collisions = $psoResults | Group-Object Precedence | Where-Object { $_.Count -gt 1 }

if ($collisions.Count -gt 0) {
    foreach ($collision in $collisions) {
        $collidingNames = ($collision.Group | Select-Object -ExpandProperty PSOName) -join ", "
        Write-Status "PRECEDENCE COLLISION at value $($collision.Name): $collidingNames" "ERROR"
        foreach ($item in $collision.Group) {
            $existing = $psoResults | Where-Object { $_.PSOName -eq $item.PSOName }
            $existing.Findings = if ($existing.Findings -eq "OK") { "PRECEDENCE_COLLISION" } else { "$($existing.Findings), PRECEDENCE_COLLISION" }
        }
    }
} else {
    Write-Status "No precedence collisions found." "OK"
}

# ---------------------------------------------------------------------------
# Part 4 — Optional per-user resultant policy check
# ---------------------------------------------------------------------------
$userResultSummary = $null

if ($UserName) {
    Write-Status "Checking resultant password policy for user: $UserName" "INFO"
    try {
        $resultant = Get-ADUserResultantPasswordPolicy -Identity $UserName -ErrorAction Stop
        if ($resultant) {
            Write-Status "Resultant PSO for '$UserName': $($resultant.Name)" "OK"
        } else {
            Write-Status "No PSO applies to '$UserName' — falls back to the domain-wide GPO-based default policy." "WARN"
        }
    } catch {
        Write-Status "Could not resolve resultant policy for '$UserName': $($_.Exception.Message)" "ERROR"
        $resultant = $null
    }

    # Check for a direct link specifically, since it silently overrides group-based expectations
    $directLinkPSOs = $psoResults | Where-Object { $_.TargetDetail -like "*User: $UserName*" }

    $userResultSummary = [PSCustomObject]@{
        UserName          = $UserName
        ResultantPSO      = if ($resultant) { $resultant.Name } else { "NONE (domain-wide fallback applies)" }
        DirectLinkedPSOs  = if ($directLinkPSOs) { ($directLinkPSOs | Select-Object -ExpandProperty PSOName) -join ", " } else { "None" }
    }

    if ($directLinkPSOs -and $resultant -and ($directLinkPSOs.PSOName -notcontains $resultant.Name)) {
        Write-Status "NOTE: '$UserName' has a direct-linked PSO that does not match the reported resultant PSO — investigate precedence/direct-link resolution manually." "WARN"
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Status "----- PSO Summary -----" "INFO"
$psoResults | Sort-Object Precedence | Format-Table PSOName, Precedence, TargetCount, Findings -AutoSize

$flaggedCount = @($psoResults | Where-Object { $_.Findings -ne "OK" }).Count
if ($flaggedCount -gt 0) {
    Write-Status "$flaggedCount of $($psoResults.Count) PSO(s) have one or more findings. Review the Findings/TargetDetail columns." "WARN"
} else {
    Write-Status "All $($psoResults.Count) PSO(s) audited cleanly." "OK"
}

if ($userResultSummary) {
    Write-Status "----- User Resultant Policy -----" "INFO"
    $userResultSummary | Format-List
}

$csvPath = Join-Path -Path $OutputPath -ChildPath "FGPPAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$psoResults | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Status "Full PSO results exported to: $csvPath" "OK"
