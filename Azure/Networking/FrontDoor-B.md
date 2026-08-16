# Azure Front Door — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---

## Triage

Run these first. Results tell you which fix path to take.

```powershell
# 1. Tier and health — Classic retires March 31, 2027 (no new profiles/domains/certs); confirm which tier this is
Get-AzFrontDoorCdnProfile -ResourceGroupName <rg> -ProfileName <profileName> | Select-Object Sku, ResourceState

# 2. Endpoint state — a disabled/stopped endpoint returns errors for EVERY route on it
Get-AzFrontDoorCdnEndpoint -ResourceGroupName <rg> -ProfileName <profileName> -EndpointName <endpointName> |
    Select-Object EnabledState, HostName, ProvisioningState

# 3. Origin group health — the single most useful first check for any "site is down/slow" ticket
Get-AzFrontDoorCdnOriginGroup -ResourceGroupName <rg> -ProfileName <profileName> -OriginGroupName <originGroupName>

# 4. Custom domain + certificate state — most "not working after DNS cutover" tickets live here
Get-AzFrontDoorCdnCustomDomain -ResourceGroupName <rg> -ProfileName <profileName> -CustomDomainName <domainName> |
    Select-Object DomainValidationState, TlsCertificateType

# 5. Is a WAF security policy actually associated with this domain, and what tier is it?
Get-AzFrontDoorCdnSecurityPolicy -ResourceGroupName <rg> -ProfileName <profileName> -SecurityPolicyName <policyName>
```

| If | Then |
|----|------|
| `Sku` shows `Classic_*` | Retires March 31, 2027 — no new domains/certs from here on; flag for migration to Standard/Premium → **Fix 1** |
| Endpoint `EnabledState` = `Disabled` | Every route on this endpoint fails until re-enabled — check for an accidental/incident-response disable first → **Fix 2** |
| `DomainValidationState` stuck on `Pending`/`PendingRevalidation` | TXT record missing/wrong, or an apex domain's autorotation revalidation was never completed → **Fix 3** |
| Custom domain works over HTTP but HTTPS fails/cert shows `CertificateDeleted`/`CertificateExpired` | Certificate provisioning or autorotation failure — apex domains fail autorotation silently → **Fix 3** |
| Requests to an exact hostname return 404 even though a route exists | Front Door requires an EXACT frontend host match — no wildcard host fallback, unlike path matching → **Fix 4** |
| Origin group shows all origins Unhealthy but the app works when hit directly | Health probe hitting a blocked/wrong port-protocol, or a WAF/NSG blocking Front Door's own probe source | → **Fix 5** |
| WAF isn't blocking anything you configured, or managed-rule findings are missing | Standard tier WAF supports **custom rules only** — no managed rules (DRS), Bot Protection, or JS Challenge without Premium | → **Fix 6** |
| A route sends traffic to the wrong origin group despite the domain/path config looking correct | A Rule Set with a Route Configuration Override action is silently taking precedence | → **Fix 7** |
| Caching serves stale content after an origin update | Expected behavior — cache TTL/query-string config, not a fault; purge is the fix, not a bug report | → **Fix 8** |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Front Door profile (Standard/Premium — Classic retires 2027, migrate before troubleshooting further)
        │
Endpoint EnabledState = Enabled
        │
Custom domain DomainValidationState = Approved
   (TXT record _dnsauth.<subdomain> for ownership; CNAME to the endpoint for non-apex routing+cert;
    apex domains have NO CNAME — cert autorotation silently fails until manually revalidated)
        │
Route: EXACT frontend host match required (protocol → domain → path, most-specific wins;
   no host wildcard fallback — an unmatched host is a 404, not a fallback to a catch-all route)
        │
[If Rule Set present] Route Configuration Override action — can silently redirect to a
   DIFFERENT origin group than the route's own association
        │
[If WAF security policy associated] Standard tier = custom rules ONLY
   Premium tier = custom rules + managed rules (DRS) + Bot Protection + JS Challenge
   Evaluation order: custom rules → rate-limit rules → bot protection → managed rules
        │
Origin group health probe (HTTP/HTTPS, HEAD by default) — 3-step health determination:
   exclude disabled → exclude failed-SampleSize/SuccessfulSamplesRequired → latency-rank the rest
   ALL origins failing = fail-OPEN round robin across all of them, not fail-closed
        │
Origin responds within timeout → response cached (if enabled) or passed through
```

</details>

---

## Diagnosis & Validation Flow

**1. Confirm tier first — this changes what's even possible to fix here:**
```powershell
Get-AzFrontDoorCdnProfile -ResourceGroupName <rg> -ProfileName <profileName> | Select-Object Sku
```
`Classic_*` → no new domain onboarding or managed certs are possible; if the ticket involves either, this IS the problem — Fix 1 (migration), not a same-ticket fix.

**2. Confirm the endpoint itself is enabled:**
```powershell
Get-AzFrontDoorCdnEndpoint -ResourceGroupName <rg> -ProfileName <profileName> -EndpointName <endpointName> | Select-Object EnabledState
```
`Disabled` → every route on it fails identically regardless of route/origin config — Fix 2.

**3. Split the problem: is this a domain/certificate issue or a routing/origin issue?**
- Client reports HTTPS errors, cert warnings, or "domain won't validate" → step 4.
- Client reports 404s, wrong content, or slow/down responses → step 5.

**4. Domain and certificate:**
```powershell
Get-AzFrontDoorCdnCustomDomain -ResourceGroupName <rg> -ProfileName <profileName> -CustomDomainName <domainName> |
    Select-Object DomainValidationState, TlsCertificateType, ValidationProperties
```
`Pending`/`PendingRevalidation` → check the `_dnsauth.<subdomain>` TXT record exists and matches exactly. If this is an **apex domain**, there is no CNAME — Microsoft-managed certificate autorotation cannot silently revalidate ownership the way it does for a CNAME'd subdomain, and the domain owner must manually re-approve. This is the single most common apex-domain certificate ticket — Fix 3.

**5. Routing and origin health:**
```powershell
Get-AzFrontDoorCdnRoute -ResourceGroupName <rg> -ProfileName <profileName> -EndpointName <endpointName> -Name <routeName>
Get-AzFrontDoorCdnOriginGroup -ResourceGroupName <rg> -ProfileName <profileName> -OriginGroupName <originGroupName>
```
If the reported hostname doesn't exactly match any route's configured frontend host, Front Door returns 404 — there's no wildcard-host fallback the way there's a wildcard-path fallback. If origins show Unhealthy, confirm the probe port/protocol/path actually matches what the origin serves, and that nothing (WAF, origin-side firewall/NSG) is blocking Front Door's own probe traffic — Fix 5.

**6. If a Rule Set exists on the matched route, check for an override before trusting the route's own origin group association:**
```powershell
Get-AzFrontDoorCdnRuleSet -ResourceGroupName <rg> -ProfileName <profileName> -RuleSetName <ruleSetName>
Get-AzFrontDoorCdnRule -ResourceGroupName <rg> -ProfileName <profileName> -RuleSetName <ruleSetName> -RuleName <ruleName>
```
A `RouteConfigurationOverride` action redirects to a different origin group than what the route itself shows — Fix 7.

**7. If the complaint is "WAF isn't catching attacks" rather than a false-positive block, confirm tier before assuming a rule is misconfigured:**
```powershell
Get-AzFrontDoorCdnSecurityPolicy -ResourceGroupName <rg> -ProfileName <profileName> -SecurityPolicyName <policyName>
```
Standard tier's WAF has no managed rule set at all — Fix 6.

---

## Common Fix Paths

<details><summary>Fix 1 — Client is still on Front Door (classic)</summary>

**Symptom:** `Sku` returns a `Classic_*` value. Classic retires **March 31, 2027** — no new profile creation, no new domain onboarding, no managed certificates from that point. It is still fully operational for existing configuration until then, but any request to add a domain or troubleshoot cert issuance on a Classic profile hits a hard platform wall as retirement approaches.

```powershell
# Inventory current config before scheduling a migration window
Get-AzFrontDoorCdnProfile -ResourceGroupName <rg> -ProfileName <profileName>
```

This is a scheduled migration (Microsoft provides a guided migration path from Classic to Standard/Premium preserving endpoint hostnames), not a same-ticket change — see `FrontDoor-A.md` Playbook 1. Note it as a required follow-up in the ticket.

**Rollback:** N/A — inventory only, no change made.

</details>

<details><summary>Fix 2 — Endpoint disabled, all routes on it failing identically</summary>

**Symptom:** Every hostname on one endpoint returns the same error (connection refused / 403 depending on client), while other endpoints on the same profile work fine.

```powershell
$endpoint = Get-AzFrontDoorCdnEndpoint -ResourceGroupName <rg> -ProfileName <profileName> -EndpointName <endpointName>
if ($endpoint.EnabledState -eq 'Disabled') {
    Update-AzFrontDoorCdnEndpoint -ResourceGroupName <rg> -ProfileName <profileName> -EndpointName <endpointName> -EnabledState Enabled
}
```

Before re-enabling, confirm this wasn't an intentional incident-response action (e.g., an emergency traffic cutoff during an active attack) — check the Activity Log for who disabled it and why.

```powershell
Get-AzActivityLog -ResourceId $endpoint.Id -StartTime (Get-Date).AddHours(-48) | Select-Object EventTimestamp, Caller, OperationName
```

**Rollback:** Disable again if this was in fact an intentional emergency action being prematurely reversed.

</details>

<details><summary>Fix 3 — Custom domain stuck validating, or certificate errors on an apex domain</summary>

**Symptom:** `DomainValidationState` is `Pending` or `PendingRevalidation`, or HTTPS fails/shows a cert warning while HTTP works.

```powershell
$domain = Get-AzFrontDoorCdnCustomDomain -ResourceGroupName <rg> -ProfileName <profileName> -CustomDomainName <domainName>
$domain.ValidationProperties   # contains the expected TXT record name/value
```

**For a non-apex (subdomain) domain:** confirm both DNS records exist and are correct:
- `_dnsauth.<subdomain>` TXT record with the exact value Front Door generated
- CNAME from the subdomain to the endpoint's `*.azurefd.net`/`*.z01.azurefd.net` hostname

**For an apex/root domain:** there is no CNAME possible (DNS protocol limitation) — an ALIAS/ANAME record (if the DNS provider supports it, Azure DNS does) points traffic correctly, but **certificate autorotation has no CNAME to revalidate ownership against** and will silently fail at renewal time until an admin manually re-approves domain ownership. This is not a bug — treat any apex-domain cert expiry warning as requiring manual revalidation, not a platform fault.

```powershell
# Re-trigger validation after fixing DNS records
Update-AzFrontDoorCdnCustomDomain -ResourceGroupName <rg> -ProfileName <profileName> -CustomDomainName <domainName>
```

Allow up to 10 minutes after a DNS record change before re-checking `DomainValidationState`.

**Rollback:** N/A — DNS/validation fix only, no destructive change.

</details>

<details><summary>Fix 4 — Exact-match hostname returns 404 despite a route existing</summary>

**Symptom:** `https://app.contoso.com/anything` returns 404, but the route configuration looks correct.

```powershell
# Confirm the EXACT host configured on the route matches what's being requested, character for character
(Get-AzFrontDoorCdnRoute -ResourceGroupName <rg> -ProfileName <profileName> -EndpointName <endpointName> -Name <routeName>).CustomDomains
```

Front Door matches frontend host with an **exact match only** — there is no wildcard-host fallback the way there's a wildcard-path fallback (`/*`). A request for `images.contoso.com` when only `www.contoso.com` and `contoso.com` have routes returns a 404 with no partial match, even if a catch-all path route exists on the other hosts. The fix is adding a route (or associating the existing route) for the missing exact hostname, not adjusting path patterns.

**Rollback:** N/A — configuration addition only.

</details>

<details><summary>Fix 5 — Origin group shows all origins Unhealthy, but the app works when hit directly</summary>

**Symptom:** `Get-AzFrontDoorCdnOriginGroup` / origin health checks show every origin in the group as failed, yet manually curling the origin's own endpoint succeeds.

```powershell
# Check the actual probe configuration — protocol, path, and interval
(Get-AzFrontDoorCdnOriginGroup -ResourceGroupName <rg> -ProfileName <profileName> -OriginGroupName <originGroupName>).HealthProbeSettings
```

Common root causes, in order of likelihood:
1. Probe path returns a non-200 status the origin's real traffic never hits (e.g., probing `/` on an API-only origin that 404s at root).
2. Origin-side firewall/NSG/WAF blocking Front Door's probe source — Front Door probes originate from its edge infrastructure, not a fixed IP range friendly to simple allow-lists; the documented approach is validating the `X-Azure-FDID` header rather than IP-based origin restriction.
3. Probe protocol mismatch (HTTP probe against an HTTPS-only listener or vice versa).

```powershell
# Correct the probe path/protocol if mismatched
Update-AzFrontDoorCdnOriginGroup -ResourceGroupName <rg> -ProfileName <profileName> -OriginGroupName <originGroupName> `
    -HealthProbeSetting @{ ProbePath = "/healthz"; ProbeProtocol = "Https"; ProbeRequestType = "HEAD" }
```

**Rollback:** Revert probe path/protocol to the prior value if this wasn't the actual cause.

</details>

<details><summary>Fix 6 — WAF isn't blocking what was expected</summary>

**Symptom:** A client configured "the WAF" and expects OWASP-style managed protection (SQLi, XSS, etc.), but nothing is being caught — only explicitly authored custom rules fire.

```powershell
Get-AzFrontDoorWafPolicy -ResourceGroupName <rg> -Name <wafPolicyName> | Select-Object Sku, ManagedRules
```

**Standard tier Front Door WAF supports custom rules only** — no managed rule sets (DRS), no Bot Protection, no JavaScript Challenge. This is a tier ceiling, not a configuration gap; there is no setting to enable managed rules on Standard. Confirm expectations with the client before spending more time here — the fix is a tier upgrade to Premium, not a rule change.

```powershell
# Confirm tier before promising managed-rule behavior is achievable without upgrading
(Get-AzFrontDoorCdnProfile -ResourceGroupName <rg> -ProfileName <profileName>).Sku
```

**Rollback:** N/A — tier ceiling, not a change to roll back.

</details>

<details><summary>Fix 7 — Route Configuration Override silently redirecting traffic</summary>

**Symptom:** The route's own origin group association looks correct, but traffic for certain paths/conditions goes to a different origin group than expected.

```powershell
Get-AzFrontDoorCdnRuleSet -ResourceGroupName <rg> -ProfileName <profileName> -RuleSetName <ruleSetName>
Get-AzFrontDoorCdnRule -ResourceGroupName <rg> -ProfileName <profileName> -RuleSetName <ruleSetName> -RuleName <ruleName>
```

A rule set attached to the matched route can carry a **Route Configuration Override** action, which fully overrides the route's own origin group selection for matching requests — this happens after the normal host/path route matching, not instead of it, which is why the route configuration itself "looks right" while behavior differs. Review every rule in the attached rule set for a `RouteConfigurationOverride` action before assuming the route object is misconfigured.

**Rollback:** Remove or correct the overriding rule if it's not intentional.

</details>

<details><summary>Fix 8 — Stale content served after an origin update</summary>

**Symptom:** Origin content was updated, but Front Door keeps serving the old version.

```powershell
# Purge the specific content path (or /* for everything) rather than treating this as a fault
Clear-AzFrontDoorCdnEndpointContent -ResourceGroupName <rg> -ProfileName <profileName> -EndpointName <endpointName> -ContentPath @("/*")
```

This is expected caching behavior governed by cache-control headers / TTL configuration on the route, not a defect. If this recurs frequently for content that changes often, address it with cache-duration/query-string caching behavior on the route rather than manually purging every time.

**Rollback:** N/A — purge is non-destructive; content is re-fetched from origin on next request.

</details>

---

## Escalation Evidence

```
=== Azure Front Door Failure — Ticket Evidence ===

Date/Time:                       _______________
Profile name / RG:                _______________
SKU (Classic/Standard/Premium):   _______________
Endpoint / reported hostname:     _______________
Reported symptom:                 _______________  (domain/cert / routing 404 / origin health / WAF / stale cache)

--- Commands Run ---
Endpoint EnabledState:                 _______________
DomainValidationState:                 _______________
Apex domain (Y/N):                     _______________
Origin group health (per origin):      _______________
Probe protocol/path/port:              _______________
WAF policy SKU (managed rules avail?): _______________
Rule Set present with Route Override:  _______________

--- Steps Taken ---
[ ] Confirmed tier (Classic vs. Standard vs. Premium)
[ ] Confirmed endpoint EnabledState
[ ] Checked domain validation state + DNS records (TXT/CNAME, apex vs. subdomain)
[ ] Checked exact-host route match for the reported hostname
[ ] Checked origin group health + probe configuration
[ ] Checked for a Rule Set Route Configuration Override
[ ] Confirmed WAF tier supports the expected protection level
```

---

## 🎓 Learning Pointers

- **Front Door route matching requires an EXACT frontend host match — there's no wildcard-host fallback.** A request for a hostname with no route explicitly configured for it 404s outright, even if a catch-all `/*` path route exists on a different host. This trips up engineers used to path-based wildcard matching and assuming the same leniency applies to hosts. [MS Docs: How requests get matched to a route](https://learn.microsoft.com/en-us/azure/frontdoor/front-door-route-matching)

- **Standard tier Front Door WAF is custom-rules-only — no managed rule sets, Bot Protection, or JS Challenge.** This is one of the most consequential and least obvious tier differences in the Front Door product: a client can fully configure and associate a WAF policy on Standard and still have zero OWASP-style protection, with no error or warning surfaced anywhere in the configuration. Confirm tier before promising managed protection is achievable without a Premium upgrade. [MS Docs: WAF on Azure Front Door](https://learn.microsoft.com/en-us/azure/web-application-firewall/afds/afds-overview)

- **Apex/root domains cannot have a CNAME, and Microsoft-managed certificate autorotation depends on one.** A subdomain's cert silently renews because Front Door can re-validate ownership via the existing CNAME; an apex domain has no such record, so autorotation fails and requires manual domain re-validation before expiry. Flag any client running Front Door on an apex domain as needing a recurring manual-revalidation check, not a "set and forget" TLS configuration. [MS Docs: Apex domains in Azure Front Door](https://learn.microsoft.com/en-us/azure/frontdoor/apex-domain)

- **All origins failing health probes doesn't stop traffic — Front Door fails OPEN, round-robining across every origin in the group** (the same fail-open philosophy documented for Azure Load Balancer). This can mask a genuine full-origin-group outage as "still working, just slow," since requests keep flowing to origins that are actually down rather than returning a clean error. [MS Docs: Health probes - Azure Front Door](https://learn.microsoft.com/en-us/azure/frontdoor/health-probes)

- **Front Door (classic) retires March 31, 2027** — no new profile creation, domain onboarding, or managed certificates from that point forward. Any Classic profile discovered during a client engagement should be flagged for migration now; Microsoft provides a guided in-place migration path to Standard/Premium that preserves the existing `*.azurefd.net` endpoint hostname. [MS Docs: Migrate to Front Door Standard/Premium](https://learn.microsoft.com/en-us/azure/frontdoor/migrate-tier)

- **"The load balancer"/"the firewall" confusion extends to Front Door too** — a client describing global edge caching, path-based routing across regions, or a WAF block on a globally-distributed site is describing Front Door, not the regional `AppGateway-A.md`/`LoadBalancer-A.md` resources covered elsewhere in this folder. Confirm which resource is actually in the request path before troubleshooting the wrong layer.
