# Cloud Infrastructure Entitlement Management (CIEM) — Reference Runbook (Mode A: Deep Dive)
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
- [🎓 Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

Covers **Cloud Infrastructure Entitlement Management (CIEM)** as it exists today: a native capability of **Microsoft Defender for Cloud**, delivered through the paid **Defender CSPM** plan, providing multicloud (Azure/AWS/GCP) identity and permission-risk visibility — overprivileged/inactive identity detection, effective-permission analysis via Cloud Security Explorer, and lateral-movement correlation via Attack Path Analysis.

**Why this is a distinct topic rather than a section of `DefenderForCloud-A.md`:** CIEM is architecturally and operationally different enough from the rest of Defender for Cloud's CSPM surface (posture recommendations, regulatory compliance, agentless scanning) to warrant its own file — it has its own plan sub-toggle, its own per-cloud onboarding mechanics (CloudFormation/Terraform re-runs distinct from base connector onboarding), its own recommendation set, and — critically — a recent product-history event (the retirement of the standalone Microsoft Entra Permissions Management product) that generates a specific, recurring class of client question this file is built to answer directly.

**Historical context that shapes almost every CIEM ticket:** Microsoft previously offered CIEM as a **standalone product**, Microsoft Entra Permissions Management (the evolution of the acquired CloudKnox Security platform). That standalone product **was retired after October 1, 2025** and is no longer available or supported. Its capabilities were **not automatically migrated** — organizations that used it must onboard CIEM fresh inside Defender for Cloud's Defender CSPM plan. Microsoft's public retirement guidance also references third-party alternatives (e.g., Delinea's Privilege Control for Cloud Entitlements) for organizations wanting a dedicated, vendor-neutral CIEM product outside the Defender for Cloud umbrella — that evaluation is explicitly out of scope here, which stays Microsoft-native.

**In scope:**
- CIEM as a sub-feature of the Defender CSPM plan (enablement, licensing gate, role requirements)
- Multicloud identity discovery and effective-permission analysis (Azure Entra ID, AWS IAM, GCP IAM)
- The two per-cloud CIEM recommendation types (overprovisioned identities / inactive identities)
- Cloud Security Explorer as it applies to identity/entitlement queries
- Attack Path Analysis as it correlates over-privileged identities with lateral-movement risk
- The CIEM Workbook
- Known current limitations (Permissions Creep Index deprecation, AWS serverless/compute identity exclusion from inactivity logic)
- The standalone-product retirement and what it means operationally for existing clients

**Explicitly out of scope (covered elsewhere):**
- General Defender for Cloud CSPM (Secure Score, regulatory compliance, agentless scanning, multicloud connector *base* onboarding) → `DefenderForCloud-A.md` / `-B.md`
- Microsoft Entra ID's own PIM (Privileged Identity Management) for directory roles or Azure resource roles — a JIT activation model, architecturally unrelated to CIEM's posture/discovery model → `EntraID/Troubleshooting/PIM-A.md` / `PIMAzureResources-A.md`
- Conditional Access policies scoped to workload identities → `EntraID/Troubleshooting/WorkloadIdentity-A.md`
- Third-party CIEM tooling (Delinea PCCE or others) — not a Microsoft-native capability
- AWS/GCP IAM configuration mechanics themselves (creating/modifying roles, policies) — CIEM only *observes and recommends*, it does not configure the underlying cloud IAM

**Assumptions:**
- At least one Azure subscription with Defender for Cloud access
- For AWS/GCP coverage: those environments are already connected to Defender for Cloud via a multicloud connector (base onboarding — see `DefenderForCloud-A.md`) before attempting CIEM-specific enablement
- `Az.Security` and `Az.ResourceGraph` PowerShell modules, or Azure CLI (`az security`) equivalent, for the Azure-side read operations this file's script covers
- Security Admin role (not just Owner/Contributor) for enablement actions

---
## How It Works

<details><summary>Full architecture — plan layering, per-cloud onboarding, and the retirement transition</summary>

### CIEM Is a Sub-Feature, Not a Plan

Microsoft Defender for Cloud's CSPM capability ships in two tiers: **Foundational CSPM** (free, always-on baseline recommendations) and **Defender CSPM** (paid, opt-in — adds agentless scanning, attack path analysis, governance rules, regulatory compliance dashboards, and CIEM). Enabling the Defender CSPM plan does **not** automatically enable CIEM — CIEM is a further, independent toggle *within* the Defender CSPM plan's own Settings blade, per environment (per Azure subscription, per AWS account, per GCP project). This two-layer gating is the architectural root of the single most common CIEM support ticket: "we're on Defender CSPM but see no permission recommendations."

### Per-Cloud Onboarding Is Not Uniform

Once the CIEM toggle is turned on, each cloud provider requires its own onboarding completion step, and none of them are automatic:

- **Azure** — no additional step beyond the toggle itself; Defender for Cloud already has native read access to Entra ID identity data via the subscription's existing service connection.
- **AWS** — requires re-running the connector's **Configure access** wizard, which generates an *updated* CloudFormation template/StackSet granting the additional IAM read permissions CIEM needs. An AWS connector that was set up *before* CIEM was ever toggled on will not retroactively have these permissions — this is a distinct action from the original connector onboarding, easy to miss because the connector already "exists" and appears healthy for base CSPM purposes.
- **GCP** — analogous to AWS: requires re-running a Cloud Shell or Terraform deployment script granting the additional IAM read scope.

Both AWS and GCP also benefit from (and for full inactivity-detection accuracy, effectively require) ingestion of their respective audit log sources — **AWS CloudTrail** and **GCP Cloud Logging** — configured as a related but separate step in the same onboarding flow.

After a successful onboarding/toggle, Microsoft's own documentation states applicable recommendations "appear... within a few hours" — this is a stated expectation, not a fixed SLA, and should be quoted to clients as such rather than as a hard number.

### What CIEM Actually Analyzes

CIEM continuously analyzes identity configurations and *usage patterns* (not just static permission grants) across:
- **Azure** — Entra ID users, groups, and service principals
- **AWS** — IAM users, roles, and groups
- **GCP** — IAM users, groups, and service accounts

It covers both human and non-human (workload/service) identities, and surfaces two categories of finding per cloud, exposed as standard Defender for Cloud security recommendations (readable via the same `Get-AzSecurityAssessment` mechanism as any other CSPM recommendation):
1. **Overprovisioned identities** — identities holding more permission than their observed usage pattern justifies (least-privilege violations)
2. **Inactive identities** — identities with access that haven't exercised it, whose permissions should be revoked

### Beyond Recommendations: Cloud Security Explorer and Attack Path Analysis

CIEM's identity/entitlement data doesn't only surface as static recommendations — it feeds two interactive surfaces:
- **Cloud Security Explorer** lets an analyst query the identity-to-resource graph directly (e.g., "which identities can reach this specific storage account containing sensitive data, and how"), rather than waiting for a pre-defined recommendation to surface the risk.
- **Attack Path Analysis** correlates over-privileged/misconfigured identities with actual reachability to sensitive or internet-exposed resources, surfacing concrete lateral-movement chains an attacker could exploit starting from a compromised identity — this is where CIEM data becomes actionable prioritization rather than just an inventory list.

Neither Cloud Security Explorer's graph contents nor Attack Path Analysis results are exposed via a documented PowerShell cmdlet as of this writing — both are portal/API-graph-query surfaces. Verify current Graph/REST API coverage before promising script-based access to either.

### The CIEM Workbook

A customizable Azure Monitor Workbook (same underlying mechanism as other Defender for Cloud workbooks) providing a visual rollup of identity security posture, unhealthy CIEM recommendations, and related attack paths — useful for recurring client-facing reporting without re-querying the portal each time.

### Known Current Limitations (verify against live docs before quoting as permanent)

- **The Permissions Creep Index (PCI)** metric — a composite score the older tooling used to summarize over-provisioning risk — is being **deprecated** and will no longer appear in Defender for Cloud recommendations. Clients or internal staff referencing PCI from older documentation, dashboards, or training material should be redirected to the two current named recommendations plus Cloud Security Explorer/Attack Path Analysis for the equivalent insight.
- **AWS serverless and compute identities are no longer included in CIEM's inactivity logic** — this changes recommendation counts relative to a manual IAM Access Analyzer review or the old standalone tool's behavior, and is documented, expected behavior rather than a detection gap to chase.

### The Standalone-Product Retirement, Explained for Client Conversations

Microsoft Entra Permissions Management (standalone) is retired as of October 1, 2025. The underlying CIEM *capability* was not discontinued — it was consolidated into Defender for Cloud's Defender CSPM plan as a native sub-feature. For an organization that previously ran the standalone product, this is functionally a **new onboarding**, not an upgrade or migration:
- No configuration, custom rules, or historical entitlement data carries over automatically
- The role model is different — standalone Entra Permissions Management had its own distinct RBAC roles; CIEM-in-Defender-for-Cloud uses Defender for Cloud's own Security Admin gate
- The feature set is not 1:1 — some capabilities specific to the deep, multi-cloud-normalized CIEM workflows of the standalone product (which was originally a dedicated, more mature CIEM platform pre-acquisition) are represented differently or not at all inside the CSPM-embedded version; do not promise full feature parity without verifying the specific capability against current documentation

</details>

---
## Dependency Stack

```
Layer 0 — Cloud Environment Onboarding
    Azure subscription (native) | AWS account (multicloud connector) | GCP project (multicloud connector)
    │
    ▼
Layer 1 — Defender for Cloud Base CSPM
    Foundational CSPM (free, always-on) — does NOT include CIEM
    │
    ▼
Layer 2 — Defender CSPM Plan (paid, opt-in)
    Adds: agentless scanning | attack path analysis | governance rules |
          regulatory compliance | CIEM (still requires its OWN toggle below)
    │
    ▼
Layer 3 — CIEM Sub-Toggle (per environment: per subscription / per AWS account / per GCP project)
    "Permissions Management (CIEM)" — Environment settings > Defender CSPM > Settings
    │
    ▼
Layer 4 — Per-Cloud CIEM Onboarding Completion (NOT automatic once Layer 3 is toggled on)
    ├── Azure — no extra step; native Entra ID read access already present
    ├── AWS   — re-run "Configure access": updated CloudFormation stack/StackSet
    │            (+ recommended: CloudTrail log ingestion for inactivity accuracy)
    └── GCP   — re-run Cloud Shell/Terraform deployment script
                 (+ recommended: Cloud Logging ingestion for inactivity accuracy)
    │
    ▼
Layer 5 — Identity/Permission Telemetry Ingestion
    Usage-pattern analysis across human + non-human identities
    (results appear "within a few hours" per Microsoft's own stated, non-fixed expectation)
    │
    ▼
Layer 6 — Output Surfaces
    ├── CIEM Recommendations (2 per cloud: overprovisioned / inactive identities)
    │     → readable via Get-AzSecurityAssessment (same mechanism as any CSPM recommendation)
    ├── Cloud Security Explorer (identity-to-resource graph queries — portal/API only)
    ├── Attack Path Analysis (lateral-movement correlation — portal/API only)
    └── CIEM Workbook (Azure Monitor Workbook visual rollup)
    │
    ▼
Layer 7 — Access Control
    Security Admin role required for enablement (subscription scope for Azure;
    account/org level for AWS; project/org level for GCP — assigned in each
    cloud's own IAM, not inherited from Azure RBAC)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| No CIEM recommendations anywhere, any cloud | Defender CSPM plan not enabled at all (Foundational CSPM tier only) | `Get-AzSecurityPricing` — `CloudPosture` tier |
| Defender CSPM confirmed enabled, still zero CIEM recommendations | CIEM sub-toggle within the plan's own Settings is off, or was enabled less than a few hours ago | Portal: Environment settings > plan > Settings > Permissions Management (CIEM) |
| Azure recommendations present, AWS/GCP show nothing | Multicloud connector's CIEM-specific "Configure access" re-run was never completed for that cloud | Portal: re-check Configure access step; compare connector creation date vs. CIEM toggle-on date |
| Inactivity-based recommendations seem inaccurate or sparse for AWS/GCP | CloudTrail / Cloud Logging ingestion not enabled for that environment | Portal: connector settings — log ingestion toggle |
| Client asks where their old Entra Permissions Management dashboard/config went | Standalone product retired Oct 1 2025 — no automatic migration | Confirm which product the client means before troubleshooting further |
| Old documentation/dashboard references "Permissions Creep Index" not visible anywhere current | PCI metric deprecated from current recommendations | Redirect to the two current recommendation types + Cloud Security Explorer/Attack Path Analysis |
| AWS inactive-identity recommendation count looks lower than expected vs. manual review | Serverless/compute identities excluded from AWS inactivity logic (documented limitation) | Not a bug — confirm against current Microsoft Learn limitations list before escalating |
| CIEM toggle greyed out / enablement action fails | Account lacks Security Admin role at the correct scope | Azure: `Get-AzRoleAssignment` at subscription scope; AWS/GCP: check native IAM role assignment |
| Recommendation exists but engineer can't find the underlying identity/resource detail | Trying to use Get-AzSecurityAssessment alone — deeper investigation requires Cloud Security Explorer (portal/API, no cmdlet) | Escalate to portal-based Cloud Security Explorer query |
| Client wants to correlate a CIEM finding with actual breach risk, not just a static list | Attack Path Analysis is the correct tool — not exposed via recommendations list alone | Portal: Attack Path Analysis, filtered to the affected identity/resource |

---
## Validation Steps

1. **Confirm Defender CSPM plan tier for the affected environment.**
   ```powershell
   Get-AzSecurityPricing | Where-Object { $_.Name -eq "CloudPosture" } | Select-Object Name, PricingTier
   ```
   Good: `Standard` (the API's internal name for Defender CSPM). Bad: `Free` → CIEM is unavailable until the plan itself is upgraded.

2. **Confirm CIEM's own sub-toggle (portal-only check — no cmdlet surfaces this specific setting).**
   Defender for Cloud → Environment settings → target subscription/AWS account/GCP project → Defender CSPM plan → Settings → "Permissions Management (CIEM)".
   Good: On. Bad: Off, or recently toggled on (allow a few hours before escalating).

3. **For Azure, confirm recommendations are actually populating.**
   ```powershell
   Get-AzSecurityAssessment | Where-Object { $_.DisplayName -match "overprovisioned identities|inactive identities" } |
       Select-Object DisplayName, @{N="Status";E={$_.Status.Code}}, @{N="Severity";E={$_.Metadata.Severity}}
   ```

4. **For AWS/GCP, confirm the CIEM-specific "Configure access" step post-dates the CIEM toggle-on event, not just the original connector creation.**
   Portal: connector settings history/audit trail (if available) or direct conversation with the client's cloud admin about when the updated CloudFormation/Terraform deployment was last run.

5. **Confirm audit-log ingestion (AWS CloudTrail / GCP Cloud Logging) for inactivity-signal accuracy.**
   Portal: connector settings — log ingestion toggle state.

6. **Confirm Security Admin role for whoever is attempting to enable or modify CIEM settings.**
   ```powershell
   Get-AzRoleAssignment -SignInName <user-upn> -Scope "/subscriptions/<sub-id>" |
       Where-Object { $_.RoleDefinitionName -eq "Security Admin" }
   ```

7. **If the client references the old standalone product, explicitly confirm they understand this is a fresh onboarding.**
   No technical check — a scoping/expectations conversation. Document it in the ticket to prevent repeat confusion later.

---
## Troubleshooting Steps (by phase)

### Phase 1: Disambiguate the request
Determine whether the client means (a) the retired standalone Microsoft Entra Permissions Management product, (b) CIEM inside Defender for Cloud, or (c) a general Defender for Cloud CSPM question unrelated to identity/entitlements. Route (a) to Fix 4-equivalent messaging immediately; route (c) to `DefenderForCloud-A.md`.

### Phase 2: Confirm the plan/toggle layering
Check Defender CSPM plan tier first, then the CIEM sub-toggle specifically — never assume one implies the other.

### Phase 3: Validate per-cloud onboarding completion
For AWS/GCP specifically, confirm the CIEM-specific access-configuration step was completed *after* the toggle was turned on, not just that a connector exists.

### Phase 4: Interpret recommendation output correctly
Cross-reference any "missing" or "unexpectedly low" recommendation count against the documented current limitations (PCI deprecation, AWS serverless/compute exclusion) before treating it as a defect.

### Phase 5: Escalate to interactive tools for deep investigation
If the client needs to understand *why* an identity is flagged or *what* it can actually reach, route to Cloud Security Explorer and Attack Path Analysis — the static recommendation list alone is not sufficient for root-cause identity investigation.

### Phase 6: Escalate genuine anomalies
If plan tier, toggle state, per-cloud onboarding, and role assignment are all confirmed correct and CIEM data still doesn't populate within a reasonable window past the "few hours" guidance, open a Microsoft support case with the environment ID, connector ID, and toggle-enabled timestamp.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Greenfield CIEM enablement across Azure, AWS, and GCP</summary>

1. Confirm Defender CSPM plan is (or will be) enabled for every target environment — CIEM cannot be enabled independently of this plan.
2. For Azure: toggle "Permissions Management (CIEM)" on in the subscription's Defender CSPM plan Settings. No further action needed.
3. For AWS: ensure a multicloud connector already exists (base CSPM onboarding); toggle CIEM on; then run "Configure access" to deploy the *updated* CloudFormation stack/StackSet; enable CloudTrail ingestion.
4. For GCP: ensure a multicloud connector already exists; toggle CIEM on; then run the updated Cloud Shell/Terraform script; enable Cloud Logging ingestion.
5. Wait a few hours; confirm recommendations populate per Validation Steps 3-4.
6. Walk the client through Cloud Security Explorer and Attack Path Analysis as the deeper-investigation tools, not just the recommendation list — this is usually the differentiator clients actually cared about when they had the standalone product.
7. Set a recurring review cadence for CIEM recommendations, consistent with how the client already reviews other Defender for Cloud recommendations.

**Rollback:** Toggling CIEM off per environment stops new analysis; it does not remove the IAM read permissions already granted via CloudFormation/Terraform unless those are separately torn down.

</details>

<details><summary>Playbook 2 — Migrating client expectations from the retired standalone product</summary>

1. Confirm explicitly with the client that the standalone Microsoft Entra Permissions Management product is retired (Oct 1, 2025) and there is no in-place upgrade path.
2. Set expectations: this is a new onboarding into Defender for Cloud's CIEM sub-feature, not a migration — no configuration or historical entitlement data carries over.
3. Follow Playbook 1 for the actual technical enablement.
4. If the client specifically needs capabilities the standalone product had that aren't clearly represented in the CSPM-embedded version, verify against current Microsoft Learn documentation before promising parity — do not assume feature-for-feature equivalence.
5. If after verification a genuine capability gap exists and the client needs dedicated CIEM tooling, note Microsoft's own retirement guidance pointing to third-party options (e.g., Delinea PCCE) as a client-facing option — evaluating or deploying that tooling itself is outside this repo's scope.

**Rollback:** N/A — advisory/scoping playbook.

</details>

<details><summary>Playbook 3 — Investigating a specific overprivileged/inactive identity finding end-to-end</summary>

1. Start from the recommendation (`Get-AzSecurityAssessment` for Azure, or the equivalent AWS/GCP recommendation in-portal) to identify the specific flagged identity.
2. Open **Cloud Security Explorer** and query for that identity to see its full effective-permission graph — what it can actually reach, not just what the recommendation summary states.
3. Cross-reference with **Attack Path Analysis** filtered to that identity or its accessible resources to determine whether it sits on a genuine lateral-movement path (e.g., reaches an internet-exposed or sensitive-data resource).
4. Prioritize remediation based on Attack Path findings over the raw recommendation list alone — a flagged identity with no meaningful attack path is lower priority than one that completes a path to a critical asset.
5. Remediate in the underlying cloud's own IAM (this repo's CIEM coverage stops here — CIEM observes and recommends, it does not configure AWS/GCP/Entra ID permissions itself).
6. Re-check the recommendation after the next refresh cycle to confirm remediation was correctly detected.

**Rollback:** N/A — investigative playbook; any actual permission changes are made and rolled back in the underlying cloud IAM, not in Defender for Cloud.

</details>

---
## Evidence Pack

```
CIEM evidence collection is a mix of scriptable (Azure recommendation state) and portal-only
(CIEM toggle state, Cloud Security Explorer graph contents, Attack Path Analysis results) data.
For an escalation packet, capture:

1. Defender CSPM plan tier for the affected environment(s):
   Get-AzSecurityPricing | Where-Object { $_.Name -eq "CloudPosture" } | Select-Object Name, PricingTier

2. CIEM toggle state and last-changed timestamp (portal — Environment settings > Defender CSPM > Settings)

3. CIEM recommendation state (Azure):
   Get-AzSecurityAssessment | Where-Object { $_.DisplayName -match "overprovisioned identities|inactive identities" } |
       Select-Object DisplayName, @{N="Status";E={$_.Status.Code}}, @{N="Severity";E={$_.Metadata.Severity}} |
       Export-Csv .\CIEM-Recommendations-Evidence.csv -NoTypeInformation

4. Multicloud connector inventory and creation date (AWS/GCP):
   Search-AzGraph -Query "resources | where type =~ 'microsoft.security/securityconnectors' | project name, environmentName = tostring(properties.environmentName)"

5. For AWS/GCP: confirmation (screenshot or client statement) of when "Configure access" was last
   re-run relative to the CIEM toggle-on date, and whether CloudTrail/Cloud Logging ingestion is enabled

6. Security Admin role assignment for the account performing enablement actions:
   Get-AzRoleAssignment -SignInName <user-upn> | Where-Object { $_.RoleDefinitionName -eq "Security Admin" }

7. If relevant: confirmation the client understands the standalone-product retirement and this is a
   fresh onboarding (avoids repeat escalations rooted in a mismatched expectation, not a technical fault)
```

---
## Command Cheat Sheet

| Task | Command / Location |
|---|---|
| Check Defender CSPM plan tier | `Get-AzSecurityPricing \| Where-Object { $_.Name -eq "CloudPosture" }` |
| CIEM toggle state | Portal only: Environment settings > plan > Settings > Permissions Management (CIEM) |
| Azure CIEM recommendations | `Get-AzSecurityAssessment \| Where-Object { $_.DisplayName -match "overprovisioned identities\|inactive identities" }` |
| Multicloud connector inventory | `Search-AzGraph -Query "resources \| where type =~ 'microsoft.security/securityconnectors'"` |
| Security Admin role check | `Get-AzRoleAssignment -SignInName <upn> \| Where-Object { $_.RoleDefinitionName -eq "Security Admin" }` |
| Re-run AWS CIEM access config | Portal: Environment settings > AWS account > Defender CSPM > Settings > Configure access |
| Re-run GCP CIEM access config | Portal: Environment settings > GCP project > Defender CSPM > Settings > Configure access |
| Cloud Security Explorer | Portal only — Defender for Cloud > Cloud Security Explorer |
| Attack Path Analysis | Portal only — Defender for Cloud > Attack path analysis |
| CIEM Workbook | Portal only — Defender for Cloud > Workbooks > CIEM |
| Base CSPM fleet audit (plan tiers, Secure Score, connectors) | `Security/Defender/Scripts/Get-DefenderForCloudPostureAudit.ps1` |
| CIEM-specific fleet audit | `Security/Defender/Scripts/Get-CIEMRecommendationAudit.ps1` |

---
## 🎓 Learning Pointers

- **CIEM's plan/toggle layering (Defender CSPM plan → CIEM sub-toggle → per-cloud onboarding completion) is a three-deep gate, and each layer fails silently from the layer above's perspective.** Always validate all three independently rather than assuming plan enablement implies feature enablement. See [Cloud infrastructure entitlement management (CIEM) — Defender for Cloud](https://learn.microsoft.com/en-us/azure/defender-for-cloud/permissions-management).
- **Standalone Microsoft Entra Permissions Management is retired (Oct 1, 2025) with no automatic migration.** Every client conversation referencing the old product name should be treated as a fresh-onboarding scoping conversation first, technical troubleshooting second. See [Microsoft Entra Permissions Management overview](https://learn.microsoft.com/en-us/entra/permissions-management/overview) and the retirement guidance linked from it.
- **AWS and GCP CIEM onboarding is not automatic once the toggle is on** — both require re-running a cloud-specific access-configuration step (CloudFormation/Terraform) distinct from the base multicloud connector, which is easy to overlook on connectors created before CIEM existed on that account. See [Enable CIEM in Defender for Cloud](https://learn.microsoft.com/en-us/azure/defender-for-cloud/enable-permissions-management).
- **Cloud Security Explorer and Attack Path Analysis, not the static recommendation list, are where CIEM data becomes actionable.** A recommendation tells you an identity is over-privileged; Attack Path Analysis tells you whether that over-privilege actually matters given real reachability to sensitive/exposed resources. See [Cloud Security Explorer](https://learn.microsoft.com/en-us/azure/defender-for-cloud/how-to-manage-cloud-security-explorer) and [Attack Path Analysis](https://learn.microsoft.com/en-us/azure/defender-for-cloud/how-to-manage-attack-path).
- **The Permissions Creep Index is being deprecated and AWS serverless/compute identities are excluded from inactivity logic** — both are documented, current-state limitations. Verify the live limitations list before treating either as a bug, since CIEM's exact feature surface has changed meaningfully since the standalone-product era and continues to evolve. See [Enable CIEM — Limitations](https://learn.microsoft.com/en-us/azure/defender-for-cloud/enable-permissions-management#limitations).
