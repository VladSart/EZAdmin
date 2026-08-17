<#
.SYNOPSIS
    Domain-wide, read-only audit of AdminSDHolder/SDProp state: current protected-group
    membership, every object flagged adminCount=1, and orphaned/stale protection where
    adminCount=1 but the object is no longer in any current protected group.

.DESCRIPTION
    Matches the dependency stack documented in
    ActiveDirectory/Troubleshooting/AdminSDHolder/AdminSDHolder-A.md and -B.md.
    Performs three passes:
      1. Builds the ground-truth set of currently protected principals by transitively
         expanding membership of every protected group (Domain Admins, Enterprise Admins,
         Administrators, Schema Admins, Account/Backup/Print/Server Operators, Replicator,
         Krbtgt-holding Domain Controllers group, Read-only Domain Controllers, Enterprise/Key
         Admins).
      2. Finds every object domain-wide with adminCount=1 via an LDAP filter.
      3. Cross-references the two sets: any adminCount=1 object NOT in the current protected
         set is flagged as ORPHANED — a well-known AD hygiene finding (also surfaced by tools
         like PingCastle, Purple Knight, and BloodHound) where the account/group was once
         privileged but adminCount and disabled inheritance were never cleared after removal,
         by original design (see AdminSDHolder-A.md "Why adminCount Is Never Automatically
         Cleared").

    This script does NOT modify, clear, or reset adminCount, inheritance, or any ACL. It is a
    pure inventory/audit tool intended to feed the manual review-then-remediate process in
    AdminSDHolder-A.md Remediation Playbook 1 — orphaned findings should always be reviewed
    before clearing, not mechanically auto-fixed.

.PARAMETER OutputPath
    Folder to write the CSV summary to. Default: current directory.

.PARAMETER IncludeTemplateACL
    Switch. When present, also reports the AdminSDHolder template object's own current ACL
    to a separate text file, for reference when investigating unexpected permissions on
    protected objects.

.EXAMPLE
    .\Get-AdminSDHolderAudit.ps1
    Runs the full domain-wide adminCount/protected-membership cross-reference audit.

.EXAMPLE
    .\Get-AdminSDHolderAudit.ps1 -IncludeTemplateACL -OutputPath "C:\Temp"
    Runs the audit and also dumps the AdminSDHolder template's current ACL, writing
    AdminSDHolderAudit_<timestamp>.csv and AdminSDHolderTemplateACL_<timestamp>.txt to C:\Temp.

.NOTES
    Requires: ActiveDirectory PowerShell module (RSAT). Run from a DC or a management host.
    Run-as: Any account with domain-wide read access to adminCount, group membership, and
            nTSecurityDescriptor is sufficient — no elevated rights required for the audit itself.
    Safe/Unsafe: 100% read-only. No adminCount, inheritance, or ACL is created, modified, or removed.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".",

    [Parameter(Mandatory = $false)]
    [switch]$IncludeTemplateACL
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
# Step 1 — PDC Emulator (informational — SDProp evaluates only here)
# ---------------------------------------------------------------------------
try {
    $pdce = (Get-ADDomain).PDCEmulator
    Write-Status "PDC Emulator: $pdce (SDProp runs only here, every 60 min by default)."
    $pdceReachable = Test-Connection -ComputerName $pdce -Count 1 -Quiet -ErrorAction SilentlyContinue
    if (-not $pdceReachable) {
        Write-Status "PDC Emulator did not respond to a connectivity test — SDProp convergence may be stalled." "WARN"
    }
} catch {
    Write-Status "Could not determine PDC Emulator: $($_.Exception.Message)" "WARN"
    $pdce = "UNKNOWN"
}

# ---------------------------------------------------------------------------
# Step 2 — Build ground-truth current protected-principal set (transitive)
# ---------------------------------------------------------------------------
Write-Status "Building current protected-group membership baseline (transitive)..."

$protectedGroups = @(
    "Account Operators", "Administrators", "Backup Operators", "Domain Admins",
    "Domain Controllers", "Enterprise Admins", "Enterprise Key Admins", "Key Admins",
    "Print Operators", "Read-only Domain Controllers", "Replicator",
    "Schema Admins", "Server Operators"
)

$protectedSids = [System.Collections.Generic.HashSet[string]]::new()
$groupCoverage = [System.Collections.Generic.List[object]]::new()

foreach ($grp in $protectedGroups) {
    try {
        $members = @(Get-ADGroupMember -Identity $grp -Recursive -ErrorAction Stop)
        foreach ($m in $members) { [void]$protectedSids.Add($m.SID.Value) }
        $groupCoverage.Add([PSCustomObject]@{ Group = $grp; MemberCount = $members.Count; Status = "OK" })
    } catch {
        $groupCoverage.Add([PSCustomObject]@{ Group = $grp; MemberCount = 0; Status = "NOT_FOUND_OR_UNREADABLE" })
        Write-Status "  Could not enumerate '$grp': $($_.Exception.Message)" "WARN"
    }
}

# Krbtgt is a protected account (not a group) — check it directly
try {
    $krbtgt = Get-ADUser -Identity "krbtgt" -ErrorAction Stop
    [void]$protectedSids.Add($krbtgt.SID.Value)
} catch {
    Write-Status "  Could not resolve krbtgt account directly: $($_.Exception.Message)" "WARN"
}

Write-Status "  Protected-principal baseline: $($protectedSids.Count) unique SID(s) across $($protectedGroups.Count) groups + krbtgt." "INFO"

# ---------------------------------------------------------------------------
# Step 3 — Find every adminCount=1 object domain-wide
# ---------------------------------------------------------------------------
Write-Status "Scanning domain for all adminCount=1 objects..."

$flagged = @(Get-ADObject -LDAPFilter "(adminCount=1)" `
    -Properties Name, ObjectClass, SamAccountName, objectSid, whenChanged, DistinguishedName `
    -ErrorAction SilentlyContinue)

Write-Status "  Found $($flagged.Count) object(s) with adminCount=1." "INFO"

# ---------------------------------------------------------------------------
# Step 4 — Cross-reference: flag orphaned (stale) protection
# ---------------------------------------------------------------------------
Write-Status "Cross-referencing against current protected-group membership..."

foreach ($obj in $flagged) {
    $sidValue = if ($obj.objectSid) { $obj.objectSid.Value } else { $null }
    $isCurrentlyProtected = ($sidValue -and $protectedSids.Contains($sidValue))

    $inheritanceDisabled = "UNKNOWN"
    try {
        $acl = Get-Acl -Path "AD:\$($obj.DistinguishedName)" -ErrorAction Stop
        $inheritanceDisabled = $acl.AreAccessRulesProtected
    } catch {
        # Non-fatal — some object classes / permission levels may not expose this cleanly
    }

    $findings = [System.Collections.Generic.List[string]]::new()
    if ($isCurrentlyProtected) {
        $findings.Add("CURRENTLY_PROTECTED")
    } else {
        $findings.Add("ORPHANED_STALE_ADMINCOUNT")
    }
    if ($inheritanceDisabled -eq $true -and -not $isCurrentlyProtected) {
        $findings.Add("INHERITANCE_STILL_DISABLED_DESPITE_NO_LONGER_PROTECTED")
    }

    $results.Add([PSCustomObject]@{
        Name                  = $obj.Name
        ObjectClass           = $obj.ObjectClass
        SamAccountName        = $obj.SamAccountName
        CurrentlyProtected    = $isCurrentlyProtected
        InheritanceDisabled   = $inheritanceDisabled
        WhenChanged           = $obj.whenChanged
        Findings              = ($findings -join ", ")
        DistinguishedName     = $obj.DistinguishedName
    })
}

# ---------------------------------------------------------------------------
# Optional — AdminSDHolder template ACL dump
# ---------------------------------------------------------------------------
if ($IncludeTemplateACL) {
    try {
        $domainDN = (Get-ADDomain).DistinguishedName
        $templateAclPath = Join-Path -Path $OutputPath -ChildPath "AdminSDHolderTemplateACL_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
        Write-Status "Dumping AdminSDHolder template ACL to $templateAclPath..."
        Get-Acl -Path "AD:\CN=AdminSDHolder,CN=System,$domainDN" |
          Select-Object -ExpandProperty Access |
          Format-Table -AutoSize | Out-File -FilePath $templateAclPath
        Write-Status "  Template ACL written." "OK"
    } catch {
        Write-Status "Could not read AdminSDHolder template ACL: $($_.Exception.Message)" "WARN"
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Status "----- Group Coverage -----" "INFO"
$groupCoverage | Format-Table -AutoSize

Write-Status "----- Summary -----" "INFO"
$results | Format-Table Name, ObjectClass, CurrentlyProtected, InheritanceDisabled, Findings -AutoSize

$orphanedCount = @($results | Where-Object { $_.Findings -match "ORPHANED_STALE_ADMINCOUNT" }).Count
$currentCount  = @($results | Where-Object { $_.CurrentlyProtected -eq $true }).Count

if ($orphanedCount -gt 0) {
    Write-Status "$orphanedCount object(s) have STALE adminCount=1 with no current protected-group membership — review each before clearing (see AdminSDHolder-A.md Remediation Playbook 1)." "WARN"
} else {
    Write-Status "No orphaned adminCount=1 objects found." "OK"
}

Write-Status "Total adminCount=1 objects: $($results.Count) (Currently protected: $currentCount, Orphaned/stale: $orphanedCount)" "INFO"

$csvPath = Join-Path -Path $OutputPath -ChildPath "AdminSDHolderAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Status "Full results exported to: $csvPath" "OK"
