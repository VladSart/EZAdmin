# Intune Advanced Analytics (Anomalies, Device timeline, Battery health, Resource performance, Device scopes) — Reference Runbook (Mode A: Deep Dive)
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

**Covers:** the Advanced Analytics (AA) report layer in Intune — Anomalies, Device timeline, Battery health, Resource performance and custom Device scopes — how each is fed, what each can and can't tell you, and how to operationalise them in an MSP (proactive tickets, hardware refresh, post-change regression checks).

**Does not cover:** Device query / Device query for multiple devices ([DeviceQuery-A.md](DeviceQuery-A.md)); base Endpoint analytics onboarding, scoring and the data-collection pipeline ([EndpointAnalytics-A.md](EndpointAnalytics-A.md)); licensing economics ([IntuneSuiteBaseLicensing-A.md](IntuneSuiteBaseLicensing-A.md)); STIG audit baseline ([STIGAuditBaseline-A.md](STIGAuditBaseline-A.md)).

**Assumes:** Intune Plan 1/2 plus an AA entitlement; Windows devices that are Intune-managed or co-managed and Entra joined or hybrid joined; an admin with Intune reporting rights.

Sources fetched 2026-09-25 (run 263): Learn Advanced Analytics overview (updated 2026-05-21), Anomalies, Device timeline, Battery health, Resource performance, Device scopes (all ms.date 2026-03-24), Advanced Analytics FAQ (updated 2026-03-30).

---
## How It Works
<details><summary>Full architecture</summary>

### Layering
AA is **not a separate product surface**. It extends Endpoint analytics (EA) in place: new tabs appear under **Reports > Endpoint analytics**, and new tabs appear in the **single-device view** (Devices > Windows > device > User Experience). Enablement is automatic once licence requirements are met — Learn says allow **up to 48 hours** after purchase or trial start. There's no admin toggle, which is why "we bought it and nothing changed" tickets are usually base-EA problems in disguise.

```
 Windows device (Intune / co-managed, Entra or hybrid joined)
   │  DiagTrack + Intune data collection policy  (restart needed after policy lands)
   ▼
 Microsoft diagnostic ingestion ──► Intune data platform (≈24 h processing)
   │
   ├── Endpoint analytics (base): Startup perf · App reliability · Work from anywhere
   │
   └── Advanced Analytics (licence-gated)
         ├─ Tenant reports:   Anomalies · Battery health · Resource performance · Device scopes
         ├─ Device views:     Device timeline (replaces App reliability tab) · Battery · Resource · Device query
         └─ Other:            Device query (multi-device, under Devices) · STIG audit baseline
```

### Anomalies
Monitors **app hangs, app crashes and Stop Error Restarts** and flags device **cohorts** whose behaviour is statistically unusual. Four models (Learn):

| Model | What it catches | Weakness |
|---|---|---|
| Threshold heuristic | Devices breaching fixed thresholds for hangs/crashes/stop errors | Thresholds are **predetermined, not customisable** |
| Paired t-test | Before/after shifts on the same devices (e.g. stop errors after a policy change, crashes after an OS update) | Needs a clear change boundary |
| Population Z-score | Outlier devices/apps against the fleet mean | Needs **large datasets** to be accurate |
| Time-series Z-score | Sliding-window deviation over time | Needs enough history per window |

Each anomaly has severity, state, first/last occurrence, affected devices and the detecting model. For **Medium and High** severity only, AA builds **device correlation groups** — devices sharing attributes such as app version, driver update, OS version or model — with a **prevalence rate** (% of the group affected) and a count of **at-risk** devices (share the attributes, not yet affected). The FAQ is explicit that missing anomalies on correctly licensed devices are usually a **volume** issue: devices must be actively used and a high event count is needed before something is flagged.

**Operational meaning:** Anomalies is a *fleet regression detector*, not per-user crash alerting. It pays off after Patch Tuesday, driver pushes and app updates in fleets large enough for the Z-score models to work.

### Device timeline
A per-device, low-latency event history: **app crash, app unresponsive, device boot, device sign-in, anomaly detected**. Searchable by event name/detail; filterable by source, level and time range. Most events land within 24 h; restart/stop-error events that couldn't upload at the time arrive later but keep their **original timestamp**. Timestamps display in the **signed-in admin's** time zone.

Two traps: it **replaces the Application reliability tab** in tenants with AA (the per-device app reliability score then lives only in the EA Application reliability report's Device performance tab), and it's **not available for ConfigMgr-only devices**.

### Battery health
Score = weighted average of **capacity score** (full-charge vs design capacity) and **runtime score** (estimated runtime on full charge at the plugged-in usage pattern), each 0–100 averaged across devices.

| Insight | Rule (Learn) |
|---|---|
| Low capacity | <60 % most impacted; 60–80 % moderately impacted |
| Low runtime | <3 h estimated runtime most impacted |
| Good capacity, poor runtime | Power-hungry/inefficient apps **or** a battery designed for low capacity — check **App impact** |

Tabs: Device performance (incl. cycle count and 14-day top apps), Model performance, OS performance, App impact (14-day cumulative drain per app). CSV export writes unavailable values as `-1`.

### Resource performance
0–100 score, weighted average of **CPU spike time score** (spike = >50 % usage) and **RAM spike time score** (spike = >75 %), each averaged over 14 days relative to usage duration. Covers Windows physical devices **and Windows 365 Cloud PCs** (W365 licences include this report for Cloud PCs). Recommendations: upgrade CPU/RAM on physical devices, move Cloud PCs to a higher configuration. CSV quirks: `HealthStatus` 0–3 (Unknown / Insufficient data / Needs attention / Meeting goals), `MachineType` Physical/CPC/Others, some columns exported as double. Not available in DoD cloud.

### Device scopes
Filter EA/AA reports (Startup performance, Work from anywhere, Application reliability, Battery health) by a **single Intune scope tag**. Default Off; up to 24 h to process after switching On; ≥10 devices or you get *Insufficient Data*; **100 saved / 20 active**; only creator or Global Admin can delete; deleting the underlying scope tag breaks the device scope. For MSPs with a multi-customer-in-one-tenant or multi-site model, scope tags per site/department become per-site scorecards.

### Data egress
No connector to other monitoring tools (FAQ). Out paths: CSV export in the portal, and the Graph **beta** `userExperienceAnalytics*` resources (used by `Get-AdvancedAnalyticsReportAudit.ps1`). Beta shapes can change — treat scripted output as best-effort.
</details>

---
## Dependency Stack

```
[7] Operational use: proactive tickets, refresh planning, post-change regression reviews
[6] Report-specific gates: volume (Anomalies) · battery present (Battery) · Intune/co-managed (Timeline)
    · ≥10 devices + 1 scope tag (Device scopes) · not DoD (Resource perf)
[5] ≈24 h processing (+ delayed upload of crash/restart details, original timestamps kept)
[4] Telemetry path: DiagTrack running · device online · diagnostic endpoints reachable (no breaking SSL inspection)
[3] Intune data collection policy applied + device restarted at least once afterwards
[2] Device eligibility: Windows · Intune-managed or co-managed · Entra joined / hybrid joined · EA-onboarded
[1] Tenant: EA configured · AA licence (auto-enabled, ≤48 h) · cloud = Public / GCC High / DoD (reduced)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| No AA tabs anywhere | No AA licence, or < 48 h since purchase/trial | `Get-MgSubscribedSku` service plans; licence date |
| AA tabs present, all empty | Base EA not collecting | EA Startup performance populated? [EndpointAnalytics-A.md](EndpointAnalytics-A.md) |
| Some devices never appear | Not rebooted since policy; ConfigMgr-only; DiagTrack disabled | Validation step 3 |
| Anomalies empty for weeks | Fleet too small/quiet; thresholds not met | FAQ: volume requirement; use Device timeline instead |
| Anomaly has no correlation groups | Severity Low | By design — cohorts only for Medium/High |
| App reliability tab "disappeared" | Replaced by Device timeline under AA | EA > Application reliability > Device performance |
| Crash missing from timeline | < 24 h, or device hadn't rebooted to upload stop-error details | Re-check later; original timestamp will show |
| Timeline times look wrong | Displayed in admin's time zone | Compare with device local time |
| Device scope "Insufficient Data" | < 10 devices, still processing, or Off | Manage device scopes state; tag membership |
| Device scope error banner | Scope tag deleted | Edit to valid tag or delete scope |
| Battery `Not available` / `-1` | No battery, insufficient drain data | Expected |
| Low runtime on healthy battery | App drain or low-design-capacity battery | App impact tab |
| Resource performance missing | DoD cloud, or non-Windows device | Tenant cloud; platform |

---
## Validation Steps

1. **Licence present and provisioned**
   ```powershell
   Get-MgSubscribedSku | Select-Object SkuPartNumber -ExpandProperty ServicePlans |
     Where-Object ServicePlanName -match 'AdvancedEA|Advanced_?Analytics|INTUNE_SUITE' |
     Select-Object SkuPartNumber, ServicePlanName, ProvisioningStatus
   ```
   Good: `ProvisioningStatus : Success`. Bad: no rows (confirm SKU manually — bundle plan names differ) or `PendingProvisioning`.
2. **AA Graph surfaces answer**
   ```powershell
   Invoke-MgGraphRequest -Uri 'https://graph.microsoft.com/beta/deviceManagement/userExperienceAnalyticsResourcePerformance?$top=1'
   ```
   Good: a `value` array (may be empty early on). Bad: 403 (scope/role) or 400/404 (beta shape change — use the portal).
3. **Device eligible and reporting**
   ```powershell
   dsregcmd /status | Select-String 'AzureAdJoined|DomainJoined|DeviceId'
   Get-Service DiagTrack | Select-Object Status, StartType
   (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
   ```
   Good: joined, `Running/Automatic`, reboot after policy deployment. Bad: DiagTrack `Disabled` (hardening baseline) — AA and EA both go blind.
4. **Report populated** — Reports > Endpoint analytics > Battery health / Resource performance show device counts; a sample device shows a Device timeline tab with boot/sign-in events.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Entitlement.** Licence → 48 h → AA tabs visible. If tabs never appear, it's commercial, not technical.

**Phase 2 — Base pipeline.** If EA base reports are empty, stop and work [EndpointAnalytics-A.md](EndpointAnalytics-A.md) (data collection policy, DiagTrack, network). AA inherits every base failure.

**Phase 3 — Device population.** Compare Intune Windows device count to AA report device count. Gaps cluster around: ConfigMgr-only devices, devices not rebooted since policy, devices offline > 14 days, desktops (Battery only).

**Phase 4 — Report semantics.** Most "bug" reports at this point are design behaviour: anomaly volume thresholds, Medium/High-only cohorts, Timeline replacing App reliability, admin-time-zone timestamps, scope limits, `-1` in CSV.

**Phase 5 — Escalate.** Only with: licensed ≥ 48 h, base EA healthy, eligible rebooted devices, and a report still empty after 72 h — or a fleet-wide crash spike that Anomalies doesn't surface.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Monthly post-Patch-Tuesday anomaly review (MSP routine)</summary>

1. Day +3 after Patch Tuesday / driver ring promotion: open **Anomalies**, sort by severity, filter state = active.
2. For each Medium/High: open correlation groups, note common factors (app version, driver, OS build, model) and **prevalence**.
3. Pivot to **Device timeline** on 2–3 affected devices to confirm the event pattern (restarts vs app crash).
4. Remediate on a pilot subset (driver rollback, app update, KIR — see `Windows/Troubleshooting/KnownIssueRollback-A.md`), watch 48 h, then push to the **at-risk** devices listed by the correlation group.
5. Record the anomaly in the ITSM known-issue list so L1 links incoming tickets.

Rollback: remediation-specific (driver rollback via Windows Update for Business driver policies, app version pin in Intune).
</details>

<details><summary>Playbook 2 — Battery warranty sweep</summary>

1. Run `Get-AdvancedAnalyticsReportAudit.ps1 -CapacityThreshold 60 -RuntimeThresholdMinutes 180`.
2. Join the battery CSV with warranty data (OEM API or asset register) on serial/device name.
3. Raise warranty claims for in-warranty devices with capacity < 60 %; schedule budgeted replacements for 60–80 %.
4. For "good capacity, poor runtime" rows, check **App impact** first — a Teams/browser extension issue is cheaper than batteries.

No destructive steps.
</details>

<details><summary>Playbook 3 — RAM/CPU right-sizing (including Cloud PCs)</summary>

1. Resource performance > Model performance: identify models with low scores.
2. Device performance: filter RAM spike time score 0–40; export.
3. Physical: RAM upgrade where the chassis allows, otherwise bring forward refresh. Cloud PCs: resize to a higher SKU (see `Azure/Windows365` runbooks — resize requires a Cloud PC restart/reprovision window).
4. Re-check after 14 days (the metric is a 14-day rolling average).

Rollback (Cloud PC): resize down again — note licence change implications.
</details>

<details><summary>Playbook 4 — Per-site / per-department scorecards with Device scopes</summary>

1. Ensure each site has a dedicated Intune **scope tag** assigned to its devices (one tag per scope — make a combined tag if you need a union).
2. EA > Startup performance > Device scope > Manage device scopes > add scope (tag) > name > **State On**.
3. Wait ≤ 24 h; confirm ≥ 10 devices.
4. Keep under 20 active scopes — rotate seasonal ones Off.

Rollback: toggle Off or delete (creator / Global Admin only).
</details>

<details><summary>Playbook 5 — "Timeline replaced App reliability" training fix</summary>

Tell L1/L2: the per-device app reliability **score** now lives under Reports > Endpoint analytics > Application reliability > **Device performance** (search device). The device's own view shows the **event timeline** instead. Update internal KB screenshots.
</details>

---
## Evidence Pack

```powershell
# Collect-AdvancedAnalyticsEvidence.ps1 — run on the affected device (elevated) AND attach tenant audit CSVs
$out = Join-Path $env:TEMP ("AA-Evidence-{0:yyyyMMdd-HHmm}" -f (Get-Date))
New-Item -ItemType Directory -Path $out -Force | Out-Null
dsregcmd /status > "$out\dsregcmd.txt"
Get-Service DiagTrack, dmwappushservice -ErrorAction SilentlyContinue |
  Select-Object Name, Status, StartType | Export-Csv "$out\services.csv" -NoTypeInformation
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, LastBootUpTime |
  Export-Csv "$out\os.csv" -NoTypeInformation
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -ErrorAction SilentlyContinue |
  Out-File "$out\datacollection-policy.txt"
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Enrollments\*' -ErrorAction SilentlyContinue |
  Where-Object ProviderID -eq 'MS DM Server' | Select-Object PSChildName, UPN, ProviderID |
  Export-Csv "$out\enrollments.csv" -NoTypeInformation
Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue |
  Select-Object InstanceName, FullChargedCapacity | Export-Csv "$out\battery-fcc.csv" -NoTypeInformation
Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue |
  Select-Object InstanceName, DesignedCapacity | Export-Csv "$out\battery-design.csv" -NoTypeInformation
Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='Application Error','Application Hang'; StartTime=(Get-Date).AddDays(-7)} -ErrorAction SilentlyContinue |
  Select-Object TimeCreated, Id, ProviderName, Message | Export-Csv "$out\app-crash-hang-7d.csv" -NoTypeInformation
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
Write-Host "Evidence: $out.zip"
# Tenant side: .\Intune\Scripts\Get-AdvancedAnalyticsReportAudit.ps1 -OutputFolder <folder>
```
The local crash/hang events let you prove whether events *happened* on the device independent of whether AA surfaced them; the WMI battery classes give a ground-truth capacity ratio to compare with the report.

---
## Command Cheat Sheet

| Purpose | Command |
|---|---|
| Connect Graph (read) | `Connect-MgGraph -Scopes DeviceManagementManagedDevices.Read.All,Organization.Read.All` |
| Licence service plans | `Get-MgSubscribedSku \| Select -Expand ServicePlans` |
| Anomalies (beta) | `Invoke-MgGraphRequest -Uri 'https://graph.microsoft.com/beta/deviceManagement/userExperienceAnalyticsAnomaly'` |
| Battery devices (beta) | `.../userExperienceAnalyticsBatteryHealthDevicePerformance` |
| Resource perf (beta) | `.../userExperienceAnalyticsResourcePerformance` |
| Fleet audit script | `.\Intune\Scripts\Get-AdvancedAnalyticsReportAudit.ps1 -OutputFolder .\AA` |
| Join state | `dsregcmd /status` |
| Telemetry service | `Get-Service DiagTrack` |
| Last reboot | `(Get-CimInstance Win32_OperatingSystem).LastBootUpTime` |
| Local battery report | `powercfg /batteryreport /output "$env:TEMP\battery.html"` |
| Design capacity | `Get-CimInstance -Namespace root\wmi BatteryStaticData` |
| Full-charge capacity | `Get-CimInstance -Namespace root\wmi BatteryFullChargedCapacity` |
| Local crash/hang events | `Get-WinEvent -FilterHashtable @{LogName='Application';ProviderName='Application Error','Application Hang'}` |
| Stop errors (bugchecks) | `Get-WinEvent -FilterHashtable @{LogName='System';Id=1001;ProviderName='Microsoft-Windows-WER-SystemErrorReporting'}` |

---
## 🎓 Learning Pointers
- Read the four anomaly models once — they explain why small fleets see nothing and why cohorts only exist for Medium/High: [Anomalies report — statistical models](https://learn.microsoft.com/en-us/intune/advanced-analytics/anomalies#statistical-models-for-determining-anomalies).
- AA licences are auto-enabled and take up to 48 h; the extra reports then appear inside the existing Endpoint analytics blade rather than a new node: [Advanced Analytics overview](https://learn.microsoft.com/en-us/intune/advanced-analytics/).
- Battery health gives numeric thresholds (60 %/80 % capacity, 3 h runtime) you can put straight into an SOW for proactive battery replacement: [Battery health report](https://learn.microsoft.com/en-us/intune/advanced-analytics/battery-health).
- Resource performance covers **Windows 365 Cloud PCs** too, which makes it the evidence base for Cloud PC resize requests: [Resource performance report](https://learn.microsoft.com/en-us/intune/advanced-analytics/resource-performance).
- Device scopes are one-tag-each with 20-active/100-saved limits; plan your scope-tag design before promising per-site dashboards: [Device scopes](https://learn.microsoft.com/en-us/intune/advanced-analytics/device-scopes).
- Pair with this repo's [DeviceQuery-A.md](DeviceQuery-A.md) — timeline tells you *what happened*, device query tells you *the state right now*.
