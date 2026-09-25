# Intune Advanced Analytics (Anomalies, Device timeline, Battery health, Resource performance, Device scopes) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

> **Scope:** the Advanced Analytics reports layered on top of Endpoint analytics — **Anomalies**, **Device timeline**, **Battery health**, **Resource performance**, and **custom Device scopes**. Device query (single and multi-device) is covered in [DeviceQuery-B.md](DeviceQuery-B.md); base Endpoint analytics onboarding (Startup performance / App reliability / Work from anywhere not populating) is covered in [EndpointAnalytics-B.md](EndpointAnalytics-B.md). Fix the base layer first — every report here depends on it.
> Sources (fetched 2026-09-25): Learn [Advanced Analytics overview](https://learn.microsoft.com/en-us/intune/advanced-analytics/) (updated 2026-05-21), [Anomalies](https://learn.microsoft.com/en-us/intune/advanced-analytics/anomalies), [Device timeline](https://learn.microsoft.com/en-us/intune/advanced-analytics/device-timeline), [Battery health](https://learn.microsoft.com/en-us/intune/advanced-analytics/battery-health), [Resource performance](https://learn.microsoft.com/en-us/intune/advanced-analytics/resource-performance), [Device scopes](https://learn.microsoft.com/en-us/intune/advanced-analytics/device-scopes), [FAQ](https://learn.microsoft.com/en-us/intune/advanced-analytics/faq).

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

```powershell
# Tenant side (Graph PowerShell; read-only)
Connect-MgGraph -Scopes 'DeviceManagementManagedDevices.Read.All','Organization.Read.All' -NoWelcome

# 1. Is there an Advanced Analytics entitlement? (service-plan names vary by SKU/bundle — match loosely, confirm in admin center)
Get-MgSubscribedSku | ForEach-Object { $s=$_; $_.ServicePlans |
  Where-Object { $_.ServicePlanName -match 'AdvancedEA|Advanced_?Analytics|INTUNE_SUITE' } |
  Select-Object @{n='Sku';e={$s.SkuPartNumber}}, ServicePlanName, ProvisioningStatus }

# 2. Is Advanced Analytics data flowing? (beta endpoints — empty/403 is informative)
(Invoke-MgGraphRequest -Uri 'https://graph.microsoft.com/beta/deviceManagement/userExperienceAnalyticsAnomaly?$top=5').value |
  Select-Object anomalyName, severity, state, anomalyLatestOccurrenceDateTime
(Invoke-MgGraphRequest -Uri 'https://graph.microsoft.com/beta/deviceManagement/userExperienceAnalyticsBatteryHealthDevicePerformance?$top=5').value |
  Select-Object deviceName, maxCapacityPercentage, estimatedRuntimeInMinutes

# 3. Fleet-wide audit + CSVs
.\Intune\Scripts\Get-AdvancedAnalyticsReportAudit.ps1 -OutputFolder .\AA-Audit
```

| Observation | Meaning | Do |
|---|---|---|
| No matching service plan / `ProvisioningStatus` ≠ `Success` | Not licensed (or bundle not recognised by the regex) | Confirm SKU in admin center → Fix 1 |
| Licensed < 48 h ago, tabs missing | Provisioning window (Learn: up to 48 h after purchase/trial) | Wait; re-check at 48 h |
| Base Endpoint analytics reports empty too | Base layer broken — not an AA problem | [EndpointAnalytics-B.md](EndpointAnalytics-B.md) first |
| Battery/Resource tabs populated, **Anomalies** empty | Normal for small/quiet fleets — model needs high event volume | Fix 3 — expectation setting, not a fault |
| **Device timeline** tab missing on one device | Device is ConfigMgr-only (not Intune-managed/co-managed) | Fix 4 |
| Custom device scope shows **Insufficient Data** | < 10 devices in scope tag, or scope still processing (≤ 24 h), or scope toggled Off | Fix 5 |
| Battery report shows `Not available` / CSV `-1` | Desktop/no battery, or not enough drain data yet | Expected — Fix 6 |
| Tenant is **DoD** cloud and Resource performance missing | Documented: DoD excludes Resource performance and Device query | Not fixable — document |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Cloud: Public, GCC High or DoD (DoD: no Resource performance, no Device query)
 └─ Licence: Intune Plan 1/2 + Advanced Analytics entitlement (add-on / Intune Suite / qualifying bundle)
     └─ Auto-enabled on licence — up to 48 h to appear (no toggle to find)
         └─ Endpoint analytics configured in tenant (Reports > Endpoint analytics > Settings)
             └─ Device: Windows, Intune-managed or co-managed, Entra joined or hybrid joined
                 └─ Intune data collection policy applied + device RESTARTED at least once after
                     └─ Device online, reaching Microsoft diagnostic endpoints (no SSL inspection breaking them)
                         └─ ~24 h processing latency (longer for crash/restart events uploaded later)
                             ├─ Battery health  → needs a battery + enough drain history
                             ├─ Resource perf.  → Windows physical + Windows 365 Cloud PCs
                             ├─ Device timeline → Intune/co-managed only; replaces App reliability tab
                             ├─ Anomalies       → needs event VOLUME; cohorts only for Medium/High
                             └─ Device scopes   → 1 scope tag each, ≥10 devices, ≤20 active / 100 saved
```
</details>

---
## Diagnosis & Validation Flow

1. **Licence & provisioning.** Triage #1. Expected: at least one row with `ProvisioningStatus = Success`. If the customer "has E3", check [IntuneSuiteBaseLicensing-A.md](IntuneSuiteBaseLicensing-A.md) for whether their bundle actually includes it today — don't assume.
2. **Base layer.** Reports > Endpoint analytics > Startup performance shows devices? If not → [EndpointAnalytics-B.md](EndpointAnalytics-B.md). Advanced Analytics cannot work where base EA doesn't.
3. **Device eligibility** (on the device):
   ```powershell
   dsregcmd /status | Select-String 'AzureAdJoined|DomainJoined'
   Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Enrollments\*' -ErrorAction SilentlyContinue |
     Where-Object ProviderID -eq 'MS DM Server' | Select-Object UPN, ProviderID
   Get-Service DiagTrack | Select-Object Status, StartType   # expect Running / Automatic
   (Get-CimInstance Win32_OperatingSystem).LastBootUpTime        # must be AFTER the data-collection policy landed
   ```
   `AzureAdJoined : YES` (or hybrid), an `MS DM Server` enrollment, `DiagTrack` running, and a reboot since policy = eligible.
4. **Latency.** Learn: data typically refreshes every 24 h; restart/stop-error events that can't upload immediately appear later **with their original timestamp**. A crash "missing" from the timeline after 6 h is not a fault.
5. **Report-specific checks** — use the Fix that matches the triage row.

---
## Common Fix Paths

<details><summary>Fix 1 — Not licensed / wrong licence</summary>

1. Microsoft 365 admin center > Billing > Your products: confirm an Advanced Analytics-bearing SKU (standalone add-on, Intune Suite, or a bundle that now includes it).
2. Advanced Analytics is **tenant-enabled by licence** — there's no per-user assignment toggle in Intune to flip. Allow 48 h.
3. If a trial was started, note the trial end date in the ticket; reports disappear when it lapses.
</details>

<details><summary>Fix 2 — Licensed, but nothing Advanced-Analytics-specific shows</summary>

1. Re-validate base EA (Diagnosis step 2).
2. Confirm devices are Intune-managed or co-managed (ConfigMgr-only devices never get the AA single-device views).
3. Confirm the data collection policy is applied and **the device has restarted since** — the FAQ calls this out explicitly.
4. Check the network path from device to diagnostic endpoints (SSL inspection/proxy auth are the usual culprits — see EndpointAnalytics-A "network" section).
</details>

<details><summary>Fix 3 — Anomalies report empty or "missing" a known crash</summary>

This is usually **expected behaviour**:
- Thresholds are **predetermined and not customisable**; the models (threshold heuristic, paired t-test, population Z-score, time-series Z-score) need a **high volume** of hangs/crashes/stop-error restarts. A single user's crashing app won't surface.
- Device correlation groups (shared app version, driver, OS build, model) are only produced for **Medium and High** severity anomalies.
- Use **Device timeline** on the affected device instead to see the individual crash/hang events.

Escalate only if a genuinely fleet-wide crash spike (dozens of devices, same app) is absent after 48 h.
</details>

<details><summary>Fix 4 — Device timeline missing / "where's the App reliability tab?"</summary>

- With Advanced Analytics active, **Device timeline replaces Application reliability** in the device drill-down. The per-device **app reliability score** is no longer on that tab — get it from Reports > Endpoint analytics > Application reliability > **Device performance** tab, search the device.
- Timeline is **not available for ConfigMgr-only devices**. Enable co-management/Intune enrollment ([CoManagement-B.md](CoManagement-B.md)).
- Timestamps are localised to the **signed-in admin's** time zone — check that before telling a user "the crash didn't happen at 09:12".
</details>

<details><summary>Fix 5 — Custom device scope shows Insufficient Data / errors</summary>

1. Reports > Endpoint analytics > (e.g.) Startup performance > **Device scope** > **Manage device scopes**.
2. Scope **State** must be **On** (new scopes default to Off). Allow up to **24 h** processing.
3. Scope tag must cover **≥ 10 devices**.
4. Limits: **1 scope tag per device scope**, **20 active**, **100 saved**. Need multiple tags? Create a new combined scope tag and assign it to the device set.
5. Error in Manage device scopes = the underlying **scope tag was deleted** → edit to a valid tag or delete the device scope. Only the creator or a Global Administrator can delete it.
6. Creator needs Help Desk Operator / Endpoint Security Manager / Read Only Operator / Intune Role Administrator, or a custom role with **Roles/Read** + managed-device read.
</details>

<details><summary>Fix 6 — Battery / Resource performance values look wrong</summary>

- `Not available` in UI = `-1` in CSV export. Estimated runtime needs enough drain data; new batteries may show cycle count `0*`; counts >2 get `*` (UPS/external battery).
- Thresholds: capacity **<60 % = most impacted**, 60–80 % moderate; runtime **<3 h** most impacted. Low-design-capacity batteries always show low runtime — by design.
- Resource performance: CPU spike = >50 % usage, RAM spike = >75 %, both averaged over 14 days. CSV `HealthStatus` 0 Unknown / 1 Insufficient data / 2 Needs attention / 3 Meeting goals; `MachineType` `CPC` = Cloud PC.
- Good capacity + poor runtime → check the **App impact** tab (14-day per-app drain) before recommending hardware.
</details>

---
## Escalation Evidence

```
INTUNE ADVANCED ANALYTICS — ESCALATION
======================================
Ticket #: <>
Tenant ID / cloud (Public / GCC High / DoD): <>
AA licence SKU + service plan + ProvisioningStatus: <>
Licence start date (48 h passed? Y/N): <>
Report affected: <Anomalies / Device timeline / Battery health / Resource performance / Device scopes>
Base Endpoint analytics populated (Y/N): <>
Example device(s): <name, Intune device ID, join type, co-managed Y/N>
DiagTrack running (Y/N) / last reboot after policy (Y/N): <>
Graph beta endpoint result (count / 403 / empty): <>
Get-AdvancedAnalyticsReportAudit.ps1 output attached (Y/N): <>
Expected vs observed: <>
First noticed: <>
```

---
## 🎓 Learning Pointers
- Advanced Analytics is **switched on by licence**, not by a toggle — if it's licensed and still absent after 48 h, the problem is almost always the base Endpoint analytics layer. [Advanced Analytics overview](https://learn.microsoft.com/en-us/intune/advanced-analytics/).
- Anomalies uses fixed, non-customisable statistical models and needs volume; don't sell it to a 30-seat customer as "crash alerting". Its real value is the **correlation groups** (app version / driver / OS / model) plus the **at-risk** device list. [Anomalies report](https://learn.microsoft.com/en-us/intune/advanced-analytics/anomalies).
- Device timeline **replaces** App reliability in the device view — techs used to the old tab will think a score has vanished. [Device timeline](https://learn.microsoft.com/en-us/intune/advanced-analytics/device-timeline).
- Battery health + Resource performance are the MSP hardware-refresh story: export CSV (`-1` = unavailable) and sort by model to target warranty claims and RAM upgrades. [Battery health](https://learn.microsoft.com/en-us/intune/advanced-analytics/battery-health) · [Resource performance](https://learn.microsoft.com/en-us/intune/advanced-analytics/resource-performance).
- There's no connector to a SIEM/RMM; CSV export and Graph beta are the only ways out ([FAQ](https://learn.microsoft.com/en-us/intune/advanced-analytics/faq)). Deep dive: [AdvancedAnalytics-A.md](AdvancedAnalytics-A.md).
