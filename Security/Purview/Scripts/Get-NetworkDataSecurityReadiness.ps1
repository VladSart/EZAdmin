<#
.SYNOPSIS
    Audits tenant-side prerequisites and Purview DLP configuration for Microsoft Purview
    network data security (the Entra Global Secure Access content-policy DLP integration).

.DESCRIPTION
    Network data security (preview) has no dedicated cmdlet surface for its GSA-side
    components — content policies, security profiles, and traffic logs are all
    Entra-admin-center-portal-only. This script audits the half of the stack that IS
    reachable via PowerShell/Graph:
      - Tenant licensing signal (E7 / Purview E5 + Internet Access-family SKUs)
      - Purview DLP policies whose name/comment suggests Inline web traffic / network scope
      - Whether any DLP rule action list references the network-specific "Restrict browser
        and network activities" action (best-effort text match against rule XML/JSON)
    It does NOT and cannot confirm: GSA content policy existence/config, security profile
    linkage, Conditional Access session-control linkage, GSA client forwarding state, GSA
    traffic logs, or Purview pay-as-you-go billing enablement — all require the portal
    checklist printed at the end of this script's output.

.PARAMETER AdminUPN
    UPN used to connect to Security & Compliance PowerShell (Connect-IPPSSession).

.EXAMPLE
    .\Get-NetworkDataSecurityReadiness.ps1 -AdminUPN admin@contoso.com

.NOTES
    Read-only. Requires the ExchangeOnlineManagement module (Connect-IPPSSession) and
    Microsoft.Graph.Identity.DirectoryManagement (or equivalent) for Get-MgSubscribedSku.
    Safe to run repeatedly; makes no configuration changes.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AdminUPN,

    [string]$OutputPath = ".\NetworkDataSecurityReadiness_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

# --- Preflight: connect ---
Write-Status "Connecting to Security & Compliance PowerShell as $AdminUPN..."
try {
    Connect-IPPSSession -UserPrincipalName $AdminUPN -ShowBanner:$false
    Write-Status "Connected to Security & Compliance PowerShell." "OK"
}
catch {
    Write-Status "Failed to connect to Security & Compliance PowerShell: $($_.Exception.Message)" "ERROR"
    throw
}

try {
    Connect-MgGraph -Scopes "Organization.Read.All" -NoWelcome
    Write-Status "Connected to Microsoft Graph." "OK"
}
catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "WARN"
    Write-Status "Licensing checks will be skipped." "WARN"
}

# --- Detect: licensing signal ---
Write-Status "Checking tenant SKUs for a network-data-security-eligible licensing path..."
$licenseFlag = "UNKNOWN"
try {
    $skus = Get-MgSubscribedSku -ErrorAction Stop
    $relevant = $skus | Where-Object {
        $_.SkuPartNumber -match "SPE_E7|PURVIEW|INFORMATION_PROTECTION|INTERNET_ACCESS|GLOBAL_SECURE|ENTRA_SUITE"
    }
    if ($relevant) {
        foreach ($sku in $relevant) {
            $enabled = ($sku.PrepaidUnits).Enabled
            $results.Add([PSCustomObject]@{
                Category = "Licensing"
                Item     = $sku.SkuPartNumber
                Status   = "Present ($enabled seats)"
                Detail   = "Consumed: $($sku.ConsumedUnits)"
            })
        }
        $licenseFlag = "CANDIDATE_SKU_PRESENT"
        Write-Status "Found $($relevant.Count) candidate SKU(s) toward E7 or Purview E5 + Internet Access path." "OK"
    }
    else {
        $licenseFlag = "NO_CANDIDATE_SKU"
        Write-Status "No SKU matched the E7 / Purview E5 + Internet Access pattern — verify licensing manually." "WARN"
        $results.Add([PSCustomObject]@{
            Category = "Licensing"; Item = "NetworkDataSecurityLicensing"
            Status   = "NO_CANDIDATE_SKU"; Detail = "Manually confirm M365 E7, or Purview E5 (or equiv) + Entra Internet Access"
        })
    }
}
catch {
    Write-Status "Could not read subscribed SKUs: $($_.Exception.Message)" "WARN"
}

# --- Detect: Purview DLP policies possibly scoped to network / Inline web traffic ---
Write-Status "Scanning DLP policies for network/Inline-web-traffic scope signals..."
try {
    $allPolicies = Get-DlpCompliancePolicy -ErrorAction Stop
    $networkCandidates = $allPolicies | Where-Object {
        $_.Workload -match "CloudAppsInternal|Network" -or
        $_.Name -match "(?i)network|inline web|gsa|global secure" -or
        $_.Comment -match "(?i)network|inline web|gsa|global secure"
    }

    if ($networkCandidates) {
        foreach ($pol in $networkCandidates) {
            $results.Add([PSCustomObject]@{
                Category = "DLPPolicy"
                Item     = $pol.Name
                Status   = if ($pol.Enabled -and $pol.Mode -eq "Enable") { "Enabled/Enforce" } else { "$($pol.Mode)/Enabled=$($pol.Enabled)" }
                Detail   = "Workload: $($pol.Workload -join ',')"
            })
        }
        Write-Status "Found $($networkCandidates.Count) DLP polic(y/ies) matching network/Inline-web-traffic naming or workload signals." "OK"
    }
    else {
        Write-Status "No DLP policy name/workload/comment suggests Inline web traffic / network scope." "WARN"
        $results.Add([PSCustomObject]@{
            Category = "DLPPolicy"; Item = "InlineWebTrafficPolicy"
            Status   = "NOT_FOUND"; Detail = "No matching policy — network data security enforcement may not be configured yet"
        })
    }

    # Best-effort: check rule action text for the network-specific restrict action
    Write-Status "Checking rules for the network-specific 'Restrict browser and network activities' action (best effort)..."
    $ruleHits = 0
    foreach ($pol in $allPolicies) {
        try {
            $rules = Get-DlpComplianceRule -Policy $pol.Name -ErrorAction SilentlyContinue
            foreach ($rule in $rules) {
                $ruleText = ($rule | ConvertTo-Json -Depth 6 -ErrorAction SilentlyContinue)
                if ($ruleText -match "(?i)RestrictBrowserAccess|NetworkActivit|CloudAppsInternal") {
                    $ruleHits++
                    $results.Add([PSCustomObject]@{
                        Category = "DLPRule"
                        Item     = "$($pol.Name)/$($rule.Name)"
                        Status   = if ($rule.Disabled) { "Disabled" } else { "Enabled" }
                        Detail   = "Matched network-activity action signature"
                    })
                }
            }
        }
        catch { continue }
    }
    if ($ruleHits -eq 0) {
        Write-Status "No rule matched a network-activity action signature across any DLP policy." "WARN"
    }
    else {
        Write-Status "Found $ruleHits rule(s) referencing network-activity actions." "OK"
    }
}
catch {
    Write-Status "Failed to enumerate DLP policies/rules: $($_.Exception.Message)" "ERROR"
}

# --- Report: portal-only checklist (cannot be automated) ---
Write-Status "" 
Write-Status "=== PORTAL-ONLY ITEMS — this script CANNOT check these; verify manually ===" "WARN"
$portalChecklist = @(
    "Entra admin center > Global Secure Access > Secure > Content policies — rule exists, Action = Scan with Purview"
    "Entra admin center > Global Secure Access > Secure > Security profiles — content policy linked"
    "Entra ID > Conditional Access > policy Session tab — Use Global Secure Access Security Profile linked"
    "Entra admin center > Global Secure Access > Connect > Traffic forwarding — Internet Access profile enabled + assigned"
    "Entra admin center > Global Secure Access > Monitor > Traffic logs — recent hits for the affected user/app"
    "Purview portal > Settings > pay-as-you-go billing — configured (required even to select Network as an enforcement location)"
    "Purview portal > Data Classification > Activity explorer — Enforcement plane = Network shows events"
    "GSA client (on affected device) > Troubleshooting > Advanced Diagnostics > Forwarding Profile tab — Internet Access rules present"
)
foreach ($item in $portalChecklist) {
    Write-Host "  [ ] $item" -ForegroundColor Yellow
    $results.Add([PSCustomObject]@{ Category = "PortalOnly"; Item = $item; Status = "MANUAL_CHECK_REQUIRED"; Detail = "No cmdlet/Graph read surface exists" })
}

# --- Export ---
$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Status "Report exported to $OutputPath ($($results.Count) rows)." "OK"
Write-Status "Licensing signal: $licenseFlag" "INFO"
