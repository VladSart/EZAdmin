# Intune Device Query (single & multiple devices) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

**Scope:** Intune Advanced Analytics **Device query** — the single-device live KQL blade (Devices > Windows > *device* > Monitor > Device Query) and **Device query for multiple devices** (Devices > Device query). Covers "blade missing", "query fails / times out", "no results for Windows devices", KQL syntax errors, and throttling.
**Not in scope:** Properties catalog profile design (`PropertiesCatalog-B.md`), Endpoint analytics onboarding in general (`EndpointAnalytics-B.md`), Defender Advanced Hunting (`Security/Sentinel/Hunting-B.md`).

Sources (live-fetched run 261): Learn "Device query" (ms.date 2026-09-01), "Device query for multiple devices" (ms.date 2026-09-01), "Advanced Analytics overview" (updated 2026-05-21).

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

First decide **which** feature is failing — they have different transports and prerequisites:

| | Single-device query | Multiple-device query |
|---|---|---|
| Data | **Live**, from the device, in real time | **Inventory** already collected (not live) |
| Transport | WNS push → device answers immediately | None at query time |
| Platforms | Windows only | Windows, iOS/iPadOS, macOS, Android Enterprise COBO/COSU/COPE |
| Windows prerequisite | Corporate-owned, Entra joined or hybrid joined | Corporate-owned + **properties catalog policy** deployed |
| RBAC | Custom role with **Managed Devices/Query** + read perms | Help Desk Operator, or custom role with Organization/Read + Managed devices/Read |
| Throttle | 15 queries/min | 10 queries/min, **1,000/month** |

Run on the affected Windows device (elevated) for single-device failures:

```powershell
# 1. Join state (need AzureAdJoined : YES, or DomainJoined + AzureAdJoined for hybrid)
dsregcmd /status | Select-String 'AzureAdJoined','DomainJoined','TenantName'

# 2. WNS client service — mandatory transport for single-device query
Get-Service WpnService | Select-Object Name, Status, StartType

# 3. WNS reachability
Test-NetConnection client.wns.windows.com -Port 443 | Select-Object ComputerName, TcpTestSucceeded

# 4. Policy that turns off WNS network usage (either hive)
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications','HKCU:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\PushNotifications' -ErrorAction SilentlyContinue |
    Select-Object PSPath, NoCloudApplicationNotification

# 5. Multi-device only: is the Device Inventory Agent (properties catalog collector) installed?
Test-Path 'C:\Program Files\Microsoft Device Inventory Agent'
```

| Result | Meaning | Do this |
|---|---|---|
| **Device Query** missing under Monitor for every device | Advanced Analytics not licensed / not yet provisioned, or you lack Managed Devices/Query | Fix 1 |
| Blade present for some devices, not others | Those devices are personal-owned, not Entra/hybrid joined, or not Windows | Fix 2 |
| Query spins then fails / times out | WNS blocked, WpnService stopped, device offline | Fix 3 |
| `NoCloudApplicationNotification = 1` | WNS network usage disabled by policy | Fix 3 |
| Multi-device query returns rows for Macs/iOS but **no Windows** | No properties catalog policy on Windows devices, or collected <24 h ago | Fix 4 |
| "query limit exceeded" | Throttle (15/min single, 10/min multi) | Wait a minute; batch queries |
| Multi-device queries start failing near month-end | 1,000 queries/month cap | Fix 6 |
| Syntax error / red underline on `Device` | Using `Device` entity where a scalar is needed | Fix 5 |
| Result shows "rows truncated" | 128 KB result limit (single) / ~50,000 records (multi) | Add `where`/`project`/`take` |
| DoD tenant: no Device query at all | Documented: DoD Advanced Analytics excludes Device query | Not available — use Remediations |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Intune Plan 1/2 + Advanced Analytics entitlement (Intune Suite / add-on / E5-class bundle that includes it)
└── Tenant provisioned (up to 48 h after licence/trial)
    └── Endpoint analytics configured in tenant, devices onboarded (Windows)
        ├── SINGLE-DEVICE (live)
        │   ├── Windows, Intune-managed, ownership = Corporate
        │   ├── Entra joined OR Entra hybrid joined
        │   ├── Admin role: custom role incl. Managed Devices/Query (+ Org/Read, Managed devices/Read)
        │   └── WNS: WpnService running, *.wns.windows.com / *.notify.windows.com reachable,
        │        not disabled by policy  → device executes KQL → result ≤128 KB within limits
        └── MULTI-DEVICE (inventory)
            ├── Corporate-owned
            ├── Windows: properties catalog policy assigned → Device Inventory Agent → inventory (~24 h)
            ├── iOS/iPadOS, macOS, Android Enterprise corp: collected automatically
            ├── Admin role: Help Desk Operator or custom read role
            └── Limits: 10/min, 1,000/month, ≤3 joins, ~50,000 rows returned
```
</details>

---
## Diagnosis & Validation Flow

1. **Confirm licensing/provisioning.** Intune admin center → Tenant administration → Intune add-ons (or Reports > Endpoint analytics shows Advanced Analytics reports such as *Anomalies* / *Resource performance*).
   - Expected: Advanced Analytics active. If just purchased: allow up to **48 h**.

2. **Confirm your role.** Tenant administration → Roles → My permissions.
   - Single-device: need **Managed Devices → Query**. Built-in Help Desk Operator is documented for *multi*-device only; don't assume it grants live query.

3. **Check the device record.** Devices > Windows > device > Overview: *Ownership* must be **Corporate**; join type Entra joined / hybrid.

4. **Run the device-side checks** (Triage #1–#4, or `Intune/Scripts/Get-DeviceQueryReadiness.ps1`).
   - Expected: `WpnService Running`, `TcpTestSucceeded : True`, no `NoCloudApplicationNotification = 1`.

5. **Test with a trivial query** to separate transport from KQL problems:
   ```kusto
   OsVersion
   ```
   - Returns a row → transport fine; the original query's KQL is the problem (Fix 5).
   - Fails → transport/prereq (Fix 2/3).

6. **Multi-device, Windows rows missing:** confirm a properties catalog profile is assigned to the device group and was applied ≥24 h ago; confirm `C:\Program Files\Microsoft Device Inventory Agent` exists on a sample device.

---
## Common Fix Paths

<details><summary>Fix 1 — Blade missing tenant-wide (licence / RBAC)</summary>

- Verify the Advanced Analytics entitlement is assigned and wait up to 48 h after purchase/trial start.
- Create/assign a custom Intune role that includes **Managed Devices: Query**, plus Organization: Read and Managed devices: Read, scoped with the right scope tags.

```powershell
# List Intune role definitions that include the Query permission (Graph, read-only)
Connect-MgGraph -Scopes DeviceManagementRBAC.Read.All
(Invoke-MgGraphRequest GET 'https://graph.microsoft.com/beta/deviceManagement/roleDefinitions').value |
  Where-Object { ($_.rolePermissions.resourceActions.allowedResourceActions -join ' ') -match 'ManagedDevices_Query' } |
  Select-Object displayName, isBuiltIn
```
(If nothing returns, no role grants live query — create one in Tenant administration → Roles → Create.)
</details>

<details><summary>Fix 2 — Device not eligible (ownership / join / platform)</summary>

- Change ownership to **Corporate** if the device is corporate (Devices > device > Properties > Device ownership). ⚠️ Changing ownership also changes what data Intune collects and what actions are allowed — confirm with the customer's privacy stance.
- Personal/Entra-registered-only devices aren't supported for single-device query. Workplace-joined → no.
- Non-Windows → use multi-device query instead (inventory, not live).
</details>

<details><summary>Fix 3 — WNS transport broken</summary>

```powershell
# Service
Set-Service WpnService -StartupType Automatic
Start-Service WpnService

# Firewall/proxy: allow outbound 443 to *.wns.windows.com and *.notify.windows.com (per Intune network endpoints)
Test-NetConnection client.wns.windows.com -Port 443

# Policy disabling WNS network usage — find the source GPO/Intune profile, don't just delete the value
gpresult /h "$env:TEMP\gp.html"; Start-Process "$env:TEMP\gp.html"
```
Microsoft is explicit: WNS can't be bypassed; if it's blocked, single-device query fails. SSL inspection of WNS traffic commonly breaks it — exclude those FQDNs from inspection.
Rollback: none needed (restores default behaviour).
</details>

<details><summary>Fix 4 — Multi-device query has no Windows data</summary>

1. Devices > Configuration > Create > Windows 10 and later > **Properties catalog**; select the categories your queries use (e.g. CPU, OS Version, Encryptable Volume, Tpm, Battery).
2. Assign to the Windows device group.
3. Wait ~24 h for first inventory; verify on a device: `Test-Path 'C:\Program Files\Microsoft Device Inventory Agent'`.
Note: an entity only returns data for categories you actually collect — `Battery` rows won't appear if Battery isn't in the profile. See `PropertiesCatalog-B.md` for the 100-registry-key per-device cap.
</details>

<details><summary>Fix 5 — KQL errors specific to device query</summary>

- `Device` is an **entity**; use a scalar for `summarize`/`distinct`/`order by`: `order by Device.DeviceName`, not `order by Device`.
- Joins: use `on Device` (or omit `on`). `on Device.DeviceId` is **no longer supported**.
- Name aggregates: `summarize N = dcount(DeviceId) | order by N` (unnamed `dcount_DeviceId` fails).
- Max **3** joins per query; `!like` unsupported; single-device string operators (`contains`, `startswith`, …) need **single quotes** even though the editor suggests double.
- `datetime_add()` doesn't accept negative amounts — use `ago()` instead.
- Queries ≤2,048 characters (single-device).

Working patterns:
```kusto
EncryptableVolume
| where ProtectionStatus != "PROTECTED"
| join LogicalDrive on Device
```
```kusto
WindowsService
| where ServiceName == 'WpnService'
| project ServiceName, State, StartMode
```
</details>

<details><summary>Fix 6 — Monthly cap hit (1,000 multi-device queries)</summary>

The cap is tenant-level. Move recurring fleet questions to saved queries run on a schedule by people, not by refreshing, and push anything repeated daily into Remediations / reports. Export (up to 50,000 rows to CSV) once rather than re-running for different filters.
</details>

---
## Escalation Evidence

```
Ticket: Intune Device query — <single | multiple> — <symptom>
Tenant / cloud (Commercial / GCC High / DoD): <...>
Advanced Analytics active since:              <date>
Admin UPN + role(s) used:                     <...>  Has Managed Devices/Query? <Y/N>
Device name / Intune device ID:               <...>
Ownership / join type / OS build:             <Corporate|Personal> / <Entra|Hybrid> / <build>
WpnService status / WNS 443 test:             <Running|..> / <True|False>
NoCloudApplicationNotification present?:      <Y/N, hive>
Properties catalog profile assigned (multi):  <name, assigned date>
Exact query text:                             <KQL>
Exact error / screenshot / time (UTC):        <...>
Get-DeviceQueryReadiness.ps1 CSV attached:    <Y/N>
```

---
## 🎓 Learning Pointers
- Single-device and multi-device query are different products under one name: live-over-WNS vs. collected inventory. Diagnose the right one first. [Device query](https://learn.microsoft.com/en-us/intune/advanced-analytics/device-query) · [Device query for multiple devices](https://learn.microsoft.com/en-us/intune/advanced-analytics/device-query-multiple-devices)
- WNS is a hard dependency — include `*.wns.windows.com` / `*.notify.windows.com` in every customer's proxy/SSL-inspection exclusion baseline. [Intune network endpoints](https://learn.microsoft.com/en-us/intune/intune-service/fundamentals/intune-endpoints)
- Multi-device Windows data only exists for property categories you collect; plan the properties catalog profile around the queries helpdesk needs. See `PropertiesCatalog-A.md`.
- Query results can drive **Add all items to a group** — a fast way to build a remediation/CA target group from a KQL finding (e.g. unencrypted volumes).
- Local admins can alter client-reported values (OS version, registry) — treat device query as troubleshooting telemetry, not a tamper-proof compliance source. [Advanced Analytics overview](https://learn.microsoft.com/en-us/intune/advanced-analytics/)
