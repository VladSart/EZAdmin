# Intune STIG Audit Baseline — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [🎓 Learning Pointers](#-learning-pointers)

---
## Triage

**⚠️ GCC High only.** The Intune STIG audit baseline is available **exclusively in US Government Community Cloud High (GCC High) tenants** — it does not exist in commercial cloud, GCC, or DoD cloud environments. If a ticket references this feature and the tenant isn't confirmed GCC High, stop and re-scope: the tenant either doesn't have this capability, or the ticket is actually about a different Intune security baseline (`Security-Baselines-B.md`) or a manually-applied DISA STIG GPO/registry configuration.

The baseline is **audit-only** — it evaluates Windows 10/11 device configuration against DISA's Security Technical Implementation Guide (STIG) rules and reports Pass/Fail/Error/Conflict/Not applicable per rule per device. It does **not** configure or enforce anything. If a ticket assumes the STIG baseline itself fixes non-compliant settings, that's a misunderstanding of the feature, not a bug — remediation is a separate step via Settings Catalog, compliance policies, or the standard Windows MDM security baseline.

```powershell
# 1. Confirm this IS a GCC High tenant before troubleshooting further
Get-MgOrganization | Select-Object Id, DisplayName
# Cross-check against the GCC High service endpoint/tenant configuration —
# a commercial or GCC tenant will never show this baseline as an option at all

# 2. Confirm Intune Advanced Analytics licensing is present (required add-on, separate from Plan 1/2)
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match 'ADVANCED_ANALYTICS|INTUNE' } |
    Select-Object SkuPartNumber, ConsumedUnits, PrepaidUnits

# 3. Confirm the device's co-management workload ownership (if co-managed) —
#    Device configuration MUST be Pilot Intune or Intune, or the audit profile never applies
# (Check via ConfigMgr console or ' Get-CoManagementStatus.ps1' in this same folder)

# 4. Retrieve the STIG audit baseline template and confirm current version/rule count
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/templates?`$filter=templateFamily eq 'baseline'" |
    Select-Object -ExpandProperty value | Where-Object { $_.displayName -match 'STIG' } |
    Select-Object displayName, displayVersion, settingTemplateCount, id

# 5. Find the tenant's actual audit profile (PolicyId) built from that template
Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?`$filter=templateReference/templateId eq '<templateId>'" |
    Select-Object -ExpandProperty value | Select-Object id, name
```

| If... | Then... |
|---|---|
| Tenant is confirmed commercial cloud or GCC (not GCC High) | The STIG audit baseline is not available at all, full stop — no license or configuration change can enable it. Redirect to `Security-Baselines-B.md` (Windows MDM security baseline) or manual Settings Catalog/GPO-based STIG remediation instead. |
| STIG baseline doesn't appear in Endpoint Security > Security baselines list, in a confirmed GCC High tenant | Check Intune Advanced Analytics licensing first (a separate add-on, not covered by Plan 1/2 alone) — this is the most common "eligible tenant, missing feature" cause. See Fix 1. |
| Admin can't create/edit the audit profile despite being an Intune admin | RBAC gap — needs an Intune role with Organization:Read plus Security baselines:Assign/Create/Delete/Read/Update (the built-in Endpoint Security Manager role has these) plus scope tag permissions for the target device groups. See Fix 2. |
| Audit profile assigned but no data appears for 24+ hours on newly targeted devices | Expected up to 24h for initial results; if longer, check co-management workload ownership and basic device check-in health before assuming the baseline itself is broken. See Fix 3. |
| A co-managed device never reports STIG audit data at all | Device configuration workload isn't set to Pilot Intune/Intune — the STIG baseline rides the same device-configuration delivery pipeline as ordinary Settings Catalog profiles and needs Intune to own that workload. See Fix 3. |
| Trying to select a subset of STIG rules, or create a custom/older-version profile | Not supported — the baseline audits ALL rules in the single current benchmark version as one profile; you cannot cherry-pick CAT levels or individual rules, and only the latest published version can be used to create *new* profiles (older-version profiles you already created keep running). See Fix 4. |
| Trying to create/edit a STIG audit profile via Graph API directly | Not supported — profile creation is UX-only through the Intune admin center in the current release; there is no documented POST endpoint for authoring a new profile. Read/report APIs are fully supported via `/beta`. |
| Audit report shows Fail for a rule that's on the manual-verification list (e.g., firewall installed, admin rights list) | Expected — ~20 STIG rules require human/administrative judgment and are excluded from automated CSP-based evaluation; treat these as a separate manual compliance process, not a bug in the audit. See Fix 5. |
| Report data looks stale / doesn't reflect a recent remediation | Data isn't real-time — up to 1-2 device check-in cycles of lag. Use **Generate again** on the report, or force a device sync for the fastest refresh of already-cached local results. |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Tenant is US Government Community Cloud High (GCC High) —
 NOT available in commercial, GCC, or DoD cloud, no exception]
        │
        ▼
[Intune Advanced Analytics add-on licensed
 (in addition to Microsoft Intune Plan 1 or Plan 2)]
        │
        ▼
[Device is Windows 10 or Windows 11, enrolled in Intune;
 for co-managed devices, Device configuration workload = Pilot Intune or Intune]
        │
        ▼
[Admin has RBAC: Organization:Read + Security baselines:Assign/Create/Delete/Read/Update
 (Endpoint Security Manager built-in role, or equivalent custom role)
 + scope tag permissions for the target device groups]
        │
        ▼
[Admin creates a STIG Audit profile in the Intune admin center — UX ONLY,
 no API-based profile creation in the current release —
 all rules in the current benchmark version audited as ONE profile, no subsetting]
        │
        ▼
[Profile assigned to device groups]
        │
        ▼
[Devices check in → each rule evaluated locally against DISA SCAP benchmark values →
 result reported: Pass / Fail / Error / Conflict / Not applicable / Unknown]
        │   (~20 rules excluded — require manual verification, not CSP-evaluable)
        ▼
[Audit report populates — up to 24h initial delay, 1-2 check-in cycles of ongoing lag —
 viewable in admin center, exportable via CSV or Graph /beta bulk export/per-setting reports]
        │
        ▼
[Findings used to drive SEPARATE remediation: Settings Catalog profiles,
 Windows MDM security baseline, compliance policies, or Group Policy (co-managed) —
 the STIG baseline itself never pushes or enforces a setting]
```

If the tenant isn't GCC High, nothing below the first line is reachable — no license, role assignment, or configuration will surface this feature.

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm GCC High**
This is the first and most important check. If uncertain, confirm via the tenant's service endpoint/environment designation rather than assuming based on "government contractor" status alone — DoD and GCC (non-High) tenants exist and do **not** get this feature either.

**Step 2 — Confirm Intune Advanced Analytics licensing**
```powershell
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match 'ADVANCED_ANALYTICS' }
```
Absence of this add-on is the most common reason a confirmed-eligible GCC High tenant still doesn't see the STIG baseline option in Endpoint Security > Security baselines.

**Step 3 — Confirm RBAC**
Intune admin center > **Tenant administration > Roles** — confirm the admin's assigned role includes Organization:Read and Security baselines Assign/Create/Delete/Read/Update, or is the built-in **Endpoint Security Manager** role. Also confirm scope tag coverage for the device groups in question.

**Step 4 — Confirm profile assignment and co-management workload**
Intune admin center > **Endpoint security > Security baselines > Microsoft Windows 11 STIG SCAP Benchmark** > the profile > **Assignments**. For co-managed devices, separately confirm (ConfigMgr console or ` Get-CoManagementStatus.ps1`) that the Device configuration workload slider is Pilot Intune or Intune — this baseline is delivered through Intune's device-configuration pipeline and silently won't apply if ConfigMgr still owns that workload.

**Step 5 — Confirm data population timing**
Newly targeted devices can take up to 24 hours for first results. For established profiles, ongoing data can lag 1-2 device check-in cycles behind reality — use **Generate again** on the Audit report, and/or force a device sync, before concluding data is stuck.

**Step 6 — For a specific Fail, confirm it isn't on the manual-verification exclusion list**
Cross-check the STIG Rule ID / Group ID shown in the report against the ~20 documented manually-verified rules (firewall presence, admin-rights-list correctness, UEFI mode, etc. — see Learning Pointers). These are excluded from the automated audit report by design.

---
## Common Fix Paths

<details><summary>Fix 1 — STIG baseline option missing from Security baselines list (confirmed GCC High tenant)</summary>

1. Confirm Intune Advanced Analytics is licensed and assigned at the tenant level — this is a separate subscription from Microsoft Intune Plan 1/Plan 2 and is easy to miss during initial GCC High tenant setup.
2. Confirm the admin account itself has a role with visibility into Security baselines (RBAC gap can also hide the option, not just missing licensing — see Fix 2).
3. If licensing and RBAC both check out and the option is still missing, confirm the tenant's GCC High designation directly with Microsoft — a small number of GCC High tenants may have staged feature rollout timing differences.

**Rollback:** N/A — licensing/eligibility check only.

</details>

<details><summary>Fix 2 — Admin can't create or manage STIG audit profiles (RBAC)</summary>

1. Confirm the admin's Intune role includes **Organization: Read** and **Security baselines: Assign, Create, Delete, Read, Update** — the built-in **Endpoint Security Manager** role has all of these by default.
2. If using a custom role, add the missing permissions explicitly rather than assuming a broadly-named role ("Endpoint Administrator," etc.) covers baseline management.
3. Confirm scope tag permissions cover the specific device groups the admin needs to audit — a role with the right baseline permissions but the wrong scope tag will still show an incomplete or empty device list.

**Rollback:** N/A — RBAC verification/grant, not a destructive change.

</details>

<details><summary>Fix 3 — No audit data appearing for targeted devices</summary>

1. Confirm it's been at least 24 hours since the device was first targeted by the profile — this is the documented initial-population window, not a fault.
2. For co-managed devices specifically, confirm the **Device configuration** workload slider is set to **Pilot Intune** or **Intune** in ConfigMgr — if ConfigMgr still owns that workload, the STIG audit policy (delivered through Intune's device-configuration pipeline) will never reach the device, with no error surfaced anywhere.
3. Confirm basic device health: recent check-in timestamp, no broader MDM enrollment or policy-delivery issues affecting the same device (cross-reference `Enrollment-B.md`/`Policy-Conflict-B.md` if this device is failing to receive *any* policy, not just this one).
4. Use **Generate again** on the Audit report to force a refresh once data is confirmed to actually exist.

**Rollback:** N/A — diagnostic/timing issue, no configuration change required unless the co-management workload itself needs to be moved (a separate, deliberate co-management decision, not a STIG-specific fix).

</details>

<details><summary>Fix 4 — Trying to scope/customize the baseline (not supported)</summary>

1. Confirm the ask: selecting a subset of rules, targeting only CAT I findings, or using an older STIG version for a new profile. None of these are supported — the baseline audits every rule in the single current benchmark version as one non-customizable profile.
2. If a genuinely older-version profile is required for continuity with an existing DoD reporting cycle, confirm it was created before the newer version became the only option for *new* profile creation — existing older-version profiles continue to run, but a brand-new one cannot be created against a superseded version.
3. If rule-level customization is a hard requirement, this feature is not the right tool — the audit baseline exists specifically to mirror DISA's published, unmodified SCAP benchmark for compliance-reporting purposes. Redirect to Settings Catalog-based enforcement of only the desired subset instead, understanding that approach won't produce STIG-formatted XCCDF-mapped audit reports.

**Rollback:** N/A — feature-limitation clarification, not a configuration change.

</details>

<details><summary>Fix 5 — A specific rule always shows Fail/isn't in the report despite remediation</summary>

1. Check the STIG Rule ID (e.g., `V-253281`, `V-253269`) against the documented manual-verification exclusion list — roughly 20 rules require physical inspection or administrative judgment (host-based firewall presence, correct admin-rights membership, UEFI boot mode, Bluetooth policy, DoD time-source sync, and others) and are **excluded from the automated report entirely**, not merely reported as Fail.
2. If the rule genuinely appears in the report as Fail (not simply missing), confirm the actual remediation was applied via Settings Catalog/security baseline/compliance policy/Group Policy — the STIG audit report only reflects real device state, it does not push a fix.
3. Allow 1-2 check-in cycles after remediation before re-checking; use **Generate again** and/or force a device sync.
4. If a rule shows Fail with no remediation path obvious from Settings Catalog, cross-reference the DISA STIG library rule text directly (`public.cyber.mil/stigs`) for the exact expected registry/policy value.

**Rollback:** N/A — verification workflow, no configuration change made by this fix itself.

</details>

---
## Escalation Evidence

```
Ticket: Intune STIG Audit Baseline issue
─────────────────────────────────────────
Tenant ID:                              <____________________>
Confirmed GCC High (Y/N):               <____________________>
Intune Advanced Analytics licensed (Y/N): <__________________>
Admin RBAC role:                        <____________________>
STIG baseline version in use / rule count: <_________________>
PolicyId (audit profile GUID):          <____________________>
Device name / co-management workload state (if applicable): <_______>
Symptom (baseline missing / no data / RBAC denied / specific rule Fail / can't customize): <_______>
Affected STIG Rule ID (if applicable):  <____________________>
Time since device first targeted:       <____________________>
Time issue first observed:              <____________________>
```

---
## 🎓 Learning Pointers

- **This feature does not exist outside GCC High — confirm the cloud environment before anything else.** Not commercial, not GCC, not DoD. A ticket describing "our STIG baseline" from a non-GCC-High tenant is describing something else entirely — a manual GPO/Settings Catalog STIG implementation, or confusion with the ordinary Windows MDM security baseline. [Use STIG audit baselines to assess Windows device compliance in Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-security/security-baselines/stig-audit-baseline)

- **Audit-only means audit-only — there is no enforcement path inside this feature.** Every Fail in the report is a finding to remediate through a *different* Intune mechanism (Settings Catalog, the Windows MDM security baseline, compliance policies, or Group Policy for co-managed devices). Don't let a ticket's framing ("the STIG baseline isn't fixing X") send you looking for a bug that doesn't exist. [Use STIG audit baselines to assess Windows device compliance in Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-security/security-baselines/stig-audit-baseline)

- **Co-management workload ownership is a silent, total blocker.** The STIG audit policy rides Intune's device-configuration delivery pipeline exactly like a Settings Catalog profile — if ConfigMgr still owns the Device configuration workload for a co-managed device, the policy simply never lands, with nothing in the STIG baseline UI itself hinting at why. [Use STIG audit baselines to assess Windows device compliance in Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-security/security-baselines/stig-audit-baseline)

- **Roughly 20 STIG rules are deliberately excluded from the automated report** because they require physical inspection or administrative judgment the device's own configuration service providers can't detect (firewall presence, correct admin-rights membership, UEFI mode, and others). Don't chase these as "missing data" — they're an intentionally separate, manual compliance process. [Use STIG audit baselines to assess Windows device compliance in Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-security/security-baselines/stig-audit-baseline)

- **Bulk export via the Graph exportJobs API is dramatically cheaper than the per-setting cached-report pattern at this baseline's scale.** For a 197-rule benchmark, the per-setting create/poll/retrieve pattern costs at least 591 API calls; the `exportJobs`-based bulk export does the same job in two to three calls total. Default to bulk export for any full-tenant STIG reporting automation. [Use STIG audit baselines to assess Windows device compliance in Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-security/security-baselines/stig-audit-baseline)
