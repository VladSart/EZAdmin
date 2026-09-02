# Security — Agent Instructions

## What's in this folder

Microsoft security-suite runbooks spanning six sub-products: Conditional Access (the identity-and-device policy engine), Microsoft Security Copilot (the AI-assisted investigation platform), Microsoft Defender (the XDR suite — endpoint, cloud apps, identity, cloud posture, vulnerability management, and related governance/retirement topics), Microsoft Security Exposure Management (the unified posture-management/attack-path platform), Microsoft Purview (data governance, DLP, compliance, and privacy), and Microsoft Sentinel (SIEM/SOAR — data connectors, analytics, hunting, and the data lake).

Each sub-product folder is self-contained with its own `_AGENT.md`, runbooks, and `Scripts/`. This file is the domain-level index — use it to route a ticket to the right sub-product folder before diving into a specific runbook. Unlike `M365/`, this domain has no shared cross-cutting script or single "one-stop" diagnostic; each sub-product's tooling and RBAC model is distinct enough that they rarely overlap except through Entra ID identity and Intune device management underneath all of them.

---

## Sub-modules

| Folder | Covers |
|--------|--------|
| `ConditionalAccess/` | The Entra ID policy engine deciding allow/block/step-up based on user, device, location, and app signals. Policy design and break-glass management, conflict/lockout diagnosis, device filters, Authentication Strengths (phishing-resistant MFA), Authentication Context (step-up for specific sensitive actions), Named Locations, Token Protection (anti-AiTM), and the Custom Controls retirement |
| `Copilot/` | Microsoft Security Copilot — the AI-assisted investigation platform (standalone portal plus embedded experiences in Defender XDR/Purview/Intune/Entra). Three-layer RBAC (Copilot Owner/Contributor, Entra role inheritance, plugin service RBAC), Security Compute Unit (SCU) capacity/billing, plugin/promptbook publishing scope, multitenant/MSSP access (B2B, GDAP, Lighthouse). **Not** Microsoft 365 Copilot (`M365/Copilot/`) — a different product entirely |
| `Defender/` | The largest sub-product — Defender for Endpoint (MDE) onboarding/sensor health, Defender for Cloud Apps (MDA) and its File Policy retirement (Jan 6, 2027), Defender for Identity (MDI), Defender for Cloud (CSPM) and CIEM, Defender Vulnerability Management, ASR rules, Network/Cloud/Tamper Protection, WDAC, Automated Investigation & Response (AIR), App Governance, Device Control, Attack Simulation Training, Defender for Office 365 Safe Links/Safe Attachments, Defender for Business, and the tenant-wide Secure Score |
| `ExposureManagement/` | Microsoft Security Exposure Management (MSEM) — the unified exposure graph aggregating endpoint/cloud/identity/external-attack-surface/third-party data; Critical Asset Management, Security Initiatives, Attack Path analysis; dual RBAC model (unified RBAC vs. legacy Entra roles); 72-hour ingestion latency / 14-day snapshot model. Distinct from CIEM (a Defender for Cloud sub-feature feeding into MSEM's graph) and Sentinel graph (a separate, analyst-facing hunting surface) |
| `Purview/` | Data governance and compliance — DLP, Sensitivity Labels, Retention Labels/policies, Insider Risk Management, Adaptive Protection (routes IRM risk into DLP/DLM/CA), Communication Compliance, Information Barriers, Priva (privacy risk + Subject Rights Requests), the Unified Audit Log (Standard/Premium), Compliance Manager (a read-only scoring layer over the rest of this folder), DSPM for AI / Data Security Posture Management, and eDiscovery |
| `Sentinel/` | SIEM/SOAR — data connector troubleshooting (where most Sentinel tickets actually live), analytics rule/incident tuning, Logic Apps playbook/SOAR automation, UEBA, Hunting (Bookmarks/Hunts/KQL jobs), Notebooks, the data lake and Sentinel graph, the Unified Security Operations Platform onboarding layer (Sentinel workspace → Defender portal), Threat Intelligence ingestion (and the separate MDTI standalone-product retirement), and Watchlists |

---

## Before responding, also check

- `EntraID/` — every sub-product in this folder ultimately depends on Entra ID identity, roles, and device state; most "who can access this" and "why is RBAC not matching expectations" tickets trace back here
- `Intune/Troubleshooting/Policy-Conflict-A.md` — Defender, WDAC, and DLP endpoint policies are frequently delivered via Intune; conflicts surface there, not in the security product itself
- `Azure/Arc/` — Defender for Cloud (CSPM) posture and Sentinel AMA-based connectors both depend on Arc-connected on-prem/multicloud servers as a prerequisite layer
- `M365/Exchange/` — Attack Simulation Training, Safe Links/Safe Attachments, and Communication Compliance/Insider Risk all interact with mail flow, transport rules, and the Unified Audit Log, which are Exchange/compliance-side settings
- `M365/Copilot/` — do not confuse with `Security/Copilot/` (Security Copilot); different product, different license, different RBAC

---

## Key diagnostic approaches

```powershell
# Conditional Access — sign-in log analysis for a blocked/challenged user
Connect-MgGraph -Scopes "AuditLog.Read.All","Policy.Read.All"
Get-MgAuditLogSignIn -Filter "userPrincipalName eq '<UPN>'" -Top 5 |
    Select-Object CreatedDateTime, AppliedConditionalAccessPolicies

# Defender for Endpoint — device onboarding/sensor health
Connect-MgGraph -Scopes "Machine.Read.All"
Invoke-MgGraphRequest -Method GET -Uri "https://api.securitycenter.microsoft.com/api/machines?`$filter=computerDnsName eq '<deviceName>'"

# Purview — DLP policy and rule inventory
Connect-IPPSSession
Get-DlpCompliancePolicy | Select-Object Name, Mode, Enabled
Get-DlpComplianceRule -Policy "<policyName>"

# Sentinel — connector and data ingestion health
Connect-AzAccount
Get-AzSentinelDataConnector -ResourceGroupName <rg> -WorkspaceName <workspace>
```

---

## Common entry points

- "User suddenly can't access Teams/Outlook/SharePoint after a policy change" → `ConditionalAccess/CA-Troubleshooting-B.md`
- "Designing CA policy, break-glass accounts, or a phishing-resistant MFA rollout" → `ConditionalAccess/CA-Design-A.md` / `ConditionalAccess/AuthenticationStrengths-A.md`
- "Device not showing in Defender portal / sensor unhealthy" → `Defender/MDE-Onboarding-B.md`
- "Application or macro blocked by Defender / false positive" → `Defender/ASR-Rules-B.md`
- "Secure Score dropped and won't move after a fix" → `Defender/SecureScore-B.md` (24-48h refresh delay) — confirm it's the M365 tenant-wide score, not Defender for Cloud's Azure-resource CSPM score of the same name
- "Where did our Entra Permissions Management dashboard go?" → `Defender/CIEM-B.md` Fix 4 (standalone product retired Oct 1, 2025 — this is fresh onboarding into Defender for Cloud CIEM, not a migration)
- "User can't access Security Copilot / plugin shows no data" → `Copilot/SecurityCopilot-B.md` Fix 1/2
- "RBAC configured but Exposure Management access doesn't match expectations" → `ExposureManagement/ExposureManagement-B.md` Fix 2 (dual RBAC-model confusion — the #1 real-world ticket)
- "DLP policy blocking emails/shares incorrectly, or alert storm" → `Purview/DLP-Policy-B.md`
- "Retention label not showing up / item retained or deleted incorrectly" → `Purview/RetentionLabels-B.md`
- "Sentinel connector says Connected but no logs" → `Sentinel/DataConnectors-B.md` Triage + Fix 1
- "All Sentinel data stopped at once" → `Sentinel/DataConnectors-B.md` Fix 2 (workspace quota) before touching individual connectors
- "Analytics rule shows AUTO DISABLED or won't fire" → `Sentinel/AnalyticsRules-B.md`
- "MDTI / Defender Threat Intelligence portal is gone" → `Sentinel/MDTIRetirement-B.md` (standalone product retired Aug 1, 2026 — disambiguate from Sentinel's own TI ingestion, unaffected)

---

## Response format reminder

Always respond with all three layers:
1. **Hotfix** — sign-in log / policy / sensor check → fix → validate
2. **Deep Dive** — the sub-product's architecture, RBAC model, and data flow
3. **Learning Pointers** — what to study to get sharper at that specific Microsoft security product
