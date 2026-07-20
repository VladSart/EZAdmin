# macOS Recovery Lock — Hotfix Runbook (Mode B: Ops)
> Fix or escalate Recovery Lock issues in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

Recovery Lock is an **Intune-side (Graph/portal) feature, not a local one** — there is no `fdesetup`-style CLI command on the Mac itself that reports or clears it. Triage happens almost entirely in the Intune admin center. Run these first:

```
# 1. Confirm the device is even eligible (do this BEFORE assuming the policy is broken)
Intune admin center → Devices → All devices → <device> → Hardware
# Expected: Processor architecture / model indicates Apple Silicon (M1/M2/M3/M4 family)
# Bad: Intel model (e.g. MacBookPro16,x and earlier Intel-chip models) → Recovery Lock is
#      NOT SUPPORTED on Intel Macs. No error is shown anywhere — the policy just never applies.

# 2. Confirm supervision status
Intune admin center → Devices → All devices → <device> → Properties
# Expected: "Supervised: Yes" (only true for ADE/Automated Device Enrollment devices)
# Bad: Supervised: No → policy silently does nothing. Common on BYOD / Company-Portal-enrolled Macs.

# 3. Confirm the Settings Catalog policy is actually assigned and succeeded
Intune admin center → Devices → Configuration → <your Recovery Lock policy> → Device status
# Expected: Succeeded for the device in question
# Bad: Pending / Error / Not applicable → see Fix 1

# 4. Check per-setting status for the actual password value
Intune admin center → Reports → Device management → Per setting status report
  → filter to the Recovery Lock Password setting → select device → "Passwords and keys"
# Expected: A password value is present with a recent "last updated" timestamp
# Bad: No password shown → policy hasn't successfully applied yet, or device hasn't checked in

# 5. Confirm you (the admin) have the right RBAC permissions for the ACTION (not just the policy)
Intune admin center → Tenant administration → Roles → <your role> → Permissions
# Look for: Remote tasks / Rotate macOS Recovery Lock password
#           Remote tasks / View macOS recovery lock password
# Bad: Missing either permission → "Rotate Recovery Lock Passcode" action is greyed out or fails
```

**Interpretation table:**

| Finding | Action |
|---|---|
| Device is an Intel Mac | Stop — not supported. Do not troubleshoot further; document as out of scope. |
| Device is Apple Silicon but not supervised | Not fixable in place → Fix 2 (re-enrollment via ADE required) |
| Apple Silicon + supervised, but policy status = Error/Not applicable | Fix 1 (assignment/scope issue) |
| Policy succeeded, but no password showing in report | Fix 3 (device hasn't checked in / report lag) |
| Need the current passcode right now (user stuck at Recovery) | Fix 4 (retrieve from portal — there is no local recovery) |
| Rotated the passcode but the old one still worked at the Mac | Fix 5 (expected — device hadn't checked in yet, not a bug) |
| Device is being unenrolled/retired and will go offline for a long time | Fix 6 (retrieve/clear passcode BEFORE removal — read this before you decommission anything) |
| Rotate action greyed out or errors for you specifically | Fix 7 (your admin role is missing the remote-task permission) |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Apple Silicon chip (M1 or later) — hard hardware requirement
        │
        ▼
macOS 11.5+ AND device is MDM-supervised
   (supervision = ADE/Automated Device Enrollment only —
    Company Portal / user-initiated enrollment can NEVER be supervised)
        │
        ▼
Settings Catalog profile: "Recovery Lock Password" category
   ├── Enable Recovery Lock Password = Enabled
   └── Recovery Lock Password Rotation Schedule = 1–12 months
        │
        ▼
Profile assigned to a group containing the device, AND device checks in
        │
        ▼
Intune generates a strong random password, pushes it to recoveryOS,
   stores it centrally (Passwords and keys / Per setting status report)
        │
        ▼
Password required to: boot into recoveryOS, access Startup Options,
   change the Recovery Lock password itself
        │
   (admin needs "Rotate"/"View" RBAC permissions to read or rotate it later)
```

**Key concept — no local escape hatch:** unlike the old Intel-era EFI firmware password (which had known local bypass procedures involving RAM/logic-board changes), Apple Silicon's Recovery Lock has **no supported local reset path**. If the password is lost and Intune can't supply it (tenant access lost, device never checked in after a policy change, etc.), the only outcome is contacting Apple Support with proof of purchase — there is no MSP-side workaround. This is the single most important thing to communicate to a customer before enabling this feature.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Confirm hardware eligibility**
```
Intune → Devices → <device> → Hardware → check model / chip
```
Intel Mac → stop here, feature not supported, no further diagnosis needed.

**Step 2 — Confirm supervision**
```
Intune → Devices → <device> → Properties → Supervised: Yes/No
```
`No` → the device was not enrolled via ADE. Recovery Lock cannot be applied without re-enrolling through Apple Business/Automated Device Enrollment.

**Step 3 — Confirm policy assignment and processing status**
```
Intune → Devices → Configuration → <policy> → Device status tab
```
Look specifically at this device's row: `Succeeded`, `Pending`, `Error`, or `Not applicable`.
- `Not applicable` almost always means the hardware/supervision checks above failed silently.
- `Error` → open the row for the specific error code; usually a conflicting profile (see Fix 1).

**Step 4 — Confirm the password itself is available**
```
Intune → Reports → Device management → Per setting status report
   → filter setting to "Recovery Lock Password" → locate device
   → open "Passwords and keys" to reveal the value
```
No value present with `Succeeded` policy status → device applied the config but hasn't reported the actual passcode value back yet (this can lag — see Fix 3).

**Step 5 — Confirm rotation history if relevant**
```
Intune → Devices → <device> → device action history (Rotate Recovery Lock Passcode entries)
```
Confirms whether a rotation was actually triggered and whether it completed (applies at next successful check-in only).

---

## Common Fix Paths

<details><summary>Fix 1 — Policy shows Error / Not applicable on an eligible device</summary>

**Cause:** Usually a conflicting configuration profile targeting the same setting, or the device group assignment doesn't actually include this device (nested group / dynamic group evaluation lag).

```
# 1. Check for a second Recovery Lock (or any firmware/startup security) profile targeting the same device
Intune → Devices → Configuration → filter by platform macOS → look for duplicate Recovery Lock policies

# 2. Confirm the assignment group membership is current
Intune → Groups → <assigned group> → Members → search for the device/user
# For dynamic groups, check Entra ID → Groups → <group> → Dynamic membership rules → Validate rules

# 3. Force a device check-in rather than waiting for the ~8hr default cycle
Intune → Devices → <device> → Sync
```

**Rollback:** N/A — read-only diagnostic and a sync request; no destructive action.

</details>

<details><summary>Fix 2 — Device is Apple Silicon but not supervised</summary>

**Cause:** The Mac was enrolled via Company Portal (user-initiated) rather than Automated Device Enrollment (ADE) through Apple Business. Supervision is a one-way state set only at enrollment time — you cannot "upgrade" an unsupervised device to supervised without wiping and re-enrolling it.

```
# There is no in-place fix. The remediation is:
# 1. Confirm the device is (or can be) assigned to a DEP/ADE profile in Apple Business
# 2. Back up user data
# 3. Wipe the device (Intune → Devices → <device> → Wipe, or erase locally in Recovery)
# 4. Re-enroll via Setup Assistant so it picks up the ADE profile → device enrolls supervised
# 5. Re-apply the Recovery Lock Settings Catalog policy
```

**Rollback:** N/A — this is itself the remediation, not a reversible action. Communicate the data-loss/downtime impact to the customer before proceeding.

</details>

<details><summary>Fix 3 — Policy succeeded but no password shown in the report</summary>

**Cause:** Reporting lag between the device applying the configuration and Intune's back-end reflecting the actual passcode value in the Per setting status report.

```
# 1. Wait 15-30 minutes and re-check the Per setting status report
# 2. Force another device sync to accelerate reporting:
Intune → Devices → <device> → Sync
# 3. If still empty after an hour, check the device's own configuration profile list was actually
#    delivered (this is one of the few things you CAN check locally, even though the password isn't
#    locally readable):
sudo profiles -P | grep -i "recovery"
```

**Rollback:** N/A — no changes made.

</details>

<details><summary>Fix 4 — User is stuck at the Recovery Lock prompt and needs the passcode NOW</summary>

**Cause:** User (or a tech) booted into recoveryOS / Startup Options and is being prompted for the Recovery Lock password. There is no local bypass.

```
# Retrieve the current passcode from the Intune admin center:
Intune → Devices → <device> → Passwords and keys → View Recovery Lock Passcode
# (Requires the "Remote tasks / View macOS recovery lock password" permission — see Fix 7 if you
#  can't see this option.)
```

Give the retrieved passcode to whoever is standing at the Mac. There is no CLI, no reset disk utility,
and no Apple Configurator workaround for a Recovery Lock passcode on a supervised, enrolled device.

**Rollback:** N/A — read-only retrieval.

</details>

<details><summary>Fix 5 — Rotated the passcode but the old one still worked at the device</summary>

**Cause — this is expected behaviour, not a bug:** "The new Recovery Lock passcode is applied to the
device the next time the device successfully checks in with Intune. If the device is offline or not
checking in, the existing Recovery Lock passcode remains in effect until the device checks in."

```
# Force the device to check in before expecting the new passcode to be live:
Intune → Devices → <device> → Sync
# Then confirm the new value in Passwords and keys / Per setting status report
```

**Rollback:** N/A — informational, no action needed beyond forcing a check-in.

</details>

<details><summary>Fix 6 — Retiring/unenrolling a device that may go offline for a long time</summary>

**Cause:** Unenrolling a device from Intune automatically clears its Recovery Lock password — but
**only if the device successfully receives that instruction before it goes offline for good.**
Unassigning the policy (without unenrolling) only makes Intune *attempt* to clear the password on
next check-in — it is not guaranteed and not instant. If a device is wiped, sold, or goes permanently
offline while still holding an active Recovery Lock passcode that Intune never confirmed clearing,
**that passcode is required to ever use the recoveryOS environment again**, and it will not be
retrievable from Intune once the device record is gone.

```
# BEFORE decommissioning / long-term-offlining a Recovery-Lock-enabled Mac:
# 1. Confirm the device is online and will check in (Intune → Devices → <device> → last check-in time)
# 2. Force a sync
Intune → Devices → <device> → Sync
# 3. Either:
#    a) Unenroll/Retire the device from Intune (auto-clears Recovery Lock), THEN wipe, OR
#    b) If wiping locally first, record the current passcode from "Passwords and keys" first —
#       treat it like a BitLocker recovery key: document it in your ticketing/asset system before
#       the device leaves management
```

**Rollback:** N/A — this is a preventive checklist, not a reversible action once missed.

</details>

<details><summary>Fix 7 — Rotate/View action is greyed out or fails for your account</summary>

**Cause:** Your Intune admin role doesn't include the specific remote-task permissions this feature
requires — being an Intune Administrator normally covers this, but a **custom RBAC role** (common in
MSP delegated-admin setups) needs both permissions explicitly granted.

```
# Check/grant via:
Intune → Tenant administration → Roles → <custom role> → Properties → Permissions
# Required, separately:
#   Remote tasks / Rotate macOS Recovery Lock password
#   Remote tasks / View macOS recovery lock password
# (Configuring the underlying policy itself instead requires the Policy and Profile Manager
#  built-in role or equivalent custom permission — a different permission from the two above.)
```

**Rollback:** N/A — RBAC grant, not destructive. Follow least-privilege — grant only to techs who
actually need to view/rotate Recovery Lock passcodes.

</details>

---

## Escalation Evidence

```
ESCALATION TICKET — macOS Recovery Lock Issue
=====================================
Device Name:              [hostname]
Serial Number:            [Intune → device → Hardware → Serial number]
macOS Version:             [sw_vers -productVersion, or Intune Hardware blade]
Chip Type:                 [Apple Silicon model / Intel — from Intune Hardware blade]
Supervised:                [Yes/No — Intune → device → Properties]
Enrollment Type:           [ADE/Automated | User-enrolled/Company Portal]

Recovery Lock Policy Name: [policy name]
Policy Device Status:      [Succeeded | Pending | Error | Not applicable]
Rotation Schedule Set:     [N months]
Last Rotate Action:        [timestamp + result, from device action history]
Password Visible in Report: [Yes/No + last-updated timestamp]

Admin RBAC Role:           [role name]
Has "Rotate" permission:   [Yes/No]
Has "View" permission:     [Yes/No]

Symptom description:
[what the user/tech is seeing — stuck at prompt, action greyed out, etc.]

Steps already attempted:
[ ] Confirmed hardware eligibility (Apple Silicon)
[ ] Confirmed supervision status
[ ] Forced device sync
[ ] Checked Per setting status report
[ ] Verified own RBAC permissions
```

---

## 🎓 Learning Pointers

- **There is no local fallback — plan around that, not just around fixing it.** Recovery Lock has no supported bypass on a supervised Apple Silicon Mac. Before enabling it fleet-wide, make sure your team's off-boarding/decommission runbook always forces a sync (or explicitly retrieves the passcode) before a device is wiped or leaves management. [Configure Recovery Lock](https://learn.microsoft.com/en-us/intune/device-configuration/settings-catalog/configure-recovery-lock-macos)

- **Intel Macs fail silently, not loudly.** There's no error message telling you "this device can't have Recovery Lock" — the policy status just reports Not applicable, or nothing changes. Always check chip type first; it's the fastest possible triage step and rules out an entire class of "policy isn't working" tickets in ten seconds.

- **Supervision is a one-time, enrollment-time property.** You cannot supervise an already-unsupervised device without wiping and re-enrolling through ADE. This is the same constraint that governs Bootstrap Token availability for FileVault (see `FileVault-B.md`) — the two features share this root cause, so a device that can't get a Bootstrap Token also can't get Recovery Lock, for the identical reason.

- **RBAC for the policy and RBAC for the action are two different grants.** An admin can have full rights to create the Settings Catalog profile (Policy and Profile Manager) and still be unable to rotate or view the resulting passcode, because that requires separate "Remote tasks" permissions. This split trips up MSP delegated-admin setups more than almost any other Intune RBAC gap in this repo's experience.

- **Rotation isn't instant — it's check-in-gated, same pattern as everything else in Apple MDM.** Every "I changed it but the device still has the old value" ticket in this domain (Recovery Lock, FileVault keys, Bootstrap Token) resolves the same way: force a sync, then re-check. [Rotate Recovery Lock passcode device action](https://learn.microsoft.com/en-us/intune/device-management/actions/rotate-recovery-lock-passcode)
