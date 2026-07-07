# Microsoft Defender for Cloud (CSPM) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

> **Scope note:** This is Cloud Security Posture Management (CSPM) — Secure Score, recommendations, regulatory compliance, and multicloud connector health for Azure/AWS/GCP subscriptions and on-prem (via Arc). It is distinct from `MDA-B.md` (Defender for Cloud **Apps** — SaaS/CASB), `MDE-Onboarding-B.md` (Defender for **Endpoint** — device sensor), and `MDI-B.md` (Defender for **Identity**). If the issue is a connector for an Azure Arc-enabled server itself (agent won't connect, heartbeat lost), start at `Azure/Arc/AzureArc-B.md` first — this runbook assumes the Arc agent is already healthy and covers what Defender for Cloud does with it afterward.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

```powershell
# 1. Confirm Defender for Cloud plans enabled on the subscription
Connect-AzAccount
Get-AzSecurityPricing | Select-Object Name, PricingTier, FreeTrialRemainingTime

# 2. Pull current Secure Score
Get-AzSecuritySecureScore | Select-Object DisplayName, @{N="Current";E={$_.Score.Current}}, @{N="Max";E={$_.Score.Max}}, @{N="Percentage";E={[math]::Round(($_.Score.Current/$_.Score.Max)*100,1)}}

# 3. Check for unhealthy/failed assessments (top offenders)
Get-AzSecurityAssessment | Where-Object { $_.Status.Code -eq "Unhealthy" } |
    Select-Object DisplayName, @{N="Severity";E={$_.Metadata.Severity}}, ResourceId |
    Sort-Object Severity | Format-Table -AutoSize

# 4. Check multicloud connector health (AWS/GCP) via Resource Graph
Search-AzGraph -Query "resources | where type =~ 'microsoft.security/securityconnectors' | project name, properties.environmentName, properties.environmentData"

# 5. Check for resource locks blocking connector delete/update
Get-AzResourceLock | Where-Object { $_.ResourceId -match "securityconnectors" }
```

**Interpretation table:**

| Result | What it means | Action |
|---|---|---|
| `PricingTier = Free` on all plans | Only Foundational CSPM active — no Defender CSPM, no agentless scanning, no attack path analysis | Confirm this is intentional (cost) before assuming a bug — see Fix 1 |
| Secure Score dropped suddenly | New resources deployed without hardening, or a recommendation went stale/inaccurate | Diff the unhealthy assessment list against last week's export — Fix 2 |
| Many `Unhealthy` assessments with same `ResourceId` prefix | A whole resource group/subscription was recently onboarded and hasn't been remediated yet | Expected transient state for 24-48h after onboarding — re-check after that window |
| AWS/GCP connector missing from Resource Graph query | Connector was never created, or onboarding failed silently | Fix 3 |
| Connector present but no findings for that account for 24h+ | Discovery scan hasn't completed, or permission/role trust broken on the cloud side | Fix 3 |
| Resource lock found on a `securityconnectors` resource | Blocks delete/update operations, including re-onboarding after a broken connector | Remove lock, retry |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft Defender for Cloud (portal.azure.com / security.microsoft.com)
        │
        ├── Foundational CSPM (free, always-on for onboarded subs)
        │       ├── Microsoft Cloud Security Benchmark (MCSB) standard assigned
        │       ├── Asset inventory (Resource Graph-backed)
        │       └── Secure Score (computed from MCSB recommendation pass/fail state)
        │
        ├── Defender CSPM (paid — opt-in per subscription/connector)
        │       ├── Agentless VM scanning (vuln + secrets) — needs Azure Policy assignment,
        │       │       no VM agent required, but VM must not be deallocated
        │       ├── Agentless container/Kubernetes discovery
        │       ├── Attack path analysis / Security Explorer (needs Resource Graph + Data
        │       │       Security graph population — can lag 24h after onboarding)
        │       ├── Governance rules (drives remediation SLAs — needs assigned owner emails)
        │       └── Regulatory compliance dashboard (needs standard assigned to subscription)
        │
        ├── Multicloud connectors
        │       ├── AWS: CloudFormation StackSet (management + member accounts)
        │       │       └── IAM role trust to Microsoft's assumed-role ARN
        │       ├── GCP: Cloud Shell onboarding script
        │       │       └── Workload Identity Federation (WorkloadIdentityPoolId,
        │       │           WorkloadIdentityProviderId, ServiceAccountEmail)
        │       └── On-prem/other-cloud servers: Azure Arc-enabled servers
        │               └── Arc agent healthy & connected (see Azure/Arc/AzureArc-B.md)
        │
        └── Data plane feeding assessments
                ├── Azure Policy (assigns MCSB + any custom initiatives)
                ├── Azure Resource Graph (asset inventory backend)
                └── Log Analytics / Azure Monitor Agent (for VM-level, non-agentless checks)
```

</details>

---
## Diagnosis & Validation Flow

**1. Establish which layer the complaint is about**

```
"Secure Score dropped" / "recommendation X shows unhealthy" → Fix 2
"AWS/GCP account shows no data" / connector error            → Fix 3
"VM vulnerability scan results missing"                       → Fix 4
"Regulatory compliance dashboard is empty/wrong standard"     → Fix 5
"Can't delete/re-add a connector"                             → Fix 6
```

**2. Confirm plan tier first — most "missing feature" tickets are a plan gap, not a bug**

```powershell
Get-AzSecurityPricing | Select-Object Name, PricingTier
```
Attack path analysis, agentless scanning, governance rules, and regulatory compliance assessments **require Defender CSPM (paid)** — Foundational CSPM does not have them. Check this before troubleshooting further.

**3. Confirm the resource is actually in scope**

Agentless VM scanning excludes deallocated VMs and Databricks VMs (Azure); excludes nonrunning instances (GCP); Defender CSPM billing/scanning also has service-specific exclusions (see `DefenderForCloud-A.md` → Dependency Stack for the full exclusion tables).

**4. For multicloud, confirm the connector itself exists as a resource**

```powershell
Search-AzGraph -Query "resources | where type =~ 'microsoft.security/securityconnectors'"
```
If it returns nothing, onboarding never completed — go to Fix 3, not a scan-health investigation.

**5. Check assessment freshness**

```powershell
(Get-AzSecurityAssessment | Select-Object -First 1).Metadata
# Look at the assessment's own timestamp/status vs. "LastComputed" — assessments can be
# stale for up to 24h after a resource change; don't chase a false "not updating" report
# inside that window.
```

---
## Common Fix Paths

<details><summary>Fix 1 — Feature "missing" is actually a plan-tier gap</summary>

**Cause:** Foundational CSPM (free) does not include: agentless scanning (VM vuln/secrets, container discovery), attack path analysis / Cloud Security Explorer, governance rules, regulatory compliance assessments beyond MCSB, AI/API security posture, DevOps security (PR annotations, code-to-cloud mapping), or ServiceNow integration. These all require the paid **Defender CSPM** plan.

**Steps:**
1. Confirm current tier: `Get-AzSecurityPricing | Select-Object Name, PricingTier`
2. If the requested feature is on the paid-only list, this is a licensing conversation, not a bug — quote the feature comparison table in `DefenderForCloud-A.md`.
3. To enable (with owner approval — this is billable):
   ```powershell
   Set-AzSecurityPricing -Name "CloudPosture" -PricingTier "Standard"
   ```
4. Allow up to 24h for agentless scanning and attack path data to populate after upgrade.

**Rollback:**
```powershell
Set-AzSecurityPricing -Name "CloudPosture" -PricingTier "Free"
```

</details>

<details><summary>Fix 2 — Secure Score dropped / recommendation shows unhealthy</summary>

**Cause:** Either a genuine new misconfiguration, a newly onboarded resource still in its grace window, or a recommendation whose underlying check changed.

**Steps:**
1. Pull the specific unhealthy assessment and its remediation guidance:
   ```powershell
   Get-AzSecurityAssessment | Where-Object DisplayName -eq "<recommendation name>" |
       Select-Object DisplayName, Status, ResourceId, @{N="Description";E={$_.Metadata.Description}}, @{N="Remediation";E={$_.Metadata.RemediationDescription}}
   ```
2. Check the resource's creation/change timestamp — if it's inside the last 24h, this may just be pending recompute, not a real regression.
3. If genuine: apply the remediation using the built-in "Fix" action where available (portal → Recommendations → select → **Fix**), or the underlying Azure Policy remediation task.
4. For at-scale drift (many resources, same recommendation), use a **Governance rule** (Defender CSPM only) to assign an owner and SLA rather than fixing one at a time.
5. Re-check score after 24h — Secure Score recompute is not instantaneous.

**Rollback:** N/A — this is a posture-improving action, not a destructive change. If a policy-based remediation was applied incorrectly, revert via the Azure Policy remediation task history.

</details>

<details><summary>Fix 3 — AWS/GCP connector missing data or failing onboarding</summary>

**AWS — CloudFormation error lookup:**

| Error | Fix |
|---|---|
| Access denied | Verify IAM role/StackSet org trust access; rerun with correct IAM role |
| Already exists / duplicate resource | Deploy template in one region first; remove leftover duplicates; retry |
| Unsupported Lambda runtime | Template is outdated — download latest template and redeploy |
| StackSet won't start / hangs | Enable Org trusted access for CloudFormation; retry via AWS CLI instead of console |
| Account already onboarded elsewhere in tenant | Only one connector per AWS account per Entra tenant is allowed — remove the existing connector first |

**GCP — common causes:**
1. Cloud Shell onboarding script didn't finish — rerun it fully; don't Ctrl-C partway through.
2. Missing `compute.regions.list` permission or Entra permission to create the onboarding service principal.
3. Confirm `WorkloadIdentityPoolId`, `WorkloadIdentityProviderId`, and `ServiceAccountEmail` resources actually exist in the GCP project.
4. If agentless VM scan results are empty after 24h: check the GCP org policy `Compute Storage resource use restrictions` — it commonly blocks Defender's access to disks/images/snapshots. Fix: GCP Console → IAM & Admin → Organization Policies → find that policy → set to **Allow** → allowlist `under:organizations/517615557103` → Save.

**Both clouds:**
```powershell
# Confirm the connector resource exists at all
Search-AzGraph -Query "resources | where type =~ 'microsoft.security/securityconnectors' | project name, properties.environmentName, properties.environmentData.hierarchyIdentifier"

# Confirm workloads actually exist in the target account/project — Defender can't
# show data for an empty account, which is often mistaken for a broken connector.
```

**Rollback:** Remove and recreate the connector from Environment Settings → the specific cloud → Remove, then re-run onboarding. Check for resource locks first (Fix 6) if delete silently fails.

</details>

<details><summary>Fix 4 — Agentless VM vulnerability/secrets scan results missing</summary>

**Cause:** Agentless scanning requires Defender CSPM (or Defender for Servers P2) and has resource-state exclusions.

1. Confirm plan: agentless scanning is not on Foundational CSPM — see Fix 1.
2. Confirm VM is not deallocated/nonrunning — deallocated Azure VMs and nonrunning GCP/AWS instances are explicitly excluded.
3. Confirm the relevant Azure Policy assignment ("Configure machines to receive a vulnerability assessment provider" / agentless scanning initiative) shows as **Compliant**, not just assigned.
4. Allow up to 24h after onboarding/policy assignment for first scan results.
5. For GCP specifically: check the org policy fix in Fix 3 — this is the #1 cause of "connector fine, but zero scan results" tickets for GCP.

**Rollback:** N/A — read-only scanning; disabling the plan simply stops future scans.

</details>

<details><summary>Fix 5 — Regulatory compliance dashboard empty or wrong standard</summary>

1. Confirm a compliance standard is actually assigned to the subscription/connector:
   - Portal: Environment Settings → subscription/connector → Security Policies → check assigned standards.
2. Regulatory compliance assessments beyond MCSB require **Defender CSPM** — Foundational CSPM only shows MCSB.
3. If the wrong standard (e.g., PCI-DSS instead of ISO 27001) is showing, it's an assignment issue, not a data issue — reassign the correct initiative under Security Policies.
4. Allow the same 24h recompute window as Secure Score after assigning a new standard.

**Rollback:** Remove the incorrectly assigned standard from Security Policies; reassign the correct one.

</details>

<details><summary>Fix 6 — Can't delete or re-add a connector (stuck state)</summary>

1. Check for a resource lock on the connector resource:
   ```powershell
   Get-AzResourceLock | Where-Object { $_.ResourceId -match "securityconnectors" }
   ```
2. Check Azure Activity Log for the failed delete operation and its specific error.
3. Remove any lock found:
   ```powershell
   Remove-AzResourceLock -LockId "<lock resource ID>"
   ```
4. Retry the delete from Environment Settings → connector → Remove.
5. If deletion still fails, open a support case — some connector states (e.g., mid-onboarding failures) require backend cleanup.

**Rollback:** Re-adding the lock after successful reconfiguration, if it was intentional (e.g., a `CanNotDelete` lock protecting production security tooling).

</details>

---
## Escalation Evidence

```
ESCALATION TICKET — Microsoft Defender for Cloud (CSPM)
=========================================================
Date/Time of issue:              ___________________________
Affected subscription/account:   ___________________________
Cloud (Azure / AWS / GCP / on-prem via Arc): ___________________________
Symptom observed:
  [ ] Secure Score / recommendation issue
  [ ] Multicloud connector missing data or onboarding failure
  [ ] Agentless VM scan results missing
  [ ] Regulatory compliance dashboard issue
  [ ] Connector stuck / can't delete or re-add

Current plan tier (Get-AzSecurityPricing output):   ___________________________
Connector resource confirmed via Resource Graph:    [ ] Yes  [ ] No
Time since onboarding/last change:                  ___________________________
Specific recommendation/assessment name (if applicable): ___________________________
CloudFormation/GCP Cloud Shell error text (if applicable): ___________________________
Resource lock present:                               [ ] Yes  [ ] No — Lock ID: ___________
Azure Activity Log correlation ID:                   ___________________________

Attached evidence:
  [ ] Get-AzSecurityAssessment export (CSV)
  [ ] Get-AzSecurityPricing output
  [ ] Resource Graph query output for the connector
  [ ] Screenshot of Environment Settings → connector → Connectivity status

Support contact: https://admin.microsoft.com → Support → New service request
Product: Microsoft Defender for Cloud
```

---
## 🎓 Learning Pointers

- **Foundational CSPM vs. Defender CSPM is the #1 source of "missing feature" tickets:** Foundational CSPM is free and always on — asset inventory, MCSB, Secure Score, and basic recommendations. Attack path analysis, agentless scanning, governance rules, and regulatory compliance beyond MCSB all require the paid Defender CSPM plan. Check `Get-AzSecurityPricing` before assuming something is broken. [MS Docs: What is CSPM](https://learn.microsoft.com/en-us/azure/defender-for-cloud/concept-cloud-security-posture-management)

- **Agentless scanning has real resource-state exclusions, not just plan gaps:** Deallocated Azure VMs, Databricks VMs, nonrunning GCP/AWS instances, and certain storage tiers (nearline/coldline/archive in GCP) are excluded from both scanning and billing. A "missing scan result" ticket is often a resource that was never in scope, not a scan failure. [MS Docs: Agentless VM scanning](https://learn.microsoft.com/en-us/azure/defender-for-cloud/enable-agentless-scanning-vms)

- **The GCP disk-scanning org policy is a recurring, specific gotcha:** If GCP agentless scan results don't appear within 24h, check the `Compute Storage resource use restrictions` organization policy before escalating — it silently blocks Defender's access to disks/images/snapshots and is easy to miss since the connector itself shows healthy. [MS Docs: Resolve agentless scan error](https://learn.microsoft.com/en-us/azure/defender-for-cloud/resolve-disk-scanning-error)

- **Only one connector per cloud account per Entra tenant:** If an AWS account or GCP project was previously onboarded under a different Azure subscription in the same tenant, a second onboarding attempt will fail or conflict. Always search Resource Graph for existing `microsoft.security/securityconnectors` resources tenant-wide before troubleshooting a "failed" onboarding as if it were the first attempt. [MS Docs: Troubleshoot connectors guide](https://learn.microsoft.com/en-us/azure/defender-for-cloud/troubleshoot-connectors)

- **Assessment and Secure Score data has a real recompute lag:** Don't chase a "not updating" report inside the first 24 hours after a resource change, policy assignment, or new onboarding — this is expected pipeline latency (Resource Graph → Policy compliance → assessment → Secure Score), not a stuck system.
