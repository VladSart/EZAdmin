# Cloud Infrastructure Entitlement Management (CIEM) — Hotfix Runbook (Mode B: Ops)
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

**First, confirm you're troubleshooting the right thing.** Standalone **Microsoft Entra Permissions Management** (the product formerly known as CloudKnox) was **retired after October 1, 2025** and is no longer available or supported. CIEM capability now lives natively **inside Microsoft Defender for Cloud**, gated behind the paid **Defender CSPM** plan. If a client references "Entra Permissions Management" by name, they mean this feature — there is nothing left to troubleshoot in the old standalone product.

```powershell
# 1. Confirm Defender CSPM plan is enabled (CIEM requires this specific paid plan — Foundational CSPM does not include it)
Get-AzSecurityPricing | Where-Object { $_.Name -eq "CloudPosture" } | Select-Object Name, PricingTier

# 2. Check for the two CIEM-specific recommendation types (Azure) — presence confirms CIEM is enabled and has returned results
Get-AzSecurityAssessment | Where-Object { $_.DisplayName -match "overprovisioned identities|inactive identities" } |
    Select-Object DisplayName, @{N="Status";E={$_.Status.Code}}

# 3. Confirm a multicloud connector exists if the question is about AWS/GCP
Search-AzGraph -Query "resources | where type =~ 'microsoft.security/securityconnectors' | project name, environmentName = tostring(properties.environmentName)"

# 4. Confirm the account has Security Admin role — CIEM enablement requires it, Owner/Contributor alone is not sufficient
Get-AzRoleAssignment -SignInName <user-upn> | Where-Object { $_.RoleDefinitionName -match "Security Admin" }

# 5. There is no PowerShell cmdlet that reads the CIEM on/off toggle itself — confirm via portal:
#    Defender for Cloud > Environment settings > <subscription/account/project> > Defender CSPM plan > Settings > "Permissions Management (CIEM)"
```

| If... | Then... |
|---|---|
| `CloudPosture` tier is `Free`/`Standard` shows disabled | CIEM is unavailable — Defender CSPM plan must be enabled first (a licensing/plan gap, not a bug) |
| Plan enabled, but no CIEM recommendations in step 2 | CIEM sub-toggle is likely OFF within the plan, or it was enabled less than a few hours ago | 
| Recommendations present for Azure but AWS/GCP show nothing | Multicloud connector's CIEM-specific onboarding step (CloudFormation/Terraform update) was never run | 
| Client asks "where did our old Entra Permissions Management dashboard go?" | Product retirement — this is an expectations conversation, not a technical fault (see Fix 4) |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Azure Subscription / AWS Account / GCP Project
    └── Onboarded to Defender for Cloud (multicloud connector required for AWS/GCP; native for Azure)
            └── Defender CSPM plan ENABLED (paid — Foundational CSPM does NOT include CIEM)
                    └── "Permissions Management (CIEM)" toggle ENABLED inside the Defender CSPM plan's own Settings
                            ├── Azure — enabled directly; requires Security Admin role at subscription scope
                            ├── AWS  — requires re-running "Configure access" (updated CloudFormation stack/StackSet);
                            │          CloudTrail log ingestion recommended for accurate inactivity signals
                            └── GCP  — requires re-running Cloud Shell/Terraform deployment script;
                                       Cloud Logging ingestion recommended for accurate inactivity signals
                                            └── Identity/permission telemetry ingested (first results within a few hours)
                                                    ├── CIEM Recommendations (2 per cloud: overprovisioned / inactive identities)
                                                    ├── Cloud Security Explorer (queryable identity-to-resource graph)
                                                    └── Attack Path Analysis (correlates over-privilege with lateral-movement paths)
```

**The critical gotcha:** enabling the Defender CSPM *plan* and enabling the *CIEM sub-feature within that plan* are two separate steps. A subscription can have Defender CSPM fully enabled with CIEM still off, and this is the single most common "why is this data missing" ticket.

</details>

---
## Diagnosis & Validation Flow

1. **Confirm plan tier.**
   ```powershell
   Get-AzSecurityPricing | Where-Object { $_.Name -eq "CloudPosture" } | Select-Object Name, PricingTier
   ```
   Expect `PricingTier = Standard` (this is the Defender CSPM plan's internal API name). `Free` means only Foundational CSPM — CIEM is not available at all until upgraded.

2. **Confirm the CIEM toggle itself (portal-only — no cmdlet exists for this specific setting).**
   Defender for Cloud → Environment settings → select subscription/AWS account/GCP project → Defender CSPM plan → **Settings** → confirm **Permissions Management (CIEM)** shows **On**.
   If it was just turned on, allow "a few hours" (Microsoft's own stated SLA, not a fixed number) before expecting recommendations.

3. **For Azure, confirm recommendations are populating.**
   ```powershell
   Get-AzSecurityAssessment | Where-Object { $_.DisplayName -match "overprovisioned identities|inactive identities" } |
       Select-Object DisplayName, @{N="Status";E={$_.Status.Code}}, @{N="Severity";E={$_.Metadata.Severity}}
   ```

4. **For AWS/GCP, confirm the multicloud connector's CIEM-specific onboarding step actually completed** — this is separate from the base connector that feeds general CSPM recommendations.
   Portal: Environment settings → the AWS account/GCP project → Defender CSPM plan → Settings → re-check whether "Configure access" was completed *after* CIEM was toggled on (an older connector created before CIEM existed on that account will not automatically have the additional IAM/service-account permissions CIEM needs).

---
## Common Fix Paths

<details><summary>Fix 1 — Defender CSPM enabled, but zero CIEM recommendations anywhere</summary>

**Cause:** the CIEM sub-toggle inside the Defender CSPM plan is off — a separate step from enabling the plan itself.

```
Defender for Cloud > Environment settings > <subscription> > Defender CSPM > Settings
  → Enable "Permissions Management (CIEM)" → Continue → Save
```

Wait a few hours, then re-run the Triage step 2 query. If still empty after 24h, escalate — this exceeds the documented refresh window.

**Rollback:** Toggling CIEM off stops new recommendation generation; existing assessment history is retained per standard Defender for Cloud data retention, not deleted immediately.

</details>

<details><summary>Fix 2 — AWS account shows no CIEM data despite the toggle being on</summary>

**Cause:** the CloudFormation stack/StackSet backing the AWS connector was never updated with the additional IAM read permissions CIEM requires. This is a distinct action from the original connector onboarding.

```
Defender for Cloud > Environment settings > <AWS account> > Defender CSPM > Settings
  → Configure access → select deployment method → run the UPDATED CloudFormation template
  → check "CloudFormation template has been updated on AWS environment (Stack)" → Review and generate → Update
```

Also confirm CloudTrail log ingestion is enabled for that account — without it, inactivity-based recommendations will be less accurate or absent.

**Rollback:** N/A — this only grants additional read-only IAM permissions; it does not modify AWS resources.

</details>

<details><summary>Fix 3 — GCP project shows no CIEM data despite the toggle being on</summary>

**Cause:** same class of issue as Fix 2 — the Cloud Shell/Terraform deployment script granting CIEM the necessary IAM read scope was never re-run after enabling the toggle.

```
Defender for Cloud > Environment settings > <GCP project> > Defender CSPM > Settings
  → Configure access → select permissions type and deployment method
  → run the updated Cloud Shell or Terraform script → confirm the checkbox → Review and generate → Update
```

Also confirm GCP Cloud Logging ingestion is enabled for full inactivity-signal accuracy.

**Rollback:** N/A — read-only IAM scope grant only.

</details>

<details><summary>Fix 4 — Client asks "where did our old Entra Permissions Management dashboard go?"</summary>

**Cause:** not a fault. The standalone Microsoft Entra Permissions Management product was retired after October 1, 2025. Its functionality did not migrate automatically — CIEM inside Defender for Cloud's Defender CSPM plan is a **separate onboarding**, not a continuation of the old tool's configuration or historical data.

**What to tell the client:**
1. The standalone product is gone; nothing to restore.
2. Equivalent (not identical) capability is available today inside Defender for Cloud, gated behind the Defender CSPM plan.
3. It must be enabled fresh per cloud (Azure/AWS/GCP) — see the Dependency Cascade above. There is no data carryover from the old tool.
4. If the client specifically needs a dedicated, vendor-neutral CIEM product instead, Microsoft's own retirement guidance points to third-party options (e.g. Delinea Privilege Control for Cloud Entitlements) — that evaluation is outside this repo's Microsoft-native scope, but worth surfacing as a client-facing option.

**Rollback:** N/A — informational.

</details>

<details><summary>Fix 5 — Old documentation/dashboard references a "Permissions Creep Index (PCI)" that's no longer visible</summary>

**Cause:** the PCI metric is being deprecated from Defender for Cloud's CIEM recommendations. This is expected, current-state behavior, not a missing-data bug.

Point the client to the two current recommendation types instead ("overprovisioned identities should have only the necessary permissions" / "permissions of inactive identities should be revoked") plus **Cloud Security Explorer** for ad-hoc entitlement queries and **Attack Path Analysis** for lateral-movement-risk context — these are the current tools for the same underlying question PCI used to summarize.

**Rollback:** N/A — informational.

</details>

<details><summary>Fix 6 — AWS "inactive identity" recommendation looks like it's undercounting serverless/compute identities</summary>

**Cause:** documented, current limitation — serverless and compute identities for AWS are no longer included in CIEM's inactivity logic, which changes recommendation counts versus what an engineer might expect from the old standalone tool or from manual IAM review. Not a bug; do not spend time trying to force these into the recommendation.

**Rollback:** N/A — informational.

</details>

<details><summary>Fix 7 — Enabling CIEM fails, or the toggle is greyed out / permission denied</summary>

**Cause:** the account attempting to enable CIEM lacks the **Security Admin** role at the correct scope. Owner or Contributor alone is not sufficient for this specific action.

```powershell
# Azure — required at subscription scope
Get-AzRoleAssignment -SignInName <user-upn> -Scope "/subscriptions/<sub-id>" |
    Where-Object { $_.RoleDefinitionName -eq "Security Admin" }
```

For AWS/GCP, the equivalent is the Security Admin role at the account/organization level (AWS) or project/org level (GCP) — assigned outside of Azure RBAC, in the respective cloud's own IAM.

**Rollback:** N/A — role-assignment fix.

</details>

---
## Escalation Evidence

```
=== CIEM Escalation Packet ===
Ticket #: ___________
Client / Tenant: ___________
Cloud(s) affected: [ ] Azure  [ ] AWS  [ ] GCP

Defender CSPM plan tier (Get-AzSecurityPricing):  ___________
CIEM toggle state (portal, per environment):      ___________
Time CIEM was enabled (if known):                 ___________
Multicloud connector present (Y/N):               ___________
CIEM-specific onboarding step (CloudFormation/Terraform) re-run after toggle-on (Y/N): ___________
CloudTrail / Cloud Logging ingestion enabled (AWS/GCP only):  ___________
Recommendation output (Triage step 2/3 results, paste below):
___________________________________________________

Security Admin role confirmed for the account making changes (Y/N): ___________
Client previously used standalone Entra Permissions Management (Y/N) — if Y, note this is a fresh onboarding, not a migration: ___________
```

---
## 🎓 Learning Pointers

- **Standalone Microsoft Entra Permissions Management retired after October 1, 2025.** Any client-facing conversation should start by confirming which product they mean — the retired standalone tool has no successor migration path, only a fresh onboarding into Defender for Cloud's CIEM capability. See [Microsoft Entra Permissions Management overview](https://learn.microsoft.com/en-us/entra/permissions-management/overview).
- **CIEM is a sub-feature of the Defender CSPM plan, not the plan itself.** Enabling Defender CSPM does not automatically enable CIEM — they are two separate toggles, and this is the most common "data is missing" ticket. See [Cloud infrastructure entitlement management (CIEM) — Defender for Cloud](https://learn.microsoft.com/en-us/azure/defender-for-cloud/permissions-management).
- **AWS and GCP require a CIEM-specific re-run of the connector's access-configuration step**, distinct from the original multicloud connector onboarding — an existing connector predating CIEM enablement will not automatically have the needed permissions. See [Enable CIEM in Defender for Cloud](https://learn.microsoft.com/en-us/azure/defender-for-cloud/enable-permissions-management).
- **The Permissions Creep Index (PCI) metric is being deprecated** — don't chase its absence as a bug; the two named recommendation types plus Cloud Security Explorer/Attack Path Analysis are the current surface for the same insight.
