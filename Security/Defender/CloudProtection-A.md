# Defender Cloud Protection — Reference Runbook (Mode A: Deep Dive)
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

**Covers:**
- Microsoft Defender Antivirus Cloud Protection (MAPS — Microsoft Active Protection Service)
- Block at First Sight (BAFS)
- Cloud-delivered protection levels and timeout settings
- MAPS telemetry levels (Basic, Advanced)
- Signature update via cloud vs. Security Intelligence Updates (SIU)
- Intune/GPO/SCCM delivery of cloud protection settings

**Assumes:**
- Windows 10 1703+ or Windows 11 endpoint
- Microsoft Defender Antivirus is the active AV (not in passive/EDR-only mode unless noted)
- Network connectivity to Defender cloud endpoints
- Devices enrolled in MDE or Intune (cloud-only or co-managed)

**Out of scope:**
- Defender for Endpoint SIEM integration
- Custom indicators and IOC management (see MDE-Onboarding-A.md)
- Third-party AV coexistence

---

## How It Works

<details><summary>Full architecture — Cloud Protection pipeline</summary>

### MAPS (Microsoft Active Protection Service)

MAPS is the cloud telemetry and query service underpinning Defender's cloud-delivered protection. When Defender encounters an unknown or suspicious file, it sends a **sample report** to MAPS and receives a near-real-time verdict.

```
Endpoint                    Microsoft Cloud
┌──────────────────┐        ┌─────────────────────────────┐
│  Defender AV     │        │  MAPS / Cloud Protection    │
│                  │        │                             │
│  File encounter  │──────▶│  1. File hash lookup        │
│                  │        │  2. Metadata analysis       │
│  Unknown hash?   │◀──────│  3. ML classification       │
│  → Send to MAPS  │        │  4. Detonation (if needed)  │
│                  │        │  5. Block/Allow verdict     │
└──────────────────┘        └─────────────────────────────┘
         │
         ▼
  Block at First Sight (BAFS)
  ┌────────────────────────────────┐
  │ Before execution, if:          │
  │ - File is unknown to cloud     │
  │ - No existing SIU signature    │
  │ → Block pending cloud verdict  │
  │ → Timeout = 1–60 seconds      │
  └────────────────────────────────┘
```

### Protection Levels

| Level | Registry Value | Behavior |
|-------|---------------|---------|
| Disabled | 0 | No cloud queries — not recommended |
| Basic (default) | 1 | Block known-bad; minimal telemetry |
| Advanced | 2 | Heuristic + ML; broader telemetry |
| Not Configured | (GPO default) | Inherits OS default = Basic |
| Zero Tolerance | 4 | Block all unknowns aggressively |

### Signature Update Flow

```
Cloud SIU (hourly)
      │
      ▼
Security Intelligence Update
      │
      ├── Delivered via Windows Update
      ├── Delivered via WSUS (if configured)
      ├── Delivered via MDE onboarding package
      └── Direct cloud pull (if MAPS reachable)

BAFS supplements SIU — catches zero-day before signature exists
```

### BAFS Decision Tree

```
File execution request
        │
        ▼
Known good hash? ──YES──▶ Allow
        │
        NO
        │
        ▼
Known bad hash? ──YES──▶ Block (SIU signature)
        │
        NO
        │
        ▼
Cloud Protection enabled? ──NO──▶ Allow with heuristics only
        │
        YES
        │
        ▼
Query MAPS (async, max N seconds)
        │
        ├──Verdict=Malicious──▶ Block + quarantine
        ├──Verdict=Safe──▶ Allow
        └──Timeout/No network──▶ Allow (default) or Block (Zero Tolerance)
```

### Required Cloud Endpoints

| Service | Endpoint | Protocol |
|---------|----------|----------|
| MAPS | `*.wns.windows.com` | HTTPS 443 |
| MAPS primary | `*.wd.microsoft.com` | HTTPS 443 |
| SIU | `go.microsoft.com` | HTTPS 443 |
| SIU | `definitionupdates.microsoft.com` | HTTPS 443 |
| BAFS | `*.smartscreen.microsoft.com` | HTTPS 443 |
| Detonation | `*.blob.core.windows.net` | HTTPS 443 |
| MDE cloud | `unitedstates.x.cp.wd.microsoft.com` | HTTPS 443 |
| MDE cloud | `*.endpoint.security.microsoft.com` | HTTPS 443 |

</details>

---

## Dependency Stack

```
Microsoft Defender Cloud Protection
        │
        ├── Windows Defender Antivirus Service (WinDefend)
        │       └── Must be running + active AV (not passive)
        │
        ├── Network Connectivity
        │       ├── *.wd.microsoft.com (HTTPS 443)
        │       ├── *.wns.windows.com (HTTPS 443)
        │       └── TLS inspection proxy awareness (MUST allow)
        │
        ├── Windows Security Center (wscsvc)
        │       └── Reports AV status to OS
        │
        ├── Policy (GPO / Intune CSP / Registry)
        │       ├── MAPSReporting (telemetry level)
        │       ├── SubmitSamplesConsent (auto-sample submission)
        │       └── MpCloudBlockLevel (protection aggressiveness)
        │
        └── MDE Onboarding (optional but typical)
                └── Extends cloud verdicts with org-specific IOCs
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Cloud protection shows "Off" in Security Center | GPO/Intune policy setting MAPS=Disabled | `Get-MpPreference \| Select MAPSReporting` |
| BAFS not blocking unknown files | BAFS disabled or protection level=Basic | `Get-MpPreference \| Select CloudBlockLevel, CloudExtendedTimeout` |
| Slow file access with AV scans | BAFS timeout too high (cloud query delay) | `CloudExtendedTimeout` value; reduce or test with 0 |
| "Cloud protection: error" in Defender UI | Network cannot reach MAPS endpoints | Test-NetConnection to `*.wd.microsoft.com:443` |
| Signatures stuck >7 days old | WSUS blocking cloud SIU; cloud SIU fallback failing | Check WSUS settings + `Get-MpComputerStatus` |
| Files quarantined that shouldn't be | Overly aggressive cloud protection level | `MpCloudBlockLevel` = 4 (Zero Tolerance) |
| Event 1116 (malware detected) but no quarantine | Remediation setting or tamper protection conflict | Check remediation config + Tamper Protection state |
| Policy conflict — Intune vs GPO | Both sources configured; GPO wins | Check RSOP / registry duplication |

---

## Validation Steps

**1. Check current cloud protection state**
```powershell
Get-MpPreference | Select-Object MAPSReporting, SubmitSamplesConsent, CloudBlockLevel, CloudExtendedTimeout, DisableBlockAtFirstSeen
```
Expected good:
- `MAPSReporting` = 2 (Advanced) or 1 (Basic) — NOT 0
- `DisableBlockAtFirstSeen` = False
- `CloudBlockLevel` = 2 (High) recommended; 0 = not configured
- `CloudExtendedTimeout` = 0–50 (seconds beyond default 10)

**2. Verify Defender service is active AV**
```powershell
Get-MpComputerStatus | Select-Object AMRunningMode, AntivirusEnabled, RealTimeProtectionEnabled
```
Expected: `AMRunningMode = Normal`, `AntivirusEnabled = True`

**3. Test MAPS connectivity**
```powershell
Test-NetConnection -ComputerName "wd.microsoft.com" -Port 443
Test-NetConnection -ComputerName "unitedstates.x.cp.wd.microsoft.com" -Port 443
```
Expected: `TcpTestSucceeded = True`

**4. Check signature age**
```powershell
Get-MpComputerStatus | Select-Object AntivirusSignatureLastUpdated, AntivirusSignatureVersion
```
Expected: LastUpdated within 24 hours (or per your SLA)

**5. Confirm BAFS is not disabled**
```powershell
(Get-MpPreference).DisableBlockAtFirstSeen
```
Expected: `False`

**6. Check policy source (registry)**
```powershell
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet" -ErrorAction SilentlyContinue
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows Defender\Spynet" -ErrorAction SilentlyContinue
```
Policy registry takes precedence over Defender preference. If both exist, HKLM\SOFTWARE\Policies wins.

**7. Review recent cloud verdicts in event log**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" |
    Where-Object { $_.Id -in @(1116, 1117, 2050, 2051) } |
    Select-Object TimeCreated, Id, Message |
    Format-List
```

---

## Troubleshooting Steps (by phase)

### Phase 1 — Establish Baseline State

```powershell
# Full cloud protection snapshot
$pref = Get-MpPreference
$status = Get-MpComputerStatus

[PSCustomObject]@{
    MAPSReporting          = $pref.MAPSReporting
    CloudBlockLevel        = $pref.CloudBlockLevel
    CloudExtendedTimeout   = $pref.CloudExtendedTimeout
    DisableBAFS            = $pref.DisableBlockAtFirstSeen
    SubmitSamplesConsent   = $pref.SubmitSamplesConsent
    AMRunningMode          = $status.AMRunningMode
    AntivirusEnabled       = $status.AntivirusEnabled
    RTPEnabled             = $status.RealTimeProtectionEnabled
    SigLastUpdated         = $status.AntivirusSignatureLastUpdated
    SigVersion             = $status.AntivirusSignatureVersion
} | Format-List
```

### Phase 2 — Policy Conflict Detection

```powershell
# Check if GPO is suppressing cloud settings
$spynetPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet"
if (Test-Path $spynetPath) {
    Write-Warning "GPO Spynet key detected — policy may override Intune/local settings"
    Get-ItemProperty $spynetPath
} else {
    Write-Host "No GPO Spynet override found" -ForegroundColor Green
}

# Check Defender policy key
$defPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
Get-ItemProperty $defPolicyPath -ErrorAction SilentlyContinue
```

### Phase 3 — Network Connectivity

```powershell
$endpoints = @(
    "wd.microsoft.com",
    "wdcp.microsoft.com",
    "wdcpalt.microsoft.com",
    "smartscreen.microsoft.com",
    "unitedstates.x.cp.wd.microsoft.com"
)

foreach ($ep in $endpoints) {
    $result = Test-NetConnection -ComputerName $ep -Port 443 -WarningAction SilentlyContinue
    [PSCustomObject]@{
        Endpoint = $ep
        Reachable = $result.TcpTestSucceeded
        PingSuccess = $result.PingSucceeded
    }
} | Format-Table -AutoSize
```

### Phase 4 — Signature Currency

```powershell
$status = Get-MpComputerStatus
$age = (Get-Date) - $status.AntivirusSignatureLastUpdated

if ($age.TotalHours -gt 24) {
    Write-Warning "Signatures are $([int]$age.TotalHours)h old — forcing update"
    Update-MpSignature -UpdateSource MicrosoftUpdateServer
} else {
    Write-Host "Signatures OK: $([int]$age.TotalMinutes) minutes old" -ForegroundColor Green
}
```

### Phase 5 — Force Cloud Protection On

```powershell
# Enable MAPS Advanced + BAFS (run as admin, use only if no policy conflict)
Set-MpPreference -MAPSReporting Advanced
Set-MpPreference -DisableBlockAtFirstSeen $false
Set-MpPreference -CloudBlockLevel High
Set-MpPreference -CloudExtendedTimeout 10

Write-Host "Cloud protection settings applied. Verify in Security Center UI."
```

---

## Remediation Playbooks

<details><summary>Playbook 1 — Cloud Protection Disabled by GPO</summary>

**Symptom:** `MAPSReporting = 0` and GPO Spynet key present.

**Cause:** Group Policy `Configure the 'Block at First Sight' feature` or `Join Microsoft MAPS` set to Disabled.

**Fix:**
1. Open Group Policy Management on DC
2. Navigate to: `Computer Configuration → Administrative Templates → Windows Components → Microsoft Defender Antivirus → MAPS`
3. Set `Join Microsoft MAPS` to `Advanced MAPS`
4. Set `Configure the 'Block at First Sight' feature` to `Enabled`
5. Force GPO: `gpupdate /force` on client

**Verify:**
```powershell
gpresult /r | Select-String -Pattern "MAPS|Defender"
(Get-MpPreference).MAPSReporting  # Should be 2
```

**Rollback:** Revert GPO settings to previous state; no destructive changes made.

</details>

<details><summary>Playbook 2 — BAFS Disabled via Intune</summary>

**Symptom:** `DisableBlockAtFirstSeen = True` traced to Intune MDM policy.

**Fix via Intune:**
1. Navigate to: Endpoint Security → Antivirus → [Policy Name]
2. Find `Block At First Sight` setting → Set to `Yes (Enabled)`
3. Set `Cloud-delivered protection level` to `High` or `High+`
4. Assign and sync

**Fix via PowerShell (temporary, will be overridden by policy):**
```powershell
Set-MpPreference -DisableBlockAtFirstSeen $false
Invoke-MpScan -ScanType QuickScan
```

**Check MDM diagnostic:**
```powershell
# Export MDM diagnostic report
$path = "$env:TEMP\MDMDiagReport"
mdmdiagnosticstool.exe -area DeviceEnrollment;DeviceProvisioning;TPM -zip "$path.zip"
Write-Host "Report at: $path.zip"
```

**Rollback:** Remove or reassign Intune policy to previous state.

</details>

<details><summary>Playbook 3 — MAPS Network Blocked by Proxy/Firewall</summary>

**Symptom:** `TcpTestSucceeded = False` for `*.wd.microsoft.com`.

**Cause:** Corporate proxy or firewall blocking MAPS endpoints. Common with SSL inspection.

**Fix (proxy bypass — apply at WinHTTP or proxy PAC):**
```powershell
# Check current WinHTTP proxy
netsh winhttp show proxy

# If proxy in use, add bypass for Defender endpoints
# Edit your PAC file or proxy policy to allow:
# *.wd.microsoft.com, *.wdcp.microsoft.com, *.smartscreen.microsoft.com

# For per-machine WinHTTP bypass (temporary test):
netsh winhttp set proxy proxy-server="<proxyServer>:<port>" bypass-list="*.wd.microsoft.com;*.wdcp.microsoft.com"
```

**SSL inspection:** If using TLS inspection, add Defender endpoints to the bypass/exclusion list in your proxy solution (Zscaler, Netskope, Forcepoint, etc.).

**Firewall rule (if no proxy):**
```
Allow HTTPS (443) outbound to:
  13.89.0.0/16 (Microsoft Defender cloud range)
  52.168.0.0/16
  52.184.0.0/16
  Or use FQDN-based rules for *.wd.microsoft.com
```

**Rollback:** Revert proxy/firewall change; no endpoint changes made.

</details>

<details><summary>Playbook 4 — Zero Tolerance Causing False Positive Quarantines</summary>

**Symptom:** `CloudBlockLevel = 4`, legitimate software being quarantined.

**Fix:**
```powershell
# Reduce to High (2) or Medium (1)
Set-MpPreference -CloudBlockLevel High
# Or via Intune: Cloud-delivered protection level → High

# Restore quarantined item (get ThreatID from event log first)
$threats = Get-MpThreat
$threats | Select-Object ThreatID, ThreatName, Resources | Format-List

# Restore specific threat
Restore-MpThreat -ThreatID <ThreatID>

# Add exclusion to prevent re-quarantine (use with care)
Add-MpPreference -ExclusionPath "C:\Path\To\LegitApp"
```

**Rollback:** Set CloudBlockLevel back to 4 if needed; remove exclusion path if added incorrectly.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Cloud Protection Evidence Collection
.NOTES     Run as Administrator. Safe — read-only except Update-MpSignature.
#>

$report = @{}

# 1. Defender preferences
$pref = Get-MpPreference
$report["Preferences"] = [PSCustomObject]@{
    MAPSReporting        = $pref.MAPSReporting
    CloudBlockLevel      = $pref.CloudBlockLevel
    CloudExtendedTimeout = $pref.CloudExtendedTimeout
    DisableBAFS          = $pref.DisableBlockAtFirstSeen
    SubmitSamples        = $pref.SubmitSamplesConsent
    ExclusionPaths       = $pref.ExclusionPath -join "; "
    ExclusionExtensions  = $pref.ExclusionExtension -join "; "
}

# 2. Computer status
$status = Get-MpComputerStatus
$report["Status"] = [PSCustomObject]@{
    AMRunningMode      = $status.AMRunningMode
    AntivirusEnabled   = $status.AntivirusEnabled
    RTPEnabled         = $status.RealTimeProtectionEnabled
    CloudProtEnabled   = $status.CloudProtectionEnabled
    SigLastUpdated     = $status.AntivirusSignatureLastUpdated
    SigVersion         = $status.AntivirusSignatureVersion
    EngineVersion      = $status.AMEngineVersion
    ProductStatus      = $status.AMProductVersion
}

# 3. Policy registry
$spynet = Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet" -ErrorAction SilentlyContinue
$report["GPOSpynet"] = if ($spynet) { $spynet } else { "Not present" }

# 4. Network connectivity
$endpoints = @("wd.microsoft.com","wdcp.microsoft.com","smartscreen.microsoft.com")
$report["NetworkTests"] = $endpoints | ForEach-Object {
    $r = Test-NetConnection -ComputerName $_ -Port 443 -WarningAction SilentlyContinue
    [PSCustomObject]@{ Endpoint=$_; OK=$r.TcpTestSucceeded }
}

# 5. Recent Defender events
$report["RecentEvents"] = Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 30 |
    Where-Object { $_.Id -in @(1116,1117,2050,2051,5001,5010) } |
    Select-Object TimeCreated, Id, Message

# 6. Export
$ts = Get-Date -Format "yyyyMMdd-HHmm"
$outFile = "$env:TEMP\DefenderCloudEvidence-$ts.json"
$report | ConvertTo-Json -Depth 6 | Out-File $outFile -Encoding UTF8
Write-Host "Evidence saved to: $outFile" -ForegroundColor Cyan

# Display summary
$report["Preferences"] | Format-List
$report["Status"] | Format-List
$report["NetworkTests"] | Format-Table
```

---

## Command Cheat Sheet

| Action | Command |
|--------|---------|
| Check all cloud settings | `Get-MpPreference \| Select MAPSReporting,CloudBlockLevel,CloudExtendedTimeout,DisableBlockAtFirstSeen` |
| Check AV running mode | `(Get-MpComputerStatus).AMRunningMode` |
| Check cloud protection enabled | `(Get-MpComputerStatus).CloudProtectionEnabled` |
| Check signature age | `(Get-MpComputerStatus).AntivirusSignatureLastUpdated` |
| Force signature update | `Update-MpSignature` |
| Enable MAPS Advanced | `Set-MpPreference -MAPSReporting Advanced` |
| Enable BAFS | `Set-MpPreference -DisableBlockAtFirstSeen $false` |
| Set cloud level to High | `Set-MpPreference -CloudBlockLevel High` |
| Test MAPS connectivity | `Test-NetConnection wd.microsoft.com -Port 443` |
| View recent AV events | `Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 50` |
| List quarantined items | `Get-MpThreat` |
| Restore quarantined file | `Restore-MpThreat -ThreatID <ID>` |
| Force Defender scan | `Start-MpScan -ScanType QuickScan` |
| Check GPO policy key | `Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet"` |
| Export MDM diagnostic | `mdmdiagnosticstool.exe -area DeviceEnrollment -zip $env:TEMP\mdm.zip` |

---

## 🎓 Learning Pointers

- **MAPS vs. SIU are complementary, not competing.** Signature Intelligence Updates (SIU) cover known threats at point-in-time; MAPS provides real-time cloud verdicts for zero-days. Disabling either weakens the model significantly. See: [Microsoft Defender cloud protection overview](https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/cloud-protection-microsoft-defender-antivirus)

- **TLS inspection is the #1 MAPS connectivity killer.** Proxy solutions that do SSL inspection often block Defender's certificate pinned connections. Always add `*.wd.microsoft.com` to inspection bypass — it's a Microsoft trust requirement. See: [Configure proxy and connectivity for MDE](https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/configure-proxy-internet)

- **CloudBlockLevel 4 (Zero Tolerance) is aggressive by design.** It's appropriate for high-security environments but will block unsigned or uncommon software. Use custom file indicators (MDE allow list) for known-good binaries before enabling. See: [Block at first sight](https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/configure-block-at-first-sight-microsoft-defender-antivirus)

- **GPO wins over Intune for Spynet keys.** If both a GPO `HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet` key and Intune CSP are present, GPO takes precedence. This is a common co-management trap — always check RSOP before assuming Intune controls are applied.

- **`AMRunningMode = Passive` means cloud protection does nothing for blocking.** Passive mode occurs when a third-party AV is detected or when MDE is in audit mode. Cloud protection still sends telemetry but won't block. Ensure you understand running mode before troubleshooting block failures.

- **Sample submission consent controls what BAFS can detonate.** `SubmitSamplesConsent = 0` (Always prompt) or `3` (Never send) prevents unknown samples from reaching Microsoft's sandbox, which weakens BAFS verdict accuracy. Set to `1` (Send safe samples) or `2` (Send all) for full protection. See: [Sample submission settings](https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/enable-cloud-protection-microsoft-defender-antivirus)
