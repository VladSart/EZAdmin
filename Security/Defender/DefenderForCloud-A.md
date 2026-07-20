# Microsoft Defender for Cloud (CSPM) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

Covers **Microsoft Defender for Cloud** as a Cloud Security Posture Management (CSPM) platform — Secure Score, security recommendations, regulatory compliance, asset inventory, attack path analysis, and multicloud (Azure/AWS/GCP) plus hybrid (on-prem via Azure Arc) posture management.

**Explicitly out of scope (covered elsewhere):**
- Defender for Cloud **Apps** (MDA) — SaaS/CASB security → `MDA-A.md` / `MDA-B.md`
- Defender for **Endpoint** (MDE) sensor onboarding/health → `MDE-Onboarding-A.md` / `-B.md`
- Defender for **Identity** (MDI) → `MDI-A.md` / `MDI-B.md`
- Defender for **Servers** workload protection agent internals (EDR, AV) are adjacent — Defender for Cloud is the plan/posture layer that *enables* Defender for Servers, but agent-level troubleshooting belongs to MDE
- Azure Arc agent connectivity/identity itself → `Azure/Arc/AzureArc-A.md` (this document assumes Arc is already healthy and covers what Defender for Cloud does once a machine is Arc-connected)
- **CIEM (Cloud Infrastructure Entitlement Management)** — the identity/permission-risk sub-feature of the Defender CSPM plan (overprivileged/inactive identity detection, Cloud Security Explorer identity queries, Attack Path Analysis correlation, and the Oct 2025 retirement of standalone Microsoft Entra Permissions Management) is substantial and distinct enough to warrant its own file → `CIEM-A.md` / `-B.md`

**Assumptions:**
- At least one Azure subscription with Defender for Cloud accessible via `portal.azure.com` → Defender for Cloud, or the unified `security.microsoft.com` portal
- `Az.Security` and `Az.ResourceGraph` PowerShell modules, or equivalent Azure CLI (`az security`) access
- Contributor or Security Admin role at minimum for read operations; Owner/Security Admin for plan changes and connector management

---

## How It Works

<details><summary>Full architecture — CSPM plans, data flow, and multicloud onboarding</summary>

### Two-Plan Model

Defender for Cloud's posture management is split into two plans, both under the umbrella pricing name `CloudPosture`:

```
┌───────────────────────────────────────────────────────────────────┐
│                  Microsoft Defender for Cloud (CSPM)               │
│                                                                     │
│  ┌───────────────────────────┐   ┌─────────────────────────────┐  │
│  │  Foundational CSPM (Free)  │   │   Defender CSPM (Paid)       │  │
│  │  - Asset inventory         │   │   - Everything in Foundational│ │
│  │  - MCSB standard           │   │   - Agentless VM/container    │  │
│  │  - Secure Score            │   │     scanning (vuln + secrets)  │  │
│  │  - Basic recommendations   │   │   - Attack path analysis /     │  │
│  │  - Data export             │   │     Cloud Security Explorer    │  │
│  │  - Workflow automation     │   │   - Governance rules           │  │
│  └───────────────────────────┘   │   - Regulatory compliance      │  │
│                                    │     (beyond MCSB)              │  │
│                                    │   - DevOps security (PR        │  │
│                                    │     annotations, code-to-cloud)│  │
│                                    │   - AI/API security posture    │  │
│                                    │   - External attack surface mgmt│ │
│                                    └─────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────┘
```

Foundational CSPM is enabled automatically the moment a subscription, AWS account, or GCP project is onboarded — there is no separate "enable" step. Defender CSPM is opt-in per subscription/connector and is billed per specific resource type (see Dependency Stack for the exact billable-resource tables).

### Recommendation → Secure Score Pipeline

```
Azure Policy (MCSB + any custom initiatives)
        │  assigned to subscription/management group
        ▼
Policy compliance evaluation (continuous, ~sub-hour for policy state,
        but assessment recompute can lag up to 24h after a resource change)
        ▼
Security Assessments (Microsoft.Security/assessments)
        │  one assessment per recommendation per resource
        │  Status: Healthy / Unhealthy / NotApplicable
        ▼
Secure Score computation
        │  weighted by security control, NOT a simple average of
        │  pass/fail — some controls are worth more points than others
        │  and a control caps out at its max even if all sub-checks pass
        ▼
Secure Score displayed per subscription, and rolled up for management
        groups / multicloud connectors
```

**Key nuance:** Secure Score is *not* "percentage of recommendations passed." It's computed per security control (a named grouping like "Enable MFA" or "Remediate vulnerabilities"), each with its own point weight and its own maximum achievable score. A single unresolved recommendation in a high-weight control can move the score more than ten resolved recommendations in a low-weight control.

### Multicloud Onboarding Architecture

```
AWS onboarding:
    Defender for Cloud → generates CloudFormation template
        │
        ├── Management account stack (org-wide, deploys StackSet)
        │       └── IAM role: CspmMonitorAws (assumed by Microsoft's
        │           service principal, scoped to read-only security data)
        │
        └── Member account stacks (per-account, via StackSet)
                └── Same assumed-role trust, deployed to each member account

GCP onboarding:
    Defender for Cloud → generates Cloud Shell onboarding script
        │
        ├── Creates Workload Identity Federation pool + provider
        │       (WorkloadIdentityPoolId, WorkloadIdentityProviderId)
        ├── Creates a GCP service account (ServiceAccountEmail)
        │       scoped with viewer-level IAM roles
        └── No long-lived key/secret — WIF issues short-lived tokens
            to Microsoft's service, avoiding static GCP service account keys

On-prem / other-cloud servers:
    Individual machine → Azure Arc agent (azcmagent connect)
        │
        └── Once Arc-connected, the machine appears as a
            Microsoft.HybridCompute/machines resource — Defender for
            Cloud treats it like any other Azure resource for policy
            assignment, MCSB assessment, and (with Defender CSPM +
            Defender for Servers) agent-based or agentless posture checks
```

Both AWS and GCP connectors are **agentless by design** for CSPM purposes — no agent is installed in the customer's cloud account for basic posture data. Agentless VM/container scanning (Defender CSPM feature) works via cloud-native snapshot APIs (EBS snapshots for AWS, persistent disk snapshots for GCP), not an in-guest agent, which is why "deallocated/nonrunning" exclusions exist — there's no live disk to snapshot.

### Attack Path Analysis & Cloud Security Explorer (Defender CSPM only)

```
Resource Graph (asset + config data)
        │
        ▼
Data Security graph population (correlates identity, network exposure,
        vulnerability data, and resource relationships — this is the
        graph attack path analysis walks)
        │
        ▼
Attack paths: pre-computed chains like
    "Internet-exposed VM → has vulnerability → has access to
     Key Vault → Key Vault has secret used by privileged Function App"
        │
        ▼
Cloud Security Explorer: ad-hoc query interface over the same graph
```

This graph takes time to populate after onboarding (up to 24h is typical) — an empty Security Explorer immediately after enabling Defender CSPM is expected, not broken.

</details>

---

## Dependency Stack

```
Layer 7: Regulatory Compliance Dashboard & Governance Rules  (Defender CSPM)
                    │  requires standard assignment + Defender CSPM plan
Layer 6: Attack Path Analysis / Cloud Security Explorer       (Defender CSPM)
                    │  requires Data Security graph population (~24h lag)
Layer 5: Agentless VM/Container Scanning (vuln + secrets)     (Defender CSPM)
                    │  requires Azure Policy assignment + resource not
                    │  deallocated/nonrunning
Layer 4: Security Assessments & Secure Score                  (Foundational — always on)
                    │  requires Azure Policy MCSB assignment
Layer 3: Azure Policy (MCSB + custom initiatives)
                    │  requires subscription/mgmt-group policy assignment scope
Layer 2: Asset connectivity layer
                    ├── Azure: native Resource Manager (no extra step)
                    ├── AWS: CloudFormation StackSet + assumed IAM role
                    ├── GCP: Workload Identity Federation + service account
                    └── On-prem/other-cloud: Azure Arc agent (HybridCompute)
Layer 1: Azure Resource Graph (backing store for all asset inventory)
                    │
Layer 0: Entra ID tenant + Azure subscription (root identity/billing scope)
```

**Billable resource exclusions (Defender CSPM), by cloud:**

| Cloud | Service | Included | Excluded |
|---|---|---|---|
| Azure | Compute | VMs, VMSS, classic VMs | Deallocated VMs, Databricks VMs |
| Azure | Storage | Storage accounts | Accounts without blob containers or file shares |
| Azure | Databases | SQL servers, PostgreSQL/MySQL servers, Synapse workspaces | – |
| AWS | Compute | EC2 instances | Deallocated (stopped) VMs |
| AWS | Storage | S3 buckets | – |
| AWS | Databases | RDS instances | – |
| GCP | Compute | Compute instances, Instance Groups | Nonrunning instances |
| GCP | Storage | Storage buckets | Nearline/coldline/archive classes, unsupported regions |
| GCP | Databases | Cloud SQL instances | – |

**Critical external dependencies:**
- AWS: `sts.amazonaws.com` assumed-role trust; CloudTrail (incurs AWS-side cost from Defender's own API calls)
- GCP: Workload Identity Federation endpoints reachable; Azure Arc firewall allowlist for GCP connector onboarding files
- Both: initial and periodic discovery scans generate cloud-native API call volume/cost (CloudTrail lookup events on AWS; loggable via `Log Explorer` on GCP)

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Feature (attack path, agentless scan, compliance standard) not visible | Foundational CSPM only — feature requires paid Defender CSPM | `Get-AzSecurityPricing` |
| Secure Score suddenly drops | Genuine new misconfiguration, OR newly onboarded resources still in 24h grace window | Diff unhealthy assessments against resource creation timestamps |
| Secure Score doesn't move after fixing a recommendation | Assessment recompute lag (up to 24h), or fix didn't actually satisfy the policy definition | Re-check after 24h; validate against the exact policy condition |
| AWS connector onboarding fails at CloudFormation | Access denied / duplicate resource / outdated template / StackSet org trust issue | CloudFormation error resolution table (below) |
| GCP connector onboarding fails | Missing `compute.regions.list` or Entra permission; WIF resources not created | Confirm `WorkloadIdentityPoolId`/`WorkloadIdentityProviderId`/`ServiceAccountEmail` exist |
| Same AWS/GCP account can't be onboarded | Already connected under a different Azure subscription in the same Entra tenant — only one connector per account per tenant | Tenant-wide Resource Graph search for existing connector |
| Agentless VM scan results empty (GCP specifically) | `Compute Storage resource use restrictions` GCP org policy blocking disk/snapshot access | GCP Console → Organization Policies |
| Agentless scan results empty (any cloud) | Resource deallocated/nonrunning, or Defender CSPM not enabled, or <24h since onboarding | `Get-AzSecurityPricing` + resource power state |
| Attack path / Security Explorer empty | Data Security graph not yet populated (new onboarding), or Defender CSPM not enabled | Wait 24h; confirm plan tier |
| Regulatory compliance dashboard shows wrong/no standard | No standard assigned, or assigned standard requires Defender CSPM | Environment Settings → Security Policies |
| Connector stuck, can't delete | Resource lock on the `securityconnectors` resource | `Get-AzResourceLock` |
| On-prem server never shows Defender for Cloud data | Arc agent not connected/healthy — this is a prerequisite layer, not a Defender for Cloud fault | `Azure/Arc/AzureArc-B.md` triage first |
| Unexpected AWS CloudTrail / GCP API billing | Defender's own discovery + periodic scan API calls generate cloud-native cost | Query CloudTrail/Log Explorer filtered by Defender's assumed-role ARN or `microsoft-defender` principal |

---

## Validation Steps

**1. Confirm plan tiers across all Defender for Cloud plans**
```powershell
Connect-AzAccount
Get-AzSecurityPricing | Select-Object Name, PricingTier, FreeTrialRemainingTime
```
Expect `Name = CloudPosture` to show `Standard` if Defender CSPM is purchased, `Free` if only Foundational.

**2. Pull Secure Score and per-control breakdown**
```powershell
Get-AzSecuritySecureScore | Select-Object DisplayName, @{N="Current";E={$_.Score.Current}}, @{N="Max";E={$_.Score.Max}}
Get-AzSecuritySecureScoreControl | Select-Object DisplayName, @{N="Current";E={$_.Score.Current}}, @{N="Max";E={$_.Score.Max}}, HealthyResourceCount, UnhealthyResourceCount | Sort-Object UnhealthyResourceCount -Descending
```

**3. Enumerate unhealthy assessments (the raw recommendation feed)**
```powershell
Get-AzSecurityAssessment | Where-Object { $_.Status.Code -eq "Unhealthy" } |
    Select-Object DisplayName, ResourceId, @{N="Severity";E={$_.Metadata.Severity}} |
    Sort-Object Severity
```

**4. Confirm multicloud connectors exist and their config**
```powershell
Search-AzGraph -Query "resources | where type =~ 'microsoft.security/securityconnectors' | project name, properties.environmentName, properties.environmentData"
```
Cross-reference `environmentName` (AWS/GCP) and confirm the account/project ID matches expectations.

**5. Confirm Azure Policy (MCSB) is actually assigned**
```powershell
Get-AzPolicyAssignment | Where-Object { $_.Properties.DisplayName -match "Microsoft cloud security benchmark" }
```

**6. Check for AWS discovery API call volume/cost (if billing concern raised)**
```
# Run in AWS Athena or CloudTrail Lake against the account in question
SELECT COUNT(*) AS overallApiCallsCount FROM <TABLE-NAME>
WHERE userIdentity.arn LIKE 'arn:aws:sts::<ACCOUNT-ID>:assumed-role/CspmMonitorAws/MicrosoftDefenderForClouds_<TENANT-ID>'
AND eventTime > TIMESTAMP '<DATETIME>'
```

**7. Check for resource locks blocking connector management**
```powershell
Get-AzResourceLock | Where-Object { $_.ResourceId -match "securityconnectors" }
```

---

## Troubleshooting Steps (by phase)

### Phase 1: Plan/licensing confirmation (always do this first)
1. `Get-AzSecurityPricing` — confirm which plans are Standard vs. Free.
2. Map the reported "missing" feature against the Foundational vs. Defender CSPM feature table (Dependency Stack section).
3. If it's a plan gap: this is a purchasing decision, escalate to the account owner, not an engineering fix.

### Phase 2: Secure Score / recommendation investigation
1. Pull unhealthy assessments and sort by severity.
2. Check resource creation/change timestamp — inside 24h of onboarding/change is expected transient unhealthy state.
3. Apply the recommendation's built-in "Fix" action where offered, or trigger the underlying Azure Policy remediation task.
4. For at-scale drift across many resources, use a Governance rule (Defender CSPM) to assign owner + SLA rather than manual one-by-one fixes.
5. Re-validate Secure Score after 24h.

### Phase 3: Multicloud connector onboarding failure
1. Identify which cloud (AWS/GCP) and pull the exact error text from the CloudFormation event log (AWS) or Cloud Shell script output (GCP).
2. AWS: match against the CloudFormation error resolution table.
3. GCP: confirm required permissions and WIF resources exist; confirm Cloud Shell script ran to completion.
4. Tenant-wide check: search Resource Graph for an existing connector on the same account/project before assuming this is a first-time onboarding failure.
5. Retry onboarding only after root cause is addressed — repeated retries against an unresolved IAM/WIF issue will fail identically.

### Phase 4: Agentless scanning / attack path data missing
1. Confirm Defender CSPM plan is Standard.
2. Confirm resource power state (not deallocated/nonrunning).
3. GCP-specific: check and fix the `Compute Storage resource use restrictions` org policy.
4. Allow the full 24h data-population window before treating as broken.
5. If still empty after 24h with plan confirmed Standard and resources running: escalate with connector resource ID and onboarding timestamp.

### Phase 5: MSP fleet-scale posture review
1. Pull Secure Score across all managed tenants/subscriptions via a Lighthouse-delegated or per-tenant loop:
   ```powershell
   $subs = Get-AzSubscription
   foreach ($sub in $subs) {
       Set-AzContext -SubscriptionId $sub.Id | Out-Null
       Get-AzSecuritySecureScore | Select-Object @{N="Subscription";E={$sub.Name}}, DisplayName, @{N="Current";E={$_.Score.Current}}, @{N="Max";E={$_.Score.Max}}
   }
   ```
2. Flag subscriptions still on Foundational CSPM only, if Defender CSPM is the agreed managed-service baseline.
3. Flag subscriptions with zero multicloud connectors where the client is known to run AWS/GCP workloads — a coverage gap, not a technical fault.
4. Roll up into a client-facing posture summary — Secure Score percentage, count of high-severity unhealthy recommendations, and connector coverage.

---

## Remediation Playbooks

<details>
<summary>Playbook 1 — Enable Defender CSPM on a subscription (with cost awareness)</summary>

**Scenario:** Client wants attack path analysis, agentless scanning, and regulatory compliance beyond MCSB.

**Steps:**
1. Confirm current state: `Get-AzSecurityPricing | Select-Object Name, PricingTier`
2. Review billable resource tables (Dependency Stack) with the client — Defender CSPM is billed per specific resource type, not a flat subscription fee. Use the [cost calculator](https://learn.microsoft.com/en-us/azure/defender-for-cloud/cost-calculator) before enabling.
3. Enable:
   ```powershell
   Set-AzSecurityPricing -Name "CloudPosture" -PricingTier "Standard"
   ```
4. Allow 24h for agentless scanning and Data Security graph (attack path) population.
5. Assign additional regulatory compliance standards if required: Environment Settings → Security Policies → Add standard.

**Rollback:**
```powershell
Set-AzSecurityPricing -Name "CloudPosture" -PricingTier "Free"
```
Reverting stops future agentless scans and attack path computation; historical data in the portal may remain visible for a retention window but will stop refreshing.

</details>

<details>
<summary>Playbook 2 — Onboard an AWS organization at scale (management + member accounts)</summary>

**Scenario:** MSP managing an AWS Organization wants full-org CSPM coverage, not just the management account.

**Steps:**
1. In Defender for Cloud → Environment Settings → Add environment → Amazon Web Services.
2. Choose **Management account** onboarding (not single account) to cover the full AWS Organization via StackSet.
3. Download and run the generated CloudFormation template against the management account first.
4. Confirm the StackSet deploys to member accounts — this can take significant time for large orgs; monitor via AWS CloudFormation console, not the Defender for Cloud portal.
5. If StackSet deployment stalls: verify Organizations trusted access for CloudFormation is enabled in AWS Organizations settings (a common silent blocker).
6. Validate: `Search-AzGraph` for the connector resource, then confirm member-account resources appear in Asset Inventory within 24h.
7. Assign Defender CSPM to the connector if paid features are required (billed per AWS resource type, same tables as Azure).

**Rollback:** Remove the connector from Environment Settings; this does not automatically remove the CloudFormation stacks from AWS — those must be deleted separately from the AWS side if full cleanup is required.

</details>

<details>
<summary>Playbook 3 — Fix the GCP agentless-scan-empty org policy issue at scale</summary>

**Scenario:** Multiple GCP projects under an organization show zero agentless scan results 24h+ after onboarding, despite connectors showing healthy.

**Steps:**
1. Confirm the pattern is org-wide, not per-project, by checking 2-3 projects' `Compute Storage resource use restrictions` policy.
2. In GCP Console → IAM & Admin → Organization Policies (at the **organization** level, not per-project, to fix all projects at once): find `Compute Storage resource use restrictions (Compute Engine disks, images, and snapshots)`.
3. Set policy type to **Allow**, add `under:organizations/517615557103` to the allowlist, Save.
4. This applies to all projects under the org going forward — no per-project change needed.
5. Wait up to 24h for the next scheduled agentless scan API call cycle; results populate automatically once the policy fix is in place.
6. Validate via `Get-AzSecurityAssessment` filtered to the GCP-connected resources, confirming assessment status moves off "no data."

**Rollback:** Revert the organization policy to its prior restriction level if there was a compliance reason it was set — coordinate with the client's GCP security/compliance owner before changing an org-level policy, since this is a customer-owned control, not a Defender for Cloud setting.

</details>

<details>
<summary>Playbook 4 — MSP fleet-wide Secure Score and coverage sweep</summary>

**Scenario:** Quarterly posture review across all managed client tenants/subscriptions — identify coverage gaps and low-scoring subscriptions before the client review call.

```powershell
$subs = Get-AzSubscription
$report = foreach ($sub in $subs) {
    Set-AzContext -SubscriptionId $sub.Id | Out-Null
    $pricing = Get-AzSecurityPricing -Name "CloudPosture"
    $score   = Get-AzSecuritySecureScore
    $connectors = (Search-AzGraph -Query "resources | where type =~ 'microsoft.security/securityconnectors'").Count

    [PSCustomObject]@{
        Subscription      = $sub.Name
        DefenderCSPMTier  = $pricing.PricingTier
        SecureScorePct    = if ($score.Score.Max -gt 0) { [math]::Round(($score.Score.Current/$score.Score.Max)*100,1) } else { "N/A" }
        MulticloudConnectors = $connectors
    }
}
$report | Sort-Object SecureScorePct | Format-Table -AutoSize
$report | Export-Csv "C:\Reports\FleetPostureReview-$(Get-Date -Format 'yyyyMMdd').csv" -NoTypeInformation
```

**Use the output to:** flag subscriptions still on Free tier where Defender CSPM is contractually expected, flag zero-connector subscriptions for clients with known multicloud footprints, and prioritize the lowest Secure Score subscriptions for the review call.

**Rollback:** N/A — read-only reporting script.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Defender for Cloud (CSPM) evidence for escalation or client reporting.
.NOTES
    Read-only. Requires Az.Security, Az.ResourceGraph, Az.Resources modules and an
    authenticated Az context with at least Security Reader role.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = "C:\Temp\DefenderForCloud-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
)

function Write-Status { param([string]$Msg,[string]$Status="INFO") Write-Host "[$Status] $Msg" -ForegroundColor $(switch($Status){"OK"{"Green"}"WARN"{"Yellow"}"ERROR"{"Red"}default{"Cyan"}}) }

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

Write-Status "Collecting plan/pricing state..."
Get-AzSecurityPricing | Select-Object Name, PricingTier, FreeTrialRemainingTime |
    Export-Csv "$OutputPath\pricing_plans.csv" -NoTypeInformation

Write-Status "Collecting Secure Score..."
Get-AzSecuritySecureScore | Select-Object DisplayName, @{N="Current";E={$_.Score.Current}}, @{N="Max";E={$_.Score.Max}} |
    Export-Csv "$OutputPath\secure_score.csv" -NoTypeInformation

Write-Status "Collecting Secure Score control breakdown..."
Get-AzSecuritySecureScoreControl | Select-Object DisplayName, @{N="Current";E={$_.Score.Current}}, @{N="Max";E={$_.Score.Max}}, HealthyResourceCount, UnhealthyResourceCount |
    Export-Csv "$OutputPath\secure_score_controls.csv" -NoTypeInformation

Write-Status "Collecting unhealthy assessments..."
Get-AzSecurityAssessment | Where-Object { $_.Status.Code -eq "Unhealthy" } |
    Select-Object DisplayName, ResourceId, @{N="Severity";E={$_.Metadata.Severity}} |
    Export-Csv "$OutputPath\unhealthy_assessments.csv" -NoTypeInformation

Write-Status "Collecting multicloud connectors..."
try {
    (Search-AzGraph -Query "resources | where type =~ 'microsoft.security/securityconnectors' | project name, properties.environmentName, properties.environmentData").Data |
        Export-Csv "$OutputPath\multicloud_connectors.csv" -NoTypeInformation
} catch { Write-Status "Resource Graph query failed: $_" "WARN" }

Write-Status "Collecting resource locks on security connectors..."
Get-AzResourceLock | Where-Object { $_.ResourceId -match "securityconnectors" } |
    Export-Csv "$OutputPath\connector_locks.csv" -NoTypeInformation

Write-Status "Evidence collected to: $OutputPath" "OK"
```

---

## Command Cheat Sheet

| Task | Command |
|---|---|
| Check plan tiers | `Get-AzSecurityPricing` |
| Enable Defender CSPM | `Set-AzSecurityPricing -Name "CloudPosture" -PricingTier "Standard"` |
| Get Secure Score | `Get-AzSecuritySecureScore` |
| Get Secure Score per control | `Get-AzSecuritySecureScoreControl` |
| List unhealthy recommendations | `Get-AzSecurityAssessment \| Where-Object { $_.Status.Code -eq "Unhealthy" }` |
| Find multicloud connectors | `Search-AzGraph -Query "resources \| where type =~ 'microsoft.security/securityconnectors'"` |
| Check MCSB policy assignment | `Get-AzPolicyAssignment \| Where-Object { $_.Properties.DisplayName -match "cloud security benchmark" }` |
| Check resource locks on connectors | `Get-AzResourceLock \| Where-Object { $_.ResourceId -match "securityconnectors" }` |
| Cost calculator (Defender CSPM) | https://learn.microsoft.com/en-us/azure/defender-for-cloud/cost-calculator |
| Portal — Environment Settings | `portal.azure.com` → Defender for Cloud → Environment Settings |
| Portal — Security Explorer / attack paths | `portal.azure.com` → Defender for Cloud → Cloud Security Explorer |
| GCP org policy for disk scan | GCP Console → IAM & Admin → Organization Policies → `Compute Storage resource use restrictions` |
| AWS CloudTrail cost query | Athena/CloudTrail Lake filtered on `assumed-role/CspmMonitorAws/...` |

---

## 🎓 Learning Pointers

- **Secure Score is control-weighted, not a flat percentage of passed checks:** Each security control has its own point value and cap. Fixing the highest-severity, highest-weight control (often "Enable MFA" or "Remediate vulnerabilities") moves the score far more than clearing several low-weight recommendations. Use `Get-AzSecuritySecureScoreControl` to see per-control weight before prioritizing remediation work. [MS Docs: Secure score](https://learn.microsoft.com/en-us/azure/defender-for-cloud/secure-score-security-controls)

- **Foundational CSPM vs. Defender CSPM is a licensing line, not a bug boundary:** Nearly every "why doesn't this feature work" ticket for attack paths, agentless scanning, governance rules, or non-MCSB compliance standards resolves to "that's a paid-plan feature." Confirming plan tier via `Get-AzSecurityPricing` should be the first move in any CSPM ticket, before any deeper investigation. [MS Docs: What is CSPM](https://learn.microsoft.com/en-us/azure/defender-for-cloud/concept-cloud-security-posture-management)

- **Multicloud connectors are agentless and identity-federated, not credential-based:** AWS uses an assumed IAM role (no static keys); GCP uses Workload Identity Federation (no static service account keys). This is more secure than legacy key-based integrations but means onboarding failures are almost always an identity/trust configuration problem (StackSet org trust, WIF resource creation) rather than a "wrong password" problem. [MS Docs: Connect your AWS account](https://learn.microsoft.com/en-us/azure/defender-for-cloud/quickstart-onboard-aws)

- **Only one connector per cloud account per Entra tenant, ever:** This trips up MSPs managing multiple subscriptions in one tenant — if a client's AWS account was piloted under a sandbox subscription, it must be removed there before it can be onboarded under the production management subscription. Always search Resource Graph tenant-wide first. [MS Docs: Troubleshoot connectors guide](https://learn.microsoft.com/en-us/azure/defender-for-cloud/troubleshoot-connectors)

- **Defender's own discovery scans generate billable API activity on the customer's cloud account:** AWS CloudTrail lookup events and GCP API calls from Defender's periodic discovery scans are not free on the cloud provider's side. For cost-sensitive clients, this is worth surfacing proactively rather than waiting for a surprise CloudTrail bill question. [MS Docs: Troubleshoot connectors — cost impact](https://learn.microsoft.com/en-us/azure/defender-for-cloud/troubleshoot-connectors)

- **Azure Arc is the on-ramp for hybrid/on-prem CSPM coverage:** A server outside Azure only becomes visible to Defender for Cloud once it's Arc-connected (`Microsoft.HybridCompute/machines`). If a client asks why their on-prem fleet has no Secure Score contribution, the answer is almost always "they're not Arc-onboarded yet," not a Defender for Cloud configuration issue — start with `Azure/Arc/AzureArc-A.md`.
