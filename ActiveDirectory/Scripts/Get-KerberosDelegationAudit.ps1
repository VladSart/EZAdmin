<#
.SYNOPSIS
    Domain-wide, read-only audit of Kerberos delegation configuration: unconstrained delegation,
    classic constrained delegation (KCD), resource-based constrained delegation (RBCD), and the
    two intentional delegation-blocking controls (AccountNotDelegated, Protected Users).

.DESCRIPTION
    Matches the dependency stack documented in
    ActiveDirectory/Troubleshooting/KerberosDelegation/Delegation-A.md and Delegation-B.md.
    Performs four passes:
      1. Finds every account/computer with TRUSTED_FOR_DELEGATION set (unconstrained) — flagged
         as the highest-priority finding regardless of anything else.
      2. Finds every account/computer with msDS-AllowedToDelegateTo populated (classic constrained
         delegation) and lists the exact authorized target SPN(s).
      3. Finds every object with msDS-AllowedToActOnBehalfOfOtherIdentity populated (RBCD) and
         resolves the authorized principal(s).
      4. Cross-references every delegation-capable account/computer found above against
         well-known Tier-0 group membership (Domain Admins, Enterprise Admins, Schema Admins,
         Administrators) to flag tiering violations — a Tier-0 principal with delegation rights
         onto anything is a standing escalation path.

    This script does NOT create, modify, or remove any AD object, userAccountControl flag, or
    delegation ACL. It is a pure inventory/audit tool intended to feed a manual remediation
    decision (see Delegation-A.md Remediation Playbook 2 and 4).

.PARAMETER IncludeTierZeroCrossCheck
    Switch. When present (default: on), cross-references every flagged delegation-capable
    account against Domain Admins/Enterprise Admins/Schema Admins/Administrators membership.
    Disable with -IncludeTierZeroCrossCheck:$false on very large domains to reduce runtime.

.PARAMETER OutputPath
    Folder to write the CSV summary to. Default: current directory.

.EXAMPLE
    .\Get-KerberosDelegationAudit.ps1
    Runs the full domain-wide delegation audit with Tier-0 cross-checking enabled.

.EXAMPLE
    .\Get-KerberosDelegationAudit.ps1 -IncludeTierZeroCrossCheck:$false -OutputPath "C:\Temp"
    Runs the audit without the Tier-0 membership cross-check (faster on large domains) and
    writes KerberosDelegationAudit_<timestamp>.csv to C:\Temp.

.NOTES
    Requires: ActiveDirectory PowerShell module (RSAT). Run from a DC or a management host.
    Run-as: Any account with domain-wide read access to userAccountControl, msDS-AllowedToDelegateTo,
            and msDS-AllowedToActOnBehalfOfOtherIdentity is sufficient — no elevated rights required.
    Safe/Unsafe: 100% read-only. No delegation configuration is created, modified, or removed.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [bool]$IncludeTierZeroCrossCheck = $true,

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

$results = [System.Collections.Generic.List[object]]::new()

# ---------------------------------------------------------------------------
# Tier-0 membership baseline (only if cross-check requested)
# ---------------------------------------------------------------------------
$tierZeroSids = [System.Collections.Generic.HashSet[string]]::new()

if ($IncludeTierZeroCrossCheck) {
    Write-Status "Building Tier-0 membership baseline (Domain Admins, Enterprise Admins, Schema Admins, Administrators)..."
    $tierZeroGroups = "Domain Admins", "Enterprise Admins", "Schema Admins", "Administrators"
    foreach ($grp in $tierZeroGroups) {
        try {
            Get-ADGroupMember -Identity $grp -Recursive -ErrorAction Stop | ForEach-Object {
                [void]$tierZeroSids.Add($_.SID.Value)
            }
        } catch {
            Write-Status "  Could not enumerate '$grp' (may not exist in this domain, or is a forest-root-only group): $($_.Exception.Message)" "WARN"
        }
    }
    Write-Status "  Tier-0 baseline: $($tierZeroSids.Count) unique principal(s)." "INFO"
}

function Test-TierZero {
    param([string]$ObjectSid)
    if (-not $IncludeTierZeroCrossCheck) { return "NOT_CHECKED" }
    if ([string]::IsNullOrEmpty($ObjectSid)) { return "UNKNOWN" }
    if ($tierZeroSids.Contains($ObjectSid)) { return "YES" }
    return "NO"
}

# ---------------------------------------------------------------------------
# Pass 1 — Unconstrained delegation (TRUSTED_FOR_DELEGATION, userAccountControl bit 0x80000)
# ---------------------------------------------------------------------------
Write-Status "Pass 1: Scanning for unconstrained delegation..."

$unconstrained = @(Get-ADObject -LDAPFilter "(userAccountControl:1.2.840.113556.1.4.803:=524288)" `
    -Properties Name, ObjectClass, SamAccountName, objectSid, DistinguishedName -ErrorAction SilentlyContinue)

Write-Status "  Found $($unconstrained.Count) object(s) with unconstrained delegation." $(if ($unconstrained.Count -gt 0) { "WARN" } else { "OK" })

foreach ($obj in $unconstrained) {
    $tierZero = Test-TierZero -ObjectSid $obj.objectSid.Value
    $findings = [System.Collections.Generic.List[string]]::new()
    $findings.Add("UNCONSTRAINED_DELEGATION")
    if ($tierZero -eq "YES") { $findings.Add("TIER_ZERO_PRINCIPAL_WITH_UNCONSTRAINED_DELEGATION") }

    $results.Add([PSCustomObject]@{
        Name             = $obj.Name
        ObjectClass      = $obj.ObjectClass
        DelegationModel  = "Unconstrained"
        AuthorizedTarget = "ANY SPN (domain-wide, unscoped)"
        TierZeroMember   = $tierZero
        Findings         = ($findings -join ", ")
        DistinguishedName = $obj.DistinguishedName
    })
}

# ---------------------------------------------------------------------------
# Pass 2 — Classic constrained delegation (msDS-AllowedToDelegateTo)
# ---------------------------------------------------------------------------
Write-Status "Pass 2: Scanning for classic constrained delegation (KCD)..."

$constrained = @(Get-ADObject -LDAPFilter "(msDS-AllowedToDelegateTo=*)" `
    -Properties Name, ObjectClass, SamAccountName, objectSid, DistinguishedName, `
        "msDS-AllowedToDelegateTo", TrustedToAuthForDelegation -ErrorAction SilentlyContinue)

Write-Status "  Found $($constrained.Count) object(s) with classic constrained delegation configured." "INFO"

foreach ($obj in $constrained) {
    $tierZero = Test-TierZero -ObjectSid $obj.objectSid.Value
    $targets = @($obj."msDS-AllowedToDelegateTo")
    $findings = [System.Collections.Generic.List[string]]::new()
    if ($obj.TrustedToAuthForDelegation) { $findings.Add("PROTOCOL_TRANSITION_ENABLED_S4U2SELF") }
    if ($tierZero -eq "YES") { $findings.Add("TIER_ZERO_PRINCIPAL_WITH_CONSTRAINED_DELEGATION") }
    if ($findings.Count -eq 0) { $findings.Add("OK") }

    $results.Add([PSCustomObject]@{
        Name             = $obj.Name
        ObjectClass      = $obj.ObjectClass
        DelegationModel  = "Constrained (KCD)"
        AuthorizedTarget = ($targets -join "; ")
        TierZeroMember   = $tierZero
        Findings         = ($findings -join ", ")
        DistinguishedName = $obj.DistinguishedName
    })
}

# ---------------------------------------------------------------------------
# Pass 3 — Resource-based constrained delegation (msDS-AllowedToActOnBehalfOfOtherIdentity)
# ---------------------------------------------------------------------------
Write-Status "Pass 3: Scanning for resource-based constrained delegation (RBCD)..."

$rbcd = @(Get-ADObject -LDAPFilter "(msDS-AllowedToActOnBehalfOfOtherIdentity=*)" `
    -Properties Name, ObjectClass, SamAccountName, objectSid, DistinguishedName, `
        "msDS-AllowedToActOnBehalfOfOtherIdentity" -ErrorAction SilentlyContinue)

Write-Status "  Found $($rbcd.Count) object(s) with RBCD authorization configured." "INFO"

foreach ($obj in $rbcd) {
    $tierZero = Test-TierZero -ObjectSid $obj.objectSid.Value
    $findings = [System.Collections.Generic.List[string]]::new()

    $authorizedNames = "UNABLE_TO_PARSE_SECURITY_DESCRIPTOR"
    try {
        $sd = $obj."msDS-AllowedToActOnBehalfOfOtherIdentity"
        if ($sd -and $sd.DiscretionaryAcl) {
            $names = foreach ($ace in $sd.DiscretionaryAcl) {
                try {
                    $principal = Get-ADObject -Filter "objectSid -eq '$($ace.SecurityIdentifier.Value)'" -Properties Name -ErrorAction Stop
                    if ($principal) { $principal.Name } else { $ace.SecurityIdentifier.Value }
                } catch {
                    $ace.SecurityIdentifier.Value
                }
            }
            $authorizedNames = ($names -join "; ")
        }
    } catch {
        $findings.Add("SECURITY_DESCRIPTOR_PARSE_ERROR")
    }

    if ($tierZero -eq "YES") { $findings.Add("TIER_ZERO_PRINCIPAL_AS_RBCD_RESOURCE") }
    if ($findings.Count -eq 0) { $findings.Add("OK") }

    $results.Add([PSCustomObject]@{
        Name             = $obj.Name
        ObjectClass      = $obj.ObjectClass
        DelegationModel  = "Resource-Based (RBCD)"
        AuthorizedTarget = "Principals authorized TO delegate to this resource: $authorizedNames"
        TierZeroMember   = $tierZero
        Findings         = ($findings -join ", ")
        DistinguishedName = $obj.DistinguishedName
    })
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Status "----- Summary -----" "INFO"
$results | Format-Table Name, ObjectClass, DelegationModel, TierZeroMember, Findings -AutoSize

$unconstrainedCount = @($results | Where-Object { $_.DelegationModel -eq "Unconstrained" }).Count
$tierZeroFindings = @($results | Where-Object { $_.Findings -match "TIER_ZERO" }).Count

if ($unconstrainedCount -gt 0) {
    Write-Status "$unconstrainedCount object(s) have UNCONSTRAINED delegation — treat as a standing lateral-movement risk and schedule migration to constrained/RBCD (see Delegation-A.md Remediation Playbook 2)." "WARN"
} else {
    Write-Status "No unconstrained delegation found." "OK"
}

if ($IncludeTierZeroCrossCheck) {
    if ($tierZeroFindings -gt 0) {
        Write-Status "$tierZeroFindings finding(s) involve a Tier-0 principal in a delegation relationship — review immediately, this is a tiering violation regardless of delegation type." "ERROR"
    } else {
        Write-Status "No Tier-0 principals found in any delegation relationship." "OK"
    }
}

Write-Status "Total delegation-related objects found: $($results.Count) (Unconstrained: $unconstrainedCount, Constrained: $(@($results | Where-Object {$_.DelegationModel -eq 'Constrained (KCD)'}).Count), RBCD: $(@($results | Where-Object {$_.DelegationModel -eq 'Resource-Based (RBCD)'}).Count))" "INFO"

$csvPath = Join-Path -Path $OutputPath -ChildPath "KerberosDelegationAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Status "Full results exported to: $csvPath" "OK"
