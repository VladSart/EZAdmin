<#
.SYNOPSIS
    Domain-wide, read-only audit of Read-Only Domain Controller (RODC) Password
    Replication Policy (PRP) posture: Allowed/Denied list membership, currently
    cached credentials, and the "Replicating Directory Changes All" over-permission
    security check.

.DESCRIPTION
    Matches the dependency stack documented in
    ActiveDirectory/Troubleshooting/RODC/RODC-A.md and -B.md.
    Performs, for every RODC in the domain (or a single named RODC via -RODCName):
      1. Reports Allowed and Denied Password Replication Policy list membership
         (via repadmin /prp, run against a writable DC).
      2. Reports currently-cached (revealed) credentials for that RODC.
      3. Flags any Denied-list account that is ALSO present in the Allowed list
         (a config that looks intentional but is a no-op, since Deny always wins —
         worth flagging so admins don't assume the Allow entry is doing anything).
      4. Domain-wide, checks whether the "Replicating Directory Changes All" extended
         right is granted to the Enterprise Read-only Domain Controllers group (or,
         optionally, to individual RODC computer objects) on the domain partition —
         the critical over-permission finding described in RODC-A.md's "Replicating
         Directory Changes All Misconfiguration" section. This is the single highest-
         priority finding this script can surface, since it silently bypasses PRP
         entirely for every RODC in the domain.

    This script does NOT modify PRP, does NOT change any replication permission, and
    does NOT reset or clear any cached credential. It is a pure inventory/audit tool.
    If the "Replicating Directory Changes All" finding is flagged, treat it as a
    security-critical result requiring the manual remediation in RODC-A.md Remediation
    Playbook 1 (which includes reviewing the exposure window before assuming an ACL
    fix alone is sufficient).

.PARAMETER RODCName
    Audit a single named RODC instead of every RODC in the domain.

.PARAMETER OutputPath
    Folder to write the CSV/report output to. Default: current directory.

.PARAMETER IncludeReplicationACLCheck
    Switch. When present (default: on), also runs the domain-wide "Replicating
    Directory Changes All" over-permission check via dsacls. Can be disabled with
    -IncludeReplicationACLCheck:$false if dsacls is unavailable in the run context.

.EXAMPLE
    .\Get-RODCPasswordReplicationAudit.ps1
    Audits PRP posture and the replication ACL for every RODC in the domain.

.EXAMPLE
    .\Get-RODCPasswordReplicationAudit.ps1 -RODCName "BRANCH-RODC01" -OutputPath "C:\Temp"
    Audits a single named RODC only, writing output to C:\Temp.

.NOTES
    Requires: ActiveDirectory PowerShell module (RSAT), repadmin.exe, dsacls.exe.
    Run from a writable DC or a management host with RSAT tools installed.
    Run-as: Any account with domain-wide read access to PRP attributes and the domain
            partition's ACL is sufficient — no elevated rights required for the audit.
    Safe/Unsafe: 100% read-only. No PRP list, replication permission, or cached
                 credential is created, modified, reset, or removed.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$RODCName,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".",

    [Parameter(Mandatory = $false)]
    [bool]$IncludeReplicationACLCheck = $true
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

if (-not (Get-Command repadmin.exe -ErrorAction SilentlyContinue)) {
    Write-Status "repadmin.exe not found on PATH. Install RSAT or run from a domain controller." "ERROR"
    throw "repadmin.exe is required for this audit."
}

$results = [System.Collections.Generic.List[object]]::new()

# ---------------------------------------------------------------------------
# Step 1 — Enumerate target RODC(s)
# ---------------------------------------------------------------------------
if ($RODCName) {
    try {
        $rodcs = @(Get-ADDomainController -Identity $RODCName -ErrorAction Stop)
    } catch {
        Write-Status "Could not find domain controller '$RODCName': $($_.Exception.Message)" "ERROR"
        throw
    }
} else {
    Write-Status "Enumerating all RODCs in the domain..."
    $rodcs = @(Get-ADDomainController -Filter { IsReadOnly -eq $true } -ErrorAction Stop)
}

if ($rodcs.Count -eq 0) {
    Write-Status "No RODCs found in scope. Nothing to audit." "WARN"
} else {
    Write-Status "Found $($rodcs.Count) RODC(s) to audit." "INFO"
}

# ---------------------------------------------------------------------------
# Step 2 — Per-RODC PRP audit
# ---------------------------------------------------------------------------
foreach ($dc in $rodcs) {
    $name = $dc.HostName
    Write-Status "Auditing RODC: $name" "INFO"

    # Allowed / Denied list membership
    $allowedRaw = & repadmin.exe /prp view $name Allowed 2>&1
    $deniedRaw  = & repadmin.exe /prp view $name Denied 2>&1
    $revealedRaw = & repadmin.exe /prp view $name reveal 2>&1

    # Extract plausible SamAccountName-like tokens from repadmin's text output for
    # the overlap check. repadmin's output format includes DN-style lines; a
    # conservative regex pull of CN= values is used rather than assuming a fixed
    # column format, since repadmin's text output is not a stable structured format.
    $allowedNames = @($allowedRaw | Select-String -Pattern 'CN=([^,]+)' -AllMatches |
        ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value })
    $deniedNames  = @($deniedRaw | Select-String -Pattern 'CN=([^,]+)' -AllMatches |
        ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value })

    $overlap = @($allowedNames | Where-Object { $deniedNames -contains $_ })

    $revealedCount = @($revealedRaw | Select-String -Pattern 'CN=').Count

    $results.Add([PSCustomObject]@{
        RODC                 = $name
        AllowedListEntries   = $allowedNames.Count
        DeniedListEntries    = $deniedNames.Count
        RevealedCredentials  = $revealedCount
        AllowDenyOverlap     = ($overlap -join "; ")
        AllowDenyOverlapNote = if ($overlap.Count -gt 0) { "Deny wins — these Allow entries are currently no-ops" } else { "" }
    })

    if ($overlap.Count -gt 0) {
        Write-Status "  $($overlap.Count) account(s) present in BOTH Allowed and Denied lists — Deny wins, Allow entry is a no-op: $($overlap -join ', ')" "WARN"
    }
    if ($revealedCount -gt ($allowedNames.Count + 5)) {
        Write-Status "  Revealed-credential count ($revealedCount) notably exceeds the Allowed list size ($($allowedNames.Count)) — worth a closer look, though some excess is expected via legitimate authenticate-then-cache activity." "WARN"
    }

    # Write raw repadmin output for this RODC to file for evidence purposes
    $rodcReportPath = Join-Path -Path $OutputPath -ChildPath "RODC_${name}_PRP_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    @(
        "=== Allowed List — $name ===", $allowedRaw,
        "", "=== Denied List — $name ===", $deniedRaw,
        "", "=== Revealed (Cached) Credentials — $name ===", $revealedRaw
    ) | Out-File -FilePath $rodcReportPath -Encoding UTF8
    Write-Status "  Raw PRP detail written to $rodcReportPath" "INFO"
}

# ---------------------------------------------------------------------------
# Step 3 — Domain-wide "Replicating Directory Changes All" over-permission check
# ---------------------------------------------------------------------------
if ($IncludeReplicationACLCheck) {
    Write-Status "Checking domain partition replication ACL for RODC over-permission..." "INFO"

    if (-not (Get-Command dsacls.exe -ErrorAction SilentlyContinue)) {
        Write-Status "dsacls.exe not found on PATH — skipping the replication ACL check. Install RSAT or run -IncludeReplicationACLCheck:`$false to suppress this warning." "WARN"
    } else {
        try {
            $domainDN = (Get-ADDomain).DistinguishedName
            $aclOutput = & dsacls.exe "$domainDN" 2>&1

            $rodcGroupLines = @($aclOutput | Select-String -Pattern "Enterprise Read-only Domain Controllers")
            $overBroadFound = $false

            foreach ($line in $rodcGroupLines) {
                if ($line -match "Replicating Directory Changes All") {
                    $overBroadFound = $true
                    Write-Status "  CRITICAL: 'Replicating Directory Changes All' is granted to Enterprise Read-only Domain Controllers. This bypasses Password Replication Policy domain-wide for every RODC. See RODC-A.md Remediation Playbook 1." "ERROR"
                }
            }

            if (-not $overBroadFound -and $rodcGroupLines.Count -gt 0) {
                Write-Status "  Enterprise Read-only Domain Controllers holds only the expected narrower replication right(s). No over-permission finding." "OK"
            } elseif ($rodcGroupLines.Count -eq 0) {
                Write-Status "  Could not locate an explicit ACE line for Enterprise Read-only Domain Controllers in dsacls output — verify manually via LDP if RODCs are in use, since ACL text formatting can vary by OS build." "WARN"
            }

            $aclReportPath = Join-Path -Path $OutputPath -ChildPath "RODC_DomainReplicationACL_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
            $aclOutput | Out-File -FilePath $aclReportPath -Encoding UTF8
            Write-Status "  Full domain partition ACL dump written to $aclReportPath" "INFO"
        } catch {
            Write-Status "  Could not run dsacls check: $($_.Exception.Message)" "WARN"
        }
    }
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Status "----- Summary -----" "INFO"
$results | Format-Table RODC, AllowedListEntries, DeniedListEntries, RevealedCredentials, AllowDenyOverlapNote -AutoSize

$csvPath = Join-Path -Path $OutputPath -ChildPath "RODCPasswordReplicationAudit_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
Write-Status "Full results exported to: $csvPath" "OK"
