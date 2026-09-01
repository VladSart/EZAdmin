# Intune STIG Audit Baseline — Reference Runbook (Mode A: Deep Dive)
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

Covers the **Intune STIG audit baseline** — a **US Government Community Cloud High (GCC High)-only** security baseline type that assesses Windows 10/11 device configuration against DISA's (Defense Information Systems Agency) published Security Technical Implementation Guides (STIGs), and reports the result per rule per device without configuring or enforcing anything. It exists specifically for organizations that must demonstrate STIG compliance as a Department of Defense (DoD) contractual or regulatory requirement.

**Hard scope note, stated up front because it governs every other fact in this file:** this feature is not available in commercial cloud, standard GCC, or DoD cloud environments — only GCC High. An MSP whose clients are entirely commercial-cloud tenants will very rarely, if ever, encounter this feature in practice; when this topic is relevant, confirm the tenant's cloud designation before investing further troubleshooting time.

**Does not cover:**
- The ordinary Windows MDM security baseline (configures and enforces settings, available in all clouds) — see `Security-Baselines-B.md`/`-A.md`. That baseline type and this one share the Endpoint Security > Security baselines UI surface but have fundamentally different behavior (push-and-enforce vs. audit-only).
- Manual, non-Intune-native STIG implementation via raw GPO or hand-authored Settings Catalog profiles referencing DISA STIG values directly — a valid approach for non-GCC-High tenants that still have a DoD STIG requirement, but architecturally unrelated to this specific Intune feature.
- Co-management workload arbitration mechanics in general — see `CoManagement-B.md`/`-A.md`. This file only covers the specific dependency that the Device configuration workload must be Intune-owned for the STIG audit policy to be delivered at all.
- Individual STIG rule remediation guidance (the actual registry/policy values DISA specifies per rule) — that content lives in DISA's own SCAP benchmark files and STIG library, referenced here but not reproduced.

---
## How It Works

<details><summary>Full architecture</summary>

### What the STIG audit baseline is, architecturally

Unlike every other Intune security baseline type, which *push and enforce* configuration, the STIG audit baseline is deliberately **read-only**. It evaluates each targeted device's current settings against the rule definitions in a DISA-published SCAP (Security Content Automation Protocol) benchmark, and reports a per-rule, per-device Pass/Fail/Error/Conflict/Not-applicable/Unknown result — never writing a configuration value to the device. This design choice matters for two reasons: it means the STIG baseline can be safely deployed alongside every other Intune policy type without conflict risk (since it never contends for ownership of a setting the way two enforcing baselines/profiles can), and it means every "why isn't this baseline fixing my Fail findings" ticket is, without exception, a misunderstanding of the feature rather than a defect.

### The single supported benchmark, as one non-customizable profile

At the time of this writing, exactly one STIG audit baseline is available: the **Microsoft Windows 11 STIG SCAP Benchmark, Version 2, Release 7** (benchmark date January 5, 2026), covering **197 discrete rules**. It can be assigned to both Windows 10 and Windows 11 devices — rules that don't apply to a given device's OS version report as **Not applicable** rather than failing outright. CAT I (high), CAT II (medium), and CAT III (low) severity rules are all bundled into this single benchmark; there is no way to create a profile scoped to only one severity tier, and no way to select or deselect individual rules — the profile audits every rule in the benchmark, full stop. DISA updates STIGs on roughly a quarterly cadence; when Intune surfaces a newer benchmark version, admins can create a new profile against it or update an existing one, but **only the latest published version can be used to create new profiles** — a profile built against an older version, once created, continues running, but you cannot go back and create a fresh profile against a superseded version.

### RBAC and licensing

Beyond standard Intune enrollment and GCC High tenancy, two gates are required:
- **Intune Advanced Analytics** — a licensed add-on, in addition to (not included in) Microsoft Intune Plan 1 or Plan 2. This is the single most common "eligible tenant, feature not visible" cause.
- **RBAC**: Organization:Read plus Security baselines:Assign/Create/Delete/Read/Update — bundled into the built-in **Endpoint Security Manager** role, or addable to a custom role — plus scope tag coverage for the target device population.

### Delivery pipeline and the co-management trap

The audit profile is delivered through **Intune's standard device-configuration pipeline** — the same channel an ordinary Settings Catalog profile uses. For a co-managed device, this means the **Device configuration** workload slider must be set to **Pilot Intune** or **Intune**; if ConfigMgr still owns that workload, the STIG audit policy is silently never delivered, with no error surfaced in the STIG baseline's own UI. This is the single highest-value "why is there no data for this device" diagnostic and is easy to miss because it looks identical to a data-population-timing issue at first glance.

### Result semantics and XCCDF mapping

Each device/rule combination resolves to one of six statuses — **Unknown** (not yet reported), **Not applicable** (rule doesn't apply to this device's OS), **Pass**, **Fail**, **Error** (evaluation itself failed), or **Conflict** (a conflicting policy was detected for that setting). Each status maps to a corresponding **NIST XCCDF** (Extensible Configuration Checklist Description Format) result category, which is the formal reporting vocabulary DISA and DoD auditors expect — this mapping is what makes the report directly usable for formal compliance submissions rather than requiring a manual translation step.

### The manual-verification exclusion set

Roughly 20 STIG rules cannot be automatically evaluated because they require physical inspection, administrative judgment, or conditions the device's configuration service providers (CSPs) simply cannot observe — examples include confirming UEFI (not Legacy BIOS) firmware mode, verifying that only appropriate accounts hold local Administrator rights, confirming a host-based firewall is installed and enabled, and confirming SNMP is not installed. These rules are **excluded from the audit report entirely**, not reported as a permanent Fail or Unknown — organizations must establish and document a separate manual process to assess and record compliance for this subset. Treating a "missing" rule as a bug rather than an intentional exclusion is a common early misunderstanding.

### Data freshness

Newly targeted devices can take up to **24 hours** to show initial results. Beyond that, the report can lag the true device state by **one to two check-in cycles** — devices evaluate rules locally on their own schedule and only report results at their next Intune check-in. **Generate again** in the Audit report view forces a refresh of already-cached data; for the most current *local* evaluation without waiting for the next scheduled check-in, a device sync from the admin center retrieves the most recent cached results without a full new evaluation cycle.

### Graph API access — two very different cost profiles

All Graph calls for STIG data use the **`/beta`** endpoint exclusively (`/v1.0` doesn't support these calls). Two access patterns exist with materially different costs at this baseline's scale:

- **Per-setting cached report pattern** (`cachedReportConfigurations` create → poll → `getCachedReport` retrieve): a three-call round trip **per SettingId**. For a 197-rule baseline, a full-baseline pull this way costs **at least 591 API calls**.
- **Bulk export** (`reports/exportJobs`, `reportName: "IndustryBaselinePerSettingDeviceAuditList"`): a create → poll → download pattern that returns the **entire tenant's** dataset as a ZIP/CSV from blob storage in **two to three calls total**, with no per-setting iteration and no pagination limit — purpose-built for full-tenant or cross-tenant STIG reporting automation (e.g., for DISA's Continuous Monitoring and Risk Scoring / CMRS program).

Retrieving a **PolicyId** (the tenant-specific GUID of the audit profile itself, required for both patterns) requires either reading it from the admin center URL, or first retrieving the template `id` via `GET /beta/deviceManagement/templates?$filter=templateFamily eq 'baseline'`, then listing policies built from that template with `GET /beta/deviceManagement/configurationPolicies?$filter=templateReference/templateId eq '{templateId}'`. **SettingIds are globally consistent across tenants** for a given STIG template version (useful for cross-tenant correlation); **PolicyIds are tenant-specific** and must be rediscovered per tenant, and change whenever a tenant upgrades to a newer STIG version.

### Known, permanent limitations (not bugs)

- Audit-only — no enforcement, ever, by design.
- No custom baselines or rule subsetting — the full benchmark, as published, or nothing.
- The Audit report shows pass/fail per rule, but **not the actual on-device configuration value** — you know a rule failed, not exactly what value caused it, without separate on-device investigation.
- Only the latest benchmark version can be used to create *new* profiles; older-version profiles already created keep running.
- GCC High only — no commercial, GCC, or DoD cloud availability.
- **UX-only profile creation** — there is no documented API for authoring a new STIG audit profile; the read/report APIs are fully supported, but profile creation itself is admin-center-only.
- Data latency as described above.

</details>

---
## Dependency Stack

```
[Tenant cloud environment: US Government Community Cloud High (GCC High) —
 hard requirement, zero exceptions, not present in commercial/GCC/DoD cloud]
        │
        ▼
[Intune Advanced Analytics add-on licensed
 (separate from, and in addition to, Microsoft Intune Plan 1/Plan 2)]
        │
        ▼
[Device: Windows 10 or Windows 11, enrolled in Intune]
        │      (for co-managed devices: Device configuration workload
        │       MUST be Pilot Intune or Intune — STIG audit rides the
        │       same delivery pipeline as ordinary device-config policy)
        ▼
[Admin RBAC: Organization:Read + Security baselines:Assign/Create/Delete/Read/Update
 (Endpoint Security Manager built-in role, or equivalent custom role)
 + scope tag coverage for target device groups]
        │
        ▼
[STIG Audit profile created in Intune admin center — UX ONLY, no API authoring —
 ONE profile = ALL rules in the current benchmark version, no subsetting,
 no CAT-level filtering, only latest version usable for NEW profile creation]
        │
        ▼
[Profile assigned to device group(s)]
        │
        ▼
[Device evaluates locally against DISA SCAP benchmark rule definitions
 (~20 rules excluded — require manual/physical verification, not CSP-observable)]
        │
        ▼
[Result reported at next check-in: Pass / Fail / Error / Conflict / Not applicable / Unknown
 → mapped to NIST XCCDF result categories for formal DoD/DISA reporting]
        │
        ▼
[Audit report populated — up to 24h initial delay, 1-2 check-in cycles ongoing lag;
 viewable in admin center, exportable via CSV, per-setting Graph reports (/beta,
 591+ calls for full baseline), or bulk exportJobs (/beta, 2-3 calls, full tenant)]
        │
        ▼
[Findings drive SEPARATE remediation via Settings Catalog / Windows MDM security
 baseline / compliance policies / Group Policy (co-managed) — this baseline never
 writes a configuration value itself]
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| STIG baseline type doesn't appear anywhere in Endpoint Security > Security baselines | Tenant is not GCC High, or Intune Advanced Analytics add-on isn't licensed | Confirm cloud environment first; then confirm Advanced Analytics licensing |
| Admin can see other baseline types but not create/manage STIG profiles | RBAC gap — missing Security baselines permission set or Organization:Read | Confirm role assignment includes both, or use Endpoint Security Manager |
| Profile assigned, zero data after 24+ hours | Co-managed device with ConfigMgr still owning Device configuration workload | Confirm workload slider = Pilot Intune/Intune |
| Data present but appears stale relative to a recent remediation | Normal 1-2 check-in cycle reporting lag | Use "Generate again" and/or force device sync |
| A specific STIG rule never appears in the report for any device | Rule is one of ~20 requiring manual verification — excluded by design | Cross-check STIG Rule ID against the manual-verification list |
| "Why doesn't the baseline fix this Fail" | Audit-only feature — there is no enforcement anywhere in this feature | Remediate separately via Settings Catalog/security baseline/compliance policy/GPO |
| Can't select individual rules or a CAT-severity subset when creating a profile | Not supported — one profile always audits the entire benchmark | No workaround; use Settings Catalog directly for a custom subset (loses XCCDF reporting) |
| Trying to create a profile against an older STIG version | Only the latest published version is usable for *new* profile creation | Existing older-version profiles keep running; a new one must use current version |
| Automation trying to POST/PUT a new STIG profile via Graph fails | Not supported — profile creation is UX-only in the current release | Author in the admin center; use Graph only for reads/reports |
| Full-baseline Graph export is slow / hitting throttling | Using the per-setting cached-report pattern instead of bulk export | Switch to `reports/exportJobs` with `IndustryBaselinePerSettingDeviceAuditList` |
| PolicyId lookup fails after a STIG version upgrade | PolicyIds are tenant- and version-specific and change on upgrade | Re-discover via the templates → configurationPolicies lookup chain each time |

---
## Validation Steps

**Step 1 — Confirm cloud environment**
Confirm GCC High designation directly (tenant configuration/service endpoint), not inferred from "government contractor" status — GCC and DoD cloud tenants exist and do not have this feature.

**Step 2 — Confirm licensing**
```powershell
Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match 'ADVANCED_ANALYTICS' }
```

**Step 3 — Confirm RBAC**
Intune admin center > **Tenant administration > Roles** — confirm Organization:Read + Security baselines:Assign/Create/Delete/Read/Update, and scope tag coverage.

**Step 4 — Confirm profile and template metadata**
```
GET /beta/deviceManagement/templates?$filter=templateFamily eq 'baseline'
```
Expected fields: `displayName` ("Microsoft Windows 11 Security Technical Implementation Guide"), `displayVersion` (e.g., "Version 2, Release 7 Benchmark Date: 05 Jan 2026"), `settingTemplateCount` (e.g., 197), `baseId` (globally consistent), `id` (use as `templateId` next).

**Step 5 — Confirm the tenant's actual audit profile (PolicyId)**
```
GET /beta/deviceManagement/configurationPolicies?$filter=templateReference/templateId eq '{templateId}'
```
The returned `id` is the **PolicyId** used in all subsequent report calls. Confirm this matches what's visible in the admin center for the profile in question.

**Step 6 — For co-managed devices, confirm workload ownership**
ConfigMgr console (or `Get-CoManagementStatus.ps1`) — Device configuration workload = Pilot Intune or Intune.

**Step 7 — Confirm report data freshness expectations**
Newly targeted device: allow up to 24h. Established profile: allow 1-2 check-in cycles after a remediation before treating stale-looking data as a fault.

**Step 8 — For a missing rule, cross-check the manual-verification exclusion list**
Compare the STIG Rule ID/Group ID against the ~20 documented exclusions before assuming a reporting gap.

---
## Troubleshooting Steps (by phase)

### Phase 1: Eligibility
1. Confirm GCC High, Advanced Analytics licensing, and RBAC (Validation Steps 1-3) before investigating any profile-level symptom.

### Phase 2: Profile and delivery
1. Confirm profile/template metadata and PolicyId (Validation Steps 4-5).
2. Confirm assignment scope in the admin center.
3. For co-managed devices specifically, confirm workload ownership (Validation Step 6) — this is the single highest-value check for a "no data" symptom on a co-managed fleet.

### Phase 3: Data and reporting
1. Apply the freshness expectations from Validation Step 7 before escalating a "stale data" complaint.
2. For automation/reporting pipelines, confirm the correct Graph pattern is in use — bulk `exportJobs` for full-tenant/full-baseline pulls, per-setting cached reports only for genuinely targeted single-setting lookups.
3. Re-discover PolicyId after any STIG benchmark version upgrade — do not assume a cached PolicyId from a prior version remains valid.

### Phase 4: Rule-level findings
1. For a Fail, confirm the finding is real (not a manual-verification-excluded rule that shouldn't appear at all) and drive remediation through a separate Intune mechanism.
2. For a rule that "never shows up," check the exclusion list before assuming a data gap.
3. Allow the documented lag window after remediation before re-verifying.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Stand up STIG audit reporting for a new GCC High tenant</summary>

1. Confirm GCC High designation and Intune Advanced Analytics licensing.
2. Assign or confirm an admin role with the required Security baselines/Organization RBAC and appropriate scope tags.
3. In the Intune admin center, create a new STIG Audit profile against the current benchmark version (Endpoint Security > Security baselines > Microsoft Windows 11 STIG SCAP Benchmark > Create profile) — no configuration selection needed, the profile audits the full benchmark by definition.
4. Assign to the target device group(s); for any co-managed devices in scope, confirm the Device configuration workload is Intune-owned before assignment, not after.
5. Allow up to 24h for initial data, then review the Audit report and Device assignment status views.
6. Establish the separate manual-verification process for the ~20 excluded rules alongside the automated report, so the organization's overall compliance picture isn't missing that slice.
7. Stand up bulk-export automation (`reports/exportJobs`, `IndustryBaselinePerSettingDeviceAuditList`) if recurring formal DISA/DoD reporting is required, rather than building against the far more expensive per-setting pattern.

**Rollback:** Remove the profile's assignment to stop future evaluation; the audit-only nature means there is no device configuration to revert, since nothing was ever pushed.

</details>

<details><summary>Playbook 2 — Migrate STIG audit reporting after a benchmark version upgrade</summary>

1. Confirm the newer benchmark version is available via `GET /beta/deviceManagement/templates?$filter=templateFamily eq 'baseline'` — compare `displayVersion`/`settingTemplateCount` against the currently-used profile's.
2. Create a **new** STIG Audit profile against the new version (required — you cannot upgrade an existing profile in place to a new benchmark version; confirm this against the current admin-center experience since this specific mechanic is the part most likely to evolve release-over-release).
3. Re-discover the new profile's PolicyId (Validation Step 5) — do not assume the prior PolicyId or any cached automation configuration carries forward.
4. Assign the new profile to the same device groups; consider a brief overlap window with the prior profile still active before removing its assignment, to avoid a reporting gap.
5. Update any Graph-based automation (bulk export or per-setting) to reference the new PolicyId.
6. Remove the prior version's profile assignment once the new version's data is confirmed populating correctly.

**Rollback:** Re-assign the prior version's profile if the new version's data doesn't populate as expected; both profile objects can coexist (assigned or not) without conflict since the feature is audit-only.

</details>

<details><summary>Playbook 3 — Recover a co-managed fleet with silently missing STIG data</summary>

1. Confirm the STIG audit profile is correctly assigned to the affected device group (rule out an assignment-scope gap first).
2. For each affected device, confirm Device configuration workload ownership in ConfigMgr — this is the most likely root cause for a co-managed fleet showing systemically missing data while other (Intune-only) devices report fine.
3. If ConfigMgr currently owns Device configuration, this is a co-management workload decision with implications far beyond STIG reporting (see `CoManagement-A.md` before moving it) — don't move the workload solely to fix STIG reporting without considering the broader impact.
4. Once workload ownership is confirmed Intune-side, allow the standard 24h/1-2-check-in-cycle windows before re-verifying data population.

**Rollback:** N/A — this playbook is a diagnosis-and-workload-ownership-decision flow; any workload change itself follows standard co-management change-control, not a STIG-specific rollback.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Intune STIG audit baseline evidence for escalation
.NOTES     Requires Connect-MgGraph with DeviceManagementConfiguration.Read.All
           and Organization.Read.All scopes, against a GCC High tenant.
           Output saved to current directory.
#>

$output = [System.Collections.Generic.List[string]]::new()
$ts     = Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC" -AsUTC
$out    = ".\STIGAuditEvidence_$(Get-Date -Format yyyyMMdd_HHmmss).txt"

function Add-Section {
    param([string]$Title, [scriptblock]$Body)
    $output.Add("=" * 60)
    $output.Add("  $Title")
    $output.Add("=" * 60)
    try { $output.Add((&$Body | Out-String).Trim()) }
    catch { $output.Add("ERROR: $($_.Exception.Message)") }
    $output.Add("")
}

Add-Section "Collection metadata" {
    "Collected : $ts"
}

Add-Section "Tenant organization info" {
    Get-MgOrganization | Select-Object Id, DisplayName | Format-List
}

Add-Section "Intune Advanced Analytics licensing signal" {
    Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -match 'ADVANCED_ANALYTICS|INTUNE' } |
        Select-Object SkuPartNumber, ConsumedUnits | Format-Table -AutoSize | Out-String
}

Add-Section "STIG baseline template metadata" {
    try {
        $templates = Invoke-MgGraphRequest -Method GET `
            -Uri "https://graph.microsoft.com/beta/deviceManagement/templates?`$filter=templateFamily eq 'baseline'"
        $templates.value | Where-Object { $_.displayName -match 'STIG' } |
            Select-Object displayName, displayVersion, settingTemplateCount, id | Format-List | Out-String
    } catch { "ERROR retrieving template metadata: $($_.Exception.Message)" }
}

$output | Set-Content -Path $out -Encoding UTF8
Write-Host "Evidence saved to: $out" -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Confirm tenant org info | `Get-MgOrganization \| Select Id,DisplayName` |
| Check Advanced Analytics licensing signal | `Get-MgSubscribedSku \| Where SkuPartNumber -match 'ADVANCED_ANALYTICS'` |
| Retrieve STIG template metadata | `GET /beta/deviceManagement/templates?$filter=templateFamily eq 'baseline'` |
| Retrieve tenant's audit profile (PolicyId) | `GET /beta/deviceManagement/configurationPolicies?$filter=templateReference/templateId eq '{templateId}'` |
| Per-policy audit summary (3-step cached report) | `POST /beta/deviceManagement/reports/cachedReportConfigurations` → poll → `POST .../getCachedReport` |
| Bulk full-tenant export (preferred for automation) | `POST /beta/deviceManagement/reports/exportJobs` with `reportName: IndustryBaselinePerSettingDeviceAuditList` |
| Admin center — profile management | Endpoint security > Security baselines > Microsoft Windows 11 STIG SCAP Benchmark |
| Admin center — audit results | (profile) > Audit report / Device assignment status |
| Force refresh of already-cached report | "Generate again" button in Audit report view |
| Co-management workload check (cross-reference) | `Intune/Scripts/Get-CoManagementStatus.ps1` |

---
## 🎓 Learning Pointers

- **GCC High only, no exceptions — this is the fact that governs every other decision in this topic.** Confirm cloud environment before spending time on licensing, RBAC, or profile troubleshooting for a tenant that will never have this feature regardless of configuration. [Use STIG audit baselines to assess Windows device compliance in Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-security/security-baselines/stig-audit-baseline)

- **Audit-only is an architectural choice, not a current limitation Microsoft is working to fix.** Because it never writes configuration, it can safely coexist with every other Intune policy type with zero conflict risk — a genuinely different design philosophy from every other Intune security baseline. Remediation of findings always routes through Settings Catalog, the Windows MDM security baseline, compliance policies, or Group Policy. [Use STIG audit baselines to assess Windows device compliance in Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-security/security-baselines/stig-audit-baseline)

- **Co-management workload ownership is the single highest-value diagnostic for "no data" on a mixed ConfigMgr/Intune fleet.** The STIG audit policy rides the exact same device-configuration delivery pipeline as an ordinary Settings Catalog profile and is just as silently blocked by ConfigMgr workload ownership — with nothing in the STIG UI itself pointing at the cause. [Use STIG audit baselines to assess Windows device compliance in Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-security/security-baselines/stig-audit-baseline)

- **Bulk export is not just a convenience — it's roughly a 200x reduction in API call volume for a full-baseline pull at 197 rules (591+ calls per-setting vs. 2-3 via `exportJobs`).** Any recurring or cross-tenant STIG reporting automation should default to the bulk export pattern; reach for the per-setting cached-report pattern only for genuinely narrow, single-setting lookups. [Use STIG audit baselines to assess Windows device compliance in Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-security/security-baselines/stig-audit-baseline)

- **PolicyId is tenant-specific and version-specific; SettingId is globally consistent across tenants for a given benchmark version.** This asymmetry is exactly what the CMRS-style cross-tenant correlation pattern is built on — correlate results by SettingId, but always re-discover PolicyId per tenant and after every benchmark version upgrade. [Use STIG audit baselines to assess Windows device compliance in Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-security/security-baselines/stig-audit-baseline)

- **The ~20 manually-verified rules are a permanent, documented gap in automated coverage, not a bug.** Build a genuinely separate manual compliance process for them (firewall presence, admin-rights correctness, UEFI mode, and the rest) rather than treating their absence from the automated report as something to troubleshoot. [Use STIG audit baselines to assess Windows device compliance in Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-security/security-baselines/stig-audit-baseline)
