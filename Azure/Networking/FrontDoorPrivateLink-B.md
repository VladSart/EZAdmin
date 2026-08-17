# Azure Front Door Premium — Private Link Origins — Hotfix Runbook (Mode B: Ops)
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
# 1. Tier — Private Link origins are PREMIUM-ONLY, not available on Standard or Classic
(Get-AzFrontDoorCdnProfile -ResourceGroupName <rg> -ProfileName <profileName>).Sku.Name

# 2. Per-origin Private Link connection state — ONLY "Approved" carries traffic
$origin = Get-AzFrontDoorCdnOrigin -ResourceGroupName <rg> -ProfileName <profileName> -OriginGroupName <originGroupName> -OriginName <originName>
$origin.SharedPrivateLinkResource | Select-Object PrivateLink, GroupId, PrivateLinkLocation, Status, RequestMessage

# 3. Does this origin group mix public and private origins? (unsupported — causes routing errors)
$origins = Get-AzFrontDoorCdnOrigin -ResourceGroupName <rg> -ProfileName <profileName> -OriginGroupName <originGroupName>
$origins | Select-Object Name, @{N='PrivateLinkEnabled';E={$null -ne $_.SharedPrivateLinkResource}}

# 4. Duplicate-resource check — origins pointing at the same backend with different ports (routing-issue trap)
$origins | Where-Object { $_.SharedPrivateLinkResource } |
    Group-Object { $_.SharedPrivateLinkResource.PrivateLink } |
    Where-Object { $_.Count -gt 1 } |
    Select-Object Name, @{N='Ports';E={$_.Group | ForEach-Object { "$($_.HttpPort)/$($_.HttpsPort)" }}}

# 5. Recent 429s at the origin — Private Link traffic is capped at 7200 RPS per regional cluster per profile
Get-AzFrontDoorCdnLogAnalyticsMetric -ResourceId <profileResourceId> -MetricName "RequestCount" -DateTimeBegin (Get-Date).AddHours(-1) -DateTimeEnd (Get-Date)
```

| If | Then |
|----|------|
| `Sku.Name` isn't `Premium_AzureFrontDoor` | Private Link origins don't exist on this tier — confirm this isn't a Standard-tier expectation mismatch before troubleshooting further → **Fix 1** |
| `SharedPrivateLinkResource.Status` = `Pending` | Origin owner never approved the private endpoint request — zero traffic flows until they do → **Fix 2** |
| `Status` = `Rejected` or `Timeout` | The request was declined or expired — must be re-created, cannot be re-approved in place → **Fix 3** |
| Origin group contains both Private-Link and non-Private-Link origins | Mixing public and private origins in one origin group is explicitly unsupported → **Fix 4** |
| Two+ origins share the same resource ID/Group ID/region but different ports | Platform limitation — can cause routing issues between Front Door and the origin → **Fix 5** |
| Requests fail for the first few minutes right after enabling Private Link on an origin | Expected — connection establishment takes a few minutes after approval → **Fix 6** |
| 429 "Too Many Requests" under load, origin otherwise healthy | 7200 RPS/region/profile platform cap for Private Link traffic — needs multi-region origins → **Fix 7** |
| Client expects mTLS/client-cert auth to the origin | Not supported for Private Link (or public) origins on Front Door at all — not a misconfiguration → **Fix 8** |
| Portal shows "You don't have access" clicking into the private endpoint object | Expected — the PE is hosted in a Microsoft-managed subscription, not the customer's → **Fix 9** |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Front Door profile SKU = Premium (Private Link origins do not exist on Standard/Classic)
        │
Origin type is one of the supported set: App Service, Blob Storage, Storage Static Website,
   internal Load Balancer (incl. AKS/ARO-exposed ones), API Management, Application Gateway,
   Container Apps  —  NOT App Service Slots, NOT Static Web Apps
        │
Region for the Private Link endpoint chosen from Front Door's supported (AZ-enabled) region list
   (feature is region-agnostic in principle, but closest-to-origin minimizes added latency)
        │
Front Door creates a Private Endpoint from ITS OWN managed regional VNet
   (not the customer's VNet — this is the reverse direction from a normal Private Endpoint,
    where the CONSUMER creates the PE; here Front Door is the consumer, the origin is the resource)
        │
Origin owner approves the pending Private Endpoint connection request
   (Portal / Azure CLI / Azure PowerShell — Approve-AzPrivateEndpointConnection on the ORIGIN side)
        │
Connection establishes (a few minutes) → SharedPrivateLinkResource.Status = Approved
        │
Origin group rule: ALL origins in a group must be private, or ALL must be public — never mixed
        │
Health probes follow the SAME private path as real traffic (not a separate public check)
        │
Traffic flows: client → FD global POP → Microsoft backbone → FD regional cluster
   (hosting the managed VNet + dedicated PE) → Private Link → origin
        │
Rate ceiling: 7200 RPS per Front Door regional cluster per profile for Private Link traffic
   (exceeding it returns 429s — mitigated by spreading origins across multiple PL regions)
```

</details>

---

## Diagnosis & Validation Flow

**1. Confirm tier — this is a Premium-only capability:**
```powershell
(Get-AzFrontDoorCdnProfile -ResourceGroupName <rg> -ProfileName <profileName>).Sku.Name
```
Anything other than `Premium_AzureFrontDoor` means Private Link origins are not available — redirect the conversation to a tier upgrade (see `FrontDoor-A.md` for the general tier ceiling pattern) rather than debugging a feature that can't exist on this profile.

**2. Confirm the origin's Private Link connection state:**
```powershell
$origin = Get-AzFrontDoorCdnOrigin -ResourceGroupName <rg> -ProfileName <profileName> -OriginGroupName <originGroupName> -OriginName <originName>
$origin.SharedPrivateLinkResource | Format-List *
```
`Status` must read `Approved`. `Pending` is the single most common "origin unreachable" root cause for a newly-configured Private Link origin — Fix 2.

**3. If the origin was JUST enabled for Private Link, rule out the connection-establishment window before treating this as a fault:**
Allow a few minutes after approval. Requests during this window return a Front Door-generated error that clears on its own — Fix 6.

**4. Check for the mixed-origin-group error pattern:**
```powershell
$origins = Get-AzFrontDoorCdnOrigin -ResourceGroupName <rg> -ProfileName <profileName> -OriginGroupName <originGroupName>
$origins | Select-Object Name, @{N='PrivateLink';E={$null -ne $_.SharedPrivateLinkResource}}
```
If this list contains both `$true` and `$false`, or if the client reports the exact error *"Origin Group can only have origins with private links or origins without private links. They cannot have a mix of both"* — this is not a bug, it's an enforced constraint (frequently triggered transiently when converting two public origins to private at the same time, since the update is sequential, not atomic) — Fix 4.

**5. Check for the same-resource-different-port trap:**
```powershell
$origins | Where-Object { $_.SharedPrivateLinkResource } |
    Group-Object { "$($_.SharedPrivateLinkResource.PrivateLink)|$($_.SharedPrivateLinkResource.GroupId)|$($_.SharedPrivateLinkResource.PrivateLinkLocation)" } |
    Where-Object Count -gt 1
```
Any group with `Count -gt 1` shares a single underlying Private Endpoint (by design — see `FrontDoorPrivateLink-A.md`). If those origins use **different HTTP/HTTPS ports**, this is a documented platform limitation that causes routing issues — Fix 5.

**6. If the symptom is 429s under load, not connectivity failures:**
Private Link traffic is capped at 7200 RPS per Front Door regional cluster per profile — this is a hard platform ceiling, not a throttling misconfiguration on the origin side — Fix 7.

---

## Common Fix Paths

<details><summary>Fix 1 — Client expects Private Link origins on Standard tier</summary>

**Symptom:** A client configured Front Door Standard and is asking why they can't find the Private Link option on an origin.

Private Link origin connectivity is a **Premium-only** capability — there is no configuration path to enable it on Standard. This is a tier ceiling, identical in shape to Standard's WAF managed-rules gap documented in `FrontDoor-B.md` Fix 6.

```powershell
(Get-AzFrontDoorCdnProfile -ResourceGroupName <rg> -ProfileName <profileName>).Sku.Name
```

**Rollback:** N/A — informational; the fix is a tier upgrade, not a configuration change.

</details>

<details><summary>Fix 2 — Private Endpoint connection stuck Pending</summary>

**Symptom:** Origin was configured for Private Link, but Front Door returns errors to every request; `SharedPrivateLinkResource.Status` is `Pending`.

Front Door creates the Private Endpoint request; **the origin's owner must approve it** — this doesn't happen automatically even within the same subscription/tenant.

```powershell
# Run against the ORIGIN resource, not the Front Door profile
$pe = Get-AzPrivateEndpointConnection -ResourceGroupName <originRg> -ServiceName <originResourceName> -PrivateLinkResourceType <resourceType>
$pe | Where-Object { $_.PrivateLinkServiceConnectionState.Status -eq 'Pending' } |
    Approve-AzPrivateEndpointConnection -Description "Approved for Front Door Premium origin connectivity"
```

Allow a few minutes after approval for the connection to establish (see Fix 6) before re-testing.

**Rollback:** Reject the connection again if approved in error — this cuts off Front Door's private path to the origin immediately.

</details>

<details><summary>Fix 3 — Connection Rejected or Timeout</summary>

**Symptom:** `Status` shows `Rejected` (an admin explicitly declined it) or `Timeout` (nobody approved it within the request's validity window).

A rejected or timed-out Private Endpoint connection **cannot be re-approved in place** — the request object itself is dead.

```powershell
# Remove the private-link configuration from the origin, then re-add it to generate a fresh request
Update-AzFrontDoorCdnOrigin -ResourceGroupName <rg> -ProfileName <profileName> -OriginGroupName <originGroupName> -OriginName <originName> -SharedPrivateLinkResourcePrivateLink $null
Update-AzFrontDoorCdnOrigin -ResourceGroupName <rg> -ProfileName <profileName> -OriginGroupName <originGroupName> -OriginName <originName> `
    -SharedPrivateLinkResourcePrivateLink <originResourceId> -SharedPrivateLinkResourceGroupId <groupId> -SharedPrivateLinkResourcePrivateLinkLocation <region>
```
Then repeat Fix 2's approval step on the newly generated request.

**Rollback:** Remove the Private Link configuration entirely to fall back to a public origin if this is blocking an active incident and re-approval can't happen quickly — only if the origin is safe to expose publicly in the interim.

</details>

<details><summary>Fix 4 — Mixed public/private origins in one origin group</summary>

**Symptom:** Error text *"Origin Group can only have origins with private links or origins without private links. They cannot have a mix of both."* — or an origin group silently has some private, some public origins.

This most commonly happens when converting **two or more public origins to Private Link at the same time** — the platform processes origins sequentially, so mid-update there's a real (if brief) mixed state that the platform rejects.

```powershell
# Convert one origin at a time:
# 1. Remove all but one origin from the group (or scale to zero traffic on the others first)
# 2. Enable Private Link on the single remaining origin and approve its connection (Fix 2)
# 3. Only after that origin shows Approved, add/convert the next origin
```

**Rollback:** N/A — this is a sequencing fix, not a destructive change.

</details>

<details><summary>Fix 5 — Same-resource, different-port routing issue</summary>

**Symptom:** Multiple origins point at the same backend resource (same resource ID/Group ID/region) using different HTTP/HTTPS ports, and traffic behaves inconsistently or routes to the wrong port.

Front Door reuses a **single Private Endpoint** for origins sharing the same resource ID + Group ID + region combination — this is by design for cost/simplicity. Microsoft's own documentation flags multiple origins on that same shared PE with **different ports** as a known platform limitation that can cause routing issues.

```powershell
# Identify affected origin sets
$origins | Where-Object { $_.SharedPrivateLinkResource } |
    Group-Object { "$($_.SharedPrivateLinkResource.PrivateLink)|$($_.SharedPrivateLinkResource.GroupId)|$($_.SharedPrivateLinkResource.PrivateLinkLocation)" } |
    Where-Object Count -gt 1 |
    ForEach-Object { $_.Group | Select-Object Name, HttpPort, HttpsPort }
```

The supported fix is standardizing on one port scheme across origins sharing a PE, or splitting them into separate origin groups pointed at distinct resources/regions so each gets its own dedicated Private Endpoint.

**Rollback:** N/A — configuration standardization, not a destructive change.

</details>

<details><summary>Fix 6 — Errors immediately after enabling Private Link (transient)</summary>

**Symptom:** Origin was just approved for Private Link, but requests still fail with a Front Door-generated error for the first several minutes.

This is expected. After approval, **it can take a few minutes for the private connection to fully establish**; Front Door returns its own error page during this window. No action needed beyond waiting and re-testing.

```powershell
# Poll status until it's stable, don't change config mid-poll
1..10 | ForEach-Object {
    (Get-AzFrontDoorCdnOrigin -ResourceGroupName <rg> -ProfileName <profileName> -OriginGroupName <originGroupName> -OriginName <originName>).SharedPrivateLinkResource.Status
    Start-Sleep -Seconds 30
}
```

**Rollback:** N/A — no change made; this is a wait-and-confirm step.

</details>

<details><summary>Fix 7 — 429 Too Many Requests under load</summary>

**Symptom:** High-traffic origin returns 429s from Front Door itself, origin backend shows healthy and under capacity.

Private Link traffic is platform-capped at **7200 RPS per Front Door regional cluster, per profile**. This is not adjustable via support request — the documented mitigation is spreading load across **multiple origins, each using a different Private Link region**, within the same origin group.

```powershell
# Add additional origins pointing to the same app but registered under a different Private Link region
# (each origin's SharedPrivateLinkResourcePrivateLinkLocation should differ)
Update-AzFrontDoorCdnOrigin -ResourceGroupName <rg> -ProfileName <profileName> -OriginGroupName <originGroupName> -OriginName <newOriginName> `
    -SharedPrivateLinkResourcePrivateLink <originResourceId> -SharedPrivateLinkResourceGroupId <groupId> -SharedPrivateLinkResourcePrivateLinkLocation <differentRegion>
```

**Rollback:** Remove the added origin if it doesn't relieve the 429s (confirms the bottleneck is elsewhere, e.g. the origin's own scale limits).

</details>

<details><summary>Fix 8 — Client wants mTLS/client-certificate auth to a Private Link origin</summary>

**Symptom:** Security requirement calls for mutual TLS between Front Door and the origin; nothing in the origin's configuration seems to enable it.

**Azure Front Door does not support client/mutual authentication (mTLS) to origins at all — public or Private Link.** This is a hard platform gap, not a missing setting. Document this explicitly for the client and propose an alternative control (origin-side header validation of `X-Azure-FDID`, or an Application Gateway/API Management layer in front of the true origin if mTLS is a hard requirement).

**Rollback:** N/A — no configuration exists to roll back.

</details>

<details><summary>Fix 9 — "You don't have access" clicking into the Private Endpoint in the Portal</summary>

**Symptom:** While approving or reviewing the connection, double-clicking the Private Endpoint object in the Azure Portal shows *"You don't have access. Copy the error details and send them to your administrator to get access to this page."*

This is **expected behavior**, not a permissions bug — the Private Endpoint object itself lives in a Microsoft-managed subscription (Front Door's own regional managed VNet), not the customer's subscription. Manage the connection via the origin resource's own Private Endpoint Connections blade/cmdlets instead of trying to open the PE object directly.

**Rollback:** N/A — no action needed.

</details>

---

## Escalation Evidence

```
=== Front Door Premium Private Link Origin — Ticket Evidence ===

Date/Time:                              _______________
Profile name / RG:                      _______________
SKU (must be Premium):                  _______________
Origin group / origin name:             _______________
Origin type:                            _______________  (App Service / Storage / ILB / APIM / App Gateway / Container Apps)
Reported symptom:                       _______________  (unreachable / mixed-group error / 429 / mTLS / port routing / portal access)

--- Commands Run ---
SharedPrivateLinkResource.Status:       _______________
Private Link region configured:         _______________
Minutes since approval (if Pending→Approved transition): _______________
Origin group mix (all-private/all-public?):  _______________
Shared-PE port conflict found (Y/N):    _______________
Recent 429 rate (per region if known):  _______________

--- Steps Taken ---
[ ] Confirmed Premium tier
[ ] Checked SharedPrivateLinkResource.Status on the origin
[ ] Approved pending connection on the origin resource side (if applicable)
[ ] Confirmed origin group isn't mixing public/private origins
[ ] Checked for same-resource/different-port origins sharing one PE
[ ] Ruled out the few-minutes connection-establishment window
[ ] Confirmed whether 7200 RPS/region cap is a factor under load
```

---

## 🎓 Learning Pointers

- **Front Door is the CONSUMER of the Private Endpoint here, not the resource — the reverse of a typical Private Link setup.** Front Door creates the PE from its own managed regional VNet and requests approval from the origin owner, the mirror image of `PrivateLink-A.md`'s general pattern where a client VNet consumes a PaaS service. Don't apply the general Private Link mental model (client subnet → PaaS resource) without adjusting for this direction reversal. [MS Docs: Secure your origin with Private Link](https://learn.microsoft.com/en-us/azure/frontdoor/private-link)

- **This is Premium-only.** There is no path to enable Private Link origins on Standard or Classic — confirm tier immediately on any related ticket before investigating further, exactly like the WAF managed-rules tier ceiling in `FrontDoor-B.md`.

- **Origins sharing the same resource ID + Group ID + region reuse a single Private Endpoint automatically — approve it once, not per-origin.** This is a cost/complexity win, but it also means those origins must use consistent ports; mixing ports on a shared PE is a documented routing-issue trap.

- **Front Door never mixes public and private origins in the same origin group — and converting multiple public origins to private simultaneously can trip this constraint transiently**, because the platform updates origins sequentially rather than atomically. Convert one at a time to avoid the error.

- **Health probes travel the same private path as real traffic** — an unhealthy-looking origin group on a Private Link origin genuinely reflects the private path's health, not a separate public check that could mask a real private-path outage.

- **mTLS is unsupported for Private Link origins (and public ones) — full stop.** Don't spend time hunting for a setting; this is a documented platform gap requiring an architectural workaround if it's a hard requirement. [MS Docs: Azure Private Link overview](https://learn.microsoft.com/en-us/azure/private-link/private-link-overview)
