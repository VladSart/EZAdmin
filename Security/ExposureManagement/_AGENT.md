# Security — Exposure Management (Microsoft Security Exposure Management) — Agent Instructions

## What's in this folder

Runbooks for **Microsoft Security Exposure Management (MSEM)** — the unified posture-management platform inside the Microsoft Defender portal that aggregates endpoint, cloud (Azure/AWS/GCP via Defender for Cloud), identity, external attack surface, and third-party security data into a single enterprise exposure graph, and builds Critical Asset Management, Security Initiatives, and Attack Path analysis on top of it. Covers the dual RBAC model (Defender unified RBAC vs. legacy Entra ID roles), licensing/Public-Cloud-only availability, the 72-hour ingestion latency / 14-day-snapshot-only data model, critical asset classification (including the DFE sensor version floor), and initiative/recommendation architecture. Targeted at L2/L3 MSP engineers handling "can't access Exposure Management," "data looks stale," and "attack path doesn't match what I expected" tickets.

**Not to be confused with two other products that share overlapping "Attack Path"/"graph" terminology and underlying platform infrastructure:**
- **CIEM (Cloud Infrastructure Entitlement Management)** — a Defender for Cloud CSPM sub-feature whose own Attack Path Analysis output feeds into MSEM's broader graph but is configured/licensed/consumed separately. See `Security/Defender/CIEM-A.md`/`-B.md`.
- **Microsoft Sentinel graph** — a code-first, custom-GQL-query hunting surface for analysts, sharing platform infrastructure with MSEM but a different consumption model and audience. See `Security/Sentinel/SentinelGraph-A.md`.

---

## Before responding, also check

| Resource | Why |
|----------|-----|
| `Security/Defender/CIEM-A.md`/`-B.md` | Shares "Attack Path Analysis" terminology and some underlying graph data — confirm which product a ticket actually means before troubleshooting either |
| `Security/Sentinel/SentinelGraph-A.md` | Shares underlying graph-platform infrastructure with MSEM but is a distinct code-first hunting surface |
| `Security/Defender/SecureScore-A.md` | MSEM initiative recommendations are a filtered view over Secure Score/Defender for Cloud recommendations — the owning workload, not MSEM, is where remediation actually registers |
| `Security/Defender/_AGENT.md` | Defender for Endpoint device groups gate MSEM's device-group RBAC scoping; Defender Vulnerability Management is a prerequisite data source |
| `EntraID/Troubleshooting/` | The 10 legacy Entra ID roles that grant MSEM access are ordinary directory roles — general role-assignment troubleshooting lives there |

---

## Folder contents

| File | What it covers |
|------|---------------|
| `_AGENT.md` | This file — routing and orientation |
| `ExposureManagement-A.md` | Deep dive — enterprise exposure graph architecture, dual RBAC model, data freshness/retention model, Critical Asset Management, Security Initiatives, Attack Path analysis, and explicit disambiguation from CIEM/Sentinel graph/Secure Score |
| `ExposureManagement-B.md` | Hotfix runbook for access issues, dual-RBAC-model confusion, stale-data complaints, critical asset classification gaps, device-group scoping, and cloud resource coverage gaps |
| `Scripts/Get-ExposureManagementRBACAudit.ps1` | Read-only audit of legacy Entra ID role membership, tenant licensing (best-effort), Defender for Cloud CSPM plan status, and optional DFE sensor-version eligibility check for critical asset classification |

---

## Common entry points

- "User can't see Exposure Management at all" → `ExposureManagement-B.md` Fix 1
- "User has a role assigned but access doesn't match expectations" / "RBAC configured but doesn't work as expected" → `ExposureManagement-B.md` Fix 2 (dual RBAC-model confusion — the #1 real-world ticket)
- "Can't set initiative target score or edit metric weight" → `ExposureManagement-B.md` Fix 3
- "Fixed a recommendation but it still shows open in an initiative" → `ExposureManagement-B.md` Fix 4
- "Data doesn't reflect a change we made yesterday" → `ExposureManagement-B.md` Fix 5 (72h latency, 14-day-only retention)
- "Device should be a critical asset but isn't classified" → `ExposureManagement-B.md` Fix 6 (check DFE sensor version)
- "Scoped/delegated admin is missing recommendations or assets other admins can see" → `ExposureManagement-B.md` Fix 7 (device-group RBAC scoping — by design)
- "Can't connect or change the EASM vendor" → `ExposureManagement-B.md` Fix 8
- "AWS/GCP/Azure resources missing from the attack surface map or attack paths" → `ExposureManagement-B.md` Fix 9
- Architecture/design questions ("how does the exposure graph work," "how is MSEM different from CIEM or Sentinel graph") → `ExposureManagement-A.md`

---

## Key diagnostic commands

```powershell
# Legacy Entra ID role membership (one of 10 qualifying roles)
Get-MgUserMemberOf -UserId "<user@domain.com>" | Select-Object -ExpandProperty AdditionalProperties

# Tenant licensing (best-effort E5/Defender-suite SKU match)
Get-MgSubscribedSku | Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits

# Defender for Cloud CSPM plan status
Get-AzSecurityPricing | Select-Object Name, PricingTier
```

```kusto
// Device sensor version (Advanced Hunting) — critical asset classification requires 10.3740.XXXX+
DeviceInfo | project DeviceName, ClientVersion
```

**Note:** Defender unified RBAC custom role definitions and their "Microsoft Security Exposure Management" data-source assignment have no Graph/PowerShell read surface — always confirm via Defender portal → Permissions & roles → Roles (Unified RBAC).

---

## Key dependency chain

```
Tenant licensing (E5/Defender suite) + Public Cloud environment
        │
RBAC — EITHER Defender unified RBAC custom role (assigned to the MSEM data
source) OR one of 10 legacy Entra ID roles (not stacked — whichever is more
permissive governs)
        │
Device-group RBAC scope — gates full vs. restricted visibility/manage actions
        │
Environmental data sources (Defender for Endpoint/MDVM, Defender for Cloud
CSPM, EASM discovery, third-party connectors) feeding the enterprise
exposure graph
        │
72-hour ingestion latency / 14-day-snapshot-only retention
        │
Critical Asset Management · Security Initiatives (recommendations = filtered
view over Secure Score/Defender for Cloud) · Attack Path analysis
```

---

## Response format reminder

Always respond in three layers: (1) a fast Mode B fix path for an active ticket — starting with product disambiguation if "attack path" or "graph" terminology is involved, (2) the Mode A architectural "why" if the user wants to understand root cause, (3) a Learning Pointer connecting the finding to the broader dual-RBAC-model and aggregation-not-remediation pattern documented here.
