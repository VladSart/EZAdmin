<#
.SYNOPSIS
    Audits Microsoft Defender for Endpoint's Local AI Agent Discovery (Preview) coverage
    and licensing state for a tenant.

.DESCRIPTION
    Read-only Microsoft Graph audit script. It does NOT and cannot:
      - Enable or configure Local AI Agent Discovery (there is no configuration surface;
        it is automatic once a device is onboarded to Defender for Endpoint with
        Antivirus in active mode and real-time protection enabled).
      - Block, restrict, or remediate any discovered agent (this is AI Agent Runtime
        Protection's job, not Discovery's — see Get-AIAgentRuntimeProtectionAudit.ps1).
      - Query the AgentsInfo / ExposureGraphNodes / ExposureGraphEdges Advanced Hunting
        tables directly via Graph in a single generic call — those require the
        Advanced Hunting API (runHuntingQuery) with a hand-written KQL query per use
        case. This script prints the recommended KQL queries for the operator to run
        in the Defender portal or via runHuntingQuery, rather than hard-coding one
        narrow query shape.

    What it DOES check, via Microsoft Graph:
      - Tenant licensing floor: Defender for Endpoint Plan 2 (via M365 E5/E7 or a
        standalone Plan 2 SKU) and the risk-posture add-on floor (M365 E7 or
        Microsoft Agent 365).
      - Per-device onboarding and health signal via the Defender for Endpoint
        machines API, flagging devices that are onboarded but may not meet the
        Antivirus active-mode prerequisite (best-effort — full AV mode state is a
        local, not Graph-exposed, property; see the .NOTES section).
      - A best-effort scan for known local AI agent binaries in each managed device's
        installed-software inventory (via Intune detected apps), to help operators
        cross-reference "who might have a supported agent installed" before checking
        the portal inventory directly.

.PARAMETER TenantId
    Optional. Entra tenant ID to target if not using the default authentication context.

.EXAMPLE
    .\Get-LocalAIAgentDiscoveryAudit.ps1
    Runs the audit against the currently authenticated Graph context and exports
    results to CSV/JSON in the current directory.

.NOTES
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement modules.
    Run as: an account with DeviceManagementManagedDevices.Read.All and
            Organization.Read.All Graph scopes (read-only).
    Safe/unsafe: fully read-only. No configuration or remediation actions are taken.

    IMPORTANT LIMITATION: Microsoft Graph does not currently expose a
    "Local AI Agent Discovery inventory" endpoint directly — the AgentsInfo,
    ExposureGraphNodes, and ExposureGraphEdges tables are Advanced Hunting
    (KQL) constructs, queried via the security.microsoft.com portal or the
    Advanced Hunting runHuntingQuery Graph API, not standard Graph resource
    endpoints. This script surfaces the KQL you need and the licensing/onboarding
    context around it, but does not itself return the agent inventory. Treat the
    printed KQL block as the authoritative next step for actual agent-level data.
#>
#Requires -Modules Microsoft.Graph.Authentication
[CmdletBinding()]
param(
    [string]$TenantId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK" { "Green" } "WARN" { "Yellow" } "ERROR" { "Red" } default { "Cyan" } }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---- Preflight ----
Write-Status "Connecting to Microsoft Graph (read-only scopes)..."
try {
    $connectParams = @{
        Scopes = @("Organization.Read.All", "DeviceManagementManagedDevices.Read.All")
    }
    if ($TenantId) { $connectParams["TenantId"] = $TenantId }
    Connect-MgGraph @connectParams -NoWelcome
    Write-Status "Connected." "OK"
} catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    throw
}

$results = [ordered]@{
    RunTimestamp        = Get-Date -Format "o"
    LicensingFloor       = $null
    RiskPostureLicense   = $null
    OnboardedDeviceCount = $null
    KnownAgentHits       = @()
    RecommendedKQL       = @()
}

# ---- Licensing floor: Defender for Endpoint Plan 2 (directly or via E5/E7) ----
Write-Status "Checking tenant licensing for Defender for Endpoint Plan 2..."
try {
    $skus = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/subscribedSkus" |
        Select-Object -ExpandProperty value

    $planTwoPattern = "MDE_P2|ATP_ENTERPRISE|SPE_E5|SPE_E7|EMSPREMIUM"
    $planTwoSkus = $skus | Where-Object { $_.skuPartNumber -match $planTwoPattern -and $_.prepaidUnits.enabled -gt 0 }

    if ($planTwoSkus) {
        $results.LicensingFloor = ($planTwoSkus | Select-Object -ExpandProperty skuPartNumber) -join ", "
        Write-Status "Defender for Endpoint Plan 2 floor appears satisfied via: $($results.LicensingFloor)" "OK"
    } else {
        $results.LicensingFloor = "NOT FOUND"
        Write-Status "No SKU matching the Defender for Endpoint Plan 2 floor was found. Local AI Agent Discovery cannot function tenant-wide." "WARN"
    }

    $riskPostureSkus = $skus | Where-Object { $_.skuPartNumber -match "SPE_E7|Agent365" -and $_.prepaidUnits.enabled -gt 0 }
    if ($riskPostureSkus) {
        $results.RiskPostureLicense = ($riskPostureSkus | Select-Object -ExpandProperty skuPartNumber) -join ", "
        Write-Status "Risk-posture license floor (E7 / Agent 365) satisfied via: $($results.RiskPostureLicense)" "OK"
    } else {
        $results.RiskPostureLicense = "NOT FOUND"
        Write-Status "No E7 / Agent 365 SKU found. Inventory will work, but Risk level/indicators/recommendations will stay blank for all discovered agents." "WARN"
    }
} catch {
    Write-Status "Could not enumerate subscribedSkus: $($_.Exception.Message)" "WARN"
    $results.LicensingFloor = "ERROR: $($_.Exception.Message)"
}

# ---- Onboarded device count (proxy signal — full AV-mode state isn't Graph-exposed) ----
Write-Status "Counting managed devices as an onboarding-population proxy..."
try {
    $devices = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$select=id,deviceName,operatingSystem,osVersion,managementAgent" |
        Select-Object -ExpandProperty value
    $results.OnboardedDeviceCount = $devices.Count
    $winMac = $devices | Where-Object { $_.operatingSystem -match "Windows|macOS" }
    Write-Status "Found $($devices.Count) managed devices ($($winMac.Count) Windows/macOS — the only platforms Discovery supports)." "OK"
} catch {
    Write-Status "Could not enumerate managed devices: $($_.Exception.Message)" "WARN"
    $results.OnboardedDeviceCount = "ERROR: $($_.Exception.Message)"
}

# ---- Best-effort known-agent binary scan via Intune detected apps ----
Write-Status "Scanning Intune detected-apps inventory for known local AI agent names (best-effort, name-matching only)..."
$knownAgentNames = @(
    "Claude", "Claude Code", "Codex", "Gemini", "GitHub Copilot", "Cursor", "Ollama",
    "Warp", "ChatGPT", "Goose", "Perplexity", "Poe", "Cline", "Roo Code", "Kiro", "Devin", "Windsurf"
)
try {
    $apps = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/deviceAppManagement/detectedApps?`$select=id,displayName,version,deviceCount&`$top=999" |
        Select-Object -ExpandProperty value

    foreach ($name in $knownAgentNames) {
        $matches = $apps | Where-Object { $_.displayName -match [regex]::Escape($name) }
        foreach ($m in $matches) {
            $results.KnownAgentHits += [pscustomobject]@{
                MatchedTerm  = $name
                AppName      = $m.displayName
                Version      = $m.version
                DeviceCount  = $m.deviceCount
            }
        }
    }
    if ($results.KnownAgentHits.Count -gt 0) {
        Write-Status "Found $($results.KnownAgentHits.Count) detected-app entries matching known local AI agent names. Cross-reference these devices against the portal's Local agents inventory — a mismatch (app detected, not in inventory) points to an onboarding/AV-mode gap, not a missing app." "OK"
    } else {
        Write-Status "No known local AI agent names found in Intune's detected-apps inventory. Note: many local AI agents (npm-installed CLIs, VS Code extensions) are NOT captured by Intune's detected-apps inventory at all — this is a best-effort signal only, not authoritative. Trust the Defender portal inventory over this script for ground truth." "WARN"
    }
} catch {
    Write-Status "Could not query detected apps (requires an Intune-managed device population): $($_.Exception.Message)" "WARN"
}

# ---- Print the KQL the operator actually needs for ground-truth inventory data ----
$results.RecommendedKQL = @(
    @{
        Purpose = "Current local agent inventory (latest record per agent, excluding removed)"
        Query   = @"
AgentsInfo
| where Platform == "LocalAgents"
| summarize arg_max(Timestamp, Name, Version, LifecycleStatus, RawAgentInfo) by AgentId
| where LifecycleStatus !in~ ("Deleted", "Uninstalled")
"@
    },
    @{
        Purpose = "Agents with risky configuration (auto-approve or untrusted host process)"
        Query   = @"
AgentsInfo
| where Platform == "LocalAgents"
| summarize arg_max(Timestamp, Name, Version, LifecycleStatus, RawAgentInfo) by AgentId
| where LifecycleStatus !in~ ("Deleted", "Uninstalled")
| extend AgentMetadata = RawAgentInfo.localAgentMetadata
| extend AutoApprove = tostring(AgentMetadata.autoApprove), TrustedProcess = tostring(AgentMetadata.trustedProcess)
| where AutoApprove =~ "true" or TrustedProcess =~ "false"
"@
    }
)
Write-Status "Run the queries in `$results.RecommendedKQL` via security.microsoft.com > Advanced hunting, or the Advanced Hunting runHuntingQuery Graph API, for authoritative agent-level inventory and risk data (not retrievable via standard Graph endpoints)." "INFO"

# ---- Report ----
Write-Host "`n=== Local AI Agent Discovery Readiness Summary ===" -ForegroundColor Cyan
$results.GetEnumerator() | Where-Object { $_.Key -ne "RecommendedKQL" } | ForEach-Object {
    "{0,-24}: {1}" -f $_.Key, ($_.Value | Out-String).Trim()
}

$exportPath = ".\LocalAIAgentDiscovery-Audit-$(Get-Date -Format yyyyMMdd-HHmm).json"
$results | ConvertTo-Json -Depth 6 | Out-File $exportPath
Write-Status "Full results exported to $exportPath" "OK"

if ($results.KnownAgentHits.Count -gt 0) {
    $csvPath = ".\LocalAIAgentDiscovery-KnownAgentHits-$(Get-Date -Format yyyyMMdd-HHmm).csv"
    $results.KnownAgentHits | Export-Csv -Path $csvPath -NoTypeInformation
    Write-Status "Known-agent detected-app hits exported to $csvPath" "OK"
}
