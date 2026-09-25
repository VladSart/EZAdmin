# Intune Assignment Filters: osVersion → operatingSystemVersion — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

> **What changed:** Intune service release **2608** (week of 25 Aug 2026) made the `operatingSystemVersion` filter property GA for managed devices and managed apps. `osVersion` is now **deprecated**. Existing filters that use it **keep working**, and Microsoft says it "will be removed in the future" (no date). Learn reference updated 23 Sep 2026. General filter troubleshooting (staleness, platform mismatch, Not evaluated) lives in `Intune/Troubleshooting/Filters-B.md`. This runbook covers only the property change and migration mistakes.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---
## Triage
```powershell
# Needs Microsoft.Graph.Authentication. Read-only scope.
Connect-MgGraph -Scopes 'DeviceManagementConfiguration.Read.All','DeviceManagementManagedDevices.Read.All' -NoWelcome

# 1. Every filter still using osVersion (device.* or app.*)
$f = (Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/beta/deviceManagement/assignmentFilters' -OutputType PSObject).value
$f | Where-Object { $_.rule -match '(?i)\b(device|app)\.osVersion\b' } |
    Select-Object displayName, platform, assignmentFilterManagementType, rule | Format-List

# 2. Filters already on operatingSystemVersion (check these if a rollout just "changed")
$f | Where-Object { $_.rule -match '(?i)operatingSystemVersion' } | Select-Object displayName, platform, rule | Format-List

# 3. The device's actual reported version (what the filter compares against)
# (needs DeviceManagementManagedDevices.Read.All as well)
(Invoke-MgGraphRequest -Method GET -OutputType PSObject -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '<deviceName>'&`$select=deviceName,operatingSystem,osVersion,lastSyncDateTime").value
```

| Result | Meaning | Go to |
|---|---|---|
| Filter uses `osVersion` and the ticket is "can't save / can't create filter" | Rule editor steering new filters to `operatingSystemVersion` | Fix 1 |
| New `operatingSystemVersion` filter matches too many/too few devices | Wrong operator semantics (string prefix vs version compare) or wrong value format | Fix 2 |
| iOS/Android/AOSP **Available** app assignment shows inconclusive filter result | **Known issue**: `operatingSystemVersion` on Available apps for those platforms evaluates inconclusive (no ETA) | Fix 3 |
| macOS/iOS filter with values like `"14.1.2a"` or `"10.15.3 (19D2064)"` | Apple SPV letters / build suffixes aren't valid version literals | Fix 4 |
| Nothing is wrong, the ask is "do we need to migrate?" | No forced migration yet. Plan it | Fix 5 |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Policy/app applies to intended devices only
 └── Assignment (group + filter in Include/Exclude mode)
      └── Filter rule evaluates correctly
           ├── Property choice
           │    ├── osVersion (deprecated): STRING operators (-eq -ne -in -notIn -startsWith -contains -notContains)
           │    └── operatingSystemVersion: VERSION operators (-eq -ne -gt -ge -lt -le) — no -in / -startsWith / -contains
           ├── Value literal matches what Intune stores
           │    ├── Windows: 10.0.<build>.<UBR>  (e.g. 10.0.26100.4652)
           │    ├── Apple: 17.5.1  (no SPV letter "a", no "(build)" suffix)
           │    └── Android: 14 / 14.0
           └── Device inventory current (osVersion reported at last check-in, ~8 h)
      └── Platform/workload support
           └── operatingSystemVersion + Available apps on Android/AOSP/iOS = inconclusive (known issue)
```
</details>

---
## Diagnosis & Validation Flow
1. **Get the rule text exactly.**
   `$f | Where-Object displayName -eq '<filterName>' | Select-Object -ExpandProperty rule`
   Expected: one or more `(device.<property> -<op> <value>)` clauses.
2. **Get the device's stored version** (Triage command 3).
   Windows `OsVersion` = `10.0.26100.4652`. This is the value both properties compare against.
3. **Evaluate by hand.**
   - `osVersion -startsWith "10.0.26100"` → string prefix → true.
   - `operatingSystemVersion -ge 10.0.26100.0` → version compare → true.
   - `operatingSystemVersion -eq 10.0.26100` → **false** (full 4-part value differs). This is the #1 migration mistake.
4. **Use the portal's preview.** Intune admin center → Tenant administration → Filters → *filter* → **Preview** lists matching devices. Compare the count against the old filter.
5. **Check the device's evaluation.** Devices → *device* → **Filter evaluation** (up to 30 min lag; results kept 30 days). `Not evaluated` usually means an assignment conflict, not the rule.

---
## Common Fix Paths

<details><summary>Fix 1 — "I can't add osVersion to a new filter"</summary>

This is by design. New filters should use `operatingSystemVersion`. Translate the clause (Fix 2 table), save as a **new** filter, then swap it into assignments.
- Community reporting says new filters can't use `osVersion`. Behaviour when **editing** an existing `osVersion` filter isn't documented. Don't assume you can keep tweaking it. If an edit is refused, clone to a new filter.
</details>

<details><summary>Fix 2 — Translate the rule correctly</summary>

| Old (`osVersion`, string) | New (`operatingSystemVersion`, version) |
|---|---|
| `(device.osVersion -eq "17.5.1")` | `(device.operatingSystemVersion -eq 17.5.1)` |
| `(device.osVersion -startsWith "10.0.26100")` | `(device.operatingSystemVersion -ge 10.0.26100.0) and (device.operatingSystemVersion -lt 10.0.26101.0)` |
| `(device.osVersion -startsWith "10.0.22")` (all Win11 23H2/22H2/21H2 by string luck) | `(device.operatingSystemVersion -ge 10.0.22000.0) and (device.operatingSystemVersion -lt 10.0.23000.0)`. State the intent explicitly |
| `(device.osVersion -in ["17.5","17.5.1"])` | `(device.operatingSystemVersion -eq 17.5) or (device.operatingSystemVersion -eq 17.5.1)` |
| `(device.osVersion -notIn ["13","14"])` (Android) | `(device.operatingSystemVersion -ne 13) and (device.operatingSystemVersion -ne 14)` |
| `(device.osVersion -contains "26100")` | No equivalent. Rewrite as a range |
| *new capability:* "Windows 11 24H2 at or above July 2026 UBR" | `(device.operatingSystemVersion -ge 10.0.26100.4652) and (device.operatingSystemVersion -lt 10.0.26101.0)` |

Notes:
- `-gt/-ge/-lt/-le` values are **unquoted** in the Learn examples. `-eq/-ne` appear both quoted and unquoted. Unquoted is the safe default for every operator on this property.
- Combining `and`/`or` or using nested parentheses switches the portal to the rule-syntax editor (rule builder disabled). That's expected.
- Swap the filter on each assignment, **keeping the same Include/Exclude mode**, and don't delete the old filter until the new one has been live through a full check-in cycle (≥ 8 h).
- Automate the inventory and draft translations with `Intune/Scripts/Get-OSVersionFilterMigrationAudit.ps1`.
</details>

<details><summary>Fix 3 — Mobile Available apps show inconclusive results</summary>

Known issue (Learn, filter troubleshooting): `operatingSystemVersion` filters on **Available** app assignments for **Android, AOSP, iOS/iPadOS** evaluate inconclusive. Fix pending, no ETA.
- **Keep the existing `osVersion` filter** on those Available assignments until Microsoft fixes it. Don't migrate them.
- Required assignments and non-app workloads aren't listed as affected. Verify with Filter evaluation per device.
- Troubleshooting Available assignments: the app's *Device install status* report doesn't show Available apps. Use the device's **Filter evaluation** report, and have the user open the app list in Company Portal to trigger evaluation.
</details>

<details><summary>Fix 4 — Apple values with SPV letters or build suffixes</summary>

`osVersion` examples on Learn include strings like `"10.15.3 (19D2064)"`, and Learn says not to include Apple's Security Patch Version letter (`14.1.2a`). Neither is a valid version literal for `operatingSystemVersion`.
- Strip to numeric: `14.1.2a` → `14.1.2`; `10.15.3 (19D2064)` → `10.15.3`.
- Learn states the stored Apple OS version excludes the SPV letter, so a device on `14.1.2a` should match `-ge 14.1.2`. Confirm with Preview on a real RSR/BSI-patched device before relying on it.
</details>

<details><summary>Fix 5 — "Do we have to migrate now?"</summary>

No forced date. Recommended order:
1. Inventory (script or Triage command 1).
2. Migrate filters used on **Required** / config / compliance assignments first. They gain the most from real version comparison (patch-level targeting).
3. Leave mobile **Available** app filters on `osVersion` (Fix 3).
4. Run old and new filters side by side via Preview until counts match, then swap.
Rollback: re-select the old filter on the assignment. Filters are independent objects, and the old one is unchanged until you delete it.
</details>

---
## Escalation Evidence
```
Ticket: Intune assignment filter — osVersion / operatingSystemVersion
Tenant: <tenantName>          Filter name / ID: <name> / <guid>
Platform: <windows10AndLater / iOS / macOS / androidForWork / androidAOSP>   Management type: <devices / apps>
Rule (exact): <paste>
Previous rule (if migrated): <paste>
Assignment: <policy/app name>, intent <Required/Available/Uninstall>, mode <Include/Exclude>, group <name>
Affected device: <deviceName>, OsVersion reported <value>, LastSyncDateTime <UTC>
Filter evaluation result (device blade): <Match / No match / Not evaluated / inconclusive> at <UTC>
Preview count old vs new filter: <n> / <n>
Known-issue check (mobile Available app?): <Y/N>
```

---
## 🎓 Learning Pointers
- **The operator family changed, not just the name.** `osVersion` did string matching, which is why `-startsWith "10.0.2"` "worked" for Windows 11 by accident. `operatingSystemVersion` compares versions. Rewrite prefixes as explicit `-ge`/`-lt` ranges. [Assignment filter properties and operators reference](https://learn.microsoft.com/en-us/intune/fundamentals/filters/ref-device-properties)
- **`-eq` needs the full stored value.** Windows reports four parts (`10.0.26100.4652`), so `-eq 10.0.26100` matches nothing. Check the device's `osVersion` in Graph before writing any equality rule.
- **Don't migrate mobile Available-app filters yet.** There's a documented inconclusive-evaluation bug. [Assignment filter reports & troubleshooting](https://learn.microsoft.com/en-us/intune/fundamentals/filters/troubleshoot)
- **Filters are cheap to clone and swap back.** Build new, Preview, swap, keep the old one until a full check-in cycle passes. [Jeroen Burgerhout (MVP): osVersion in assignment filters is dead](https://www.burgerhout.org/p/osversion-in-assignment-filters-is-dead-here-is-what-replaces-it)
- Parent topic: `Intune/Troubleshooting/Filters-B.md` / `Filters-A.md` (staleness, platform mismatch, conflict resolution). Its older examples still show `osVersion` syntax; read them alongside this page.
