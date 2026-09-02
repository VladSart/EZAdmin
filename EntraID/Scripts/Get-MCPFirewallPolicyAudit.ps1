<#
.SYNOPSIS
    Read-only readiness and configuration audit for the Microsoft Entra Global
    Secure Access MCP firewall (Preview) — the dependency chain, MCP filtering
    policy/rule inventory, and filtering-profile/Conditional-Access linkage.

.DESCRIPTION
    The MCP firewall enforces nothing unless a specific chain is fully wired:
    Internet Access forwarding profile enabled -> TLS inspection enabled ->
    MCP filtering policy authored -> policy linked to a filtering profile ->
    filtering profile referenced by an ENFORCED (not report-only) Conditional
    Access policy. A gap anywhere in this chain produces the same symptom from
    an end user's perspective ("nothing happened") with no error surfaced
    anywhere, so this script walks the whole chain and reports exactly where
    it breaks.

    Because this is a Preview (September 2026) capability, Microsoft's own
    configuration guide is portal-driven with no documented typed Graph
    PowerShell cmdlet set for MCP policy CRUD. This script therefore uses
    Invoke-MgGraphRequest against the confirmed beta REST endpoints
    (/beta/networkAccess/forwardingProfiles, /filteringPolicies,
    /filteringProfiles) rather than assuming a typed cmdlet surface that may
    not exist in the installed module version. TLS inspection state has no
    confirmed stable read-only Graph endpoint at time of writing and is
    flagged for manual portal verification rather than guessed at.

    Analysis flags applied:
      INTERNET_PROFILE_DISABLED  - Internet Access forwarding profile is
                                    disabled. MCP traffic never reaches GSA at
                                    all, let alone the MCP firewall specifically.
      TLS_INSPECTION_UNVERIFIED  - Script cannot confirm TLS inspection state
                                    via Graph; flagged for manual portal check.
                                    Without it, MCP payload is unparseable.
      NO_MCP_POLICY_FOUND        - No filtering policy matching MCP naming/type
                                    heuristics was found in the tenant.
      POLICY_NOT_LINKED          - An MCP-like policy exists but is not linked
                                    to any filtering profile — enforces on zero
                                    traffic regardless of how correct its rules
                                    are.
      POLICY_ZERO_RULES          - Policy is linked but has no rules — with
                                    Default action = Allow this is a silent
                                    no-op; with Block this blocks everything.
      PROFILE_NOT_IN_CA          - A filtering profile with a linked MCP policy
                                    is not referenced by any Conditional Access
                                    policy's session control — configured but
                                    never invoked for any session.
      CA_REPORT_ONLY             - The Conditional Access policy referencing
                                    the relevant profile is in report-only mode
                                    — visibility only, no active enforcement.

    Read-only. Makes no changes to any profile, policy, rule, or Conditional
    Access policy.

    Does NOT cover:
    - TLS inspection true state (portal-only at time of writing — flagged, not
      determined, by this script)
    - Per-device client health / root CA trust — see GlobalSecureAccess-A.md
      Validation Steps and Get-GlobalSecureAccessHealth.ps1
    - Generative AI Insights traffic content (which servers/tools were
      actually observed) — portal-only surface, not exposed via a confirmed
      stable Graph endpoint for this audit
    - Tool/resource/prompt-level rule detail beyond what the policyRules Graph
      response returns (Microsoft's own documented UI-rendering limitation
      applies to the portal, not to this script's Graph-sourced output)

.PARAMETER PolicyNameFilter
    Substring used to identify MCP-related filtering policies by name, since
    no confirmed stable "policyType eq mcp" server-side filter exists yet.
    Default: "MCP"

.PARAMETER OutputPath
    Directory where CSV reports will be written.
    Default: .\MCPFirewall-Audit-<timestamp>\

.EXAMPLE
    .\Get-MCPFirewallPolicyAudit.ps1

    Full tenant-wide MCP firewall readiness/configuration audit using default
    policy-name matching.

.EXAMPLE
    .\Get-MCPFirewallPolicyAudit.ps1 -PolicyNameFilter "AgentTraffic"

    Same audit against MCP policies that don't follow the default "MCP"
    naming convention.

.NOTES
    Requires: Microsoft.Graph.Beta PowerShell SDK
              (Install-Module Microsoft.Graph.Beta -Scope CurrentUser)
    Scopes needed: NetworkAccess.Read.All, Policy.Read.All
    Run As: Global Reader, Security Reader, or Global Administrator (read only)
    Safe: Read-only — no forwarding profiles, filtering policies/profiles, or
          Conditional Access policies are changed
    Cross-references: EntraID/Troubleshooting/MCPFirewall-A.md (Dependency
                       Stack, Symptom -> Cause Map, Validation Steps),
                       MCPFirewall-B.md (Triage, Fix 2/4/5),
                       Get-GlobalSecureAccessHealth.ps1 (base-tunnel layer —
                       run that script first if the Internet Access profile
                       itself is unhealthy)
#>

[CmdletBinding()]
param(
    [string]$PolicyNameFilter = "MCP",

    [string]$OutputPath = ".\MCPFirewall-Audit-$(Get-Date -Format 'yyyyMMdd-HHmm')"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

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

function Invoke-GraphGetAll {
    <# Minimal $odata.nextLink-following GET wrapper for beta networkAccess endpoints #>
    param([string]$Uri)
    $results = New-Object System.Collections.Generic.List[object]
    $next = $Uri
    while ($next) {
        $resp = Invoke-MgGraphRequest -Method GET -Uri $next -ErrorAction Stop
        if ($resp.value) { $results.AddRange([object[]]$resp.value) }
        $next = $resp.'@odata.nextLink'
    }
    return $results
}

# --- Connect ---
try {
    $context = Get-MgContext
    if (-not $context) {
        Write-Status "Connecting to Microsoft Graph (beta)..." "INFO"
        Connect-MgGraph -Scopes "NetworkAccess.Read.All", "Policy.Read.All" -NoWelcome
    }
} catch {
    Write-Status "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "ERROR"
    return
}

if (-not (Get-Command Invoke-MgGraphRequest -EA SilentlyContinue)) {
    Write-Status "Microsoft.Graph(.Beta) module not found. Install with:" "ERROR"
    Write-Status "  Install-Module Microsoft.Graph.Beta -Scope CurrentUser" "ERROR"
    return
}

if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }

$findings = New-Object System.Collections.Generic.List[object]

# --- 1. Internet Access forwarding profile (base-layer prerequisite) ---
Write-Status "Checking Internet Access traffic forwarding profile..." "INFO"
$internetProfile = $null
try {
    $forwardingProfiles = Invoke-GraphGetAll -Uri "https://graph.microsoft.com/beta/networkAccess/forwardingProfiles"
    $internetProfile = $forwardingProfiles | Where-Object trafficForwardingType -eq "internet"
} catch {
    Write-Status "Failed to retrieve forwarding profiles: $($_.Exception.Message)" "ERROR"
}

if (-not $internetProfile) {
    $findings.Add([pscustomobject]@{
        Flag = "INTERNET_PROFILE_DISABLED"; Severity = "CRITICAL"
        Object = "(not found)"
        Detail = "No Internet Access forwarding profile found — MCP traffic cannot reach GSA at all."
    })
} elseif ($internetProfile.state -ne "enabled") {
    $findings.Add([pscustomobject]@{
        Flag = "INTERNET_PROFILE_DISABLED"; Severity = "CRITICAL"
        Object = $internetProfile.name
        Detail = "Internet Access profile state = '$($internetProfile.state)'. MCP traffic (and all other internet traffic) is untunneled until this is enabled."
    })
    Write-Status "Internet Access profile is DISABLED — this alone blocks the entire MCP firewall from seeing any traffic." "WARN"
} else {
    Write-Status "Internet Access profile is enabled." "OK"
}

# --- 2. TLS inspection (flag for manual check — no confirmed stable read endpoint) ---
$findings.Add([pscustomobject]@{
    Flag = "TLS_INSPECTION_UNVERIFIED"; Severity = "ACTION_REQUIRED"
    Object = "(manual check required)"
    Detail = "No confirmed stable read-only Graph endpoint for TLS inspection policy state at time of writing. Verify manually: Global Secure Access > Secure > TLS inspection policy > State = Enabled. Without this, the MCP firewall cannot parse any MCP traffic regardless of every other setting below."
})
Write-Status "TLS inspection state cannot be verified via Graph in this script version — verify manually in the portal (see finding above)." "WARN"

# --- 3. MCP filtering policy discovery ---
Write-Status "Retrieving filtering policies (beta) and matching against '$PolicyNameFilter'..." "INFO"
$allPolicies = @()
try {
    $allPolicies = Invoke-GraphGetAll -Uri "https://graph.microsoft.com/beta/networkAccess/filteringPolicies"
} catch {
    Write-Status "Failed to retrieve filtering policies: $($_.Exception.Message)" "ERROR"
}

$mcpPolicies = $allPolicies | Where-Object { $_.name -like "*$PolicyNameFilter*" }

if (-not $mcpPolicies -or $mcpPolicies.Count -eq 0) {
    $findings.Add([pscustomobject]@{
        Flag = "NO_MCP_POLICY_FOUND"; Severity = "WARN"
        Object = "(none)"
        Detail = "No filtering policy matched name filter '$PolicyNameFilter'. If an MCP policy exists under a different name, re-run with -PolicyNameFilter, or confirm in the portal under Global Secure Access > Secure > MCP policies (Preview)."
    })
    Write-Status "No policy matched '$PolicyNameFilter' by name. Re-run with -PolicyNameFilter if your MCP policy uses different naming." "WARN"
}

# --- 4. Filtering profiles + link check ---
Write-Status "Retrieving filtering profiles and policy links..." "INFO"
$filteringProfiles = @()
try {
    $filteringProfiles = Invoke-GraphGetAll -Uri "https://graph.microsoft.com/beta/networkAccess/filteringProfiles?`$expand=policies"
} catch {
    Write-Status "Failed to retrieve filtering profiles: $($_.Exception.Message)" "ERROR"
}

# --- 5. Conditional Access policies referencing a GSA filtering profile ---
Write-Status "Retrieving Conditional Access policies with a GSA session control..." "INFO"
$caPolicies = @()
try {
    $caResp = Invoke-GraphGetAll -Uri "https://graph.microsoft.com/beta/identity/conditionalAccess/policies"
    $caPolicies = $caResp | Where-Object { $_.sessionControls.globalSecureAccessFilteringProfile.isEnabled -eq $true }
} catch {
    Write-Status "Failed to retrieve Conditional Access policies: $($_.Exception.Message)" "ERROR"
}

$policyResults = foreach ($policy in $mcpPolicies) {

    # Rules
    $ruleCount = 0
    try {
        $rulesResp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/networkAccess/filteringPolicies/$($policy.id)/policyRules" -ErrorAction Stop
        $ruleCount = @($rulesResp.value).Count
    } catch {
        Write-Status "  Could not retrieve rules for policy '$($policy.name)': $($_.Exception.Message)" "WARN"
    }

    if ($ruleCount -eq 0) {
        $findings.Add([pscustomobject]@{
            Flag = "POLICY_ZERO_RULES"; Severity = "WARN"
            Object = $policy.name
            Detail = "Policy has zero rules. With a Block default action this blocks everything MCP; with Allow this is a silent no-op that filters nothing."
        })
    }

    # Which profile(s), if any, link this policy
    $linkingProfiles = $filteringProfiles | Where-Object { $_.policies.id -contains $policy.id }

    if (-not $linkingProfiles -or $linkingProfiles.Count -eq 0) {
        $findings.Add([pscustomobject]@{
            Flag = "POLICY_NOT_LINKED"; Severity = "CRITICAL"
            Object = $policy.name
            Detail = "Policy is not linked to any filtering profile ('Security profile' in the portal). It enforces on zero traffic no matter how correct its rules are. Fix: Security profiles > Link policies > + Link a policy > Existing MCP policy."
        })
    }

    foreach ($fp in $linkingProfiles) {
        $referencingCA = $caPolicies | Where-Object {
            $_.sessionControls.globalSecureAccessFilteringProfile.securityProfileId -eq $fp.id
        }

        if (-not $referencingCA -or $referencingCA.Count -eq 0) {
            $findings.Add([pscustomobject]@{
                Flag = "PROFILE_NOT_IN_CA"; Severity = "CRITICAL"
                Object = $fp.name
                Detail = "Filtering profile '$($fp.name)' (linked to MCP policy '$($policy.name)') is not referenced by any Conditional Access policy's session control. Configured but never invoked for any user session."
            })
        } else {
            foreach ($ca in $referencingCA) {
                if ($ca.state -ne "enabled") {
                    $findings.Add([pscustomobject]@{
                        Flag = "CA_REPORT_ONLY"; Severity = "WARN"
                        Object = $ca.displayName
                        Detail = "Conditional Access policy '$($ca.displayName)' references filtering profile '$($fp.name)' but state = '$($ca.state)'. Report-only mode logs violations but blocks nothing."
                    })
                }
            }
        }

        [pscustomobject]@{
            PolicyName          = $policy.name
            PolicyId            = $policy.id
            RuleCount           = $ruleCount
            LinkedProfileName   = $fp.name
            LinkedProfileState  = $fp.state
            EnforcingCAPolicies = ($referencingCA | ForEach-Object { "$($_.displayName) [$($_.state)]" }) -join "; "
        }
    }

    if (-not $linkingProfiles -or $linkingProfiles.Count -eq 0) {
        [pscustomobject]@{
            PolicyName          = $policy.name
            PolicyId            = $policy.id
            RuleCount           = $ruleCount
            LinkedProfileName   = "(none)"
            LinkedProfileState  = "(n/a)"
            EnforcingCAPolicies = "(n/a — policy not linked)"
        }
    }
}

$policyResults | Export-Csv "$OutputPath\mcp_policy_chain.csv" -NoTypeInformation
$findings | Export-Csv "$OutputPath\findings.csv" -NoTypeInformation

# --- Summary ---
Write-Host ""
Write-Status "=== MCP Firewall Readiness Summary ===" "INFO"
$critical = @($findings | Where-Object Severity -eq "CRITICAL").Count
$warn     = @($findings | Where-Object Severity -eq "WARN").Count
$action   = @($findings | Where-Object Severity -eq "ACTION_REQUIRED").Count

Write-Status "Critical findings (breaks enforcement entirely): $critical" $(if ($critical -gt 0) { "ERROR" } else { "OK" })
Write-Status "Warnings (partial/degraded coverage risk): $warn" $(if ($warn -gt 0) { "WARN" } else { "OK" })
Write-Status "Manual verification required (no stable Graph endpoint yet): $action" "WARN"
Write-Status "Reports written to: $OutputPath" "INFO"

if ($critical -eq 0 -and $warn -eq 0) {
    Write-Status "MCP policy -> profile -> Conditional Access chain looks fully wired. Still confirm TLS inspection manually (see findings.csv)." "OK"
}
