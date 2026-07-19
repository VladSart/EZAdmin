# Security — Purview — Agent Instructions

## What's in this folder

Microsoft Purview runbooks covering **Data Loss Prevention (DLP)**, Information Protection, Compliance, Insider Risk Management, **Adaptive Protection** (the ML-driven bridge routing IRM risk signal into DLP/Data Lifecycle Management/Conditional Access enforcement), Communication Compliance, Information Barriers, Microsoft Priva (Privacy Risk Management + Subject Rights Requests), and the **Unified Audit Log (Audit Standard/Premium)** that underpins several of the above in M365 environments. Targeted at L2/L3 MSP engineers supporting enterprise clients where data governance and regulatory compliance are requirements.

---

## Before responding, also check

| Resource | Why |
|----------|-----|
| `Security/ConditionalAccess/` | CA policies interact with Purview sensitivity labels (label-based CA conditions) |
| `Intune/Troubleshooting/` | Endpoint DLP requires Intune-managed devices; policy application issues often surface here |
| `EntraID/Troubleshooting/` | Purview uses Entra identity for scoping policies to users/groups |
| `M365/Exchange/` | Exchange transport rules can conflict with or complement DLP rules |
| `Security/Defender/` | MDE (Defender for Endpoint) is required for endpoint DLP enforcement |

---

## Folder contents

| File | What it covers |
|------|---------------|
| `_AGENT.md` | This file — routing and orientation |
| `DLP-Policy-A.md` | Deep dive — DLP policy evaluation engine, SITs, EDM, endpoint DLP architecture |
| `DLP-Policy-B.md` | Hotfix runbook for DLP policy misconfiguration, false positives, over-blocking, and alert storms |
| `Sensitivity-Labels-A.md` | Deep dive — sensitivity label architecture, encryption, label inheritance |
| `Sensitivity-Labels-B.md` | Hotfix runbook for label publishing, encryption, and co-authoring issues |
| `Insider-Risk-A.md` | Deep dive — Insider Risk Management policy engine, indicators, Adaptive Protection |
| `Insider-Risk-B.md` | Hotfix runbook for IRM alert noise, missing signals, licensing gaps |
| `AdaptiveProtection-A.md` | Deep dive — insider risk LEVEL vs. alert SEVERITY distinction, Quick vs. Custom Setup, the three enforcement arms (DLP/CA/DLM) and their independent safe-by-default states, disable lifecycle and orphaned-policy risk |
| `AdaptiveProtection-B.md` | Hotfix runbook for CA policies stuck in Report-only, DLP policies stuck in simulation mode, level-assignment mismatches, and the `Get-MgRiskyUser`/Entra ID Protection wrong-system gotcha |
| `eDiscovery-A.md` | Deep dive — eDiscovery case/hold/search/export architecture |
| `eDiscovery-B.md` | Hotfix runbook for case holds, failed searches, and failed exports |
| `RetentionLabels-A.md` | Deep dive — retention label vs. retention policy architecture, conflict resolution, disposition review |
| `RetentionLabels-B.md` | Hotfix runbook for unpublished labels, distribution errors, and retention/policy conflicts |
| `CommunicationCompliance-A.md` | Deep dive — policy templates, scoping/reviewer rules, role groups, channel prerequisites (no PowerShell for policy CRUD) |
| `CommunicationCompliance-B.md` | Hotfix runbook for zero-admin lockout, reviewer eligibility, under-reviewing templates, licensing gaps |
| `InformationBarriers-A.md` | Deep dive — segment/policy evaluation pipeline, FwdSync propagation delay, Allow vs. Block policy design |
| `InformationBarriers-B.md` | Hotfix runbook for segment overlap, Address Book Policy conflicts, and stuck/failed policy application |
| `Priva-A.md` | Deep dive — Privacy Risk Management policy pipeline (Test mode default, Alert→Issue→Remediation), Subject Rights Requests workflow (Access/Export/Tagged list/Delete), RBAC model, data-residency exclusions |
| `Priva-B.md` | Hotfix runbook for Priva access/licensing/RBAC gates, policies stuck in Test mode, alert-storm tuning, stuck/incomplete Subject Rights Requests, and pre-execution review for irreversible Delete requests |
| `Audit-A.md` | Deep dive — Unified Audit Log ingestion pipeline, Standard vs. Premium retention/licensing model, the four retrieval methods (portal/Graph/cmdlet/Management Activity API) and their limits, custom retention policies |
| `Audit-B.md` | Hotfix runbook for the silent 100/5,000/50,000 `Search-UnifiedAuditLog` result-count tiers, ingestion delay, mailbox audit bypass, missing Premium-only properties, and non-retroactive retention gaps |
| `Scripts/Get-PurviewDLPReport.ps1` | Tenant-wide DLP policy + incident report |
| `Scripts/Get-SensitivityLabelCoverage.ps1` | Sensitivity label publishing/coverage audit |
| `Scripts/Get-InsiderRiskPolicyStatus.ps1` | IRM policy health, alert volume, and signal plumbing audit |
| `Scripts/Get-eDiscoveryHoldAudit.ps1` | Tenant-wide case hold + export expiry audit |
| `Scripts/Get-RetentionPolicyAudit.ps1` | Tenant-wide retention label + policy distribution audit |
| `Scripts/Get-CommunicationComplianceReadinessAudit.ps1` | Audit log, role group (zero-admin risk), reviewer eligibility, licence, and Teams reporting-policy readiness check (adjacent-signal audit only — no policy CRUD API exists) |
| `Scripts/Get-InformationBarriersAudit.ps1` | Address Book Policy blocker check, segment/policy inventory with orphan and missing-reverse-pair flags, last application health, and audit-log segment-conflict scan |
| `Scripts/Get-PrivaReadinessAudit.ps1` | Priva RBAC (all 5 role groups) + Unified Audit Log prerequisite + Privacy Risk Management policy inventory audit — flags EMPTY_RBAC, NO_AUDIT_LOG, POLICY_IN_TEST_MODE, CMDLET_UNAVAILABLE; Subject Rights Requests are portal-only and out of scope for this script |
| `Scripts/Get-AuditLogHealthCheck.ps1` | Tenant-wide Unified Audit Log health check — ingestion status, mailbox audit bypass sweep (flags real UserMailboxes separately from resource/service accounts), retention policy inventory, and a live control search that flags the silent 100-record cap; best-effort tenant Premium SKU signal |
| `Scripts/Get-AdaptiveProtectionAudit.ps1` | Cross-arm Adaptive Protection audit — licensing (P2/E5), CA policies referencing insider risk (flags Report-only + wrong-risk-signal naming mismatches), best-effort DLP rule text-search for the Adaptive Protection condition (flags simulation mode), upstream IRM enabled-policy check, and orphaned-CA-policy detection when no IRM signal is live |

---

## Common entry points

| User question | Which file |
|---------------|-----------|
| "DLP policy is blocking emails / blocking SharePoint shares incorrectly" | `DLP-Policy-B.md` → Fix 1 (false positive) |
| "Users getting DLP alerts for things that should be allowed" | `DLP-Policy-B.md` → Fix 2 (scope/exception) |
| "DLP alert storm — hundreds of alerts in the compliance portal" | `DLP-Policy-B.md` → Triage + Fix 3 |
| "Endpoint DLP not enforcing on devices" | `DLP-Policy-B.md` → Fix 4 (endpoint prerequisites) |
| "How do I put a DLP policy in test mode before going live?" | `DLP-Policy-B.md` → Common Fix Paths → Test Mode |
| "DLP policy order — which policy applies when there are multiple?" | `DLP-Policy-A.md` → Policy Priority and Rule Order |
| "Sensitivity label not triggering DLP rule" | `DLP-Policy-B.md` → Diagnosis step 4 (label sync) |
| "Retention label doesn't show up for users" | `RetentionLabels-B.md` → Fix 2 (publishing scope) |
| "Item was retained when it should have deleted (or vice versa)" | `RetentionLabels-B.md` → Fix 3 (conflict resolution) |
| "Retention policy distribution stuck in Error/Pending" | `RetentionLabels-B.md` → Fix 1 (retry distribution) |
| "Disposition review never triggers" | `RetentionLabels-B.md` → Fix 6 |
| "Difference between retention labels and retention policies" | `RetentionLabels-A.md` → How It Works |
| "eDiscovery case hold stuck in Error/Pending" | `eDiscovery-B.md` → Fix 2 |
| "Global Admin can't see Communication Compliance in the portal" | `CommunicationCompliance-A.md` → Reviewer role groups section; `CommunicationCompliance-B.md` → Fix 2 |
| "Communication Compliance policy isn't catching everything" | `CommunicationCompliance-B.md` → Fix 5 (check review percentage — two templates default to 10%) |
| "Reviewer added to a Communication Compliance policy but sees nothing" | `CommunicationCompliance-B.md` → Fix 3 |
| "Can I manage Communication Compliance policies with PowerShell/Graph?" | `CommunicationCompliance-A.md` → How It Works (no — portal only) |
| "User can't find/message someone in Teams" | `InformationBarriers-B.md` → Diagnosis Step 1-2 (may be working as designed) |
| "IB policy application failed / stuck" | `InformationBarriers-B.md` → Triage + Fix 3/4 |
| "Two users who should be blocked can still chat" | `InformationBarriers-B.md` → Fix 2 |
| "Client wants to block email between two departments" | `InformationBarriers-A.md` → Scope & Assumptions (IB doesn't cover Exchange mail flow) |
| "Priva portal shows nothing / cmdlets fail" | `Priva-B.md` → Triage + Fix 1 (data residency, licensing, RBAC gates) |
| "Priva policy isn't generating any alerts" | `Priva-B.md` → Fix 4 (Test mode is the default — this is by design, not a bug) |
| "Priva alert storm / too many matches" | `Priva-A.md` → Remediation Playbook 2 (narrow classification group, adjust alert frequency) |
| "Subject Rights Request found zero/partial results" | `Priva-B.md` → Fix 5 (identity resolution + data-source scope) |
| "Need to run a Delete-type Subject Rights Request" | `Priva-B.md` → Fix 6 (irreversible — confirm holds and get sign-off first) |
| "Difference between Priva and DLP / Insider Risk" | `Priva-A.md` → Scope & Assumptions (Priva = proactive personal-data risk visibility, not loss-prevention blocking or behavioral insider-threat indicators) |
| "Search-UnifiedAuditLog only returns 100 results" | `Audit-B.md` → Fix 3 (silent default cap — use `ReturnLargeSet` or `HighCompleteness`) |
| "Audit log search returns nothing for recent activity" | `Audit-B.md` → Fix 2 (ingestion delay, 30 min–24 hrs is normal) |
| "Why can't I see this specific mailbox's activity at all" | `Audit-B.md` → Fix 4 (check `Get-MailboxAuditBypassAssociation`) |
| "MailItemsAccessed / Teams event is missing a property" | `Audit-B.md` → Fix 5 (Audit Premium license gates per actor, not per tenant) |
| "Need audit records older than 180 days / 1 year" | `Audit-B.md` → Fix 6 (retention policies are not retroactive — must be created proactively) |
| "Difference between Audit Standard and Audit Premium" | `Audit-A.md` → How It Works |
| "Client wants a SIEM feed of audit data, not ad-hoc searches" | `Audit-A.md` → Phase 2 (use the Office 365 Management Activity API, not `Search-UnifiedAuditLog`) |
| "Elevated-risk user still has full app access" | `AdaptiveProtection-B.md` → Triage #3 (CA policy likely stuck in Report-only — the Quick Setup default) |
| "Adaptive Protection DLP rule isn't blocking anything" | `AdaptiveProtection-B.md` → Triage #4 / Fix 2 (policy likely still in simulation mode) |
| "User has a High-severity IRM alert but no Elevated risk level" | `AdaptiveProtection-B.md` → Fix 3 (insider risk LEVEL ≠ alert SEVERITY — different scales) |
| "Deleted files not being preserved for a risky user" | `AdaptiveProtection-B.md` → Triage #5 / Fix 5 (DLM opt-in sub-toggle, not retroactive) |
| "Troubleshooting Adaptive Protection with `Get-MgRiskyUser` / sign-in risk finds nothing" | `AdaptiveProtection-B.md` → Fix 7 (wrong system — that's Entra ID Protection, not Adaptive Protection) |
| "What exactly does Adaptive Protection do / how is it different from plain Insider Risk Management?" | `AdaptiveProtection-A.md` → How It Works |

---

## Key diagnostic commands

```powershell
# Connect to Security & Compliance Center
Connect-IPPSSession -UserPrincipalName <adminUPN>

# List all DLP policies and their current mode
Get-DlpCompliancePolicy | Select-Object Name, Mode, Enabled, Workload | Format-Table -AutoSize

# List rules within a specific policy
Get-DlpComplianceRule -Policy "<PolicyName>" | Select-Object Name, Disabled, BlockAccess, NotifyUser | Format-Table -AutoSize

# Check DLP alerts in the last 24 hours
Get-ProtectionAlert | Where-Object { $_.AlertType -eq "DLP" -and $_.LastUpdatedTime -gt (Get-Date).AddHours(-24) }

# Check sensitive information type match details
Get-DlpDetailReport -StartDate (Get-Date).AddDays(-7) -EndDate (Get-Date) -PageSize 50 | 
    Select-Object Date, Policy, Rule, SensitiveType, Action, UserName, ObjectId | 
    Format-Table -AutoSize

# List sensitivity labels (requires AIPService or MIPLabels scope)
Get-Label | Select-Object DisplayName, Priority, IsActive | Format-Table -AutoSize

# Check endpoint DLP onboarding status (via Defender for Endpoint)
# Run in MDE portal / Advanced Hunting — or via Graph:
# GET https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$filter=operatingSystem eq 'Windows'

# Communication Compliance has NO cmdlets for policy CRUD — only these adjacent checks:
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled
Get-RoleGroupMember -Identity "Communication Compliance Admins"
Get-EXOMailbox -Identity <reviewer@tenant.com> | Select-Object RecipientTypeDetails

# Priva — read/RBAC/prerequisite cmdlets only (legacy naming, pre-dates the Priva rebrand);
# policy conditions, Test→On toggling, and ALL Subject Rights Requests actions are portal-only
Get-PrivacyManagementPolicy | Select-Object Name, Type, Mode, Enabled
Get-RoleGroupMember -Identity "Privacy Management"
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled

# Unified Audit Log — ingestion status, mailbox bypass check, retention policies
Get-AdminAuditLogConfig | Select-Object UnifiedAuditLogIngestionEnabled
Get-MailboxAuditBypassAssociation -Identity <UPN> | Select-Object AuditBypassEnabled
Get-UnifiedAuditLogRetentionPolicy | Select-Object Name, Priority, Workload, RetentionDuration
# Search with paging — never trust a bare call past 100 results:
Search-UnifiedAuditLog -StartDate <date> -EndDate <date> -ResultSize 5000 -HighCompleteness

# Adaptive Protection — only the CA arm and upstream IRM signal have clean read cmdlets;
# the master toggle, level definitions, DLP simulation-mode state, and DLM opt-in are portal-only
Get-MgIdentityConditionalAccessPolicy | Where-Object { $_.Conditions.InsiderRiskLevels } | Select-Object DisplayName, State
Get-InsiderRiskPolicy | Select-Object Name, IsEnabled
# WRONG SYSTEM for Adaptive Protection troubleshooting — this is Entra ID Protection:
# Get-MgRiskyUser
```

---

## Key dependency chain

```
[Purview DLP Policy]
        │
        ├── [Workloads scoped]
        │     ├── Exchange Online (mail flow)
        │     ├── SharePoint Online (document sharing)
        │     ├── OneDrive (sync and share)
        │     ├── Teams (chat and channel messages)
        │     └── Endpoint (Windows 10/11 via MDE onboarding)
        │
        ├── [Sensitive Information Types]
        │     ├── Built-in SITs (Credit card, SSN, NHS, etc.)
        │     └── Custom SITs (regex, keyword, document fingerprint)
        │
        ├── [Sensitivity Labels] (optional — label-based conditions)
        │     └── Synced via AIPService / MIP labels
        │
        ├── [Entra ID Groups] — Policy scope (include/exclude)
        │
        └── [Microsoft Defender for Endpoint]
              └── Required for Endpoint DLP enforcement
                    └── Devices must be onboarded to MDE
                          └── Windows 10 21H2+ or Windows 11
```

Priva has its own, separate chain — it reuses DLP's foundational SIT/classification-group engine but is not gated by DLP policy state:

```
[Tenant NOT in a Priva-excluded data-residency region] (hard, unfixable gate)
        └── [Priva licence] (E5/E5 Compliance bundle OR standalone Priva add-on)
              └── [Purview portal RBAC role] (Privacy Management role groups — NOT Entra ID roles)
                    ├── [Privacy Risk Management]
                    │     └── [Unified Audit Log enabled] → [Policy, default Test mode] →
                    │           [Alert] → [manually-created Issue] → [Remediation]
                    └── [Subject Rights Requests] (portal-only, no PowerShell equivalent)
                          └── [Data subject identity resolved] → [Search: Exchange/SharePoint/
                                OneDrive/Teams] → [auto Teams channel] → [Review] →
                                [Report/Export or irreversible Delete]
```

Adaptive Protection sits between Insider Risk Management and three independent enforcement arms, each with its own safe-by-default state that must be separately promoted — see `AdaptiveProtection-A.md` for the full chain:

```
[Insider Risk Management policy — enabled, generating alerts/insights]
        └── [Adaptive Protection master toggle: On] (portal-only, up to 36h propagation)
              └── [Insider risk LEVEL assigned: Elevated/Moderate/Minor]
                    │       (NOT the same scale as alert severity High/Medium/Low)
                    │
                    ├── [DLP arm] — Exchange/Teams/Devices only, ships in simulation mode
                    ├── [Conditional Access arm] — Entra ID P2, ships Report-only
                    │       (Graph: conditions.insiderRiskLevels — distinct from
                    │        conditions.userRiskLevels/signInRiskLevels, Entra ID
                    │        Protection's unrelated risk engine)
                    └── [Data Lifecycle Management arm] — separate opt-in sub-toggle,
                            120-day preserve, Elevated users only, not retroactive
```

The Unified Audit Log is a foundational dependency underneath Priva, Insider Risk Management, and Communication Compliance (all three check `UnifiedAuditLogIngestionEnabled` before anything else works) — troubleshoot this layer first if any of those three show no signal:

```
[UnifiedAuditLogIngestionEnabled] (tenant-wide, on by default)
        └── [Per-mailbox: NOT bypassed via Set-MailboxAuditBypassAssociation]
              └── [Ingestion pipeline] (30 min–24 hr typical latency)
                    └── [Retention] — 180 days (Standard) default, or
                    │     1 yr AAD/Exchange/OneDrive/SharePoint (Premium default),
                    │     up to 10 yrs (Premium custom policy + per-user add-on)
                    └── [Retrieval] — Portal / Graph API / Search-UnifiedAuditLog
                          (100 default → 5,000/page → 50,000/session ceiling) /
                          Management Activity API (SIEM-scale, throttled by rate not count)
```

---

## Response format reminder

Always respond in 3 layers:

1. **What to do right now** — the immediate fix with copy-paste commands
2. **Why it happened** — root cause explanation so the engineer understands
3. **How to prevent recurrence** — policy scope review, test mode strategy, or monitoring recommendation
