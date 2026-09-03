# Android Enterprise eSIM Lifecycle Management (Corporate-Owned) — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers **Intune's eSIM lifecycle management for corporate-owned Android Enterprise devices**: SIM/eSIM hardware inventory reporting (EID, ICCID), the single-device **Activate eSIM** and **Remove eSIM** device actions, and the wipe-time **"Remove all eSIMs during a device wipe"** Settings Catalog control. This is an entirely distinct platform and management surface from Windows Connected PC eSIM bulk deployment.

**In scope:** ownership-type eligibility (COBO/COSU/COPE), Android version floors per action, the hardware-inventory prerequisite for removal, RBAC permission model, the wipe-time eSIM-preservation default, and the architectural reason Intune cannot pre-validate activation success before submission.

**Explicitly out of scope:**
- Windows Connected PC eSIM deployment (CSV activation-code import, eSIM download server/SM-DP+) — an entirely separate platform; see `eSIM-A.md`/`eSIM-B.md`.
- iOS/iPadOS eSIM management — Intune's "Update cellular data plan" action also supports iOS/iPadOS via an activation server URL, a materially different flow (bulk activation-server-URL-based, no single-device Activate/Remove/ICCID model); not covered here.
- Personally owned Android Enterprise devices with a work profile (BYOD) — unsupported for every action in this runbook, at any Android version, in any device view. No workaround exists.
- Carrier-side eSIM provisioning/business processes (obtaining activation codes, SM-DP+ contractual relationships) — covered only insofar as they're an input to the Intune-side actions.
- General cellular/APN connectivity troubleshooting once an eSIM is confirmed active — see `NetworkAdapters-A.md`.

**Assumes:** engineer has Intune Help Desk Operator or equivalent custom RBAC role, access to the new (Preview) device view, and an existing relationship with a mobile carrier supporting Android Enterprise eSIM provisioning.

---
## How It Works

<details><summary>Full architecture</summary>

Android Enterprise eSIM management in Intune is built around three independent capabilities layered on top of standard device hardware inventory:

**1. SIM/eSIM hardware inventory.** Intune reports EID (eUICC ID, the hardware chip identifier) and one or more ICCIDs (per-profile identifiers) under a device's Hardware inventory. **EID reporting requires Android 13+**; **full multi-ICCID inventory requires Android 15+** — a device below these floors may show incomplete or no eSIM hardware data even if it physically supports eSIM, which is a common false-negative when troubleshooting "why can't I see this device's eSIM." Inventory is a **reporting-only** surface — it does not itself expose an Activate or Remove control.

**2. Single-device Activate eSIM.** Available **only in the new (Preview) device view**, for corporate-owned devices (COBO/COSU/COPE) on **Android 15+ uniformly across all three ownership types**. The admin selects the device, chooses Activate eSIM, and enters a carrier-supplied activation code. Critically, **Intune sends this activation request without first checking reported eSIM slot capacity on the device** — there's no client-side or server-side pre-flight validation against how many eSIM slots are already occupied. If Google (the underlying Android Enterprise management API) can't complete the activation, Intune simply surfaces whatever error Google returns; Intune has no independent diagnostic authority beyond relaying that error. Once activated, the eSIM is downloaded and activated automatically — no further manual on-device step is expected.

**3. Single-device Remove eSIM.** Also new-device-view-only. Removal is strictly **ICCID-driven**: the admin must first locate and copy the target eSIM's ICCID from device hardware inventory, then supply that exact ICCID to the Remove eSIM action. **If the ICCID isn't already present in inventory, the removal action cannot be submitted at all** — there's no free-text carrier-lookup or slot-index-based removal path. This creates a hard ordering dependency: a device sync (to populate/refresh inventory) must happen before an admin can even attempt removal.

**The version floor for Remove is asymmetric by ownership type — this is the single most important fact in this topic:**

| Action | COBO | COSU | COPE |
|---|---|---|---|
| Activate an eSIM on one device | Android 15+ | Android 15+ | Android 15+ |
| Remove an eSIM from one device | Android 15+ | Android 15+ | **Android 17+** |

COPE (corporate-owned work profile — the "BYOD-like" corporate ownership model with a separate personal/work profile split on one device) requires a full two major Android versions ahead of COBO/COSU for the identical Remove action. Microsoft does not document a reason for this asymmetry in the public reference; treat it as a hard platform constraint rather than something to work around.

**RBAC model:** Activate and Remove are gated by **two independent permissions**, not one combined "manage eSIM" grant:
- `Remote tasks/Update cellular data plan` — required for Activate (this is the same underlying permission that also governs the iOS/iPadOS activation-server-URL flow).
- `Remote tasks/Remove eSIM` — required for Remove, specifically.

Both also require baseline device visibility permissions (Organization/Read, Managed devices/Read). A custom role can legitimately grant one without the other.

**Wipe-time behavior** is governed by a separate Settings Catalog control, **"Remove all eSIMs during a device wipe"** (Android 15+, corporate-owned). The **default, unconfigured state preserves eSIMs across a wipe** — a deliberate choice, since eSIM profiles often represent a carrier-billed asset an organization may not want silently destroyed by a routine device wipe. Enabling the setting causes all eSIMs to be removed as part of that specific wipe action; it is not a standing tenant-wide toggle independent of the wipe event itself.

**Ownership-type gate, absolute:** Android Enterprise eSIM actions (Activate, Remove, and — implicitly, since the setting only applies to corporate-owned devices — the wipe-time control) support **corporate-owned devices only**. Personally owned devices enrolled with a work profile (BYOD) are unsupported for all of it, unconditionally, regardless of Android version.

</details>

---
## Dependency Stack

```
Android Enterprise device, Intune-enrolled
    │
    └── Ownership type gate (hard, absolute)
            ├── Personally owned + work profile (BYOD) → UNSUPPORTED, full stop
            └── Corporate-owned (COBO / COSU / COPE) → proceed
                    │
                    ├── Admin: "Preview new device view" turned ON
                    │       (both single-device actions are entirely absent from the
                    │        legacy/default device view)
                    │
                    ├── Hardware inventory reporting
                    │       ├── EID reporting: Android 13+
                    │       └── Full ICCID inventory: Android 15+
                    │               (a device below these floors may show incomplete
                    │                eSIM data independent of actual hardware support)
                    │
                    ├── ACTIVATE eSIM (RBAC: Remote tasks/Update cellular data plan)
                    │       └── Android 15+ (uniform across COBO/COSU/COPE)
                    │               └── Carrier activation code supplied
                    │                       └── Intune submits WITHOUT slot-capacity
                    │                           pre-check → Google/OS-level result
                    │                           (success or relayed error)
                    │
                    ├── REMOVE eSIM (RBAC: Remote tasks/Remove eSIM)
                    │       └── ICCID must already be present in hardware inventory
                    │               └── Android version floor (ownership-type-specific):
                    │                       COBO 15+ / COSU 15+ / COPE 17+
                    │                           └── Device removes only the identified eSIM
                    │
                    └── WIPE-TIME eSIM handling (independent control)
                            └── Settings Catalog: "Remove all eSIMs during a device wipe"
                                    (Android 15+, corporate-owned)
                                        ├── Unset (default): eSIMs PRESERVED across wipe
                                        └── Enabled: eSIMs REMOVED as part of that wipe
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| No Activate/Remove eSIM buttons anywhere on the device | Legacy device view in use, or device is personally owned (BYOD) | Preview new device view toggle; ownership type |
| eSIM hardware inventory missing/incomplete | Device below Android 13 (no EID) or 15 (incomplete ICCID list) | `OSVersion` vs. version floor table |
| Activate submitted, fails with a Google/OS error | Expected behavior — no client-side slot-capacity pre-check exists | Exact error text; device's actual eSIM slot occupancy |
| Remove action can't be submitted, ICCID field blocked | ICCID not yet present in hardware inventory | Trigger sync, re-check inventory |
| Remove works on COBO/COSU but not COPE at the same Android version | Documented, ownership-type-specific version floor asymmetry (COPE needs 17+, others need 15+) | Confirm exact ownership type, not just "corporate-owned" |
| eSIM survives a device wipe | "Remove all eSIMs during a device wipe" not configured — default preserves | Settings Catalog policy assignment for the device |
| One admin can Activate but not Remove (or vice versa) | Two independent RBAC permissions, not a single combined grant | Custom role permission list |
| Action attempted on a BYOD Android work-profile device | Unconditionally unsupported | Ownership type field |

---
## Validation Steps

1. **Confirm ownership type and Android version**:
   ```powershell
   Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'" |
       Select-Object DeviceName, ManagedDeviceOwnerType, OSVersion, Model
   ```
   Expected "good": `ManagedDeviceOwnerType` = `company` (corporate-owned) and an Android version meeting the relevant action's floor. A `personal` result means stop here — unsupported.

2. **Confirm hardware inventory has EID/ICCID data**:
   In the admin center's device Hardware details pane (new device view), confirm EID and at least one ICCID are populated. Absence on an Android 15+ device (where it should be present) suggests a sync-timing issue rather than a genuine hardware gap; absence on a sub-15 device is expected per the version floor.

3. **Confirm RBAC permissions for the acting admin**:
   Cross-reference the admin's role against `Remote tasks/Update cellular data plan` (Activate) and `Remote tasks/Remove eSIM` (Remove) separately — do not assume one implies the other.

4. **For a Remove attempt, confirm the target ICCID is present in inventory before attempting the action** — this is a hard precondition, not a soft warning.

5. **For a wipe-related question, confirm the applicable Settings Catalog assignment** for "Remove all eSIMs during a device wipe" on the device's assigned group — absence means the default (preserve) behavior applies.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Eligibility:**
1. Confirm ownership type (corporate-owned required, no exceptions).
2. Confirm Android version against the correct action AND correct ownership type (remembering COPE's Remove-specific 17+ floor).
3. Confirm Preview new device view is enabled for the acting admin.

**Phase 2 — Activation:**
1. Confirm carrier activation code validity and freshness out-of-band with the carrier.
2. Submit Activate eSIM; if it fails, capture the exact Google/OS-relayed error text — this is the primary diagnostic signal since Intune does not independently validate beyond relaying it.
3. If the error suggests slot exhaustion, confirm current eSIM count on the device physically before re-attempting with a different profile/slot expectation.

**Phase 3 — Removal:**
1. Trigger a device sync if the target ICCID is not yet visible in inventory.
2. Confirm the ownership-type-specific Android version floor is met.
3. Submit Remove eSIM with the exact ICCID copied from inventory (no manual retyping — copy-paste to avoid transcription errors).

**Phase 4 — Wipe-lifecycle:**
1. Before a planned bulk wipe, confirm intended eSIM disposition (preserve vs. remove) and set/verify the Settings Catalog control accordingly ahead of time — this is not something to fix reactively after a wipe if the wrong behavior occurs, since it isn't retroactive.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Provisioning eSIM on a new corporate-owned Android device</summary>

1. Confirm ownership type and Android version meet the Activate floor (15+, any of COBO/COSU/COPE) before requesting a carrier activation code.
2. Obtain the activation code from the carrier.
3. Turn on Preview new device view, select the device, Activate eSIM, enter the code.
4. Validate success via updated hardware inventory (new ICCID appears) and confirm on-device cellular data functions as expected.
5. No destructive step; safe to retry after correcting a failed attempt's root cause.

</details>

<details><summary>Playbook 2 — Decommissioning an eSIM ahead of device reassignment</summary>

1. Confirm ownership type and the ownership-type-specific Android version floor for Remove (COPE needs 17+; COBO/COSU need 15+).
2. Copy the exact ICCID from hardware inventory (sync first if not present).
3. Submit Remove eSIM with that ICCID.
4. Confirm removal on next inventory sync before reassigning the device, since a stale UI view could otherwise mask a failed removal.
5. **Note the billing implication**: removing the eSIM in Intune does not automatically stop carrier billing — that requires a separate carrier-side deprovisioning step, matching the same caveat documented for Windows Connected PC eSIM in `eSIM-B.md`.

</details>

<details><summary>Playbook 3 — Standardizing wipe behavior ahead of a bulk device-refresh cycle</summary>

1. Decide organizational policy: should eSIMs survive a wipe (e.g., device is being reassigned to another employee who should get carrier continuity) or be removed (e.g., device is leaving the fleet entirely)?
2. Configure "Remove all eSIMs during a device wipe" via Settings Catalog on the appropriate device group **before** initiating the bulk wipe — this cannot be applied retroactively to an already-completed wipe.
3. Validate the setting's assignment status on a pilot device before the full bulk operation.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Android Enterprise eSIM eligibility and inventory evidence for one device.
#>
param([Parameter(Mandatory)][string]$DeviceName)

Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"

$device = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$DeviceName'"
if (-not $device) { throw "Device '$DeviceName' not found." }

Write-Host "=== Device eligibility ===" -ForegroundColor Cyan
$device | Select-Object DeviceName, ManagedDeviceOwnerType, OSVersion, Model, LastSyncDateTime | Format-List

Write-Host "=== Hardware inventory (EID/ICCID) ===" -ForegroundColor Cyan
Get-MgDeviceManagementManagedDevice -DeviceId $device.Id -Property "hardwareInformation" |
    Select-Object -ExpandProperty HardwareInformation | Format-List

Write-Host "Reminder: cross-reference OSVersion against the ownership-type-specific version" -ForegroundColor Yellow
Write-Host "floor table in AndroidESIM-A.md before assuming eligibility for Activate/Remove." -ForegroundColor Yellow
```

Package with: exact error text from a failed Activate attempt (if applicable), a screenshot of the device's Hardware inventory pane showing (or not showing) the target ICCID, confirmation of Preview new device view state, and the acting admin's role/permission list.

---
## Command Cheat Sheet

| Purpose | Command |
|---|---|
| Confirm ownership type | `Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<name>'" \| Select ManagedDeviceOwnerType` |
| Confirm OS version | `Select-Object OSVersion` |
| Read hardware inventory (EID/ICCID) | `Get-MgDeviceManagementManagedDevice -DeviceId <id> -Property "hardwareInformation"` |
| Trigger a sync before inventory-dependent actions | Devices > select device > **Sync** (admin center; no direct single-device Graph cmdlet substitute documented for this UI action) |
| Toggle new device view (required for both actions) | Devices > All devices > **Preview new device view** |
| Graph reference for Activate | [activateDeviceEsim action](https://learn.microsoft.com/en-us/graph/api/intune-devices-manageddevice-activateDeviceEsim) |

---
## 🎓 Learning Pointers

- **This is architecturally unrelated to Windows Connected PC eSIM deployment** — different platform, different action model (single-device vs. bulk), different Graph surface. Never assume parity between `eSIM-A.md` and this topic. See [Manage eSIM plans in Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-management/actions/update-cellular-data-plan).
- **The Remove action's Android version floor is not uniform across ownership types** — COPE's 17+ requirement vs. COBO/COSU's 15+ is the single highest-value fact in this topic and the most common cause of "works for one fleet segment, not another" tickets.
- **Intune deliberately does not pre-validate eSIM slot capacity before an Activate request** — treat a post-submission Google-relayed error as a genuine device/carrier-side signal, not evidence of an Intune bug.
- **Removal is inventory-gated, not carrier-gated** — the ICCID must already be in Intune's own hardware inventory before removal can even be attempted, independent of whether the carrier could technically process a removal.
- **Wipe-time eSIM handling defaults to preservation** — this is a deliberate anti-data-loss default (carrier-billed assets aren't silently destroyed), not an oversight; plan bulk wipe operations with this default in mind.
- **Two separate RBAC permissions gate Activate vs. Remove** — don't assume a role granting one also grants the other when troubleshooting per-admin inconsistency reports.
