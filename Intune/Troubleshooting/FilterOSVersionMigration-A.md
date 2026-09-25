# Intune Assignment Filters: osVersion → operatingSystemVersion — Reference Runbook (Mode A: Deep Dive)
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
- [Learning Pointers](#-learning-pointers)

---
## Scope & Assumptions

**In scope**
- The deprecation of the `osVersion` assignment-filter property and GA of `operatingSystemVersion` (Intune service release 2608, week of 25 Aug 2026)
- Semantic differences between the two properties, how to translate rules safely, and the tenant-wide migration process across multiple customer tenants
- Known issues and edge cases (mobile Available apps, Apple version strings, Windows 4-part versions)

**Out of scope**
- General filter troubleshooting (see `Intune/Troubleshooting/Filters-A.md`)
- Entra ID dynamic group `deviceOSVersion` rules. A different engine with different syntax
- Conditional Access device-platform/version conditions

**Assumptions**
- Intune admin (or Policy and Profile Manager) rights; Graph PowerShell available
- MSP context: many tenants, each with a handful to dozens of filters, often copied between tenants from a template

**Source confidence**
- **High:** Learn "Assignment filter properties and operators reference" (updated 2026-09-23) for property definitions, operators, examples and the deprecation note ("Existing assignment filters that use `osVersion` will continue to work. The `osVersion` property will be removed in the future."). Learn "Assignment filter reports & troubleshooting" for the mobile Available-apps known issue.
- **Medium:** Intune What's New (2608) as quoted by Jeroen Burgerhout (MVP, 10 Sep 2026): GA "for managed devices and managed apps".
- **Unverified / reported:** "you can't create new filters that use `osVersion`" (community write-ups). Behaviour when editing an existing `osVersion` filter. The exact managed-app property name. `app.operatingSystemVersion` is the expected form, but the Learn app tab wasn't retrieved in this run. Confirm in the rule editor.
- **Graph:** `deviceManagement/assignmentFilters` is **beta-only**. The `payloads` navigation used below for assignment discovery is beta and treated as best-effort in the script.

---
## How It Works
<details><summary>Full architecture</summary>

### 1. Where the value comes from
Both properties read the **same inventory field**: the OS version the device reported at its last Intune check-in (`managedDevice.osVersion` in Graph). Nothing changes on the device side. What changes is **how the filter engine compares** that value.

| Platform | Typical stored value |
|---|---|
| Windows | `10.0.26100.4652` (major.minor.build.UBR) |
| iOS/iPadOS/macOS | `17.5.1`, `15.0`, SPV letter excluded |
| Android / AOSP | `14`, `13.0` |

### 2. String vs version semantics
```
osVersion (deprecated)                      operatingSystemVersion
──────────────────────                      ───────────────────────
type: string                                type: version
ops: -eq -ne -in -notIn                     ops: -eq -ne -gt -ge -lt -le
     -startsWith -contains -notContains
"10.0.26100.4652" -startsWith "10.0.2"  ✔   10.0.26100.4652 -ge 10.0.22000.0 ✔
"10.0.9999"       -startsWith "10.0.2"  ✘   (lexical)
"17.10" vs "17.9" — no ordering possible    17.10 -gt 17.9 ✔ (numeric per component)
```
The string model forced admins to encode ranges as prefix tricks (`"10.0.22"` for "Windows 11 up to 23H2") or long `-in` lists of exact builds. Those break whenever a build number crosses a digit boundary or a new UBR ships. The version model gives real ordering, which enables **patch-level targeting** (e.g. "Windows 11 24H2 below UBR 4652 gets the expedite-update policy").

### 3. Equality and component count
`-eq` compares the full version. `10.0.26100` ≠ `10.0.26100.4652`. Whether Intune pads missing components (treating `10.0.26100` as `10.0.26100.0`) isn't documented. Design rules so it doesn't matter. Use `-ge <x>.0` / `-lt <x+1>.0` ranges instead of `-eq` on partial versions.

### 4. Evaluation pipeline (unchanged)
```
Check-in / enrollment / compliance eval
  → assignment intent resolved (Required/Available/Uninstall)
  → filter mode precedence: Exclude > No filter > Include; same mode = OR
  → rule evaluated against inventory properties
  → Match / No match / Not evaluated → logged (up to 30 min to appear, retained 30 days)
```
Migrating the property doesn't change precedence. Swapping an Include filter for a new Include filter on the same assignment is a like-for-like change.

### 5. Known issue: mobile Available apps
Learn documents that `operatingSystemVersion` on **Available** app assignments for **Android, AOSP and iOS** evaluates as *inconclusive* (fix pending, no ETA). Available-intent evaluation happens when the user browses Company Portal, a different path from check-in evaluation, and the new property isn't wired through it yet. Keep `osVersion` on those assignments until Learn drops the note.

### 6. Managed-app filters
Managed-app filters (App Protection / App Configuration for MAM) are separate filter objects (`assignmentFilterManagementType = apps`) using `app.*` properties. 2608 is described as GA for managed apps as well, so the same migration applies. Validate the property name in the editor first.
</details>

---
## Dependency Stack
```
[L6] Business outcome      right devices get the policy/app/update ring
[L5] Assignment            group + intent + filter + mode (Include/Exclude)
[L4] Filter object         platform · managementType (devices|apps) · rule text (beta Graph)
[L3] Rule semantics        osVersion (string ops, deprecated) | operatingSystemVersion (version ops)
[L2] Evaluation path       check-in/compliance eval · Company Portal Available-app eval (known issue on mobile)
[L1] Inventory             managedDevice.osVersion as last reported (≈8 h check-in cadence)
[L0] Device OS             actual build/UBR, Apple base version (SPV excluded), Android API-level string
```

---
## Symptom → Cause Map

| Symptom | Most likely cause | Check |
|---|---|---|
| New filter matches 0 devices | `-eq` with a partial version (Windows needs 4 parts) | Device `osVersion` in Graph vs rule literal |
| New filter matches more devices than old | Old `-startsWith` prefix was narrower than the range you wrote (or vice versa) | Preview both filters, diff the device lists |
| Can't select `osVersion` in rule builder | Deprecated, and new filters steered to `operatingSystemVersion` | Expected. Translate |
| Rule save error on `-in` / `-startsWith` | Those operators aren't supported for `operatingSystemVersion` | Rewrite as OR'd `-eq` or ranges |
| iOS/Android Available app: inconclusive filter result | Documented known issue | Keep `osVersion` on that assignment |
| Apple filter never matches | SPV letter or `(build)` suffix in the literal | Strip to numeric |
| Device matched yesterday, not today | OS updated, inventory refreshed (expected), or filter edited | `lastSyncDateTime`, filter *Last modified* |
| "Not evaluated" after swap | Assignment conflict / intent resolution, not the property | `Filters-A.md` conflict section |
| Same template filter behaves differently across customer tenants | Tenants on different migration state (one old, one new) | Run the audit script per tenant |

---
## Validation Steps
1. **Inventory**
   `Get-OSVersionFilterMigrationAudit.ps1` → `OSVersionFilters.csv`. Good: every row has `Migration = Translated` or a documented `KeepOnOsVersion` reason. Bad: `Manual` rows with no owner.
2. **Literal format**
   For each platform, pull five devices' `osVersion` from Graph and confirm your literals have the same component count.
3. **Preview parity**
   Portal Preview of old vs new filter. Good: identical device counts (or a deliberate, documented difference). Bad: unexplained delta.
4. **Per-device evaluation**
   Device → Filter evaluation after swap. Good: `Match`/`No match` as intended, with the new filter name. Bad: `Not evaluated` (conflict) or inconclusive (mobile Available known issue).
5. **Workload outcome**
   Policy/app status report after one full check-in cycle. Good: success/applicable counts unchanged.

---
## Troubleshooting Steps (by phase)

**Phase A: discover**
- Pull all filters, classify by property used, platform, management type, and (best-effort) assignments that reference them.
- Flag mobile filters used on Available app assignments as *do not migrate yet*.

**Phase B: translate**
- Mechanical translations: `-eq`/`-ne` with full literals, `-in`/`-notIn` → OR/AND chains, `-startsWith` on a whole component → half-open range.
- Manual: `-contains`/`-notContains`, prefixes ending mid-component (`"10.0.2"`), Apple strings with build suffixes, mixed clauses with other properties.

**Phase C: build and compare**
- Create a new filter named `<old name> (osv)`. Don't edit the old one in place. Preview both. Record counts.

**Phase D: swap**
- On each assignment, replace the filter and keep the mode. Wait one full check-in cycle (≥ 8 h). Check workload reports.

**Phase E: retire**
- After a stable period, delete the old filter (it will refuse to delete while assigned, which is a useful safety net).

---
## Remediation Playbooks

<details><summary>Playbook 1 — Tenant-wide audit and draft translations</summary>

```powershell
.\Get-OSVersionFilterMigrationAudit.ps1 -OutputPath C:\Temp\FilterMig -IncludeAssignments
# Multi-tenant (MSP): run once per tenant with a delegated/GDAP session
.\Get-OSVersionFilterMigrationAudit.ps1 -TenantId '<tenantId>' -OutputPath "C:\Temp\FilterMig\<tenantName>"
```
Output columns include the original rule, a `ProposedRule`, and `Migration` = `Translated` / `Review` / `Manual` / `AlreadyMigrated`. `Review` means the translation is mechanical but the old string semantics were looser/tighter than a version range. Read it before using.
</details>

<details><summary>Playbook 2 — Create the new filter via Graph (after review)</summary>

```powershell
# Requires DeviceManagementConfiguration.ReadWrite.All. Creates a NEW filter; the old one is untouched.
Connect-MgGraph -Scopes 'DeviceManagementConfiguration.ReadWrite.All' -NoWelcome
$body = @{
    displayName = '<Old filter name> (osv)'
    description = 'Migrated from osVersion to operatingSystemVersion'
    platform    = '<windows10AndLater | iOS | macOS | androidForWork | androidAOSP>'
    rule        = '(device.operatingSystemVersion -ge 10.0.26100.0) and (device.operatingSystemVersion -lt 10.0.26101.0)'
    roleScopeTags = @('0')
} | ConvertTo-Json
Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/beta/deviceManagement/assignmentFilters' -Body $body -ContentType 'application/json'
```
Rollback: `Invoke-MgGraphRequest -Method DELETE -Uri "https://graph.microsoft.com/beta/deviceManagement/assignmentFilters/<newFilterId>"` (fails while the filter is assigned, so unassign first).
Swapping filters on assignments is **per workload** (each policy/app has its own `/assign` action and payload shape). Do it in the portal unless you already have tested per-workload automation.
</details>

<details><summary>Playbook 3 — Patch-level targeting (the new capability)</summary>

Example: target Windows 11 24H2 devices below a specific UBR with an expedited quality update or a "you're behind" compliance notification:
```
(device.operatingSystemVersion -ge 10.0.26100.0) and (device.operatingSystemVersion -lt 10.0.26100.4652)
```
Example: iOS devices below 17.6 get a stricter app-protection conditional-launch policy (managed-app filter, confirm property name):
```
(app.operatingSystemVersion -lt 17.6)
```
Remember inventory lag. A device that patched this morning may still match until its next check-in.
</details>

<details><summary>Playbook 4 — Mobile Available-app exception tracking</summary>

1. From the audit CSV, filter `Platform` in (`iOS`, `androidForWork`, `androidAOSP`, `android`) with an Available app assignment (when `-IncludeAssignments` resolved it).
2. Tag those filters with `KeepOnOsVersion: Learn known issue (Available apps, mobile)` in the filter **description**, so the next engineer doesn't "fix" them.
3. Re-check the Learn troubleshooting page each quarter. When the known-issue note is gone, migrate them.
</details>

---
## Evidence Pack
```powershell
# Read-only. Exports all filters, devices' reported versions for a sample, and the rule texts, for escalation.
Connect-MgGraph -Scopes 'DeviceManagementConfiguration.Read.All','DeviceManagementManagedDevices.Read.All' -NoWelcome
$out = Join-Path $env:TEMP ("FilterOSV-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $out -Force | Out-Null

$filters = @()
$uri = 'https://graph.microsoft.com/beta/deviceManagement/assignmentFilters'
do { $r = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject; $filters += $r.value; $uri = $r.'@odata.nextLink' } while ($uri)
$filters | Select-Object id, displayName, platform, assignmentFilterManagementType, lastModifiedDateTime, rule |
    Export-Csv "$out\filters.csv" -NoTypeInformation

$dev = (Invoke-MgGraphRequest -Method GET -OutputType PSObject `
    -Uri 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$select=deviceName,operatingSystem,osVersion,lastSyncDateTime&$top=200').value
$dev | Export-Csv "$out\device-versions-sample.csv" -NoTypeInformation
$dev | Group-Object operatingSystem | ForEach-Object {
    [pscustomobject]@{ OS = $_.Name; Count = $_.Count; ExampleVersions = (($_.Group.osVersion | Select-Object -Unique -First 5) -join '; ') }
} | Export-Csv "$out\version-format-by-os.csv" -NoTypeInformation

Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
Write-Host "Evidence: $out.zip"
```

---
## Command Cheat Sheet

| Task | Command / rule |
|---|---|
| List filters | `(Invoke-MgGraphRequest GET 'https://graph.microsoft.com/beta/deviceManagement/assignmentFilters' -OutputType PSObject).value` |
| Filters still on osVersion | `… \| Where-Object rule -match '(?i)\b(device\|app)\.osVersion\b'` |
| Device reported version | `…/v1.0/deviceManagement/managedDevices?$filter=deviceName eq '<name>'&$select=osVersion` |
| Exact version | `(device.operatingSystemVersion -eq 17.5.1)` |
| Build range (Win11 24H2) | `(device.operatingSystemVersion -ge 10.0.26100.0) and (device.operatingSystemVersion -lt 10.0.26101.0)` |
| All Win11 | `(device.operatingSystemVersion -ge 10.0.22000.0)` |
| Win10 only | `(device.operatingSystemVersion -lt 10.0.22000.0)` |
| Below patch level | `(device.operatingSystemVersion -lt 10.0.26100.4652)` |
| Replace -in | `(… -eq A) or (… -eq B)` |
| Replace -notIn | `(… -ne A) and (… -ne B)` |
| Audit script | `.\Get-OSVersionFilterMigrationAudit.ps1 -IncludeAssignments` |
| Create new filter | `POST beta/deviceManagement/assignmentFilters` (Playbook 2) |

---
## 🎓 Learning Pointers
- **Read the operator list, not just the property name.** `operatingSystemVersion` drops `-in`, `-startsWith` and `-contains` and adds `-gt/-ge/-lt/-le`. Every translation follows from that. [Assignment filter properties and operators reference](https://learn.microsoft.com/en-us/intune/fundamentals/filters/ref-device-properties)
- **Half-open ranges are the replacement for prefixes.** `-ge X.0 and -lt (X+1).0` is exact, and it survives new UBRs and digit-length changes that broke string prefixes.
- **Known issues are part of the migration plan.** Mobile Available-app assignments evaluate inconclusive on the new property, so exempt and label them. [Assignment filter reports & troubleshooting](https://learn.microsoft.com/en-us/intune/fundamentals/filters/troubleshoot)
- **Clone, preview, swap, retire.** Filters are standalone objects and deletion is blocked while assigned, so the safe path is always side-by-side. [Use filters when assigning apps, policies, and profiles](https://learn.microsoft.com/en-us/intune/fundamentals/filters/overview)
- **Patch-level targeting is the payoff.** Pair version ranges with Windows quality-update policies (see `Intune/Troubleshooting/WUfB-A.md`). [Performance recommendations for filters](https://learn.microsoft.com/en-us/intune/fundamentals/filters/performance-recommendations)
- Background: [Jeroen Burgerhout (MVP), 10 Sep 2026](https://www.burgerhout.org/p/osversion-in-assignment-filters-is-dead-here-is-what-replaces-it) · parent topic `Intune/Troubleshooting/Filters-A.md`.
