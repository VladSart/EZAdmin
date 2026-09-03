# Purview Endpoint DLP Just-in-Time (JIT) Protection — Hotfix Runbook (Mode B: Ops)
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

> **Source-confidence note:** the core JIT protection feature is documented on primary Microsoft Learn pages (`ms.date` 2026-06-22/2026-06-26). The newer **JIT Audit user/group scoping** capability (Microsoft 365 Roadmap ID 562991 — include/exclude specific users or groups from JIT Audit logging) has conflicting reported release dates across secondary sources (July CY2026 per the Roadmap listing itself, September CY2026 GA per other trade-press coverage) and no dedicated Learn conceptual page as of this writing. Treat the base JIT mechanics below as settled; re-verify the exact scoping-capability rollout date against the live Purview portal before quoting it to a client.

---

## Triage

Run these within the first 60 seconds. JIT protection is a **device-local, Windows/macOS Defender antimalware-client-enforced** feature layered on top of existing Endpoint DLP policies — most "JIT isn't working" tickets are actually prerequisite or scope gaps, not JIT defects.

```powershell
# Connect to Security & Compliance PowerShell
Connect-IPPSSession -UserPrincipalName <adminUPN>

# 1. Is JIT protection even enabled for Devices as a location?
#    (Portal-only setting — Purview portal > Settings > Data Loss Prevention > Just-in-time protection.
#     No dedicated Get- cmdlet reads this toggle directly; confirm via the portal.)

# 2. Do the affected devices meet the antimalware client version floor?
#    Run in Defender/Security portal > Investigation & response > Advanced hunting:
```

```kusto
DeviceRegistryEvents
| where InitiatingProcessVersionInfoInternalFileName == "MsMpEng.exe" and Timestamp >= ago(60d)
| summarize arg_max(Timestamp, *) by DeviceId
| distinct DeviceName, DeviceId, AntiMalwareClientVersion = InitiatingProcessVersionInfoProductVersion
| extend Meets_Minimum_JIT_4_18_23080 = strcmp(AntiMalwareClientVersion, "4.18.23080")
| extend Meets_Latest_UX_4_18_25080 = strcmp(AntiMalwareClientVersion, "4.18.25080")
```

```powershell
# 3. Does an active Endpoint DLP policy actually Block or Block-with-override the relevant egress
#    activity for this user? JIT has NOTHING to evaluate without an underlying block-capable policy.
Get-DlpCompliancePolicy | Where-Object { $_.Workload -match "Endpoint" } | Select-Object Name, Enabled, Mode
Get-DlpComplianceRule | Where-Object { $_.ParentPolicyName -in (Get-DlpCompliancePolicy | Where-Object {$_.Workload -match "Endpoint"}).Name } |
    Select-Object Name, ParentPolicyName, BlockAccess, BlockAccessScope

# 4. Is the user actually in the JIT scope? (Purview portal > Just-in-time protection > scope setting —
#    no cmdlet exposes JIT scope membership directly as of this writing)
```

**Interpretation:**

| Result | Meaning | Next step |
|--------|---------|-----------|
| Antimalware client below `4.18.23080` | Device doesn't meet the JIT prerequisite floor at all — JIT is silently inactive on that device | Go to Fix 1 |
| Antimalware client `4.18.23080`-`4.18.25079` | JIT itself works, but the improved 2026 user-experience notifications (JIT in progress / evaluation complete toasts) do not — expected, not a defect | Go to Fix 1 (optional upgrade) |
| No Endpoint DLP policy has Block or Block-with-override for the activity in question | JIT has nothing to enforce — user reports being "blocked randomly" but the actual blocking policy is a normal DLP block, not JIT, or vice versa | Go to Fix 2 |
| User reports being blocked on an activity that should be excluded (an allowed printer/USB/network share/URL) | Activity target is outside the "excluded location" allow-list, or the allow-list entry itself is misconfigured | Go to Fix 3 |
| User reports JIT blocking an app that should be exempt | App not on the JIT app-exclusion list (max 50 apps per platform) — distinct from the general Endpoint DLP app-exclusion list | Go to Fix 4 |
| JIT scope/setting change made, user reports no change even after an hour | JIT setting propagation can take up to an hour by Microsoft's own guidance; premature escalation | Go to Fix 5 |
| Copy-to-clipboard suddenly blocked/audited unexpectedly | Clipboard is **JIT Audit by default** unless "Control copying to clipboard" is explicitly enabled for Block — confirm which setting is actually on | Go to Fix 6 |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
[Microsoft Purview Endpoint DLP — Devices onboarded]
        └── [Defender antimalware client >= 4.18.23080] (minimum; 4.18.25080+ for improved UX)
              └── [JIT protection enabled for Devices location]
                    (Purview portal > Settings > Data Loss Prevention > Just-in-time protection)
                    ├── [Fallback action in case of failure]: Allow (default, recommended) vs Block
                    ├── [JIT scope]: which users/devices JIT actually evaluates for
                    ├── [Additional settings]: clipboard control, app exclusions (Win/Mac, max 50 each),
                    │     file extension exclusions, file path exclusions (Win/Mac)
                    └── requires an ACTIVE Endpoint DLP policy with Block or Block-with-override
                          action for the specific egress activity — JIT has no independent
                          detection/blocking logic of its own; it only governs files that
                          haven't been classified yet (JIT candidate files) while that
                          existing policy's evaluation is still in progress
```

JIT is **not** a DLP policy in itself — it's a timing/enforcement-gap-closer layered in front of existing Endpoint DLP policies. A tenant with JIT enabled but no Block-capable Endpoint DLP policy will see zero JIT activity, correctly, because there's nothing for JIT to protect ahead of.

</details>

---

## Diagnosis & Validation Flow

1. **Confirm the device meets the antimalware client floor.**
   Advanced Hunting query (Triage step 2). *Good:* `4.18.23080` or later. *Bad:* older — JIT is inactive on that device regardless of any policy/scope configuration.

2. **Confirm an underlying Block-capable Endpoint DLP policy actually covers this activity.**
   `Get-DlpComplianceRule` (Triage step 3). *Good:* a rule with `BlockAccess`/`BlockAccessScope` targeting the activity exists and is enabled. *Bad:* no such rule — the reported "JIT block" is either a different DLP mechanism entirely, or nothing should be blocking at all.

3. **Confirm the user/device is actually in JIT scope.**
   Purview portal > Just-in-time protection > scope. *Good:* user/device included. *Bad:* not in scope — by design, JIT doesn't evaluate them (this generates a JIT **audit** event only, per the documented workflow, never a block).

4. **Confirm the activity isn't targeting an excluded location.**
   Check allowed printer/USB/network-share/URL groups, plus JIT-specific app/file-path/file-extension exclusions (distinct lists from general Endpoint DLP exclusions — see Learning Pointers).

5. **Confirm propagation timing.**
   Allow up to one hour for any JIT setting change (including disabling JIT) to reach client devices, per Microsoft's own documented guidance — this is the most common false-escalation cause for "I just changed it and it's still wrong."

---

## Common Fix Paths

<details><summary>Fix 1 — Antimalware client below the JIT version floor</summary>

1. Confirm current version via the Advanced Hunting query in Triage step 2, or per-device via Purview portal > Data Loss Prevention > Diagnostics > "Endpoint DLP not working" card.
2. Update the Defender antimalware client through normal update channels (Microsoft Update, WSUS, or Intune-managed update policy) to at least `4.18.23080` (minimum JIT function) or `4.18.25080` (adds the improved in-progress/evaluation-complete toast notifications).
3. For devices you deliberately want JIT inactive on due to an outdated client, no separate disable step is needed — they're already effectively excluded by version.
4. If a device must have JIT force-disabled for an unrelated reason ahead of remediation, apply one of the documented disable KBs (Windows 10: KB5032278; Windows 11: KB5032288) as a temporary measure, not a long-term fix.

**Rollback:** none — this is a client-update action, not a policy change.

</details>

<details><summary>Fix 2 — No underlying Block-capable Endpoint DLP policy exists</summary>

1. Confirm this is genuinely the case via Triage step 3 rather than assuming — JIT enforcement and ordinary Endpoint DLP blocks can look identical to an end user.
2. If the user's actual complaint is an ordinary (non-JIT) Endpoint DLP block, this runbook doesn't apply — see `DLP-Policy-B.md`.
3. If JIT enforcement genuinely was expected but no Block/Block-with-override rule exists, this is a policy-authoring gap, not a JIT defect — build or fix the underlying Endpoint DLP rule first, per `DLP-Policy-A.md`.

**Rollback:** not applicable — no JIT-specific change was made.

</details>

<details><summary>Fix 3 — Activity should have been excluded but was blocked</summary>

1. Confirm the exact target (printer name, USB device ID, network share path, or URL/cloud-service domain) against the configured allow-lists in Purview portal > Data Loss Prevention > Endpoint settings.
2. Remember: JIT's own **file path exclusions** (JIT-specific) only exclude a path from JIT evaluation — the file is still fully evaluated by ordinary Endpoint DLP classification/protection. This is different from the general **File path exclusions for Windows** setting, which exempts the path from Endpoint DLP entirely. Confirm which exclusion type is actually configured before assuming the exclusion should have applied.
3. Add or correct the allow-list/exclusion entry as needed.

**Rollback:** removing an allow-list/exclusion entry re-applies standard JIT evaluation to that target — non-destructive.

</details>

<details><summary>Fix 4 — App should be exempt from JIT but isn't</summary>

1. Confirm the app is actually on the **JIT-specific** app-exclusion list (Windows or Mac, max 50 apps each) — distinct from any general Endpoint DLP app-based restriction list.
2. Add the app if missing. If already at the 50-app cap for that platform, prioritize which apps genuinely need JIT exemption versus ordinary Endpoint DLP evaluation.

**Rollback:** removing an app from the exclusion list re-applies JIT evaluation to it — non-destructive, but re-test for unexpected blocking before wide rollout.

</details>

<details><summary>Fix 5 — Setting changed, no observed effect yet</summary>

1. Confirm at least one hour has elapsed since the change, per Microsoft's documented propagation guidance (applies to enabling, disabling, and scope/setting changes alike).
2. If more than an hour has passed with no effect, re-confirm the change actually saved in the portal (a common false assumption when a save silently fails) before escalating.

**Rollback:** not applicable — this is a timing issue, not a configuration problem.

</details>

<details><summary>Fix 6 — Unexpected clipboard block/audit behavior</summary>

1. Confirm whether **Control copying to clipboard** is turned on. Clipboard activity is **JIT Audit by default** (logged, not blocked) unless this additional setting is explicitly enabled, which escalates it toward block-capable evaluation.
2. If the client didn't intend to restrict clipboard activity this tightly, disable **Control copying to clipboard** and confirm expected behavior returns (allow up to an hour for propagation — Fix 5).
3. Before enabling this setting for a new rollout, explicitly warn stakeholders about the documented productivity impact and test on a pilot group first, per Microsoft's own caution note.

**Rollback:** toggling **Control copying to clipboard** off/on is non-destructive and immediately reversible (subject to the standard propagation delay).

</details>

---

## Escalation Evidence

```
=== Endpoint DLP JIT Protection — Escalation Packet ===
Tenant:
Ticket #:
Date/Time (UTC):
Affected user/device:

1. Antimalware client version on affected device (Advanced Hunting output, attach):
2. JIT protection enabled for Devices location: Y/N (portal screenshot)
3. Fallback action in case of failure setting: Allow / Block
4. JIT scope — is this user/device included: Y/N
5. Underlying Endpoint DLP policy/rule with Block or Block-with-override for this activity (Get-DlpComplianceRule output, attach):
6. Activity type affected (removable media / network share / print / RDP / Bluetooth / clipboard / cloud upload):
7. Relevant exclusion list state (allowed printer/USB/network share/URL; JIT app/file-path/file-extension exclusions), attach:
8. Time elapsed since last JIT setting change: ____________
9. Activity Explorer JIT event detail (JIT triggered = true, Enforcement mode value), attach:
10. Prior fix paths attempted from this runbook:
```

---

## 🎓 Learning Pointers

- JIT is a **timing-gap enforcement layer**, not an independent DLP engine — it only acts on files that haven't been classified yet or have a stale classification, and it has nothing to enforce without an existing Block-capable Endpoint DLP policy underneath it. Always confirm that policy exists before troubleshooting JIT itself.
- **JIT-specific file path exclusions** and **general Endpoint DLP "File path exclusions for Windows"** are two different settings with different scope — the first only skips JIT evaluation (ordinary DLP still applies), the second exempts the path from Endpoint DLP entirely. This distinction is a common source of "I excluded it and it's still being blocked" tickets.
- Clipboard copy is **JIT Audit by default** — it only becomes block-capable if **Control copying to clipboard** is explicitly turned on, which Microsoft explicitly flags as a productivity-impacting setting to pilot-test first.
- Allow **up to one hour** for any JIT setting change — including disabling JIT — to propagate to client devices before treating a change as ineffective.
- The newer **JIT Audit user/group scoping** capability (Roadmap ID 562991) narrows audit-logging further to explicitly included/excluded users or groups — verify its live rollout status in this tenant's Purview portal rather than assuming it's present, since reported GA timing varies across sources (see the source-confidence note above).
- See [Get started with Endpoint DLP Just-in-time protection](https://learn.microsoft.com/en-us/purview/endpoint-dlp-get-started-jit) and [Learn about Endpoint DLP just-in-time protection](https://learn.microsoft.com/en-us/purview/endpoint-dlp-learn-about-jit) for the full documented workflow and antimalware client version table.
