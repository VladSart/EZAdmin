# Network Protection — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---

## Triage

```powershell
# 1. Is Network Protection enabled and in what mode?
Get-MpPreference | Select-Object EnableNetworkProtection
# 0 = Disabled, 1 = Block, 2 = Audit

# 2. Is MDA active (required for Network Protection to enforce)?
Get-MpComputerStatus | Select-Object AMRunningMode, RealTimeProtectionEnabled, NISEnabled

# 3. Recent Network Protection blocks (last 4 hours)
Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 200 |
    Where-Object { $_.Id -eq 1125 -or $_.Id -eq 1126 } |
    Select-Object TimeCreated, Id, Message | Sort-Object TimeCreated -Descending

# 4. Check WdFilter driver (underlying enforcement)
fltmc | findstr /I "WdFilter"

# 5. Check for Network Protection exclusions
Get-MpPreference | Select-Object ExclusionIpAddress, ExclusionProcess
```

| If | Then |
|----|------|
| `EnableNetworkProtection = 0` | Network Protection not configured → **Fix 1** |
| `EnableNetworkProtection = 2` (Audit) | Audit mode — events logged but not blocked; move to Block for enforcement |
| `AMRunningMode = Passive` | Third-party AV active; Network Protection not enforced → check AV stack |
| `NISEnabled = False` | Network Inspection Service disabled → **Fix 2** |
| Event 1125 = Block; legitimate site | False positive → **Fix 3** |
| Event 1126 = Audit only | Policy in Audit mode — normal for testing; no action needed |
| `WdFilter` absent from `fltmc` | Driver not loaded → restart MDA or reboot |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft Defender Antivirus — active, not passive
        │
Windows Defender Network Inspection Service (WdNisSvc) — running
        │
WdFilter.sys kernel driver — loaded
        │
Network Protection enabled (state 1 or 2) via policy
        │
MDE Sensor (MsSense.exe) — for cloud reputation data (SmartScreen back-end)
        │
Device must have internet access to query cloud reputation
        │
Browser/application makes connection to potentially malicious URL/IP
        │
Network Protection evaluates and blocks/audits
```

</details>

---

## Diagnosis & Validation Flow

**1. Confirm NIS service and driver are healthy:**
```powershell
Get-Service -Name WdNisSvc | Select-Object Status, StartType
fltmc | findstr /I "WdFilter"
```
Expected: `WdNisSvc = Running`; `WdFilter` in fltmc output.

**2. Confirm protection state:**
```powershell
Get-MpPreference | Select-Object EnableNetworkProtection
# 1 = Block (enforced), 2 = Audit, 0 = Disabled
```

**3. Check recent Network Protection events:**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 500 |
    Where-Object { $_.Id -in @(1125, 1126, 1127, 1128) } |
    Select-Object TimeCreated, Id, Message |
    Sort-Object TimeCreated -Descending | Select-Object -First 20
```
| Event ID | Meaning |
|----------|---------|
| 1125 | Network Protection blocked a connection |
| 1126 | Network Protection audited a connection (Audit mode) |
| 1127 | Network Protection block overridden (user allowed) |
| 1128 | Network Protection exclusion applied |

**4. Identify blocked URL/IP from event:**
```powershell
# Parse Event 1125 message for URL and process
Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 50 |
    Where-Object Id -eq 1125 |
    ForEach-Object {
        [PSCustomObject]@{
            Time    = $_.TimeCreated
            Message = $_.Message -replace '\s+',' '
        }
    } | Select-Object Time, Message | Format-List
```
The event message contains: URL/IP blocked, process name, and GUID.

**5. Test Network Protection response (controlled):**
```powershell
# Microsoft provides a test URL — safe to use
# Open in browser or test with:
Invoke-WebRequest "https://smartscreentestratings2.net" -ErrorAction SilentlyContinue
# Network Protection in Block mode should prevent this
```

---

## Common Fix Paths

<details><summary>Fix 1 — Enable Network Protection via PowerShell (for standalone/testing)</summary>

```powershell
# Enable in Block mode
Set-MpPreference -EnableNetworkProtection Enabled

# Enable in Audit mode (safe for initial testing)
Set-MpPreference -EnableNetworkProtection AuditMode

# Verify
Get-MpPreference | Select-Object EnableNetworkProtection
# Enabled = 1 (Block), AuditMode = 2

# Test with Microsoft's test URL
Start-Process "https://smartscreentestratings2.net"
```

**In Intune:** Endpoint Security → Attack Surface Reduction → Network Protection = Block / Audit.

**Rollback:**
```powershell
Set-MpPreference -EnableNetworkProtection Disabled
```

</details>

<details><summary>Fix 2 — NIS service (WdNisSvc) stopped or not starting</summary>

```powershell
# Check state
Get-Service -Name WdNisSvc | Select-Object Status, StartType

# Start service
Start-Service -Name WdNisSvc
Set-Service -Name WdNisSvc -StartupType Automatic

# If service fails to start, try restarting all MDA services:
Stop-Service -Name WinDefend, WdNisSvc -Force -ErrorAction SilentlyContinue
Start-Service -Name WinDefend
Start-Service -Name WdNisSvc

# Verify
Get-Service -Name WdNisSvc | Select-Object Status
Get-MpComputerStatus | Select-Object NISEnabled, NISEngineVersion, NISSignatureVersion
```

**If service still won't start:** Check Event Viewer → System for Service Control Manager errors. MDA component may need repair:
```powershell
# Run Windows Security health check
Start-MpScan -ScanType QuickScan
```

</details>

<details><summary>Fix 3 — False positive — legitimate site/IP being blocked</summary>

**Symptom:** Business-critical site blocked by Network Protection (Event 1125).

```powershell
# Step 1: Identify what was blocked from the event
Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 100 |
    Where-Object Id -eq 1125 | Select-Object -First 5 -ExpandProperty Message

# Step 2: Temporarily switch to Audit mode to unblock while investigating
Set-MpPreference -EnableNetworkProtection AuditMode

# Step 3: Confirm it's a false positive (not an actual threat)
# Check URL/IP reputation at: https://www.microsoft.com/en-us/wdsi/support/report-unsafe-site-guest

# Step 4: Submit false positive to Microsoft
# MDE Portal → Reports → Submit a file for analysis (choose URL/IP)

# Step 5: Add process or IP exclusion if needed (not recommended; prefer FP submission)
# Process exclusion (blocks Network Protection for that specific process only):
Add-MpPreference -ExclusionProcess "C:\Path\To\app.exe"

# Step 6: Revert to Block mode after FP is confirmed and submitted
Set-MpPreference -EnableNetworkProtection Enabled
```

**Note:** Network Protection does not support URL-level exclusions — only process or IP exclusions. For URL-level exclusions, configure SmartScreen exclusions via GPO/Intune instead.

**Rollback:**
```powershell
Remove-MpPreference -ExclusionProcess "C:\Path\To\app.exe"
```

</details>

<details><summary>Fix 4 — Network Protection not enforcing despite being set to Block</summary>

**Symptom:** `EnableNetworkProtection = 1` but connections to known-malicious URLs not blocked.

```powershell
# Step 1: Confirm MDA is active, not passive
Get-MpComputerStatus | Select-Object AMRunningMode
# Must be "Normal" — Passive mode does NOT enforce Network Protection

# Step 2: Confirm cloud-delivered protection is enabled (required for URL reputation)
Get-MpPreference | Select-Object MAPSReporting, CloudBlockLevel
# MAPSReporting: 0=None, 1=Basic, 2=Advanced — must be 1 or 2

# Step 3: Enable cloud-delivered protection if disabled
Set-MpPreference -MAPSReporting Advanced

# Step 4: Check NIS signatures are up to date
Get-MpComputerStatus | Select-Object NISSignatureVersion, NISSignatureLastUpdated

# Step 5: Force signature update
Update-MpSignature

# Step 6: Retest with Microsoft test URL
Start-Process "https://smartscreentestratings2.net"
```

</details>

---

## Escalation Evidence

```
=== Network Protection Issue — Ticket Evidence ===

Date/Time:           _______________
Device Name:         _______________
User:                _______________
Issue Type:          [ ] False Positive  [ ] Not Enforcing  [ ] Service Down  [ ] FP Submission

--- Configuration ---
EnableNetworkProtection:  _______________  (0=Off, 1=Block, 2=Audit)
AMRunningMode:            _______________  (must be Normal)
NISEnabled:               _______________
NISEngineVersion:         _______________
NISSignatureVersion:      _______________
MAPSReporting:            _______________

--- Events ---
Event 1125 (Blocked) in last 4h:  _______________  (Y/N, how many)
Blocked URL/IP:                    _______________
Blocking process:                  _______________
Event timestamp:                   _______________

--- Steps Taken ---
[ ] Confirmed MDA in Normal mode
[ ] Confirmed WdNisSvc running
[ ] Checked Event 1125 message
[ ] Tested with MS test URL
[ ] Verified cloud protection enabled
[ ] Switched to Audit mode (if FP — to restore access)
[ ] Submitted FP to Microsoft (URL: https://www.microsoft.com/en-us/wdsi/support/report-unsafe-site-guest)
```

---

## 🎓 Learning Pointers

- **Network Protection ≠ ASR rules** — they're siblings in the Exploit Guard family but distinct features. Network Protection blocks based on URL/IP cloud reputation (SmartScreen back-end). ASR rules block based on behaviour patterns (process relationships, API calls). Both require MDA in active mode. [MS Docs: Network Protection overview](https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/network-protection)

- **Passive mode silently kills enforcement** — when a third-party AV is installed, MDA moves to passive mode and Network Protection stops enforcing blocks (it still logs audits). Always verify `AMRunningMode = Normal` before assuming a policy is working. `Get-MpComputerStatus | Select AMRunningMode` is the definitive check.

- **Cloud protection (MAPS) is required** — Network Protection's URL blocking relies on Microsoft's cloud reputation service. If `MAPSReporting = 0` (disabled), the feature degrades significantly. Some hardened/air-gapped environments deliberately disable MAPS — in those environments, Network Protection only blocks a limited offline list.

- **False positives: report, don't just exclude** — Network Protection exclusions are broad (process-level, not URL-level). A process exclusion removes protection for ALL network connections that process makes. Report FPs via the MDE portal or the WDSI submission page; Microsoft typically updates reputation within 24-48 hours. [MS FP submission](https://www.microsoft.com/en-us/wdsi/support/report-unsafe-site-guest)

- **Audit mode first, Block mode later** — the transition pattern is identical to ASR rules. Deploy Audit mode fleet-wide, review Event 1126 data via Advanced Hunting (`DeviceEvents | where ActionType == "NetworkProtectionUserBypassEvent"`), resolve FPs, then move to Block. Skipping Audit → Block cold is how you get emergency calls about broken LOB applications.
