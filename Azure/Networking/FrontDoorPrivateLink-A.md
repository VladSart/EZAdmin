# Azure Front Door Premium — Private Link Origins — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains the reversed consumer/resource relationship and platform limitations, not just the fix commands.

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
- Azure Front Door **Premium** connecting to an origin via Azure Private Link (Standard and Classic cannot do this at all)
- The connection-approval workflow, Private Endpoint creation/reuse/deletion mechanics specific to Front Door's managed regional VNet
- Supported and unsupported origin types
- Region availability constraints and the latency trade-off of picking a non-ideal region
- Rate limiting specific to Private Link origin traffic (7200 RPS/region/profile)
- Mixed origin group and multi-origin conversion pitfalls

**Out of scope:**
- **General Private Link/Private Endpoint mechanics** (connection state machine fundamentals, DNS Zone Group automation, network-policy exemptions) — covered generically in `PrivateLink-A.md`/`PrivateLink-B.md`. This file assumes that foundation and documents only what's specific to Front Door as the PE *consumer*.
- **Front Door's general architecture, routing, WAF, and certificate behavior** — covered in `FrontDoor-A.md`/`FrontDoor-B.md`. This file assumes an existing, working Front Door Premium profile with at least one origin group.
- **The origin resource's own Private Link enablement requirements** (e.g., what it takes to make a Storage account or App Service Private Link-capable in the first place) — covered by each origin type's own MS Learn "how-to" article; this file covers the Front Door side of the handshake, not the origin's initial setup.
- **Azure Front Door (classic)** — Private Link origins never existed on Classic; not addressed further here.

**Assumptions:**
- Front Door Premium tier profile already exists
- Origin is one of the documented supported types (see below)
- Reader has Contributor (or higher) on both the Front Door profile's resource group AND the origin resource's resource group — approving the Private Endpoint connection requires access to the origin side, which is very often a different team/subscription than the one managing Front Door

---

## How It Works

<details><summary>Full architecture</summary>

### The Reversed Consumer Relationship

In a standard Private Link scenario (see `PrivateLink-A.md`), a **client** creates a Private Endpoint in its own subnet to reach a PaaS resource privately — the client is the consumer, the PaaS service is the resource being connected to.

**Front Door Premium's Private Link origin feature inverts this.** Front Door itself is the consumer: when you enable Private Link on an origin, Front Door creates a Private Endpoint **from its own Microsoft-managed regional virtual network** — not from any VNet you own or can see — and sends a connection request to the origin resource. The **origin owner** (who may be an entirely different team than whoever manages the Front Door profile) must approve that request before any traffic flows.

```
Client (public internet)
        │
Front Door Global POP (anycast edge — same as any Front Door traffic)
        │  (Microsoft backbone network)
Front Door Regional Cluster
   └── Front Door-managed Private VNet (you cannot see or manage this VNet directly)
           └── Dedicated Private Endpoint (created BY Front Door, FOR this origin)
                       │  (Private Link platform, over Microsoft backbone)
                       ▼
                  Your Origin (App Service / Storage / ILB / APIM / App Gateway / Container Apps)
```

Because the Private Endpoint lives in Front Door's own managed subscription, clicking into it directly in the Azure Portal returns *"You don't have access"* — this is expected, not a permissions bug (see Troubleshooting Steps, Phase 4).

### Supported Origin Types

| Origin type | Notes |
|---|---|
| App Service (Web App, Function App) | Not supported for **Slots** |
| Blob Storage | |
| Storage Static Website | Distinct capability/how-to from plain Blob Storage |
| Internal Load Balancer | Includes anything that exposes an ILB, e.g. AKS or Azure Red Hat OpenShift internal services |
| API Management | |
| Application Gateway | Front Door (global) → Private Link → Application Gateway (regional) → backend is a legitimate, documented layered pattern |
| Azure Container Apps | |

**Explicitly unsupported:** App Service **Slots**, and **Static Web Apps** — both commonly assumed to inherit App Service's support since they're adjacent products, and both a source of "why won't this option appear" tickets.

### Region Availability and the Latency Trade-off

Front Door Private Link is available only in a curated list of regions — specifically those with **Availability Zone support**, since the feature requires zonal resiliency. The list spans most but not all Azure regions across the Americas, Europe, Middle East/Africa, and Asia Pacific (plus Azure Government/Secret/Top Secret regions), and changes over time as new regions gain AZ support.

The feature is technically **region-agnostic** — you can pick any supported region regardless of where your origin actually lives — but Microsoft's own guidance is to always pick the **region closest to the origin** to minimize added latency. If the origin's own region isn't in the supported list, pick the nearest supported region instead; this introduces an additional network hop (client → FD POP → FD regional cluster in the chosen PL region → Private Link → origin, potentially in a different region than the PL endpoint) worth measuring with Azure's published inter-region latency statistics before committing to a design.

### Private Endpoint Creation, Reuse, and Deletion

This is the single most consequential and least intuitive mechanic in the whole feature:

**Reuse rule:** Within a single Front Door profile, if two or more Private Link-enabled origins share the exact same **resource ID + Group ID + region**, Front Door creates and reuses **one** Private Endpoint for all of them. You approve it once; every origin matching that tuple rides the same connection with no further approval needed.

**New-PE triggers:**
- Any origin whose resource ID, Group ID, or region **differs** from an existing one gets its own new Private Endpoint, requiring its own approval.
- Private Link-enabled origins in **different Front Door profiles** always get separate Private Endpoints, even if every other parameter matches — PE reuse is scoped to a single profile only.

**Known limitation on shared PEs:** avoid pointing multiple origins at the identical resource ID + Group ID + region tuple while using **different HTTP/HTTPS ports** on those origins — Microsoft's documentation explicitly flags this as a platform limitation that can cause routing issues between Front Door and the origin, since the underlying shared PE doesn't cleanly disambiguate by port the way separate PEs would.

**Deletion cascade:** deleting a Front Door profile deletes every Private Endpoint it created — but only the ones tied to *that* profile. A shared PE reused across origin groups within one profile is deleted once, cleanly, when the profile goes; a PE created for a different profile (even against the identical origin) is entirely unaffected.

### Mixing Public and Private Origins

An origin group can contain **only** private origins or **only** public origins — never a mix. This is enforced at the platform level, not a soft warning. The most common way to trip it isn't a deliberate misconfiguration, but **converting two or more existing public origins to Private Link at the same time**: Front Door processes origin updates sequentially, not atomically, so mid-batch there's a real (if brief) window where the group is genuinely mixed, and the platform rejects the operation with an explicit mixed-state error.

### Rate Limiting Specific to Private Link Traffic

For platform protection, each **Front Door regional cluster** enforces a limit of **7200 requests per second (RPS) per Front Door profile** for Private Link traffic. Traffic beyond that ceiling at a given region is rate-limited with HTTP 429. This is separate from any general Front Door or WAF rate-limiting you may have configured yourself.

The documented mitigation is **deploying multiple origins, each registered against a different Private Link region**, within the same origin group — this spreads traffic across multiple regional clusters rather than funneling all of it through one. If maintaining fully separate application instances per region isn't feasible, Microsoft's own guidance is that you can still register multiple origins pointing at the **same hostname** but with **different Private Link regions**; Front Door will route to the same backend instance but via different regional clusters, relieving the per-cluster cap.

### mTLS Is Not Supported

Azure Front Door does not support client/mutual TLS authentication to origins — public or Private Link-enabled. This is a flat platform gap with no configuration path around it on Front Door itself; if mutual TLS is a hard security requirement, it needs to be satisfied by a layer behind Front Door (e.g., validating the `X-Azure-FDID` header Front Door sends, or placing Application Gateway/API Management between Front Door and the true backend to terminate mTLS there).

### Health Probes Follow the Private Path

Front Door's health probes for a Private Link-enabled origin travel over the **same private connection** as real traffic — there is no separate public-path probe. This means an origin group showing all origins unhealthy on a Private Link origin is a genuine reflection of the private path's actual health (connection state, origin responsiveness), not a false signal from a probe that couldn't reach the origin the way real traffic could.

</details>

---

## Dependency Stack

```
Front Door Premium profile
        │
Origin type supported for Private Link (App Service / Storage / Storage Static Website /
   ILB / APIM / App Gateway / Container Apps — NOT App Service Slots, NOT Static Web Apps)
        │
Private Link region selected (must support Availability Zones; ideally nearest to the origin)
        │
Front Door creates a Private Endpoint from its OWN managed regional VNet
   (reused automatically for any other origin in the same profile sharing
    resource ID + Group ID + region; new PE otherwise)
        │
Origin owner approves the pending connection (on the ORIGIN resource, not the FD profile)
        │
Connection establishes (allow a few minutes) → Status = Approved
        │
Origin group contains ONLY private origins, or ONLY public origins (never mixed)
        │
Health probes + real traffic both flow: FD POP → backbone → FD regional cluster →
   managed VNet → Private Endpoint → origin
        │
7200 RPS/region/profile ceiling enforced — exceeding it returns 429 regardless of origin health
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| All requests to a newly Private Link-enabled origin fail | Connection never approved by origin owner | `SharedPrivateLinkResource.Status` |
| Requests fail for the first few minutes after approval, then recover | Expected connection-establishment delay | Wait, re-check `Status` after ~5 min |
| "Origin Group can only have origins with private links or origins without private links" error | Mixed-group state, often from converting multiple public origins to private simultaneously | List origins' `SharedPrivateLinkResource` presence |
| Traffic to two origins on the same backend behaves inconsistently | Shared Private Endpoint reused across origins with different ports | Group origins by resource ID+GroupId+region, compare ports |
| 429 "Too Many Requests" under load, origin backend healthy and under capacity | 7200 RPS/region/profile platform cap for Private Link traffic | Check request volume against the regional cluster ceiling |
| Client wants mTLS to the origin and can't find the setting | Not supported for any Front Door origin, public or private | Confirm with client this is a platform gap, propose an alternate control |
| Portal "You don't have access" clicking the PE object | PE lives in a Microsoft-managed subscription, expected | Manage via the origin resource's own PE Connections blade/cmdlets instead |
| Deleted a Front Door profile and a shared origin's Private Endpoint vanished for another profile too | Misunderstanding of PE scoping — should NOT happen; PE reuse never crosses profiles | Re-verify which profile actually owned the deleted PE |
| Option for Private Link doesn't appear on an origin at all | Wrong tier (Standard/Classic) or unsupported origin type (Slot / Static Web App) | `Sku.Name`; origin resource type |
| Latency higher than expected on a Private Link origin vs. the same origin public | Private Link region chosen isn't the nearest supported region to the origin | Compare configured PL region to origin's actual region using Azure inter-region latency stats |

---

## Validation Steps

**1. Confirm tier supports the feature at all:**
```powershell
(Get-AzFrontDoorCdnProfile -ResourceGroupName <rg> -ProfileName <profileName>).Sku.Name
```
Expected/good: `Premium_AzureFrontDoor`. Bad: anything else — the feature simply isn't available.

**2. Confirm the origin resource type is supported:**
Cross-reference the origin's Azure resource type against the supported list above. Expected/good: one of the seven listed types, and not a Slot or Static Web App. Bad: an unsupported type — no amount of configuration will surface the option.

**3. Confirm the Private Link connection state on the origin:**
```powershell
(Get-AzFrontDoorCdnOrigin -ResourceGroupName <rg> -ProfileName <profileName> -OriginGroupName <ogName> -OriginName <originName>).SharedPrivateLinkResource
```
Expected/good: `Status = Approved`. Bad: `Pending` (needs origin-side approval), `Rejected`/`Timeout` (needs a fresh request).

**4. Confirm the connection was approved from the ORIGIN resource, not attempted from the Front Door side:**
```powershell
Get-AzPrivateEndpointConnection -ResourceGroupName <originRg> -ServiceName <originResourceName> -PrivateLinkResourceType <resourceType>
```
Expected/good: a connection entry with `PrivateLinkServiceConnectionState.Status = Approved` and a description referencing Front Door. Bad: no matching connection object (request never reached the origin, or was deleted).

**5. Confirm origin-group homogeneity:**
```powershell
(Get-AzFrontDoorCdnOrigin -ResourceGroupName <rg> -ProfileName <profileName> -OriginGroupName <ogName>) |
    Select-Object Name, @{N='PrivateLink';E={$null -ne $_.SharedPrivateLinkResource}}
```
Expected/good: every row identical (`$true` for all, or `$false` for all). Bad: a mix.

**6. Confirm no port conflict on a shared Private Endpoint:**
```powershell
$origins | Where-Object { $_.SharedPrivateLinkResource } |
    Group-Object { "$($_.SharedPrivateLinkResource.PrivateLink)|$($_.SharedPrivateLinkResource.GroupId)|$($_.SharedPrivateLinkResource.PrivateLinkLocation)" } |
    Where-Object Count -gt 1 | ForEach-Object { $_.Group | Select-Object Name, HttpPort, HttpsPort }
```
Expected/good: origins sharing a PE all use identical ports. Bad: differing ports on a shared PE.

**7. Confirm the chosen Private Link region against the origin's actual region:**
Compare `SharedPrivateLinkResource.PrivateLinkLocation` against the origin resource's own region. Expected/good: same region, or the nearest AZ-supported region if the origin's own region isn't on Front Door's supported list. Bad: an arbitrarily distant region adding avoidable latency.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Confirm the feature can exist here at all**
Check tier (`Premium_AzureFrontDoor`) and origin type support before anything else. A Standard-tier or unsupported-origin-type ticket masquerading as a "Private Link isn't working" ticket wastes time on a feature that was never available.

**Phase 2 — Confirm the connection-approval handshake completed**
Check `SharedPrivateLinkResource.Status` on the Front Door side, then cross-check `Get-AzPrivateEndpointConnection` on the origin side. Remember these are frequently managed by **different teams** — the Front Door admin may not have rights to approve on the origin, and vice versa. This is the most common real-world delay: the request sits Pending because nobody with origin-side access knew it needed approval.

**Phase 3 — Rule out the transient establishment window**
If `Status` just flipped to `Approved`, allow a few minutes before escalating "still broken" — this is documented, expected behavior, not a fault.

**Phase 4 — Check origin-group and shared-PE constraints**
Homogeneity (all-private or all-public) and port consistency on shared PEs are both platform-enforced constraints that produce confusing symptoms (an outright rejection error, or inconsistent per-origin behavior) rather than a clear single root cause pointing at themselves.

**Phase 5 — Check for the platform-level rate ceiling**
If everything above checks out and the symptom is specifically 429s that correlate with traffic volume, this is very likely the 7200 RPS/region/profile cap — confirm via request-volume metrics before assuming an origin-side throttle or WAF rate-limit rule is responsible.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Standing up a new Private Link origin end to end</summary>

1. Confirm profile is Premium tier and origin type is supported (Phase 1 above).
2. Choose a Private Link region — prefer the origin's own region if it supports Availability Zones; otherwise the nearest supported region.
3. Configure the origin with `SharedPrivateLinkResource` pointing at the origin's resource ID, the correct Group ID for that resource type, and the chosen region.
4. Notify/coordinate with the origin owner (may be a different team) that a Private Endpoint connection request is incoming and needs approval.
5. Approve the connection from the origin side (`Approve-AzPrivateEndpointConnection`).
6. Wait several minutes for connection establishment before testing.
7. If adding this as one of multiple origins in a group, ensure any existing origins in that group are ALSO private (or convert them one at a time per Playbook 2) and that ports match if this origin shares a PE with another.
8. Validate end-to-end with a real request, then confirm health probe status shows healthy over the private path.

**Rollback:** Remove the `SharedPrivateLinkResource` configuration from the origin to revert to public connectivity — only appropriate if the origin is safe to expose publicly in the interim.

</details>

<details><summary>Playbook 2 — Converting an existing public origin group to Private Link without an outage</summary>

1. If the group has multiple origins, do **not** attempt to convert them all in one batch update — the platform processes sequentially and will reject the operation with the mixed-state error.
2. Reduce the origin group (temporarily) to a single origin, or ensure only one origin is being converted per operation.
3. Enable Private Link on that one origin; approve its connection; confirm `Approved` and a successful test request.
4. Only after the first origin is fully private and validated, convert/add the next origin the same way.
5. Repeat until every origin in the group is private.

**Rollback:** At any point, an unconverted origin can remain public if the group currently contains it alone (single-origin groups aren't subject to the mixed-state constraint mid-conversion the same way a multi-origin group is) — halt the conversion there if issues arise, and resume later.

</details>

<details><summary>Playbook 3 — Relieving the 7200 RPS/region cap</summary>

1. Confirm via metrics that 429s correlate specifically with request volume approaching or exceeding 7200 RPS at a single region/cluster.
2. Identify one or more additional Private Link regions supported by Front Door.
3. Add additional origin(s) in the same origin group pointing at the same backend (same hostname is fine) but registered under a different `SharedPrivateLinkResourcePrivateLinkLocation`.
4. Confirm Front Door's load balancing now distributes traffic across the regional clusters tied to each origin's PL region.
5. Re-monitor for 429s; add further regions if volume still exceeds capacity even after spreading across two.

**Rollback:** Remove the added region-specific origin(s) if this doesn't relieve the 429s, which would indicate the actual bottleneck is elsewhere (origin-side scaling, a WAF rate-limit rule, or a client-side retry storm).

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Front Door Premium Private Link origin evidence for escalation.
#>
param(
    [Parameter(Mandatory)][string]$ResourceGroupName,
    [Parameter(Mandatory)][string]$ProfileName,
    [Parameter(Mandatory)][string]$OriginGroupName
)

$evidence = [ordered]@{
    Timestamp   = Get-Date -Format o
    ProfileSku  = (Get-AzFrontDoorCdnProfile -ResourceGroupName $ResourceGroupName -ProfileName $ProfileName).Sku.Name
    Origins     = @()
}

$origins = Get-AzFrontDoorCdnOrigin -ResourceGroupName $ResourceGroupName -ProfileName $ProfileName -OriginGroupName $OriginGroupName

foreach ($o in $origins) {
    $evidence.Origins += [pscustomobject]@{
        Name                = $o.Name
        HttpPort            = $o.HttpPort
        HttpsPort           = $o.HttpsPort
        PrivateLinkEnabled  = $null -ne $o.SharedPrivateLinkResource
        PLResourceId        = $o.SharedPrivateLinkResource.PrivateLink
        PLGroupId           = $o.SharedPrivateLinkResource.GroupId
        PLRegion            = $o.SharedPrivateLinkResource.PrivateLinkLocation
        PLStatus            = $o.SharedPrivateLinkResource.Status
        PLRequestMessage    = $o.SharedPrivateLinkResource.RequestMessage
    }
}

$evidence | ConvertTo-Json -Depth 5
$evidence.Origins | Export-Csv -Path ".\FrontDoorPrivateLink-Evidence-$(Get-Date -Format yyyyMMdd-HHmmss).csv" -NoTypeInformation
```

---

## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `(Get-AzFrontDoorCdnProfile ...).Sku.Name` | Confirm Premium tier |
| `Get-AzFrontDoorCdnOrigin ... \| Select SharedPrivateLinkResource` | Per-origin Private Link connection state |
| `Get-AzPrivateEndpointConnection -ServiceName <origin>` | View/approve the connection from the origin side |
| `Approve-AzPrivateEndpointConnection` | Approve a pending connection (run on the origin) |
| `Update-AzFrontDoorCdnOrigin -SharedPrivateLinkResource...` | Configure/clear Private Link on an origin |
| `Group-Object` on resourceId+GroupId+region | Detect origins sharing (and potentially port-conflicting on) one PE |
| `Get-AzFrontDoorCdnLogAnalyticsMetric -MetricName RequestCount` | Correlate 429s with request volume against the 7200 RPS cap |
| `Clear-AzFrontDoorCdnEndpointContent` | Purge cache (same as any Front Door origin, unrelated to Private Link itself) |

---

## 🎓 Learning Pointers

- **Front Door is the Private Endpoint consumer here — the opposite direction from the typical Private Link pattern.** It creates the PE from its own managed VNet and requests approval from the origin; internalize this before applying `PrivateLink-A.md`'s general "client creates PE, resource owner approves" mental model unmodified. [MS Docs: Secure your origin with Private Link in Azure Front Door Premium](https://learn.microsoft.com/en-us/azure/frontdoor/private-link)

- **The origin owner and the Front Door admin are frequently different people or teams — coordinate the approval step explicitly.** The single most common real-world delay isn't a technical fault; it's a pending request nobody with origin-side access knew existed.

- **Private Endpoint reuse is scoped to resource ID + Group ID + region, within one profile only.** Understanding this correctly prevents two mistakes: assuming every origin needs its own separate approval (it doesn't, if it matches an existing tuple), and assuming a PE can be shared across Front Door profiles (it can't, ever).

- **7200 RPS per regional cluster per profile is a hard platform ceiling for Private Link traffic specifically** — distinct from, and not fixable via, any WAF rate-limit rule or origin-side throttling setting. The only documented mitigation is spreading origins across multiple Private Link regions. [MS Docs: Azure Front Door Private Link FAQ](https://learn.microsoft.com/en-us/azure/frontdoor/private-link)

- **mTLS to the origin is unsupported on Front Door, period — public or private.** Don't burn time looking for a setting; this requires an architectural workaround (header validation, or a downstream layer that does terminate mTLS) if it's a hard requirement.

- **Origin groups cannot mix public and private origins, and the platform's sequential (non-atomic) update processing can trigger this error even when the end state you're aiming for is fully consistent** — converting multiple origins to Private Link in one batch is the classic way to trip it. Convert one at a time.
