# Windows Autopatch Quality Update Policies — Hotfix Runbook (Mode B: Ops)
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

**Scope check first:** this runbook covers the **cloud-based Windows quality update policy** object (Intune admin center → Devices → Manage updates → Windows updates → Quality updates), rolling out to all tenants September 1 – October 15, 2026. This is a distinct, admin-configured **approval/deferral/pause** mechanism layered over — and taking precedence over — the ring-based orchestration covered in `Autopatch-A/B.md`. If the ticket is about ring assignment, staggered rollout, or Microsoft's own automatic incident-triggered pause, start with `Autopatch-B.md` instead; this file is for tickets about admin-driven approve/defer/pause decisions and .NET Framework update behavior.

```powershell
# Connect to Microsoft Graph
Connect-MgGraph -Scopes "DeviceManagementConfiguration.Read.All,DeviceManagementManagedDevices.Read.All" -NoWelcome

# 1. Is the device even targeted by a cloud-based quality update policy, or only a legacy Update ring?
# (Portal is authoritative — Intune admin center > Devices > Manage updates > Windows updates > Quality updates > Manage updates)

# 2. Quick device compliance/update-status snapshot via Graph
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<deviceName>'" |
    Select-Object DeviceName, ComplianceState, OSVersion, LastSyncDateTime

# 3. Confirm the device isn't running a Windows Insider build
#    (Insider-build devices are silently excluded from quality update policy enrollment)
Write-Host "Check winver / build number on device — Insider builds are excluded from Autopatch quality update policy" -ForegroundColor Cyan
```

**Interpretation:**

| Result | Likely cause | Go to |
|--------|-------------|-------|
| Device never gets the monthly security update despite an "Automatic" policy | Deferral period configured too high (up to 30 days allowed), or release is still Paused | Fix 1 |
| Device didn't get an optional/non-security preview update, ticket calls this "broken" | Default approval for non-security releases is **Manual** — this is by design, not a fault | Fix 2 |
| A release was intentionally paused but devices that already installed it are asking to be "rolled back" | Pause never rolls back already-installed devices — documented, expected behavior | Fix 3 (expectation-setting) |
| Admin paused/resumed a release and nothing changed for hours | Pause/resume can take up to 8 hours to reach managed devices (Intune check-in latency) | Fix 3 |
| Device has hotpatch enabled but a non-security update was approved and it caused an unexpected restart | Approving non-security updates while hotpatch is enabled removes the device from the hotpatch path for that cycle — documented interaction, not a bug | Fix 4 |
| Device shows a target release/compliance date that doesn't match what the client expects | Compliance date formula differs for manual vs. automatic approval — see Learning Pointers | Fix 5 |
| Client wants to change an existing policy from Automatic to Manual approval (or vice versa) | Approval method **cannot be edited** on an existing policy — must create a new one | Fix 6 |
| Device is on both a legacy Update ring policy and a new cloud-based quality update policy, behavior is inconsistent | Cloud-based quality update policy takes precedence for approval/deferral; ring policy's deadline/grace period settings still apply | Fix 7 |

---

## Dependency Cascade

<details><summary>What must be true for a cloud-based quality update policy to govern a device</summary>

```
[Windows quality update policy] (Intune admin center, cloud-based object)
    │
    ├── Device NOT on a Windows Insider build
    │     └── Insider builds silently excluded from quality update enrollment
    │
    ├── Device assigned to the policy
    │     └── Auto-enrolled in Windows Autopatch for quality updates upon assignment
    │           └── Remains enrolled 24h after unassignment (grace period), then auto-unenrolls
    │
    ├── Per-release-category approval method configured (independently, per category):
    │     ├── Monthly security updates          (default: Automatic)
    │     ├── Monthly non-security preview       (default: Manual)
    │     ├── Out-of-band security updates       (default: Manual)
    │     └── Out-of-band non-security updates   (default: Manual)
    │           └── Same policy also governs matching .NET Framework update categories
    │
    ├── For Automatic approval:
    │     └── Deferral period configured (0–30 days) → release offered after (release date + deferral)
    │           └── Can be manually overridden (immediate approval) at any time
    │
    ├── For Manual approval:
    │     └── Explicit admin approval required per release (Manage updates > Approve)
    │
    ├── Release NOT currently Paused
    │     └── Pause revokes approval — no NEW devices receive it; already-installed devices unaffected
    │           └── Resume = re-approve; up to 8h for pause/resume to reach devices (Intune latency)
    │
    ├── Compliance date calculated:
    │     ├── Manual approval: approval date + client deadline
    │     └── Automatic approval: release date + policy deferral + client deadline
    │           └── Client deadline itself comes from Update rings / supported CSP policy, NOT this policy
    │
    └── Policy conflict precedence (when multiple policies target one device):
          ├── Cloud-based quality update policy > legacy Update ring policy (for approval/deferral)
          │     └── Update ring's deadline/grace-period settings still apply
          ├── Multiple cloud-based quality update policies → policy approving the LATEST release wins
          └── Cloud-based policy > legacy quality update policy with only hotpatch setting
```

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm which policy type actually governs the device**
Intune admin center → **Devices** → **Manage updates** → **Windows updates** → **Quality updates** → **Manage updates** blade → find the device/policy assignment.
Expected: device listed under a specific cloud-based quality update policy.
Bad: device only shows under a legacy Update ring — this runbook doesn't apply; use `Autopatch-B.md`/WUfB update-ring guidance instead.

---

**Step 2 — Confirm the approval method and deferral for the relevant release category**
Open the assigned policy → note approval method (Automatic/Manual) and, if Automatic, the deferral days — **per category** (security / non-security / OOB security / OOB non-security). Categories are configured independently; don't assume all four match.
Expected: matches what the client believes is configured.
Bad: category defaults were left as-is (Manual for non-security/OOB) when the client assumed everything was Automatic like security updates.

---

**Step 3 — Confirm the specific release's approval/pause state**
**Manage updates** blade → select the **Release** name → check the **Approved policies** column (X of Y policies approved) and whether the release shows **Paused**.
Expected: release approved for the relevant policy, not paused.
Bad: release shows **Needs review** for this policy (manual approval never actioned), or **Paused** (intentionally or accidentally halted).

---

**Step 4 — Confirm the compliance date calculation matches expectations**
For manually-approved releases: **approval date + client deadline**. For automatically-approved releases: **release date + policy deferral + client deadline**. Client deadline comes from the Update rings / Windows Update for Business CSP policy still assigned to the device — check that separately if the date looks wrong even after confirming the quality update policy's own settings.

---

**Step 5 — Check for a legacy Update ring / hotpatch policy conflict**
If the device is also targeted by a legacy Update ring policy or a legacy quality update policy carrying only a hotpatch setting, apply the precedence rules in the Dependency Cascade above — the cloud-based quality update policy always wins on approval/deferral, but the older policy's deadline/grace period may still be the one actually in effect.

---

**Step 6 — For pause/resume tickets, confirm elapsed time before assuming it failed**
Pause and resume instructions can take **up to 8 hours** to reach managed devices, since Windows Autopatch relies on standard Intune device check-in latency. Don't escalate a "pause didn't work" ticket inside that window.

---

## Common Fix Paths

<details>
<summary>Fix 1 — Device isn't getting the monthly security update on schedule</summary>

**Symptoms:** Policy shows Automatic approval for security updates, but a device hasn't installed the current release well past when it should have.

**Step 1 — Check the configured deferral period**
Intune admin center → policy → **Monthly security updates** → **Make updates available after** setting (0–30 days). A high deferral value delays availability by design.

**Step 2 — Check whether the release is Paused**
**Manage updates** → select the release → confirm it isn't showing **Paused** for this policy. A paused release stops new devices from receiving it, even under Automatic approval.

**Step 3 — Manually override the deferral if urgency requires it**
```
Intune admin center > Devices > Manage updates > Windows updates > Quality updates
> Manage updates > select Release > select policy > Approve
```
This immediately approves the release for the policy, overriding any remaining deferral period.

**Step 4 — Confirm the device isn't excluded for other reasons**
Check for Windows Insider build enrollment (silently excluded) and confirm the device is still actively assigned to the policy (not in the 24h post-unassignment grace window headed for auto-unenrollment).

**Rollback:** Re-approving early is not reversible via "un-approve" — if this causes issues, use Pause (Fix 3) on the specific release instead.

</details>

<details>
<summary>Fix 2 — Optional/non-security update "isn't deploying" (client expected it to)</summary>

**Symptoms:** Client reports a non-security preview or out-of-band non-security update never reached devices, treating it as a fault.

**Step 1 — Confirm this is expected default behavior**
The default approval configuration for **all categories except monthly security updates** is **Manual** — non-security preview, OOB security, and OOB non-security updates require explicit admin approval by design, even inside an otherwise "Automatic" policy.

**Step 2 — If manual approval is genuinely wanted, approve the release**
**Manage updates** → select the Release → select the policy → **Approve**.

**Step 3 — If the client wants this category to be Automatic going forward**
Approval method **cannot be changed on an existing policy** (see Fix 6) — a new policy must be created with Automatic approval for that category, and devices reassigned.

**Rollback:** N/A — this is a configuration/expectation clarification, not a fault.

</details>

<details>
<summary>Fix 3 — Pause a problematic release, or investigate a stalled pause/resume</summary>

**Symptoms:** A release is causing issues and needs to stop rolling out further, OR an admin paused/resumed a release and devices don't reflect the change.

**Step 1 — Pause the specific release for the affected policy**
```
Intune admin center > Devices > Manage updates > Windows updates > Quality updates
> Manage updates > select Release > select the affected policy > Pause
```

**Step 2 — Set correct expectations about what Pause does and doesn't do**
- Pause stops **new** devices from receiving the release.
- Pause does **NOT** roll back devices that already installed it — there is no remote-rollback action here.
- Pause can take up to 8 hours to reach managed devices (Intune check-in latency).
- Pausing one release category doesn't pause others — pausing a .NET Framework release doesn't pause an approved OS security release, and vice versa.

**Step 3 — Resume when ready**
Re-**Approve** the same release — Windows Autopatch offers it again to devices that still need it, as if newly approved.

**Rollback:** Resuming (re-approving) is the only way back; there is no separate "cancel pause" action distinct from Approve.

</details>

<details>
<summary>Fix 4 — Unexpected restart on a hotpatch-enabled device after a non-security update</summary>

**Symptoms:** A device enrolled in hotpatch updates (expected zero-restart monthly security patching) suddenly needed a full restart.

**Step 1 — Check whether a non-security update was approved for that policy**
If a policy has hotpatch updates enabled AND non-security updates get approved, the device **will not** receive the non-security update while remaining on the hotpatch path for that cycle — applying it removes the device from hotpatch, which is precisely the kind of change that forces a full restart and typically requires waiting until the next hotpatch cycle to resume.

**Step 2 — Decide the intended behavior**
- To keep hotpatch behavior clean (zero-restart security-only cadence): leave non-security updates on Manual and don't approve them for hotpatch-targeted rings.
- To intentionally apply a non-security update: disable the hotpatch update setting in the quality update policy first, understanding the device exits hotpatch for that cycle.

**Rollback:** N/A — this reflects an architectural interaction between hotpatch and non-security update approval, not a bug to revert. See `Hotpatch-A.md` for hotpatch-specific troubleshooting.

</details>

<details>
<summary>Fix 5 — Compliance date on the Quality update status report doesn't match expectations</summary>

**Symptoms:** A device's Target compliance date in Intune's Quality update status report looks wrong.

**Step 1 — Identify which approval path applies**
- Manually approved release: **Approval date + client deadline**.
- Automatically approved release: **Release date + policy deferral period + client deadline**.
- Device only on a legacy Update ring (no cloud-based quality update policy): **Update ring deferral + client deadline** (no quality-update-policy component at all).

**Step 2 — Confirm the client deadline source**
Client deadline itself is set via Windows Update for Business CSP / Update rings policy — check that assignment separately if the deadline component looks wrong even once the quality-update-policy math is confirmed correct.

**Step 3 — Pull the per-device detail from the Quality update status report**
Intune admin center → **Reports** → **Windows Autopatch** → **Windows quality updates** → **Reports** tab → **Quality update status**. Columns include Target compliance, Target release, Installed release, and the specific Quality update policy/Update ring policy names in effect — use this to see exactly which policy Intune considers authoritative for that device.

**Rollback:** N/A — diagnostic clarification only.

</details>

<details>
<summary>Fix 6 — Client wants to change an existing policy's approval method</summary>

**Symptoms:** Request to flip a category (e.g. security updates) from Automatic to Manual, or vice versa, on an already-created policy.

**Step 1 — Confirm this cannot be done in place**
The approval method for a quality update policy **cannot be edited after creation** — this is an explicit product constraint, confirmed in Microsoft's own FAQ for this feature.

**Step 2 — Create a new policy with the desired approval method**
Build a new quality update policy with the correct per-category approval settings.

**Step 3 — Reassign affected devices**
Move the device/group assignment from the old policy to the new one. Plan for a brief window where devices may show **None assigned** for quality update policy if unassignment and reassignment aren't done together.

**Rollback:** Keep the old policy until the new one is validated, then remove device assignment from the old policy.

</details>

<details>
<summary>Fix 7 — Device targeted by both a legacy Update ring and a new cloud-based quality update policy</summary>

**Symptoms:** Inconsistent-seeming update behavior; client unsure which policy is "really" in control.

**Step 1 — Apply the documented precedence order**
- Cloud-based quality update policy takes priority for **approval settings and deferral**.
- The legacy Update ring policy's **deadline and grace period** settings remain active and still apply.
- Practically: the quality update policy decides *whether/when* an update becomes available; the Update ring policy still shapes *how long the device has to comply* once it is.

**Step 2 — Confirm via the Quality update status report**
The **Applied policy** column shows the effective policy Intune is honoring for that device — use this rather than inferring from configuration alone.

**Step 3 — Recommend consolidation if this is a recurring source of confusion**
For steady-state environments, moving fully to cloud-based quality update policies (retiring the parallel legacy Update ring assignment for the same devices) removes this class of ambiguity going forward — note as a follow-up recommendation, not an emergency fix.

**Rollback:** N/A — this is a design/precedence clarification, not a fault requiring reversal.

</details>

---

## Escalation Evidence

```
TICKET ESCALATION — Windows Autopatch Quality Update Policy Issue
=====================================================================
Tenant:                     [tenant name / domain]
Device name:                [device name]
Policy name:                [quality update policy name]
Release/category affected:  [Monthly security / Monthly non-security / OOB security / OOB non-security / .NET Framework]
Issue type:                 [Not deploying / Unexpected restart / Pause not taking effect / Wrong compliance date / Policy edit blocked / Ring conflict]
First observed:             [date/time]

Approval method for category: [Automatic / Manual]
Deferral period (if Automatic): [N days]
Release approval state:      [Approved / Needs review / Paused]
Hotpatch enabled on policy:  [Yes/No]
Device on legacy Update ring too: [Yes/No]
Applied policy (per report): [policy name from Quality update status report]

Target compliance date:      [from report]
Target release:               [from report]
Installed release:            [from report]

Actions taken so far:
  □ Confirmed policy type governing the device (cloud-based vs. legacy ring)
  □ Checked per-category approval method and deferral
  □ Checked release approval/pause state
  □ Confirmed elapsed time against 8h pause/resume propagation window
  □ Pulled Quality update status report for the device
  □ [Other]

Next recommended action: [your assessment]
```

---

## 🎓 Learning Pointers

- **This is a new policy object, not a new setting inside Windows Autopatch's existing ring model.** The cloud-based quality update policy (Intune admin center → Manage updates → Windows updates → Quality updates) governs *approval, deferral, and pause* — a materially different control surface than the ring-based staggered-rollout-with-automatic-incident-pause behavior already documented in `Autopatch-A/B.md`. Both can apply to the same device simultaneously; know which one a given ticket is actually about. MS Docs: [Windows quality updates and .NET Framework updates](https://learn.microsoft.com/en-us/windows/deployment/windows-autopatch/manage/windows-autopatch-windows-quality-update-overview)

- **Defaults are asymmetric by design, and this is the single most common "why didn't it deploy" ticket.** Only monthly security updates default to Automatic approval — non-security preview, out-of-band security, and out-of-band non-security releases all default to **Manual**, even within a policy an admin thinks of as "the automatic one." Check each category independently before assuming a gap is a fault.

- **Pause never rolls back.** It only stops *new* devices from receiving a release — devices that already installed it stay as they are. Set this expectation with clients immediately; "pause" and "rollback" are not the same action, and no rollback action exists here.

- **The approval method is immutable once a policy is created.** There is no in-place toggle between Automatic and Manual for an existing policy — changing approach always means creating a new policy and reassigning devices, which has its own transition-window considerations (Fix 6).

- **.NET Framework updates ride the same policy, but with real platform-version caveats.** The quality update policy's approval/deferral settings apply to .NET Framework updates too, but only for Windows 11 devices — Windows 10 ESU devices keep receiving .NET Framework updates via legacy client-side settings regardless of this policy, and .NET Framework 3.5 updates are never managed through this workflow at all (standalone, client-governed).

- **Hotpatch and non-security-update approval actively conflict, not just coexist.** Approving non-security updates on a hotpatch-enabled policy silently pulls the device off the hotpatch path for that cycle rather than layering on top of it — a common source of "why did this hotpatch device suddenly need a full restart" escalations. Cross-reference `Hotpatch-A.md` when this interaction is in play.
