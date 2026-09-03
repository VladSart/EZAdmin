<#
.SYNOPSIS
    Audits Microsoft Purview DLP policies scoped to non-Microsoft connected apps (Box, Dropbox,
    Google Workspace, Salesforce) for structural correctness against documented Preview constraints.

.DESCRIPTION
    Read-only Security & Compliance PowerShell audit. For every DLP policy whose Workload indicates
    a non-Microsoft app / third-party-app location, checks:
      - Rule type: confirms every rule is an Advanced DLP rule (the only supported type here)
      - Location mixing: flags any policy that combines a non-Microsoft app location with a
        Microsoft 365 location (SharePoint/OneDrive/Exchange/Fabric) or Devices, which is unsupported
      - Policy mode: reports On/Off state (there is no Simulation mode for this location type, so
        a policy showing anything other than a clean On/Off is worth a second look)
      - Enabled rule count per policy, to catch policies with zero active rules

    This script CANNOT check Microsoft Defender for Cloud Apps connector health — there is no
    documented PowerShell/Graph read API for MDCA app connector status. That check must be performed
    manually in the Defender portal (Cloud apps > Connected apps > App connectors) per the companion
    runbook. This script also does not create, modify, or disable any policy.

.PARAMETER OutputPath
    Folder to write the CSV report to. Defaults to the current directory.

.EXAMPLE
    .\Get-NonMicrosoftDLPReadinessAudit.ps1 -OutputPath "C:\Reports"

.NOTES
    Requires: Exchange Online Management module (for Connect-IPPSSession) and an account holding
    Compliance Administrator, Compliance Data Administrator, Information Protection Admin, or
    Security Administrator (read access is sufficient).
    Safe/unsafe: fully read-only. No policy or rule is changed.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputPath = "."
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---- Preflight ----
try {
    $null = Get-DlpCompliancePolicy -ErrorAction Stop | Select-Object -First 1
} catch {
    Write-Status "Not connected to Security & Compliance PowerShell, or insufficient permissions. Run Connect-IPPSSession first. $($_.Exception.Message)" "ERROR"
    return
}

# ---- Detect: pull all DLP policies, filter to non-Microsoft-app-scoped ones ----
Write-Status "Retrieving all DLP policies..."
$allPolicies = Get-DlpCompliancePolicy
Write-Status "Found $($allPolicies.Count) total DLP polic(ies). Filtering to non-Microsoft-app-scoped policies..."

# Non-Microsoft app location workload identifiers are matched heuristically since exact
# Workload string values may vary by tenant rollout wave and Exchange Online module version.
$nonMsftPattern = "ThirdPartyApp|NonMicrosoft|ConnectedApp|Box|Dropbox|GoogleWorkspace|Salesforce"
$targetPolicies = $allPolicies | Where-Object { ($_.Workload -join ",") -match $nonMsftPattern }

if ($targetPolicies.Count -eq 0) {
    Write-Status "No policies matched a non-Microsoft-app workload pattern. Either none exist yet, or the tenant's Workload naming differs from the patterns this script checks for — verify manually in the Purview portal before concluding there's no coverage." "WARN"
}
Write-Status "Found $($targetPolicies.Count) candidate polic(ies) to audit." "OK"

$microsoftLocationPattern = "SharePoint|OneDrive|Exchange|Fabric|Device"

# ---- Execute: build per-policy findings ----
$results = New-Object System.Collections.Generic.List[Object]

foreach ($p in $targetPolicies) {
    $workloadJoined = ($p.Workload -join ", ")
    $mixesLocations = $p.Workload -and (($p.Workload -join ",") -match $microsoftLocationPattern)

    $rules = @()
    try {
        $rules = Get-DlpComplianceRule -Policy $p.Name -ErrorAction Stop
    } catch {
        Write-Status "Could not retrieve rules for policy '$($p.Name)': $($_.Exception.Message)" "WARN"
    }

    $enabledRules = @($rules | Where-Object { -not $_.Disabled })
    $nonAdvancedRules = @($enabledRules | Where-Object { -not $_.AdvancedRule })

    $findings = New-Object System.Collections.Generic.List[string]
    if ($mixesLocations) { $findings.Add("Workload mixes a non-Microsoft app location with a Microsoft 365 location/Devices — unsupported combination") }
    if ($enabledRules.Count -eq 0) { $findings.Add("No enabled rules found on this policy") }
    if ($nonAdvancedRules.Count -gt 0) { $findings.Add("$($nonAdvancedRules.Count) enabled rule(s) not confirmed as Advanced DLP rules — verify manually, only Advanced rules are supported for this location") }
    if ($p.Mode -notin @("Enable", "Disable")) { $findings.Add("Policy Mode is '$($p.Mode)' — Simulation-like modes are not supported for non-Microsoft app locations, verify this is intentional") }

    $results.Add([PSCustomObject]@{
        PolicyName          = $p.Name
        Enabled             = $p.Enabled
        Mode                = $p.Mode
        Workload            = $workloadJoined
        MixesUnsupportedLoc = $mixesLocations
        EnabledRuleCount    = $enabledRules.Count
        NonAdvancedRuleCount = $nonAdvancedRules.Count
        FindingsCount       = $findings.Count
        Findings            = ($findings -join "; ")
    })
}

# ---- Report ----
$reportPath = Join-Path $OutputPath "NonMicrosoftAppsDLP-Audit-$(Get-Date -Format yyyyMMdd-HHmm).csv"
$results | Sort-Object FindingsCount -Descending | Export-Csv -Path $reportPath -NoTypeInformation

$flagged = @($results | Where-Object { $_.FindingsCount -gt 0 }).Count
Write-Status "Audit complete: $($results.Count) polic(ies) checked, $flagged with findings." "OK"
Write-Status "Report written to $reportPath" "OK"
Write-Status "REMINDER: MDCA app connector health could not be checked by this script — verify manually in the Defender portal (Cloud apps > Connected apps) for each affected app before closing out any 'nothing is being flagged' investigation." "WARN"

$results | Sort-Object FindingsCount -Descending | Select-Object PolicyName, Enabled, Mode, FindingsCount, Findings | Format-Table -AutoSize
