# Intune Properties Catalog (Device Inventory / Registry Collection) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

> **Source confidence:** built from a live fetch of Microsoft's own current Learn page [Use Intune properties catalog to collect device properties from Windows devices](https://learn.microsoft.com/en-us/intune/device-configuration/collect-device-properties) (`ms.date` 2026-07-01, `updated_at` 2026-08-12) plus the "Week of July 27, 2026" and "Week of August 25, 2026" entries in [What's new in Microsoft Intune](https://learn.microsoft.com/en-us/intune/whats-new/). Current, GA how-to documentation. The Learn page itself explicitly flags several behaviors as "initial release limitations" — those are called out below as subject to change in later service releases, not as permanent architecture.

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

This runbook covers the **properties catalog** profile type: a no-script mechanism for collecting hardware, configuration, registry, and security-signal data from managed Windows devices into Intune's Device Inventory. It does not cover Proactive Remediations/Remediation scripts (a script-based alternative with different reporting), the general Windows Settings Catalog (a policy/configuration mechanism, not a collection one), or platform-native property collection on macOS/iOS/Android/Linux, which happens automatically outside this feature entirely.

Applies to Windows devices only, in one of four management states: Intune-managed, co-managed (Intune + Configuration Manager), Microsoft Entra joined, or Microsoft Entra hybrid joined. Assumes an account holding the Policy and Profile Manager role (or an equivalent custom role) to configure policy, and Managed Devices/Read to view collected data.

---
## How It Works

<details><summary>Full architecture</summary>

Properties catalog is a **declarative collection policy**, distinct in kind from both Settings Catalog (which configures device behavior) and Remediation scripts (which execute arbitrary logic). An admin selects property *categories* to collect — not individual registry values freeform, except within the Registry category itself — and Intune's on-device Device Inventory Agent (`C:\Program Files\Microsoft Device Inventory Agent`) reports the matching data back on the standard policy check-in cadence, landing in Device Inventory within roughly 24 hours of initial assignment.

**Category structure and required properties.** Selecting any property within a category automatically pulls in that category's "required" properties as well — for example, selecting anything under Bios Info always also collects Bios Name, Software Element ID, Software Element State, and Target Operating System, whether or not the admin explicitly picked them. This matters for capacity planning against the Registry category's 100-key device limit: required properties in *other* categories don't count against that limit, but padding out the Registry category itself does.

**Registry key inventory — the newest and most operationally significant category.** Three collection methods are supported: a single explicit value; all values directly under a key (non-recursive — subkeys of subkeys aren't walked); or the same named value across a key's immediate subkeys (useful for enumerating per-instance configuration, e.g., one value repeated across several device/app subkeys). Collection is restricted to `HKEY_LOCAL_MACHINE` only in the initial release — no HKCU, HKCR, or other hive is supported. Two independent limits apply: a 6 KB cap per collected value, and a 100-registry-key cap per device (not per-profile — cumulative across every properties catalog profile assigned to that device).

**Sensitive-value filtering.** Registry key inventory includes detection logic intended to prevent "potentially sensitive values" from being ingested. Microsoft's documentation is explicit that a flagged value simply "isn't collected" — there is no admin-facing notification, override, or allowlist mechanism described. This is a meaningful operational gotcha: an admin configuring a registry key expecting to see its value in Device Inventory may see the key referenced but no value, with no error surfaced anywhere in the Intune admin center to explain why.

**The Local AI Agent category is a notable non-registry addition worth understanding in context**, even though it's not this runbook's focus: it collects Agent Name, Install Location, and Install Scope to help discover locally-running AI coding agents (specifically referenced as "OpenClaw" in Microsoft's documentation) on managed Windows devices, feeding into Device Query and a dedicated Local AI Agent security baseline that can block such agents. Microsoft specifically recommends also collecting the **Host process** property, since such agents can run under generic-looking process names (`node.exe`, `wsl.exe`) rather than a distinctive executable name. This is a materially different mechanism from Defender's own local AI agent discovery capability — see the Learning Pointers cross-reference.

**Data lifecycle.** Collection can only be *stopped* at the category level — there's no documented mechanism to remove a single property or single registry key from an active category while leaving the rest of that category's collection running for the same profile. Deleting a properties catalog profile entirely doesn't immediately erase history: last-collected data remains visible in Device Inventory for up to 28 days after profile deletion, a grace window worth knowing about both for troubleshooting ("why does data still show for a deleted profile") and for data-governance conversations ("how quickly does removing collection actually purge visible data").

</details>

---
## Dependency Stack

```
Layer 4: Viewing (RBAC: Managed Devices/Read)
         Devices > Windows > select device > Tools > Device Inventory > category
         Up to 24h after assignment for initial collection
         Up to 28 days of continued visibility after profile deletion
Layer 3: Registry-specific constraints (only within the Registry category)
         Hive: HKLM only (initial release)
         Value size: 6 KB cap, enforced
         Device cap: 100 registry keys, cumulative across ALL properties catalog
                     profiles assigned to the device
         Sensitive-value detection: silent exclusion, no override/notification
         Collection methods: single value / all values under a key (non-recursive)
                              / same value across immediate subkeys
Layer 2: Category selection (18 categories: Application Properties, Battery,
         Bios Info, CPU, Disk Drive, Encryptable Volume, Local AI Agent, Logical
         Drive, Memory Info, Network Adapter, OS Version, Sim Info, Registry,
         System Enclosure, System Info, Time, TPM, Video Controller, Windows QFE)
         Selecting any property auto-includes that category's required properties
Layer 1: Properties catalog profile (Devices > Windows > Configuration > Create >
         New Policy > Properties catalog)
         RBAC to create: Policy and Profile Manager, OR custom role with
         Organization/Read + Managed Devices/Read + Device configurations/
         Create,Read,Assign
Layer 0: Device eligibility
         Platform: Windows only
         Management state: Intune-managed OR co-managed OR Entra joined OR
         Entra hybrid joined (at least one required)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| No data at all appears for a newly-assigned profile | Within the 24-hour initial-collection window | Compare current time against policy assignment timestamp |
| A specific registry value never appears despite correct key path | Sensitive-value detection silently excluded it, or value exceeds 6 KB | No documented way to confirm filtering directly — check value size manually; if under 6 KB and still missing, sensitive-filtering is the leading hypothesis |
| Registry values under `HKEY_CURRENT_USER` never collect | Unsupported hive — HKLM only in initial release | Confirm hive in the configured key path |
| New registry keys stop appearing on one device but work on others | Per-device 100-key cap reached, likely from cumulative keys across multiple profiles | Sum registry keys across every properties catalog profile assigned to that specific device |
| Removing one property from a category doesn't stop just that property | Expected — collection can only be stopped at the category level | Confirm current documented behavior before promising partial removal |
| Data still visible in Device Inventory after deleting the profile | Expected — up to 28-day retention of last-collected data post-deletion | Confirm deletion timestamp is within the 28-day window |
| Device platform is non-Windows and profile doesn't apply | Expected — feature is Windows-only; other platforms auto-collect | Confirm device OS |

---
## Validation Steps

1. **Confirm device eligibility (platform + management state).**
   ```powershell
   Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<device-name>'" |
       Select-Object DeviceName, OperatingSystem, JoinType, ManagementAgent
   ```
   Good: `OperatingSystem` = Windows, and the device shows an Intune-managed, co-managed, Entra joined, or Entra hybrid joined state. Bad: any other platform, or a Windows device that is domain-joined-only with no Entra/Intune relationship.

2. **Confirm profile assignment and elapsed time.**
   Good: profile status Succeeded and 24+ hours elapsed since assignment. Bad: recently assigned — treat as pending, not broken.

3. **For registry-specific gaps, validate hive, size, and count independently.**
   Good: value under HKLM, under 6 KB, and the device's cumulative registry-key count across all properties catalog profiles is comfortably under 100. Bad: any of the three constraints violated — each has a distinct, non-overlapping remediation.

4. **Check Device Inventory directly for the category in question**, rather than inferring from policy assignment status alone — a Succeeded policy status reflects the policy reaching the device, not that every configured property successfully collected and passed filtering.
   Devices > Windows > select device > **Tools** > **Device Inventory** > select category.

5. **For anything unresolved by configuration checks, pull client logs.**
   `C:\Program Files\Microsoft Device Inventory Agent\Logs` locally, or via the **Collect Diagnostics** device action remotely.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Confirm this is even the right feature for the requirement.** Properties catalog is a *collection* mechanism, not a *configuration* one — if the actual goal is changing device behavior (not just observing it), Settings Catalog is the correct tool, and properties catalog will never satisfy that requirement no matter how it's configured.

**Phase 2 — Separate "not collected yet" (time) from "will never collect" (hard limit).** The 24-hour initial window and category-level-only stop behavior both look like failures to an admin expecting immediate, granular control — confirm which situation applies before investigating further.

**Phase 3 — For registry gaps specifically, check constraints in a fixed order**: hive (HKLM only) → size (6 KB) → device-wide key count (100) → sensitive-value filtering (the only one with no direct confirmation method, so check it last by elimination).

**Phase 4 — When sensitive-value filtering is the suspected cause, don't spend time looking for an override.** Microsoft's documentation describes this as a hard content-based filter with no admin-facing exception path in the current release. If the value is genuinely required and isn't actually sensitive, the practical path is an alternate collection mechanism (Remediation script), not further properties catalog configuration.

**Phase 5 — For governance/compliance questions about this feature (not just break-fix), address the standing risk framing directly.** Microsoft's own documentation explicitly calls registry key inventory access via standard Device Inventory permissions an "accepted risk" that could expose missed-sensitive configuration data. This is worth raising proactively with security/compliance stakeholders before broad Registry-category rollout, not discovered after the fact.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Rolling out registry-based device inventory across a fleet</summary>

1. Inventory the actual registry keys/values needed up front and validate each is under HKLM and under 6 KB before building the profile.
2. Group related keys into logical profiles (e.g., by team/use case) rather than one monolithic profile, since removal is category-level and a single profile mixing unrelated keys makes future partial cleanup harder.
3. Budget against the 100-key-per-device cap across ALL profiles that will target overlapping device populations, not just the one profile being built.
4. Pilot on a small device group first and confirm expected values actually appear in Device Inventory (not just that policy status shows Succeeded) before wider assignment — this catches sensitive-value filtering early.
5. Loop in security/compliance review before enabling broad Registry-category collection, given Microsoft's own "accepted risk" framing around standard Device Inventory read access.

Rollback: remove the affected category from the profile (stops future collection); prior data remains visible for up to 28 days regardless.

</details>

<details><summary>Playbook 2 — A required registry value keeps getting silently filtered</summary>

1. Confirm the value's hive (HKLM), size (under 6 KB), and rule out the device-wide 100-key cap as camouflage for what looks like filtering.
2. If all three check out and the value still doesn't appear, treat sensitive-value detection as the confirmed cause by elimination — there's no direct confirmation surface in the admin center.
3. Evaluate whether the underlying need can be met by a different, non-filtered property already available in another category (Bios Info, System Info, TPM, etc.) before building a workaround.
4. If the specific registry value is genuinely required, use a Remediation script (Proactive Remediations) as an alternate collection path, understanding it reports through a different mechanism and RBAC surface than Device Inventory.

Rollback: not applicable — no destructive action involved in this investigation path.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects properties catalog policy assignment and per-device registry-key
    budget evidence to support troubleshooting or escalation.
#>
param(
    [string]$DeviceName
)

$device = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$DeviceName'"
$profiles = Get-MgDeviceManagementDeviceConfiguration -Filter "contains(displayName,'Properties catalog') or contains(displayName,'Registry')"

[PSCustomObject]@{
    DeviceName          = $device.DeviceName
    OperatingSystem      = $device.OperatingSystem
    JoinType             = $device.JoinType
    ManagementAgent      = $device.ManagementAgent
    EligiblePlatform     = ($device.OperatingSystem -eq "Windows")
    CandidateProfiles    = $profiles.DisplayName
    ProfileCount         = $profiles.Count
    Note                 = "Manual cross-check required: sum registry keys configured across ALL listed profiles against the documented 100-key-per-device cap; this script does not parse profile payload content."
    PulledAtUtc          = (Get-Date).ToUniversalTime()
} | ConvertTo-Json -Depth 4
```

---
## Command Cheat Sheet

```powershell
# Confirm device platform/management-state eligibility
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<device-name>'" | Select-Object DeviceName, OperatingSystem, JoinType, ManagementAgent

# List candidate properties catalog / registry profiles by name match
Get-MgDeviceManagementDeviceConfiguration -Filter "contains(displayName,'Properties catalog') or contains(displayName,'Registry')"

# Check profile assignment
Get-MgDeviceManagementDeviceConfigurationAssignment -DeviceConfigurationId "<profile-id>"

# Portal paths (no direct Graph read for collected inventory *values* — view in-portal):
#   Create/edit profile : Devices > Windows > Configuration > Create > New Policy > Properties catalog
#   View collected data : Devices > Windows > select device > Tools > Device Inventory > select category
#   Client logs (local)  : C:\Program Files\Microsoft Device Inventory Agent\Logs
```

---
## 🎓 Learning Pointers

- Properties catalog is a **collection-only** mechanism — it has no ability to change device behavior. Don't reach for it when the actual need is configuration (that's Settings Catalog) or remediation (that's Proactive Remediations). See [Use Intune properties catalog to collect device properties from Windows devices](https://learn.microsoft.com/en-us/intune/device-configuration/collect-device-properties).
- The 100-registry-key cap is **per device, cumulative across every properties catalog profile assigned to it** — not per-profile. Capacity planning has to account for every profile targeting overlapping device populations, not just the one being built.
- Sensitive-value detection for the Registry category is a **silent, non-overridable filter** in the current release — a missing value with no error anywhere in the admin center is the expected signature of this behavior, not evidence of a bug.
- Collection can only be **stopped at the category level**, never per-property or per-key within an active category — structure profiles around logical groupings from the start if partial future removal is likely to matter.
- Deleted-profile data has a **28-day visibility tail** in Device Inventory — relevant both for "why is this still showing" troubleshooting and for data-governance/retention conversations.
- The Local AI Agent property category (OpenClaw discovery) is a **distinct mechanism** from Microsoft Defender's own local AI agent discovery capability covered in `Security/Defender/LocalAIAgentDiscovery-A.md`/`-B.md` — properties catalog surfaces it via Device Inventory/Device Query, while Defender's discovery surfaces through the security portal. Don't assume enabling one gives visibility through the other's reporting surface.
- Microsoft's own documentation explicitly frames broad Registry-category read access via standard **Managed Devices/Read** permission as an "accepted risk" that could expose missed-sensitive configuration data — this is a live governance consideration worth raising with security/compliance stakeholders before wide rollout, not a settled/mitigated concern.
