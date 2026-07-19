# Defender Device Control (USB/Removable Media/Printer/Bluetooth) — Hotfix Runbook (Mode B: Ops)

> Fix or escalate in under 10 minutes.
> **Environment:** Windows 10/11 · Defender for Endpoint Plan 1/2 or Defender for Business · Intune-managed · anti-malware client ≥ `4.18.2103.3`

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

```powershell
# 1) Is device control even enabled, and what's the default enforcement?
(Get-MpPreference).AttackSurfaceReductionRules_Actions -ne $null  # sanity — confirms MpPreference is readable
Get-MpComputerStatus | Select-Object AMProductVersion, AMEngineVersion

# 2) Was a specific device blocked/allowed and by which policy? (Advanced Hunting query — run in Defender portal)
#    DeviceEvents
#    | extend parsed = parse_json(AdditionalFields)
#    | where ActionType == "RemovableStoragePolicyTriggered"
#    | project Timestamp, DeviceName,
#        Policy = tostring(parsed.RemovableStoragePolicy),
#        Access = tostring(parsed.RemovableStorageAccess),
#        Verdict = tostring(parsed.RemovableStoragePolicyVerdict),
#        VID_PID = strcat(tostring(parsed.VendorId), "_", tostring(parsed.ProductId))
#    | order by Timestamp desc

# 3) Windows device-manager-level block (separate, coarser layer from Defender device control)
Get-WinEvent -LogName "Microsoft-Windows-DeviceSetupManager/Admin" -MaxEvents 30 -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match "blocked|denied" }

# 4) Confirm the policy actually landed on this device (Intune-delivered device control policy)
Get-Item "HKLM:\SOFTWARE\Microsoft\Windows Defender\Device Control" -ErrorAction SilentlyContinue

# 5) Confirm the physical device is even classified as a "removable media device" by Windows —
#    device control only governs devices that mount a drive letter (E:, F:, etc.)
Get-PnpDevice -Class DiskDrive, WPD | Select-Object FriendlyName, InstanceId, Status
```

**If X → Do Y**

| What you see | Likely cause | Jump to |
|---|---|---|
| User says "USB blocked" but device never shows in Device Manager at all | Windows-level Device Installation Restriction (separate from Defender device control) | [Fix 1](#fix-1--device-installation-restriction-vs-device-control-confusion) |
| Device shows in Device Manager but files can't be read/written | Defender device control policy denying Read/Write access mask | [Fix 2](#fix-2--removable-storage-access-denied-by-device-control-policy) |
| Policy set to Allow but device still blocked | Default enforcement is Deny and no matching Allow rule/entry exists for this device | [Fix 3](#fix-3--default-enforcement-deny-with-no-matching-allow-entry) |
| Works for most USBs, fails for one specific drive | Device isn't in the expected group — wrong `VID_PID`/`SerialNumberId`/`InstancePathId` match | [Fix 4](#fix-4--specific-device-not-matching-the-intended-group) |
| Audit policy configured, but nothing shows in Advanced Hunting | Audit-only entry with no paired Allow/Deny — inherits *default enforcement*, not the audit's own verdict | [Fix 5](#fix-5--audit-only-policy-with-no-paired-allowdeny) |
| Printer blocked unexpectedly after a device control rollout | Default enforcement was set to Deny for all device types, including printers, without an explicit Printer exception | [Fix 6](#fix-6--printer-blocked-by-default-enforcement) |
| Some entries in a rule seem to be ignored / apply in the wrong order | Intune UI does not preserve rule ordering — assumed the display order is enforcement order | [Fix 7](#fix-7--rule-ordering-assumption-in-intune-ui) |

---

## Dependency Cascade

<details>
<summary><strong>What must be true for a device control decision to apply as intended</strong></summary>

```
[1] Device running Windows 10/11 with Defender anti-malware client ≥ 4.18.2103.3
         ↓ required for
[2] Device onboarded to Defender for Endpoint (device control does not work on unenrolled/unlicensed devices)
         ↓ combined with
[3] Device Control feature toggled ON in an Intune Attack Surface Reduction "Device Control" profile
         ↓ sets
[4] Default Enforcement (Allow or Deny) — the fallback verdict when NOTHING else matches
         ↓ can be narrowed by
[5] Device Types selected (Removable Media / CD-DVD / Printers / WPD) — device control ignores any type NOT selected here
         ↓ layered with
[6] Groups (reusable settings) — filter devices/printers by VID_PID, SerialNumberId, InstancePathId, etc.
         ↓ referenced by
[7] Rules — Included Device Groups (must match ALL) + Excluded Device Groups (must match NONE)
         ↓ if the rule matches, evaluate
[8] Entries — the actual Allow/Deny/AuditAllow/AuditDeny + AccessMask (Read/Write/Execute/Print) + optional User/Machine conditions
         ↓ if NO rule/entry matches at all, falls through to
[9] Default Enforcement from step 4 — this is why "the policy says Allow but it's still blocked" usually traces back here
```

**Break at any layer and the device silently gets the *default enforcement* verdict, not an error.** There is no "policy failed to apply" signal to the end user — a misconfigured group or rule just means the default kicks in instead, indistinguishable from "no policy at all" unless you check the actual entry match.

- Device control in Defender is **entirely separate** from Windows' own built-in Device Installation Restrictions (ADMX/GPO-based, blocks at the Device Manager level by Device ID/Instance ID/Setup Class). The two can be layered but are configured, evaluated, and logged completely independently — a device blocked by one shows completely different symptoms/logs than one blocked by the other.
- BitLocker-encryption-state-based device control (`DeviceEncryptionStateId`) is a **Preview** feature and evaluates independently of the Read/Write/Execute access mask entries — don't assume it's covered by an existing Allow/Deny rule that doesn't explicitly reference it.

</details>

---

## Diagnosis & Validation Flow

Work top-to-bottom. Stop when you find the break.

**Step 1 — Confirm which layer actually blocked the device**
```powershell
# Windows-level Device Installation Restriction blocks show up in Device Manager as "This device is disabled" / error code 22 / 43
Get-PnpDevice | Where-Object { $_.Status -eq "Error" -or $_.Status -eq "Unknown" }
```
If the device is fully absent/disabled at the Device Manager level, this is a **Device Installation Restriction** (Windows built-in, ADMX-based), not Defender device control — jump to [Fix 1](#fix-1--device-installation-restriction-vs-device-control-confusion).

**Step 2 — If the device IS visible/installed, confirm it's actually in scope for device control**
Device control only governs devices that create a drive letter (removable media, CD/DVD), Windows Portable Devices, and printers — not every USB peripheral. A USB keyboard or webcam is out of scope for the "Removable Storage" group type entirely.
```powershell
Get-PnpDevice -Class DiskDrive, WPD, Printer | Select-Object FriendlyName, Class, InstanceId
```

**Step 3 — Confirm via Advanced Hunting what verdict was actually applied**
Run in the Defender portal (Advanced Hunting):
```kusto
DeviceEvents
| extend parsed = parse_json(AdditionalFields)
| where ActionType == "RemovableStoragePolicyTriggered"
| where DeviceName == "<hostname>"
| project Timestamp, RemovableStoragePolicy = tostring(parsed.RemovableStoragePolicy),
    RemovableStorageAccess = tostring(parsed.RemovableStorageAccess),
    Verdict = tostring(parsed.RemovableStoragePolicyVerdict),
    SerialNumberId = tostring(parsed.SerialNumber),
    VID = tostring(parsed.VendorId), PID = tostring(parsed.ProductId)
| order by Timestamp desc
```
The `RemovableStoragePolicy` field tells you **which named rule/policy** made the decision — if it shows a generic/default name rather than one of your authored rules, the device fell through to default enforcement (step 9 of the dependency cascade).

**Step 4 — Confirm the device's actual matchable properties**
```powershell
# Device Manager > Properties > Details tab > "Device instance path" gives you: {BusId}\{DeviceId}\{SerialNumberId}
Get-PnpDeviceProperty -InstanceId "<InstanceId from Step 2>" -KeyName "DEVPKEY_Device_HardwareIds"
```
Cross-check these against the actual group definitions in Intune (Endpoint Security → Attack Surface Reduction → Reusable Settings) — a common failure is a group authored against `VID_PID` when the intended match property is actually `SerialNumberId`, or vice versa.

**Step 5 — Confirm rule ordering assumptions are not in play**
Intune's device control UI **does not preserve or guarantee rule evaluation order** — rules can be evaluated in any order. If two rules could both match a device and produce conflicting verdicts, explicitly exclude the unintended group from the rule that shouldn't apply, rather than relying on visual ordering in the console.

**Step 6 — Confirm policy actually reached the device (not just assigned in Intune)**
```powershell
# Confirm the device checked in and the ASR/Device Control CSP was delivered
Get-Item "HKLM:\SOFTWARE\Microsoft\Windows Defender\Device Control" -ErrorAction SilentlyContinue
```
In Intune: **Devices → [device] → Device configuration** → confirm the Device Control profile shows **Succeeded**, not Pending/Error/Conflict.

---

## Common Fix Paths

<details>
<summary><strong>Fix 1 — Device Installation Restriction vs. Device Control confusion</strong></summary>

**Confirms:** Device fully disabled/absent in Device Manager (error code 22/43), not just access-restricted while still installed.

This is Windows' own built-in device installation policy (ADMX-based, deployed via Intune Administrative Templates or GPO), not Defender for Endpoint's device control. It blocks by Device ID / Hardware ID / Setup Class **before the device is even usable at all** — there's no Read/Write granularity, it's binary install-or-not.

```powershell
# Check for GPO/CSP-delivered device installation restriction policy
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions" /s
```

**To allow this specific device:** either add its Hardware ID/Device ID to the allow-list in the Intune "Restrict USB devices and allow specific USB devices using ADMX templates" profile, or remove the device class from the deny policy if the block was overly broad.

**Do not** try to fix this by editing a Defender device control policy — it operates at an entirely different, earlier layer and won't touch this restriction at all.

</details>

<details>
<summary><strong>Fix 2 — Removable storage access denied by device control policy</strong></summary>

**Confirms:** Device installs fine (visible, healthy in Device Manager), Advanced Hunting shows `RemovableStoragePolicyTriggered` with `Verdict: Deny`.

```text
1. In Intune admin center: Endpoint security > Attack surface reduction > Policies > [the Device Control policy]
2. Identify which rule/entry produced the Deny — cross-reference the RemovableStoragePolicy name from Advanced Hunting
3. If the device SHOULD be allowed: add its identifying property (VID_PID, SerialNumberId, or InstancePathId — confirm which via
   Step 4 of Diagnosis flow) to the correct reusable Removable Storage group referenced by an Allow rule
4. If using OMA-URI/XML authoring instead of the native Device Control profile UI, confirm the AccessMask value covers what's
   needed: 1=Device Read, 2=Device Write, 8=File Read, 16=File Write (combine by summing, e.g. 24 = File Read + File Write)
```

**Rollback:** removing the device from the Allow group reverts it to whatever the previous rule/default enforcement was — no data loss risk, this only affects future access attempts.

</details>

<details>
<summary><strong>Fix 3 — Default enforcement Deny with no matching Allow entry</strong></summary>

**Confirms:** Advanced Hunting shows the generic/default policy name (not one of your authored rule names) with `Verdict: Deny`, and you expected an Allow rule to have matched.

This means the device didn't match ANY rule's included/excluded group combination — it fell all the way through to default enforcement.

```text
1. Re-verify the device's actual properties against Step 4 of the Diagnosis flow — the most common cause is a group
   authored against the wrong property type (e.g., matched on FriendlyNameId which can vary between drivers/OS versions,
   instead of the more stable SerialNumberId or VID_PID)
2. Confirm the rule's Included Device Groups actually contains this device's group, AND that no Excluded Device Group
   also unintentionally matches it (a device in BOTH included and excluded groups never matches the rule at all)
3. If correcting the group doesn't help, temporarily change default enforcement to Allow (Intune > Attack Surface
   Reduction > Device Control policy > Configuration settings) to confirm the rule-matching theory, then revert once fixed —
   don't leave default enforcement wide open as a permanent workaround
```

</details>

<details>
<summary><strong>Fix 4 — Specific device not matching the intended group</strong></summary>

**Confirms:** Policy works correctly for most devices in a category, fails/succeeds unexpectedly for one specific unit.

```powershell
# Pull the exact matchable identifiers for the specific device
Get-PnpDevice -InstanceId "<InstanceId>" | Get-PnpDeviceProperty -KeyName "DEVPKEY_Device_HardwareIds", "DEVPKEY_Device_InstanceId"
```

Common root cause: the group was authored using a wildcard on `VID_PID` (e.g., `0781_*` for all SanDisk products) but this specific unit reports a different VID than expected — verify against the actual `Get-PnpDeviceProperty` output, not the label on the physical drive. Cross-reference the Defender portal's own Media name/Vendor Id/DeviceId/Serial Number field labels against the `FriendlyNameId`/`HardwareId`/`InstancePathId`/`SerialNumberId` property names used in policy authoring — the labels differ between the portal UI and the policy schema.

</details>

<details>
<summary><strong>Fix 5 — Audit-only policy with no paired Allow/Deny</strong></summary>

**Confirms:** An audit policy (AuditAllow/AuditDeny) is configured, but access behaves as if no policy exists, and/or events aren't appearing as expected.

Audit-only entries do not themselves determine access — **if only audit policies are configured for a device, the permission is inherited entirely from default enforcement**, not from the audit verdict itself. This is a documented, easy-to-misread behavior.

```text
Always pair an audit entry with an explicit Allow and/or Deny entry for the same device group — use audit ALONE only when
you're deliberately testing "what would happen" without affecting real access, and even then confirm default enforcement is
set the way you want production access to behave in the meantime.
```

</details>

<details>
<summary><strong>Fix 6 — Printer blocked by default enforcement</strong></summary>

**Confirms:** After enabling device control broadly, corporate/network printers stop working, and no explicit printer rule was authored.

```text
Anti-malware client 4.18.2205+ expanded default enforcement to cover Printer device type by default. If default enforcement
was set to Deny to lock down USB storage, it silently also denies printers unless Printer was explicitly excluded from
the Device Types scope, or an explicit Allow rule/entry exists for the needed printer group.
```

**Fix:** In the Device Control profile, either remove `Printers` from the selected Device Types (if printer control isn't a goal), or add an explicit Allow rule for the corporate printer group (`PrinterConnectionId` = `Corporate`/`Network`/`Universal` as appropriate).

</details>

<details>
<summary><strong>Fix 7 — Rule ordering assumption in Intune UI</strong></summary>

**Confirms:** Two rules exist that could both match the same device, with conflicting Allow/Deny outcomes, and the wrong one appears to be "winning" inconsistently.

```text
Intune does not guarantee or preserve rule evaluation order for Device Control policies — this is explicitly documented,
not a bug. Rules must be made non-intersecting by design: explicitly exclude any group from a rule that should NOT apply
to it, rather than relying on the order rules appear in the console to break ties.
```

**Fix:** Add the conflicting group to the Excluded Device Groups list of whichever rule should NOT apply to it, so the two rules can no longer both match the same device simultaneously.

</details>

---

## Escalation Evidence

Copy/paste into ticket before escalating:

```text
DEFENDER DEVICE CONTROL ESCALATION EVIDENCE
=============================================
Date/Time         : <timestamp>
Device Name       : <hostname>
User              : <UPN if user-targeted policy>
Peripheral        : <make/model/description of the blocked or misbehaving device>
Anti-malware ver. : <Get-MpComputerStatus AMProductVersion>

--- SCOPE ---
Device visible in Device Manager: <Yes/No>
Device class                    : <DiskDrive / WPD / Printer / other>
Device instance path            : <BusId\DeviceId\SerialNumberId>

--- ADVANCED HUNTING RESULT ---
RemovableStoragePolicy (rule name) : <value, or "default/none" if it fell through>
RemovableStorageAccess requested   : <Read/Write/etc>
Verdict                            : <Allow/Deny>
Timestamp of event                 : <value>

--- POLICY STATE (INTUNE) ---
Device Control profile name  : <name>
Assignment status on device  : <Succeeded/Pending/Error/Conflict>
Default enforcement          : <Allow/Deny>
Device Types in scope        : <Removable Media / CD-DVD / Printers / WPD>

--- EXPECTED VS ACTUAL ---
Expected behavior: <what should happen>
Actual behavior  : <what is happening>

--- FIXES ATTEMPTED ---
<list what was tried and result>
```

---

## 🎓 Learning Pointers

- **Device control and Device Installation Restrictions are two entirely separate Microsoft technologies that both live under the umbrella term "device control"** — one is a Windows built-in (ADMX/GPO/CSP, binary install-or-not, works even without Defender for Endpoint), the other is Defender for Endpoint's own cross-platform, access-mask-granular system. Misdiagnosing which one is acting is the single most common time-waster on these tickets — always check Device Manager status first (Fix 1) before touching a Defender policy. Read: [Device control in Microsoft Defender for Endpoint — Microsoft Learn](https://learn.microsoft.com/en-us/defender-endpoint/device-control-overview)

- **A device that matches no rule doesn't error — it silently gets the default enforcement verdict.** This is the same fail-quiet design pattern seen elsewhere in this repo (BitLocker Network Unlock, Conditional Access). Never assume "the policy says Allow" means allowed — always confirm via Advanced Hunting which specific policy name actually produced the verdict, because a misconfigured group falling through to a Deny default looks identical to a correctly-authored Deny rule from the end user's perspective.

- **Audit-only entries don't grant or deny anything on their own** — this is explicitly and easily misread in the Intune UI, where an audit policy configured with no paired Allow/Deny still inherits from default enforcement. Always pair audit entries with an explicit enforcement entry, or accept that "audit mode" is really "current default enforcement, with logging."

- **Intune's rule list does not preserve evaluation order — design rules to be mutually exclusive, don't rely on visual ordering.** This is a documented characteristic, not a bug to report — the correct pattern is explicit exclusion, not sequencing.

- **The property labels differ between the Defender portal's Advanced Hunting/report UI and the policy authoring schema** — "Media name" in the portal maps to `FriendlyNameId` in policy, "Vendor Id" maps to `HardwareId`, "DeviceId" maps to `InstancePathId`. Cross-referencing an event to a policy group by eye without knowing this mapping is a common source of "I added the exact ID from the portal and it still doesn't match" tickets.

- **BitLocker-encrypted-state-based device control is Preview** — don't build a production access model around `DeviceEncryptionStateId` (allow only BitLocker-encrypted removable drives) without accounting for its Preview status and separately confirming it behaves as expected in your tenant; Preview features can change behavior without the same notice period as GA features.
