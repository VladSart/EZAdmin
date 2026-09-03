# Intune Properties Catalog (Device Inventory / Registry Collection) — Hotfix Runbook (Mode B: Ops)
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

A properties catalog profile (device inventory / registry collection) shows Succeeded on a Windows device, but the data doesn't appear in Device Inventory, a specific registry value never shows up, or a request to add "just one more" registry key silently seems to do nothing.

```powershell
# 1. Confirm the profile is assigned and reporting Succeeded
Get-MgDeviceManagementDeviceConfiguration -Filter "contains(displayName,'<profile-name>')"

# 2. Confirm device platform and management state — Windows only, and must be
#    Intune-managed, co-managed, Entra joined, or Entra hybrid joined
Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<device-name>'" |
    Select-Object DeviceName, OperatingSystem, JoinType, ManagementAgent

# 3. Confirm elapsed time since policy assignment — initial collection can take
#    up to 24 hours; this is the single most common false-alarm cause
Get-MgDeviceManagementDeviceConfigurationAssignment -DeviceConfigurationId "<profile-id>"
```

| Result | Interpretation |
|---|---|
| Device is macOS, iOS/iPadOS, Android, or Linux | **Not applicable.** Properties catalog collection is Windows-only; other platforms already auto-collect device properties by default — no policy needed there. |
| Policy assigned less than 24 hours ago | Expected — initial collection can take up to 24 hours. Not a fault; re-check after the window. |
| Device not Intune-managed, co-managed, Entra joined, or Entra hybrid joined | Device doesn't meet the management-state prerequisite — this is a hard requirement, not a soft recommendation. |
| Policy Succeeded, 24+ hours elapsed, data still missing for a specific registry value | Value was likely flagged by sensitive-data detection logic and silently excluded — go to [Fix 1](#common-fix-paths). |
| Trying to collect a value from `HKEY_CURRENT_USER` or another non-HKLM hive | **Not supported in the initial release.** HKLM-only — go to [Fix 2](#common-fix-paths). |
| Registry collection appears to have silently stopped adding new keys for a device/profile | Likely the per-device 100-key or per-value 6KB limit was hit — go to [Fix 3](#common-fix-paths). |
| Need to stop collecting one specific property but keep the rest of its category | **Not directly supported.** Collection can only be stopped at the category level — go to [Fix 4](#common-fix-paths). |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
Device eligibility
    ├── Platform: Windows only (other platforms auto-collect; no policy applies)
    └── Management state (at least one required):
            ├── Intune-managed
            ├── Co-managed (Intune + Configuration Manager)
            ├── Microsoft Entra joined
            └── Microsoft Entra hybrid joined
                    └── Properties catalog profile (Devices > Windows > Configuration
                        > Create > New Policy > Properties catalog) assigned to device
                            └── RBAC to CREATE the policy:
                                    Policy and Profile Manager role, OR custom role with
                                    Organization/Read + Managed Devices/Read +
                                    Device configurations/Create,Read,Assign
                                        └── Property categories selected (Application,
                                            Battery, Bios Info, CPU, Disk Drive,
                                            Encryptable Volume, Local AI Agent, Logical
                                            Drive, Memory Info, Network Adapter, OS
                                            Version, Sim Info, Registry, System
                                            Enclosure, System Info, Time, TPM, Video
                                            Controller, Windows QFE)
                                                └── For Registry category specifically:
                                                        ├── HKLM only (no HKCU/other hives)
                                                        ├── Sensitive-value detection logic
                                                        │   silently excludes flagged values
                                                        ├── Per-value size limit: 6 KB
                                                        └── Per-device limit: 100 registry
                                                            keys total
                                                                └── Up to 24 hours for
                                                                    initial collection
                                                                        └── Data visible
                                                                            in Device
                                                                            Inventory
                                                                                └── RBAC to
                                                                                    VIEW:
                                                                                    Managed
                                                                                    Devices/
                                                                                    Read
    └── Independently: stopping collection is category-level ONLY — removing a single
        property from a category profile does not stop just that property; the whole
        category's collection for that profile must be removed
    └── Independently: deleting the profile entirely still leaves last-collected data
        visible in Device Inventory for up to 28 days afterward
```

</details>

---
## Diagnosis & Validation Flow

1. **Confirm platform and management-state eligibility first.** Properties catalog is Windows-only; macOS/iOS/Android/Linux devices already report properties through their own platform mechanisms and never need (or support) this profile type. Within Windows, the device must be Intune-managed, co-managed, Entra joined, or Entra hybrid joined — a Windows device outside all four states cannot collect via this feature.

2. **Rule out the 24-hour initial-collection window before treating anything as a failure.** A policy that reports Succeeded at the device-policy level does not mean data has landed in Device Inventory yet — allow the full window before escalating.

3. **For a specific missing registry value, check hive and size first.** Only `HKEY_LOCAL_MACHINE` is supported in the initial release; any value under `HKEY_CURRENT_USER` or another hive will never appear regardless of policy configuration. Values exceeding 6 KB are enforced-limited and won't be collected.

4. **Check whether the missing value was silently filtered as potentially sensitive.** Microsoft's own documentation states registry key inventory "includes detection logic to help prevent potentially sensitive values from being ingested. If a value is flagged as potentially sensitive, it isn't collected." There is no admin override or exception list for this — a value flagged as sensitive simply never appears, without an explicit error on the profile.

5. **Check the per-device 100-key ceiling if multiple registry entries across one or more profiles target the same device.** The limit is per-device, not per-profile — a device targeted by several properties catalog profiles, each contributing registry keys, can hit the ceiling even if no single profile looks large.

6. **For anything beyond configuration verification, pull client-side logs.** `C:\Program Files\Microsoft Device Inventory Agent\Logs` on the device, or trigger via the **Collect Diagnostics** device action if local access isn't available.

---
## Common Fix Paths

<details><summary>Fix 1 — A specific registry value never appears in Device Inventory</summary>

1. Confirm the value is under `HKEY_LOCAL_MACHINE` — no other hive is supported in the initial release.
2. Confirm the value is at or under the 6 KB per-value size limit.
3. If hive and size both check out, the value is very likely being silently excluded by sensitive-data detection logic. There is no documented admin override, allowlist, or notification when this happens — the value simply won't collect.
4. If the value is genuinely needed and isn't actually sensitive, there's no supported workaround within properties catalog itself; consider a Remediation script (Proactive Remediations) as an alternative collection path for that specific value, understanding it's a materially different mechanism with its own reporting surface.

Rollback: not applicable — no destructive action involved.

</details>

<details><summary>Fix 2 — Need HKEY_CURRENT_USER (or another non-HKLM hive) data</summary>

1. Confirm this is a genuine requirement, not a hive mix-up — many "missing" HKLM values are actually stored per-user under HKCU and were never going to appear via this feature.
2. There is no supported workaround inside properties catalog for non-HKLM hives in the initial release. Use a Win32 app or Remediation script with a custom detection/collection script if per-user registry data is required, and treat it as a separate reporting pipeline from Device Inventory.

Rollback: not applicable.

</details>

<details><summary>Fix 3 — New registry keys stop being collected on a device</summary>

1. Count the total registry keys currently configured for collection across every properties catalog profile assigned to the affected device — the 100-key limit is per-device, cumulative across all profiles targeting it, not per-profile.
2. If at or near the limit, prioritize which keys are actually needed and remove lower-value entries (remembering removal is category-level — see Fix 4) before adding new ones.
3. If genuinely all 100 keys are load-bearing, consolidate: some values may be redundant with data already available via other properties catalog categories (Bios Info, System Info, TPM, etc.) that don't count against the registry-specific limit.

Rollback: not applicable — this is a capacity-planning fix, not a change to undo.

</details>

<details><summary>Fix 4 — Need to stop collecting one property without losing the rest of its category</summary>

1. Confirm this limitation before promising a partial removal to a stakeholder: **collection can only be stopped at the category level.** Removing one registry key from a profile that's collecting several does not selectively stop just that one — verify current documented behavior before making changes, since this is an area Microsoft may refine over time.
2. If a genuinely partial stop is required, the practical workaround is splitting registry collection across multiple properties catalog profiles by logical grouping up front, so an entire profile (and therefore one coherent set of keys) can be removed together without affecting unrelated keys tracked in a different profile.
3. Removing the category from an existing profile stops future collection; previously collected data for that category remains visible in Device Inventory for up to 28 days per the standard retention behavior.

Rollback: re-adding the category/property to the profile resumes collection going forward but does not retroactively backfill the gap during which it was removed.

</details>

---
## Escalation Evidence

```
=== Intune Properties Catalog — Escalation Template ===
Tenant ID:                                    <fill in>
Affected device name(s):                      <fill in>
Device management state (Intune/co-managed/Entra joined/Entra hybrid joined): <fill in>
Properties catalog profile name(s):           <fill in>
Property categories configured:               <fill in>
Specific registry key/value affected (if applicable): <fill in>
Hive (must be HKLM):                          <fill in>
Time since policy assignment (must be 24h+ before treating as failure): <fill in>
Approx. total registry keys configured for this device across all profiles: <fill in>
Business impact:                              <fill in>
Requested next step:                          <fill in>
```

---
## 🎓 Learning Pointers

- Properties catalog is **Windows-only** — macOS, iOS/iPadOS, Android, and Linux devices already collect properties automatically through their own platform mechanisms and don't use (or support) this profile type. See [Use Intune properties catalog to collect device properties from Windows devices](https://learn.microsoft.com/en-us/intune/device-configuration/collect-device-properties).
- Initial collection can take **up to 24 hours** after policy assignment — this is the single most common source of "it's not working" tickets that resolve themselves with time.
- Registry key inventory is explicitly **not intended for sensitive/confidential values**, and Microsoft's own detection logic silently drops flagged values with no admin override, allowlist, or error notification — don't assume a missing value means the policy is broken.
- Initial-release hard limits: **HKLM only** (no HKCU or other hives), **6 KB per value**, **100 registry keys per device** (cumulative across all properties catalog profiles targeting that device, not per-profile).
- Stopping collection is **category-level only** — there's no supported way to remove a single property from an active category while leaving the rest of that category collecting. Plan profile structure (grouping related keys into their own profile) around this limitation from the start.
- Deleting a properties catalog profile doesn't immediately erase history — last-collected data remains visible in Device Inventory for up to 28 days afterward.
- Registry key inventory data is accessible through the same **Managed Devices/Read** permission as all other Device Inventory data — Microsoft's own documentation frames the risk of over-broad read access exposing missed-sensitive configuration data as an "accepted risk" organizations should review before enabling broad collection, not a solved problem.
