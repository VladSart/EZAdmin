<#
.SYNOPSIS
    Read-only RBAC and environmental-prerequisite audit for Microsoft Security
    Exposure Management (MSEM) access troubleshooting.

.DESCRIPTION
    MSEM supports two independent, simultaneously-valid RBAC models (Defender
    unified RBAC custom roles, and ten legacy Microsoft Entra ID roles), plus a
    set of environmental prerequisites (Defender for Cloud CSPM, Defender
    Vulnerability Management, Defender for Endpoint sensor version for critical
    asset classification). This script audits only the pieces reachable via
    Microsoft Graph and Az:

      1. For each specified user, legacy Entra ID role membership against the
         10 qualifying roles (Global Admin, Security Admin, Security Operator,
         Global Reader, Security Reader, Service Support Administrator, User
         Administrator, Helpdesk Administrator, Exchange Administrator,
         SharePoint Administrator), with the effective permission tier flagged
         per Microsoft's documented action matrix.
      2. Tenant licensing check (E5 / qualifying add-on / Defender suite SKU
         presence) — best-effort SKU name matching, since exact SKU part
         numbers vary by agreement type and are not hardcoded here.
      3. Defender for Cloud CSPM plan status per subscription (Az.Security).
      4. Optional: Defender for Endpoint sensor version check for a supplied
         list of device names, via Microsoft Graph Advanced Hunting
         (requires ThreatHunting.Read.All), flagging devices below the
         documented 10.3740.XXXX floor required for critical asset
         classification.

    Does NOT and CANNOT read (no documented Graph/REST surface as of this
    writing): Defender unified RBAC custom role definitions or their
    "Microsoft Security Exposure Management" data-source assignment, initiative
    scores/history, critical asset classification results, attack path graph
    contents, or third-party data connector configuration. All of these must
    be verified manually in the Defender portal per the Escalation Evidence
    template in ExposureManagement-B.md. This script performs zero write
    operations.

.PARAMETER UserPrincipalName
    One or more user UPNs to audit legacy Entra ID role membership for.

.PARAMETER CheckCloudPosture
    Switch. If set, checks Defender for Cloud CSPM plan status across all
    accessible subscriptions in the current Az context.

.PARAMETER DeviceName
    Optional list of Defender for Endpoint device names to check sensor
    version against the 10.3740.XXXX critical-asset-classification floor.

.PARAMETER OutputPath
    Folder to write the CSV export to. Default: current directory.

.EXAMPLE
    .\Get-ExposureManagementRBACAudit.ps1 -UserPrincipalName "analyst@contoso.com"

.EXAMPLE
    .\Get-ExposureManagementRBACAudit.ps1 `
        -UserPrincipalName "analyst@contoso.com","lead@contoso.com" `
        -CheckCloudPosture `
        -DeviceName "DESKTOP-ABC123","SRV-FILE01" `
        -OutputPath "C:\Evidence"

.NOTES
    Requires: Microsoft.Graph.Users, Microsoft.Graph.Identity.DirectoryManagement,
    Microsoft.Graph.Security (for Advanced Hunting), Az.Accounts, Az.Security
    PowerShell modules. Requires a signed-in Microsoft Graph session
    (Connect-MgGraph -Scopes "Directory.Read.All","RoleManagement.Read.Directory",
    "ThreatHunting.Read.All") and, if -CheckCloudPosture is used, a signed-in
    Az session (Connect-AzAccount) with Security Reader or higher.
    Read-only. No Set-/New-/Remove-/Update- cmdlets are used anywhere in this
    script's executable code.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$UserPrincipalName,

    [Parameter(Mandatory = $false)]
    [switch]$CheckCloudPosture,

    [Parameter(Mandatory = $false)]
    [string[]]$DeviceName,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$results = [System.Collections.Generic.List[object]]::new()

# Ten legacy Entra ID roles that grant some level of MSEM access, with the
# documented effective tier per Microsoft's own action-permission matrix.
$qualifyingRoles = @{
    "Global Administrator"          = "Full (read + write)"
    "Security Administrator"        = "Full (read + write)"
    "Security Operator"             = "Limited write (criticality level/rule toggle only)"
    "Global Reader"                 = "Read-only"
    "Security Reader"               = "Read-only"
    "Service Support Administrator" = "Read-only"
    "User Administrator"            = "Read-only"
    "Helpdesk Administrator"        = "Read-only"
    "Exchange Administrator"        = "Full (read + write, per documented matrix)"
    "SharePoint Administrator"      = "Full (read + write, per documented matrix)"
}

# ------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------
Write-Status "Verifying Microsoft Graph session..."
try {
    $mgContext = Get-MgContext
    if (-not $mgContext) { throw "No Microsoft Graph context." }
} catch {
    Write-Status "Not connected to Microsoft Graph. Run Connect-MgGraph -Scopes 'Directory.Read.All','RoleManagement.Read.Directory','ThreatHunting.Read.All' first." -Status "ERROR"
    throw
}

# ------------------------------------------------------------------
# 1. Legacy Entra ID role membership per user
# ------------------------------------------------------------------
foreach ($upn in $UserPrincipalName) {
    Write-Status "Checking legacy Entra ID role membership for $upn..."
    try {
        $memberships = Get-MgUserMemberOf -UserId $upn -All -ErrorAction Stop
        $matchedRoles = $memberships | Where-Object {
            $_.AdditionalProperties.ContainsKey('displayName') -and
            $qualifyingRoles.ContainsKey($_.AdditionalProperties['displayName'])
        }

        if (-not $matchedRoles -or $matchedRoles.Count -eq 0) {
            Write-Status "  $upn holds NONE of the 10 qualifying legacy Entra ID roles." -Status "WARN"
            $results.Add([PSCustomObject]@{
                Category = "LegacyRole"
                Item     = $upn
                Status   = "WARN"
                Detail   = "No qualifying legacy Entra ID role found — MSEM access, if present, must come from a Defender unified RBAC custom role (portal-only, not checked by this script)."
            })
            continue
        }

        foreach ($role in $matchedRoles) {
            $roleName = $role.AdditionalProperties['displayName']
            $tier = $qualifyingRoles[$roleName]
            $results.Add([PSCustomObject]@{
                Category = "LegacyRole"
                Item     = "$upn / $roleName"
                Status   = "OK"
                Detail   = "Effective MSEM tier: $tier"
            })
            Write-Status "  $upn holds '$roleName' — effective tier: $tier" -Status "OK"
        }
    } catch {
        Write-Status "  Could not retrieve role membership for ${upn}: $($_.Exception.Message)" -Status "WARN"
        $results.Add([PSCustomObject]@{ Category = "LegacyRole"; Item = $upn; Status = "ERROR"; Detail = $_.Exception.Message })
    }
}

# ------------------------------------------------------------------
# 2. Tenant licensing (best-effort)
# ------------------------------------------------------------------
Write-Status "Checking tenant licensing for E5/Defender-suite-qualifying SKUs..."
try {
    $skus = Get-MgSubscribedSku -All -ErrorAction Stop
    $candidateSkus = $skus | Where-Object {
        $_.SkuPartNumber -match "E5|ENTERPRISEPREMIUM|SPE_E5|MDATP|Defender"
    }
    if ($candidateSkus) {
        foreach ($sku in $candidateSkus) {
            $results.Add([PSCustomObject]@{
                Category = "Licensing"
                Item     = $sku.SkuPartNumber
                Status   = "OK"
                Detail   = "ConsumedUnits=$($sku.ConsumedUnits); PrepaidEnabled=$($sku.PrepaidUnits.Enabled) (verify this SKU actually maps to a qualifying plan for your agreement type — not all E5-adjacent SKU names guarantee MSEM entitlement)"
            })
        }
        Write-Status "Found $($candidateSkus.Count) candidate E5/Defender-suite SKU(s) — manually confirm entitlement." -Status "OK"
    } else {
        Write-Status "No obviously-qualifying SKU found by name pattern — manually verify licensing." -Status "WARN"
        $results.Add([PSCustomObject]@{ Category = "Licensing"; Item = "Tenant-wide"; Status = "WARN"; Detail = "No SKU matched the E5/Defender-suite name pattern search — this is a best-effort check only; confirm manually." })
    }
} catch {
    Write-Status "Could not check tenant licensing: $($_.Exception.Message)" -Status "WARN"
    $results.Add([PSCustomObject]@{ Category = "Licensing"; Item = "Tenant-wide"; Status = "ERROR"; Detail = $_.Exception.Message })
}

# ------------------------------------------------------------------
# 3. Defender for Cloud CSPM plan status (optional)
# ------------------------------------------------------------------
if ($CheckCloudPosture) {
    Write-Status "Checking Defender for Cloud CSPM plan status..."
    try {
        $azContext = Get-AzContext
        if (-not $azContext) { throw "No Az context — run Connect-AzAccount first." }

        $pricing = Get-AzSecurityPricing -ErrorAction Stop
        foreach ($plan in $pricing) {
            $isCspm = $plan.Name -match "CloudPosture|CSPM"
            $enabled = $plan.PricingTier -ne "Free"
            $results.Add([PSCustomObject]@{
                Category = "CloudPosture"
                Item     = $plan.Name
                Status   = if ($isCspm -and $enabled) { "OK" } elseif ($isCspm) { "WARN" } else { "INFO" }
                Detail   = "PricingTier=$($plan.PricingTier)"
            })
        }
        Write-Status "Cloud posture check complete — see CSV for per-plan detail." -Status "OK"
    } catch {
        Write-Status "Could not check Defender for Cloud pricing: $($_.Exception.Message)" -Status "WARN"
        $results.Add([PSCustomObject]@{ Category = "CloudPosture"; Item = "Tenant-wide"; Status = "ERROR"; Detail = $_.Exception.Message })
    }
} else {
    Write-Status "Skipping Defender for Cloud CSPM check — pass -CheckCloudPosture to include it." -Status "WARN"
}

# ------------------------------------------------------------------
# 4. Device sensor version check (optional, via Advanced Hunting)
# ------------------------------------------------------------------
if ($DeviceName -and $DeviceName.Count -gt 0) {
    Write-Status "Checking Defender for Endpoint sensor versions for critical-asset-classification eligibility..."
    $minVersion = [version]"10.3740.0.0"
    try {
        $deviceList = $DeviceName -join '","'
        $kqlQuery = "DeviceInfo | where DeviceName in (`"$deviceList`") | summarize arg_max(Timestamp, ClientVersion) by DeviceName"
        $body = @{ Query = $kqlQuery } | ConvertTo-Json
        $huntResult = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/security/runHuntingQuery" -Body $body -ErrorAction Stop

        foreach ($row in $huntResult.results) {
            $deviceName = $row.DeviceName
            $clientVersion = $row.ClientVersion
            $eligible = $false
            try {
                # ClientVersion format varies (e.g. 10.3740.24012.1004) — compare major.minor only
                $parts = $clientVersion -split '\.'
                if ($parts.Count -ge 2) {
                    $comparable = [version]"$($parts[0]).$($parts[1]).0.0"
                    $eligible = $comparable -ge $minVersion
                }
            } catch { $eligible = $false }

            $results.Add([PSCustomObject]@{
                Category = "SensorVersion"
                Item     = $deviceName
                Status   = if ($eligible) { "OK" } else { "FAIL" }
                Detail   = "ClientVersion=$clientVersion (floor: 10.3740.XXXX for critical asset classification)"
            })
            Write-Status "  $deviceName : $clientVersion" -Status $(if ($eligible) { "OK" } else { "WARN" })
        }
    } catch {
        Write-Status "Could not run Advanced Hunting sensor-version query: $($_.Exception.Message)" -Status "WARN"
        $results.Add([PSCustomObject]@{ Category = "SensorVersion"; Item = "Query"; Status = "ERROR"; Detail = $_.Exception.Message })
    }
} else {
    Write-Status "Skipping device sensor version check — pass -DeviceName to include it." -Status "WARN"
}

# ------------------------------------------------------------------
# Known Gaps — explicitly not covered by this script
# ------------------------------------------------------------------
$knownGaps = @(
    "Defender unified RBAC custom role definitions and their 'Microsoft Security Exposure Management' data-source assignment — no documented Graph/REST read surface; check Defender portal → Permissions & roles → Roles (Unified RBAC) manually."
    "Initiative scores, target scores, 14-day trend/drift, and History — portal-only (Exposure insights → Initiatives)."
    "Critical asset classification results (predefined/custom/manually-reviewed) — portal-only (device inventory criticality level, or System → Settings → Microsoft Defender XDR → Critical asset management)."
    "Attack Path analysis graph contents and choke-point identification — portal-only visualization, though the underlying ExposureGraphNodes/ExposureGraphEdges schemas ARE queryable via Advanced Hunting for ad hoc investigation, just not audited wholesale here."
    "Third-party data connector (ServiceNow CMDB, Tenable, Qualys, Rapid7) configuration and consumption/pricing state — portal-only."
)
foreach ($gap in $knownGaps) {
    $results.Add([PSCustomObject]@{ Category = "KnownGap"; Item = "Manual verification required"; Status = "INFO"; Detail = $gap })
}

# ------------------------------------------------------------------
# Report
# ------------------------------------------------------------------
Write-Status "=== Summary ===" -Status "INFO"
$results | Group-Object Status | ForEach-Object { Write-Status "$($_.Name): $($_.Count)" }

$exportFile = Join-Path -Path $OutputPath -ChildPath "ExposureManagement-RBACAudit-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$results | Export-Csv -Path $exportFile -NoTypeInformation
Write-Status "Full results exported to $exportFile" -Status "OK"

$results
