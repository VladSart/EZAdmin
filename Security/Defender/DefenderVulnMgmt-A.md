# Defender Vulnerability Management — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains the architecture, data pipeline, and remediation lifecycle of Microsoft Defender Vulnerability Management (MDVM) in an MSP context.

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

**In scope:**
- Microsoft Defender Vulnerability Management (MDVM) — the standalone SKU and the capabilities included in MDE P2
- Software inventory, CVE discovery, security recommendations, and remediation tracking
- Integration with Intune for software patching and configuration baselines
- MDVM on Windows 10/11, Windows Server 2016+, macOS, and Linux (limited)

**Out of scope:**
- Microsoft Defender for Cloud (Azure workloads)
- Defender EASM (External Attack Surface Management)
- Third-party scanner integration (Qualys, Tenable) via MDVM connector

**Assumptions:**
- Devices are onboarded to MDE (sensor running)
- Tenant has MDE P2 or MDVM Add-on licence
- Analyst has Security Reader or Security Administrator role in the Defender portal

---

## How It Works

<details><summary>Full architecture</summary>

MDVM is built on the MDE sensor data pipeline. When a device is onboarded, the MDE sensor (`MsSense.exe` / `SenseIR.exe`) continuously inventories:

1. **Installed software** — via registry hive scanning (`HKLM\SOFTWARE`, `HKLM\SOFTWARE\WOW6432Node`), WMI (`Win32_Product` avoided for performance; uses alternative sources), and application shimming data
2. **File hashes** — for executables, to match against the Microsoft Threat Intelligence CVE database
3. **OS configuration** — registry keys, GPO state, and security baselines (CIS/STIG benchmarks)
4. **Missing patches** — by comparing installed KB list against the Microsoft Update Catalog via the cloud service

This telemetry is streamed to the Microsoft Security Graph cloud backend, which correlates it against:
- The **National Vulnerability Database (NVD)** feed (CVSS scores)
- Microsoft's own **MSRC (Microsoft Security Response Center)** bulletins
- Threat intelligence signals (active exploitation in the wild → Priority score boost)

The result is surfaced in the **Microsoft Defender portal** (`security.microsoft.com`) under:
- **Vulnerability management → Dashboard** — overall exposure score
- **Vulnerability management → Weaknesses** — CVE list with device counts
- **Vulnerability management → Recommendations** — actionable remediation items
- **Vulnerability management → Software inventory** — all detected software per device
- **Vulnerability management → Remediation** — tickets and Intune remediation tasks

```
MDE Sensor (device)
       │
       ├─ Software registry scan
       ├─ Running process hashes
       ├─ OS config baseline checks
       └─ Patch state (WU history)
               │
               ▼
    Microsoft Security Graph (cloud)
               │
               ├─ CVE correlation (NVD + MSRC)
               ├─ Threat Intel enrichment (CISA KEV, in-the-wild)
               └─ Exposure Score calculation
                          │
                    Defender Portal
                          │
              ┌───────────┴───────────┐
         Weaknesses            Recommendations
         (CVEs)                (remediation tasks)
              │                       │
              └──────── Intune ────────┘
                   (software update /
                    config baseline push)
```

**Exposure Score** is a weighted metric (0–100):
- High-severity CVEs on internet-exposed devices score more
- Active exploitation in the wild adds a threat multiplier
- Patched CVEs immediately reduce the score (with ~4h cloud sync delay)

**Microsoft Secure Score for Devices** is a separate metric focused on configuration hardening (e.g. "Enable ASR rules", "Disable SMBv1"), not CVE patching.

</details>

---

## Dependency Stack

```
Microsoft Defender Portal (security.microsoft.com)
        │
        ▼
Microsoft Security Graph (cloud backend)
        │
        ├── MDE Sensor (MsSense.exe) — must be running & healthy
        │         │
        │         ├── Windows: MDE P1/P2 licence, onboarding package applied
        │         ├── macOS: wdav daemon, full disk access granted
        │         └── Server: AMA or legacy MMA (being deprecated)
        │
        ├── Licence check: MDE P2 or MDVM Add-on
        │         └── Assigned to device via Entra group or direct assignment
        │
        ├── Network: Device can reach *.endpoint.security.microsoft.com, *.securitycenter.microsoft.com
        │
        └── Software inventory sync: ~24h initial, ~6h refresh cycle
                  └── CVE correlation: additional ~4h post-sync
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Device not appearing in software inventory | MDE sensor not running or not reporting | `Get-Service -Name Sense` on device; check sensor health in portal |
| CVE count unexpectedly high after onboarding | Normal — first full scan surfaces all existing CVEs | Wait 24h; compare to baseline; check if software versions are accurate |
| Exposure score not decreasing after patching | Cloud sync delay (4–8h) or patch not detected as installed | Verify patch in `Get-HotFix`; check MDVM refresh; force sync via portal |
| Software showing wrong version | Registry shimming or legacy installer leaving stale registry key | Check actual installed version in `winget list` or Programs & Features |
| Recommendations not generating Intune tasks | Intune–MDE connection not configured, or device not Intune-managed | Check connection in `Settings → Endpoints → Intune connection` |
| CVE marked as "Applicable" but not patched by WU | Patch may be out-of-band, superseded, or require manual application | Check MSRC bulletin for remediation path; may need manual installer |
| "No vulnerabilities found" on a known vulnerable device | Sensor not yet completed initial inventory (new onboard) | Wait 24h; verify sensor is reporting via `MdeSensor.ps1` |
| High count of CVEs with no patch available | Third-party software with slow vendor response; OS EOL | Filter by "Patch available" in Weaknesses view; consider upgrade/replace |

---

## Validation Steps

**1. Confirm MDE sensor is healthy on device**
```powershell
Get-Service -Name Sense | Select-Object Name, Status, StartType
# Expected: Status = Running, StartType = Automatic
```
Bad: `Status = Stopped` → onboarding incomplete or sensor crashed

**2. Verify device appears in Defender portal**
```powershell
# Via Graph API (requires SecurityEvents.ReadAll)
$token = (Get-MgAccessToken -Scopes "SecurityEvents.Read.All")
Invoke-RestMethod -Uri "https://api.securitycenter.microsoft.com/api/machines?`$filter=computerDnsName eq '<hostname>'" `
  -Headers @{Authorization = "Bearer $token"}
# Expected: Returns device JSON with healthStatus = "Active"
```

**3. Check last software inventory sync time**
In the Defender portal:
- Navigate to **Vulnerability management → Software inventory**
- Filter by device name
- The "Last updated" column shows the last sync timestamp
- Should be within the last 24h for active devices

**4. Verify Intune connection**
```powershell
# Check in Defender portal via Settings → Endpoints → Advanced features
# Intune connection = On
# Alternatively, check the MDE–Intune connector status in Intune admin center:
# Tenant administration → Connectors and tokens → Microsoft Defender for Endpoint
# Status should be "Enabled"
```

**5. Confirm exposure score is decreasing post-patch**
```powershell
# Force a device sync (via MDE API):
$deviceId = "<MDE-device-id>"
Invoke-RestMethod -Method Post `
  -Uri "https://api.securitycenter.microsoft.com/api/machines/$deviceId/collectInvestigationPackage" `
  -Headers @{Authorization = "Bearer $token"; "Content-Type" = "application/json"} `
  -Body '{"Comment":"Manual sync post-patch"}'
# Then wait 4-8h for portal to reflect updated CVE state
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — Sensor / Inventory Not Working

1. Verify sensor service: `Get-Service Sense`
2. Check MDE onboarding status via registry:
   ```powershell
   Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status" |
     Select-Object OnboardingState
   # OnboardingState = 1 means onboarded
   ```
3. Review MDE sensor logs:
   ```
   %ProgramData%\Microsoft\Windows Defender Advanced Threat Protection\Logs\
   ```
   Look for `MsSense.exe` errors, network connectivity failures, or certificate validation errors.

4. Test network connectivity to MDE endpoints:
   ```powershell
   $urls = @(
     "us-v20.events.data.microsoft.com",
     "winatp-gw-cus.microsoft.com",
     "winatp-gw-eus.microsoft.com",
     "crl.microsoft.com"
   )
   foreach ($url in $urls) {
     $result = Test-NetConnection -ComputerName $url -Port 443 -WarningAction SilentlyContinue
     [PSCustomObject]@{ URL = $url; TcpSuccess = $result.TcpTestSucceeded }
   }
   ```

### Phase 2 — CVEs Not Appearing / Wrong Count

1. Wait 24h post-onboarding — initial inventory takes time
2. Check if the software is in MDVM's inventory at all:
   - Defender portal → **Vulnerability management → Software inventory** → filter by device
3. If software shows but CVE count is 0 for a known-vulnerable version:
   - The CVE may be marked as "Not applicable" due to a mitigating factor (e.g. workaround applied, registry key set)
   - Check the CVE detail page for applicability logic
4. If software doesn't appear at all:
   - It may be installed in a non-standard path not scanned by the sensor
   - Portable executables (not installed via MSI/registry) may not appear

### Phase 3 — Intune Remediation Task Not Creating

1. Verify the **Intune connection** is enabled:
   - Defender portal → **Settings → Endpoints → Advanced features → Intune connection = On**
2. In the Intune admin center, verify the MDE connector:
   - **Tenant administration → Connectors and tokens → Microsoft Defender for Endpoint**
   - Status must be **Enabled** with a recent heartbeat
3. When creating a remediation task from a recommendation:
   - The device must be **Intune-managed** (not just MDE-onboarded)
   - The recommendation must support Intune remediation (software update or config change)
   - Not all CVE types support automated Intune remediation (e.g. BIOS/firmware CVEs cannot)
4. After creating the task, it appears in:
   - Defender portal → **Vulnerability management → Remediation**
   - Intune → **Endpoint security → Security baselines** (for config-type tasks)

---

## Remediation Playbooks

<details><summary>Playbook 1 — Bulk patch Windows OS CVEs via Intune</summary>

**Use when:** MDVM shows multiple CVEs patched by a specific Windows Update KB that hasn't deployed.

```powershell
# Step 1: Identify the KB from the MDVM recommendation
# Defender portal → Recommendations → click recommendation → "Remediation options" → note KB number

# Step 2: Create a Windows Update ring in Intune targeting affected devices
# Intune → Devices → Windows → Update rings → Create
# OR: Use Update policies to push specific KB via "Windows 10/11 quality updates"

# Step 3: Verify KB deployment
$computers = @("<hostname1>", "<hostname2>")
foreach ($computer in $computers) {
  $session = New-PSSession -ComputerName $computer
  Invoke-Command -Session $session -ScriptBlock {
    Get-HotFix | Where-Object { $_.HotFixID -eq "KB<number>" } |
      Select-Object HotFixID, InstalledOn, InstalledBy
  }
  Remove-PSSession $session
}

# Step 4: After deployment, allow 4-8h for MDVM to re-evaluate and update exposure score
```

**Rollback:** Windows Update rollback via `wusa.exe /uninstall /kb:<number>` — use only for non-security quality updates. Security patches generally cannot be safely rolled back.

</details>

<details><summary>Playbook 2 — Remediate third-party software CVE (e.g. Chrome, Acrobat)</summary>

**Use when:** MDVM shows a CVE in a third-party application that Intune can update.

```powershell
# Step 1: Confirm the CVE and required version from MDVM recommendation
# Defender portal → Recommendations → "Update [Software] to version X.X"

# Step 2: Check current deployment in Intune
# Intune → Apps → All apps → find the app → check deployment version

# Step 3: Update the app deployment to the new version
# For Win32 apps: update the .intunewin package and bump the version in the app properties
# For Microsoft Store apps: update should be automatic if "auto-update" is enabled

# Step 4: Force Intune sync on target devices
Invoke-Command -ComputerName <hostname> -ScriptBlock {
  Start-Process "C:\Program Files (x86)\Microsoft Intune Management Extension\AgentExecutor.exe" `
    -ArgumentList "-applicationinstall" -Wait
}

# OR trigger via Intune admin center:
# Devices → find device → Sync

# Step 5: Verify installed version
Invoke-Command -ComputerName <hostname> -ScriptBlock {
  Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" |
    Where-Object { $_.DisplayName -like "*<AppName>*" } |
    Select-Object DisplayName, DisplayVersion
}
```

</details>

<details><summary>Playbook 3 — Suppress/Accept risk for a CVE (exception workflow)</summary>

**Use when:** A CVE cannot be patched (EOL software, business-critical legacy app, compensating control in place).

```powershell
# This must be done in the portal UI — no PowerShell API for exceptions as of 2025

# Portal path:
# Vulnerability management → Weaknesses → select CVE → "Exception options"
# OR
# Vulnerability management → Recommendations → select recommendation → "Request exception"

# Exception types:
# - Third-party fix: vendor has a patch but it's not yet deployed (sets a due date)
# - Alternate mitigation: compensating control in place (e.g. network isolation)
# - Risk accepted: business decision to accept risk (requires justification)

# Document the exception in your ticket system with:
# - CVE ID
# - Business justification
# - Compensating controls
# - Review date (max 6 months for P1/P2 CVEs recommended)

# Exceptions are visible in:
# Vulnerability management → Remediation → Exceptions
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects MDVM evidence for escalation or audit
.NOTES     Requires MDE API access and SecurityEvents.Read.All permission
           Run from a machine with internet access and the Graph/MDE modules
#>

$OutputPath = "$env:TEMP\MDVM-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

# 1. Local sensor health
$sensorHealth = [PSCustomObject]@{
  SenseService = (Get-Service -Name Sense -ErrorAction SilentlyContinue).Status
  SenseStartType = (Get-Service -Name Sense -ErrorAction SilentlyContinue).StartType
  OnboardingState = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status" -ErrorAction SilentlyContinue).OnboardingState
  ComputerName = $env:COMPUTERNAME
  OSVersion = (Get-CimInstance Win32_OperatingSystem).Caption
  CollectedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}
$sensorHealth | Export-Csv "$OutputPath\01-SensorHealth.csv" -NoTypeInformation

# 2. Installed patches (last 90 days)
Get-HotFix | Where-Object { $_.InstalledOn -gt (Get-Date).AddDays(-90) } |
  Sort-Object InstalledOn -Descending |
  Export-Csv "$OutputPath\02-RecentPatches.csv" -NoTypeInformation

# 3. Installed software (registry scan)
$software = @()
$paths = @(
  "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
  "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
foreach ($path in $paths) {
  $software += Get-ItemProperty $path -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName } |
    Select-Object DisplayName, DisplayVersion, Publisher, InstallDate
}
$software | Sort-Object DisplayName | Export-Csv "$OutputPath\03-InstalledSoftware.csv" -NoTypeInformation

# 4. MDE connectivity test
$mdeUrls = @(
  "us-v20.events.data.microsoft.com",
  "winatp-gw-cus.microsoft.com",
  "winatp-gw-eus.microsoft.com",
  "crl.microsoft.com",
  "ctldl.windowsupdate.com"
)
$connectivityResults = foreach ($url in $mdeUrls) {
  $test = Test-NetConnection -ComputerName $url -Port 443 -WarningAction SilentlyContinue
  [PSCustomObject]@{ URL = $url; Port = 443; TcpSuccess = $test.TcpTestSucceeded }
}
$connectivityResults | Export-Csv "$OutputPath\04-MDEConnectivity.csv" -NoTypeInformation

# 5. MDE sensor log (last 100 lines)
$logPath = "$env:ProgramData\Microsoft\Windows Defender Advanced Threat Protection\Logs"
if (Test-Path $logPath) {
  $latestLog = Get-ChildItem $logPath -Filter "*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($latestLog) {
    Get-Content $latestLog.FullName -Tail 100 | Out-File "$OutputPath\05-MDESensorLog-tail100.txt"
  }
}

Write-Host "Evidence collected to: $OutputPath" -ForegroundColor Green
Compress-Archive -Path $OutputPath -DestinationPath "$OutputPath.zip" -Force
Write-Host "Zipped to: $OutputPath.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command / Location |
|------|--------------------|
| Check MDE sensor service | `Get-Service -Name Sense` |
| Verify onboarding state | `Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status"` |
| Get installed software (registry) | `Get-ItemProperty "HKLM:\SOFTWARE\*\CurrentVersion\Uninstall\*" \| Where DisplayName` |
| List recent patches | `Get-HotFix \| Sort-Object InstalledOn -Desc \| Select -First 20` |
| Test MDE network connectivity | `Test-NetConnection winatp-gw-cus.microsoft.com -Port 443` |
| View exposure score | Defender portal → Vulnerability management → Dashboard |
| View CVE list (all devices) | Defender portal → Vulnerability management → Weaknesses |
| View CVEs per device | Defender portal → Device inventory → select device → Discovered vulnerabilities |
| Create Intune remediation task | Defender portal → Recommendations → select → Request remediation |
| View exception requests | Defender portal → Vulnerability management → Remediation → Exceptions |
| Force MDE device sync | Defender portal → Device inventory → select device → Sync (Action menu) |
| List CVEs via MDE API | `GET https://api.securitycenter.microsoft.com/api/vulnerabilities` |
| Get device CVEs via API | `GET https://api.securitycenter.microsoft.com/api/machines/{id}/vulnerabilities` |
| View MDVM in Intune | Intune → Endpoint security → Microsoft Defender for Endpoint |
| Check Intune–MDE connector | Intune → Tenant administration → Connectors and tokens → MDE |

---

## 🎓 Learning Pointers

- **Exposure Score ≠ Patch compliance %** — Exposure Score is risk-weighted (active exploitation multiplier, asset criticality), so a 10% patch compliance improvement may drop Exposure Score by 30% if the patched CVEs were actively exploited. Focus remediation on MDVM's sorted recommendations list, not raw CVE count. [MDVM Exposure Score](https://learn.microsoft.com/en-us/microsoft-365/security/defender-vulnerability-management/tvm-exposure-score)

- **The MDE sensor doesn't use WMI Win32_Product** — Microsoft deliberately avoids `Win32_Product` because querying it triggers an MSI repair on every package (major performance impact). The sensor uses registry hive scanning and file hash analysis instead. This means portable apps and non-installer software may not appear in the inventory. [Software inventory limitations](https://learn.microsoft.com/en-us/microsoft-365/security/defender-vulnerability-management/tvm-software-inventory)

- **CISA KEV drives the threat multiplier** — CVEs listed in the [CISA Known Exploited Vulnerabilities catalog](https://www.cisa.gov/known-exploited-vulnerabilities-catalog) receive a "Threat insights" boost in MDVM's priority scoring. If MDVM flags a CVE as "Active alert" or "Breach indicator," check the KEV catalog first — CISA mandates federal agencies patch these within 2 weeks, and MSPs should treat them with equivalent urgency.

- **Intune remediation tasks only work for Intune-managed devices** — MDE can onboard devices via GPO, SCCM, or local script, but the Intune remediation workflow requires the device to also be enrolled in Intune (MDM-enrolled, not just Entra-joined). For non-Intune devices, export the recommendation list and remediate via SCCM or manual patch deployment. [Intune integration](https://learn.microsoft.com/en-us/microsoft-365/security/defender-vulnerability-management/tvm-security-recommendation)

- **MDVM Add-on vs. MDE P2** — MDVM capabilities are included in MDE P2. The standalone MDVM Add-on is for organizations that want vuln management without the full MDE P2 EDR capabilities (e.g. they use a different EDR). The Add-on licence still requires the MDE sensor to be deployed — it runs in a "passive" mode that collects inventory without interfering with the third-party EDR. [Licensing overview](https://learn.microsoft.com/en-us/microsoft-365/security/defender-vulnerability-management/mdvm-licensing)

- **Software version detection lag is normal** — After deploying a patch or upgrading software, expect up to 8 hours before MDVM reflects the updated version and removes the associated CVEs. If after 24h a patched CVE is still showing, check whether the old software version left registry keys behind (stale uninstall entries are a common false-positive source). [MDVM data freshness](https://learn.microsoft.com/en-us/microsoft-365/security/defender-vulnerability-management/tvm-weaknesses)
