<#
.SYNOPSIS
    Audits tenant-wide Power Platform data (DLP) policies for Copilot Studio-specific connector
    coverage and flags the highest-risk governance gaps.

.DESCRIPTION
    Local diagnostic companion to PowerAutomate/PowerApps/CopilotStudio-Security-A.md and -B.md.

    Enumerates every data policy in the tenant, extracts the Copilot Studio-specific connectors
    (authentication, knowledge sources, channels, HTTP, skills, event triggers), and reports:
      - Which policies exist, their scope (tenant-wide / specific-environments / exclude-list),
        and which Copilot Studio connectors each one classifies.
      - The single highest-priority governance gap this script can detect without a live
        Copilot Studio session: whether ANY policy in the tenant blocks the
        "Chat without Microsoft Entra ID authentication in Copilot Studio" connector. If no
        policy blocks it anywhere, agent makers in every environment can still publish fully
        unauthenticated, public agents — the runbook's most common "why does this agent have no
        login" root cause.
      - Copilot Studio connectors present in a policy but sitting in the DEFAULT/unclassified
        group (commonly auto-blocked as Non-Business in many tenant baselines) — the runbook's
        documented #1 cause of "this used to work" tickets after a Microsoft feature update ships
        a new connector.
      - Policies whose Copilot Studio connectors span more than one data group within the SAME
        policy, which prevents those connectors from exchanging data with each other even without
        an explicit block.

    This script does NOT read individual agent authentication settings, CMK status, or Purview
    audit logs — those require a live Copilot Studio session or Purview portal access respectively
    and are covered by the runbook's own Validation Steps 4-6. It also does NOT create, modify,
    or delete any policy — read-only reporting only.

.PARAMETER OutputPath
    Folder to write the CSV report to. Default: $env:TEMP.

.EXAMPLE
    .\Get-CopilotStudioDLPAudit.ps1
    Runs a full tenant audit of Copilot Studio-relevant data policy coverage with default settings.

.EXAMPLE
    .\Get-CopilotStudioDLPAudit.ps1 -OutputPath C:\Temp\Evidence
    Writes the CSV report to a specific evidence folder for ticket attachment.

.NOTES
    Requires: Microsoft.PowerApps.Administration.PowerShell module, connected via
              Add-PowerAppsAccount as a user with Power Platform Administrator or
              Environment Admin rights.
              Install-Module -Name Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser
    Safe: Read-only. No policies, connectors, or environments are created, modified, or deleted.
    Companion runbooks: PowerAutomate/PowerApps/CopilotStudio-Security-A.md (deep dive),
                         PowerAutomate/PowerApps/CopilotStudio-Security-B.md (hotfix triage).
#>
[CmdletBinding()]
param(
    [string]$OutputPath = $env:TEMP
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------------------------------------------------------------------------
# Module / connection check
# ---------------------------------------------------------------------------
Write-Status "Checking for Microsoft.PowerApps.Administration.PowerShell module..."
if (-not (Get-Module -ListAvailable -Name Microsoft.PowerApps.Administration.PowerShell)) {
    Write-Status "Module not found. Install with: Install-Module -Name Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser" "ERROR"
    throw "Required module missing."
}
Import-Module Microsoft.PowerApps.Administration.PowerShell -ErrorAction Stop

try {
    $null = Get-AdminDlpPolicy -ErrorAction Stop
    Write-Status "Existing admin session detected." "OK"
} catch {
    Write-Status "No active admin session detected. Run Add-PowerAppsAccount first, then re-run this script." "ERROR"
    throw
}

# ---------------------------------------------------------------------------
# Reference table: Copilot Studio connector name fragments and what they govern
# ---------------------------------------------------------------------------
$copilotStudioConnectorMap = @{
    "*without*Microsoft*Entra*ID*authentication*Copilot*Studio*" = "Unauthenticated chat gate"
    "*SharePoint*OneDrive*Copilot*Studio*"                       = "SharePoint/OneDrive knowledge source"
    "*public*websites*Copilot*Studio*"                           = "Public website knowledge source"
    "*documents*Copilot*Studio*"                                 = "Document knowledge source"
    "*Teams*Microsoft 365*Channel*Copilot*Studio*"               = "Teams + M365 channel publish"
    "*Direct Line*Copilot*Studio*"                                = "Direct Line channels (Demo/custom website, mobile)"
    "*Facebook*Copilot*Studio*"                                  = "Facebook channel publish"
    "*Omnichannel*Copilot*Studio*"                                = "Dynamics 365 Customer Service channel publish"
    "*SharePoint channel*Copilot*Studio*"                        = "SharePoint channel publish"
    "*WhatsApp*Copilot*Studio*"                                  = "WhatsApp channel publish"
    "*Skills*Copilot*Studio*"                                    = "Skills usage"
    "*Application Insights*Copilot*Studio*"                      = "App Insights telemetry"
}

function Get-CopilotStudioConnectorLabel {
    param([string]$ConnectorName)
    foreach ($pattern in $copilotStudioConnectorMap.Keys) {
        if ($ConnectorName -like $pattern) { return $copilotStudioConnectorMap[$pattern] }
    }
    if ($ConnectorName -match '^HTTP$') { return "HTTP request node publish" }
    if ($ConnectorName -match '^shared_microsoftflowforadmins$|^Microsoft Copilot Studio$') { return "Event triggers / automated evaluations" }
    return $null
}

# ---------------------------------------------------------------------------
# Enumerate policies and extract Copilot Studio connector rows
# ---------------------------------------------------------------------------
Write-Status "Enumerating tenant data policies..."
$policies = Get-AdminDlpPolicy
if (-not $policies) {
    Write-Status "No data policies found in this tenant. Every Copilot Studio agent is ungoverned by DLP." "WARN"
}

$results = New-Object System.Collections.Generic.List[object]
$anyAuthBlockFound = $false

foreach ($policySummary in $policies) {
    $policy = Get-AdminDlpPolicy -PolicyName $policySummary.PolicyName
    if (-not $policy.ConnectorGroups) { continue }

    $csConnectorGroupsSeen = New-Object System.Collections.Generic.HashSet[string]

    foreach ($group in $policy.ConnectorGroups) {
        foreach ($connector in $group.Connectors) {
            $label = Get-CopilotStudioConnectorLabel -ConnectorName $connector.name
            if (-not $label) { continue }

            $null = $csConnectorGroupsSeen.Add($group.classification)

            $isAuthGate = $label -eq "Unauthenticated chat gate"
            if ($isAuthGate -and $group.classification -eq "Blocked") {
                $anyAuthBlockFound = $true
            }

            $results.Add([pscustomobject]@{
                PolicyName        = $policy.DisplayName
                PolicyScope       = $policy.EnvironmentType
                ConnectorName     = $connector.name
                Governs           = $label
                Classification    = $group.classification
                IsAuthGate        = $isAuthGate
                RiskNote          = if ($isAuthGate -and $group.classification -ne "Blocked") {
                                        "Unauthenticated agents CAN still be published under this policy scope"
                                     } elseif ($group.classification -eq "Non-Business") {
                                        "Verify this classification was set deliberately, not inherited by default"
                                     } else { "" }
            })
        }
    }

    if ($csConnectorGroupsSeen.Count -gt 1) {
        Write-Status "Policy '$($policy.DisplayName)' splits Copilot Studio connectors across $($csConnectorGroupsSeen.Count) data groups — those connectors cannot exchange data with each other under this policy." "WARN"
    }
}

# ---------------------------------------------------------------------------
# Tenant-wide summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Status "=== Tenant-wide Copilot Studio DLP Governance Summary ===" "INFO"
if ($anyAuthBlockFound) {
    Write-Status "At least one policy blocks unauthenticated Copilot Studio chat somewhere in the tenant." "OK"
} else {
    Write-Status "NO policy in this tenant blocks 'Chat without Microsoft Entra ID authentication in Copilot Studio' anywhere. Fully unauthenticated, publicly-reachable agents can be published in every environment not otherwise restricted." "WARN"
}

$unclassifiedRisk = $results | Where-Object { $_.RiskNote -ne "" }
if ($unclassifiedRisk) {
    Write-Status "$($unclassifiedRisk.Count) row(s) flagged for review — see RiskNote column in the CSV." "WARN"
} else {
    Write-Status "No default-classification or unauthenticated-publish risk rows detected in existing policies." "OK"
}

# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
$csvPath = Join-Path -Path $OutputPath -ChildPath ("CopilotStudioDLPAudit_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
$results | Sort-Object PolicyName, Governs | Export-Csv -Path $csvPath -NoTypeInformation
Write-Status "Report exported to: $csvPath" "OK"
Write-Status "Remember: this script only sees policy CONFIGURATION. It cannot see per-agent authentication settings, CMK status, or Purview audit trails — cross-check the runbook's Validation Steps 4-6 for those." "INFO"
