# Intune Device Query (single & multiple devices) — Reference Runbook (Mode A: Deep Dive)
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

**Covers:** Intune Advanced Analytics device query in both forms — **single-device query** (live KQL against one Windows device, with in-blade remote actions) and **device query for multiple devices** (KQL over collected inventory across Windows, Apple and corporate Android). Licensing, RBAC, transport, the KQL subset and its device-query-specific quirks, throttles, and helpdesk/MSP operating patterns.

**Doesn't cover:** Properties catalog profile authoring and its registry limits (`PropertiesCatalog-A.md`), Endpoint analytics scores/onboarding (`EndpointAnalytics-A.md`), Remediations (`Remediations-A.md`), Defender Advanced Hunting (`Security/Sentinel/Hunting-A.md`), Configuration Manager CMPivot (on-prem analogue).

**Assumes:** Intune Plan 1/2 plus an Advanced Analytics entitlement (Microsoft lists it as an add-on subscription beyond Plan 1/2 — Intune Suite or a bundle that includes it; confirm SKU against current Microsoft pricing before quoting a customer); an admin with Intune RBAC rights.

Sources live-fetched run 261: Learn "Device query" and "Device query for multiple devices" (both ms.date 2026-09-01), "Advanced Analytics overview" (updated 2026-05-21), "Intune Data Platform Schema" (ms.date 2026-03-24).

---
## How It Works

<details><summary>Full architecture</summary>

### Two features, one name

```
                    ┌──────────── SINGLE-DEVICE QUERY (live) ────────────┐
Admin (Intune UI) → │ Intune service → WNS push → device agent executes   │ → result ≤128 KB back to portal
                    │ KQL locally against live OS state (WMI/registry/     │
                    │ event log/files) — "real time, immediate response"   │
                    └──────────────────────────────────────────────────────┘

                    ┌──────── DEVICE QUERY FOR MULTIPLE DEVICES (inventory) ─────────┐
Admin (Intune UI) → │ Intune data platform — KQL over inventory already collected:    │ → ≤~50,000 rows,
                    │  Windows: properties catalog → Device Inventory Agent (~24 h)   │   export ≤50,000 CSV,
                    │  iOS/iPadOS/macOS/Android Ent. corp: collected automatically    │   "Add all items to a group"
                    └─────────────────────────────────────────────────────────────────┘
```

The distinction explains nearly every ticket. Single-device query is **live**: if the device is offline or WNS can't reach it, it fails, but it sees current state (running processes, services, a registry value set five minutes ago, a specific event log entry). Multi-device query never contacts the device: it's fast and cross-platform, but only as fresh as the last inventory cycle and only includes entities you're collecting.

### Eligibility

| | Single-device | Multi-device |
|---|---|---|
| Platform | Windows | Windows; iOS/iPadOS; macOS; Android Enterprise COBO, COSU, COPE |
| Ownership | Corporate | Corporate |
| Join | Entra joined or Entra hybrid joined | n/a (Intune-managed) |
| Extra Windows prerequisite | Endpoint analytics onboarding | Properties catalog policy assigned |
| RBAC | Custom role with **Managed Devices/Query** + read perms | Help Desk Operator, or custom role with Organization/Read + Managed devices/Read |
| Cloud | Public, GCC High (DoD: **not** available) | same |

### Transport — WNS is mandatory

Single-device query uses Windows Push Notification Services both to wake the device and to return results. Microsoft is explicit that WNS "cannot be disabled or bypassed". The practical failure modes are (a) the `WpnService` service disabled by hardening baselines, (b) outbound 443 to WNS FQDNs blocked or SSL-inspected, (c) the "Turn off notifications network usage" policy (`NoCloudApplicationNotification`). This is the same dependency that makes other push-driven Intune actions sluggish, so a device that also syncs slowly after "Sync" is a strong WNS suspect.

### Entities

Single-device (live): `BiosInfo, Certificate, Cpu, DiskDrive, EncryptableVolume, FileInfo, LocalGroup, LocalUserAccount, LogicalDrive, MemoryInfo, OsVersion, Process, SystemEnclosure, SystemInfo, Tpm, WindowsAppCrashEvent, WindowsDriver, WindowsEvent, WindowsQfe, WindowsRegistry, WindowsService`.

Multi-device (inventory): Apple Auto Setup Admin Accounts, Apple Device States, Apple Update Settings, Battery, Bios Info, Bluetooth, Cellular, CPU, Device Storage, Disk Drive, Encryptable Volume, **Local AI Agent**, Logical Drive, Memory Info, Network Adapter, Os Version, Shared iPad, Sim Info, System Enclosure, SystemInfo, Time, Tpm, Video Controller, Windows Qfe — plus the linked **`Device`** entity (DeviceId, EntraDeviceId, DeviceName, SerialNumber, Manufacturer, Model, OSVersion, EnrollmentProfileName, EnrolledDateTime, CertExpirationDateTime, PrimaryUserId, LastSeenDateTime, Ownership, …).

Note what's missing from multi-device: processes, services, arbitrary registry, event logs, files. Those are live-only. (Selected HKLM registry values *can* be inventoried via the properties catalog Registry category — see `PropertiesCatalog-A.md`.)

Per-entity properties are in the Intune Data Platform Schema. `WindowsRegistry` is parameterised — you must pass the key, e.g. `WindowsRegistry('HKEY_LOCAL_MACHINE\\ServiceLastKnownStatus')`; e.g. `WindowsService` exposes `ServiceName, DisplayName, State, StartMode, ProcessId, Path, …`; `EncryptableVolume` exposes `WindowsDriveLetter, ProtectionStatus, EncryptionMethod, EncryptionPercentage, Locked, …`.

### The KQL subset

Table operators: `count, distinct, join, order by, project, take, top, where` (+ `summarize` — listed for multi-device; the single-device page lists aggregation functions "with the summarize operator" but omits `summarize` from its operator table, a documentation inconsistency; test before relying on it in single-device runbooks). Aggregations: `avg, count, countif, dcount, max, maxif, min, minif, percentile, sum, sumif`. Scalars: `ago, bin, case, datetime_add, datetime_diff, iif, indexof, isnotnull, isnull, now, strcat, strlen, substring, tostring`. Operators: comparisons, arithmetic, `like, contains, !contains, startswith, !startswith, endswith, !endswith, and, or`.

Device-query-specific rules that trip experienced KQL users:
- **`Device` is an entity, not a column value.** Use `Device.DeviceName`, `Device.SerialNumber` in `order by`/`summarize`/`distinct`/aggregations.
- **Joins** are implicitly per-device. Use `join X on Device` or omit `on`; `on Device.DeviceId` is no longer supported. Multi-device supports `innerunique` (default), `inner`, `leftouter`, `rightouter`, `fullouter`, `leftsemi`, `rightsemi`, `leftanti`, `rightanti`. Max **3** joins.
- **Name your aggregates** (`N = dcount(x)`) before referencing them downstream.
- **Single quotes** for string operators on single-device (the editor suggests doubles; they fail).
- `!like` unsupported; `now()` no offset; `datetime_add()` no negative amounts.

### Limits

| Limit | Single-device | Multi-device |
|---|---|---|
| Rate | 15 queries/min | 10 queries/min |
| Volume | — | 1,000 queries/**month** |
| Result | 128 KB string (truncated with row count message) | ~50,000 records; export ≤50,000 |
| Query length | 2,048 chars | — |
| Joins | — | ≤3 |
| In-grid search/filter | — | only when ≤50 rows |

### Data trust

Microsoft notes a local admin can alter client-sourced values (OS version, registry). Known data quirks: `Tpm` returns activated/enabled TRUE whenever TPM 2.0 is present; `WindowsRegistry` can't return root keys, 64-bit shared keys, or binary data; only the first NIC's domain is returned; `FileInfo` errors on files in use. Treat results as troubleshooting telemetry.

### Remote actions & groups

Single-device query surfaces Intune remote actions (restart, remediation, etc., per platform) next to results. Multi-device query can **Add all items to a group** — turning a finding into a targetable Entra security group for a Remediation, config profile, or CA policy.
</details>

---
## Dependency Stack

```
Layer 7  Result in portal (≤128 KB / ≤50k rows) → remote action / group creation / CSV
Layer 6  KQL valid for the device-query subset (entity rules, join rules, quotes)
Layer 5  Throttles: 15/min (single) · 10/min + 1,000/month (multi)
Layer 4  Data source
          ├─ Single: device online + WNS (WpnService, *.wns/*.notify.windows.com:443, no policy block)
          └─ Multi : inventory present (Windows properties catalog → Device Inventory Agent; others automatic)
Layer 3  Device eligibility: corporate-owned; Windows Entra/hybrid joined (single); supported platform (multi)
Layer 2  RBAC: Managed Devices/Query (single) · Help Desk Operator / read perms (multi); scope tags
Layer 1  Intune P1/P2 + Advanced Analytics entitlement, provisioned (≤48 h); Endpoint analytics configured; cloud ≠ DoD
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| No "Device Query" under Monitor anywhere | Advanced Analytics not active / <48 h / DoD cloud | Tenant add-ons; Reports > Endpoint analytics for AA reports |
| Blade visible but "Run" denied | Role lacks Managed Devices/Query | My permissions |
| Works on some Windows devices only | Ownership Personal, or Entra-registered only | Device overview |
| Spinner then timeout | WNS path broken or device offline | `Get-DeviceQueryReadiness.ps1` |
| Every push action is slow on that device | Same WNS problem | `WpnService`, 443 test |
| Multi-device returns Apple/Android rows only | No properties catalog on Windows | Configuration profiles |
| Multi-device missing a specific entity (e.g. Battery) | Category not collected in the profile | Profile categories |
| New Windows device absent from multi-device | First inventory not yet uploaded (~24 h) | Device Inventory Agent folder / wait |
| "query limit exceeded" | Per-minute throttle | Wait 60 s |
| Multi-device queries fail late in month | 1,000/month cap | Usage pattern |
| Red underline on `Device` in `summarize` | Entity used where scalar needed | Use `Device.<Property>` |
| Join fails after previously working | `on Device.DeviceId` no longer supported | Use `on Device` |
| String filter returns nothing / errors (single) | Double quotes on `contains`/`startswith` | Use single quotes |
| Registry value "missing" | Root key, 64-bit shared key, or binary value | Known limitation |
| TPM shows enabled on a device you know is off | Known TPM 2.0 reporting quirk | Validate with `Get-Tpm` via Remediation |

---
## Validation Steps

1. **Entitlement.** Intune admin center → Reports → Endpoint analytics shows *Resource performance / Anomalies / Battery health*. Good: present. Bad: absent → licence/provisioning.
2. **RBAC.** Tenant administration → Roles → My permissions contains Managed devices → Query. Good: yes. Bad: build a custom role (Playbook 1).
3. **Device eligibility.** Device overview: Ownership = Corporate, join = Entra/hybrid. Or via Graph:
   ```powershell
   Connect-MgGraph -Scopes DeviceManagementManagedDevices.Read.All
   Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<DeviceName>'" |
     Select-Object DeviceName, ManagedDeviceOwnerType, AzureAdRegistered, DeviceEnrollmentType, OperatingSystem, LastSyncDateTime
   ```
   Good: `company`, and `dsregcmd /status` on the device shows AzureAdJoined YES. Bad: `personal`, or a device that is only Entra-registered (workplace-joined).
4. **Transport (on device).** `Get-Service WpnService` → Running; `Test-NetConnection client.wns.windows.com -Port 443` → `TcpTestSucceeded : True`; no `NoCloudApplicationNotification = 1`.
5. **Smoke query.** `OsVersion` (single) returns one row in seconds. Bad: timeout → back to step 4.
6. **Inventory (multi).** `Cpu | summarize N = count() by Device.OSVersion` includes Windows builds. Bad: none → properties catalog.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Which feature?** Live single-device vs. inventory multi-device. Different transport, prerequisites, and RBAC.

**Phase 2 — Tenant layer.** Licence, 48 h provisioning, cloud (DoD excluded), Endpoint analytics configured.

**Phase 3 — Admin layer.** Role permissions and scope tags (a scope-tag mismatch hides the device entirely, which looks like "device not found").

**Phase 4 — Device layer.** Ownership, join type, online, WNS. For co-managed devices, confirm the Intune side is healthy (`CoManagement-A.md`).

**Phase 5 — Query layer.** Reduce to a one-entity query, then add clauses back. Apply device-query KQL rules (entity, joins, quotes, named aggregates).

**Phase 6 — Limits.** Truncation (narrow with `where`/`project`), per-minute throttles, monthly cap.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Least-privilege helpdesk role for live query</summary>

Tenant administration → Roles → Create (Windows) → permissions: **Managed devices: Read, Query**; **Organization: Read**; optionally **Remote tasks** for the actions you want L1/L2 to run from results (e.g. Reboot now, Run remediation). Assign with scope tags matching the customer/site. Validate with an L1 test account. Rollback: remove the assignment.
</details>

<details><summary>Playbook 2 — Restore WNS on hardened devices</summary>

1. Identify the blocker: `Get-Service WpnService`; `gpresult /h` for *Turn off notifications network usage*; proxy/firewall logs for `*.wns.windows.com` / `*.notify.windows.com`.
2. Re-enable the service via the owning baseline/profile (not ad hoc), set Automatic.
3. Exclude WNS FQDNs from TLS inspection.
4. Re-test with `OsVersion`.
Rollback: n/a (returns to Windows default). If the customer deliberately blocks WNS for policy reasons, single-device query is not viable — use Remediations instead.
</details>

<details><summary>Playbook 3 — Enable Windows data for multi-device query</summary>

1. Create a **Properties catalog** profile covering the categories your fleet queries need (CPU, OS Version, Encryptable Volume, Tpm, Battery, Memory Info, Network Adapter, Windows Qfe, Local AI Agent…).
2. Assign to all corporate Windows devices (use a filter for ownership if needed).
3. Wait ~24 h; validate with `Cpu | summarize N = count() by Device.OSVersion`.
Rollback: remove the assignment; previously collected data persists up to 28 days (see `PropertiesCatalog-A.md`).
</details>

<details><summary>Playbook 4 — Helpdesk query library (replace remote-control sessions)</summary>

Save these in the ITSM KB (Microsoft recommends saved queries for recurring investigations):

```kusto
// Is a service running? (single)
WindowsService | where ServiceName == 'Spooler' | project ServiceName, State, StartMode

// Top memory processes (single)
Process | top 10 by WorkingSetSizeBytes | project ProcessName, ProcessId, WorkingSetSizeBytes, Path

// App config registry value (single)
// WindowsRegistry is a function: pass the key (doubled backslashes)
WindowsRegistry('HKEY_LOCAL_MACHINE\\SOFTWARE\\Contoso\\App') | project RegistryKey, ValueName, ValueType, ValueData

// Recent patches (single)
WindowsQfe | project Caption, QfeDescription, InstalledDate | order by InstalledDate desc

// Fleet: unprotected BitLocker volumes → group for remediation (multi)
EncryptableVolume | where ProtectionStatus != "PROTECTED" | project Device, WindowsDriveLetter, ProtectionStatus

// Fleet: OS build distribution (multi)
OsVersion | summarize DevicesCount = count() by OsVersion

// Fleet: TPM disabled (multi)
Tpm | where Enabled != true
```
Then use **Add all items to a group** on multi-device results to target a Remediation.
</details>

<details><summary>Playbook 5 — Staying under the 1,000/month cap (MSP multi-tenant)</summary>

The cap is per tenant. For each customer: define a small monthly report set, run once, **Export** (≤50,000 rows) and filter offline; avoid iterative re-runs to refine filters. Use Copilot in Intune to draft KQL, but review before running since each attempt counts.
</details>

---
## Evidence Pack

```powershell
<# Device query evidence pack — run elevated on the affected Windows device #>
$out = Join-Path $env:TEMP ("DeviceQuery-Evidence-{0:yyyyMMdd-HHmm}" -f (Get-Date))
New-Item -ItemType Directory -Path $out -Force | Out-Null

dsregcmd /status > "$out\dsregcmd.txt"
Get-Service WpnService, dmwappushservice -ErrorAction SilentlyContinue |
  Select-Object Name, Status, StartType | Export-Csv "$out\services.csv" -NoTypeInformation
foreach ($h in 'client.wns.windows.com') {
  Test-NetConnection $h -Port 443 -WarningAction SilentlyContinue |
    Select-Object ComputerName, RemoteAddress, TcpTestSucceeded | Export-Csv "$out\wns-connectivity.csv" -NoTypeInformation -Append
}
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications',
                 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications' -ErrorAction SilentlyContinue |
  Format-List * | Out-File "$out\wns-policy.txt"
netsh winhttp show proxy > "$out\winhttp-proxy.txt"
Get-ChildItem 'C:\Program Files\Microsoft Device Inventory Agent' -Recurse -ErrorAction SilentlyContinue |
  Select-Object FullName, Length, LastWriteTime | Export-Csv "$out\inventory-agent.csv" -NoTypeInformation
Get-WinEvent -LogName 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin' -MaxEvents 200 -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, LevelDisplayName, Message | Export-Csv "$out\mdm-admin-events.csv" -NoTypeInformation
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
Write-Host "Evidence: $out.zip"
```

---
## Command Cheat Sheet

| Task | Command / KQL |
|---|---|
| Readiness script | `Intune/Scripts/Get-DeviceQueryReadiness.ps1` |
| Join state | `dsregcmd /status` |
| WNS service | `Get-Service WpnService` |
| WNS reachability | `Test-NetConnection client.wns.windows.com -Port 443` |
| WNS policy | `Get-ItemProperty HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications` |
| Inventory agent | `Test-Path 'C:\Program Files\Microsoft Device Inventory Agent'` |
| Ownership via Graph | `Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '<name>'" \| Select ManagedDeviceOwnerType, DeviceEnrollmentType` |
| Smoke test (single) | `OsVersion` |
| Service state | `WindowsService \| where ServiceName == 'WpnService'` |
| Registry value | `WindowsRegistry('HKEY_LOCAL_MACHINE\\<path>') \| project ValueName, ValueData` |
| Fleet OS spread | `OsVersion \| summarize DevicesCount = count() by OsVersion` |
| Unencrypted volumes | `EncryptableVolume \| where ProtectionStatus != "PROTECTED"` |
| Join correctly | `EncryptableVolume \| join LogicalDrive on Device` |
| Sort by device | `MemoryInfo \| order by Device.DeviceName` |

---
## 🎓 Learning Pointers
- Picture the two data paths (live-over-WNS vs. inventory) before troubleshooting — most "device query is broken" tickets are a mismatch between the question and the feature. [Device query](https://learn.microsoft.com/en-us/intune/advanced-analytics/device-query) · [Multiple devices](https://learn.microsoft.com/en-us/intune/advanced-analytics/device-query-multiple-devices)
- The schema page is the source of truth for property names and which entity works where ("Single device query on-demand" vs "Device query for multiple devices" vs "Inventory"). [Intune Data Platform Schema](https://learn.microsoft.com/en-us/intune/advanced-analytics/ref-data-platform-schema)
- Device query's `Device` entity and per-device implicit joins are its biggest departures from Log Analytics KQL; if you write Sentinel/Defender hunting queries, unlearn `on DeviceId`.
- Advanced Analytics is an add-on entitlement; confirm what each customer actually owns before promising live query in an SOW. [Advanced Analytics overview — prerequisites](https://learn.microsoft.com/en-us/intune/advanced-analytics/#prerequisites)
- Pair multi-device findings with **Add all items to a group** + Remediations for a find-and-fix loop without scripts running blind across the fleet. See `Remediations-A.md`.
- ConfigMgr veterans: this is the cloud analogue of [CMPivot](https://learn.microsoft.com/en-us/intune/configmgr/core/servers/manage/cmpivot) — similar idea, different entity set and limits.
