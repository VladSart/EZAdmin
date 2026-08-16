<#
.SYNOPSIS
    Collects Azure Front Door health — tier/migration posture, endpoint state, custom domain
    validation (with apex-domain autorotation risk flagging), origin group health, and WAF
    tier/association posture — for triage or escalation.

.DESCRIPTION
    Companion script to Azure/Networking/FrontDoor-B.md and FrontDoor-A.md.
    Gathers, in one pass, everything the runbooks' triage and diagnosis steps ask for:
    - Profile SKU (flags any surviving Front Door classic profile — retires March 31, 2027)
    - Endpoint EnabledState (a disabled endpoint fails every route on it identically)
    - Custom domain validation state, with a dedicated APEX-DOMAIN CERT-RISK flag for domains
      whose managed certificate autorotation has no CNAME to silently revalidate against
    - Route inventory — flags any custom domain NOT associated with at least one route
    - Origin group health probe configuration and origin count (flags empty origin groups)
    - Security Policy → WAF policy association, with a WAF-TIER-GAP flag when a Standard-tier
      WAF policy is associated to a domain (no managed rules/Bot Protection/JS Challenge exist
      at that tier, a frequent silent-gap misunderstanding)
    - Rule Set presence with a heads-up flag to manually review for Route Configuration Override
      actions (rule action contents aren't fully enumerable read-only without deep rule inspection)

    Produces a console summary with pass/fail per check and exports full detail to CSV,
    so the output can be pasted directly into the runbook's Escalation Evidence template.

    Does NOT cover:
    - Fixing any detected issue (that's FrontDoor-B.md Fix 1-8 / FrontDoor-A.md Playbooks 1-3 —
      this script only detects)
    - Front Door (classic) resource enumeration beyond the SKU flag itself — classic profiles use
      a different module (Az.FrontDoor) with a different object model; a classic profile found
      by this script's SKU check should be inventoried separately per FrontDoor-A.md Playbook 1
    - Application Gateway or Load Balancer (regional Layer 7/4 resources) — see
      Get-AppGatewayHealth.ps1 / Get-LoadBalancerHealth.ps1 if the ticket turns out to be regional

.PARAMETER ResourceGroupName
    Resource group to scope the audit to. If omitted, audits every Front Door profile
    the current context can see across all resource groups.

.PARAMETER ProfileName
    Specific Front Door profile name to audit. If omitted, audits every profile found in scope.

.PARAMETER ExportPath
    Path for CSV export. Default: .\FrontDoorHealth-<timestamp>.csv

.EXAMPLE
    .\Get-FrontDoorHealth.ps1
    Audits every Front Door profile visible in the current Az context.

.EXAMPLE
    .\Get-FrontDoorHealth.ps1 -ResourceGroupName rg-prod-edge -ProfileName afd-prod-01
    Audits a single named profile.

.NOTES
    Requires: Az.Cdn and Az.Network modules; Windows PowerShell 5.1+ or PowerShell 7+
    Run-as: Account with Reader (minimum) on the target resource group(s)
    Safe: Fully read-only. No profile, domain, route, origin, or WAF policy changes.
#>

[CmdletBinding()]
param(
    [string]$ResourceGroupName,

    [string]$ProfileName,

    [string]$ExportPath
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

#region ─── Preflight ──────────────────────────────────────────────────────────
Write-Status "Get-FrontDoorHealth — $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

if (-not $ExportPath) {
    $timestamp  = Get-Date -Format 'yyyyMMdd-HHmm'
    $ExportPath = ".\FrontDoorHealth-$timestamp.csv"
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Result {
    param([string]$ProfileNm, [string]$Check, [string]$Status, [string]$Detail)
    $results.Add([PSCustomObject]@{
        Profile   = $ProfileNm
        Check     = $Check
        Status    = $Status
        Detail    = $Detail
        CheckedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    })
    Write-Status "[$ProfileNm] $Check — $Detail" $Status
}

try {
    if ($ProfileName -and $ResourceGroupName) {
        $profiles = @(Get-AzFrontDoorCdnProfile -ResourceGroupName $ResourceGroupName -ProfileName $ProfileName -ErrorAction Stop)
    } elseif ($ResourceGroupName) {
        $profiles = @(Get-AzFrontDoorCdnProfile -ResourceGroupName $ResourceGroupName -ErrorAction Stop)
    } else {
        $profiles = @(Get-AzFrontDoorCdnProfile -ErrorAction Stop)
    }
} catch {
    Write-Status "Failed to enumerate Front Door profiles: $_" "ERROR"
    exit 1
}

if (-not $profiles -or $profiles.Count -eq 0) {
    Write-Status "No Front Door (Standard/Premium) profiles found in scope. Note: Front Door (classic) profiles use a different module/object model and are NOT enumerated by this script — check separately if a classic profile is suspected." "WARN"
    exit 0
}
#endregion

foreach ($fdProfile in $profiles) {
    $name = $fdProfile.Name
    $rg   = $fdProfile.ResourceGroupName

    #region ─── 1. SKU / tier ───────────────────────────────────────────────────
    if ($fdProfile.Sku.Name -like 'Classic*') {
        Add-Result $name "SKU" "ERROR" "Classic tier — retires March 31, 2027. No new domain onboarding or managed certificates possible. Flag for migration (FrontDoor-A.md Playbook 1)"
    } else {
        Add-Result $name "SKU" "OK" "$($fdProfile.Sku.Name)"
    }
    #endregion

    #region ─── 2. Endpoints ────────────────────────────────────────────────────
    $endpoints = @()
    try {
        $endpoints = @(Get-AzFrontDoorCdnEndpoint -ResourceGroupName $rg -ProfileName $name -ErrorAction Stop)
    } catch {
        Add-Result $name "Endpoints" "WARN" "Could not enumerate endpoints: $_"
    }

    foreach ($ep in $endpoints) {
        if ($ep.EnabledState -eq 'Disabled') {
            Add-Result $name "Endpoint-$($ep.Name)" "ERROR" "EnabledState=Disabled — EVERY route on this endpoint is failing identically. Confirm this wasn't an intentional incident-response action before re-enabling"
        } else {
            Add-Result $name "Endpoint-$($ep.Name)" "OK" "EnabledState=$($ep.EnabledState), Host=$($ep.HostName)"
        }
    }
    #endregion

    #region ─── 3. Custom domains — validation state + apex cert-risk flag ─────
    $domains = @()
    try {
        $domains = @(Get-AzFrontDoorCdnCustomDomain -ResourceGroupName $rg -ProfileName $name -ErrorAction Stop)
    } catch {
        Add-Result $name "CustomDomains" "WARN" "Could not enumerate custom domains: $_"
    }

    foreach ($domain in $domains) {
        $hostName = $domain.HostName
        $isApex = $false
        if ($hostName) {
            # Heuristic: an apex/root domain has exactly one dot in a standard two-label TLD
            # (contoso.com) vs. a subdomain (www.contoso.com, app.contoso.com). Not exhaustive
            # for multi-part TLDs (co.uk etc.) — flagged as best-effort, verify manually if unsure.
            $labelCount = ($hostName -split '\.').Count
            $isApex = ($labelCount -le 2)
        }

        if ($domain.DomainValidationState -ne 'Approved') {
            Add-Result $name "Domain-$hostName" "ERROR" "DomainValidationState=$($domain.DomainValidationState) — check _dnsauth TXT record; if apex domain, this may require manual re-validation (see APEX-CERT-RISK note)"
        } elseif ($isApex) {
            Add-Result $name "Domain-$hostName" "WARN" "APEX-CERT-RISK: apex/root domain (best-effort detection) — no CNAME exists for managed-certificate autorotation to revalidate against. Confirm this is on a tracked recurring manual-revalidation schedule, not assumed auto-renewing"
        } else {
            Add-Result $name "Domain-$hostName" "OK" "DomainValidationState=Approved, TlsCertificateType=$($domain.TlsCertificateType)"
        }
    }
    #endregion

    #region ─── 4. Routes — domain-to-route association gap check ──────────────
    $allRoutes = @()
    foreach ($ep in $endpoints) {
        try {
            $routes = @(Get-AzFrontDoorCdnRoute -ResourceGroupName $rg -ProfileName $name -EndpointName $ep.Name -ErrorAction Stop)
            $allRoutes += $routes
            foreach ($route in $routes) {
                $ruleSetNote = if ($route.RuleSets -and @($route.RuleSets).Count -gt 0) {
                    " — Rule Set(s) attached: MANUALLY REVIEW for a RouteConfigurationOverride action before trusting this route's static OriginGroup"
                } else { "" }
                Add-Result $name "Route-$($route.Name)" "INFO" "Endpoint=$($ep.Name), OriginGroup=$($route.OriginGroup)$ruleSetNote"
            }
        } catch {
            Write-Verbose "Could not enumerate routes for endpoint $($ep.Name): $_"
        }
    }

    $associatedDomainIds = @($allRoutes | ForEach-Object { $_.CustomDomains } | Where-Object { $_ })
    foreach ($domain in $domains) {
        $isAssociated = $associatedDomainIds -contains $domain.Id
        if (-not $isAssociated -and $domain.DomainValidationState -eq 'Approved') {
            Add-Result $name "DomainRouteGap-$($domain.HostName)" "WARN" "Domain is Approved but not associated with ANY route — validated but not actually serving traffic"
        }
    }
    #endregion

    #region ─── 5. Origin groups — probe config + empty-group check ────────────
    try {
        $originGroups = @(Get-AzFrontDoorCdnOriginGroup -ResourceGroupName $rg -ProfileName $name -ErrorAction Stop)
        foreach ($og in $originGroups) {
            $probe = $og.HealthProbeSetting
            $origins = @()
            try {
                $origins = @(Get-AzFrontDoorCdnOrigin -ResourceGroupName $rg -ProfileName $name -OriginGroupName $og.Name -ErrorAction Stop)
            } catch {
                Write-Verbose "Could not enumerate origins for group $($og.Name): $_"
            }

            if ($origins.Count -eq 0) {
                Add-Result $name "OriginGroup-$($og.Name)" "ERROR" "Zero origins configured — every request to a route using this group will fail"
            } else {
                $enabledCount = @($origins | Where-Object { $_.EnabledState -ne 'Disabled' }).Count
                if ($enabledCount -eq 0) {
                    Add-Result $name "OriginGroup-$($og.Name)" "ERROR" "All $($origins.Count) origin(s) are Disabled — origin group is effectively empty"
                } else {
                    Add-Result $name "OriginGroup-$($og.Name)" "OK" "$enabledCount of $($origins.Count) origin(s) enabled. Probe: Protocol=$($probe.ProbeProtocol), Path=$($probe.ProbePath), Method=$($probe.ProbeRequestType)"
                }
            }

            if ($probe -and $probe.ProbeRequestType -eq 'GET') {
                Add-Result $name "OriginGroup-$($og.Name)-ProbeMethod" "INFO" "Using GET for health probes — HEAD is Microsoft's recommendation to reduce origin load/cost unless the origin requires a full response to validate health"
            }
        }
    } catch {
        Add-Result $name "OriginGroups" "WARN" "Could not enumerate origin groups: $_"
    }
    #endregion

    #region ─── 6. Security Policies — WAF association + tier-gap check ────────
    try {
        $secPolicies = @(Get-AzFrontDoorCdnSecurityPolicy -ResourceGroupName $rg -ProfileName $name -ErrorAction Stop)
        if ($secPolicies.Count -eq 0) {
            Add-Result $name "SecurityPolicies" "INFO" "No Security Policy resources found — no WAF policy is associated with any domain on this profile"
        }
        foreach ($sp in $secPolicies) {
            $wafPolicyId = $sp.Parameter.WafPolicy.Id
            if ($wafPolicyId) {
                $wafRgName   = ($wafPolicyId -split '/')[4]
                $wafPolicyNm = ($wafPolicyId -split '/')[-1]
                try {
                    $wafPolicy = Get-AzFrontDoorWafPolicy -ResourceGroupName $wafRgName -Name $wafPolicyNm -ErrorAction Stop
                    if ($wafPolicy.Sku.Name -like 'Standard*') {
                        Add-Result $name "SecurityPolicy-$($sp.Name)" "WARN" "WAF-TIER-GAP: associated WAF policy '$wafPolicyNm' is Standard tier — custom rules ONLY, no managed rule set (DRS), Bot Protection, or JS Challenge exist at this tier. Confirm client expectations match actual coverage"
                    } else {
                        Add-Result $name "SecurityPolicy-$($sp.Name)" "OK" "WAF policy '$wafPolicyNm', SKU=$($wafPolicy.Sku.Name)"
                    }
                } catch {
                    Add-Result $name "SecurityPolicy-$($sp.Name)" "WARN" "Could not resolve associated WAF policy '$wafPolicyNm': $_"
                }
            }
        }
    } catch {
        Add-Result $name "SecurityPolicies" "WARN" "Could not enumerate security policies: $_"
    }
    #endregion
}

#region ─── Summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── Front Door Health Summary ─────────────────────────" -ForegroundColor Cyan
$errorCount = ($results | Where-Object { $_.Status -eq "ERROR" }).Count
$warnCount  = ($results | Where-Object { $_.Status -eq "WARN" }).Count

Write-Host "  Profiles audited : $($profiles.Count)"
Write-Host "  Checks run       : $($results.Count)"
Write-Host "  Errors           : $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Green" })
Write-Host "  Warnings         : $warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })

if ($errorCount -eq 0 -and $warnCount -eq 0) {
    Write-Host "  Overall: All audited Front Door profiles look healthy." -ForegroundColor Green
} else {
    Write-Host "  Overall: Issues found — see FrontDoor-B.md fix paths matching the failed checks above." -ForegroundColor Yellow
}
Write-Host ""
#endregion

#region ─── Export ──────────────────────────────────────────────────────────────
$results | Export-Csv -Path $ExportPath -NoTypeInformation -Encoding UTF8
Write-Status "Exported → $ExportPath" "OK"
Write-Status "Done — $(Get-Date -Format 'yyyy-MM-dd HH:mm')" "OK"
#endregion
