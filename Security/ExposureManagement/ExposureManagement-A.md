# Microsoft Security Exposure Management — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

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

Covers **Microsoft Security Exposure Management (MSEM)** — the unified posture-management platform inside the Microsoft Defender portal that aggregates endpoint, cloud (Azure/AWS/GCP via Defender for Cloud), identity, external attack surface, and third-party security data into a single **enterprise exposure graph**, and builds Critical Asset Management, Security Initiatives, and Attack Path analysis on top of it. Covers licensing/prerequisites, the dual RBAC model, data freshness/retention characteristics, critical asset classification, initiatives, attack paths, and data connectors.

**Explicitly out of scope (covered elsewhere, overlapping terminology, different products):**
- **Cloud Infrastructure Entitlement Management (CIEM)** — a Defender for Cloud CSPM sub-feature covering identity/permission-risk analysis across Azure/AWS/GCP, whose own Attack Path Analysis output is one of several signals feeding into MSEM's broader graph, but which is configured, licensed, and consumed as its own distinct capability. See `Security/Defender/CIEM-A.md`/`-B.md`.
- **Microsoft Sentinel graph** — a code-first, custom-query (GQL) hunting surface for security analysts, sharing underlying graph-platform infrastructure with MSEM but serving an entirely different consumption model and audience. See `Security/Sentinel/SentinelGraph-A.md`.
- **Microsoft Secure Score** — a separate tenant-wide scoring surface (Identity/Device/Apps/Data categories) that MSEM's initiative recommendation lists partially draw from, but which has its own independent scoring model, API, and admin surface. See `Security/Defender/SecureScore-A.md`.
- **Microsoft Defender Vulnerability Management (MDVM)** as a standalone topic — MDVM is a prerequisite data source feeding MSEM's device posture signal, not something this topic administers directly.
- **External Attack Surface Management (EASM) as a standalone product** — this topic covers EASM only as one of MSEM's built-in Security Initiatives; deep EASM-specific reconnaissance/inventory configuration is out of scope here.
- Third-party data-connector-specific configuration (ServiceNow CMDB, Tenable, Qualys, Rapid7 field mapping) beyond the RBAC permission required to configure a connector.

---
## How It Works

<details><summary>Full architecture</summary>

MSEM's core architectural idea is a **single enterprise exposure graph** that unifies asset and posture data that was previously siloed across separate Defender products, then layers three consumer experiences on top of that graph: **Critical Asset Management**, **Security Initiatives**, and **Attack Path analysis**. With the integration of Defender for Cloud directly into the Defender portal, this graph now spans endpoints, cloud resources (Azure/AWS/GCP), identities, and external attack surface data in one unified inventory — aligning with Gartner's Continuous Threat Exposure Management (CTEM) framework of continuous discovery, prioritization, and validation.

**Availability constraint:** MSEM is **Public Cloud only**. It is explicitly not available in US Gov, China Gov, or other sovereign/national clouds — a hard platform limitation, not a licensing gap that can be purchased around.

**Data sources feeding the graph:**
- Microsoft Defender for Endpoint / Microsoft Defender Vulnerability Management (device posture, exposure scoring)
- Microsoft Defender for Cloud with CSPM capabilities (Azure, AWS, GCP cloud misconfigurations and multicloud assets)
- External Attack Surface Management (EASM) discovery
- Third-party data connectors — currently **public preview** with separate consumption-based pricing; free to use during the preview period, becoming consumption-based (priced per asset retrieved) once generally available. Supported connectors include ServiceNow CMDB, Tenable, Qualys, and Rapid7.

**Data freshness and retention — a deliberately narrow model, not a full historical system:**
- Data is ingested and made available in the graph within **72 hours** of production at the source product.
- Microsoft product data is retained for **no less than 14 days**, but only the **latest snapshot** is stored — there is no historical trend data beyond what Initiatives explicitly track (their own 14-day trend/drift graphs and History view) or what Events capture. Microsoft explicitly reserves the right to widen the ingestion latency window or shorten the retention period in the future.
- Some graph data is queryable via **Advanced Hunting** (subject to Advanced Hunting's own service limitations), through two dedicated schemas: `ExposureGraphNodes` and `ExposureGraphEdges`.

**RBAC — two independent, simultaneously-supported models, evaluated as alternatives:**

1. **Microsoft Defender unified RBAC.** Custom roles under the **Security posture** permission category, with two MSEM-specific permissions:
   - **Exposure Management (read)** — access to all Exposure Management experiences, read-only.
   - **Exposure Management (manage)** — read access plus the ability to set initiative target scores and edit metric values, **conditional on the user also having access to all Defender for Endpoint device groups**.
   A third permission, **Core security settings (manage)** (under the *Authorization and settings* category, not Security posture), is required specifically to connect or change the EASM initiative's vendor — this is easy to miss since it lives in a different permission category entirely.
   Critically, **any custom role must be explicitly assigned to the "Microsoft Security Exposure Management" data source** to actually grant MSEM access — a role with the right permission name but the wrong (or no) data source assignment does nothing.

2. **Legacy Microsoft Entra ID roles.** An alternative access path via ten specific Entra roles, each with a different permission ceiling documented in a detailed action-by-role matrix (grant permissions to others; onboard EASM; favorite an initiative; set target score; view initiatives; share/export metrics; edit metric weight; manage/view recommendations; export events; change criticality level; set/create/toggle critical asset rules; run exposure graph queries; configure/view data connectors). At minimum one **Global Administrator or Security Administrator** must exist in the tenant to create the initial Exposure Management workspace. Global Reader and Security Reader are read-only across the entire matrix; Security Operator gets limited write (criticality level changes, toggling criticality rules) but cannot set target scores, edit metric weights, or create criticality rules; only Global Administrator and Security Administrator get near-full write access.

   These two models are **not layered** — a user's effective access is whichever of the two grants them the broader permission, and a tenant can have some users governed by each simultaneously with zero built-in cross-validation between them. This is the single most common source of "my RBAC configuration doesn't match what the user can actually do" confusion.

**Device-group scoping — applies on top of whichever RBAC model grants access:** full MSEM access (both "manage" actions and unrestricted visibility) requires the user's role to cover **all** Defender for Endpoint device groups. A user restricted to a subset of device groups still gets global exposure insights data, but their view of metrics, recommendations, events, and initiative history is filtered to assets within their scope, and attack path visibility is limited to devices within scope. Critical Asset Management "manage" permission specifically requires access to all device groups with no scoped-access equivalent at all.

**Critical Asset Management** identifies and prioritizes business-critical assets across devices, identities, and cloud resources using three mechanisms: automatic classification against a **predefined catalog** (domain controllers, file servers, sensitive databases, identity groups like Power Users, privileged roles like Privileged Role Administrator, cloud resources from Azure/AWS/GCP, and third-party-discovered external assets), **custom classifications** built via a query builder against any asset domain, and **manual asset review** to add assets that matched a classification with lower confidence or that fall outside any automated classification entirely. Predefined classifications cannot be edited — only turned off (and Microsoft's own documentation notes the toggle may not be visible to some users due to a known display issue). Custom classifications can be freely edited, deleted, or toggled. Device-level classification requires a Defender for Endpoint sensor version of **10.3740.XXXX or later** — an easy silent gap on fleets running older sensors, since there's no error, just an absent classification.

**Security Initiatives** provide metric-driven tracking of exposure in a specific area (e.g., Ransomware, Critical Asset Protection, External Attack Surface Management) — each initiative has a current score, a 14-day trend/drift graph, an optional custom target score (Global Admin/Security Admin only), a History view (drilling into up to the top 100 changed assets behind any score-affecting event), and associated metrics and recommendations. **The recommendations shown under an initiative are a filtered view of recommendations currently active in Microsoft Secure Score or Microsoft Defender for Cloud — MSEM does not maintain an independent remediation-tracking system.** This is architecturally important: fixing something in the owning workload is what actually changes an initiative's recommendation state; there's no separate "mark resolved" action inside MSEM itself for these.

**Attack Path analysis** correlates data across the enterprise exposure graph to simulate how an attacker could move through the environment — including **hybrid attack paths that explicitly span on-premises and cloud contexts** — and surfaces **choke points**: single assets or misconfigurations through which a disproportionate number of attack paths converge, making them high-leverage remediation targets. This capability consumes the same underlying platform Sentinel's own custom graph hunting is built on, and the same misconfiguration data CIEM's Defender-for-Cloud-scoped Attack Path Analysis produces — the three are related by shared infrastructure, not by being the same feature under different names.

</details>

---
## Dependency Stack

```
Tenant licensing: M365 E5 / E3+add-ons / Defender suite qualifying plan
(Public Cloud only — hard platform exclusion for Gov/China/sovereign clouds)
        │
Microsoft Defender portal (security.microsoft.com) — Exposure Management
built into the unified portal, no separate deployment
        │
RBAC (either path — not stacked):
   ├── Defender unified RBAC: "Exposure Management (read/manage)" custom role,
   │   assigned to the "Microsoft Security Exposure Management" data source;
   │   "Core security settings (manage)" separately required for EASM vendor changes
   └── Legacy Entra ID role: Global Admin / Security Admin / Security Operator /
       Global Reader / Security Reader / Service Support Admin / User Admin /
       Helpdesk Admin / Exchange Admin / SharePoint Admin
        │
Device-group RBAC scope (Defender for Endpoint) — gates full vs. restricted
visibility and ALL "manage"-tier actions
        │
Data sources → enterprise exposure graph:
   ├── Defender for Endpoint / Defender Vulnerability Management
   ├── Defender for Cloud CSPM (Azure / AWS / GCP)
   ├── External Attack Surface Management discovery
   └── Third-party data connectors (Preview — ServiceNow CMDB, Tenable, Qualys, Rapid7)
        │
Ingestion latency ≤ 72h; retention ≥ 14 days, latest-snapshot-only
        │
Consumer experiences:
   ├── Critical Asset Management (predefined + custom + manual review;
   │   device classification requires DFE sensor ≥ 10.3740.XXXX)
   ├── Security Initiatives (metric-driven scores; recommendations are a FILTERED
   │   VIEW over Secure Score / Defender for Cloud, not independently tracked)
   └── Attack Path analysis (hybrid on-prem + cloud; choke-point identification;
       queryable via Advanced Hunting ExposureGraphNodes / ExposureGraphEdges)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Exposure Management section missing entirely | Wrong cloud environment (Gov/China/sovereign) or missing license | Confirm Public Cloud tenant + E5/Defender suite licensing |
| User has RBAC assigned but access doesn't match expectation | Dual RBAC-model confusion — the *other* model is actually governing access | Check both legacy Entra roles AND Defender unified RBAC custom role/data source assignment |
| Can't set initiative target score / edit metric weight | Role tier too low (Security Operator/Reader insufficient) | Confirm Global Admin/Security Admin or "Exposure Management (manage)" |
| Recommendation resolved elsewhere but still shows under an initiative | Initiative recommendation list is a filtered view, not independently tracked; sync latency | Confirm status in the owning workload (Secure Score/Defender for Cloud) directly |
| "Stale data" complaint after a recent fix | 72-hour ingestion latency; 14-day-only retention | Compare elapsed time since the fix against the latency window |
| Device not showing expected critical-asset classification | DFE sensor below `10.3740.XXXX`, or low-confidence match needing manual review | `DeviceInfo \| project DeviceName, ClientVersion` |
| Scoped/delegated admin missing recommendations, metrics, or assets others see | Device-group RBAC scoping — by design | Confirm the role's device-group access |
| Can't connect/change EASM vendor despite having Exposure Management (manage) | Missing "Core security settings (manage)" — a separate permission category | Grant explicitly; not implied by Exposure Management (manage) |
| Cloud (AWS/GCP/Azure) resources thin or missing from graph/attack paths | Defender for Cloud CSPM plan not enabled, or multicloud connector "Configure access" incomplete | Confirm CSPM plan status per subscription/connector |
| Third-party connector (ServiceNow/Tenable/Qualys/Rapid7) data missing | Connector in Preview — free during preview but may not be configured, or awaiting the eventual GA consumption-billing cutover | Confirm connector configuration status and preview/GA state |
| "Attack Path Analysis" behaves differently than expected / user references a feature that doesn't match MSEM's UI | Wrong product — likely means CIEM's Defender-for-Cloud Attack Path Analysis or Sentinel graph | Disambiguate per the Scope & Assumptions cross-references before troubleshooting further |

---
## Validation Steps

1. **Confirm licensing and cloud environment.**
   ```powershell
   Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits
   ```
   Good: an E5, qualifying E3 add-on, or Defender suite SKU present; tenant confirmed Public Cloud. Bad: no qualifying SKU, or tenant is Gov/China/sovereign cloud (hard exclusion, not fixable via licensing).

2. **Confirm the user's legacy Entra ID role membership.**
   ```powershell
   Get-MgUserMemberOf -UserId "<user@domain.com>" | Select-Object -ExpandProperty AdditionalProperties
   ```
   Good: one of the 10 qualifying roles present, matching the access level expected. Bad: none present — check the Defender unified RBAC model instead before concluding access is misconfigured.

3. **Confirm Defender unified RBAC custom role assignment (portal-only).** Defender portal → Permissions & roles → Roles (Unified RBAC) → confirm a role with "Exposure Management (read/manage)" exists and is explicitly assigned to the **Microsoft Security Exposure Management** data source, and that the target user/group is assigned that role.

4. **Confirm device-group scope** for the role in question, in the same Unified RBAC role configuration screen or via Entra role scoping. Good: access to all device groups if full "manage" capability is expected. Bad: scoped access combined with a report of missing global data — expected behavior, not a defect.

5. **Confirm environmental prerequisites.**
   ```powershell
   Get-AzSecurityPricing | Select-Object Name, PricingTier
   ```
   Good: CSPM (or higher) plan enabled for relevant subscriptions. Bad: `Free` tier — cloud resource coverage in MSEM will be materially incomplete.

6. **Confirm device sensor version for critical asset classification.**
   ```kusto
   DeviceInfo | project DeviceName, ClientVersion
   ```
   (Advanced Hunting) Good: `10.3740.XXXX` or later. Bad: older — classification will silently not apply to that device.

7. **Confirm data freshness expectations against the 72-hour/14-day model** before treating any "missing recent change" report as a defect.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Access verification:** Confirm licensing and cloud environment first — these are hard gates with no workaround. Then check *both* RBAC models independently rather than assuming one governs the tenant.

**Phase 2 — Scope verification:** Confirm device-group RBAC scope for any partial-visibility report before investigating further — this accounts for a large share of "data is missing" tickets that are actually working as designed.

**Phase 3 — Data source verification:** Confirm the relevant upstream data source (Defender for Cloud CSPM, Defender for Endpoint sensor version, third-party connector configuration) is actually feeding the graph before assuming MSEM itself is malfunctioning — MSEM aggregates, it does not independently discover most of what it displays.

**Phase 4 — Freshness/consistency verification:** Confirm elapsed time since any expected change against the 72-hour ingestion latency and 14-day-only retention model before escalating a "stale data" report.

**Phase 5 — Product disambiguation:** For any ticket referencing "attack path," "exposure graph," or similar terminology that doesn't match what's actually in the MSEM UI, confirm which of the three related-but-distinct products (MSEM, CIEM, Sentinel graph) the user actually means before troubleshooting further.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Standing up MSEM access for a new security team from scratch</summary>

1. Confirm tenant licensing (E5/Defender suite) and Public Cloud environment.
2. Decide which RBAC model the tenant will standardize on — Defender unified RBAC (recommended for granular, least-privilege control) or legacy Entra ID roles (simpler, but coarser-grained). Document the decision; don't mix ad hoc.
3. If using Defender unified RBAC: create a custom role with "Exposure Management (read)" (analysts) or "Exposure Management (manage)" (team leads/architects) under Security posture, assign it to the **Microsoft Security Exposure Management** data source, and assign device-group scope matching the team's actual responsibility (all device groups for anyone needing full "manage" capability).
4. If using legacy Entra roles: assign **Security Reader** for view-only analysts, **Security Administrator** for anyone needing to set initiative targets or manage recommendations, reserving **Global Administrator** for emergency/break-glass scenarios only, per Microsoft's own least-privilege guidance.
5. Separately grant **Core security settings (manage)** to whoever owns EASM vendor configuration — don't assume it's covered by Exposure Management (manage) alone.
6. Confirm environmental prerequisites: Defender for Cloud CSPM enabled on all relevant cloud subscriptions/connectors, Defender Vulnerability Management enabled (standalone or via Defender for Endpoint P2).
7. Validate access end-to-end with a test user in each role tier before rolling out broadly.

</details>

<details><summary>Playbook 2 — Diagnosing and resolving a dual-RBAC-model access mismatch</summary>

1. Pull the user's legacy Entra ID role memberships (Command Cheat Sheet).
2. Pull the user's Defender unified RBAC custom role assignment(s) and confirm data-source scoping via the Defender portal (no Graph read surface exists for this — portal check required).
3. Compare both against the access level actually observed. If the observed access matches the *more* permissive of the two models, that's the one actually governing — the other assignment, if present, is redundant, not broken.
4. If the client wants to consolidate onto a single model going forward (recommended for auditability), plan the removal of the redundant assignment as a deliberate, documented change — not a live troubleshooting step, since removing the wrong one first could cause an unexpected access loss.

</details>

<details><summary>Playbook 3 — Investigating a "recommendation still open" discrepancy between MSEM and the owning workload</summary>

1. Identify the initiative and specific recommendation in question.
2. Check the same recommendation's status directly in its owning workload — Microsoft Secure Score (`security.microsoft.com/securescore`) or Defender for Cloud recommendations, depending on which one the recommendation actually belongs to.
3. If the owning workload shows it resolved but MSEM's initiative view still shows it open, this is a sync-latency issue — confirm elapsed time against the 72-hour ingestion window before escalating.
4. If the owning workload also shows it open, remediate there — MSEM has no independent "resolve" action for these recommendations; it is purely a downstream view.

</details>

<details><summary>Playbook 4 — Improving critical-asset coverage after a fleet-wide sensor-version gap is found</summary>

1. Run the sensor-version Advanced Hunting query (Command Cheat Sheet) fleet-wide to identify devices below `10.3740.XXXX`.
2. Prioritize sensor updates for devices matching predefined critical-asset classification patterns (domain controllers, file servers) first, since those are the highest-value gaps.
3. After updates propagate, re-check classification coverage — allow for the same 72-hour ingestion latency before expecting the graph to reflect newly-classified assets.
4. For assets that still don't classify automatically after the sensor update, use the manual asset-review feature (for low-confidence auto-matches) or build a custom classification (for organization-specific assets the predefined catalog doesn't cover).

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects MSEM-adjacent RBAC and prerequisite evidence for escalation.
    Portal-only state (initiative scores/history, attack path graph contents,
    critical asset classification details, data connector configuration) must
    be captured manually from the Defender portal per the Escalation Evidence
    template in ExposureManagement-B.md.
#>
param(
    [Parameter(Mandatory)] [string]$UserPrincipalName
)

Write-Host "=== Legacy Entra ID role membership ===" -ForegroundColor Cyan
$qualifyingRoles = @("Global Administrator","Security Administrator","Security Operator",
                      "Global Reader","Security Reader","Service Support Administrator",
                      "User Administrator","Helpdesk Administrator","Exchange Administrator",
                      "SharePoint Administrator")
Get-MgUserMemberOf -UserId $UserPrincipalName |
  Where-Object { $_.AdditionalProperties.displayName -in $qualifyingRoles } |
  Select-Object @{N='RoleName';E={$_.AdditionalProperties.displayName}} | Format-Table

Write-Host "=== Tenant licensing ===" -ForegroundColor Cyan
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits, @{N='Prepaid';E={$_.PrepaidUnits.Enabled}} | Format-Table

Write-Host "=== Defender for Cloud CSPM plan status ===" -ForegroundColor Cyan
try {
    Get-AzSecurityPricing | Select-Object Name, PricingTier | Format-Table
} catch {
    Write-Host "Az.Security module / Defender for Cloud not reachable in this session — check manually." -ForegroundColor Yellow
}

Write-Host "=== NOTE ===" -ForegroundColor Yellow
Write-Host "Defender unified RBAC custom role assignment to the 'Microsoft Security Exposure Management' data source has no Graph/PowerShell read surface — confirm via Defender portal → Permissions & roles → Roles (Unified RBAC)."
Write-Host "Device sensor version check: run 'DeviceInfo | project DeviceName, ClientVersion' in Defender portal → Advanced Hunting."
```

---
## Command Cheat Sheet

```powershell
# Legacy Entra ID role membership
Get-MgUserMemberOf -UserId "<user@domain.com>" | Select-Object -ExpandProperty AdditionalProperties

# Tenant licensing
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits

# Defender for Cloud CSPM plan status
Get-AzSecurityPricing | Select-Object Name, PricingTier
```

```kusto
// Device sensor version (Advanced Hunting) — critical asset classification requires 10.3740.XXXX+
DeviceInfo
| project DeviceName, ClientVersion

// Exposure graph — device nodes (Advanced Hunting, subject to AH service limits)
ExposureGraphNodes
| where NodeLabel == "device"
| take 50

// Exposure graph — relationship edges
ExposureGraphEdges
| take 50
```

**Portal navigation reference:**
- Exposure Management home: Defender portal → **Exposure management**
- Initiatives: **Exposure management → Exposure insights → Initiatives**
- Metrics: **Exposure management → Exposure insights → Initiatives → Security metrics**
- Recommendations: **Exposure management → Exposure insights → Initiatives → Security recommendations**
- Events: **Exposure management → Exposure insights → Events**
- Critical asset management (manage): **System → Settings → Microsoft Defender XDR → Critical asset management**
- Defender unified RBAC roles: **Permissions & roles → Roles (Unified RBAC)**

---
## 🎓 Learning Pointers

- **MSEM's core value proposition is unification, and its core troubleshooting trap is exactly the same thing — three products with overlapping "attack path"/"graph" vocabulary that share infrastructure but not configuration surfaces.** Leading every non-trivial MSEM ticket with a disambiguation step (this topic vs. CIEM vs. Sentinel graph) saves far more time than it costs.
- **The dual RBAC model is a permanent architectural feature, not a transitional state.** Treat "which model governs this user" as a standing question on every access ticket, not a one-time migration checklist item.
- **MSEM is fundamentally a read/aggregation layer over other products' remediation state, not an independent remediation system** — this is most visible in how Initiatives surface recommendations (a filtered view of Secure Score/Defender for Cloud) but is true more broadly: MSEM discovers and correlates, the owning workload remediates.
- **The 72-hour/14-day-snapshot-only data model means MSEM is unsuitable as a compliance audit trail or historical reporting source** on its own — pair it with the owning workload's own history/audit features (Secure Score history, Purview Audit, Defender for Cloud recommendation history) for anything requiring longer retention.
- **A single silent prerequisite (DFE sensor ≥ 10.3740.XXXX) gates an entire capability (critical asset classification) with zero error surfaced to the admin.** This is a recurring MSP pattern worth watching for across Microsoft's security stack generally — always check the "what's new" / minimum-version page for a feature before assuming a configuration problem.
- [MS Docs: What is Microsoft Security Exposure Management?](https://learn.microsoft.com/en-us/security-exposure-management/microsoft-security-exposure-management) · [MS Docs: Prerequisites and support](https://learn.microsoft.com/en-us/security-exposure-management/prerequisites) · [MS Docs: Critical asset management overview](https://learn.microsoft.com/en-us/security-exposure-management/critical-asset-management) · [MS Docs: Review security initiatives](https://learn.microsoft.com/en-us/security-exposure-management/initiatives) · [MS Docs: Manage RBAC (Defender unified RBAC)](https://learn.microsoft.com/en-us/defender-xdr/manage-rbac)
