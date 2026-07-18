# Intune Endpoint Analytics — Hotfix Runbook (Mode B: Ops)
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

Run these first to locate the failure layer. This is NOT Proactive Remediations (script pairs — see `Remediations-B.md`) and NOT Windows Autopatch (`Autopatch-B.md`) — this is the Startup Performance / Application Reliability / Work From Anywhere scoring pipeline under **Reports > Endpoint analytics**.

```powershell
# 1. Per-device score + health status via Graph (fastest single check)
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
Invoke-MgGraphRequest -Method GET `
  -Uri "https://graph.microsoft.com/v1.0/deviceManagement/userExperienceAnalyticsDeviceScores?`$filter=deviceName eq '<DeviceName>'" |
  Select-Object -ExpandProperty value |
  Select-Object deviceName, endpointAnalyticsScore, startupPerformanceScore, appReliabilityScore, workFromAnywhereScore, healthStatus

# 2. Confirm the device is even in the reporting population at all (5-device minimum applies tenant/scope-wide, not per device)
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceManagement/userExperienceAnalyticsDeviceScores").value.Count

# 3. On the device: confirm DiagTrack is running (hard prerequisite — no exceptions)
Get-Service -Name DiagTrack | Select-Object Name, Status, StartType

# 4. On the device: confirm it has restarted since the data collection policy was applied
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, @{n='LastBoot';e={$_.LastBootUpTime}}

# 5. On the device: confirm the required telemetry endpoint is reachable (cert-pinned — SSL inspection breaks this silently)
Test-NetConnection -ComputerName v10.events.data.microsoft.com -Port 443
```

| Result | Action |
|--------|--------|
| Device score object doesn't exist / 404-equivalent empty result | → Fix 1: Confirm data collection policy assignment |
| `healthStatus` = 1 (Insufficient data) tenant-wide, device count < 5 | → Fix 2: Expand assignment scope — 5-device minimum is hard-coded |
| DiagTrack stopped or disabled | → Fix 3: Start/re-enable DiagTrack |
| Device hasn't restarted since policy applied, or restarted <24-25h ago | → Fix 4: Wait out the pipeline, or force a restart if it's been days |
| `Test-NetConnection` fails, or succeeds but a proxy is doing SSL inspection | → Fix 5: Bypass SSL inspection for `*.events.data.microsoft.com` |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
[Device platform eligibility]
  └─ Windows 10/11 Pro, Pro Education, Enterprise, or Education
  └─ NOT Windows Home (unsupported, silently never reports)
         |
[Local telemetry service]
  └─ DiagTrack ("Connected User Experiences and Telemetry") running
         |
[Management + identity mode — at least one of]
  └─ Intune-managed, OR
  └─ Co-managed (Intune + Configuration Manager), OR
  └─ Configuration Manager-managed via tenant attach, OR
  └─ Microsoft Entra joined / Microsoft Entra hybrid joined
         |
[Network path]
  └─ Outbound HTTPS reachability to *.events.data.microsoft.com
  └─ NO SSL inspection/interception on this path (certificate pinning — inspection breaks silently, no error surfaced)
         |
[Intune data collection policy]
  └─ "Windows health monitoring" configuration profile created by the Endpoint analytics guided setup
  └─ Assigned to the target device (or "All cloud-managed devices")
  └─ Profile status = Succeeded on the device
         |
[Device restart]
  └─ At least one restart AFTER the data collection policy applied
  └─ Startup score specifically needs boot+sign-in telemetry, only generated at boot
         |
[Processing pipeline]
  └─ Near-real-time send → processed every 24h → up to 96h max end-to-end latency
  └─ Practically: up to 24-25h after restart before device appears in Device performance tab
         |
[Reporting population threshold]
  └─ Minimum 5 devices reporting in scope for a non-"Insufficient data" score
         |
[Consent to share data — for baseline-relative reports]
  └─ "I consent to share anonymized and aggregate metrics" checkbox enabled
  └─ If revoked: startup performance insights disable, historical data purges after 60 days
```

</details>

---
## Diagnosis & Validation Flow

**1. Confirm platform + service prerequisites on the device**
```powershell
Get-CimInstance Win32_OperatingSystem | Select-Object Caption
Get-Service -Name DiagTrack
```
*Good:* Caption shows Pro/Pro Education/Enterprise/Education; DiagTrack status = Running, StartType = Automatic.
*Bad:* Windows Home (hard blocker, no workaround); DiagTrack Stopped/Disabled.

**2. Confirm the Intune data collection policy is assigned and succeeded**
Intune admin center → **Devices > Configuration** → profile named **Intune data collection policy** → **Device status** tab → find the device.
*Good:* Status = Succeeded.
*Bad:* Not assigned, Pending, or Error — device was never told to collect/send data at all.

**3. Confirm the device restarted after the policy applied, and enough time has passed**
```powershell
Get-CimInstance Win32_OperatingSystem | Select-Object @{n='LastBoot';e={$_.LastBootUpTime}}
```
*Good:* Restart timestamp is after the policy's "applied" time in step 2, and it's been ≥25 hours.
*Bad:* No restart since policy applied — no boot/sign-in telemetry has been generated yet; restart the device and wait.

**4. Confirm network path to the telemetry endpoint isn't silently broken by SSL inspection**
```powershell
Test-NetConnection -ComputerName v10.events.data.microsoft.com -Port 443
```
Then check whether a proxy/firewall is terminating and re-issuing the TLS certificate (SSL inspection). Endpoint analytics uses certificate pinning — Windows detects the substituted certificate and silently drops the telemetry. There is no client-side error for this; the only symptom is the device never appearing in reports.
*Good:* Direct connection, or an explicit bypass rule for this endpoint on the proxy.
*Bad:* Proxy is doing SSL inspection on this destination — telemetry is being sent but discarded.

**5. Confirm the tenant/scope has enough devices to produce a real score**
```powershell
(Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/deviceManagement/userExperienceAnalyticsDeviceScores").value.Count
```
*Good:* ≥5 devices with real scores in the relevant scope.
*Bad:* <5 — every report will show "Insufficient data" regardless of how healthy the pipeline is. This is a hard product threshold, not a bug.

**6. If ConfigMgr co-managed: confirm custom client settings actually pushed the change**
Configuration Manager console → **Devices** workspace → target device → **Client settings > Resultant client settings**. Confirm **Enable Endpoint analytics data collection** shows **Yes** as the *resultant* value, not just in the settings object definition — a known issue lets the console show Yes on a pre-existing custom client setting that never actually redeployed to devices.

---
## Common Fix Paths

<details><summary>Fix 1 — Data collection policy never assigned / never confirmed on this device</summary>

Use when: the device has no "Intune data collection policy" profile, or it shows Not Applicable/Pending indefinitely.

1. Intune admin center → **Reports > Endpoint analytics** → if this is the very first setup, run the guided setup and choose **All cloud-managed devices** (or **Selected devices** and explicitly include the target group).
2. To retarget an existing setup: **Devices > Configuration** → **Intune data collection policy** → **Properties > Assignments > Edit** → add the device's group.
3. Force a policy sync on the device so it doesn't wait for the normal check-in cycle:
```powershell
Start-Process -FilePath "C:\Windows\System32\DeviceEnroller.exe" -ArgumentList "/o"
```
4. Restart the device once the profile shows Succeeded.

**Rollback:** Remove the device/group from the policy assignment — data collection stops, no destructive local change was made.

</details>

<details><summary>Fix 2 — Reporting population below the 5-device minimum</summary>

Use when: `healthStatus` is consistently 1 (Insufficient data) tenant-wide or for a specific scope/scope-tag filter, and the device count check in Triage step 2 confirms <5.

This is not a fault to "fix" on any individual device — expand the assigned scope of the Intune data collection policy to cover more devices, or, if you're intentionally piloting on a small group, accept that scores will read "Insufficient data" until the pilot group grows past 5.

```powershell
# Confirm current assignment size before deciding whether to expand
Get-MgGroupMember -GroupId '<DataCollectionPolicyTargetGroupId>' -All | Measure-Object
```

**Rollback:** N/A — this is a scope decision, not a destructive action.

</details>

<details><summary>Fix 3 — DiagTrack (Connected User Experiences and Telemetry) stopped or disabled</summary>

Use when: Triage step 3 shows DiagTrack not Running.

```powershell
Set-Service -Name DiagTrack -StartupType Automatic
Start-Service -Name DiagTrack
```

If a GPO or Intune policy is actively disabling DiagTrack (common in privacy-hardened baselines, e.g. via `AllowTelemetry` / diagnostic data settings that go further than Endpoint analytics needs), that policy will re-disable it on the next refresh cycle — identify and carve out an exception for in-scope devices rather than fighting the policy locally.

**Rollback:** If DiagTrack was intentionally disabled for a documented privacy/compliance reason, re-disabling it after troubleshooting restores that posture — but understand this permanently excludes the device from Endpoint analytics.

</details>

<details><summary>Fix 4 — Device hasn't restarted / hasn't had enough elapsed time</summary>

Use when: policy shows Succeeded, DiagTrack is healthy, network path is clean, but the device still isn't in reports.

1. Confirm last restart time is genuinely before the policy was applied (Triage step 4).
2. If so, schedule/prompt a restart. Startup performance data is only generated at boot — no amount of waiting substitutes for an actual restart.
3. After restart, allow up to 24-25 hours for the device to appear in the **Device performance** tab, and up to several weeks for a stable startup score (Microsoft's own guidance: boot-score computation depends on user behavior/power settings and may take longer than the base processing latency to stabilize).

**Rollback:** N/A — no destructive action.

</details>

<details><summary>Fix 5 — Proxy SSL inspection silently discarding telemetry</summary>

Use when: network reachability tests pass but the device never appears in reports, and the environment is known to run SSL/TLS inspection on outbound traffic.

1. Preferred: add an explicit **bypass** rule on the proxy/firewall for `*.events.data.microsoft.com` — do not decrypt/re-sign traffic to this destination.
2. If bypass isn't available and the device has a signed-in user with proxy permissions (not headless, not running Defender for Endpoint): configure user-level WinINET proxy settings and ensure the user has proxy authentication permission. **Do not use this method on devices running Microsoft Defender for Endpoint** — it requires the opposite `DisableEnterpriseAuthProxy` registry value (`1`) from what user proxy auth needs (`0`).
3. For headless devices or devices running Defender for Endpoint: configure device-context WinHTTP proxy instead (`netsh winhttp set proxy`, WPAD, transparent proxy, or the **Make proxy settings per-machine** GPO) and ensure the proxy authenticates computer accounts via Windows-Integrated Authentication.

**Rollback:** Removing a bypass rule restores inspection but re-breaks Endpoint analytics for those devices — document the exception rather than reverting it.

</details>

---
## Escalation Evidence

```
INTUNE ENDPOINT ANALYTICS ESCALATION
======================================
Date/Time                        :
Tenant ID                        :
Device Name                      :
Device Object ID                 :
Windows Edition                  :
DiagTrack Service State          :
Intune Data Collection Policy    : (Succeeded / Pending / Error / Not Assigned)
Last Restart Timestamp           :
Time Elapsed Since Restart       :
Proxy/SSL Inspection In Use      : YES / NO
Devices Reporting in Scope (count):
Per-Device healthStatus Value    : (0 Unknown / 1 Insufficient data / 2 Needs attention / 3 Meeting goals)
Consent to Share Data Enabled    : YES / NO
Managed Via                      : (Intune / Co-managed / ConfigMgr tenant attach)
Steps Already Tried              :
```

---
## 🎓 Learning Pointers

- **A "healthy" score pipeline can still show nothing for days — that's expected, not broken.** Data flows near-real-time → processes every 24h → up to 96h max end-to-end latency, and startup score specifically needs an actual boot event. Don't chase this as a fault until you've confirmed the timing window has genuinely elapsed. [Endpoint analytics data collection — data flow](https://learn.microsoft.com/en-us/intune/endpoint-analytics/ref-data-collection)
- **SSL inspection is the single most common silent killer of this feature.** Certificate pinning means Windows detects a substituted cert and drops the telemetry with zero client-side error — if reachability tests pass but devices never show up, this is the first thing to check in any environment with a corporate proxy. [Troubleshoot endpoint analytics — proxy server authentication](https://learn.microsoft.com/en-us/intune/endpoint-analytics/troubleshoot#proxy-server-authentication)
- **The 5-device minimum is a hard product floor, not a configuration problem.** Small pilot groups will always show "Insufficient data" — this is by design, not something to troubleshoot away.
- **This is a different pipeline from Proactive Remediations and Autopatch.** Endpoint analytics scores device experience (boot time, app crashes, remote-work readiness); it does not run detection/remediation script pairs (`Remediations-B.md`) or orchestrate update rollout (`Autopatch-B.md`) — don't conflate the three when triaging a "device not showing expected data" ticket.
- **CSV exports don't use the friendly UI values — misreading them causes false alarms.** A `MeanTimeToFailure` of `2147483647` means *no crash events*, not an astronomically long uptime; `-1`/`-2` in a score column means the score is unavailable, not zero. [Troubleshooting endpoint analytics — exported CSV values](https://learn.microsoft.com/en-us/intune/endpoint-analytics/troubleshoot#exported-csv-files-display-numerical-values)
- **ConfigMgr custom client settings can lie in the console.** If **Computer Agent** custom client settings pre-date Endpoint analytics onboarding, the console can show **Enable Endpoint analytics data collection = Yes** without it ever having deployed — always verify via **Resultant Client Settings** on the actual device, not the settings object.
