# Microsoft Defender Vulnerability Management — Hotfix Runbook (Mode B: Ops)
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

Run these first to determine what's broken:

```powershell
# 1. Check MDE onboarding status (device must be onboarded before MDVM data appears)
# Run on affected device:
Get-Service -Name "Sense" | Select-Object Status, StartType

# 2. Check MDVM sensor health (run on device)
$reg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status" -ErrorAction SilentlyContinue
[PSCustomObject]@{
    OnboardingState = $reg.OnboardingState  # 1 = onboarded
    SenseIsRunning  = $reg.SenseIsRunning   # 1 = running
    OrgId           = $reg.OrgId
}

# 3. Check last scan time (run on device)
Get-MpComputerStatus | Select-Object AMProductVersion, QuickScanStartTime, FullScanStartTime, QuickScanAge

# 4. Pull device's current exposure score via API (requires MDE API token)
# Use Defender portal: security.microsoft.com → Vulnerability Management → Dashboard

# 5. Check if software inventory is populating
# Defender portal: Vulnerability Management → Software inventory → search device name
```

| Result | Interpretation | Action |
|--------|---------------|--------|
| `Sense` service stopped | MDE sensor not running | → Fix 1 |
| `OnboardingState` ≠ 1 | Device not onboarded to MDE | → MDE-Onboarding-B.md |
| Device shows in portal but no CVEs | Software inventory delay | → Fix 2 |
| Device shows "No sensor data" | Connectivity or sensor issue | → Fix 3 |
| CVE shown but remediation task missing | MDVM add-on not licensed | → Fix 4 |
| Remediation request sent but not actioned | ServiceNow/Intune integration | → Fix 5 |
| Exposure score not updating | Data pipeline delay | → Fix 6 |

---
## Dependency Cascade

<details><summary>What must be true for MDVM to work</summary>

```
Microsoft Defender for Endpoint (MDE) — P2 license OR MDVM standalone
└── Device onboarded (Sense service running, OrgId set)
    └── Device communicates to MDE cloud endpoints (*.wdcp.microsoft.com, *.wd.microsoft.com)
        └── Software inventory collected (CBS log, WMI, registry scan)
            └── CVE correlation engine matches software to NVD/MSRC
                └── Recommendations generated in security.microsoft.com
                    ├── Remediation activities (manual or via Intune)
                    ├── Exception requests (workflow)
                    └── Security baselines assessment
                        └── Exposure score calculated per device/org
```

**License requirement:** MDVM is included with MDE P2 (Defender for Endpoint Plan 2). The add-on MDVM standalone SKU adds advanced features (authenticated scans, browser extensions, certificate assessment). Without P2, you get limited vulnerability data only.

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Confirm device is onboarded and sensor healthy**
```powershell
# On affected device (elevated PS)
Get-Service Sense | Select-Object Status
$status = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status"
Write-Host "Onboarding: $($status.OnboardingState) | Running: $($status.SenseIsRunning) | Org: $($status.OrgId)"
```
- Expected: `Onboarding: 1`, `SenseIsRunning: 1`, OrgId populated
- If OrgId is wrong: device is onboarded to a different tenant

**Step 2 — Check software inventory collection**
```powershell
# On affected device — check CBS log for recent activity
Get-Content "$env:WINDIR\Logs\CBS\CBS.log" -Tail 20 | Where-Object { $_ -match "Error|Fail" }

# Check Windows Installer inventory
Get-WmiObject -Class Win32_Product | Measure-Object  # Count of installed products

# Check if MDVM data collection service is active
Get-ScheduledTask -TaskPath "\Microsoft\Windows\Windows Defender\" | Select-Object TaskName,State
```
- If `Win32_Product` returns 0 or very low count: WMI corruption — see Fix 3

**Step 3 — Test connectivity to MDVM cloud endpoints**
```powershell
# Test key MDVM/MDE connectivity endpoints
$endpoints = @(
    "winatp-gw-cus.microsoft.com",
    "winatp-gw-eus.microsoft.com",
    "us-v20.events.data.microsoft.com",
    "wd-prod-cp-us-west-1-fe.westus.cloudapp.azure.com"
)
foreach ($ep in $endpoints) {
    $result = Test-NetConnection -ComputerName $ep -Port 443 -InformationLevel Quiet
    Write-Host "$ep : $result"
}
```
- All should return `True`; failures → proxy/firewall issue

**Step 4 — Check vulnerability portal for device**

In **Defender portal** (`security.microsoft.com`):
- Vulnerability Management → Devices → find device by name
- Check: Last seen, Exposure level, Vulnerabilities count, Software inventory count
- "No sensor data" = Step 1 issue
- "0 software" despite device being active = Step 2 issue

**Step 5 — Validate license assignment**
```powershell
Connect-MgGraph -Scopes "User.Read.All"
$upn = "<user@domain.com>"  # User whose device is affected
Get-MgUserLicenseDetail -UserId $upn | Select-Object SkuPartNumber,ServicePlans | Format-List
```
- Look for `MDATP` (MDE P1), `WINDEFATP` (MDE P2), or `MDE_SMB` in SkuPartNumber
- MDVM features require `mdatp_MDVM` service plan = enabled

---
## Common Fix Paths

<details><summary>Fix 1 — Restart/repair the Sense service</summary>

**Symptom:** Sense service stopped; device shows as inactive in portal.

```powershell
# On affected device (elevated)
# Restart the service
Restart-Service -Name "Sense" -Force
Start-Sleep -Seconds 10
Get-Service -Name "Sense" | Select-Object Status

# If service fails to start, check event log
Get-WinEvent -LogName "Microsoft-Windows-SENSE/Operational" -MaxEvents 20 | Format-List TimeCreated,Message

# If corrupted, re-run the onboarding script
# Download fresh WindowsDefenderATPOnboardingScript.cmd from Defender portal:
# Settings → Endpoints → Device management → Onboarding → Windows 10/11 → Local Script
# Run as administrator
```

**If service keeps crashing:**
```powershell
# Check for conflicting security products
Get-WmiObject -Class AntiVirusProduct -Namespace root/SecurityCenter2 | Select-Object DisplayName
# Third-party AV can conflict with Sense — ensure MDE is in passive mode or AV is removed
```

</details>

<details><summary>Fix 2 — Force software inventory refresh</summary>

**Symptom:** Device onboarded and active, but software inventory shows 0 items or is outdated in MDVM portal. New software not appearing after install.

```powershell
# On affected device (elevated)

# Force MDE to rescan software inventory
# Method 1: Restart MDE sensor (triggers re-scan on startup)
Restart-Service -Name "Sense" -Force

# Method 2: Run Microsoft Compatibility Appraiser (feeds into software inventory)
$task = Get-ScheduledTask -TaskName "Microsoft Compatibility Appraiser" -ErrorAction SilentlyContinue
if ($task) {
    Start-ScheduledTask -TaskPath "\Microsoft\Windows\Application Experience\" -TaskName "Microsoft Compatibility Appraiser"
    Write-Host "Compatibility Appraiser triggered"
} else {
    Write-Host "Task not found — running manual inventory via WMI"
}

# Method 3: Trigger WMI refresh
$namespace = "root\cimv2"
$query = "SELECT * FROM Win32_Product"
(Get-WmiObject -Query $query -Namespace $namespace | Measure-Object).Count | Write-Host "WMI Products:"

# Allow 2-4 hours for data to appear in MDVM portal after scan
Write-Host "Software inventory refresh triggered. Check portal in 2-4 hours."
```

</details>

<details><summary>Fix 3 — Resolve "No sensor data" / connectivity issue</summary>

**Symptom:** Device onboarded (registry shows state=1) but portal shows "No sensor data" or device last seen >7 days ago.

```powershell
# On affected device (elevated)

# 1. Check Windows Defender network service
Get-Service WinDefend, Sense, SecurityHealthService | Select-Object Name,Status

# 2. Check proxy configuration affecting Sense
netsh winhttp show proxy
# Also check system-wide proxy
[System.Net.WebProxy]::GetDefaultProxy().Address

# 3. Test the MDE connectivity diagnostic
# If MDE Connectivity Analyzer is available:
& "$env:ProgramFiles\Windows Defender Advanced Threat Protection\MDATPClientAnalyzer.cmd"
# Output saved to: C:\analyzer_result.zip

# 4. If behind a proxy — set proxy for WinHTTP
netsh winhttp set proxy proxy-server="http=<proxy>:<port>" bypass-list="*.local;<internaldomains>"

# 5. Check Windows Firewall isn't blocking outbound 443
Get-NetFirewallRule -Direction Outbound | Where-Object { $_.Enabled -eq 'True' -and $_.Action -eq 'Block' } | Select-Object DisplayName,Profile
```

**If proxy is confirmed as the issue:**
- Set `TelemetryProxyServer` registry key:
```powershell
Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection" -Name "TelemetryProxyServer" -Value "http://<proxy>:<port>" -Type String
Restart-Service -Name "Sense"
```

</details>

<details><summary>Fix 4 — MDVM features missing (licensing issue)</summary>

**Symptom:** Can see basic vulnerability data but missing: remediation activities, security baselines, browser extension scanning, authenticated scan, certificate assessment.

```powershell
Connect-MgGraph -Scopes "Organization.Read.All"

# Check org-level MDVM license
$org = Get-MgOrganization
$assignedPlans = $org.AssignedPlans | Where-Object { $_.CapabilityStatus -eq "Enabled" }
$assignedPlans | Where-Object { $_.Service -match "WindowsDefenderATP|MDE|MDATP" } | Select-Object Service,CapabilityStatus
```

**MDVM Add-on features require:**
- **MDE P2** (`WINDEFATP`): Included in M365 E5, Defender for Endpoint P2
- **MDVM standalone add-on** (`MDE_VULNERABILITY_MGMT`): Required for authenticated scans, browser extensions, advanced features

If license is missing: escalate to licensing admin to add MDE P2 or MDVM add-on.

> Defender portal: Settings → Endpoints → Licenses (shows what's active)

</details>

<details><summary>Fix 5 — Remediation task created but not actioned by Intune/ServiceNow</summary>

**Symptom:** MDVM remediation activity created in portal, assigned to IT, but patch/config change not deployed.

```powershell
# Check remediation activities via Defender API (requires MDE API permissions)
# Defender portal: Vulnerability Management → Remediation → Activities tab

# For Intune-integrated remediation:
# Verify the Intune connection is active
# Defender portal: Settings → Endpoints → Advanced features → Microsoft Intune connection = On

# For security recommendations pushed to Intune:
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All"
# Check for pending device configuration profiles related to MDVM recommendations
Get-MgDeviceManagementDeviceConfiguration | Where-Object { $_.DisplayName -match "Defender|Security|MDVM" } | Select-Object DisplayName,CreatedDateTime,LastModifiedDateTime
```

**Manual workaround if integration is broken:**
1. Export CVEs from MDVM: Vulnerability Management → Vulnerabilities → Export
2. Cross-reference with affected devices list
3. Push remediation manually via Intune Update Ring or Windows Update for Business

</details>

<details><summary>Fix 6 — Exposure score stale or not updating</summary>

**Symptom:** Exposure score unchanged after patching, or showing incorrect/outdated value.

Exposure score updates are **not real-time** — they can take up to 24 hours after a patch is applied and scanned.

```powershell
# On affected device — verify patch was actually applied
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 10
# Confirm KB number matches CVE remediation recommendation

# Verify Windows Update scan
$wu = New-Object -ComObject Microsoft.Update.Searcher
$result = $wu.Search("IsInstalled=0")
Write-Host "Pending updates: $($result.Updates.Count)"

# Trigger MDE re-evaluation (restart sensor)
Restart-Service -Name "Sense"
Write-Host "Allow 12-24 hours for exposure score to recalculate in portal"
```

**If score still not updating after 24 hours post-patch:**
- Check if device is sending telemetry (Fix 3)
- Verify the patch addresses the specific CVE — some CVEs require non-KB mitigations (config changes, software removal)
- Check MDVM portal → Weaknesses → search CVE ID → confirm remediated devices list updates

</details>

---
## Escalation Evidence

```
ESCALATION TICKET — Microsoft Defender Vulnerability Management
================================================
Date/Time:              _______________
Reported by:            _______________
Affected device(s):     _______________
Device OS:              _______________
MDE sensor version:     _______________

Symptom:                _______________
  □ No sensor data      □ Missing software inventory
  □ CVEs not showing    □ Remediation tasks not working
  □ Exposure score stale □ MDVM features missing

Triage results:
  Sense service status:        _______________
  OnboardingState (registry):  _______________
  SenseIsRunning:              _______________
  OrgId in registry:           _______________
  Last seen in portal:         _______________
  License (MDE P2 / MDVM):    _______________
  Connectivity test (443):     _______________
  Proxy configured:            _______________

CVE/Recommendation in question: _______________
Remediation activity ID:         _______________

Steps already taken:    _______________
Escalating to:          _______________
```

---
## 🎓 Learning Pointers

- **MDVM is built on top of MDE — no sensor, no data.** Every MDVM capability depends on the Sense service running and communicating. If something looks wrong in MDVM, check MDE health first. [MDVM overview](https://learn.microsoft.com/en-us/defender-vulnerability-management/defender-vulnerability-management)
- **Software inventory uses multiple sources**, including CBS (Component Based Servicing), the registry, WMI, and file system scanning. A device with WMI corruption or restrictive AppLocker/WDAC policies blocking these paths will have incomplete inventory.
- **Exposure score ≠ CVE count.** The score is weighted by severity, exploitability, and asset importance. Patching one critical, actively-exploited CVE can move the score more than patching 20 medium CVEs. [Exposure score docs](https://learn.microsoft.com/en-us/defender-vulnerability-management/tvm-exposure-score)
- **The MDVM add-on unlocks authenticated network scans** — meaning you can scan unmanaged/network devices (printers, routers, unmanaged servers) for vulnerabilities without MDE agents. Huge value for MSPs. [Network scan docs](https://learn.microsoft.com/en-us/defender-vulnerability-management/mdvm-network-scan)
- **Remediation activities in MDVM are requests, not actions.** MDVM tells you what to fix; Intune, WSUS, or your RMM actually does the fixing. The Intune integration lets you push remediation directly as a task, but it still requires correct scoping and assignment.
- **Security baselines in MDVM** compare device config against CIS/Microsoft benchmarks — separate from CVEs. Hardening recommendations (disable guest account, enable audit policies) come from baseline assessment, not vulnerability scanning. Check both tabs.
