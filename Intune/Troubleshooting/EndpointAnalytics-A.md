# Intune Endpoint Analytics — Reference Runbook (Mode A: Deep Dive)
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

**What this covers:**
- Endpoint analytics core reports: **Startup performance**, **Application reliability**, **Work from anywhere**, and the top-level **Endpoint analytics score**
- Configuration (Intune data collection policy / Windows health monitoring profile), data collection/consent, baselines, and per-device/per-model scoring
- Data flow architecture, timing/latency behavior, and the network/proxy path that most commonly breaks it
- Configuration Manager co-management and tenant-attach onboarding paths, and their specific known issues
- Graph API access to score/history data for reporting and automation

**What this does NOT cover:**
- **Proactive Remediations** (detection + remediation script pairs) — a related but architecturally separate Intune capability under the same "Reports" umbrella conceptually, but with its own configuration, licensing note, and execution pipeline. See `Remediations-A.md`/`-B.md`.
- **Windows Autopatch** ring assignment and update orchestration — see `Autopatch-A.md`/`-B.md`. Endpoint analytics' Work From Anywhere "Windows" metric *measures* whether devices are on supported/current Windows versions, but does not manage the update process itself.
- **Microsoft Intune Advanced Analytics** — a separately licensed, deeper analytics tier built on top of Endpoint analytics (deeper reporting, extended retention, additional insight types). Out of scope here; flagged only where it changes a prerequisite or a UI location.
- Windows Update for Business ring/deferral configuration — see `WUfB-A.md`.
- Group Policy Analytics migration tooling itself — see `GP-to-CSP-A.md`. (Endpoint analytics' Startup performance report *surfaces* GP-caused delay as an insight; it does not perform the migration.)

**Requirements:**
- Device platform: Windows 10/11 **Pro, Pro Education, Enterprise, or Education**. Windows Home is not supported.
- Device management: Intune-managed, co-managed (Intune + Configuration Manager), Configuration Manager-managed via tenant attach, Microsoft Entra joined, or Microsoft Entra hybrid joined.
- Local service: **Connected User Experiences and Telemetry** (`DiagTrack`) must be enabled and running.
- Network: outbound HTTPS reachability from managed devices to `https://*.events.data.microsoft.com`, without SSL/TLS interception (certificate pinning is enforced).
- Licensing: a valid Intune license per enrolled device (or Configuration Manager licensing for ConfigMgr-managed devices).
- Roles: configuring the feature requires an Intune role with **Endpoint Analytics/Read**, **Endpoint Analytics/Create, Update, Delete**, **Organization/Read**, **Managed Devices/Read**, and **Device configurations/Create, Read, Assign** (or the built-in **School Administrator** role); *viewing* reports only requires **Endpoint Analytics/Read** plus **Organization/Read** and **Managed Devices/Read** (or built-in **Help Desk Operator**, **Read Only Operator**, **Endpoint Security Manager**, **School Administrator**, or the Entra **Reports Reader** role).
- Configuration Manager environments must have **tenant attach** enabled; using multiple ConfigMgr hierarchies with a single Endpoint analytics instance is not supported.

---
## How It Works

<details><summary>Full architecture</summary>

Endpoint analytics is a scoring and insight layer sitting on top of telemetry that Windows devices already generate. It does not install a new agent — for Intune-managed and Entra-joined/hybrid-joined devices it rides on the existing `DiagTrack` diagnostic data pipeline; for Configuration Manager-managed devices it rides on the ConfigMgr client's own data collection plus the tenant-attach cloud connector. Three purpose-built reports (Startup performance, Application reliability, Work from anywhere) plus a rolled-up **Endpoint analytics score** are the product surface; a fourth tier, **Advanced Analytics**, adds deeper/extended reporting under separate licensing and isn't covered here.

**Configuration model.** The first time an admin opens **Reports > Endpoint analytics**, a guided setup creates a configuration profile called the **Intune data collection policy** — internally a *Windows health monitoring* policy — and assigns it to whatever scope the admin chooses (**All cloud-managed devices**, a selected set, or none yet). This is the single control surface that tells Intune-managed/co-managed devices to begin sending the required functional data. Configuration Manager-managed devices instead get enabled via **Cloud Attach > Configure upload**, plus a **Computer Agent > Enable Endpoint analytics data collection** client setting that controls *local* collection independently of whether it's *uploaded*.

**Data flow.** For Intune/co-managed devices: the device sends required functional data in near real-time directly to the Microsoft Endpoint Management service in the Microsoft public cloud, where it's processed roughly every 24 hours; the documented **maximum end-to-end latency is 96 hours**. For ConfigMgr-managed devices: the device sends data to its ConfigMgr site server every 24 hours, and the tenant-attach connector forwards it to the Gateway Service every hour — the connector itself needs cloud connectivity, but individual devices don't need direct internet access. Results are published for both individual devices and organizational aggregates in the Intune admin center via Graph.

**Why startup data specifically takes longer.** Startup performance data (`coreBootTimeInMilliseconds`, `totalBootTimeInMilliseconds`, `gpLogonDurationInMilliseconds`, `desktopShownDurationInMilliseconds`, `desktopUsableDurationInMilliseconds`, per-process CPU/name data during boot, etc.) is only generated *at boot*. A device that never restarts after the data collection policy applies will never contribute a startup score, no matter how long you wait. Microsoft's own guidance goes further: because the data required to compute a startup score depends heavily on power settings and user restart behavior, it can take **weeks** after enrollment for a device to show a startup score at all, even once the base 24-96h processing pipeline is satisfied.

**Scoring model.** Every score (Endpoint analytics score, Startup performance, Application reliability, Work from anywhere) is 0-100, where lower means more room for improvement. The top-level **Endpoint analytics score** is a weighted average of the Startup performance, Application reliability, and Work from anywhere scores. Any report requires a minimum of **5 devices** reporting in scope to produce a real score — below that, the UI (and the Graph `healthStatus` field) reports **Insufficient data** rather than a misleadingly small-sample number.

**Baselines are comparison anchors, not thresholds.** A built-in **All organizations (median)** baseline — an anonymized, aggregated cross-tenant median — is always available (except for Work from anywhere's subscore metrics, which have no commercial median yet). Admins can also create up to **20 custom baselines** per tenant from their own current metrics, each with a configurable **regression threshold** (default 10%) that determines when a metric is flagged red as "regressed" versus normal daily fluctuation. Sharing data for the "All organizations" baseline is opt-in **consent** — revoking it disables reports that depend on shared aggregate data (startup performance insights specifically), makes existing report data go stale immediately, and purges historical data after 60 days.

**Insights and recommendations** is a separate, prioritized action list computed alongside the scores — each entry names the specific factor dragging a score down (e.g., "N devices have HDD boot drives," "N devices have Group-Policy-caused sign-in delay") and how many points fixing it would recover. This list is the fastest way to turn a low score into concrete remediation targets rather than staring at a single number.

**Work From Anywhere is structurally different from the other two reports** — it isn't measuring an observed performance metric, it's measuring *readiness*, computed from four weighted sub-metrics: **Windows** (percent on supported Windows versions), **Cloud management** (percent using CMG/tenant-attach/co-management/full Intune — each unlocking progressively more remote-management capability), **Cloud identity** (percent Entra joined or hybrid joined), and **Cloud provisioning** (percent that are either Windows 365 Cloud PCs, or physical devices registered in Windows Autopilot *with a deployment profile actually assigned* — note the trap: a device that only inherited the default all-devices Autopilot profile does **not** get credit here, since the metric checks for an explicitly assigned profile, not just inheritance). A related **Windows 11 hardware readiness** view lives in the same report but is purely informational and does not affect the Work From Anywhere score itself.

</details>

---
## Dependency Stack

```
Layer 0 — Device platform eligibility
  Windows 10/11 Pro / Pro Education / Enterprise / Education
  (Windows Home unsupported — no error, device simply never appears)

Layer 1 — Local telemetry service
  DiagTrack (Connected User Experiences and Telemetry) enabled + running
  Can be disabled by privacy-hardened GPO/Intune baselines — creates a silent conflict

Layer 2 — Management + identity binding (at least one path)
  Intune-managed  OR  Co-managed (Intune + ConfigMgr)  OR
  ConfigMgr-managed via tenant attach  OR  Entra joined / Entra hybrid joined

Layer 3 — Network path
  Outbound HTTPS to *.events.data.microsoft.com
  Zero SSL/TLS interception (certificate pinning enforced — inspection = silent data loss)
  ConfigMgr path: device → site server (local) → tenant-attach connector → Gateway Service (cloud)

Layer 4 — Data collection policy / client setting
  Intune: "Intune data collection policy" (Windows health monitoring profile), assigned + Succeeded
  ConfigMgr: Cloud Attach "Enable Endpoint analytics" upload flag + Computer Agent client setting

Layer 5 — Device restart
  At least one restart AFTER Layer 4 applies
  Startup-specific telemetry generated only at boot — no substitute for an actual restart

Layer 6 — Processing pipeline (timing)
  Near-real-time send → ~24h processing cycle → up to 96h max end-to-end latency
  Startup score specifically: additional multi-week stabilization depending on restart cadence

Layer 7 — Reporting population threshold
  Minimum 5 devices reporting in the relevant scope for a non-"Insufficient data" score

Layer 8 — Consent + baseline configuration
  Consent to share anonymized/aggregate data (drives "All organizations" baseline availability)
  Custom baseline selection (comparison context only — doesn't gate data collection)
```

A break at any layer produces the *same* visible symptom one layer up — "device/score missing from the report" — which is why layer-by-layer validation (not guessing) is the only efficient path through this topic.

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Startup score shows 0 with a "waiting for data" banner | Data collection policy not yet processed, or device hasn't restarted since | Policy assignment status + device last-boot time |
| A specific device is completely missing from every report | Windows Home edition, DiagTrack disabled, or SSL inspection dropping telemetry | Platform check → `DiagTrack` service → proxy/cert path |
| Score shows "Insufficient data" tenant- or scope-wide | Fewer than 5 devices reporting in that scope | `userExperienceAnalyticsDeviceScores` count for the scope |
| Reports that were working suddenly show stale/no new data | Consent to share anonymized data was revoked | Endpoint analytics **Settings > General** consent checkbox |
| ConfigMgr device shows collection "enabled" in console but no data arrives | Pre-existing custom client settings didn't actually redeploy (known issue) | **Resultant Client Settings** on the device, not the settings object |
| Hardware inventory starts failing after enabling Endpoint analytics (ConfigMgr) | `Browser Usage (SMS_BrowserUsage)` inventory class SQL primary-key conflict | `Dataldr.log` for `BROWSER_USAGE_HIST_PK` errors |
| CSV export shows `-1` or `-2` in a score column | Score genuinely unavailable for that device, not zero/error | Cross-check against portal UI value for the same device |
| CSV export shows `MeanTimeToFailure = 2147483647` | No crash events recorded — sentinel value, not a real duration | Application reliability report for the same app/device in the UI |
| Device shows Windows 11 readiness = "Unknown" | Device is inactive (not checking in), not a readiness computation failure | Last check-in time via Intune device details |
| Cloud provisioning metric stays low despite Autopilot being used fleet-wide | Devices inherited the **default** (all-devices-group) Autopilot profile, which doesn't count as "assigned" | Autopilot deployment profile assignment per device, not just enrollment |
| All Endpoint analytics data vanished after a tenant-to-tenant migration | Expected, documented behavior — data doesn't migrate | Confirm migration timing against data-loss window; reports repopulate going forward |
| Same physical device appears twice, once via Intune once via ConfigMgr | Deduplication normally prevents this — enrollment method mismatch or dedup key collision | Compare `aaddeviceid` / `localId` values across both entries |
| Startup score present but Group Policy delay insight never populates | Not enough affected devices to clear the insight's minimum device threshold | Device performance tab sorted by GP sign-in time |
| Proxy/firewall passes a basic port-443 reachability test but device still absent | SSL inspection terminating and re-signing the cert (pinning violation is silent) | Compare certificate issuer seen by the client vs. Microsoft's actual cert |
| The **Update Stale Group Policies** remediation script returns error `0x87D00321` | Script execution timeout, typically on remotely-connected machines | Target only devices with reliable internal network connectivity |

---
## Validation Steps

1. **Confirm platform eligibility.**
   ```powershell
   Get-CimInstance Win32_OperatingSystem | Select-Object Caption
   ```
   *Good:* Pro / Pro Education / Enterprise / Education. *Bad:* Home — hard, unfixable blocker for this feature.

2. **Confirm DiagTrack is running.**
   ```powershell
   Get-Service -Name DiagTrack | Select-Object Status, StartType
   ```
   *Good:* Running / Automatic. *Bad:* Stopped/Disabled — check for a conflicting privacy-hardening policy before just re-enabling.

3. **Confirm the data collection policy reached the device.**
   Intune admin center → **Devices > Configuration** → **Intune data collection policy** → **Device status**. *Good:* Succeeded. *Bad:* Error, Conflict, or the device isn't listed at all (not in assignment scope).

4. **Confirm restart timing relative to policy application.**
   ```powershell
   Get-CimInstance Win32_OperatingSystem | Select-Object @{n='LastBoot';e={$_.LastBootUpTime}}
   ```
   *Good:* Restart occurred after the policy's applied timestamp, and ≥25 hours have elapsed. *Bad:* No restart since, or too recent — this is expected latency, not a fault.

5. **Confirm the tenant/scope population clears the 5-device floor.**
   ```powershell
   (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceManagement/userExperienceAnalyticsDeviceScores").value.Count
   ```
   *Good:* ≥5. *Bad:* <5 — every score in this scope will read "Insufficient data" regardless of pipeline health.

6. **Confirm network path integrity (no SSL inspection).**
   ```powershell
   Test-NetConnection -ComputerName v10.events.data.microsoft.com -Port 443
   ```
   Then verify with the network/security team whether this destination is excluded from SSL inspection. *Good:* Direct TLS to Microsoft, or a documented bypass. *Bad:* Proxy terminates TLS for this destination — telemetry silently discarded.

7. **Confirm consent state if previously-working reports have gone stale.**
   Intune admin center → **Reports > Endpoint analytics > Settings > General** → consent checkbox. *Good:* Checked (if the org intends to see startup performance insights and baseline comparisons). *Bad:* Unchecked with no documented reason — likely an accidental revocation.

---
## Troubleshooting Steps (by phase)

**Phase 1 — Rule out prerequisite gaps.** Platform edition, DiagTrack state, and licensing first — these are binary gates with no partial-credit state. A device failing here will never appear regardless of everything downstream being perfect.

**Phase 2 — Confirm policy assignment and processing timing.** Check the Intune data collection policy's assignment and per-device status, then map the device's last restart against the known latency windows (24-25h for the device to appear at all after restart; up to 96h max end-to-end; potentially weeks for a stabilized startup score). Most "it's broken" tickets in this topic are actually "it hasn't been long enough" — resist the urge to change configuration before the timing window has genuinely elapsed.

**Phase 3 — Walk the network/proxy path.** This is the highest-value phase to investigate early in any environment with SSL inspection, because it produces zero client-side error and looks identical to "just needs more time" from the device's perspective. Confirm with the network team whether `*.events.data.microsoft.com` is excluded from inspection; if not, this is very likely the root cause regardless of what else looks healthy.

**Phase 4 — Configuration Manager-specific known issues.** If the affected devices are ConfigMgr-managed (or co-managed with ConfigMgr handling collection), check the two documented known issues: custom client settings that show "enabled" in the console without having redeployed, and the `SMS_BrowserUsage` hardware inventory class conflict that can start throwing `Dataldr.log` errors once Endpoint analytics is turned on.

**Phase 5 — Interpret confusing report/export values before treating them as faults.** `-1`/`-2` score values, the `2147483647` MeanTimeToFailure sentinel, and the numeric-only CSV encodings (`HealthStatus`, `UpgradeEligibility`) are documented behavior, not bugs. Cross-check any "weird number" against the portal UI for the same device before escalating.

**Phase 6 — Escalate with evidence, not conclusions.** Once Phases 1-5 are exhausted and the gap remains unexplained, gather the Evidence Pack output below before opening a Microsoft support case — Endpoint analytics processing itself (the cloud-side pipeline) is not directly diagnosable by admins once the device-side path is confirmed clean.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Fleet-wide phased onboarding</summary>

Use when: standing up Endpoint analytics for the first time across an MSP client tenant, and you want to avoid an "Insufficient data" false start or an unmanaged flood of new configuration profile assignments.

1. Create a pilot Entra group of ≥10 representative devices (comfortably above the 5-device floor, across the model mix you care about for **Model scores**).
2. Run the guided setup with **Selected devices** targeting the pilot group, not **All cloud-managed devices**, on first pass.
3. Confirm DiagTrack and platform eligibility across the pilot group before wider rollout — a Home-edition or DiagTrack-disabled device silently produces no score, it doesn't error, so a pre-check avoids chasing phantom gaps later.
4. After confirming pilot devices report cleanly (Validation Steps 3-6), expand the **Intune data collection policy** assignment to **All cloud-managed devices** or the full target scope.
5. Set a calendar reminder for 30 days out — startup scores specifically can take that long to stabilize even after the base pipeline is healthy; don't judge the rollout a failure prematurely.

**Rollback:** Change the policy assignment back to the pilot group (or remove entirely) — no destructive local state was created on devices.

</details>

<details><summary>Playbook 2 — Fix ConfigMgr collection-enabled-but-no-data</summary>

Use when: Phase 4 identifies the custom-client-settings known issue.

1. Configuration Manager console → **Administration > Client Settings** → locate the custom client settings object that includes **Computer Agent** settings and predates Endpoint analytics onboarding.
2. Open it, set **Enable Endpoint analytics data collection** to **No**, select **OK** to close and save.
3. Reopen the same custom client settings, set it back to **Yes**, select **OK** again. This forces a real redeployment to targeted devices, unlike simply leaving it at the (visually correct but never-applied) **Yes** value.
4. Verify via **Resultant Client Settings** on a sample of affected devices before considering this closed.

If the failure instead matches the `BROWSER_USAGE_HIST_PK` hardware inventory error pattern in `Dataldr.log`: disable collection of the **Browser Usage (SMS_BrowserUsage)** hardware inventory class — Endpoint analytics does not use or transmit this class, so disabling it has no analytics impact.

**Rollback:** Re-enabling the Browser Usage inventory class, or reverting client settings, restores prior state — neither action is destructive.

</details>

<details><summary>Playbook 3 — Correct SSL inspection blocking telemetry</summary>

Use when: Phase 3 confirms SSL/TLS interception on the required endpoint.

1. **Preferred:** work with network/security to add a permanent bypass rule for `*.events.data.microsoft.com` on the proxy/firewall — no decrypt-and-resign for this destination.
2. If a blanket bypass isn't acceptable, choose an authentication model matched to the device population:
   - **User proxy authentication** (WinINET) — only for devices with a signed-in user who has proxy permission, and explicitly **not compatible with Microsoft Defender for Endpoint** (conflicting `DisableEnterpriseAuthProxy` registry requirement: `0` for this method vs. `1` for Defender for Endpoint).
   - **Device proxy authentication** (WinHTTP, local system context) — required for headless devices, non-Windows-Integrated-Auth proxies, and any device running Defender for Endpoint. Configure via `netsh winhttp set proxy`, WPAD, transparent proxy, or the **Make proxy settings per-machine** GPO, with the proxy authenticating computer accounts via Windows-Integrated Authentication.
3. Re-run Validation Step 6 after the change, then wait a full processing cycle (up to 96h) before concluding it worked or didn't.

**Rollback:** Removing the bypass/exception restores full SSL inspection but re-breaks this feature for affected devices — treat the exception as a permanent, documented requirement of running Endpoint analytics, not a temporary workaround.

</details>

<details><summary>Playbook 4 — Cleanly decommission Endpoint analytics (consent + data collection)</summary>

Use when: a client wants to fully stop using this feature (privacy requirement, licensing change, or genuine non-use).

1. For Intune-managed/co-managed devices: unselect the **Endpoint analytics** scope from the Intune data collection policy assignment (or remove the assignment entirely).
2. Optionally revoke consent: **Settings > General** → clear **I consent to share anonymized and aggregate metrics...** → confirm. Understand the immediate effects: reports relying on shared data (startup performance insights) disable immediately, existing data goes stale immediately, and historical data is retained for only 60 more days before removal.
3. For ConfigMgr-managed devices: **Administration > Cloud Services > Co-management** → **CoMgmtSettingsProd > Properties > Configure upload** → uncheck **Enable Endpoint analytics for devices uploaded to Microsoft Endpoint Manager**. Optionally also disable the **Computer Agent > Enable Endpoint analytics data collection** default client setting.
4. Document the 60-day data retention window explicitly in the change record if there's any chance of needing historical data for a later audit or dispute.

**Rollback:** Re-running the guided setup and re-consenting restores the feature going forward, but data from before decommissioning past the 60-day window is unrecoverable — this is a genuine one-way door for historical data, flag it as such before executing.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS
    Collects Endpoint analytics evidence for a single device or a full-tenant check,
    for escalation or pre-rollout validation. Read-only.
#>
param(
    [string]$DeviceName,
    [string]$OutputPath = "C:\Temp\EndpointAnalyticsEvidence-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
)

$evidence = [System.Collections.Generic.List[string]]::new()
$evidence.Add("=== Endpoint Analytics Evidence Pack — $(Get-Date) ===")

# Tenant-wide reporting population
try {
    $all = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceManagement/userExperienceAnalyticsDeviceScores"
    $evidence.Add("Total devices with scores in scope: $($all.value.Count)")
    if ($all.value.Count -lt 5) {
        $evidence.Add("WARNING: below the 5-device minimum — expect 'Insufficient data' everywhere in this scope.")
    }
} catch {
    $evidence.Add("Graph call failed for userExperienceAnalyticsDeviceScores: $($_.Exception.Message)")
}

# Specific device, if provided
if ($DeviceName) {
    try {
        $dev = Invoke-MgGraphRequest -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/deviceManagement/userExperienceAnalyticsDeviceScores?`$filter=deviceName eq '$DeviceName'"
        $evidence.Add("--- Device: $DeviceName ---")
        $evidence.Add(($dev.value | ConvertTo-Json -Depth 5))
    } catch {
        $evidence.Add("Graph call failed for device '$DeviceName': $($_.Exception.Message)")
    }
}

# Local device-side checks (run this block ON the affected device)
$evidence.Add("--- Local device state (run on affected device) ---")
$evidence.Add("OS: $((Get-CimInstance Win32_OperatingSystem).Caption)")
$evidence.Add("DiagTrack: $((Get-Service -Name DiagTrack).Status)")
$evidence.Add("Last boot: $((Get-CimInstance Win32_OperatingSystem).LastBootUpTime)")

$evidence | Out-File -FilePath $OutputPath -Encoding UTF8
Write-Host "Evidence written to $OutputPath" -ForegroundColor Green
```

For a fleet-wide sweep across multiple devices with flagged findings, see `Scripts/Get-EndpointAnalyticsHealth.ps1`.

---
## Command Cheat Sheet

| Command | Purpose |
|---|---|
| `Get-Service -Name DiagTrack` | Confirm local telemetry service state |
| `Get-CimInstance Win32_OperatingSystem \| select Caption` | Confirm platform edition eligibility |
| `Get-CimInstance Win32_OperatingSystem \| select LastBootUpTime` | Confirm restart timing for startup telemetry |
| `Test-NetConnection -ComputerName v10.events.data.microsoft.com -Port 443` | Confirm outbound reachability to the telemetry endpoint |
| `Invoke-MgGraphRequest -Method GET -Uri ".../deviceManagement/userExperienceAnalyticsDeviceScores"` | Per-device and tenant-wide score + healthStatus |
| `Invoke-MgGraphRequest -Method GET -Uri ".../deviceManagement/userExperienceAnalyticsDeviceStartupHistory"` | Boot/sign-in history detail per device |
| `Invoke-MgGraphRequest -Method GET -Uri ".../deviceManagement/userExperienceAnalyticsWorkFromAnywhereMetrics"` | Work From Anywhere sub-metric detail |
| `Invoke-MgGraphRequest -Method GET -Uri ".../deviceManagement/userExperienceAnalyticsBaselines"` | List configured baselines |
| `Start-Process DeviceEnroller.exe -ArgumentList "/o"` | Force Intune policy sync on device |
| `Get-Service -Name DiagTrack \| Set-Service -StartupType Automatic` | Re-enable telemetry service |
| `netsh winhttp show proxy` | Confirm device-context (WinHTTP) proxy configuration |
| `netsh winhttp set proxy` | Configure device-context proxy for headless/Defender for Endpoint devices |
| (Portal) Devices > Configuration > Intune data collection policy > Device status | Per-device policy assignment/apply status |
| (Portal) Reports > Endpoint analytics > Settings > General | Consent state, data collection status |
| (ConfigMgr console) Devices > target device > Client settings > Resultant client settings | Verify actual (not just configured) collection state |

---
## 🎓 Learning Pointers

- **The 24-96 hour latency window and the multi-week startup-score stabilization period are the most common source of false "it's broken" escalations in this topic.** Always validate elapsed time against a confirmed restart before touching configuration. [Endpoint analytics data collection — data flow](https://learn.microsoft.com/en-us/intune/endpoint-analytics/ref-data-collection)
- **Certificate pinning means SSL inspection fails silently, with no client-side error.** In any environment running a corporate proxy with TLS inspection, this should be checked early, not last — it produces the exact same symptom ("device never appears") as half a dozen other, easier-to-rule-out causes. [Troubleshooting endpoint analytics — proxy server authentication](https://learn.microsoft.com/en-us/intune/endpoint-analytics/troubleshoot#proxy-server-authentication)
- **Work From Anywhere's "Cloud provisioning" metric checks for an explicitly *assigned* Autopilot deployment profile, not mere enrollment or inherited defaults** — a fleet that's "fully on Autopilot" by every other measure can still score low here if devices only ever picked up the default all-devices profile. [Work from anywhere report — cloud provisioning](https://learn.microsoft.com/en-us/intune/endpoint-analytics/work-from-anywhere)
- **Endpoint analytics data does not survive a tenant-to-tenant migration.** If a client is planning a tenant move, set the expectation up front that historical Endpoint analytics data is lost at the migration boundary and reports repopulate from zero afterward — this is documented, expected behavior, not a defect to chase post-migration. [Troubleshooting endpoint analytics — FAQ](https://learn.microsoft.com/en-us/intune/endpoint-analytics/troubleshoot#frequently-asked-questions)
- **CSV exports use raw numeric encodings, not the friendly portal labels** — misreading `HealthStatus`, `UpgradeEligibility`, or the `MeanTimeToFailure` sentinel value (`2147483647` = no crashes, not a real duration) as literal numbers is a recurring source of misdiagnosis when data is pulled for offline analysis or a client report. [Troubleshooting endpoint analytics — exported CSV values](https://learn.microsoft.com/en-us/intune/endpoint-analytics/troubleshoot#exported-csv-files-display-numerical-values)
- **This is a distinct pipeline from Remediations and Autopatch, despite living under the same Intune "device health" umbrella conceptually.** Endpoint analytics measures and scores experience; it doesn't remediate (Remediations) or orchestrate updates (Autopatch). Cross-reference rather than duplicate when a ticket touches more than one of these three.
