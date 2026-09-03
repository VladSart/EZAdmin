# Purview DLP for Non-Microsoft Connected Apps (Box/Dropbox/Google Workspace/Salesforce) — Hotfix Runbook (Mode B: Ops)
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

> **Source-confidence note:** this feature is in **Preview** as of this writing (Microsoft Learn `ms.date` 2026-08-26), gated by the [Supplemental Terms of Use for Azure Previews](https://azure.microsoft.com/support/legal/preview-supplemental-terms/). Supported apps (Box, Dropbox, Google Workspace, Salesforce) are rolling out in phases — not all may be present in a given tenant yet. Re-check the [Microsoft 365 roadmap](https://www.microsoft.com/en-us/microsoft-365/roadmap) for current per-app availability before promising a client this works for their specific app today.

---

## Triage

Run these within the first few minutes to classify the problem. This feature spans two admin surfaces — Microsoft Defender for Cloud Apps (MDCA) and Microsoft Purview — so triage has to check both.

```powershell
Connect-IPPSSession -UserPrincipalName <adminUPN>

# 1. Does a non-Microsoft-app-scoped DLP policy even exist?
Get-DlpCompliancePolicy | Where-Object { $_.Workload -match "ThirdPartyApp|NonMicrosoft" } |
    Select-Object Name, Mode, Enabled, Workload

# 2. What rules exist under it, and are they Advanced rules? (only Advanced rules are supported here)
Get-DlpComplianceRule -Policy "<PolicyName>" | Select-Object Name, Disabled, AdvancedRule

# 3. Confirm the requester's role — this feature requires one of a specific set of roles
Get-RoleGroupMember -Identity "Compliance Administrator"
Get-RoleGroupMember -Identity "Compliance Data Administrator"
Get-RoleGroupMember -Identity "Information Protection Admin"
```

Also check the Microsoft Defender for Cloud Apps admin console (security.microsoft.com → Cloud apps → Connected apps) for the underlying app connector — Purview policies for non-Microsoft apps are entirely dependent on that connector already being configured; there is no PowerShell surface for the MDCA connector step itself.

**Interpretation:**

| Result | Meaning | Next step |
|--------|---------|-----------|
| No policy exists scoped to the non-Microsoft app location | Policy was never created, or was created against the wrong location type | Go to Fix 1 |
| MDCA connector for the app (Box/Dropbox/Google Workspace/Salesforce) shows disconnected or errored | DLP policy has nothing to act on — this is the root cause, not the policy itself | Go to Fix 2 |
| Policy exists, is On, but nothing is being flagged | Confirm the rule is an Advanced DLP rule — the simple rule builder isn't supported for this location | Go to Fix 3 |
| Client expects policy tips or user override prompts inside Box/Google Workspace/etc. | Not supported for non-Microsoft app locations — expected behavior, not a bug | Note as known limitation |
| Client wants to test the policy safely before enforcing | Simulation mode isn't supported for this location type — there is no dry-run | Go to Fix 4 |
| Client wants to browse/search actual flagged content in Content Explorer | Not supported for non-Microsoft connected apps — only Activity Explorer and DLP alerts work here | Note as known limitation |
| PDF or encrypted files aren't being classified even though they clearly contain sensitive data | Documented known issue — PDFs and encrypted files aren't currently supported for classification in non-Microsoft apps | Note as known limitation |
| Policy silently stopped matching after previously working | Check whether an admin tried to combine this location with SharePoint/OneDrive/Exchange/Fabric/Devices in the same policy, or scoped it to an Administrative Unit — both are unsupported and will misbehave | Go to Fix 5 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
DLP policy actively protecting data in a non-Microsoft app (Box/Dropbox/Google Workspace/Salesforce)
│
├── App is in the supported, currently-rolled-out set for this tenant
│   (phased rollout — not guaranteed present even if generally announced)
│
├── Microsoft Defender for Cloud Apps (MDCA) app connector configured and healthy
│   └── Purview does NOT talk to the SaaS app directly — it reuses the existing
│       MDCA connector; if the connector is broken, the DLP policy has no data to act on
│
├── Requester/policy-author holds one of: Compliance Administrator, Compliance Data
│   Administrator, Information Protection, Information Protection Admin, Security Administrator
│
├── DLP policy created via "Enterprise applications & devices" → non-Microsoft app location
│   ├── Custom policy template ONLY (Financial/Medical/Privacy templates unsupported here)
│   ├── Scope = Full directory (Administrative Units NOT supported for this location)
│   └── Location cannot be combined with SharePoint/OneDrive/Exchange/Fabric/Devices
│       in the same policy — non-Microsoft app locations only mix with each other
│
├── Rule type = Advanced DLP rule (the basic/simple rule builder is not supported)
│
├── Policy mode = On immediately, or Off
│   └── Simulation mode does NOT exist for this location — no dry-run capability
│
└── Content characteristics
    ├── File is not encrypted (unsupported for classification)
    └── File is not a PDF (unsupported for classification)
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm MDCA connector health (do this first, always)**

In the Microsoft Defender portal: **Cloud apps → Connected apps → App connectors**. Confirm the relevant app (Box/Dropbox/Google Workspace/Salesforce) shows a healthy, recent-sync connection. There is no supported PowerShell cmdlet for reading MDCA connector health directly — this is a portal-only check. If the connector is broken or was never configured, nothing downstream in Purview can work, regardless of how the DLP policy itself is configured.

**Step 2 — Confirm policy scope and template type**

```powershell
Get-DlpCompliancePolicy -Identity "<PolicyName>" | Select-Object Name, Mode, Enabled, Workload, Comment
```
Expect: `Workload` reflects the non-Microsoft app location(s), and the policy was built from the **Custom** template — not Financial/Medical/Privacy, which don't support this location type at all.

**Step 3 — Confirm rule type**

```powershell
Get-DlpComplianceRule -Policy "<PolicyName>" | Select-Object Name, Disabled, AdvancedRule
```
`AdvancedRule` must be populated — the simple/basic rule builder used for SharePoint/Exchange policies doesn't apply to non-Microsoft app locations.

**Step 4 — Confirm no unsupported location mixing**

```powershell
(Get-DlpCompliancePolicy -Identity "<PolicyName>").Workload
```
If this shows a mix of a non-Microsoft app and SharePoint/OneDrive/Exchange/Fabric/Devices, the policy was built incorrectly — this configuration isn't supported and behavior is undefined. Split it into separate policies.

**Step 5 — Confirm activity is actually being generated**

Purview portal → **Data Loss Prevention → Alerts**, filtered to the relevant policy — confirm alerts are (or aren't) appearing. Cross-check against **Activity Explorer**, which is supported for this location. Content Explorer is explicitly **not** supported here, so don't waste time looking for flagged content there.

---

## Common Fix Paths

<details><summary>Fix 1 — No policy exists for the non-Microsoft app location</summary>

Build it via the Purview portal (there is no documented PowerShell path to create a non-Microsoft-app-scoped DLP policy end-to-end — the portal wizard is the supported method):

1. Purview portal → **Data Loss Prevention → Policies → + Create policy**
2. **What info do you want to protect?** → **Enterprise applications & devices**
3. **Custom → Custom policy** (only supported template family for this location)
4. Scope defaults to **Full directory** — Administrative Units aren't selectable here
5. **Choose where to apply the policy** → select the supported non-Microsoft app(s). Do not also select SharePoint/OneDrive/Exchange/Fabric/Devices in the same policy.
6. **Define policy settings** → **Create or customize advanced DLP rules** (mandatory — the simple builder isn't offered for this location)
7. Configure conditions/actions (available options vary by app — see Learning Pointers for the attribute-availability table)
8. Policy tips and user overrides are not configurable here — don't look for them
9. Choose **Turn the policy on immediately** or leave it off — there is no simulation mode to fall back to

</details>

<details><summary>Fix 2 — MDCA app connector is disconnected or unhealthy</summary>

This is a Defender for Cloud Apps issue, not a Purview issue — resolve it there first:

1. Defender portal → **Cloud apps → Connected apps → App connectors**
2. Locate the affected app and check connection status / last sync time
3. Reauthorize the connector (typically an OAuth re-consent flow against the SaaS app's own admin console — e.g., a Google Workspace super admin or Box enterprise admin will need to complete the re-auth on their side)
4. Once reconnected, allow time for MDCA to resync before expecting DLP evaluation to resume — this is not instantaneous

**Escalate to the client's SaaS-app admin** if reauthorization requires credentials/access the MSP doesn't hold (common for Google Workspace and Salesforce, which are often managed by a different team or vendor).

</details>

<details><summary>Fix 3 — Policy uses the simple rule builder instead of Advanced rules</summary>

The simple rule builder isn't offered when the policy location is a non-Microsoft app, so this is more often a symptom of the policy being incorrectly scoped in the first place (Fix 5) than a rule authored the wrong way. Confirm scope first; if scope is correct and rules genuinely aren't Advanced, rebuild the rule using **Create or customize advanced DLP rules** rather than attempting to convert an existing simple rule in place.

</details>

<details><summary>Fix 4 — Client wants to test before enforcing (no simulation mode available)</summary>

There is no simulation/test mode for non-Microsoft app locations. The practical workaround is to scope the policy narrowly first:
- Use **Exclude instances** / **Specific instances** scoping to a single, low-risk app instance or a pilot tenant/org unit within the SaaS app if the app supports that separation
- Set actions to a low-impact/notify-only action first rather than a blocking action, if the app's available actions support that distinction (varies by app — check the attribute/action availability table)
- Turn the policy on and monitor via Activity Explorer and DLP Alerts closely for a defined pilot window before widening scope

Document explicitly for the client that this is a mitigation, not a true simulation mode — real actions still fire during the pilot.

</details>

<details><summary>Fix 5 — Policy mixes non-Microsoft app locations with Microsoft locations, or targets an Administrative Unit</summary>

```powershell
(Get-DlpCompliancePolicy -Identity "<PolicyName>").Workload
```
If this confirms mixed/unsupported scoping, split the policy:
1. Create a new policy scoped **only** to the non-Microsoft app location(s), rebuilding rules as Advanced DLP rules
2. Leave the original policy scoped to its Microsoft 365 locations (SharePoint/OneDrive/Exchange/Fabric/Devices) unchanged
3. Disable/retire the incorrectly-scoped combined policy once the split policies are validated

If scoped to an Administrative Unit, recreate the policy at Full directory scope — AU-scoped policies aren't supported for non-Microsoft app locations and may not enforce as expected.

</details>

---

## Escalation Evidence

```
TICKET: Purview DLP — Non-Microsoft Connected App
=====================================================
Affected app: <Box / Dropbox / Google Workspace / Salesforce>
MDCA connector status (screenshot/description): <connected/disconnected, last sync time>
DLP policy name: <name>
Policy Mode (On/Off): <value>
Workload/location scope: <output of Workload property>
Rule type confirmed Advanced: <yes/no>
Administrative Unit scoping used: <yes/no>
Symptom: <nothing flagged / false negatives on PDFs or encrypted files / policy tips expected / etc.>
Reproduction: <steps, including a specific test file/content type if applicable>
Requester role confirmed (Compliance Admin / Compliance Data Admin / Info Protection Admin / Security Admin): <role>
Business impact: <e.g., data governance requirement, compliance audit finding>
```

---

## 🎓 Learning Pointers

- This is a **preview** feature — supported apps roll out in phases per tenant. Always confirm current per-app availability against the [Microsoft 365 roadmap](https://www.microsoft.com/en-us/microsoft-365/roadmap) rather than assuming general availability applies to a specific client's tenant.
- Purview does not talk to Box/Dropbox/Google Workspace/Salesforce directly for this feature — it rides entirely on the existing **Microsoft Defender for Cloud Apps app connector**. Always check MDCA connector health before troubleshooting anything on the Purview side. See [Connect apps to get visibility and control with Microsoft Defender for Cloud Apps](https://learn.microsoft.com/en-us/defender-cloud-apps/enable-instant-visibility-protection-and-governance-actions-for-your-apps).
- Attribute availability varies by app — e.g., **Created date** is not available for Dropbox items even though it's available for the other three supported apps. Don't assume every condition/attribute works identically across apps; check the current attribute-availability table in Microsoft's documentation before building a rule.
- Four capabilities that work differently here than in familiar SharePoint/Exchange DLP: no policy tips, no user overrides, no simulation mode, and no Content Explorer support (Activity Explorer and DLP Alerts still work). Set client expectations on all four up front.
- PDFs and encrypted files are explicitly unsupported for classification in non-Microsoft apps as of this writing — a documented known issue, not something to troubleshoot as a local misconfiguration.
- Full reference: [Use Microsoft Purview data loss prevention policies for non-Microsoft connected apps (preview)](https://learn.microsoft.com/en-us/purview/dlp-non-microsoft-connected-applications).
