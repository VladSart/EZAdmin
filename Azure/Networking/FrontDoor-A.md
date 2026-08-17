# Azure Front Door — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains the global-edge routing/security model, not just the fix commands.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps (by phase)](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

**In scope:**
- Azure Front Door Standard and Premium (the only tiers that can still be created — `Az.Cdn` module cmdlets)
- Front Door (classic) — covered only for identification and migration guidance, since it retires March 31, 2027
- Global-edge routing: profiles, endpoints, origin groups/origins, routes, and route matching (host/path precedence)
- Health probes and origin failover behavior
- Custom domains and certificate provisioning/autorotation (managed and BYO certificate, subdomain and apex)
- Web Application Firewall (WAF) on Front Door — the security policy resource model, tier-gated capability differences, and rule evaluation order
- Rule Sets and the Route Configuration Override action
- Caching and purge behavior at a conceptual level

**Out of scope:**
- **Azure Application Gateway** — regional Layer 7 reverse proxy, covered in `AppGateway-A.md`/`AppGateway-B.md`. Front Door and Application Gateway are frequently deployed together (Front Door globally, Application Gateway as an origin per region) — see the disambiguation in Learning Pointers.
- **Azure Load Balancer** — regional Layer 4, covered in `LoadBalancer-A.md`/`LoadBalancer-B.md`. Architecturally unrelated to Front Door beyond both being traffic-distribution resources.
- **Azure Traffic Manager** — DNS-based global traffic distribution, a different mechanism entirely (no proxying, no caching, no WAF; just DNS responses). Referenced only where a client might be choosing between the two.
- **CDN-specific rules engine actions beyond routing/security** (image optimization, compression tuning, advanced rule set actions for URL rewrite/redirect) — the Rule Set engine is documented here only as far as the Route Configuration Override behavior that affects routing/origin selection; the full rules engine action catalog is a possible future topic if ticket volume justifies it.
- **Private Link origins** — Premium-tier support for privately connecting to an origin (Storage, App Service, or an internal Load Balancer) without public exposure; now its own dedicated topic — see `FrontDoorPrivateLink-A.md`/`FrontDoorPrivateLink-B.md`.

**Assumptions:**
- Standard or Premium tier (or a Classic profile being assessed for migration)
- Reader has CDN Profile Contributor or higher on the resource group
- At least one endpoint, one origin group with a real origin, and one route already exist

---

## How It Works

<details><summary>Full architecture</summary>

### The Resource Hierarchy

```
Profile (Standard or Premium — the billing/management boundary)
    │
    ├── Endpoint (one or more; each gets its own *.azurefd.net / *.z0N.azurefd.net hostname)
    │       │
    │       └── Route (protocol + domain + path → origin group; caching config lives here too)
    │
    ├── Origin Group (health probe settings + load-balancing settings live here)
    │       │
    │       └── Origin(s) (the actual backend — App Service, Storage, a Load Balancer/App Gateway IP,
    │                       an on-prem endpoint, or a Private Link target on Premium)
    │
    ├── Custom Domain (validated separately from any route; a route then associates it)
    │
    ├── Security Policy (associates a WAF policy — a SEPARATE resource type — to one or more domains)
    │
    └── Rule Set (optional; ordered rules with match conditions and actions, attached to one or more routes)
```

A **WAF policy** (`Microsoft.Network/FrontDoorWebApplicationFirewallPolicies`) is its own independent Azure resource, authored and versioned separately from the Front Door profile. It has no effect on any traffic until associated to a domain via a **Security Policy** resource — an extra indirection layer that doesn't exist in Application Gateway, where the WAF policy attaches directly to the gateway/listener/path. Forgetting this middle resource is a common "I created a WAF policy and nothing changed" report.

### Route Matching — Exact Host, Most-Specific Path

Front Door evaluates every incoming request against the "left-hand side" of every route: protocol, domain (frontend host), and path, in that order, always resolving to the **most-specific match**.

**Frontend host matching is exact-match only.** Front Door checks for a route with an exact match on the requested host. If none exists, the request is rejected with a 404 — there is no host-wildcard fallback (`*.contoso.com` catching every unconfigured subdomain the way a path's `/*` catches every unconfigured path). Each hostname a client wants served needs its own route/domain association, full stop.

**Path matching, once the host resolves, follows a strict precedence:**
1. Exact match beats a wildcard.
2. Among wildcards, the longest/most-specific matching prefix wins.
3. A path ending in `/` is itself an exact-match path, distinct from the same path without the trailing slash.
4. `*` is only valid as the final character of a path, and must be preceded by `/` — `/foo*` is invalid, `/foo/*` is valid.

This produces some genuinely non-obvious results worth internalizing before debugging a "wrong content served" ticket: given routes for `/`, `/*`, `/abc`, `/abc/`, and `/abc/*` all on the same host, a request for `/abc/def` matches `/abc/*` (not `/*`, despite `/*` technically matching too — specificity wins), while `/abc/` (trailing slash, no further path) matches the exact-match `/abc/` route, not `/abc/*`.

### Route Configuration Override — A Second, Higher-Precedence Routing Decision

Once a route matches, Front Door checks whether a **Rule Set** attached to that route contains a rule whose action is `RouteConfigurationOverride`. If one matches, its origin group selection (and other routing behavior it specifies) takes precedence over the route's own static configuration for that request. This is a deliberately powerful feature — for A/B testing, canary releases, or header/geo-based origin selection — but it means the route object's own configuration is not always the full story, and reviewing only the route without checking for an attached Rule Set can lead to "the config says X but the behavior is Y" confusion.

### Health Probes and the Three-Step Health Determination

Each Front Door edge location independently sends synthetic HTTP/HTTPS probes to every origin in a group, using the same TCP port configured for routing traffic (not separately overridable), with a `User-Agent: Edge Health Probe` header. **GET or HEAD** are the supported methods; HEAD is the default for new profiles and Microsoft's own recommendation, since it avoids the origin generating and returning a full response body for every probe — meaningful at the probe volumes global edge infrastructure generates (roughly `edge_location_count × 2` probes per minute at the default 30-second interval, scaled down if a given edge location isn't receiving real client traffic).

Health determination is a three-step process, evaluated per origin group:
1. **Exclude disabled origins** from consideration entirely.
2. **Exclude origins failing their probe health check** — evaluated over the last `SampleSize` probe responses, healthy if at least `SuccessfulSamplesRequired` of them succeeded (both configurable on the origin group's load-balancing settings; only a non-2xx response, a timeout, or a connection failure counts as a probe failure).
3. **Among the remaining healthy origins, rank by measured latency** (wall-clock time from request-sent to last-byte-received, using a fresh TCP connection each time — not biased toward an origin with an existing warm connection) and route accordingly, respecting configured origin priority/weight.

**If every origin in a group fails its probe simultaneously, Front Door does not fail closed.** It treats the entire group as unhealthy and falls back to round-robin distribution across all origins regardless of their failed probe state, resuming normal latency-based routing the moment any origin recovers. This is the same fail-open philosophy as Azure Load Balancer's UDP-flow behavior and Application Gateway's backend pool handling — worth flagging explicitly to a client, since it means a genuine full-outage at the origin layer can present as "still up, just erratic" rather than a clean, unambiguous failure.

### Custom Domains, Validation, and the Apex Domain Certificate Trap

Adding a custom domain to Front Door requires two independent DNS records, serving two different purposes:

1. **Domain ownership validation** — a TXT record named `_dnsauth.<subdomain>` (or `_dnsauth` at the apex) with a value Front Door generates. This proves control of the domain and must be approved before the domain can be associated with any route.
2. **Traffic routing (+ managed certificate issuance path)** — for a non-apex domain, a CNAME record pointing the domain at the endpoint's `*.azurefd.net` hostname. Managed TLS certificate issuance and **autorotation** both ride on this CNAME being present and pointing at Front Door.

**Apex/root domains cannot have a CNAME** — it's a DNS protocol constraint (a zone apex can only carry an SOA/NS/A/AAAA/ALIAS-style record, never a CNAME), so apex domains are onboarded via an ALIAS/ANAME record instead (Azure DNS supports this natively; Microsoft's own guidance is to host apex domains in Azure DNS specifically for this reason). Traffic routes correctly, but **the managed certificate's autorotation mechanism has no CNAME to re-verify domain ownership against at renewal time**, and silently fails to auto-renew — requiring a human to manually re-approve domain validation before the existing certificate expires. This is a scheduled operational task for any apex domain on Front Door, not a one-time setup step, and is easy to miss since nothing alerts proactively beyond the certificate's own expiry approaching.

### WAF on Front Door — Tier Is a Hard Capability Ceiling, Not a Setting

A WAF policy's `policyType` is fixed at creation to either `Microsoft.Network/FrontDoorWebApplicationFirewallPolicies` (Front Door) or the Application Gateway equivalent — the two are not interchangeable resources despite superficially similar portal experiences, and a Front Door WAF policy cannot be associated with an Application Gateway or vice versa.

**Standard tier Front Door WAF supports custom rules only.** There is no managed rule set (the Default Rule Set / DRS, currently at 2.1, providing OWASP-style signature-based protection), no Bot Protection (good/bad/unknown bot classification via the Bot Manager rule set), and no JavaScript Challenge — all three require **Premium**. This is a genuinely easy trap: a client provisions Standard because it's cheaper, associates a WAF policy, sees "WAF: Enabled" in the portal, and reasonably assumes baseline OWASP protection is active. It isn't, and nothing in the configuration surfaces this as a gap — only the tier itself gates it.

**Evaluation order**, once a request reaches an active WAF policy, is fixed: **custom rules → rate-limit rules → Bot Protection → managed rules (DRS, with anomaly scoring)**. A custom rule with an explicit Allow/Block action can therefore short-circuit before a managed-rule finding is ever evaluated — useful for deliberate exclusions, but also a common source of "why didn't the managed rule catch this" confusion when an overly broad custom rule matched first.

### Caching

Caching is configured per route, keyed by the request URL (with configurable query-string caching behavior: ignore, include all, or include a specified allow-list). Cache-Control/Expires response headers from the origin govern TTL when caching is enabled. Serving stale content after an origin change is expected behavior, not a fault — resolved via a manual purge (`Clear-AzFrontDoorCdnEndpointContent`, scoped by path or wildcard) or by tuning cache duration/query-string handling for content that changes frequently.

</details>

---

## Dependency Stack

```
Profile (Standard/Premium — Classic retires March 31, 2027, no new domains/certs from then on)
    │
Endpoint EnabledState = Enabled (a disabled endpoint fails EVERY route on it identically)
    │
Custom domain DomainValidationState = Approved
    ├─ Non-apex: _dnsauth TXT record (ownership) + CNAME to the endpoint (routing + managed-cert issuance/autorotation)
    └─ Apex: _dnsauth TXT record only — NO CNAME possible; managed-cert AUTOROTATION silently fails at
       renewal and needs manual re-validation (recurring operational task, not one-time setup)
    │
Route: protocol → EXACT host match (no wildcard-host fallback) → most-specific PATH match
    │
[If Rule Set attached] check for a RouteConfigurationOverride action — can redirect to a
    DIFFERENT origin group than the route's own static association, evaluated AFTER normal matching
    │
[If Security Policy associates a WAF policy] tier gates capability:
    Standard = custom rules only | Premium = custom + managed rules (DRS) + Bot Protection + JS Challenge
    Evaluation order: custom → rate-limit → bot protection → managed rules
    │
Origin group health probe (HTTP/HTTPS, HEAD default) — 3-step: exclude disabled →
    exclude SampleSize/SuccessfulSamplesRequired failures → latency-rank survivors
    ALL origins failing = fail-OPEN round robin, not fail-closed
    │
Origin responds within timeout → cached per route config (if enabled) or passed through
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| A specific subdomain 404s while others on the same profile work fine | No route explicitly matches that EXACT host — no wildcard-host fallback exists | Confirm a route/domain association exists for that literal hostname |
| Custom domain stuck `Pending`/`PendingRevalidation` | Missing/incorrect `_dnsauth` TXT record, or (apex domain) autorotation revalidation never completed | Check `ValidationProperties` for the exact expected TXT value; confirm apex-vs-subdomain handling |
| Apex domain's HTTPS suddenly breaks with no recent config change | Managed certificate autorotation failed silently — apex domains have no CNAME to revalidate ownership against | Check certificate expiry date and `DomainValidationState`; manually re-approve validation |
| Origin group shows all origins Unhealthy, app works when hit directly | Probe path/protocol mismatch, or origin-side firewall/WAF blocking Front Door's probe source | Check `HealthProbeSettings`; validate `X-Azure-FDID` header handling instead of IP allow-listing |
| Traffic still flows during a confirmed full-origin-group outage, just erratically | Fail-open round-robin behavior when every origin fails its probe — by design, not a bug | Confirm via `Get-AzFrontDoorCdnOriginGroup` health state; explain the fail-open model to the client |
| WAF policy is associated and shows Enabled, but nothing beyond custom rules is blocking | Standard tier — no managed rule set, Bot Protection, or JS Challenge exists at this tier | Check `Sku` on the profile; this is a tier ceiling, not a rule misconfiguration |
| A specific path or condition routes to an unexpected origin group despite the route object looking correct | A Rule Set attached to the route contains a `RouteConfigurationOverride` action | Review every rule in the attached Rule Set, not just the route's own static config |
| Content changed at the origin but Front Door keeps serving the old version | Expected caching behavior per the route's TTL/query-string config | Purge via `Clear-AzFrontDoorCdnEndpointContent`, or tune cache duration for frequently-changing content |
| A client wants to onboard a new domain or fix a stuck certificate on a Classic profile | Classic retiring March 31, 2027 — new domain onboarding/managed certs are a platform wall, not a config issue | Confirm `Sku`; this requires a migration to Standard/Premium, not a fix |
| "I created a WAF policy and nothing changed" | WAF policy is a separate resource with zero effect until associated to a domain via a Security Policy resource | Check `Get-AzFrontDoorCdnSecurityPolicy` for the actual domain association, not just the WAF policy's own existence |

---

## Validation Steps

**1. Confirm tier and profile health first:**
```powershell
Get-AzFrontDoorCdnProfile -ResourceGroupName <rg> -ProfileName <profileName> | Select-Object Sku, ResourceState
```
Expected: `Sku` is `Standard_AzureFrontDoor` or `Premium_AzureFrontDoor`. A `Classic_*` result is an immediate migration flag (Playbook 1), not something to troubleshoot as if it had Standard/Premium capabilities.

**2. Confirm every endpoint on the profile is enabled:**
```powershell
Get-AzFrontDoorCdnEndpoint -ResourceGroupName <rg> -ProfileName <profileName> |
    Select-Object EndpointName, EnabledState, HostName, ProvisioningState
```

**3. Confirm custom domain validation state and, if HTTPS-related, apex-vs-subdomain handling:**
```powershell
Get-AzFrontDoorCdnCustomDomain -ResourceGroupName <rg> -ProfileName <profileName> -CustomDomainName <domainName> |
    Select-Object DomainValidationState, TlsCertificateType, ValidationProperties
```
Expected: `DomainValidationState = Approved`. For an apex domain, confirm the certificate's expiry date isn't approaching without a corresponding recent re-validation.

**4. Confirm the route's exact-host and most-specific-path configuration matches what's actually being requested:**
```powershell
Get-AzFrontDoorCdnRoute -ResourceGroupName <rg> -ProfileName <profileName> -EndpointName <endpointName> -Name <routeName> |
    Select-Object CustomDomains, PatternsToMatch, OriginGroup, RuleSets
```
Expected: The reported hostname appears in `CustomDomains` (exact match), and the reported path falls under one of `PatternsToMatch`.

**5. If a Rule Set is attached, check every rule for a Route Configuration Override:**
```powershell
Get-AzFrontDoorCdnRule -ResourceGroupName <rg> -ProfileName <profileName> -RuleSetName <ruleSetName> -RuleName <ruleName> |
    Select-Object Action, MatchCondition
```

**6. Confirm origin group health and probe configuration:**
```powershell
Get-AzFrontDoorCdnOriginGroup -ResourceGroupName <rg> -ProfileName <profileName> -OriginGroupName <originGroupName> |
    Select-Object HealthProbeSettings, LoadBalancingSettings
```
Expected: `HealthProbeSettings.ProbePath`/`ProbeProtocol` match what the origin actually serves at that path/protocol.

**7. If a WAF policy is in scope, confirm tier before assuming managed-rule behavior is available:**
```powershell
Get-AzFrontDoorWafPolicy -ResourceGroupName <rg> -Name <wafPolicyName> | Select-Object Sku, ManagedRules, Customrules
Get-AzFrontDoorCdnSecurityPolicy -ResourceGroupName <rg> -ProfileName <profileName> -SecurityPolicyName <policyName>
```
Expected: `Sku` on the WAF policy matches the profile's own tier expectation, and the Security Policy resource actually associates the WAF policy with the domain(s) in question.

---

## Troubleshooting Steps (by phase)

### Phase 1: Profile and Tier Health

1. Confirm `Sku` — flag any `Classic_*` profile for migration before investigating further as if it had Standard/Premium capability.
2. Confirm `ResourceState`/`ProvisioningState` on the profile and endpoint are both healthy, not mid-operation or Failed.

### Phase 2: Domain and Certificate

1. Confirm `DomainValidationState = Approved`.
2. If Pending, check the exact `_dnsauth` TXT record value against DNS — allow up to 10 minutes for propagation after a correction.
3. If apex domain and cert-related, check certificate expiry proactively rather than waiting for a client-reported outage — apex autorotation failure is silent until the cert actually expires.

### Phase 3: Routing

1. Confirm the exact frontend host requested has a route explicitly associating it — no host-wildcard fallback exists.
2. Confirm path specificity resolves to the intended route (exact > longest-wildcard-prefix > shorter wildcard).
3. If a Rule Set is attached to the matched route, check every rule for a `RouteConfigurationOverride` action before trusting the route's own static origin group association.

### Phase 4: Origin Health

1. Confirm probe protocol/path/method actually matches what the origin serves — mismatches read as Unhealthy even when the origin itself is fine.
2. Confirm nothing origin-side (WAF, NSG, app-layer firewall) is blocking Front Door's own probe traffic; validate using the `X-Azure-FDID` header rather than attempting IP-based allow-listing.
3. If ALL origins in a group show Unhealthy simultaneously, remember Front Door fails open (round robin across all) rather than returning a clean error — a client reporting "it's up but flaky" during a real full-outage is consistent with this behavior, not evidence the outage isn't real.

### Phase 5: WAF (if in scope)

1. Confirm the WAF policy is actually associated to the domain via a Security Policy resource — policy existence alone has zero effect.
2. Confirm tier before promising or troubleshooting managed-rule/Bot Protection/JS Challenge behavior — these don't exist on Standard.
3. If a legitimate request is being blocked, check evaluation order (custom → rate-limit → bot → managed) to identify which layer actually fired before authoring an exclusion.

### Phase 6: Disambiguation from Application Gateway / Load Balancer

1. Confirm the reported symptom is genuinely global-edge (multi-region latency routing, edge caching, a `*.azurefd.net` hostname involved) rather than a regional Layer 7/4 concern misattributed to "Front Door" because it's the most recently deployed or most visible resource.
2. A client describing per-region backend health or a specific data center's Application Gateway/Load Balancer behavior should be routed to `AppGateway-A.md`/`LoadBalancer-A.md` instead.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Migrate a Front Door (classic) profile to Standard/Premium</summary>

Classic retires **March 31, 2027** — no new profile creation, domain onboarding, or managed certificates from that point. Treat discovery of a Classic profile as a scheduled migration, not an in-place fix.

```powershell
# 1. Inventory the Classic profile's current configuration before starting
Get-AzFrontDoorCdnProfile -ResourceGroupName <rg> -ProfileName <classicProfileName>
# (Classic uses the older Az.FrontDoor module cmdlets for backend pools/routing rules —
#  Get-AzFrontDoor, Get-AzFrontDoorBackendPool, Get-AzFrontDoorRoutingRule — inventory via those)

# 2. Use Microsoft's guided in-place migration tooling (portal-driven "Migrate to Front Door Standard/Premium"
#    wizard, or the documented API-based migration) rather than a manual side-by-side rebuild — this path
#    is specifically designed to preserve the existing *.azurefd.net endpoint hostname, avoiding a DNS
#    cutover for any client still pointed at the raw Front Door hostname rather than a custom domain.
#    See: https://learn.microsoft.com/en-us/azure/frontdoor/migrate-tier

# 3. After migration, re-validate every custom domain and re-confirm WAF policy associations —
#    these do not always carry over automatically depending on migration path chosen.
```

**Rollback:** Microsoft's migration tooling supports keeping the Classic profile intact until the Standard/Premium profile is validated and cut over — do not delete the Classic profile until custom domain validation, WAF, and origin health are all confirmed on the new profile.

</details>

<details><summary>Playbook 2 — Onboard a new custom domain (subdomain and apex) end-to-end</summary>

```powershell
# 1. Add the custom domain resource to the profile
New-AzFrontDoorCdnCustomDomain -ResourceGroupName <rg> -ProfileName <profileName> -CustomDomainName <domainName> `
    -HostName <fqdn> -TlsSettingCertificateType ManagedCertificate

# 2. Retrieve the generated TXT validation value
(Get-AzFrontDoorCdnCustomDomain -ResourceGroupName <rg> -ProfileName <profileName> -CustomDomainName <domainName>).ValidationProperties

# 3. Create the DNS records:
#    - Non-apex: _dnsauth.<subdomain> TXT record (ownership) + CNAME <subdomain> -> <endpoint>.azurefd.net (routing+cert)
#    - Apex:     _dnsauth TXT record (ownership) + ALIAS/ANAME record at the zone apex -> <endpoint>.azurefd.net
#      (Azure DNS natively supports ALIAS records at the apex; confirm the client's DNS provider does too
#       before committing to this path, since not every provider supports apex ALIAS/ANAME records)

# 4. Poll validation state (allow up to 10 min after DNS propagation)
Get-AzFrontDoorCdnCustomDomain -ResourceGroupName <rg> -ProfileName <profileName> -CustomDomainName <domainName> |
    Select-Object DomainValidationState

# 5. Associate the validated domain with a route
Update-AzFrontDoorCdnRoute -ResourceGroupName <rg> -ProfileName <profileName> -EndpointName <endpointName> `
    -Name <routeName> -CustomDomain @(<domainId>)

# 6. If APEX domain: calendar a recurring check (e.g., 30 days before every renewal cycle) to confirm
#    DomainValidationState is still Approved and the certificate isn't approaching expiry unrenewed —
#    autorotation cannot self-heal this the way it does for a CNAME'd subdomain.
```

**Rollback:** Remove the custom domain association from the route, then delete the custom domain resource; DNS records can be safely removed once no route references the domain.

</details>

<details><summary>Playbook 3 — Fleet-wide profile/domain/WAF-tier audit</summary>

```powershell
Get-AzFrontDoorCdnProfile | ForEach-Object {
    $profile = $_
    $isClassic = $profile.Sku.Name -like 'Classic*'
    $domains = Get-AzFrontDoorCdnCustomDomain -ResourceGroupName $profile.ResourceGroupName -ProfileName $profile.Name -ErrorAction SilentlyContinue
    [PSCustomObject]@{
        Profile         = $profile.Name
        ResourceGroup   = $profile.ResourceGroupName
        Sku             = $profile.Sku.Name
        IsClassic       = $isClassic
        DomainCount     = @($domains).Count
        PendingDomains  = @($domains | Where-Object { $_.DomainValidationState -ne 'Approved' }).Count
        NeedsReview     = $isClassic -or (@($domains | Where-Object { $_.DomainValidationState -ne 'Approved' }).Count -gt 0)
    }
} | Where-Object NeedsReview | Format-Table -AutoSize
```

**Rollback:** N/A — read-only audit.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Azure Front Door evidence for escalation
.NOTES     Run as a user with Reader+ on the resource group
#>

$OutputDir = "C:\Temp\FrontDoor-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$profileObj = Get-AzFrontDoorCdnProfile -ResourceGroupName $rg -ProfileName $profileName

# 1. Profile and tier
$profileObj | Select-Object Sku, ResourceState | Export-Csv "$OutputDir\Profile.csv" -NoTypeInformation

# 2. Endpoints
Get-AzFrontDoorCdnEndpoint -ResourceGroupName $rg -ProfileName $profileName |
    Select-Object EndpointName, EnabledState, HostName, ProvisioningState |
    Export-Csv "$OutputDir\Endpoints.csv" -NoTypeInformation

# 3. Custom domains and validation state
Get-AzFrontDoorCdnCustomDomain -ResourceGroupName $rg -ProfileName $profileName |
    Select-Object CustomDomainName, DomainValidationState, TlsCertificateType |
    Export-Csv "$OutputDir\CustomDomains.csv" -NoTypeInformation

# 4. Routes
Get-AzFrontDoorCdnRoute -ResourceGroupName $rg -ProfileName $profileName -EndpointName $endpointName |
    Select-Object Name, CustomDomains, PatternsToMatch, OriginGroup, RuleSets |
    ConvertTo-Json -Depth 6 | Out-File "$OutputDir\Routes.json"

# 5. Origin groups and health
Get-AzFrontDoorCdnOriginGroup -ResourceGroupName $rg -ProfileName $profileName |
    ConvertTo-Json -Depth 6 | Out-File "$OutputDir\OriginGroups.json"

# 6. Security policies and WAF association
Get-AzFrontDoorCdnSecurityPolicy -ResourceGroupName $rg -ProfileName $profileName |
    ConvertTo-Json -Depth 6 | Out-File "$OutputDir\SecurityPolicies.json"

# 7. Recent Activity Log entries for this profile
Get-AzActivityLog -ResourceId $profileObj.Id -StartTime (Get-Date).AddHours(-24) |
    Select-Object EventTimestamp, OperationName, Status, Caller |
    Export-Csv "$OutputDir\ActivityLog-24h.csv" -NoTypeInformation

Write-Host "Evidence collected: $OutputDir" -ForegroundColor Green
Compress-Archive -Path "$OutputDir\*" -DestinationPath "$OutputDir.zip"
Write-Host "Archive: $OutputDir.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# Profile tier and health — always check first
Get-AzFrontDoorCdnProfile -ResourceGroupName <rg> -ProfileName <profileName> | Select Sku, ResourceState

# Endpoint enabled state — a disabled endpoint fails every route on it
Get-AzFrontDoorCdnEndpoint -ResourceGroupName <rg> -ProfileName <profileName> -EndpointName <endpointName>

# Custom domain validation + certificate state
Get-AzFrontDoorCdnCustomDomain -ResourceGroupName <rg> -ProfileName <profileName> -CustomDomainName <domainName>

# Route configuration — exact host + most-specific path match
Get-AzFrontDoorCdnRoute -ResourceGroupName <rg> -ProfileName <profileName> -EndpointName <endpointName> -Name <routeName>

# Origin group health probe + load-balancing settings
Get-AzFrontDoorCdnOriginGroup -ResourceGroupName <rg> -ProfileName <profileName> -OriginGroupName <originGroupName>

# Rule Set — check for a Route Configuration Override before trusting the route's static config
Get-AzFrontDoorCdnRule -ResourceGroupName <rg> -ProfileName <profileName> -RuleSetName <ruleSetName> -RuleName <ruleName>

# WAF policy tier and rule sets — Standard = custom rules only, Premium = + managed rules/Bot Protection/JS Challenge
Get-AzFrontDoorWafPolicy -ResourceGroupName <rg> -Name <wafPolicyName> | Select Sku, ManagedRules

# Security Policy — the resource that actually associates a WAF policy to a domain
Get-AzFrontDoorCdnSecurityPolicy -ResourceGroupName <rg> -ProfileName <profileName> -SecurityPolicyName <policyName>

# Purge cached content after an origin update
Clear-AzFrontDoorCdnEndpointContent -ResourceGroupName <rg> -ProfileName <profileName> -EndpointName <endpointName> -ContentPath @("/*")

# Fleet-wide check for any surviving Classic profiles
Get-AzFrontDoorCdnProfile | Where-Object { $_.Sku.Name -like 'Classic*' } | Select Name, ResourceGroupName

# Activity log for a specific profile
Get-AzActivityLog -ResourceId (Get-AzFrontDoorCdnProfile -ResourceGroupName <rg> -ProfileName <profileName>).Id -StartTime (Get-Date).AddHours(-24)
```

---

## 🎓 Learning Pointers

- **Front Door's frontend-host matching has no wildcard fallback — every hostname needs its own explicit route.** This is a fundamentally different matching model from the path side of the same route, where wildcards are the norm. An engineer debugging a 404 who only checks path patterns and never confirms the exact host is present will miss the actual cause. [MS Docs: How requests get matched to a route](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-route-matching)

- **Apex domains are a structurally different, weaker-automation case than subdomains, and it's invisible until a certificate silently fails to renew.** The lack of a CNAME at the zone apex isn't just a DNS quirk — it removes the exact mechanism managed-certificate autorotation uses to reconfirm ownership. Any MSP managing a client's apex domain on Front Door should treat certificate renewal as a tracked recurring task, not an automated non-event. [MS Docs: Apex domains in Azure Front Door](https://learn.microsoft.com/en-us/azure/frontdoor/apex-domain)

- **Tier is a hard capability wall for WAF, not a configuration dial.** Standard-tier WAF policies can be fully authored, associated, and show "Enabled" with zero managed-rule protection active — there's no visual or configuration-time warning that Premium is required for DRS/Bot Protection/JS Challenge. Always confirm tier explicitly with a client before scoping a WAF engagement around managed-rule behavior. [MS Docs: What is WAF on Azure Front Door?](https://learn.microsoft.com/en-us/azure/web-application-firewall/afds/afds-overview)

- **Front Door fails open, not closed, on a total origin-group outage.** Every other resource in this folder with an explicit failure-mode note (Load Balancer's UDP-flow-termination-on-total-failure, Application Gateway's backend health defaults) is worth cross-referencing here: Front Door's fail-open round-robin means a genuine full outage can present to end users as intermittent slowness rather than a clean failure, which changes how you interpret "it's still sort of working" reports during an incident. [MS Docs: Health probes - Azure Front Door](https://learn.microsoft.com/en-us/azure/frontdoor/health-probes)

- **A WAF policy is a standalone resource with zero effect until a Security Policy resource associates it with a domain** — this extra indirection layer doesn't exist on Application Gateway, where the WAF policy attaches directly. An engineer coming from Application Gateway experience may reasonably expect creating and configuring the WAF policy to be sufficient, and miss the association step entirely.

- **Front Door (classic) retirement (March 31, 2027) is a hard platform wall for new domains and certificates, not a soft deprecation.** Any Classic profile found during a client engagement is worth flagging proactively rather than waiting for it to block a future domain-onboarding request — Microsoft's own migration tooling is specifically designed to preserve the existing endpoint hostname, minimizing the disruption of migrating ahead of the deadline. [MS Docs: Migrate to Front Door Standard/Premium](https://learn.microsoft.com/en-us/azure/frontdoor/migrate-tier)
