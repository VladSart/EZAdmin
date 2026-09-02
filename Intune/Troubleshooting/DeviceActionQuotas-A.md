# Intune Device Action Daily Quotas (Wipe / Retire / Delete) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

> **Source confidence:** built from a live fetch of Microsoft's own current Learn pages for [Wipe devices with Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-management/actions/wipe) (`ms.date` 2026-08-21), [Device action: Retire](https://learn.microsoft.com/en-us/intune/device-management/actions/retire) (`ms.date` 2026-08-06, `updated_at` 2026-08-18), and [Device action: Delete](https://learn.microsoft.com/en-us/intune/device-management/actions/delete) (`ms.date` 2026-08-06, `updated_at` 2026-08-18). All three pages are current, GA, non-preview documentation — the daily quota figures and cascade behavior below are stated as flat facts on each respective page, not flagged as subject to change.

---
## Skim Index (with jump links)
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

This runbook covers the tenant-wide daily submission quotas governing three Intune remote device actions — **Wipe**, **Retire**, and **Delete** — and the cascade relationship between them. It does not cover other remote actions (Lock, Locate, Sync, Restart, etc.), which are not subject to these same documented caps, nor does it cover the mechanics of *why* a specific device action fails for reasons unrelated to quota (device offline, missing role permission, unsupported platform) — see the standard device-action troubleshooting path for those.

Applies to all Intune-managed platforms; the specific action triggered by Delete varies by platform and Android enrollment type (covered in full below). Assumes an account holding at minimum the Help Desk Operator role (Wipe/Retire) or School Administrator/Endpoint Security Manager role (Delete), or an equivalent custom role.

---
## How It Works

<details><summary>Full architecture</summary>

Each of the three actions carries its own independent daily cap, enforced tenant-wide (not per-admin, not per-device-group):

| Action | Daily cap | Scope |
|---|---|---|
| Wipe | 500/day | Tenant-wide |
| Retire | 1,000/day | Tenant-wide |
| Delete | 1,000/day | Tenant-wide |

Each cap is **cumulative across every submission surface** for that action type — a single-device action from the device overview pane, a bulk device action from the bulk actions pane, and a Microsoft Graph API call (interactive script, RMM integration, scheduled automation) all draw from the exact same daily pool. There is no separate, larger allowance for programmatic/API-driven submissions. Microsoft's own guidance for organizations that need a higher limit is to contact Microsoft support and request a limit change — there is no self-service increase mechanism.

**Delete is not a fourth independent action with its own isolated effect.** Delete is better understood as a wrapper: it always triggers either a Retire or a Wipe command underneath, and which one depends on platform and, for Android specifically, enrollment type:

| Platform | Enrollment type | Underlying command triggered |
|---|---|---|
| Windows | Any | Retire |
| Apple mobile (iOS/iPadOS) | Any | Retire |
| macOS | Any | Retire |
| Android | Device administrator | Retire |
| Android | Personally-owned work profile (BYOD) | Retire |
| Android | Corporate-owned fully managed (COBO) | Wipe |
| Android | Corporate-owned dedicated (COSU) | Wipe |
| Android | Corporate-owned work profile (COPE) | Wipe |
| Android | Open Source Project (AOSP) | Wipe |

Critically, Microsoft's documentation is explicit that "the Delete limit applies to Delete requests even when deleting a device triggers a Retire or Wipe command" — meaning a Delete action against a corporate-owned Android device consumes quota from **both** the 1,000/day Delete pool **and** the much smaller 500/day Wipe pool simultaneously. A bulk decommissioning project targeting several hundred corporate-owned Android devices with the Delete action can exhaust the Wipe quota well before it comes close to the Delete quota, and the failure will present as a Wipe-quota block even though the admin only ever clicked Delete.

A second, architecturally separate safeguard applies specifically to Microsoft Entra joined devices protected by BitLocker: deleting or retiring the Intune object for such a device triggers a sync that removes the device's BitLocker key protectors, which **suspends BitLocker on the OS volume**. This is deliberate defense-in-depth — Microsoft's stated rationale is preventing an unrecoverable-encryption scenario in cases where the Entra device object itself is being removed. It is not a quota-related mechanism and has no daily cap of its own, but it fires on the same two actions (Delete, Retire) covered by this topic and is easy to conflate with a quota-triggered failure if the recovery-key impact isn't anticipated ahead of time.

</details>

---
## Dependency Stack

```
Layer 3: Cross-cutting safeguards (independent of quota)
         BitLocker key-protector removal + suspension on Delete/Retire of an
         Entra-joined, BitLocker-protected device (no cap, always applies)
         Multiple Administrative Approval (MAA), if configured via access policy
         (gates execution, does not consume quota until approved)
Layer 2: Action-specific daily quota (tenant-wide, resets at UTC day boundary)
         Wipe:   500/day
         Retire: 1,000/day
         Delete: 1,000/day (ALSO draws from Wipe or Retire quota per the
                  platform/enrollment cascade table above)
Layer 1: Submission surface (all surfaces share Layer 2's pool per action type)
         Admin center — single-device action
         Admin center — bulk device action
         Microsoft Graph API (interactive scripts, RMM, scheduled automation)
Layer 0: Prerequisite device/role state
         Device platform supports the requested action (see each action's
         platform requirements table)
         Admin role holds the specific Remote tasks permission for the action
         (Wipe, Retire) or Managed devices/Delete (Delete)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Large bulk Wipe/Retire/Delete job stops issuing new actions partway through, no per-device error | Daily tenant quota reached for that action type | Device actions report, same-day (UTC) totals for the action type across all sources |
| Corporate-owned Android bulk Delete stalls sooner than expected | Delete cascaded into Wipe, and the much smaller Wipe quota (500/day) was exhausted first | Confirm enrollment type (COBO/COSU/COPE/AOSP) and check Wipe-specific same-day totals |
| Automation script's device actions start failing mid-run with no code change | Interactive admins consumed shared quota earlier the same day | Check total same-day submissions across UI + bulk + Graph, not just the automation's own count |
| Device shows BitLocker suspended shortly after a Delete/Retire action | Documented Entra-joined + BitLocker safeguard, not a quota or error condition | Confirm device was Entra joined and BitLocker-protected; this is expected behavior |
| Action appears "stuck" rather than failed | Likely Multiple Administrative Approval (MAA) pending a second admin, not a quota block | Check Action center for pending-approval status |
| Single device action fails immediately with a permissions-style error, unrelated to volume | Role/permission gap, not quota | Confirm the executing account holds the specific Remote tasks permission for that action |

---
## Validation Steps

1. **Confirm the failure pattern matches quota rather than a per-device issue.**
   Good: a batch operation that stops producing new successful/pending actions after a specific volume threshold, with no distinguishing per-device error. Bad (not quota): a single device consistently failing regardless of when it's retried, or an error referencing role/permission/connectivity specifically.

2. **Reconstruct same-day (UTC) volume for the action type from all sources.**
   ```powershell
   $report = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceManagement/reports/getDeviceActionReport" -Body (@{} | ConvertTo-Json)
   $report
   ```
   Good: a volume figure well under the documented cap for the action type. Bad: a figure at or near 500 (Wipe) or 1,000 (Retire/Delete) coinciding with when the batch stalled.

3. **For Delete specifically, confirm the underlying cascade command by platform/enrollment type.**
   Cross-reference the affected devices' platform and, for Android, enrollment type against the cascade table above. A corporate-owned Android batch should be evaluated against BOTH the Delete and Wipe quotas, not Delete alone.

4. **For Entra-joined BitLocker-protected devices, confirm recovery-key escrow state independently of the quota question.**
   ```powershell
   Get-MgInformationProtectionBitlockerRecoveryKey -Filter "deviceId eq '<entra-device-object-id>'"
   ```
   Good: a recovery key is present and was captured before the Delete/Retire action. Bad: no escrowed key and the device is no longer accessible — treat as a data-recovery risk independent of the quota investigation.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Separate quota from every other failure mode first.** Quota failures have a distinctive volume-threshold signature (batch stops cleanly partway through, no per-device error text). Anything else — a specific error message, a single consistently-failing device, an obviously offline device — is not this topic; redirect to standard device-action troubleshooting.

**Phase 2 — Identify which of the three quotas was actually exhausted.** Don't assume the quota matching the action an admin clicked is the one that was hit — for Android corporate-owned Delete, the Wipe quota is frequently the binding constraint, not the Delete quota, because Delete draws from both simultaneously.

**Phase 3 — Establish full same-day submission visibility.** Quota is shared tenant-wide across UI, bulk, and Graph submissions. A troubleshooting session that only checks "did my script hit quota" while ignoring interactive admin activity that day will reach the wrong conclusion. Pull the full day's Device actions report before ruling anything in or out.

**Phase 4 — Handle the BitLocker safeguard as a separate track, not a quota symptom.** If the affected devices were Entra-joined and BitLocker-protected, treat recovery-key escrow verification as its own workstream in parallel with the quota investigation — conflating the two delays getting ahead of a genuine data-access risk.

**Phase 5 — Plan future large-volume operations around the caps, not around retries.** Once quota is confirmed as root cause, the fix is scheduling/batching discipline, not repeated resubmission attempts — repeated attempts against an exhausted daily pool will simply continue to fail until the UTC day boundary resets it.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Large-scale device decommissioning/offboarding project</summary>

1. Inventory the full target device list up front, broken out by platform and (for Android) enrollment type, so the Delete→Wipe/Retire cascade can be modeled before execution rather than discovered mid-run.
2. For any batch approaching 400+ Wipe-equivalent actions (including cascaded Deletes against corporate-owned Android) or 800+ Retire/Delete-equivalent actions in a single day, split execution across multiple UTC days rather than attempting it in one run.
3. Before issuing Delete or Retire against any Entra-joined, BitLocker-protected device in the batch, confirm and archive the BitLocker recovery key and local admin credentials for that device.
4. Coordinate timing with other tenant admins and any scheduled automation to avoid unknowingly sharing the same day's quota pool across unrelated initiatives.
5. Monitor the Device actions report throughout execution rather than only checking at the end, so a quota-driven stall is caught early rather than after an entire overnight run silently stopped partway through.

No rollback needed for the quota mechanism itself — it is a submission gate, not a destructive action; devices not yet actioned remain in their prior state.

</details>

<details><summary>Playbook 2 — Recurring operational need that regularly approaches or exceeds the documented caps</summary>

1. Confirm the caps are genuinely the binding constraint over a representative period (not, e.g., a one-time migration project that doesn't recur).
2. Document actual sustained daily volume needs with supporting data from the Device actions report.
3. Contact Microsoft support to request a tenant-specific limit change — this is the only supported path to a higher cap; there is no tenant setting or Graph parameter that raises it.
4. Until any limit change is granted, treat the documented caps as a hard operational constraint for recurring scheduling purposes, not a soft guideline.

Rollback: not applicable — this is a support-request process, not a configuration change with a rollback path.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects same-day device-action volume and BitLocker escrow evidence to support
    an Intune device-action-quota escalation.
#>
param(
    [datetime]$Date = (Get-Date).ToUniversalTime().Date
)

$report = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceManagement/reports/getDeviceActionReport" -Body (@{} | ConvertTo-Json)

$managedDevices = Get-MgDeviceManagementManagedDevice -All
$androidCorporate = $managedDevices | Where-Object {
    $_.OperatingSystem -eq "Android" -and $_.ManagedDeviceOwnerType -eq "company"
}

[PSCustomObject]@{
    ReportPulledAtUtc          = (Get-Date).ToUniversalTime()
    TargetDateUtc               = $Date
    RawDeviceActionReport       = $report
    AndroidCorporateOwnedCount  = $androidCorporate.Count
    AndroidCorporateOwnedNote   = "Delete against these devices also consumes the 500/day Wipe quota, not just the 1,000/day Delete quota."
} | ConvertTo-Json -Depth 6
```

---
## Command Cheat Sheet

```powershell
# Device action report (closest available signal to same-day quota consumption)
Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceManagement/reports/getDeviceActionReport" -Body (@{} | ConvertTo-Json)

# Single managed device's action results
Get-MgDeviceManagementManagedDevice -ManagedDeviceId "<device-object-id>" | Select-Object DeviceName, ManagementState, DeviceActionResults

# BitLocker recovery key lookup for an Entra device (verify escrow BEFORE Delete/Retire)
Get-MgInformationProtectionBitlockerRecoveryKey -Filter "deviceId eq '<entra-device-object-id>'"

# List all Android managed devices with owner type, to identify Delete→Wipe cascade candidates
Get-MgDeviceManagementManagedDevice -Filter "operatingSystem eq 'Android'" -All | Select-Object DeviceName, ManagedDeviceOwnerType, AndroidSecurityPatchLevel

# Wipe a device (consumes Wipe quota)
Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/<device-id>/wipe" -Body (@{} | ConvertTo-Json)

# Retire a device (consumes Retire quota)
Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/<device-id>/retire" -Body (@{} | ConvertTo-Json)

# Delete a device (consumes Delete quota, cascades to Retire or Wipe depending on platform/enrollment)
Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/<device-id>"
```

---
## 🎓 Learning Pointers

- The three caps — 500 Wipe/day, 1,000 Retire/day, 1,000 Delete/day — are tenant-wide and shared across every submission surface (UI, bulk, Graph). There is no per-admin, per-device-group, or API-specific allowance. See the "Important" callout on each Learn page: [Wipe](https://learn.microsoft.com/en-us/intune/device-management/actions/wipe), [Retire](https://learn.microsoft.com/en-us/intune/device-management/actions/retire), [Delete](https://learn.microsoft.com/en-us/intune/device-management/actions/delete).
- **Delete always cascades into Retire or Wipe underneath**, and the Delete quota is consumed *in addition to*, not instead of, the underlying action's own quota. For corporate-owned Android (COBO/COSU/COPE/AOSP), that underlying action is Wipe — the smallest of the three pools — making large corporate-owned Android decommissioning projects the scenario most likely to hit a quota wall unexpectedly.
- BitLocker key-protector removal on Delete/Retire of an Entra-joined, BitLocker-protected device is unrelated to the quota mechanism entirely — it's a standing safeguard with no daily cap that fires every time, and the operational fix is capturing the recovery key beforehand, not anything quota-related.
- There is no self-service quota increase — the only documented path is contacting Microsoft support to request a limit change. Design recurring large-volume operations around the documented caps rather than assuming they can be raised on demand.
- Multiple Administrative Approval, where configured, is orthogonal to this topic: it gates *when* an action executes, not *how much* quota it consumes, and a pending-approval action does not count against the daily total until it actually runs.
- No dedicated PowerShell cmdlet or Graph endpoint reports "quota remaining" for any of these three actions — the practical mitigation is proactively tracking same-day volume via the Device actions report rather than expecting a hard programmatic pre-check.
