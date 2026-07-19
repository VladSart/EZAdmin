# Defender Device Control (USB/Removable Media/Printer/Bluetooth) — Reference Runbook (Mode A: Deep Dive)

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

This runbook covers **device control in Microsoft Defender for Endpoint** — the granular, cross-platform system for controlling access to peripheral devices (removable storage, CD/DVD, Windows Portable Devices, printers, Bluetooth) via policies, rules, groups, and access-mask entries, deployed and managed through Intune. It is deliberately scoped **distinct from three adjacent, easily-confused technologies**:

- **Windows Device Installation Restrictions** (ADMX/GPO/CSP-based) — a coarser, binary install-or-not control at the Device Manager level, evaluated entirely independently of Defender device control. Already covered incidentally in `Windows/_AGENT.md`'s entry-point routing; this runbook does not duplicate its configuration, only clarifies where the boundary is.
- **BitLocker** (`Windows/Troubleshooting/BitLocker/`) — device control can *condition* access on a removable drive's BitLocker-encrypted state (Preview feature), but does not manage BitLocker itself.
- **Microsoft Purview Endpoint DLP** (`Security/Purview/DLP-Policy-A.md`) — content-aware, sensitivity-driven control (e.g., "block copying files containing credit card numbers to USB"). Device control is device-identity-aware, not content-aware; it can't inspect what's inside a file being copied. The two are commonly layered but are separate licensing, policy, and portal experiences.

Assumes:
- Defender for Endpoint Plan 1, Plan 2, or Defender for Business licensing
- Windows 10/11 clients, anti-malware client version ≥ `4.18.2103.3` (device control is not supported on Windows Server)
- Intune as the management/deployment channel (Group Policy is a documented alternative but not covered here)

---

## How It Works

<details>
<summary><strong>Full architecture</strong></summary>

Device control decisions are evaluated through a five-layer object model: **Policy → Rules → Groups → Entries → Advanced Conditions**. Understanding this hierarchy precisely is the difference between fast diagnosis and guesswork, because every layer can independently produce a fall-through to default enforcement with zero visible error.

**Layer 0 — Global toggle and default enforcement.** Device control is disabled by default (all access allowed). When enabled, it applies to all four device type families (Removable Media, CD/DVD, Printers, Windows Portable Devices) unless the Device Types scope is narrowed. Default Enforcement (Allow or Deny) is the fallback verdict for anything that matches no rule — this is evaluated **last**, not first, but functionally it's the answer for the majority of devices in most environments, since only devices matching an authored rule get anything else.

**Layer 1 — Rules.** A rule is a pairing of Included Device Groups and Excluded Device Groups. For a rule to apply to a given device, that device must match **every** included group and **none** of the excluded groups (AND/NOT-OR logic, not simple list membership). If the device matches the rule, its Entries are evaluated next. If it doesn't match any rule, Default Enforcement applies.

**Layer 2 — Groups.** Groups filter devices by property using four match types: `MatchAll` (AND), `MatchAny` (OR), `MatchExcludeAll`, `MatchExcludeAny`. There are two group families relevant to Windows: **Device** groups (Removable Storage, Printer Device) used for rule inclusion/exclusion, and four **advanced condition** group types (Network, VPN Connection, File, Print Job) used only inside entry-level Parameters, not for rule matching itself.

Key device properties and their quirks:
| Property | What it actually is | Gotcha |
|---|---|---|
| `VID_PID` | 4-digit USB vendor + 4-digit product code | Wildcards supported (`0751_*`) — broad but can over-match across a vendor's whole product line |
| `SerialNumberId` | Per-unit serial | Most granular/stable identifier; use for "this exact drive" policies |
| `InstancePathId` | `{BusId}\{DeviceId}\{SerialNumberId}` composite | What Device Manager calls "Device instance path" — the single best source for manually deriving all four related properties at once |
| `FriendlyNameId` | Display name in Device Manager | **Least stable** — can vary between driver versions/OS builds for the same physical device; a poor primary match key despite being the most human-readable |
| `DeviceEncryptionStateId` | BitLocker encryption state (Preview) | `BitlockerEncrypted` or `Plain` — evaluated independently, Preview status means behavior can shift |
| `PrinterConnectionId` | `USB`/`Network`/`Corporate`/`Universal`/`File`/`Custom`/`Local` | `Corporate` = on-prem Print Server queue; `Universal` = Universal Print (`M365/UniversalPrint/`); these are frequently confused when authoring printer allow-lists |

**Layer 3 — Entries.** An entry is the actual verdict: `Allow`, `Deny`, `AuditAllow`, or `AuditDeny`, combined with an `AccessMask` (a bitwise OR of Device Read=1, Device Write=2, Device Execute=4, File Read=8, File Write=16, File Execute=32, Print=64) and optional Notification behavior. Enforcement entries (Allow/Deny) for a matched rule are evaluated **in order until all requested permissions are matched**; if none match, the next rule is checked, and ultimately Default Enforcement applies. Audit entries are evaluated **separately, after** the enforcement decision — they log but do not themselves grant or deny access. This is the source of the single most common misconfiguration: an audit-only policy with no paired Allow/Deny entry produces logging with the access behavior entirely inherited from Default Enforcement, not from the audit verdict.

**Layer 4 — Advanced Conditions (XML-only, Windows).** Entries can be further scoped by Network (category/domain-join state), VPN Connection (name/status/server address), File (path patterns), or Print Job (output filename/source document) conditions — but only via the raw XML authoring path, not the native Intune Device Control profile UI. This is a real capability gap in the graphical experience worth knowing about before promising a customer "block printing except when connected to corporate VPN" is a point-and-click Intune task.

**User and User Group targeting.** Rules can be conditioned on a signed-in user's Entra SID/object ID or local AD SID. Device control actively monitors the live user session and re-evaluates on session changes (lock, sign-out) — Microsoft's own documentation explicitly notes this can cause conditions to become unsatisfied mid-session, which is expected, not a bug. The documented best practice is to use **either** entry-level user/group conditions **or** Intune-level user-group targeting of the whole policy — never both simultaneously, as the interaction is unsupported/unpredictable.

**Two entirely separate management surfaces produce the same-looking policy.** Intune's native "Device Control" profile type exposes a subset of features through a graphical group/rule/entry builder (reusable settings = groups). Intune's "Custom" profile type (OMA-URI) allows full XML authoring of the same underlying schema, unlocking Advanced Conditions and finer AccessMask control the native UI doesn't expose — but requires manually generated GUIDs for every group and rule, since GUIDs aren't auto-assigned the way the native UI does it. Group Policy is a third, separate authoring path with its own XML-in-GPO storage model. All three ultimately populate the same on-device policy engine, but a support engineer inspecting a device has no way to tell from the device's own state which authoring path produced a given rule — that context only exists back in whichever console authored it.

</details>

---

## Dependency Stack

```
Defender for Endpoint license (Plan 1/2 or Business) + device onboarded
         ↑ required for
Anti-malware client version ≥ 4.18.2103.3 (Windows 10/11 only — not Server)
         ↑ hosts
Device control engine (disabled by default — allows everything until turned on)
         ↑ configured via
Intune Device Control profile (native UI) OR Custom/OMA-URI XML OR Group Policy
         ↑ sets
Default Enforcement (Allow/Deny) + Device Types in scope
         ↑ layered by
Groups (reusable settings) — filter by VID_PID / SerialNumberId / InstancePathId / etc.
         ↑ referenced by
Rules — Included Device Groups (ALL must match) + Excluded Device Groups (NONE must match)
         ↑ if matched, evaluated in order by
Entries — Allow/Deny/AuditAllow/AuditDeny + AccessMask + optional User/Machine/Parameters conditions
         ↑ Parameters conditions reference (XML-only)
Advanced Condition Groups — Network / VPN Connection / File / Print Job
```

Every layer degrades to Default Enforcement on any mismatch, with **zero propagated error to the end user or a generic "access denied" with no policy-name context** unless the engineer specifically queries Advanced Hunting for the `RemovableStoragePolicyTriggered` / `PnPDeviceBlocked` event and its `RemovableStoragePolicy` field.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Device fully absent/disabled in Device Manager (error 22/43) | Windows Device Installation Restriction (separate technology) blocked it before Defender ever saw it | `Get-PnpDevice`, GPO/CSP `DeviceInstall\Restrictions` registry |
| Device installs fine, files unreadable/unwritable | Defender device control Deny verdict on Read/Write access mask | Advanced Hunting `RemovableStoragePolicyTriggered` |
| Policy authored as Allow, device still denied | Device fell through to Default Enforcement (Deny) — group/rule mismatch | Cross-check device's actual `VID_PID`/`SerialNumberId`/`InstancePathId` against group definition |
| Works for most devices in a group, fails for one | Wrong match property used (e.g., `FriendlyNameId`, which is unstable across driver/OS versions) | `Get-PnpDeviceProperty -KeyName DEVPKEY_Device_HardwareIds` |
| Audit policy configured, access behaves like "no policy" | Audit-only entry with no paired Allow/Deny — access inherits Default Enforcement | Confirm a non-audit entry also exists for the same rule |
| Printers suddenly blocked after a USB lockdown rollout | Anti-malware client ≥ 4.18.2205 expanded default enforcement to include Printers by default | Device Types scope in the profile; explicit Printer Allow rule |
| Two rules seem to apply inconsistently / order looks "wrong" | Intune does not preserve or guarantee rule evaluation order — rules aren't mutually exclusive | Add explicit exclusions instead of relying on visual order |
| Needed condition (e.g., "only when off corporate VPN") not available in Intune UI | Advanced Conditions (Network/VPN/File/PrintJob) are XML-only, not exposed in the native Device Control profile UI | Author via Custom/OMA-URI XML policy instead |
| Only 300 events/day showing for a very active device | Documented Advanced Hunting audit event cap (300 events per device per day) | Confirm whether missing events are simply beyond the cap, not a policy gap |

---

## Validation Steps

Numbered. Command + expected "good" output + what "bad" looks like.

**1. Confirm licensing and onboarding**
```powershell
Get-MpComputerStatus | Select-Object AMProductVersion, AMEngineVersion, OnboardingState
```
Good: onboarded, `AMProductVersion` ≥ `4.18.2103.3`. Bad: not onboarded — device control cannot function regardless of policy configuration.

**2. Confirm device control is enabled and check the delivered policy locally**
```powershell
Get-Item "HKLM:\SOFTWARE\Microsoft\Windows Defender\Device Control" -ErrorAction SilentlyContinue
```
Good: key exists with policy data. Bad: missing — policy never reached the device (Intune assignment/sync issue, check **Devices → [device] → Device configuration** for profile status).

**3. Confirm the target device's actual matchable identity**
```powershell
Get-PnpDevice -Class DiskDrive, WPD, Printer |
    Select-Object FriendlyName, InstanceId |
    ForEach-Object { Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName "DEVPKEY_Device_HardwareIds" }
```
Good: returns Hardware IDs matching what was used to author the group. Bad: mismatch — most common real-world root cause in this entire runbook.

**4. Confirm via Advanced Hunting which rule/policy actually decided the verdict**
```kusto
DeviceEvents
| extend parsed = parse_json(AdditionalFields)
| where ActionType == "RemovableStoragePolicyTriggered"
| project Timestamp, DeviceName, RemovableStoragePolicy = tostring(parsed.RemovableStoragePolicy),
    Verdict = tostring(parsed.RemovableStoragePolicyVerdict)
| order by Timestamp desc
```
Good: `RemovableStoragePolicy` shows your authored rule's name. Bad: shows a generic/default name — confirms fall-through to Default Enforcement, redirect diagnosis to group/rule matching (Validation Step 3).

**5. Confirm Device Installation Restriction is not the actual layer in play**
```powershell
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions" /s
```
Good: empty, or intentionally configured and understood as a separate control. Bad: populated and not accounted for — this layer runs first and can mask a device from Defender device control entirely.

**6. Confirm no unintended user-group + entry-level user condition overlap**
```powershell
whoami /user
```
Compare against any SID-based user conditions authored in the entry. Confirms whether entry-level user targeting and Intune-level user-group targeting were mistakenly combined (unsupported per Microsoft's own guidance).

---

## Troubleshooting Steps (by phase)

**Phase 1 — Establish which technology is actually acting**
Before touching any device control policy, confirm via Device Manager status (Validation Step 3 combined with a basic `Get-PnpDevice` health check) whether the device is fully blocked at install-time (Device Installation Restriction) versus installed-but-access-restricted (Defender device control). These produce visually similar user complaints ("my USB doesn't work") but are unrelated systems with unrelated fixes.

**Phase 2 — Confirm policy delivery, not just assignment**
An Intune assignment showing "Succeeded" in the console only confirms the profile was accepted by the device — always independently confirm the actual on-device registry/CSP state (Validation Step 2) before assuming the policy content itself is the problem. A "Succeeded" assignment status does not guarantee the *content* of the policy behaves as the administrator intended; it only confirms delivery.

**Phase 3 — Verify group-to-device property matching precisely**
This is where the majority of real tickets resolve. Pull the device's actual Hardware IDs/Instance Path directly from the device (Validation Step 3), not from memory or a spec sheet, and compare property-by-property against the group definition. Pay specific attention to `FriendlyNameId` usage — it's the most intuitive property to author against and the least reliable to match on.

**Phase 4 — Confirm rule logic, not just group membership**
A device correctly present in an Included Device Group can still fail to match if it's *also* present in an Excluded Device Group for the same rule (a device in both never matches). Walk both the include and exclude lists explicitly rather than assuming "it's in the right group" is sufficient.

**Phase 5 — Confirm entry-level access mask actually covers what's needed**
A device that "shows up but can't be used" often has an Allow entry with an access mask too narrow for the intended use case (e.g., Device Read only, no File Read/Write) — recompute the intended `AccessMask` sum explicitly rather than assuming a named preset in the Intune UI covers it.

**Phase 6 — Rule out Advanced Condition scope creep**
If the intended policy involves any condition beyond plain device identity (network state, VPN state, file path, print job content), confirm it was authored via the XML/OMA-URI path — these conditions silently don't exist as options in the native Device Control profile UI, so a policy built purely in that UI cannot express them no matter how the groups/rules are arranged.

---

## Remediation Playbooks

<details>
<summary><strong>Playbook 1 — Standard "allow specific USBs, block everything else" rollout</strong></summary>

1. Create two reusable settings groups: `All Removable Storage Devices` (broad match, e.g., `PrimaryId` = removable) and `Approved USBs` (narrow match on `SerialNumberId` or `VID_PID` for approved units).
2. Author two rules with Default Enforcement set to Deny:
   - Rule A: Included = `All Removable Storage Devices`, Excluded = `Approved USBs`, Entry = Deny (blocks everything not approved)
   - Rule B: Included = `Approved USBs`, Entry = Allow with the appropriate AccessMask
3. Pilot on a small device/user group before tenant-wide assignment — device control changes have immediate, visible user impact.
4. Validate via Advanced Hunting that both approved and non-approved test devices produce the expected `RemovableStoragePolicy` name and `Verdict`.
5. **Rollback:** disable the policy assignment in Intune, or set Default Enforcement back to Allow — takes effect on next policy sync, no data loss, purely an access-control change.

</details>

<details>
<summary><strong>Playbook 2 — Adding a newly-approved device to an existing Allow list</strong></summary>

1. Obtain the device's `InstancePathId` directly from the physical unit via Device Manager → Properties → Details → Device instance path (or remotely via `Get-PnpDeviceProperty`) — never rely on a label, spec sheet, or vendor-provided VID/PID list, which can be inaccurate for private-labeled or rebadged hardware.
2. Add the confirmed `SerialNumberId` (preferred, most stable) or `VID_PID` (if approving an entire product line) to the existing `Approved` reusable settings group.
3. Confirm propagation via Validation Step 4 (Advanced Hunting) on the actual target device — don't assume success from the Intune console alone.
4. **Rollback:** remove the entry from the group — takes effect on next policy sync.

</details>

<details>
<summary><strong>Playbook 3 — Diagnosing "policy says Allow but device is blocked" (fall-through to default)</strong></summary>

1. Pull `RemovableStoragePolicy` from Advanced Hunting for the specific blocked attempt (Validation Step 4) — confirm whether it names your intended Allow rule or a generic default.
2. If it shows a generic/default name: the device didn't match your rule at all. Walk Phase 3-4 of Troubleshooting Steps to find the property/group mismatch.
3. If it shows your intended rule name but the Verdict is still Deny: check for a second, higher-precedence-by-coincidence rule matching the same device with an unintended Deny entry (remember: Intune doesn't guarantee rule order) — add explicit exclusions.
4. As a last-resort diagnostic only (not a permanent fix): temporarily flip Default Enforcement to Allow to confirm whether the device was truly falling through, then revert once the actual rule/group issue is identified and fixed.
5. **Rollback:** revert Default Enforcement change immediately after diagnosis — leaving it wide open removes the intended protection for every unmatched device, not just the one being debugged.

</details>

---

## Evidence Pack

See `Security/Defender/Scripts/Get-DeviceControlPolicyAudit.ps1` — collects local policy delivery state, onboarding/AM version, PnP device inventory with Hardware IDs for cross-referencing against Intune group definitions, and Device Installation Restriction registry state (to rule that separate layer in or out) in a single pass, exported to CSV for ticket attachment.

For the server-side/tenant-wide verdict history, Advanced Hunting is the authoritative source — no local script substitutes for pulling `RemovableStoragePolicyTriggered` and `PnPDeviceBlocked` events centrally, since those events are the only place the actual policy *name* that decided a verdict is recorded.

---

## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-MpComputerStatus \| Select AMProductVersion, OnboardingState` | Confirm Defender onboarding and client version meet the device control minimum |
| `Get-Item "HKLM:\SOFTWARE\Microsoft\Windows Defender\Device Control"` | Confirm a device control policy actually reached the device |
| `Get-PnpDevice -Class DiskDrive, WPD, Printer` | Enumerate devices in scope for device control |
| `Get-PnpDeviceProperty -InstanceId <id> -KeyName DEVPKEY_Device_HardwareIds` | Pull the exact Hardware ID(s) for group-matching cross-reference |
| `reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions" /s` | Check whether Windows Device Installation Restrictions (separate layer) are in play |
| `whoami /user` | Get local SID for cross-referencing entry-level user conditions |
| Advanced Hunting: `DeviceEvents \| where ActionType == "RemovableStoragePolicyTriggered"` | The authoritative source for which named policy/rule produced a verdict |
| Advanced Hunting: `DeviceEvents \| where ActionType == "PnPDeviceBlocked"` | Confirms a Device Installation Restriction (not device control) blocked the device |
| `New-Guid` | Generate GUIDs required when authoring groups/rules/entries via OMA-URI/XML (not needed in the native UI) |

---

## 🎓 Learning Pointers

- **Device control's object model (Policy → Rules → Groups → Entries) fails closed to Default Enforcement at every layer, with no user-facing error distinguishing "correctly denied" from "misconfigured and denied by accident."** This mirrors the same fail-quiet pattern documented in `Windows/Troubleshooting/BitLocker/NetworkUnlock-A.md` — always confirm via Advanced Hunting's `RemovableStoragePolicy` field which specific rule (or the default) actually decided a verdict before assuming policy intent matches policy behavior. Read: [Device control policies in Microsoft Defender for Endpoint — Microsoft Learn](https://learn.microsoft.com/en-us/defender-endpoint/device-control-policies)

- **"Device control" is an overloaded term covering at least three unrelated Microsoft technologies** — Windows' own ADMX/GPO Device Installation Restrictions, Defender for Endpoint's access-mask-based device control (this runbook), and Purview Endpoint DLP's content-aware controls. All three can legitimately coexist on the same device and produce overlapping-looking symptoms; always establish which one is actually acting (Phase 1) before authoring a fix in the wrong console.

- **Audit-only entries are a common trap** — they log but do not grant/deny anything themselves; access still falls to whatever Default Enforcement or a paired Allow/Deny entry says. An admin who configures "Audit" expecting it to behave like a soft warning-and-allow will get whatever the default was already set to instead.

- **`FriendlyNameId` is the most tempting and least reliable match property** — it's human-readable but can change across driver updates or OS versions for the same physical device. `SerialNumberId` (per-unit) or `InstancePathId` (composite, derivable straight from Device Manager's "Device instance path" field) are the durable choices for production policy authoring.

- **Rule evaluation order is explicitly not guaranteed by Intune** — this is documented Microsoft behavior, not an edge case to work around cleverly. The only supported pattern is designing rules to be non-intersecting via explicit exclusions.

- **The native Intune Device Control profile UI is a subset of the full policy schema** — Advanced Conditions (Network/VPN/File/PrintJob) only exist via raw XML in a Custom/OMA-URI profile. Before promising a stakeholder a conditional policy (e.g., "block USB write only off corporate VPN"), confirm whether that condition is expressible in the UI they expect to manage it in day-to-day, since XML-authored policies are harder to hand off to a less PowerShell/XML-comfortable admin team. See: [Deploy and manage device control in Microsoft Defender for Endpoint with Microsoft Intune — Microsoft Learn](https://learn.microsoft.com/en-us/defender-endpoint/device-control-deploy-manage-intune)
