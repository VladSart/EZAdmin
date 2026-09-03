# Purview DLP for Non-Microsoft Connected Apps (Box/Dropbox/Google Workspace/Salesforce) — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers extending Microsoft Purview Data Loss Prevention (DLP) and Information Protection auto-labeling to **non-Microsoft SaaS applications** — currently Box, Dropbox, Google Workspace, and Salesforce — via existing Microsoft Defender for Cloud Apps (MDCA) app connectors. As of this writing (Microsoft Learn `ms.date` 2026-08-26) this is a **Preview** capability under Azure Preview Supplemental Terms, rolling out to supported apps in phases.

It assumes:
- The reader already understands Purview DLP fundamentals for Microsoft 365 locations (`Security/Purview/DLP-Policy-A.md`) — this runbook covers only what's *different* for non-Microsoft app locations, not DLP policy authoring from first principles.
- Microsoft Defender for Cloud Apps is already licensed and at least one relevant app connector may need to be configured or already exists.
- The reader is scoping work at the tenant level (Full directory) — Administrative Unit-scoped delegation is explicitly unsupported for this location type.

Out of scope: MDCA connector setup mechanics for each individual SaaS app (each has its own OAuth/API-key flow documented separately by Microsoft per app), and general Defender for Cloud Apps governance actions outside the DLP-policy integration point.

> **Source-confidence note:** Preview features can change scope, supported-app list, and behavior without the same notice period as GA features. The "Known issues" list below (encrypted files, PDFs) and the "Attribute availability by app" distinctions are explicitly called out by Microsoft as current-state, not committed-permanent behavior. Re-verify against the live Learn page before quoting specifics to a client on an engagement with compliance/audit stakes.

---

## How It Works

<details><summary>Full architecture</summary>

**The connector-reuse model.** Purview does not build or maintain its own direct integration into Box, Dropbox, Google Workspace, or Salesforce for this feature. Instead, it rides entirely on top of the **Microsoft Defender for Cloud Apps app connector** framework that already exists for Cloud App Security governance. The practical implication: DLP coverage for a non-Microsoft app is only as good as that app's MDCA connector health. A DLP policy can be perfectly configured in Purview and still do nothing if the underlying MDCA connector for that app has an expired OAuth token, a revoked API scope, or was never set up. This is architecturally different from SharePoint/OneDrive/Exchange DLP, where Purview has native, first-party visibility into the location — for non-Microsoft apps, Purview is a policy engine layered on top of somebody else's data-access pipe.

**Why only Custom/Advanced rules.** The predefined DLP templates (Financial, Medical and health, Privacy) and the simple/basic rule builder were both designed around Microsoft 365's native content model and location-specific metadata. Non-Microsoft apps expose a narrower, connector-mediated attribute surface (see the Attribute Availability table below) that the simple rule builder's UI doesn't account for — so Microsoft restricts this location type to **Custom policies with Advanced DLP rules only**, which use the more flexible rule-authoring surface capable of working with whatever attributes a given connector actually exposes.

**Why locations can't mix.** A single DLP policy in Purview can normally span multiple Microsoft 365 locations (say, SharePoint + OneDrive + Exchange) because they share a common underlying content/classification pipeline. Non-Microsoft app locations sit on a structurally different pipeline (the MDCA connector layer described above) and are documented as combinable with each other but not with Microsoft 365 locations or Devices in the same policy. Attempting to mix them isn't just discouraged — Microsoft's own policy-creation wizard enforces this by making non-Microsoft app locations mutually exclusive with other location types at the UI level, but it's still possible to hit undefined behavior if a policy is manipulated outside the guided flow, which is why this runbook treats mixed-location `Workload` values as a hard fault condition, not a style issue.

**Why Administrative Units aren't supported.** Administrative Unit-scoped delegation in Entra ID/Purview generally works by filtering policy scope to a subset of directory objects an AU-scoped admin manages. Non-Microsoft app locations aren't directory objects in the same sense — they're external application instances connected via MDCA — so the AU-scoping mechanism has no meaningful object set to filter against for this location type, and Purview forces **Full directory** scope instead.

**Why there's no simulation mode.** Purview's simulation/test mode for Microsoft 365 locations works by evaluating content against a policy without taking enforcement action, using the same native content-scanning pipeline used for real enforcement. For non-Microsoft apps, evaluation happens through the MDCA connector layer, and Microsoft has not (as of this writing, Preview stage) built an equivalent non-enforcing evaluation path through that layer — hence no simulation mode. This is a Preview-stage gap, not a permanent architectural impossibility, but treat it as current reality: the only safe pre-production testing strategy is scope-narrowing (single instance, notify-only actions where the app supports them) rather than a true dry run.

**Monitoring asymmetry.** Activity Explorer and DLP Alerts both work for non-Microsoft app locations because they consume policy *match events*, which the MDCA-connector-backed evaluation pipeline still generates and reports upstream normally. Content Explorer, by contrast, requires Purview to have direct, ongoing read access to browse and index the actual content at rest — which it doesn't have for non-Microsoft apps (only the connector-mediated, policy-evaluation-time access). This is why Content Explorer support and Activity Explorer/Alerts support diverge for this location type even though they might seem like similar "see what DLP found" surfaces.

</details>

---

## Dependency Stack

```
Layer 5: Policy Enforcement
  └─ DLP policy: Custom template + Advanced DLP rule + Full directory scope
     + Mode = On or Off (no Simulation) + non-Microsoft-app-only location mix

Layer 4: Rule Content
  └─ Conditions/actions built against the attributes the specific app's connector
     exposes (Name, File access level, Modified date always available;
     Created date unavailable for Dropbox; actions vary by app)

Layer 3: Authoring Permissions
  └─ Compliance Administrator | Compliance Data Administrator | Information
     Protection | Information Protection Admin | Security Administrator

Layer 2: Connector Layer (Microsoft Defender for Cloud Apps)
  └─ App connector configured, authorized, and actively syncing for the specific
     SaaS app (Box / Dropbox / Google Workspace / Salesforce)
     — Purview has ZERO independent visibility below this layer

Layer 1: Platform & Licensing
  └─ Microsoft Defender for Cloud Apps licensed
     + Feature available in this tenant's rollout wave (phased Preview)
     + Content type supported for classification (not PDF, not encrypted)
```

Failures at Layer 2 (connector health) are invisible from the Purview side — a policy can show `Enabled: true, Mode: Enable` and still be doing nothing if Layer 2 is broken. This is the single most important architectural fact to carry into any triage of this feature: **always validate the MDCA connector before spending time on the Purview policy itself.**

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Policy shows Enabled/On but zero alerts ever generated | MDCA app connector disconnected, expired auth, or never configured | Defender portal → Cloud apps → Connected apps |
| Can't select Financial/Medical/Privacy template for this policy | Expected — only Custom template supports non-Microsoft app locations | Rebuild using Custom template |
| Rule-builder UI looks different / missing simple conditions | Expected — only Advanced DLP rules are offered for this location | Use Create/customize advanced DLP rules |
| Can't scope policy to a specific Administrative Unit's admin | Expected — AU scoping unsupported; Full directory is the only option | No fix; document as by-design |
| Policy creation blocks combining this location with SharePoint | Expected — non-Microsoft app locations can't mix with Microsoft 365 locations or Devices in one policy | Split into separate policies |
| No "Test it out" / simulation option available | Expected — simulation mode doesn't exist for this location type (Preview-stage gap) | Use scope-narrowing as a substitute pilot strategy |
| Policy tips/user override prompts don't appear inside the SaaS app | Expected — neither is supported for non-Microsoft app locations | Document as known limitation |
| Can't find flagged items in Content Explorer | Expected — Content Explorer isn't supported for this location; use Activity Explorer instead | Check Activity Explorer / DLP Alerts |
| Encrypted file or PDF containing sensitive data isn't flagged | Documented known issue — both content types unsupported for classification here | No fix as of this writing |
| Some conditions greyed out/unavailable for a specific app (e.g., Created date on Dropbox) | Expected — attribute availability varies by connected app | Confirm against current attribute-availability table |
| Policy behaves inconsistently / undefined results | Policy scope or Workload mixes unsupported location types, likely edited outside the guided wizard | `Get-DlpCompliancePolicy` → inspect `Workload` |

---

## Validation Steps

1. **MDCA connector health (portal-only, do this first)**
   Defender portal → Cloud apps → Connected apps → App connectors. Good: target app shows connected, recent sync timestamp. Bad: disconnected, error state, or app not listed at all.

2. **Policy existence and template type**
   ```powershell
   Get-DlpCompliancePolicy | Select-Object Name, Mode, Enabled, Workload, Comment
   ```
   Good: a policy exists with `Workload` reflecting the intended non-Microsoft app(s) and no mixed Microsoft 365 locations.

3. **Rule type confirmation**
   ```powershell
   Get-DlpComplianceRule -Policy "<PolicyName>" | Select-Object Name, Disabled, AdvancedRule
   ```
   Good: `AdvancedRule` is populated (non-null/non-empty), confirming Advanced DLP rule authoring was used.

4. **Scope confirmation**
   Purview portal → policy → **Assign admin units**. Good: Full directory. Bad: any AU selected (unsupported, may not enforce reliably).

5. **Authoring permission confirmation**
   ```powershell
   Get-RoleGroupMember -Identity "Compliance Administrator"
   Get-RoleGroupMember -Identity "Compliance Data Administrator"
   Get-RoleGroupMember -Identity "Information Protection Admin"
   Get-RoleGroupMember -Identity "Security Administrator"
   ```
   Good: the policy author appears in at least one of these role groups.

6. **Monitoring surface sanity check**
   Purview portal → Data Loss Prevention → Alerts (filtered to policy) and Activity Explorer — both should be usable. Confirm Content Explorer is correctly understood as unavailable for this location rather than assumed broken.

---

## Troubleshooting Steps (by phase)

**Phase 1 — Connector layer.** Always start here. If the MDCA app connector for the affected SaaS app isn't healthy, nothing else in this runbook matters yet — fix or escalate the connector first (often requires the client's own SaaS-app admin, not just an M365 admin).

**Phase 2 — Policy construction.** Confirm Custom template, Advanced DLP rules, Full directory scope, and no mixed locations (Validation Steps 2–4). Most "policy exists but does nothing" tickets that survive Phase 1 resolve here — usually a policy built with the wrong template or accidentally combined with a Microsoft 365 location.

**Phase 3 — Rule content and app-specific attribute limits.** If the policy structure is correct but specific conditions aren't matching, check whether the condition depends on an attribute unavailable for that particular app (e.g., Created date on Dropbox). Rebuild the rule around an available attribute or accept the app-specific gap.

**Phase 4 — Content-type limitations.** If matching fails specifically for PDFs or encrypted files, stop troubleshooting the policy — this is a documented, current-state classification gap, not a fixable configuration issue.

**Phase 5 — Expectation-setting.** For any client request involving policy tips, user overrides, simulation/test mode, or Content Explorer browsing for this location type, treat it as a scoping conversation rather than a technical fix — none of the four exist for non-Microsoft app locations today.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Stand up a new non-Microsoft app DLP policy end-to-end</summary>

1. Confirm MDCA connector health for the target app first (Validation Step 1) — do not proceed until this is green.
2. Purview portal → Data Loss Prevention → Policies → Create policy → **Enterprise applications & devices** → **Custom → Custom policy**
3. Name/describe the policy, proceed past **Assign admin units** (Full directory, no choice)
4. **Choose where to apply the policy** → select only the target non-Microsoft app(s) — do not also select SharePoint/OneDrive/Exchange/Fabric/Devices
5. **Define policy settings** → **Create or customize advanced DLP rules** → **+ Create rule**
6. Configure conditions using only attributes confirmed available for the target app; configure actions from the app-specific available action set
7. Leave notifications minimal — Policy tips and user overrides are not offered here regardless of configuration
8. Choose **Turn the policy on immediately**, or leave off and rely on scope-narrowing as a pilot substitute (no simulation mode exists)
9. Validate via Activity Explorer / DLP Alerts within the first operational period, not Content Explorer

**Rollback:** disable the policy (`Set-DlpCompliancePolicy -Identity "<Name>" -Enabled $false`) — this does not affect the underlying MDCA connector or any content already flagged historically.

</details>

<details><summary>Playbook 2 — Split an incorrectly mixed-location policy</summary>

```powershell
$policy = Get-DlpCompliancePolicy -Identity "<PolicyName>"
$policy.Workload   # confirm the mix
```
1. Note all rules/conditions on the existing policy before touching anything
2. Create a new Custom-template policy scoped only to the non-Microsoft app location(s), rebuilding each rule as an Advanced DLP rule
3. Remove the non-Microsoft app location from the original policy, leaving its Microsoft 365 locations intact
4. Validate both policies independently via Activity Explorer / Alerts before considering the split complete

**Rollback:** if the split introduces regressions, re-enable the original combined policy and disable the new split policy while investigating — do not delete either policy during validation.

</details>

<details><summary>Playbook 3 — MDCA connector re-authorization (Google Workspace example)</summary>

Exact steps vary by app; general pattern:
1. Defender portal → Cloud apps → Connected apps → locate the Google Workspace connector
2. Initiate reconnect/re-authorize — this triggers an OAuth consent flow that must be completed by a Google Workspace super admin (may require handing off to the client's own admin if the MSP doesn't hold those credentials)
3. After reauthorization, allow a sync cycle to complete before re-testing DLP policy evaluation
4. Confirm connector status returns to healthy in the Defender portal before closing the ticket

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS Collects Purview non-Microsoft-app DLP policy state for escalation.
.NOTES MDCA connector health must be captured manually via portal screenshot — no PowerShell read API exists for it.
#>
Connect-IPPSSession -UserPrincipalName <adminUPN>
$out = [ordered]@{}
$out.Policies = Get-DlpCompliancePolicy | Where-Object { $_.Workload -match "ThirdPartyApp|NonMicrosoft" } |
    Select-Object Name, Mode, Enabled, Workload, Comment
$out.Rules = foreach ($p in $out.Policies) {
    Get-DlpComplianceRule -Policy $p.Name | Select-Object Name, Disabled, AdvancedRule, ParentPolicyName
}
$out.AuthorizedRoles = @{
    ComplianceAdministrator     = (Get-RoleGroupMember -Identity "Compliance Administrator").Name
    ComplianceDataAdministrator = (Get-RoleGroupMember -Identity "Compliance Data Administrator").Name
    InformationProtectionAdmin  = (Get-RoleGroupMember -Identity "Information Protection Admin").Name
    SecurityAdministrator       = (Get-RoleGroupMember -Identity "Security Administrator").Name
}
$out | ConvertTo-Json -Depth 5 | Out-File ".\NonMicrosoftAppsDLP-Evidence-$(Get-Date -Format yyyyMMdd-HHmm).json"
Write-Host "Evidence pack written. Attach an MDCA connector-health screenshot manually — no API read exists." -ForegroundColor Yellow
```

---

## Command Cheat Sheet

| Command | Purpose |
|---------|---------|
| `Get-DlpCompliancePolicy` | List DLP policies and their `Workload`/scope |
| `Get-DlpComplianceRule -Policy <Name>` | Inspect rules and confirm `AdvancedRule` is populated |
| `Set-DlpCompliancePolicy -Enabled $false` | Disable a policy (rollback path) |
| `Get-RoleGroupMember -Identity "Compliance Administrator"` | Confirm authoring permission for this feature |
| `Get-RoleGroupMember -Identity "Information Protection Admin"` | Confirm alternate authoring permission |
| *(no cmdlet)* | MDCA connector health — portal-only, Cloud apps → Connected apps |
| *(no cmdlet)* | Non-Microsoft-app DLP policy creation — portal wizard only, no documented end-to-end PowerShell path |

---

## 🎓 Learning Pointers

- Internalize the connector-reuse architecture first: Purview has **no independent visibility** into Box/Dropbox/Google Workspace/Salesforce — everything routes through the existing MDCA app connector. This single fact resolves the majority of "policy is on but doing nothing" tickets. See [Connect apps to get visibility and control with Microsoft Defender for Cloud Apps](https://learn.microsoft.com/en-us/defender-cloud-apps/enable-instant-visibility-protection-and-governance-actions-for-your-apps).
- This is a Preview feature with a phased app rollout — confirm current availability per tenant rather than assuming the announced app list is universally live. Check the [Microsoft 365 roadmap](https://www.microsoft.com/en-us/microsoft-365/roadmap).
- Four capabilities that exist for familiar SharePoint/Exchange DLP locations do not exist here: policy tips, user overrides, simulation mode, and Content Explorer. All four are consistent, documented gaps — not bugs to chase.
- Attribute availability is per-app, not universal — verify against the current [attribute availability table](https://learn.microsoft.com/en-us/purview/dlp-non-microsoft-connected-applications#attribute-availability-by-app) before promising a specific condition will work for a specific app.
- PDFs and encrypted files are unsupported for classification in this feature as of this writing — treat as a known, current-state limitation when scoping client expectations, not a troubleshooting target.
- Full reference: [Use Microsoft Purview data loss prevention policies for non-Microsoft connected apps (preview)](https://learn.microsoft.com/en-us/purview/dlp-non-microsoft-connected-applications) and [Use data loss prevention policies for non-Microsoft cloud apps](https://learn.microsoft.com/en-us/purview/dlp-use-policies-non-microsoft-cloud-apps).
