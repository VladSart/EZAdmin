# Security — Purview — Agent Instructions

## What's in this folder

Microsoft Purview runbooks covering **Data Loss Prevention (DLP)**, Information Protection, Compliance, Insider Risk Management, and Communication Compliance in M365 environments. Targeted at L2/L3 MSP engineers supporting enterprise clients where data governance and regulatory compliance are requirements.

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
| `eDiscovery-A.md` | Deep dive — eDiscovery case/hold/search/export architecture |
| `eDiscovery-B.md` | Hotfix runbook for case holds, failed searches, and failed exports |
| `RetentionLabels-A.md` | Deep dive — retention label vs. retention policy architecture, conflict resolution, disposition review |
| `RetentionLabels-B.md` | Hotfix runbook for unpublished labels, distribution errors, and retention/policy conflicts |
| `CommunicationCompliance-A.md` | Deep dive — policy templates, scoping/reviewer rules, role groups, channel prerequisites (no PowerShell for policy CRUD) |
| `CommunicationCompliance-B.md` | Hotfix runbook for zero-admin lockout, reviewer eligibility, under-reviewing templates, licensing gaps |
| `Scripts/Get-PurviewDLPReport.ps1` | Tenant-wide DLP policy + incident report |
| `Scripts/Get-SensitivityLabelCoverage.ps1` | Sensitivity label publishing/coverage audit |
| `Scripts/Get-InsiderRiskPolicyStatus.ps1` | IRM policy health, alert volume, and signal plumbing audit |
| `Scripts/Get-eDiscoveryHoldAudit.ps1` | Tenant-wide case hold + export expiry audit |
| `Scripts/Get-RetentionPolicyAudit.ps1` | Tenant-wide retention label + policy distribution audit |
| `Scripts/Get-CommunicationComplianceReadinessAudit.ps1` | Audit log, role group (zero-admin risk), reviewer eligibility, licence, and Teams reporting-policy readiness check (adjacent-signal audit only — no policy CRUD API exists) |

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

---

## Response format reminder

Always respond in 3 layers:

1. **What to do right now** — the immediate fix with copy-paste commands
2. **Why it happened** — root cause explanation so the engineer understands
3. **How to prevent recurrence** — policy scope review, test mode strategy, or monitoring recommendation
