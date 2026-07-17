<#
.SYNOPSIS
    Audits Safe Links and Safe Attachments policy coverage, precedence, and common misconfigurations.

.DESCRIPTION
    Read-only report against Exchange Online Protection / Defender for Office 365.
    Covers:
      - Every Safe Links and Safe Attachments policy + rule, with resolved priority order
      - Preset security policy (Standard/Strict) targeting, which always takes precedence
      - Recipients/domains covered by more than one enabled rule (precedence ambiguity risk)
      - Safe Attachments policies set to Off/Monitor (non-blocking) flagged for review
      - Default (AdminOnlyAccessPolicy / silent) quarantine tag usage on Safe Attachments policies
      - SharePoint/OneDrive/Teams Safe Attachments toggle state (separate from mail policies)
      - Inbound connectors that may indicate an upstream third-party URL-rewriting gateway
    Does NOT modify any policy, rule, or connector. Does NOT touch quarantine items.

.PARAMETER OutputPath
    Folder to write CSV reports to. Created if it doesn't exist.

.PARAMETER SkipSPOCheck
    Skip the SharePoint Online connection/check (requires Connect-SPOService and the
    SharePoint Administrator/Global Administrator role; some MSP contexts won't have this
    readily available and can defer it).

.EXAMPLE
    .\Get-SafeLinksAttachmentsPolicyAudit.ps1 -OutputPath C:\Temp\SLSA-Audit

.EXAMPLE
    .\Get-SafeLinksAttachmentsPolicyAudit.ps1 -SkipSPOCheck

.NOTES
    Requires: ExchangeOnlineManagement module, Connect-ExchangeOnline session.
    Optional: Microsoft.Online.SharePoint.PowerShell module + Connect-SPOService, for the
    SharePoint/OneDrive/Teams Safe Attachments and DisallowInfectedFileDownload checks.
    Run-as: Security Reader / Global Reader (read-only) is sufficient for all mail-side checks.
    Safe to run in production — no writes, no quarantine interaction.
#>

[CmdletBinding()]
param(
    [string]$OutputPath = "C:\Temp\SafeLinksAttachments-Audit-$(Get-Date -Format 'yyyyMMdd-HHmmss')",
    [switch]$SkipSPOCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colour = switch ($Status) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"Cyan"} }
    Write-Host "[$Status] $Message" -ForegroundColor $colour
}

# ---------- Preflight ----------
Write-Status "Checking for ExchangeOnlineManagement session..."
try {
    $null = Get-SafeLinksPolicy -ErrorAction Stop
} catch {
    Write-Status "Not connected to Exchange Online, or missing permissions. Run Connect-ExchangeOnline first." "ERROR"
    throw
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
$findings = [System.Collections.Generic.List[object]]::new()

# ---------- Detect: Safe Links policies/rules ----------
Write-Status "Collecting Safe Links policies and rules..."
$slPolicies = Get-SafeLinksPolicy
$slRules = Get-SafeLinksRule | Sort-Object Priority

$slPolicies | Select-Object Name, EnableSafeLinksForEmail, EnableSafeLinksForTeams, EnableSafeLinksForOffice, DoNotRewriteUrls, TrackClicks |
    Export-Csv "$OutputPath\safelinks_policies.csv" -NoTypeInformation
$slRules | Select-Object Name, State, Priority, SafeLinksPolicy, SentTo, SentToMemberOf, RecipientDomainIs |
    Export-Csv "$OutputPath\safelinks_rules.csv" -NoTypeInformation

foreach ($rule in ($slRules | Where-Object State -eq "Disabled")) {
    $findings.Add([PSCustomObject]@{
        Category = "SAFELINKS_RULE_DISABLED"
        Object   = $rule.Name
        Detail   = "Rule is disabled — associated policy '$($rule.SafeLinksPolicy)' is not being applied to anyone via this rule"
    })
}

foreach ($policy in $slPolicies) {
    if (-not $policy.EnableSafeLinksForTeams) {
        $findings.Add([PSCustomObject]@{
            Category = "SAFELINKS_TEAMS_OFF"
            Object   = $policy.Name
            Detail   = "EnableSafeLinksForTeams is false — Teams link protection not covered by this policy"
        })
    }
    if ($policy.DoNotRewriteUrls -and $policy.DoNotRewriteUrls.Count -gt 0) {
        $findings.Add([PSCustomObject]@{
            Category = "SAFELINKS_API_ONLY_URLS"
            Object   = $policy.Name
            Detail   = "$($policy.DoNotRewriteUrls.Count) URL(s) excluded from rewriting — protection for these relies on client-side API checks in supported Outlook only"
        })
    }
}

# ---------- Detect: Safe Attachments policies/rules ----------
Write-Status "Collecting Safe Attachments policies and rules..."
$saPolicies = Get-SafeAttachmentPolicy
$saRules = Get-SafeAttachmentRule | Sort-Object Priority

$saPolicies | Select-Object Name, Enable, Action, QuarantineTag, Redirect, RedirectAddress |
    Export-Csv "$OutputPath\safeattachment_policies.csv" -NoTypeInformation
$saRules | Select-Object Name, State, Priority, SafeAttachmentPolicy, SentTo, SentToMemberOf, RecipientDomainIs |
    Export-Csv "$OutputPath\safeattachment_rules.csv" -NoTypeInformation

foreach ($policy in $saPolicies) {
    if ($policy.Action -eq "Off") {
        $findings.Add([PSCustomObject]@{
            Category = "SAFEATTACHMENT_ACTION_OFF"
            Object   = $policy.Name
            Detail   = "Action = Off — no attachment detonation scanning occurs for recipients covered by this policy"
        })
    } elseif ($policy.Action -eq "Monitor") {
        $findings.Add([PSCustomObject]@{
            Category = "SAFEATTACHMENT_ACTION_MONITOR"
            Object   = $policy.Name
            Detail   = "Action = Monitor — malicious attachments are alerted on but still delivered (non-blocking)"
        })
    }
    if ([string]::IsNullOrEmpty($policy.QuarantineTag) -or $policy.QuarantineTag -eq "AdminOnlyAccessPolicy") {
        $findings.Add([PSCustomObject]@{
            Category = "SAFEATTACHMENT_SILENT_QUARANTINE"
            Object   = $policy.Name
            Detail   = "Using default/AdminOnlyAccessPolicy quarantine tag — affected recipients receive NO notification and cannot self-release"
        })
    }
}

# ---------- Detect: preset security policy targeting (always wins) ----------
Write-Status "Collecting preset security policy targeting..."
try {
    $presetRules = Get-EOPProtectionPolicyRule
    $presetRules | Select-Object Name, State, Priority, SentTo, SentToMemberOf, RecipientDomainIs, ExceptIfSentTo, ExceptIfSentToMemberOf |
        Export-Csv "$OutputPath\preset_policy_targeting.csv" -NoTypeInformation

    $enabledPresets = $presetRules | Where-Object State -eq "Enabled"
    if ($enabledPresets) {
        foreach ($p in $enabledPresets) {
            $findings.Add([PSCustomObject]@{
                Category = "PRESET_POLICY_ACTIVE"
                Object   = $p.Name
                Detail   = "Enabled preset policy — takes precedence over ALL custom Safe Links/Safe Attachments policies and Built-in protection for its targeted recipients"
            })
        }
    }
} catch {
    Write-Status "Could not query Get-EOPProtectionPolicyRule: $_" "WARN"
}

# ---------- Detect: overlapping recipient scope across enabled custom rules ----------
Write-Status "Checking for recipient-domain overlap across enabled rules (precedence ambiguity risk)..."
$slDomains = $slRules | Where-Object State -eq "Enabled" | Where-Object { $_.RecipientDomainIs } |
    Select-Object -ExpandProperty RecipientDomainIs -ErrorAction SilentlyContinue
$dupDomains = $slDomains | Group-Object | Where-Object Count -gt 1
foreach ($d in $dupDomains) {
    $findings.Add([PSCustomObject]@{
        Category = "SAFELINKS_DOMAIN_OVERLAP"
        Object   = $d.Name
        Detail   = "Domain targeted by $($d.Count) enabled Safe Links rules — only the lowest-Priority rule applies; verify intent"
    })
}

# ---------- Detect: SharePoint/OneDrive/Teams Safe Attachments state ----------
Write-Status "Checking SharePoint/OneDrive/Teams Safe Attachments toggle (separate from mail policies)..."
try {
    $atpO365 = Get-AtpPolicyForO365
    $atpO365 | Select-Object EnableATPForSPOTeamsODB | Export-Csv "$OutputPath\spo_teams_atp_state.csv" -NoTypeInformation
    if (-not $atpO365.EnableATPForSPOTeamsODB) {
        $findings.Add([PSCustomObject]@{
            Category = "SPO_TEAMS_ATP_DISABLED"
            Object   = "Tenant-wide"
            Detail   = "EnableATPForSPOTeamsODB is false — files uploaded directly to SharePoint/OneDrive/Teams are NOT scanned by Safe Attachments regardless of mail policy configuration"
        })
    }
} catch {
    Write-Status "Could not query Get-AtpPolicyForO365: $_" "WARN"
}

if (-not $SkipSPOCheck) {
    Write-Status "Checking SharePoint Online DisallowInfectedFileDownload (requires SPO connection)..."
    try {
        $spoTenant = Get-SPOTenant -ErrorAction Stop
        $spoTenant | Select-Object DisallowInfectedFileDownload | Export-Csv "$OutputPath\spo_tenant_download_block.csv" -NoTypeInformation
        if (-not $spoTenant.DisallowInfectedFileDownload) {
            $findings.Add([PSCustomObject]@{
                Category = "SPO_INFECTED_DOWNLOAD_ALLOWED"
                Object   = "Tenant-wide"
                Detail   = "DisallowInfectedFileDownload is false — users can still download files already flagged malicious by Safe Attachments for SPO/OneDrive/Teams"
            })
        }
    } catch {
        Write-Status "Not connected to SharePoint Online (Connect-SPOService) or insufficient permissions — skipping. Use -SkipSPOCheck to suppress this warning." "WARN"
    }
}

# ---------- Detect: potential upstream URL-rewriting gateway ----------
Write-Status "Checking inbound connectors for potential third-party gateway conflicts..."
try {
    $connectors = Get-InboundConnector
    $connectors | Select-Object Name, Enabled, SenderDomains, ConnectorType, TlsSenderCertificateName |
        Export-Csv "$OutputPath\inbound_connectors.csv" -NoTypeInformation

    $gatewayHints = "mimecast|proofpoint|barracuda|cisco|ironport|symantec|messagelabs|trendmicro|sophos"
    $suspectConnectors = $connectors | Where-Object {
        $_.Enabled -and ($_.Name -match $gatewayHints -or $_.TlsSenderCertificateName -match $gatewayHints)
    }
    foreach ($c in $suspectConnectors) {
        $findings.Add([PSCustomObject]@{
            Category = "POSSIBLE_UPSTREAM_GATEWAY"
            Object   = $c.Name
            Detail   = "Enabled inbound connector name/cert matches a known secure email gateway vendor pattern — verify its URL-rewriting feature isn't conflicting with Safe Links"
        })
    }
} catch {
    Write-Status "Could not query Get-InboundConnector: $_" "WARN"
}

# ---------- Report ----------
$findings | Export-Csv "$OutputPath\findings_summary.csv" -NoTypeInformation

Write-Status "----------------------------------------" "OK"
Write-Status "Audit complete: $OutputPath" "OK"
Write-Status "Total findings flagged for review: $($findings.Count)" "OK"
if ($findings.Count -gt 0) {
    $findings | Group-Object Category | Select-Object Name, Count | Sort-Object Count -Descending | Format-Table -AutoSize
}
Write-Status "Files written: $(Get-ChildItem $OutputPath | Measure-Object | Select-Object -ExpandProperty Count)" "OK"
