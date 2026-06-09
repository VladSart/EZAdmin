# Network Protection (MDE) — Reference Runbook (Mode A: Deep Dive)
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
- Microsoft Defender for Endpoint (MDE) Network Protection feature
- Block/Audit mode configuration via Intune, Group Policy, or PowerShell
- SmartScreen integration and overlap
- Indicators of Compromise (IoC) — custom block/allow lists
- Web Content Filtering (WCF) and its relationship to Network Protection
- Windows Filtering Platform (WFP) driver interactions
- False positives, broken connectivity, and partial enforcement

**What this does NOT cover:**
- Firewall rules (use Windows Defender Firewall runbooks)
- DNS-based filtering (separate from Network Protection)
- Third-party proxies intercepting TLS traffic
- macOS/Linux Network Protection (separate MDE feature set)

**Assumptions:**
- Windows 10 1709+ or Windows 11 (Network Protection requires this minimum)
- MDE Plan 1 or Plan 2 license, or Microsoft 365 Business Premium
- Devices enrolled in Intune or managed via Group Policy
- WdFilter.sys driver is loaded (part of Windows Defender)

---

## How It Works

<details><summary>Full architecture</summary>

Network Protection operates at the kernel level using the Windows Filtering Platform (WFP). Unlike browser-based SmartScreen which intercepts at the browser layer, Network Protection intercepts at the network stack — any process making outbound connections can be blocked.

### Enforcement Flow

```
Application/Process
        │
        ▼
  Winsock / WinHTTP
        │
        ▼
  Windows Filtering Platform (WFP)
        │  ← WdFilter.sys callout driver hooks HERE
        ▼
  WdFilter.sys (Windows Defender Filter Driver)
        │
        ├── Check: Is destination IP/domain in local IoC list?
        │         ├── Block IoC → DROP (Block mode) or LOG (Audit mode)
        │         └── Allow IoC → PERMIT
        │
        ├── Check: Is destination in Web Content Filtering category?
        │         └── Category blocked → DROP or LOG
        │
        └── Check: SmartScreen cloud reputation (for applicable categories)
                  ├── Malicious URL → DROP or LOG
                  └── Unknown/Clean → PERMIT
```

### Modes
| Mode | Behaviour |
|------|-----------|
| **Off** | Network Protection disabled entirely |
| **Audit** | Connections intercepted and logged but NOT blocked; events written to Windows Event Log |
| **Block** | Connections to malicious/blocked destinations are dropped; user sees Windows Defender notification |

### Key Components
- **WdFilter.sys** — kernel-mode callout driver that registers WFP callouts at `FWPM_LAYER_ALE_AUTH_CONNECT_V4` and `_V6`
- **MsSense.exe** (MDE Sensor) — forwards telemetry to MDE portal; receives IoC updates
- **SecurityHealthService** — Windows Security Center integration; reflects NP status
- **MpsSvc** (Windows Defender Service) — orchestrates policy application
- **SmartScreen** — provides cloud-based URL reputation; NP can consume this data
- **Web Content Filtering** — category-based blocking built on top of NP; requires MDE P2

### IoC Processing
Custom IoC (block/allow) lists are downloaded from the MDE backend via MsSense.exe over HTTPS to `*.endpoint.security.microsoft.com`. These are stored locally and applied by WdFilter.sys without requiring cloud connectivity per-connection.

### Audit Mode Telemetry
In Audit mode, events are written to:
- `Microsoft-Windows-Windows Defender/Operational` event log
- Event ID **1125** = Network Protection blocked connection (Block mode)
- Event ID **1126** = Network Protection audited connection (Audit mode)
- Event ID **1127** = Network Protection allowed connection (for audited/blocked scenarios where allowed)

</details>

---

## Dependency Stack

```
MDE Portal (security.microsoft.com)
        │  IoC sync / policy
        ▼
MsSense.exe (MDE Sensor Service)
        │  applies IoC policy to
        ▼
MpCmdRun.exe / Windows Defender definitions
        │
        ▼
WdFilter.sys (Kernel callout driver)
        │  hooks into
        ▼
Windows Filtering Platform (WFP)
        │  intercepts at
        ▼
Winsock / Network Stack (TCP/IP)
        │
        ▼
Outbound connections (any process)

Parallel dependency:
SmartScreen Service ──────┐
Web Content Filtering ────┤──► WdFilter.sys decision
Custom IoC list ──────────┘
```

**Chain must be intact:** if WdFilter.sys fails to load → Network Protection silently does nothing even if policy says Block.

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| NP shows "Not Configured" in Get-MpPreference | Policy not applied; WdFilter not running | `Get-MpPreference \| Select EnableNetworkProtection` |
| Legitimate HTTPS traffic blocked | False positive IoC or overly broad WCF category | Event ID 1125 in Defender Operational log |
| NP set to Block but connections not dropped | WdFilter.sys failed to load | `fltMC.exe \| findstr WdFilter` |
| Event ID 1116 flooding | NP firing on SmartScreen cloud queries | Check if proxy blocking `*.smartscreen.microsoft.com` |
| Users bypassing NP | Browser using DoH (DNS-over-HTTPS) which bypasses WFP callout | Check Edge/Chrome DoH settings |
| MDE portal shows NP as Audit but device is in Block | Policy conflict — two sources applying different settings | `Get-MpPreference`; check Intune vs GPO conflict |
| Block notification not appearing | Notification service suppressed; Block mode working silently | Check `DisableBlockAtFirstSeen` and notification settings |
| NP blocks VPN traffic | VPN adapter not excluded; WFP sees split-tunnel traffic | Check WFP audit policy; consider IoC allow for VPN endpoints |

---

## Validation Steps

**1. Confirm Network Protection mode**
```powershell
Get-MpPreference | Select-Object EnableNetworkProtection
```
Expected: `1` = Audit, `2` = Block, `0` = Off

**2. Verify WdFilter.sys is loaded**
```powershell
fltmc.exe | findstr -i WdFilter
```
Expected output: `WdFilter  <altitude>  ...`  
Bad: no output = driver not loaded = NP non-functional

**3. Check MDE sensor health**
```powershell
Get-Service -Name Sense | Select-Object Status, StartType
sc.exe query Sense
```
Expected: `Running`, `Automatic`

**4. Review recent Network Protection events**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 100 |
    Where-Object { $_.Id -in 1125, 1126, 1127 } |
    Select-Object TimeCreated, Id, Message |
    Format-List
```
Good: Events present in Audit mode = NP is intercepting. No events = either clean network or NP not working.

**5. Test Network Protection (Microsoft test URL)**
```powershell
# Should be blocked in Block mode, logged in Audit mode
Invoke-WebRequest -Uri "https://smartscreentestratings2.net" -UseBasicParsing -ErrorAction SilentlyContinue
```
Expected in Block mode: connection drops/refuses. Check Event ID 1125 after attempt.

**6. Verify IoC sync from MDE portal**
```powershell
# Check last definition update time (includes IoC)
Get-MpComputerStatus | Select-Object AntivirusSignatureLastUpdated, NisSignatureLastUpdated
```

**7. Check Intune policy application (MDM-enrolled devices)**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Defender\Policy Manager" -ErrorAction SilentlyContinue |
    Select-Object EnableNetworkProtection
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — Confirm NP is actually active

1. Run `Get-MpPreference | Select EnableNetworkProtection` — if `0`, policy not applied
2. Check Intune device config profile: **Endpoint Security > Antivirus > Microsoft Defender Antivirus** — look for "Enable Network Protection"
3. Check for GPO override: `gpresult /h c:\temp\gpresult.html` — search for `EnableNetworkProtection`
4. Verify WdFilter is loaded: `fltmc | findstr WdFilter`
5. Check Windows Defender service state: `Get-Service WinDefend, Sense, WdNisSvc`

### Phase 2 — False Positive / Legitimate traffic blocked

1. Identify blocked destination from Event ID 1125:
   ```powershell
   Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" |
       Where-Object Id -eq 1125 | Select-Object -Last 20 |
       ForEach-Object { $_.Message }
   ```
2. Determine block reason (IoC, WCF category, SmartScreen)
3. If SmartScreen false positive: report via `https://www.microsoft.com/en-us/wdsi/filesubmission`
4. If IoC false positive: navigate MDE Portal > Settings > Endpoints > Indicators — search for and remove the entry
5. If WCF category too broad: MDE Portal > Settings > Endpoints > Web content filtering — review category assignments
6. As emergency workaround: switch to Audit mode temporarily, validate traffic is safe, then add Allow IoC

### Phase 3 — NP policy conflict (Intune vs GPO)

1. `Get-MpPreference` shows unexpected mode despite correct Intune policy
2. Run `gpresult /scope computer /v` — check if GPO has competing `EnableNetworkProtection` value
3. MDM wins over GP for Intune-managed devices **only if** device is MDM-enrolled and `UseWindowsDefaultCSP` is not overriding
4. Check `HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Policy Manager` vs `HKLM:\SOFTWARE\Microsoft\Windows Defender\Policy Manager`
5. If GPO conflict confirmed: remediate by removing conflicting GPO or scoping it to exclude Intune-enrolled devices via security filtering

### Phase 4 — MDE Sensor offline (IoC not syncing)

1. `Get-Service Sense` — if stopped, start it: `Start-Service Sense`
2. Check connectivity to MDE endpoints:
   ```powershell
   Test-NetConnection -ComputerName "*.endpoint.security.microsoft.com" -Port 443
   ```
3. Review MDE connectivity via: `C:\Program Files\Windows Defender Advanced Threat Protection\MsSense.exe` logs in Event Viewer under **Microsoft-Windows-Sense/Operational**
4. If proxy required: confirm `MsSense.exe` proxy config — MDE uses `WinHTTP` proxy, not Internet Explorer/WinINET settings
5. Set proxy for MDE: `netsh winhttp set proxy <proxy:port>`

---

## Remediation Playbooks

<details><summary>Playbook 1 — Enable Network Protection in Block mode (Intune)</summary>

**Via Intune Endpoint Security Policy:**
1. Intune Portal > Endpoint Security > Antivirus > Create Policy
2. Platform: Windows 10, 11 / Profile: Microsoft Defender Antivirus
3. Setting: `Network protection` → Set to `Enabled (block mode)`
4. Assign to device group, sync device

**Via PowerShell (emergency/local):**
```powershell
Set-MpPreference -EnableNetworkProtection Enabled
# Enabled = Block mode (2)
# AuditMode = Audit mode (1)
# Disabled = Off (0)
```

**Rollback:**
```powershell
Set-MpPreference -EnableNetworkProtection AuditMode
```
Switch to Audit first; confirm no business impact; then disable if needed.

</details>

<details><summary>Playbook 2 — Add an Allow IoC (unblock legitimate site)</summary>

**Via MDE Portal:**
1. security.microsoft.com > Settings > Endpoints > Indicators
2. Add indicator > URL/Domain
3. Enter the domain (e.g., `internal-app.contoso.com`)
4. Action: Allow
5. Scope: All devices or specific device group
6. Devices receive update within ~1 hour via MsSense sync

**Via PowerShell (local override — not persistent across policy sync):**
```powershell
# Use MpCmdRun for local testing only
# Proper IoC management must go through MDE portal
```

**Note:** Allow IoCs take precedence over Block IoCs and WCF categories. Use sparingly.

</details>

<details><summary>Playbook 3 — Diagnose and resolve WdFilter.sys not loading</summary>

**Check:**
```powershell
fltmc.exe | findstr WdFilter
# If empty:
driverquery /v | findstr WdFilter
```

**If driver not loaded:**
```powershell
# Restart Windows Defender service stack
Stop-Service -Name WdNisSvc, WinDefend -Force
Start-Service WinDefend
Start-Service WdNisSvc

# If still not loading, check for third-party AV conflict
Get-WmiObject -Namespace root/SecurityCenter2 -Class AntiVirusProduct |
    Select-Object displayName, productState
```

**If third-party AV is present:** WdFilter may be intentionally disabled in passive mode. Network Protection requires MDE active mode OR co-existence mode. Check MDE sensor mode:
```powershell
Get-MpComputerStatus | Select-Object AMRunningMode
# Should be: Normal, Passive, or EDRBlockMode — NOT SxSPassive with no NP
```

**Rollback/escalation:** If WdFilter fails to load after service restart, escalate to Microsoft Support with `MpCmdRun.exe -GetFiles` output.

</details>

<details><summary>Playbook 4 — Temporarily bypass NP for emergency business access</summary>

⚠️ **Destructive / High Risk** — document and reverse within 24 hours.

```powershell
# Switch to Audit mode (logs but doesn't block)
Set-MpPreference -EnableNetworkProtection AuditMode
Write-Host "Network Protection switched to Audit mode — REVERT WITHIN 24 HOURS"

# Log the change
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Add-Content -Path "C:\Temp\NP-Bypass-Log.txt" -Value "$timestamp - NP set to Audit by $env:USERNAME"
```

**Revert:**
```powershell
Set-MpPreference -EnableNetworkProtection Enabled
```

**Note:** Intune policy will re-enforce Block mode on next Intune sync (typically within 8 hours). The local change is temporary.

</details>

---

## Evidence Pack

```powershell
# Run as Administrator — collects all evidence needed for escalation
$OutputDir = "C:\Temp\NP-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

Write-Host "Collecting Network Protection evidence..." -ForegroundColor Cyan

# 1. NP Configuration
Get-MpPreference | Select-Object EnableNetworkProtection, CloudBlockLevel, *Network* |
    Export-Csv "$OutputDir\NP-Config.csv" -NoTypeInformation

# 2. WdFilter driver status
fltmc.exe 2>&1 | Out-File "$OutputDir\WdFilter-Status.txt"

# 3. Defender service status
Get-Service WinDefend, Sense, WdNisSvc, WdFilter |
    Select-Object Name, Status, StartType |
    Export-Csv "$OutputDir\Defender-Services.csv" -NoTypeInformation

# 4. Recent NP events (1125/1126/1127)
try {
    Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 500 |
        Where-Object { $_.Id -in 1125, 1126, 1127 } |
        Select-Object TimeCreated, Id, Message |
        Export-Csv "$OutputDir\NP-Events.csv" -NoTypeInformation
} catch {
    "No NP events found or log inaccessible" | Out-File "$OutputDir\NP-Events.txt"
}

# 5. Full Defender status
Get-MpComputerStatus | Export-Csv "$OutputDir\MpComputerStatus.csv" -NoTypeInformation

# 6. Registry policy values
$regPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows Defender\Policy Manager",
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Policy Manager"
)
foreach ($path in $regPaths) {
    if (Test-Path $path) {
        Get-ItemProperty $path | Export-Csv "$OutputDir\Registry-$(($path -replace '[:\\]','-')).csv" -NoTypeInformation
    }
}

# 7. Group Policy result
gpresult /scope computer /v > "$OutputDir\GPResult.txt" 2>&1

# 8. Installed AV products
Get-WmiObject -Namespace root/SecurityCenter2 -Class AntiVirusProduct |
    Select-Object displayName, productState |
    Export-Csv "$OutputDir\AV-Products.csv" -NoTypeInformation

# 9. Network stack info
Get-NetAdapter | Select-Object Name, InterfaceDescription, Status, LinkSpeed |
    Export-Csv "$OutputDir\NetworkAdapters.csv" -NoTypeInformation

Write-Host "Evidence collected at: $OutputDir" -ForegroundColor Green
Compress-Archive -Path $OutputDir -DestinationPath "$OutputDir.zip"
Write-Host "ZIP: $OutputDir.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Check NP mode | `Get-MpPreference \| Select EnableNetworkProtection` |
| Enable Block mode | `Set-MpPreference -EnableNetworkProtection Enabled` |
| Enable Audit mode | `Set-MpPreference -EnableNetworkProtection AuditMode` |
| Disable NP | `Set-MpPreference -EnableNetworkProtection Disabled` |
| Check WdFilter driver | `fltmc \| findstr WdFilter` |
| View NP block events | `Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" \| Where Id -in 1125,1126,1127` |
| Check MDE sensor | `Get-Service Sense \| Select Status` |
| Trigger MDE sync | `& "C:\Program Files\Windows Defender\MpCmdRun.exe" -SignatureUpdate` |
| Check NP registry policy | `Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Defender\Policy Manager" \| Select EnableNetworkProtection` |
| Full Defender status | `Get-MpComputerStatus` |
| Test NP with EICAR URL | `Invoke-WebRequest -Uri "https://smartscreentestratings2.net" -UseBasicParsing` |
| Check running mode | `Get-MpComputerStatus \| Select AMRunningMode` |
| List IoC from registry | `Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows Defender\Features\Indicators"` |

---

## 🎓 Learning Pointers

- **Network Protection vs SmartScreen:** SmartScreen operates at the browser/application layer and requires app integration. Network Protection is OS-level via WFP — it catches traffic from any process including custom apps, scripts, and malware that avoids browser APIs. They're complementary, not redundant. [MS Docs: Network Protection](https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/network-protection)

- **Audit mode is your friend during rollout:** Always deploy in Audit mode first. Review Event IDs 1126 in the Defender Operational log for 1-2 weeks before switching to Block. This reveals legitimate traffic patterns that would be blocked. [Enable Network Protection](https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/enable-network-protection)

- **DoH bypasses Network Protection:** If Edge or Chrome is configured to use DNS-over-HTTPS, DNS lookups go directly to DoH servers over HTTPS — WFP callouts still intercept the TLS connection itself, but domain-reputation checks that rely on DNS hostname extraction may be less effective. For full coverage, enforce `DnsOverHttps` policy to "Disabled" via Intune/GP. [Microsoft: Network Protection known issues](https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/network-protection#known-issues)

- **Web Content Filtering requires MDE Plan 2:** WCF is built on top of Network Protection and adds category-based blocking (Adult content, Social media, etc.). NP itself (malicious URL blocking) is available in MDE P1/Business Premium. WCF is P2 only. [Web content filtering](https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/web-content-filtering)

- **WFP altitude matters:** WdFilter.sys operates at a specific altitude in the WFP filter stack. Third-party security products may have conflicting callouts at nearby altitudes. If you see WdFilter present but NP not intercepting, check `netsh wfp show filters` for conflicts. This is a less common but hard-to-diagnose failure mode.

- **IoC sync latency:** Custom IoC entries added in the MDE portal are not instant. The device polls for updates during the MDE sensor check-in cycle — typically within 1 hour but can be up to 4 hours on slow/offline devices. Use `MpCmdRun.exe -SignatureUpdate` to force an update cycle after adding IoC entries.
