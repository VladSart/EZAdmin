# Android Enterprise eSIM Lifecycle Management (Corporate-Owned) — Hotfix Runbook (Mode B: Ops)
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

**Read this first:** this covers Intune's **single-device eSIM actions for corporate-owned Android Enterprise devices** (Activate eSIM, Remove eSIM, and the wipe-time "remove all eSIMs" behavior) — a completely separate platform and management surface from Windows Connected PC eSIM bulk deployment (see `eSIM-A.md`/`eSIM-B.md`, which explicitly excludes Android). Two facts drive almost every ticket in this space: **(1)** these actions are **corporate-owned only** — COBO, COSU, and COPE are supported, personally owned BYOD work-profile devices are not, at all; and **(2)** the single-device Activate/Remove actions are **only available in the new (Preview) device view**, not the legacy device page.

Run these first, in this order:

```powershell
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"

# 1 — Confirm ownership type and Android version (governs which actions are even possible).
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'" |
    Select-Object DeviceName, ManagedDeviceOwnerType, AndroidSecurityPatchLevel, OSVersion, Model

# 2 — Confirm the device's ANDROID ENTERPRISE ENROLLMENT TYPE (COBO / COSU / COPE) —
#     not returned by the cmdlet above; check the device's enrollment profile assignment
#     or the admin center's device overview "Ownership"/"Enrollment type" fields directly,
#     since ownership type + enrollment type together (not ownership type alone) gate
#     which eSIM actions apply — see the version-floor table in AndroidESIM-A.md.

# 3 — For a REMOVE action specifically: confirm the target eSIM's ICCID is present in
#     hardware inventory. If it is not there, the removal action cannot be submitted at all.
Get-MgDeviceManagementManagedDevice -DeviceId "<DeviceId>" -Property "hardwareInformation" |
    Select-Object -ExpandProperty HardwareInformation
```

| Symptom | Likely cause | Go to |
|---------|-------------|-------|
| "Activate eSIM" / "Remove eSIM" buttons don't exist on the device | **Preview new device view** is off, or this is a personally owned (BYOD) device — neither is supported at all | Fix 1 |
| Activate eSIM submitted, then fails with a Google-returned error | Intune does **not** pre-validate eSIM slot capacity before sending the request — the carrier/OS-side rejection surfaces only after submission | Fix 2 |
| Remove eSIM action is greyed out / can't enter the ICCID | The ICCID isn't present in device hardware inventory yet (inventory hasn't synced, or the eSIM was never fully activated) | Fix 3 |
| Remove eSIM unavailable on a COPE device that works fine on a COBO/COSU device with the same Android version | **Version floor is not uniform across ownership types** — COPE requires Android 17+ for removal specifically, while COBO/COSU only require Android 15+ | Fix 4 |
| Admin expected the eSIM to be removed automatically after a routine device wipe | Default wipe behavior **preserves** eSIMs unless "Remove all eSIMs during a device wipe" was explicitly selected/configured | Fix 5 |
| Help Desk Operator can activate but not remove eSIMs (or vice versa) | Activate and Remove are gated by **two separate RBAC permissions** (`Remote tasks/Update cellular data plan` vs. `Remote tasks/Remove eSIM`) — having one does not imply the other | Fix 6 |
| Admin tries the action on a BYOD Android work-profile device | Not supported in any form — Android Enterprise eSIM actions are corporate-owned only | Fix 7 |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Android Enterprise device, Intune-enrolled, corporate-owned (COBO / COSU / COPE only —
NOT personally owned work profile / BYOD)
    │
    ├── Admin has turned on "Preview new device view"
    │       (single-device Activate eSIM / Remove eSIM actions do not exist in the
    │        legacy/default device view at all)
    │
    ├── ACTIVATE path
    │       └── Android 15+ required for ALL THREE ownership types (COBO/COSU/COPE)
    │               └── Carrier-issued activation code obtained out-of-band
    │                       └── Admin selects "Activate eSIM", enters code
    │                               └── Intune sends the request WITHOUT pre-checking
    │                                   reported eSIM slot capacity
    │                                       └── Google/OS-level activation attempt —
    │                                           success or a Google-returned error,
    │                                           surfaced back to Intune after the fact
    │
    └── REMOVE path
            └── Version floor DIFFERS BY OWNERSHIP TYPE:
                    COBO: Android 15+   COSU: Android 15+   COPE: Android 17+
                        └── Target eSIM's ICCID MUST already be present in device
                            hardware inventory (a sync/reporting prerequisite —
                            not a live carrier lookup)
                                └── Admin copies ICCID, selects "Remove eSIM", confirms
                                        └── Device removes only the identified eSIM

Separate, independent control — WIPE-TIME BEHAVIOR:
    Settings Catalog: "Remove all eSIMs during a device wipe" (Android 15+, corporate-owned)
        └── Default (unset): eSIMs are PRESERVED across a wipe
        └── If explicitly enabled: all eSIMs are removed as part of the wipe action
```

**Key fact:** Activate and Remove are gated by two independent RBAC permissions (`Remote tasks/Update cellular data plan` and `Remote tasks/Remove eSIM` respectively) layered on top of the ownership-type and Android-version gates above — a role can legitimately have one without the other, which is a common source of "the button is missing for me but not my colleague" tickets.

</details>

---
## Diagnosis & Validation Flow

1. **Confirm ownership type first.** Personally owned Android Enterprise devices with a work profile (BYOD) are unsupported for every action in this runbook — full stop. Don't proceed further if this is the case; redirect the requester to carrier-managed self-service instead.

2. **Confirm Preview new device view is on** for the admin performing the action — both Activate eSIM and Remove eSIM are single-device actions available **only** in the new device view.

3. **For Activate failures**, remember Intune does not pre-validate available eSIM slot capacity on the device before sending the activation request — a failure here is very often a genuine carrier/device-side rejection (wrong/expired code, slot already occupied, carrier-side provisioning not yet ready), not an Intune misconfiguration. Read the exact Google-returned error text before escalating.

4. **For Remove failures**, check hardware inventory for the ICCID first — if it isn't present, the UI will not let the action proceed regardless of RBAC or version eligibility. Trigger a device sync and re-check inventory before assuming a version/RBAC block.

5. **Cross-check the version floor against the SPECIFIC ownership type**, not just "Android 15+" generically — COPE devices need Android 17+ for removal specifically, a full two major versions ahead of COBO/COSU for the identical action. This asymmetry is the single most common cause of "it works on my test device but not this fleet" tickets.

6. **For wipe-related surprises**, confirm whether "Remove all eSIMs during a device wipe" was explicitly configured on the applicable policy — the unconfigured default preserves eSIMs, which surprises admins expecting a wipe to be a clean-slate operation.

---
## Common Fix Paths

<details><summary>Fix 1 — Activate/Remove eSIM buttons don't exist</summary>

1. Turn on **Preview new device view** (Devices > All devices) — these are new-view-only single-device actions.
2. If still missing after enabling the new view, confirm the device's ownership type is corporate-owned (COBO/COSU/COPE) — personally owned BYOD work-profile devices will never show these actions, in any view, at any Android version.

</details>

<details><summary>Fix 2 — Activation fails with a Google-returned error</summary>

1. Do not treat this as an Intune bug by default — Intune deliberately sends the activation request without pre-checking eSIM slot capacity, so a same-device rejection is expected behavior when the device genuinely can't accept the profile.
2. Confirm the carrier activation code is correct, unexpired, and not already consumed elsewhere.
3. Confirm the device physically has an available eSIM slot (check current eSIM count against device hardware limits) before re-attempting.
4. If the error text references a carrier-side or Google Play services issue rather than a code problem, escalate to the mobile carrier with the exact error text — this is outside Intune's control at that point.

</details>

<details><summary>Fix 3 — Remove eSIM action blocked, can't enter ICCID</summary>

1. Trigger a manual device sync and re-check hardware inventory for the ICCID before assuming a permanent block.
2. If the eSIM was only partially activated (Fix 2 scenario) it may never have reported an ICCID to inventory at all — in that case there may be nothing on the OS side to actually remove; verify directly on the device.
3. Confirm this isn't actually an Android-version gap being misread as an inventory gap — check Fix 4 next if the ICCID is confirmed present but the action is still unavailable.

</details>

<details><summary>Fix 4 — Remove works on one ownership type but not another (same Android version)</summary>

1. This is very likely the documented, asymmetric version floor, not a bug: **Remove requires Android 17+ specifically for COPE**, while COBO and COSU only require Android 15+ for the same action.
2. Confirm the exact ownership type (not just "corporate-owned" generically) and cross-reference against the version-floor table in `AndroidESIM-A.md` before escalating as a platform defect.
3. If the COPE device is genuinely below Android 17, removal is not possible until the OS is updated — there is no workaround or override.

</details>

<details><summary>Fix 5 — eSIM survived a device wipe unexpectedly</summary>

1. Confirm whether "Remove all eSIMs during a device wipe" was actually set on the policy that applied to this device — the default, unconfigured state **preserves** eSIMs across a wipe.
2. If clean-slate wipe behavior is the actual requirement, enable this Settings Catalog option going forward (Android 15+, corporate-owned) rather than treating the current behavior as a bug.
3. For an already-wiped device where the eSIM was preserved and now needs removal, use the standalone Remove eSIM action on the device post-wipe (subject to the same ICCID-in-inventory and version-floor gates above) rather than expecting a retroactive fix.

</details>

<details><summary>Fix 6 — Activate works but Remove doesn't (or vice versa) for one admin</summary>

1. Confirm the admin's RBAC role/custom role includes **both** `Remote tasks/Update cellular data plan` (Activate) and `Remote tasks/Remove eSIM` (Remove) if both actions are expected — these are separate permissions, not a single combined "manage eSIM" grant.
2. Add the missing permission to the custom role rather than assuming a platform bug when only one action works for a given admin.

</details>

<details><summary>Fix 7 — Attempted on a personally owned (BYOD) Android device</summary>

1. Set expectations immediately: this is unsupported in any form, at any Android version, in any device view. There is no workaround.
2. If cellular management for BYOD devices is a genuine business need, this must be handled outside Intune (carrier self-service, MDM-independent eSIM management from the device's own Settings app by the end user).

</details>

---
## Escalation Evidence

```
ANDROID eSIM LIFECYCLE — ESCALATION TEMPLATE
============================================
Tenant:                          <tenant name/ID>
Device name:                     <name>
Ownership type:                  <COBO / COSU / COPE / personally owned (unsupported)>
Android OS version:              <value>
Preview new device view enabled: <Y/N>
Action attempted:                <Activate eSIM / Remove eSIM / wipe-time removal>
ICCID (if Remove):               <value, confirm present in hardware inventory Y/N>
Carrier activation code (if Activate): <used Y/N — do not paste the code itself into a ticket>
Exact error text returned:       <verbatim>
Admin's RBAC role/permissions:   <role name; confirm Update cellular data plan / Remove eSIM
                                   permissions present>
```

---
## 🎓 Learning Pointers

- **This is a completely different platform from Windows Connected PC eSIM deployment** — no bulk CSV/download-server mechanism exists for Android; every action here is single-device. See `eSIM-A.md`'s own explicit exclusion of Android/iOS as a cross-reference, and [Manage eSIM plans in Microsoft Intune](https://learn.microsoft.com/en-us/intune/device-management/actions/update-cellular-data-plan).
- **Intune does not pre-validate eSIM slot capacity before sending an Activate request** — a same-device rejection after submission is expected, documented behavior, not a delivery failure to chase on the Intune side.
- **The Android version floor for Remove is not uniform across ownership types** — COPE genuinely requires two major Android versions ahead of COBO/COSU (17+ vs. 15+) for the identical action. Always confirm ownership type before comparing devices' behavior against each other.
- **Both single-device actions require the new (Preview) device view** — a missing button is very often a view-toggle issue, not a permissions or eligibility issue; check this first, every time.
- **Wipe-time eSIM removal is opt-in, not default** — a device that keeps its eSIM after a wipe is behaving exactly as documented unless "Remove all eSIMs during a device wipe" was explicitly configured.
- **Activate and Remove are gated by two separate RBAC permissions.** Don't assume role parity between the two actions when troubleshooting a "missing button for one admin" report.
