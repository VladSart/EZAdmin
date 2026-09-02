<#
.SYNOPSIS
    Audits Microsoft Purview role group membership and flags assignments that may need expiration review.

.DESCRIPTION
    Companion script to Security/Purview/TimeBoxedRoleGroups-A.md and -B.md.

    Microsoft Purview's native role-group assignment expiration (1 day - 2 years, rolled out
    July-August 2026) has NO dedicated PowerShell or Graph cmdlet surface as of this writing —
    expiration dates are set and viewed only in the Purview compliance portal
    (Settings > Roles and scopes > Role groups > <group> > Members > Expires on column).

    This script therefore does NOT and cannot report actual expiration dates. Instead it audits the
    adjacent signals this repo's runbooks depend on for troubleshooting and governance:
      - Full role group + member inventory (direct assignments)
      - Flags role groups that do NOT support expiration (eDiscovery Manager / eDiscovery Administrator)
      - Flags members that are security groups (relevant to the commercial-cloud-only limitation on
        group-based assignment/expiration)
      - Best-effort detection of a member appearing in MORE THAN ONE role group, which is relevant
        context (though not itself an "overlap" within a single role group)
      - A reminder block in the CSV/report output pointing at the manual portal step required to see
        actual expiration state

    Requires: Security & Compliance PowerShell (Connect-IPPSSession) with Role Management read rights.

.PARAMETER ExportPath
    Path to export the CSV report. Defaults to the current user's temp folder.

.PARAMETER AdminUPN
    UPN to use for Connect-IPPSSession. If omitted, assumes an existing IPPS session is present.

.EXAMPLE
    .\Get-TimeBoxedRoleGroupAudit.ps1 -AdminUPN admin@contoso.com

    Connects, audits all role groups and their members, and exports a CSV inventory.

.NOTES
    Read-only. Makes no configuration changes. Does not and cannot read expiration dates — see
    .DESCRIPTION. Requires the ExchangeOnlineManagement module (Connect-IPPSSession) and, for the
    Entra overlap check, the Microsoft.Graph.Users module.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$AdminUPN,

    [Parameter(Mandatory = $false)]
    [string]$ExportPath = (Join-Path $env:TEMP "PurviewRoleGroupAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$expirationExcludedRoleGroups = @("eDiscovery Manager", "eDiscovery Administrator")

# --- Preflight ---
try {
    Get-RoleGroup -ErrorAction Stop | Out-Null
    Write-Status "Existing Security & Compliance PowerShell session detected." "OK"
} catch {
    if ([string]::IsNullOrWhiteSpace($AdminUPN)) {
        Write-Status "No active IPPS session and no -AdminUPN supplied. Connecting interactively..." "WARN"
        Connect-IPPSSession
    } else {
        Write-Status "Connecting to Security & Compliance PowerShell as $AdminUPN..." "INFO"
        Connect-IPPSSession -UserPrincipalName $AdminUPN
    }
}

# --- Detect ---
Write-Status "Enumerating all Purview role groups..." "INFO"
$allRoleGroups = Get-RoleGroup | Select-Object -ExpandProperty Name

if (-not $allRoleGroups) {
    Write-Status "No role groups returned. Check permissions (Role Management / Organization Management)." "ERROR"
    return
}

Write-Status "Found $($allRoleGroups.Count) role groups. Enumerating members..." "INFO"

# --- Execute ---
$memberMap = @{}   # memberName -> list of role groups they belong to
$report = foreach ($rg in $allRoleGroups) {
    $expirationSupported = -not ($expirationExcludedRoleGroups -contains $rg)
    $members = Get-RoleGroupMember -Identity $rg -ErrorAction SilentlyContinue

    if (-not $members) {
        [pscustomobject]@{
            RoleGroup            = $rg
            ExpirationSupported  = $expirationSupported
            MemberName           = "(no members)"
            MemberRecipientType  = $null
            IsSecurityGroup      = $false
            AppearsInMultipleRGs = $false
        }
        continue
    }

    foreach ($m in $members) {
        if (-not $memberMap.ContainsKey($m.Name)) { $memberMap[$m.Name] = New-Object System.Collections.Generic.List[string] }
        $memberMap[$m.Name].Add($rg)

        [pscustomobject]@{
            RoleGroup            = $rg
            ExpirationSupported  = $expirationSupported
            MemberName           = $m.Name
            MemberRecipientType  = $m.RecipientType
            IsSecurityGroup      = ($m.RecipientType -match "SecurityGroup")
            AppearsInMultipleRGs = $false   # backfilled below
        }
    }
}

# Backfill multi-role-group flag now that memberMap is complete
foreach ($row in $report) {
    if ($memberMap.ContainsKey($row.MemberName) -and $memberMap[$row.MemberName].Count -gt 1) {
        $row.AppearsInMultipleRGs = $true
    }
}

# --- Validate / Report ---
$securityGroupAssignments = $report | Where-Object { $_.IsSecurityGroup }
$excludedRoleGroupRows    = $report | Where-Object { -not $_.ExpirationSupported }
$multiRoleGroupMembers    = $report | Where-Object { $_.AppearsInMultipleRGs } | Select-Object -ExpandProperty MemberName -Unique

Write-Status "Total role group / member rows: $($report.Count)" "INFO"
Write-Status "Security-group-based assignments (commercial-cloud-only expiration limitation applies): $($securityGroupAssignments.Count)" "INFO"
Write-Status "Members holding the same role group's-worth of access via MULTIPLE role groups: $($multiRoleGroupMembers.Count)" "INFO"
if ($excludedRoleGroupRows) {
    Write-Status "Role groups WITHOUT expiration support present in this tenant: $((($excludedRoleGroupRows.RoleGroup) | Select-Object -Unique) -join ', ')" "WARN"
}

$report | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Report exported to $ExportPath" "OK"
Write-Status "REMINDER: This script cannot read actual expiration dates (no cmdlet surface exists)." "WARN"
Write-Status "For per-member expiration state, check: Purview portal > Settings > Roles and scopes > Role groups > <group> > Members > 'Expires on' column." "WARN"

$report | Format-Table RoleGroup, ExpirationSupported, MemberName, IsSecurityGroup, AppearsInMultipleRGs -AutoSize
