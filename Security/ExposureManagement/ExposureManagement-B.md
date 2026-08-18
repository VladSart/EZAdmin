# Microsoft Security Exposure Management — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Microsoft Security Exposure Management (MSEM) lives entirely inside the Microsoft Defender portal (`security.microsoft.com`) — there's no separate install and no standalone PowerShell module. RBAC is readable via Microsoft Graph; everything else (initiatives, critical assets, attack paths) is portal/Advanced-Hunting-only.

```powershell
Connect-MgGraph -Scopes "RoleManagement.Read.Directory","Directory.Read.All"

# 1. Does the user hold one of the 10 legacy Entra ID roles that grant MSEM access?
$roles = @("Global Administrator","Security Administrator","Security Operator","Global Reader",
           "Security Reader","Service Support Administrator","User Administrator",
           "Helpdesk Administrator","Exchange Administrator","SharePoint Administrator")
Get-MgUserMemberOf -UserId "<user@domain.com>" |
  Where-Object { $_.AdditionalProperties.displayName -in $roles } |
  Select-Object -ExpandProperty AdditionalProperties

# 2. (Portal — no Graph read surface) Does the user instead hold a Defender unified
#    RBAC custom role with "Exposure Management (read)" or "(manage)" assigned to the
#    "Microsoft Security Exposure Management" data source?
#    Defender portal → Permissions & roles → Roles (Unified RBAC)

# 3. Is the tenant licensed? (M365 E5 / E3+add-ons / Defender suite)
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits

# 4. Is Defender for Cloud CSPM enabled? (required for cloud-resource coverage)
#    Azure portal → Defender for Cloud → Environment settings → per-subscription plan status
#    (or: Get-AzSecurityPricing | Select-Object Name, PricingTier)

# 5. Is the device on a current-enough Defender for Endpoint sensor for critical
#    asset classification? (build 10.3740.XXXX or later required)
#    DeviceInfo | project DeviceName, ClientVersion   ← run in Advanced Hunting
```

| Result | Interpretation |
|---|---|
| User has neither a matching Entra role NOR a Defender unified RBAC role assigned to the MSEM data source | → Fix 1 |
| User has a role but sees a mostly-empty/read-only experience despite expecting "manage" access | → Fix 2 (dual RBAC-model confusion) or Fix 3 (role tier too low) |
| Tenant not licensed for E5/Defender suite | → escalate — licensing gap, not a config issue |
| Defender for Cloud CSPM not enabled for a cloud subscription | → Fix 9 |
| Device sensor below `10.3740.XXXX` | → Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Tenant licensing: M365 E5 / E3+add-ons / Defender suite
(Public Cloud only — NOT available in US Gov, China Gov, or other sovereign clouds)
        │
Microsoft Defender portal (security.microsoft.com) — built-in, no separate install
        │
RBAC — EITHER path grants access (they are alternatives, not stacked requirements):
   (a) Defender unified RBAC custom role with "Exposure Management (read)" or
       "(manage)" (under Security posture), assigned to the
       "Microsoft Security Exposure Management" data source specifically
   (b) One of 10 legacy Entra ID roles (Global Admin / Security Admin /
       Security Operator / Global Reader / Security Reader / Service Support
       Administrator / User Administrator / Helpdesk Administrator /
       Exchange Administrator / SharePoint Administrator) — at least one
       Global Admin or Security Admin is required tenant-wide just to CREATE
       the Exposure Management workspace the first time
        │
Device-group scope — "manage" actions and unrestricted visibility require
access to ALL Defender for Endpoint device groups; a role scoped to a subset
of device groups gets global insight data but only scoped metrics/
recommendations/events/attack-path visibility
        │
Environmental data sources feeding the enterprise exposure graph:
   ├── Defender for Endpoint / Defender Vulnerability Management (device posture)
   ├── Defender for Cloud CSPM (Azure / AWS / GCP cloud posture)
   ├── External Attack Surface Management (EASM) discovery
   └── Third-party data connectors (ServiceNow CMDB, Tenable, Qualys, Rapid7 — Preview)
        │
Ingestion latency ≤ 72 hours; 14-day minimum retention; LATEST SNAPSHOT ONLY
        │
Experiences: Attack surface map · Critical Asset Management · Security
Initiatives (metric-driven scores) · Attack Path analysis · Advanced Hunting
(ExposureGraphNodes / ExposureGraphEdges)
```

</details>

---
## Diagnosis & Validation Flow

1. **Disambiguate which product the ticket actually means before troubleshooting.** "Attack Path Analysis" and "exposure graph" terminology is shared across at least three distinct Microsoft products: Microsoft Security Exposure Management (this topic), Cloud Infrastructure Entitlement Management/CIEM inside Defender for Cloud (see `Security/Defender/CIEM-A.md` — CIEM's own Attack Path Analysis output is one of several signals that also surfaces inside MSEM's broader graph), and Microsoft Sentinel graph (see `Security/Sentinel/SentinelGraph-A.md` — a code-first custom-graph hunting surface that shares underlying platform infrastructure with MSEM but serves analysts writing GQL queries, not posture management). Confirm which portal surface the user was actually looking at before proceeding.

2. **Confirm licensing.** MSEM requires M365 E5, M365 E3 with qualifying add-ons, or a Defender suite license, and is **Public Cloud only** — it does not exist in US Gov, China Gov, or other sovereign cloud tenants. A sovereign-cloud tenant reporting "Exposure Management" missing entirely is not a bug.

3. **Confirm RBAC via the correct model.** There are two independent, non-overlapping ways to get access — a tenant using Defender unified RBAC exclusively may have users with a valid legacy Entra role who still can't act, and vice versa. Determine which model the tenant has actually standardized on before assigning more roles (see Fix 2).

4. **Confirm device-group scope** for any "I can see some things but not others" report — this is very often correct, by-design behavior tied to Defender for Endpoint device group RBAC, not a bug.

5. **Confirm data freshness expectations** before treating "this doesn't reflect what we just fixed" as a defect — see Fix 5.

6. **Confirm environmental prerequisites** (Defender for Cloud CSPM, Defender Vulnerability Management) are actually enabled if cloud or vulnerability data looks incomplete — MSEM aggregates these sources, it doesn't independently discover them.

---
## Common Fix Paths

<details><summary>Fix 1 — User can't see Exposure Management at all</summary>

1. Confirm tenant licensing (M365 E5 / E3+add-ons / Defender suite) and that the tenant is in Public Cloud (not a sovereign/Gov cloud).
2. Confirm the user holds **either** a Defender unified RBAC custom role with "Exposure Management (read)" assigned to the **Microsoft Security Exposure Management** data source, **or** one of the 10 qualifying legacy Entra ID roles (Triage step 1).
3. If neither is assigned, grant the lightest-privilege option that satisfies the need — per Microsoft's own recommendation, avoid defaulting to Global Administrator; **Security Reader** (legacy model) or a custom Defender unified RBAC role with only "Exposure Management (read)" is sufficient for view-only needs.

</details>

<details><summary>Fix 2 — User has a role assigned but the experience looks wrong/incomplete (dual RBAC-model confusion)</summary>

**Symptom:** An admin configured a Defender unified RBAC custom role for a user, but the user's access doesn't match expectations — or a user has a legacy Entra role but a *different* admin assumed Defender unified RBAC was governing access and is confused why permissions don't line up with what they configured there.

MSEM supports **two entirely independent RBAC models simultaneously** — they are alternatives, not layers, and a tenant can have some users governed by one and some by the other with no cross-validation between them. Establish which model actually granted the access in question:
1. Check Defender portal → Permissions & roles → Roles (Unified RBAC) for a custom role assigned to the **Microsoft Security Exposure Management** data source.
2. Check the user's legacy Entra ID role memberships (Triage step 1).
3. If both are present, the effective permission is the **more permissive** of the two — don't assume removing one alone will fully restrict access if the other still grants it.

</details>

<details><summary>Fix 3 — Can't set an initiative target score or edit a metric weight</summary>

**Symptom:** User can view initiatives and metrics but the "Set target score" or metric-weight-edit controls are greyed out or rejected.

This requires **Global Administrator or Security Administrator** specifically (legacy Entra model), or **Exposure Management (manage)** (Defender unified RBAC) — **Security Operator and Security Reader cannot do this**, even though Security Operator has some write capability elsewhere in MSEM (changing criticality level, toggling criticality rules on/off). Confirm the user's exact role tier, not just "do they have a security role."

</details>

<details><summary>Fix 4 — A recommendation is visible in Secure Score or Defender for Cloud but missing/stale in an MSEM initiative</summary>

**Symptom:** A remediated item still shows as an open recommendation inside an MSEM initiative, or a recommendation the client expects to see under an initiative isn't listed.

MSEM's initiative recommendation list is a **filtered view of recommendations currently active in Microsoft Secure Score or Microsoft Defender for Cloud** — it is not an independent remediation engine with its own tracking state. If a recommendation shows resolved in Secure Score/Defender for Cloud but still appears under an initiative, treat this as a sync-latency issue (see Fix 5) rather than a broken remediation. If a recommendation the client expects is entirely absent, confirm it's actually "currently applied to assets and active" in the owning workload first — MSEM won't surface a recommendation that workload itself doesn't currently consider active.

</details>

<details><summary>Fix 5 — Data doesn't reflect a fix made yesterday ("stale data")</summary>

**Symptom:** A remediation was completed but MSEM's dashboard, initiative score, or attack path still shows the pre-remediation state.

Two documented, non-bug latency characteristics:
- **Up to 72 hours** between data production at the source product and availability in the enterprise exposure graph / MSEM experiences.
- **Only the latest snapshot is retained** — MSEM does not keep historical data beyond the current state plus whatever Initiatives/Events explicitly track (14-day minimum retention window). There is no way to query "what did this look like a month ago" beyond what an initiative's own 14-day trend graph or Events history captured.

Set client expectations accordingly — a same-day "why isn't this updated yet" ticket is very often just inside the normal latency window, not a fault.

</details>

<details><summary>Fix 6 — Critical asset classification not appearing on a device</summary>

**Symptom:** A device that should qualify for a predefined critical-asset classification (domain controller, file server, etc.) isn't showing the expected criticality level.

1. Confirm the device's Defender for Endpoint sensor version is **10.3740.XXXX or later**:
   ```kusto
   DeviceInfo | project DeviceName, ClientVersion
   ```
   (run in Defender portal → Advanced Hunting)
2. If the sensor is current and the device still isn't classified, check whether it matched a predefined classification with **lower confidence** — these require manual review/approval via the device inventory's asset-review feature rather than being applied automatically.
3. If no predefined classification fits, build a **custom classification** via the query builder (devices/identities/cloud resources, any domain — Azure/AWS/GCP/on-premises) instead of expecting the predefined catalog to cover every organization-specific "crown jewel."

</details>

<details><summary>Fix 7 — Scoped user reports missing recommendations/metrics/assets that other admins can see</summary>

**Symptom:** A helpdesk-tier or delegated admin says data "disappeared" or was never visible, while a Global Admin sees the full picture.

This is very likely **by-design device-group scoping**, not a bug. Users without access to all Defender for Endpoint device groups get:
- Global exposure insights data (unrestricted)
- Metrics, recommendations, events, and initiative history **only for assets within their device-group scope**
- Attack path visibility limited to devices within their scope

Confirm the user's actual device-group RBAC assignment before escalating this as a data-loss or platform bug.

</details>

<details><summary>Fix 8 — Can't onboard or change the External Attack Surface Management (EASM) vendor connection</summary>

**Symptom:** A user with "Exposure Management (manage)" still can't connect or change the EASM initiative's vendor.

This specific action requires a **separate** permission — **Core security settings (manage)**, located under the **Authorization and settings** category in Defender unified RBAC, not the Security posture category that "Exposure Management (manage)" lives under. Grant this explicitly; it is not implied by Exposure Management (manage) alone.

</details>

<details><summary>Fix 9 — AWS/GCP or Azure cloud resources missing from the exposure graph or attack paths</summary>

**Symptom:** On-premises and Windows device data looks complete, but cloud resources are absent or thin in the attack surface map / attack path analysis.

MSEM aggregates cloud posture from **Defender for Cloud's CSPM plan** per-cloud connector — it does not independently discover Azure/AWS/GCP resources. Confirm:
1. Defender for Cloud CSPM (or a higher Defender for Cloud plan) is enabled for the subscription/connector in question.
2. For AWS/GCP, confirm the multicloud connector's "Configure access" step actually completed — a connector can exist without this step finishing, producing exactly this symptom (see `Security/Defender/CIEM-A.md` for the AWS/GCP Configure-access re-run gap, which affects this same underlying connector).

</details>

---
## Escalation Evidence

```
MICROSOFT SECURITY EXPOSURE MANAGEMENT — ESCALATION TEMPLATE
====================================================
Tenant ID:                                <tenant-id>
Tenant licensing (E5 / E3+addons / Defender suite): <confirm>
Cloud environment (Public / Gov / China / other sovereign): <confirm — MSEM is Public Cloud only>

User UPN:                                 <user@domain.com>
Legacy Entra ID role(s) held:             <from Triage step 1>
Defender unified RBAC custom role(s):     <portal-checked — role name + data source assignment>
Device group scope (if restricted):       <device group names, or "all">

Defender for Cloud CSPM plan status:      <enabled/disabled, per subscription>
Defender Vulnerability Management status: <standalone / via Defender for Endpoint P2 / not enabled>

Affected experience:                      <Initiatives / Critical Asset Management / Attack Path / Data connectors / EASM>
Expected vs. actual behavior:             <describe>
Time since the underlying fix/change was made: <hours — compare against 72h ingestion latency>

Device (if applicable):
  DeviceName:                             <name>
  ClientVersion (DFE sensor):             <version — must be >= 10.3740.XXXX for critical asset classification>

Which of the 3 "Attack Path"/"graph" products was actually meant:
  [ ] Microsoft Security Exposure Management (this topic)
  [ ] CIEM / Defender for Cloud Attack Path Analysis (Security/Defender/CIEM-A.md)
  [ ] Microsoft Sentinel graph (Security/Sentinel/SentinelGraph-A.md)
```

---
## 🎓 Learning Pointers

- **The single highest-value disambiguation on any MSEM ticket: confirm which of three similarly-named products the user actually means.** "Attack Path Analysis" exists inside MSEM itself, inside CIEM/Defender for Cloud, and — as "graph" — inside Sentinel's custom hunting graph. All three share underlying platform infrastructure per Microsoft's own documentation, which is exactly why the confusion is so common. Getting this wrong first wastes the entire troubleshooting session.
- **The dual RBAC model (Defender unified RBAC vs. legacy Entra ID roles) is not a migration-in-progress — both are permanently supported, simultaneous, alternative paths.** Don't assume a tenant has "moved to" one model; check both explicitly on every access ticket.
- **An initiative's recommendation list is a filtered view, not an independent tracking system.** This reframes a lot of "why doesn't this match what I fixed" tickets — the fix needs to register in the *owning* workload (Secure Score or Defender for Cloud) before MSEM's initiative view will reflect it.
- **72-hour ingestion latency plus 14-day-only retention means MSEM is not a historical audit trail.** For anything requiring longer-than-14-day trend data or point-in-time historical snapshots, a different tool (Secure Score history, Defender for Cloud's own recommendation history, or a client-side export/archival process) is needed — set this expectation during any onboarding conversation.
- **Critical asset classification silently depends on a specific Defender for Endpoint sensor floor (`10.3740.XXXX`).** Older fleets that haven't been pushed a recent sensor update will show gaps in critical asset coverage with no error message pointing at the sensor version as the cause.
- [MS Docs: What is Microsoft Security Exposure Management?](https://learn.microsoft.com/en-us/security-exposure-management/microsoft-security-exposure-management) · [MS Docs: Prerequisites and support](https://learn.microsoft.com/en-us/security-exposure-management/prerequisites) · [MS Docs: Critical asset management overview](https://learn.microsoft.com/en-us/security-exposure-management/critical-asset-management) · [MS Docs: Review security initiatives](https://learn.microsoft.com/en-us/security-exposure-management/initiatives)
