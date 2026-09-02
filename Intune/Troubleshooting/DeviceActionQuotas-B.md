# Intune Device Action Daily Quotas (Wipe / Retire / Delete) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

A bulk offboarding, decommissioning, or Autopilot-reset project suddenly stops issuing Wipe/Retire/Delete actions mid-run, or individual admins report an action "did nothing." Before assuming a permissions or connectivity fault, rule the daily tenant quota in or out first.

```powershell
# 1. Confirm Graph connection
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.ReadWrite.All"

# 2. Check the device action report for a burst of failed/blocked actions in the last 24h
$report = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/beta/deviceManagement/reports/getDeviceActionReport" -Body (@{} | ConvertTo-Json)
$report

# 3. Pull recent device management action results for the affected device(s)
Get-MgDeviceManagementManagedDevice -ManagedDeviceId "<device-object-id>" |
    Select-Object DeviceName, ManagementState, DeviceActionResults

# 4. If actions were issued via Graph/automation, check the HTTP response for a 429/403 with a quota-specific error body
# (Intune returns a normal API error, not a distinct "quota" status code — the error message text is the signal)
```

| Result | Interpretation |
|---|---|
| Actions submitted today for this action type (Wipe/Retire/Delete) across UI + bulk + Graph total ≥ 500 (Wipe) or ≥ 1,000 (Retire/Delete) | **Daily tenant quota hit.** Not a bug, not a permissions issue — go to [Common Fix Paths](#common-fix-paths). |
| A single device's action shows `Failed` with a normal error, well under quota | Not this issue — troubleshoot as a standard device-action failure (device offline, MAA pending, etc.). |
| Bulk job stopped partway through a large batch (e.g. 600+ devices queued for Wipe in one run) | Very likely quota — the cap applies **per action type, per day, tenant-wide**, cumulative across every submission surface. |
| `Delete` action requested but the device was Entra-joined and BitLocker-protected, and now shows a suspended/interrupted encryption state | Expected safeguard behavior, not a bug — see the Dependency Cascade and Fix 3 below. |
| Automation/script issuing Graph `wipe`/`retire`/`cleanWindowsDevice` calls returns errors that scale with volume, not with any single device | Automation is very likely the thing tripping the shared quota — check whether interactive admins used the same action type today too. |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Tenant-wide daily quota (resets daily, UTC)
    ├── Wipe:   500 actions/day
    ├── Retire: 1,000 actions/day
    └── Delete: 1,000 actions/day
            └── Cumulative across ALL submission surfaces for that action type:
                    ├── Single-device action (admin center device page)
                    ├── Bulk device action (admin center bulk pane)
                    └── Microsoft Graph API requests (scripts, RMM, automation)
                            └── Quota is shared — an automation script and an
                                    interactive admin draw from the SAME daily pool
                                    └── Delete action triggers a cascade, NOT a
                                            fourth independent quota:
                                            ├── Windows / Apple mobile / macOS / Android
                                            │   (Device Admin, BYOD work profile)
                                            │       → Delete counts against the
                                            │         Delete quota AND issues a Retire
                                            │         command underneath
                                            └── Android (COBO / COSU / COPE / AOSP)
                                                    → Delete counts against the
                                                      Delete quota AND issues a Wipe
                                                      command underneath
                                                      (a large Android COBO delete
                                                      batch can burn BOTH the Delete
                                                      and Wipe daily pools at once)
    └── Independently, for Entra-joined + BitLocker-protected devices:
            Delete or Retire the Intune object
                └── Intune triggers a sync that removes BitLocker key protectors
                        └── BitLocker suspended on the OS volume (safeguard against
                                unrecoverable encryption if the Entra device object
                                is gone) — back up the recovery key BEFORE issuing
                                the action, not after
    └── Independently, per-action:
            Intune access policy may require Multiple Administrative Approval (MAA)
                └── Action sits in a pending-approval state until a second admin
                        approves — this is NOT the same failure mode as a quota hit
                        and does not consume the daily quota until approved and executed
```

</details>

---
## Diagnosis & Validation Flow

1. **Establish whether this is quota, MAA, or a genuine per-device failure.**
   Check the device's own action result first (Diagnosis Triage step 3). A per-device `Failed` with a specific error is not quota. A batch that silently stops issuing new actions partway through, with no per-device error, is the quota signature.

2. **Count today's submissions for the action type in question.**
   There is no dedicated Graph report that returns "quota remaining" — reconstruct the day's volume from the [Device actions report](https://learn.microsoft.com/en-us/intune/device-management/reports/overview#device-actions-report) filtered to today (UTC) and the specific action type, counting UI, bulk, and Graph-originated actions together.
   Expected: if the running total is near or over 500 (Wipe) / 1,000 (Retire, Delete), treat quota as the leading hypothesis.

3. **Check for MAA gating on the same action type.**
   ```powershell
   Get-MgDeviceManagementRoleAssignment | Where-Object { $_.RoleScopeTagIds } # cross-reference against configured access policies in the portal
   ```
   MAA-pending actions show as awaiting approval in the Action center, not as failed or silently dropped — a materially different symptom from a quota block.

4. **If Delete was used, confirm which underlying command actually fired.**
   For Windows/Apple mobile/macOS/any non-corporate-owned Android enrollment, Delete always issues Retire underneath. For Android COBO/COSU/COPE/AOSP, Delete issues Wipe underneath. A large Android corporate-owned delete batch can exhaust the Wipe quota (500/day) far faster than the Delete quota (1,000/day) — check which quota actually blocked the batch.

5. **For BitLocker-protected Entra-joined devices, confirm recovery key was captured before assuming data loss risk.**
   If Delete/Retire was issued without first exporting the BitLocker recovery key and local admin credentials, treat this as a genuine incident risk, not just a quota question — see Fix 3.

---
## Common Fix Paths

<details><summary>Fix 1 — Bulk job hit the daily quota mid-run</summary>

1. Stop the automation/bulk job immediately rather than letting it continue retrying and generating noise.
2. Wait for the daily reset (quota resets at UTC day boundary, not a rolling 24h window from your first action).
3. Resume the job the next day, ideally spacing large batches across multiple days rather than a single run for anything approaching 400-500 Wipes or 800-1,000 Retires/Deletes in one project.
4. If this is a recurring operational need (e.g. a large device-refresh cycle), request a limit change via Microsoft support rather than working around it with multiple tenants or timing tricks.

Rollback: not applicable — no destructive action was taken beyond the quota's own limit; devices not yet actioned remain untouched.

</details>

<details><summary>Fix 2 — Need to know how much quota is left before running a large batch today</summary>

There is no supported API to read remaining quota directly. Practical mitigation:

1. Before a planned large batch, check the Device actions report for the current day's volume of the same action type from all sources (UI + bulk + Graph).
2. Subtract from the documented cap (500 Wipe / 1,000 Retire / 1,000 Delete) to estimate headroom.
3. Batch conservatively — leave margin for any other admin or scheduled automation drawing from the same tenant-wide pool that day.

Rollback: not applicable — this is a planning step, not a change.

</details>

<details><summary>Fix 3 — BitLocker suspended after Delete/Retire on an Entra-joined device, recovery key wasn't captured first</summary>

1. Check whether the BitLocker recovery key was already escrowed to Entra ID/Intune before the action — if the device previously reported its key, it's usually still recoverable from the Entra device's BitLocker keys blade even after the object triggers removal, but confirm this per device rather than assuming.
2. If the key is not recoverable and the device is still physically accessible and bootable, capture the key locally before any further reset action:
   ```powershell
   # Run ON the device itself before further action, if still accessible
   manage-bde -protectors -get C:
   ```
3. Going forward, add a mandatory pre-action step to offboarding runbooks/automation: export and archive the BitLocker recovery key and local admin credentials BEFORE issuing Delete or Retire against any Entra-joined, BitLocker-protected device.

Rollback: not applicable to the suspension itself (it's a safeguard, not an error) — the risk is losing access to encrypted data if no key was captured beforehand; there is no way to "undo" a missing key after the fact.

</details>

<details><summary>Fix 4 — Automation and interactive admins are silently competing for the same daily quota</summary>

1. Identify every source issuing Wipe/Retire/Delete actions against this tenant — scheduled automation, RMM integrations, help desk staff using the admin center, and any Graph-based scripts.
2. Consolidate large-volume operations (bulk offboarding, device refresh cycles) into a single scheduled, quota-aware process rather than letting multiple uncoordinated sources compete for the same pool.
3. If MAA is configured for these action types, remember pending-approval actions do not consume quota until approved — a large pending backlog approved all at once can still spike same-day consumption unexpectedly.

Rollback: not applicable — this is a process/coordination fix.

</details>

---
## Escalation Evidence

```
=== Intune Device Action Quota — Escalation Template ===
Tenant ID:                                   <fill in>
Action type affected (Wipe/Retire/Delete):   <fill in>
Approx. count of this action type submitted today (UTC), all sources combined: <fill in>
Submission source(s) involved (UI/bulk/Graph/automation): <fill in>
First device/action that appeared to fail or stop being issued: <fill in>
Exact error text returned (if any):          <fill in>
Was this a corporate-owned Android batch (Delete→Wipe cascade)?: <yes/no>
BitLocker recovery key captured before Delete/Retire on affected Entra-joined devices?: <yes/no/unsure>
Business impact (project blocked, devices left in indeterminate state): <fill in>
Requested next step:                         <limit-increase request / scheduling guidance / key-recovery escalation>
```

---
## 🎓 Learning Pointers

- The daily cap is per **action type**, tenant-wide, and cumulative across every submission surface — the admin center UI, the bulk actions pane, and Microsoft Graph API calls all draw from the same pool. There is no separate, larger quota for automation. See [Wipe devices with Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-management/actions/wipe), [Device action: Retire](https://learn.microsoft.com/en-us/intune/device-management/actions/retire), and [Device action: Delete](https://learn.microsoft.com/en-us/intune/device-management/actions/delete).
- **Delete is not a fourth independent action** — it always triggers Retire or Wipe underneath depending on platform/enrollment type, and a Delete request counts against the Delete quota "even when deleting a device triggers a Retire or Wipe command." A large Android corporate-owned Delete batch can exhaust the smaller 500/day Wipe pool well before the 1,000/day Delete pool.
- BitLocker key-protector removal on Delete/Retire of an Entra-joined device is a **documented safeguard**, not a bug — it prevents an unrecoverable-encryption scenario if the Entra device object disappears. Capture the recovery key and local admin credentials *before* issuing the action, not after.
- Multiple Administrative Approval (MAA), where configured, is an entirely separate gate from the quota — a pending-approval action doesn't fail and doesn't consume quota until it executes. Don't conflate an MAA-pending backlog with a quota block when triaging.
- There's no supported API or report that returns "quota remaining" directly — plan large batches around the Device actions report's same-day totals rather than expecting a hard programmatic check.
- Related but distinct: `Intune/Troubleshooting/MultiAdminApproval-A.md`/`-B.md` (the approval gate itself).
