# Defender Cloud Protection — Hotfix Runbook (Mode B: Ops)
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

Run on the **affected endpoint** as an administrator.

```powershell
# T1: Cloud protection (MAPS) state
(Get-MpComputerStatus).MAPSReporting
# 0=Disabled, 1=Basic, 2=Advanced (2 required for full cloud protection)

# T2: Cloud-delivered protection enabled?
(Get-MpComputerStatus).CloudProtectionEnabled
# Should be: True

# T3: Network connectivity to Defender cloud endpoints
Test-NetConnection -ComputerName 'wdcp.microsoft.com' -Port 443
Test-NetConnection -ComputerName 'wdcpalt.microsoft.com' -Port 443

# T4: Last antivirus signature update
(Get-MpComputerStatus).AntivirusSignatureLastUpdated

# T5: Defender service states
Get-Service WinDefend, WdNisSvc, Sense | Select-Object Name, Status, StartType
```

**Interpretation:**

| Result | Meaning | Action |
|--------|---------|--------|
| `MAPSReporting = 0` | MAPS/cloud protection disabled | Fix Path 1 |
| `CloudProtectionEnabled = False` | Disabled by policy or registry | Fix Path 1 |
| `wdcp.microsoft.com` TCP 443 fails | Proxy/firewall blocking cloud endpoints | Fix Path 2 |
| Signature last updated > 24h ago | Cloud sync broken or update channel blocked | Fix Path 3 |
| WinDefend = Stopped | Defender service down | Fix Path 4 |
| WinDefend missing (Tamper Protection) | Tamper Protection blocking service stop/disable | Fix Path 4 (with care) |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft Defender Cloud (*.wdcp.microsoft.com, *.wd.microsoft.com)
    │
    └── TCP 443 outbound from endpoint
            │
            └── WinDefend service (running)
                    │
                    ├── Cloud-delivered protection enabled (MAPSReporting >= 1)
                    │
                    ├── Automatic sample submission (for enhanced blocking)
                    │
                    └── Cloud block level (High / Not Configured)
                            │
                            └── Endpoint protection policy (Intune/GPO)
```

**Cloud protection layers:**
- **MAPS (Microsoft Active Protection Service):** Real-time cloud queries for unknown files
- **Automatic sample submission:** Sends suspicious files to Microsoft for analysis
- **Cloud block level:** Controls aggressiveness (Default → High → High+ → Zero tolerance)
- **Cloud block timeout:** How long Defender waits for cloud verdict before allowing (default 10s, max 60s)

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Check current Defender cloud protection status**
```powershell
Get-MpComputerStatus | Select-Object `
    ComputerID, AMRunningMode, CloudProtectionEnabled, MAPSReporting,
    AntivirusSignatureLastUpdated, AntivirusSignatureVersion,
    AntispywareSignatureLastUpdated, NISSignatureLastUpdated |
    Format-List
```
**Expected:** `CloudProtectionEnabled = True`, `MAPSReporting = 2`, signature updated within 24h
**Bad:** `False` / `0` → policy is disabling cloud protection

---

**Step 2 — Check active Defender policies (what's enforcing the current state)**
```powershell
# Check registry for MAPS setting applied by policy
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' -ErrorAction SilentlyContinue |
    Select-Object SpyNetReporting, SubmitSamplesConsent, DisableBlockAtFirstSeen
```

| Value | Meaning |
|-------|---------|
| `SpyNetReporting = 0` | MAPS disabled by policy |
| `SpyNetReporting = 1` | Basic MAPS |
| `SpyNetReporting = 2` | Advanced MAPS (required for cloud block) |
| `DisableBlockAtFirstSeen = 1` | Block At First Seen disabled — reduces cloud detection |
| `SubmitSamplesConsent = 0` | Sample submission disabled |

---

**Step 3 — Test cloud connectivity directly**
```powershell
$endpoints = @(
    'wdcp.microsoft.com',
    'wdcpalt.microsoft.com',
    'wd.microsoft.com',
    'definitionupdates.microsoft.com',
    'go.microsoft.com'
)
foreach ($ep in $endpoints) {
    $result = Test-NetConnection -ComputerName $ep -Port 443 -WarningAction SilentlyContinue
    [PSCustomObject]@{
        Endpoint     = $ep
        Reachable    = $result.TcpTestSucceeded
        RemoteAddr   = $result.RemoteAddress
    }
} | Format-Table -AutoSize
```
**Expected:** All `True`
**Bad:** Any `False` → Fix Path 2 (proxy / firewall)

---

**Step 4 — Review Defender operational events**
```powershell
Get-WinEvent -LogName 'Microsoft-Windows-Windows Defender/Operational' -MaxEvents 50 |
    Where-Object { $_.LevelDisplayName -in @('Error','Warning') } |
    Select-Object TimeCreated, Id, Message | Format-List
```
Key event IDs:
- **1116** — Malware detected
- **2000** — Signature updated
- **3002** — Real-time protection encountered an error
- **5008** — Engine update failed
- **5010** — Scanning for malware disabled

---

## Common Fix Paths

<details><summary>Fix 1 — Enable cloud-delivered protection via PowerShell</summary>

**Symptom:** `CloudProtectionEnabled = False` or `MAPSReporting = 0`. No Intune/GPO policy enforcing it — needs immediate local fix pending policy update.

```powershell
#Requires -RunAsAdministrator

# Enable cloud-delivered protection (MAPS) — Advanced level
Set-MpPreference -MAPSReporting Advanced

# Enable Block At First Seen
Set-MpPreference -DisableBlockAtFirstSeen $false

# Enable automatic sample submission
Set-MpPreference -SubmitSamplesConsent SendSafeSamples
# Options: AlwaysPrompt | SendSafeSamples (recommended) | NeverSend | SendAllSamples

# Set cloud block level (HighPlus = aggressive, Default = standard)
Set-MpPreference -CloudBlockLevel HighPlus

# Set cloud block timeout (seconds — default 10, max 60)
Set-MpPreference -CloudExtendedTimeout 50

# Verify
Get-MpComputerStatus | Select-Object CloudProtectionEnabled, MAPSReporting
```

**Rollback:**
```powershell
Set-MpPreference -MAPSReporting Disabled
Set-MpPreference -DisableBlockAtFirstSeen $true
```

**Note:** If a GPO or Intune policy is enforcing `SpyNetReporting = 0`, this local change will be overridden at next policy refresh. Address the policy source (Fix Path 1B).

</details>

<details><summary>Fix 1B — Remove conflicting policy disabling cloud protection</summary>

**Symptom:** Cloud protection keeps reverting to disabled after policy refresh. A Defender policy is explicitly disabling MAPS.

```powershell
# Identify the policy source
gpresult /scope computer /r | Select-String -Pattern 'Defender|MAPS|SpyNet' -Context 2

# Check Intune Defender policy applied to device
# Intune Portal → Devices → [device name] → Device configuration → check for Endpoint Protection profiles
# Look for: "Cloud-delivered protection level" set to "Not configured" or "Disabled"

# Temporary registry fix (will be overridden by policy)
Remove-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet' -Name 'SpyNetReporting' -ErrorAction SilentlyContinue

# Permanent fix: Update the Intune Endpoint Protection profile or GPO
# Set "Cloud-delivered protection level" to "High" or "Not configured" (inherits default = enabled)
```

</details>

<details><summary>Fix 2 — Unblock Defender cloud endpoints at proxy/firewall</summary>

**Symptom:** Cloud protection enabled in policy but not working. `Test-NetConnection` to Defender endpoints fails.

**Required endpoints (all TCP 443):**
```
*.wdcp.microsoft.com
*.wdcpalt.microsoft.com
*.wd.microsoft.com
*.update.microsoft.com
definitionupdates.microsoft.com
go.microsoft.com
```

**Check proxy setting on device:**
```powershell
# System proxy
netsh winhttp show proxy

# WinINet proxy (user-level — Defender uses system proxy)
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' |
    Select-Object ProxyEnable, ProxyServer, ProxyOverride

# Check if Defender is configured to use a static proxy
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Defender' -Name 'ProxyServer' -ErrorAction SilentlyContinue
```

**Configure static proxy for Defender (if system proxy not picked up):**
```powershell
#Requires -RunAsAdministrator
# Replace with your proxy address
$proxy = 'http://proxy.contoso.com:8080'
Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows Defender' -Name 'ProxyServer' -Value $proxy -Type String
Restart-Service WinDefend
```

**Rollback:** Remove the `ProxyServer` registry value.

**Escalation path if proxy is managed appliance:** Provide the URLs above to network team for allow-listing. Defender does not support proxy authentication (NTLM/Kerberos proxy auth is not supported by Defender's cloud client).

</details>

<details><summary>Fix 3 — Force signature update when cloud sync broken</summary>

**Symptom:** Signatures stale (>24h). Devices not picking up updates. Could be delivery channel issue.

```powershell
#Requires -RunAsAdministrator

# Check current signature age and version
$status = Get-MpComputerStatus
Write-Host "Signature version: $($status.AntivirusSignatureVersion)"
Write-Host "Last updated: $($status.AntivirusSignatureLastUpdated)"
Write-Host "Days old: $(((Get-Date) - $status.AntivirusSignatureLastUpdated).Days)"

# Option 1: Force update via Windows Update
Update-MpSignature -UpdateSource MicrosoftUpdateServer

# Option 2: Force update via Microsoft Malware Protection Center (direct)
Update-MpSignature -UpdateSource MMPC

# Option 3: Force via IntelligenceUpdateUri (for environments with internal WSUS/UNC share)
# Update-MpSignature -UpdateSource InternalDefinitionUpdateServer

# Verify update completed
Start-Sleep -Seconds 30
(Get-MpComputerStatus).AntivirusSignatureLastUpdated
```

**If update fails with error:**
```powershell
# Check for error in Defender event log
Get-WinEvent -LogName 'Microsoft-Windows-Windows Defender/Operational' |
    Where-Object { $_.Id -in @(2001,2003,2004,5008) } |
    Select-Object -First 10 TimeCreated, Id, Message | Format-List
```

**Rollback:** N/A — signature updates are non-destructive.

</details>

<details><summary>Fix 4 — Restart Defender services</summary>

**Symptom:** WinDefend or WdNisSvc stopped. Real-time protection failing.

```powershell
#Requires -RunAsAdministrator

# Check all Defender services
$services = @('WinDefend','WdNisSvc','Sense','MdCoreSvc','MpsSvc')
Get-Service $services -ErrorAction SilentlyContinue | Select-Object Name, Status, StartType | Format-Table

# Attempt to start
Start-Service WinDefend -ErrorAction SilentlyContinue
Start-Service WdNisSvc -ErrorAction SilentlyContinue

# If Tamper Protection blocks service manipulation:
# DO NOT attempt to disable Tamper Protection to restart services — this is a security boundary
# Instead: use MDE portal to run a live response session, or reboot the device
# Tamper Protection prevents unauthorized service stops — if WinDefend is stopped, it's a serious incident

# Check Tamper Protection state
(Get-MpComputerStatus).IsTamperProtected

# Reboot as last resort for stuck Defender state
# Restart-Computer -Force
```

**⚠️ If Tamper Protection is enabled and WinDefend won't start:**
This may indicate a more serious issue (kernel conflict, WDAC blocking, or third-party AV conflict). Escalate — do not attempt to disable Tamper Protection without MDE portal authorization.

</details>

---

## Escalation Evidence

```
Defender Cloud Protection — Escalation Ticket
===============================================
Date/Time:              _______________
Device Name:            _______________
Device ID (dsregcmd):   _______________
Tenant ID:              _______________

--- CLOUD PROTECTION STATE ---
CloudProtectionEnabled:               _______________
MAPSReporting value:                  _______________
SpyNetReporting (policy registry):    _______________
DisableBlockAtFirstSeen:              _______________

--- CONNECTIVITY ---
wdcp.microsoft.com:443 reachable:     Yes / No
wdcpalt.microsoft.com:443 reachable:  Yes / No
Proxy in use:                         _______________

--- SIGNATURES ---
AntivirusSignatureVersion:            _______________
AntivirusSignatureLastUpdated:        _______________
NISSignatureLastUpdated:              _______________

--- SERVICES ---
WinDefend status:                     _______________
WdNisSvc status:                      _______________
Sense (MDE) status:                   _______________
IsTamperProtected:                    _______________

--- POLICY SOURCE ---
Managing GPO or Intune policy name:   _______________
gpresult Defender section:            [attach]

--- EVENTS ---
Defender Operational log errors:      [attach CSV]

--- FIXES ATTEMPTED ---
1. _______________
2. _______________
```

---

## 🎓 Learning Pointers

- **Cloud protection vs MAPS:** Microsoft Active Protection Service (MAPS) is the mechanism; "cloud-delivered protection" is the UI label. Both refer to the same feature. When troubleshooting, registry key `SpyNetReporting` and cmdlet `MAPSReporting` are your ground truth — ignore UI labels that can be ambiguous. [MS Docs: Cloud Protection](https://learn.microsoft.com/microsoft-365/security/defender-endpoint/cloud-protection-microsoft-defender-antivirus)

- **Block at First Seen requires cloud protection:** The "Block At First Seen" feature (which blocks unknown malware in seconds using cloud verdict) only works when cloud-delivered protection is enabled at Advanced level. Disabling either disables both. Always check both settings together. [MS Docs: Block at First Seen](https://learn.microsoft.com/microsoft-365/security/defender-endpoint/configure-block-at-first-sight-microsoft-defender-antivirus)

- **Defender doesn't support authenticated proxies:** This is a common enterprise blocker. If your proxy requires NTLM or Kerberos auth, Defender cloud traffic will silently fail. The workaround is to configure proxy bypass for `*.microsoft.com` Defender endpoints or use a unauthenticated transparent proxy/firewall rule. [MS Docs: Proxy requirements for MDE](https://learn.microsoft.com/microsoft-365/security/defender-endpoint/configure-proxy-internet)

- **Tamper Protection is not optional in MDE environments:** Tamper Protection prevents users and malware from disabling Defender. If WinDefend is stopped and Tamper Protection is on, treat it as a potential incident. Legitimate fix paths use the MDE security portal, not local registry edits. Never advise users to disable Tamper Protection to "fix" Defender issues. [MS Docs: Tamper Protection](https://learn.microsoft.com/microsoft-365/security/defender-endpoint/prevent-changes-to-security-settings-with-tamper-protection)

- **Cloud block level tuning:** The default cloud block level ("Default") is conservative — it won't block files that Microsoft hasn't definitively classified. "HighPlus" blocks files with a suspicious reputation score. In security-sensitive environments, test "HighPlus" in audit mode first — it can generate false positives for legitimate LOB applications that don't use code signing. [MS Docs: Cloud block levels](https://learn.microsoft.com/microsoft-365/security/defender-endpoint/specify-cloud-protection-level-microsoft-defender-antivirus)
