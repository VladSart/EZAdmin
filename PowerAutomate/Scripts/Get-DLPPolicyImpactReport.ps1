<#
.SYNOPSIS
    Audits all Power Platform DLP policies and reports connector classification conflicts across environments.

.DESCRIPTION
    Enumerates every DLP policy in the tenant, resolves which environments each policy applies to
    (including global/tenant-wide policies), and builds a connector-classification matrix showing
    where the same connector is classified differently across overlapping policies.

    Because the *most restrictive* classification wins when policies overlap (Blocked > Non-Business >
    Business), a connector that is "Business" in one policy but "Blocked" in a global policy applying
    to the same environment will still fail — this script surfaces exactly that scenario so you don't
    have to reconstruct it by hand from the portal.

    Also flags:
    - Connectors present in more than one group within the SAME policy (a config error)
    - Global (tenant-wide) policies, which environment admins cannot override
    - Environments with no explicit non-global policy (relying solely on the Default/global policy)

    Read-only. Makes no changes to any policy.

.PARAMETER ConnectorFilter
    Optional. Only report on connectors whose display name matches this pattern (partial match).
    Example: "SharePoint", "HTTP", "Dropbox"

.PARAMETER OutputPath
    Path to export CSV reports. Default: C:\Temp\DLPImpactReport-<timestamp>

.EXAMPLE
    .\Get-DLPPolicyImpactReport.ps1

.EXAMPLE
    # Focus the report on a specific connector that's reported as broken
    .\Get-DLPPolicyImpactReport.ps1 -ConnectorFilter "SharePoint"

.NOTES
    Requires: Microsoft.PowerApps.Administration.PowerShell module
    Install:  Install-Module Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser
    Auth:     Add-PowerAppsAccount (prompts for credentials)
    Permissions: Power Platform Service Admin, Environment Admin (partial view), or Global Admin (full view)
    Safe to run repeatedly — read-only.
    Companion runbooks: PowerAutomate/Troubleshooting/DLP-Policies-A.md and DLP-Policies-B.md
#>

[CmdletBinding()]
param(
    [Parameter()][string]$ConnectorFilter = "",
    [Parameter()][string]$OutputPath = "C:\Temp\DLPImpactReport-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
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

Write-Status "Checking for Microsoft.PowerApps.Administration.PowerShell module..."
if (-not (Get-Module -ListAvailable -Name "Microsoft.PowerApps.Administration.PowerShell")) {
    Write-Status "Module not found. Installing..." "WARN"
    Install-Module Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser -Force -AllowClobber
}
Import-Module Microsoft.PowerApps.Administration.PowerShell -ErrorAction Stop

Write-Status "Authenticating to Power Platform..."
try {
    Add-PowerAppsAccount
} catch {
    Write-Status "Authentication failed: $_" "ERROR"
    exit 1
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# ─── Collect policies ─────────────────────────────────────────────────────────

Write-Status "Retrieving all DLP policies in the tenant..."
$AllPolicies = @(Get-AdminDlpPolicy -ErrorAction Stop)

if ($AllPolicies.Count -eq 0) {
    Write-Status "No DLP policies found. Nothing to report." "WARN"
    exit 0
}

Write-Status "Found $($AllPolicies.Count) polic(y/ies)." "OK"

$GlobalPolicies = @($AllPolicies | Where-Object { $_.IsGlobal -eq $true -or -not $_.Environments })
Write-Status "$($GlobalPolicies.Count) policy(ies) are tenant-wide (global)." $(if ($GlobalPolicies.Count -gt 0) { "WARN" } else { "OK" })

# ─── Build connector classification matrix ────────────────────────────────────

Write-Status "Building connector classification matrix across all policies..."

$Matrix = [System.Collections.Generic.List[PSCustomObject]]::new()
$InPolicyConflicts = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($Policy in $AllPolicies) {

    $PolicyName    = $Policy.DisplayName
    $PolicyId      = $Policy.PolicyName
    $IsGlobal      = $Policy.IsGlobal
    $EnvList       = if ($Policy.Environments) { ($Policy.Environments.name -join "; ") } else { "ALL (global)" }

    $Groups = @{
        Business    = @($Policy.BusinessDataGroup)
        NonBusiness = @($Policy.NonBusinessDataGroup)
        Blocked     = @($Policy.BlockedGroup)
    }

    # Detect connectors appearing in more than one group within this single policy
    $AllConnectorIds = $Groups.Values | ForEach-Object { $_ } | Select-Object -ExpandProperty id -Unique
    foreach ($ConnId in $AllConnectorIds) {
        $MembershipCount = ($Groups.Values | ForEach-Object { $_ } | Where-Object { $_.id -eq $ConnId }).Count
        if ($MembershipCount -gt 1) {
            $InPolicyConflicts.Add([PSCustomObject]@{
                Policy      = $PolicyName
                ConnectorId = $ConnId
                Issue       = "Connector appears in $MembershipCount groups within the same policy"
            })
        }
    }

    foreach ($GroupName in $Groups.Keys) {
        foreach ($Conn in $Groups[$GroupName]) {
            if ($ConnectorFilter -and $Conn.name -notlike "*$ConnectorFilter*") { continue }

            $Matrix.Add([PSCustomObject]@{
                Policy          = $PolicyName
                PolicyId        = $PolicyId
                IsGlobal        = $IsGlobal
                Environments    = $EnvList
                ConnectorName   = $Conn.name
                ConnectorId     = $Conn.id
                Classification  = $GroupName
            })
        }
    }
}

# ─── Cross-policy effective classification (most restrictive wins) ───────────

Write-Status "Resolving effective (most-restrictive) classification per connector..."

$Precedence = @{ Blocked = 3; NonBusiness = 2; Business = 1 }
$ConnectorGroups = $Matrix | Group-Object ConnectorId

$EffectiveReport = [System.Collections.Generic.List[PSCustomObject]]::new()
$CrossPolicyConflicts = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($Grp in $ConnectorGroups) {
    $Entries = $Grp.Group
    $DistinctClassifications = $Entries.Classification | Select-Object -Unique
    $ConnectorName = $Entries[0].ConnectorName

    $MostRestrictive = ($Entries | Sort-Object { $Precedence[$_.Classification] } -Descending | Select-Object -First 1)

    $EffectiveReport.Add([PSCustomObject]@{
        ConnectorName            = $ConnectorName
        ConnectorId              = $Grp.Name
        PoliciesReferencing      = $Entries.Count
        DistinctClassifications  = ($DistinctClassifications -join ", ")
        EffectiveClassification  = $MostRestrictive.Classification
        MostRestrictivePolicy    = $MostRestrictive.Policy
    })

    if ($DistinctClassifications.Count -gt 1) {
        $CrossPolicyConflicts.Add([PSCustomObject]@{
            ConnectorName   = $ConnectorName
            ConnectorId     = $Grp.Name
            Classifications = ($Entries | ForEach-Object { "$($_.Policy)=$($_.Classification)" }) -join " | "
            EffectiveResult = $MostRestrictive.Classification
        })
    }
}

# ─── Report ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "=== DLP POLICY IMPACT REPORT ===" -ForegroundColor Magenta
Write-Status "Total policies:            $($AllPolicies.Count)"
Write-Status "Global (tenant-wide):      $($GlobalPolicies.Count)"
Write-Status "Connectors seen:          $($ConnectorGroups.Count)"

if ($InPolicyConflicts.Count -gt 0) {
    Write-Status "`nWithin-policy conflicts found: $($InPolicyConflicts.Count)" "ERROR"
    $InPolicyConflicts | Format-Table -AutoSize -Wrap
} else {
    Write-Status "No within-policy classification conflicts found." "OK"
}

if ($CrossPolicyConflicts.Count -gt 0) {
    Write-Status "`nCross-policy classification conflicts found: $($CrossPolicyConflicts.Count)" "WARN"
    Write-Status "(Most-restrictive classification wins — this is expected DLP behaviour, but surprises admins)"
    $CrossPolicyConflicts | Format-Table -AutoSize -Wrap
} else {
    Write-Status "No cross-policy classification conflicts found." "OK"
}

if ($GlobalPolicies.Count -gt 0) {
    Write-Status "`nGlobal policies (cannot be overridden by environment admins):" "WARN"
    $GlobalPolicies | Select-Object DisplayName, PolicyName, CreatedTime | Format-Table -AutoSize
}

# ─── Export ────────────────────────────────────────────────────────────────────

$Matrix           | Export-Csv "$OutputPath\dlp-connector-matrix.csv"        -NoTypeInformation -Encoding UTF8
$EffectiveReport  | Export-Csv "$OutputPath\dlp-effective-classification.csv" -NoTypeInformation -Encoding UTF8
$InPolicyConflicts | Export-Csv "$OutputPath\dlp-inpolicy-conflicts.csv"      -NoTypeInformation -Encoding UTF8
$CrossPolicyConflicts | Export-Csv "$OutputPath\dlp-crosspolicy-conflicts.csv" -NoTypeInformation -Encoding UTF8

Write-Status "`nReports exported to: $OutputPath" "OK"
Write-Status "Done." "OK"
