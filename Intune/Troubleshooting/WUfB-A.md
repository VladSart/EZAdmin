# Windows Update for Business — Reference Runbook (Mode A: Deep Dive)
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

This runbook covers Windows Update for Business (WUfB) in cloud-managed environments:
- WUfB via Intune Update Rings (CSP-based configuration)
- WUfB via Intune Feature Update Policies
- Expedited updates (zero-day patch workflows)
- Windows Update delivery optimisation (DO) and WSUS co-existence
- Reporting via Intune and Windows Update compliance reports

**Assumes:**
- Devices are Entra ID joined or Hybrid joined and Intune enrolled
- Update Ring policies are deployed via Intune (not WSUS or Group Policy)
- Windows 10 21H2+ or Windows 11

**Not covered:** WSUS-only environments; Configuration Manager Software Update Point (SUP); Windows Server patching (use WSUS or Azure Update Manager for those).

---
## How It Works

<details><summary>Full architecture</summary>

### WUfB vs WSUS vs Intune Update Rings

```
Traditional WSUS:
  Device → On-Prem WSUS Server → Microsoft Update

WUfB (cloud-only):
  Device → Windows Update for Business cloud service → Microsoft Update
  (No on-prem server; policies delivered via CSP/MDM or Group Policy)

Intune Update Rings (WUfB management plane):
  Intune Portal → CSP: ./Vendor/MSFT/Policy/Config/Update/* → Device
  Device reads policy → configures WUfB behaviour → contacts MU cloud service directly
```

### Key Policy Areas (Update Ring Settings)

| Setting | CSP Path | What it controls |
|---------|----------|-----------------|
| Servicing channel | `Update/BranchReadinessLevel` | GA Channel, Beta, Dev |
| Quality update deferral | `Update/DeferQualityUpdatesPeriodInDays` | Days to delay Patch Tuesday updates |
| Feature update deferral | `Update/DeferFeatureUpdatesPeriodInDays` | Days to delay OS version upgrades |
| Active hours | `Update/ActiveHoursStart` / `ActiveHoursEnd` | Windows won't reboot during these hours |
| Deadline (quality) | `Update/AutoRestartDeadlinePeriodInDays` | Max days before forced reboot for quality updates |
| Deadline (feature) | `Update/AutoRestartDeadlinePeriodInDaysForFeatureUpdates` | Max days before forced reboot for feature updates |
| Grace period | `Update/ConfigureDeadlineGracePeriod` | Days from first seen before deadline clock starts |
| Delivery Optimisation mode | `DeliveryOptimization/DODownloadMode` | P2P caching behaviour |

### Update Flow (Quality/Patch Tuesday)

```
Microsoft releases Patch Tuesday updates
        │
        ▼
WUfB cloud service holds update
        │ Deferral period (e.g. 5 days)
        ▼
Device becomes eligible to receive update
        │ Device must have WU service running + internet access
        ▼
Device scans WU endpoint (windowsupdate.microsoft.com)
        │
        ▼
Update downloaded (via DO peer cache if configured)
        │
        ▼
Deadline clock starts (grace period from offer date)
        │ User sees toast notifications; can defer within grace period
        ▼
Deadline day reached → forced reboot outside active hours
        │
        ▼
Update installed; device reports compliance to Intune
```

### Delivery Optimisation Modes

| Mode | Value | Behaviour |
|------|-------|-----------|
| HTTP only | 0 | No P2P; direct from Microsoft CDN |
| LAN P2P | 1 | Share with devices on same /16 subnet |
| Group | 2 | Share with devices in same Entra ID group (identified by GUID) |
| Internet P2P | 3 | Share with any internet peer (not recommended for corporate) |
| Simple | 99 | No P2P; no caching |
| Bypass | 100 | Legacy BITS mode |

Most MSP deployments use **Mode 1 (LAN)** or **Mode 2 (Group)** to reduce internet bandwidth.

### Feature Update Policy vs Update Ring

| | Update Ring | Feature Update Policy |
|-|-------------|----------------------|
| Controls | Deferral + reboot behaviour | Target OS version (e.g. pin to 22H2) |
| Granularity | Days | Specific build number |
| Override | Ring deferral applies first | Feature policy takes precedence over ring for OS version |
| Use case | All devices — quality patches | Controlled OS upgrades on specific groups |

**Both policies should be deployed.** Rings alone will eventually upgrade OS versions; Feature Update Policies let you pin a version and upgrade on your schedule.

</details>

---
## Dependency Stack

```
Microsoft Update Service (cloud — Microsoft-managed)
  └── Windows Update for Business cloud service
        └── Intune Update Ring / Feature Update Policy
              └── CSP Policy delivered to device via MDM channel
                    └── Windows Update Service (wuauserv) — must be Running
                          └── Device (Entra ID / Hybrid joined, Intune enrolled)
                                ├── Outbound HTTPS 443 to windowsupdate.microsoft.com
                                ├── Outbound HTTPS 443 to *.delivery.mp.microsoft.com (DO)
                                ├── Outbound HTTPS 443 to *.do.dsp.mp.microsoft.com (DO)
                                ├── Outbound HTTPS 443 to devicemanagement.microsoft.com (Intune)
                                └── Delivery Optimisation service (DoSvc) — for peer caching
                                      └── LAN/Group peers (other managed devices on same network)
```

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Device shows "Up to date" but Intune reports non-compliant | Reporting delay (up to 24h) or compliance policy misconfigured | Intune compliance policy grace period; `wuauclt /detectnow` |
| Update offered but never installs | Active hours too broad; deadline not configured; wuauserv stopped | Active hours settings; Event Log 19; service status |
| Device stuck on specific OS version despite ring allowing upgrade | Feature Update Policy pinning version | Check Feature Update assignments; `Get-WindowsUpdateLog` |
| Update downloads but reboot never happens | User deferring past grace period; no deadline set | Deadline settings in ring; Event Log 20/21 |
| High bandwidth on internet link | DO not configured or mode 0 | DO registry settings; `Get-DeliveryOptimizationStatus` |
| Intune reports "Update failed" | WU error code (CBS/DISM error); insufficient disk space | WU event log error code; disk space check |
| Expedited update not applying quickly | Expedite policy assignment delay; device offline | Device last check-in; expedited ring assignment |
| WSUS conflict (dual-homed device) | WSUS GPO overriding WUfB CSP | `gpresult /h` for Update-related GPO; registry `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` |
| DO peer cache not working | Firewall blocking DO P2P ports; DO service stopped | Port 7680 inbound; DoSvc status |

---
## Validation Steps

**1. Confirm device is receiving WUfB policy**
```powershell
# Check WUfB registry settings (applied by Intune CSP)
$wuPolicyPath = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update"
if (Test-Path $wuPolicyPath) {
    Get-ItemProperty $wuPolicyPath | Select-Object *Defer*, *Deadline*, *ActiveHours*, *Branch*
} else {
    Write-Warning "No WUfB policy applied — device may not be enrolled or policy not assigned"
}
```
Expected: Values present matching your ring configuration.

**2. Check for WSUS conflict (GPO override)**
```powershell
$wsusPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
if (Test-Path $wsusPath) {
    $wsus = Get-ItemProperty $wsusPath -ErrorAction SilentlyContinue
    if ($wsus.WUServer) {
        Write-Warning "WSUS GPO active: $($wsus.WUServer) — this overrides WUfB CSP policies"
    } else {
        Write-Host "No WSUS server override" -ForegroundColor Green
    }
} else {
    Write-Host "No Windows Update GPO path — clean WUfB environment" -ForegroundColor Green
}
```
Expected: No WSUS server configured. If WSUS server present: GPO conflict exists.

**3. Check Windows Update service**
```powershell
$services = @('wuauserv','UsoSvc','DoSvc','bits')
Get-Service -Name $services | Select-Object Name, Status, StartType | Format-Table
```
Expected: `wuauserv` (Windows Update), `UsoSvc` (Update Orchestrator), `DoSvc` (Delivery Optimisation) all `Running`.

**4. Check pending updates and deferral state**
```powershell
# Check update status via COM object
$updateSession = New-Object -ComObject Microsoft.Update.Session
$updateSearcher = $updateSession.CreateUpdateSearcher()
$pendingUpdates = $updateSearcher.Search("IsInstalled=0 AND Type='Software'")
Write-Host "Pending updates: $($pendingUpdates.Updates.Count)"
$pendingUpdates.Updates | Select-Object Title, MsrcSeverity, IsDownloaded | Format-Table
```
Expected: Zero pending updates on a compliant device. Updates listed but not downloaded = download deferred or DO issue.

**5. Validate DO peer caching**
```powershell
# Delivery Optimisation summary
Get-DeliveryOptimizationStatus | Select-Object FileId, Status, BytesFromPeers, BytesFromHTTP, DownloadMode

# Check DO configuration
$doPath = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DeliveryOptimization"
Get-ItemProperty $doPath -ErrorAction SilentlyContinue | Select-Object DODownloadMode, DOGroupId
```
Expected: `BytesFromPeers > 0` on sites with multiple managed devices. `DODownloadMode` matches your policy (1=LAN, 2=Group).

**6. Check last successful update scan time**
```powershell
$lastScan = (New-Object -ComObject Microsoft.Update.AutoUpdate).Results.LastSearchSuccessDate
Write-Host "Last WU scan: $lastScan"
$lastInstall = (New-Object -ComObject Microsoft.Update.AutoUpdate).Results.LastInstallationSuccessDate
Write-Host "Last install: $lastInstall"
```
Expected: Last scan within past 24 hours. If days/weeks old: wuauserv or connectivity issue.

---
## Troubleshooting Steps (by phase)

### Phase 1: Policy Not Applying

1. Confirm device Intune enrollment status in portal (Devices → device → Overview)
2. Check policy assignment — is the device or its user group in scope?
3. Run `dsregcmd /status` — confirm `MDMUrl` and `MDMEnrollmentUrl` present
4. Trigger MDM sync: Intune portal → device → Sync, or `Start-Process ms-settings:workplace`
5. Check for WSUS GPO conflict (Step 2 above) — WSUS GPO wins over MDM CSP for most WU settings

### Phase 2: Update Not Downloading

1. Check internet connectivity to WU endpoints (`Test-NetConnection windowsupdate.microsoft.com -Port 443`)
2. Check disk space — updates require ~10–15GB free minimum
3. Verify DO service is running
4. Check if corporate proxy is blocking WU endpoints (common on devices with forced proxy settings)
5. Review Update event log: `Get-WinEvent -LogName Microsoft-Windows-WindowsUpdateClient/Operational -MaxEvents 20`

### Phase 3: Update Downloaded, Not Installing

1. Check active hours configuration — device won't reboot during active hours window
2. Check deadline settings — if no deadline is set, user can defer indefinitely
3. Look for pending system operations blocking update (pending reboot from previous update)
4. Check Event ID 20 (install failure) or Event ID 21 (reboot pending) in WindowsUpdateClient log

### Phase 4: Compliance Reporting Discrepancy

1. WUfB compliance in Intune has up to 24–48h reporting lag — check `Last check-in` timestamp on device
2. Trigger fresh compliance evaluation: `Invoke-Command {& "$env:SystemRoot\System32\omadmclient.exe"}`  
3. Check compliance policy OS version requirement matches what the ring is delivering
4. If device shows compliant in OS but not in Intune: check Intune compliance policy settings for `OS minimum version`
5. For Windows 11 feature updates: confirm Feature Update Policy targets the correct build (e.g. 22H2 = 10.0.22621)

---
## Remediation Playbooks

<details><summary>Playbook 1 — Force Immediate Update Scan and Install</summary>

Use when: Device is non-compliant but has no obvious block; need to catch up without waiting for scheduled window.

```powershell
# Trigger WU detection/scan
wuauclt.exe /detectnow
Start-Sleep -Seconds 5
wuauclt.exe /updatenow

# Modern approach via UsoClient (Win10 1709+):
UsoClient.exe StartScan
Start-Sleep -Seconds 10
UsoClient.exe StartDownload
Start-Sleep -Seconds 30
UsoClient.exe StartInstall

# Check scan progress via event log
Get-WinEvent -LogName "Microsoft-Windows-WindowsUpdateClient/Operational" -MaxEvents 10 |
    Select-Object TimeCreated, Id, Message | Format-List
```

**Rollback:** Scans and downloads are non-destructive. The install phase requires a reboot — warn users. If a bad patch causes issues, use `wusa.exe /uninstall /kb:<KBID>` to remove.

</details>

<details><summary>Playbook 2 — Remove WSUS GPO Conflict</summary>

Use when: WSUS policy registry keys present; device ignoring Intune WUfB policy.

```powershell
# Identify conflicting GPO
gpresult /h "C:\Temp\gpresult.html" /f
Start-Process "C:\Temp\gpresult.html"
# Look for Computer Configuration > Administrative Templates > Windows Components > Windows Update

# View current WU registry values
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -ErrorAction SilentlyContinue

# Remove WSUS registry values (after confirming GPO source is removed/unlinked):
$wsusKeys = @('WUServer','WUStatusServer','UseWUServer','DisableWindowsUpdateAccess')
foreach ($key in $wsusKeys) {
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" `
        -Name $key -ErrorAction SilentlyContinue
    Write-Host "Removed: $key"
}
Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" `
    -Name "UseWUServer" -ErrorAction SilentlyContinue

# Force GP update to ensure GPO doesn't reapply
gpupdate /force

# Verify WSUS keys are gone
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -ErrorAction SilentlyContinue
```

**Rollback:** If the WSUS GPO is still linked in AD, `gpupdate /force` will restore the keys. You must remove the GPO link or move the device to an OU without the GPO before this fix is persistent.

</details>

<details><summary>Playbook 3 — Expedite a Critical Update (Zero-Day)</summary>

Use when: Critical CVE; you need devices patched in hours, not days.

```powershell
# In Intune: Home > Devices > Windows 10 and later updates > Create Expedited Update Policy
# OR via Graph API:

# Step 1: Get the security update KB number from MSRC
# https://msrc.microsoft.com/update-guide

# Step 2: Create Expedited Update policy via Graph (example)
Connect-MgGraph -Scopes "DeviceManagementConfiguration.ReadWrite.All"
$body = @{
    '@odata.type' = '#microsoft.graph.windowsQualityUpdatePolicy'
    displayName = 'Expedite - Critical CVE [DATE]'
    expeditedUpdateSettings = @{
        qualityUpdateRelease = '<YYYY-MM-DD>'  # Patch Tuesday release date
        daysUntilForcedReboot = 1
    }
} | ConvertTo-Json
Invoke-MgGraphRequest -Method POST `
    -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsQualityUpdatePolicies" `
    -Body $body -ContentType "application/json"

# Step 3: Assign to All Devices group or targeted ring
# Note: Expedited updates override deferral settings in Update Rings
```

**Rollback:** Remove the expedited policy assignment in Intune. Already-installed updates must be uninstalled via `wusa.exe /uninstall /kb:<KBID>` if rollback of the patch itself is needed.

</details>

---
## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect WUfB diagnostic evidence
.NOTES     Run on affected device as Administrator
#>

$outPath = "C:\WUfB_Diag_$(Get-Date -Format 'yyyyMMdd_HHmm')"
New-Item -ItemType Directory -Path $outPath -Force | Out-Null

# WU policy registry
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update" `
    -ErrorAction SilentlyContinue | Out-File "$outPath\wufb_policy.txt"

# WSUS policy (conflict check)
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" `
    -ErrorAction SilentlyContinue | Out-File "$outPath\wsus_policy.txt"

# WU services status
Get-Service wuauserv,UsoSvc,DoSvc,bits | Select-Object Name,Status,StartType |
    Export-Csv "$outPath\services.csv" -NoTypeInformation

# Last scan/install times
$au = New-Object -ComObject Microsoft.Update.AutoUpdate
"LastSearchSuccess: $($au.Results.LastSearchSuccessDate)" | Out-File "$outPath\au_results.txt"
"LastInstallSuccess: $($au.Results.LastInstallationSuccessDate)" | Out-File "$outPath\au_results.txt" -Append

# Pending updates
$sess = New-Object -ComObject Microsoft.Update.Session
$search = $sess.CreateUpdateSearcher()
$pending = $search.Search("IsInstalled=0")
$pending.Updates | Select-Object Title,MsrcSeverity,IsDownloaded |
    Export-Csv "$outPath\pending_updates.csv" -NoTypeInformation

# WU event log (last 50)
Get-WinEvent -LogName "Microsoft-Windows-WindowsUpdateClient/Operational" -MaxEvents 50 `
    -ErrorAction SilentlyContinue |
    Select-Object TimeCreated,Id,LevelDisplayName,Message |
    Export-Csv "$outPath\wu_events.csv" -NoTypeInformation

# Delivery Optimisation
Get-DeliveryOptimizationStatus -ErrorAction SilentlyContinue |
    Export-Csv "$outPath\do_status.csv" -NoTypeInformation

# WU log (human-readable)
Get-WindowsUpdateLog -LogPath "$outPath\WindowsUpdate.log" -ErrorAction SilentlyContinue

# MDM enrollment
dsregcmd /status | Out-File "$outPath\dsregcmd.txt"

Compress-Archive -Path "$outPath\*" -DestinationPath "$outPath.zip" -Force
Write-Host "Evidence at: $outPath.zip" -ForegroundColor Cyan
```

---
## Command Cheat Sheet

```powershell
# Trigger immediate scan
wuauclt.exe /detectnow; UsoClient.exe StartScan

# Trigger immediate download + install
UsoClient.exe StartDownload; UsoClient.exe StartInstall

# Check pending updates
(New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().Search("IsInstalled=0").Updates | Select Title

# Check WUfB policy applied
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update" | Select *Defer*,*Deadline*

# Check WSUS conflict
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -ErrorAction SilentlyContinue

# Generate human-readable WU log
Get-WindowsUpdateLog -LogPath C:\Temp\wu.log

# View last 20 WU events
Get-WinEvent -LogName "Microsoft-Windows-WindowsUpdateClient/Operational" -MaxEvents 20 | Select TimeCreated,Id,Message

# Check DO peer caching status
Get-DeliveryOptimizationStatus | Select FileId,BytesFromPeers,BytesFromHTTP,DownloadMode

# Check DO config
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DeliveryOptimization"

# Force MDM policy sync
Start-Process -FilePath "$env:SystemRoot\System32\deviceenroller.exe" -ArgumentList "/o"

# Check disk space (WU needs ~10-15GB)
Get-PSDrive C | Select-Object Used,Free

# Uninstall a specific KB
wusa.exe /uninstall /kb:<KBID> /norestart /quiet

# Restart WU services
Restart-Service wuauserv,UsoSvc -Force
```

---
## 🎓 Learning Pointers

- **Why WUfB over WSUS?** WSUS requires on-prem infrastructure, manual approval workflows, and database maintenance. WUfB outsources all of this to Microsoft's cloud service — the trade-off is less granular control over specific KB approvals (you control deferral windows, not individual KBs). For most MSP clients without complex change management requirements, WUfB is the correct default. Reference: [WUfB overview](https://learn.microsoft.com/en-us/windows/deployment/update/waas-manage-updates-wufb)
- **The WSUS + WUfB co-existence trap**: If a device has both a WSUS GPO and an Intune Update Ring, the WSUS GPO wins for scan source. The device scans WSUS, which may not have updates approved, and appears stuck or non-compliant in Intune — while Intune believes its CSP is controlling the device. This is one of the most common WUfB headaches in environments migrating from on-prem management. Reference: [Migrate from WSUS to WUfB](https://learn.microsoft.com/en-us/windows/deployment/update/migrate-wsus-to-wufb)
- **Deadline vs. deferral**: Deferral = how long WUfB waits before *offering* an update. Deadline = how long after it's *offered* before a forced reboot. Without a deadline, users can defer reboots indefinitely. Always set both — a common misconfiguration is setting deferral but leaving deadline at default (blank = no forced reboot).
- **Delivery Optimisation is not optional for large sites**: Without DO peer caching, every device downloads the same update independently from Microsoft CDN. A 700MB quality update across 200 devices = 140GB of internet traffic on Patch Tuesday. DO LAN mode (1) requires only port 7680 TCP/UDP inbound between peers on the same subnet — usually already open in LAN firewall rules. Reference: [Delivery Optimisation](https://learn.microsoft.com/en-us/windows/deployment/do/waas-delivery-optimization)
- **Feature Update Policy is your OS version control plane**: Without it, an Update Ring with zero feature deferral will upgrade devices to the latest Windows release as soon as it hits GA + deferral window. Feature Update Policies let you pin a specific build (e.g. 22H2) until you're ready to validate and migrate. Think of it as your "approved OS version" control. Reference: [Feature Update Policy](https://learn.microsoft.com/en-us/mem/intune/protect/windows-10-feature-updates)
