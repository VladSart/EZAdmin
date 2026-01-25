# Windows 11 (25H2) — Azure AD / Entra ID Joined — Time Sync Troubleshooting Runbook

> **Audience:** L2/L3 IT Support / Endpoint / Infra  
> **Scope:** Windows 11 25H2 devices **Azure AD (Entra) joined** (workgroup-like time behavior, not AD DS hierarchy).  
> **Goal:** Diagnose and fix “won’t sync time”, “source is Local CMOS Clock”, “Sync now doesn’t work”, drift, and policy/network edge cases.

---

## Table of Contents
- [1. Scope & Assumptions](#1-scope--assumptions)
- [2. How Time Sync Works (AADJ)](#2-how-time-sync-works-aadj)
- [3. Dependency Stack](#3-dependency-stack)
- [4. Symptom → Likely Cause Map](#4-symptom--likely-cause-map)
- [5. Validation Steps (Top-to-Bottom)](#5-validation-steps-top-to-bottom)
- [6. Troubleshooting Steps (Top-to-Bottom)](#6-troubleshooting-steps-top-to-bottom)
- [7. Remediation Playbooks (by Root Cause)](#7-remediation-playbooks-by-root-cause)
- [8. Evidence Pack (Escalation-Ready)](#8-evidence-pack-escalation-ready)
- [9. Appendix — Command Cheat Sheet](#9-appendix--command-cheat-sheet)

---

## 1) Scope & Assumptions

### In scope
- Windows 11 25H2 endpoints that are:
  - **Azure AD (Entra) joined** (AADJ)
  - Possibly **Intune-managed** / MDM enrolled

### Not in scope (different runbook)
- AD DS domain-joined time hierarchy (PDC emulator, NT5DS, etc.)
- DC time sourcing and domain replication impacts

### Definitions
- **System clock**: actual time used by OS for auth/TLS/logging
- **Time zone**: display offset; wrong TZ can look like wrong time
- **W32Time**: Windows Time service (sync engine)
- **NTP**: time protocol used by W32Time (UDP/123)

---

## 2) How Time Sync Works (AADJ)

### What AADJ means for time
- Azure AD join does **not** provide an AD time hierarchy.
- AADJ devices behave like **standalone/workgroup clients**:
  - Sync using **Windows Time service** (`W32Time`) + **NtpClient provider**
  - Use configured NTP peers (often defaults like `time.windows.com` unless overridden)

### Protocol truth
- NTP uses **UDP port 123**
- `ping time.windows.com` proves ICMP works, **not** NTP.

### The “ping works but NTP doesn’t” gotcha
- The built-in Windows NTP client commonly uses **UDP source port 123**.
- Some firewalls allow outbound UDP *to* 123 but block traffic *from* source port 123.
- Result: stripchart might work while resync fails (or vice versa), depending on path/security gear.

### Secure Time Seeding (STS) (context)
- Windows can “seed” time using TLS metadata if the device clock is wildly wrong.
- It’s a safety net, not a replacement for NTP.
- In locked-down networks, STS may be the only thing that partially corrects time until NTP is allowed.

---

## 3) Dependency Stack

Time sync fails if **any** layer is broken.

### Layer 0 — Hardware / Firmware
- RTC/CMOS clock accuracy + battery health
- BIOS/UEFI time configuration
- Frequent sleep/hibernate/resume patterns
- Dual-boot behavior (RTC set to UTC vs local time)

### Layer 1 — OS / Services / Providers
- `W32Time` service must run
- `NtpClient` provider enabled
- UDP socket behavior: port 123 binding and conflicts can matter

### Layer 2 — Policy / MDM / Intune
- Policy can:
  - Disable NTP client entirely
  - Force NTP peer list
  - Force poll intervals/behavior
- **Policy wins** (local changes get overwritten)

### Layer 3 — Network / DNS / Firewall
- DNS resolves NTP hostnames
- Outbound UDP 123 allowed
- NAT isn’t mangling/blackholing UDP 123
- Captive portals / guest Wi-Fi / ZTNA
- **Source port 123 allowed** (the classic “everything else works” failure)

### Layer 4 — External Time Source
- NTP server responds reliably
- Not rate-limiting your clients
- Corporate policy may require internal NTP only (public NTP blocked)

---

## 4) Symptom → Likely Cause Map

### Symptom: `w32tm /query /source` = `Local CMOS Clock`
**Likely causes**
- NTP client disabled by policy/MDM
- NTP unreachable (UDP 123 blocked)
- Service not running / trigger-start not firing
- Clock offset too large; W32Time rejects correction
- Peer list empty/invalid

### Symptom: “Ping time.windows.com works but clock won’t sync”
**Likely causes**
- UDP 123 blocked (ICMP allowed)
- Source port 123 blocked (Windows NTP client behavior)
- Public NTP blocked; only corporate NTP allowed

### Symptom: “Sync now” works once, then it stops syncing
**Likely causes**
- W32Time trigger-start behavior (service runs only on demand)
- Scheduled tasks disabled/failing
- Poll interval too long / device asleep/off during schedule
- Policy reverts config later

### Symptom: Time drifts badly after being powered off / long sleep
**Likely causes**
- CMOS battery/RTC drift
- Device offline during sync windows
- STS influencing initial correction then drifting

### Symptom: Time “snaps back” after you fix it
**Likely causes**
- Policy re-applying different config
- Another time agent/tool correcting it
- Wrong time zone (looks like a snapback)

---

## 5) Validation Steps (Top-to-Bottom)

> Don’t “fix” until you know which layer is broken. Collect proof as you go.

### 5.1 Confirm join type and management state

```powershell
dsregcmd /status
```

**Look for**
- `AzureAdJoined : YES`
- `DomainJoined : NO` (pure AADJ)
- MDM enrollment URLs if managed (Intune)

---

### 5.2 Confirm time zone isn’t the real issue

```powershell
tzutil /g
Get-Date
```

**If TZ is wrong**
- Fix TZ (may be controlled by policy/Intune)
- Then re-check system time

---

### 5.3 Check Windows Time service state + triggers

```powershell
Get-Service w32time
sc query w32time
sc qtriggerinfo w32time
```

**Healthy**
- Service starts and stays stable when needed

**Red flags**
- Service disabled
- Service starts then stops instantly
- Triggers missing/misconfigured (rare but can happen)

---

### 5.4 Read effective W32Time configuration (and what’s applied)

```powershell
w32tm /query /configuration /verbose
w32tm /query /status
w32tm /query /source
w32tm /query /peers
```

**Healthy**
- `/source` is NOT `Local CMOS Clock`
- `/status` includes a recent `Last Successful Sync Time`
- `/peers` shows expected NTP peers

**Red flags**
- NtpClient disabled
- No peers / empty list
- Type/sync mode not what you expect
- Last sync time ancient or missing

---

### 5.5 Check policy keys (fast “policy is blocking me” test)

```powershell
reg query "HKLM\SOFTWARE\Policies\Microsoft\W32Time\TimeProviders\NtpClient" /v Enabled
reg query "HKLM\SOFTWARE\Policies\Microsoft\W32Time\Parameters" /v NtpServer
```

**Interpretation**
- If policy key exists and `Enabled=0` → endpoint local fixes won’t stick.
- If `NtpServer` exists under Policies → peers are being enforced.

---

### 5.6 Prove NTP reachability (the money test)

```powershell
w32tm /stripchart /computer:time.windows.com /dataonly /samples:5 /packetinfo
w32tm /stripchart /computer:time.cloudflare.com /dataonly /samples:5 /packetinfo
w32tm /stripchart /computer:time.google.com /dataonly /samples:5 /packetinfo
```

**Healthy**
- You see offsets/delay values updating

**Broken**
- Timeouts to all → UDP 123 blocked / route / DNS / captive portal

**Special indicator**
- Stripchart works but resync fails → likely source-port-123 blocking or policy preventing W32Time from using peers.

---

### 5.7 DNS sanity (when stripchart fails)

```powershell
nslookup time.windows.com
nslookup time.cloudflare.com
nslookup time.google.com
```

If DNS fails → fix DNS/network first. NTP won’t work without name resolution unless you use IPs.

---

### 5.8 Check if UDP 123 is bound/conflicted locally

```powershell
netstat -ano | findstr ":123"
```

You’re checking whether something else is binding port 123 or if W32Time is behaving unexpectedly.

---

### 5.9 Validate Scheduled Tasks for time sync

```powershell
schtasks /Query /TN "\Microsoft\Windows\Time Synchronization\SynchronizeTime" /V /FO LIST
schtasks /Query /TN "\Microsoft\Windows\Time Synchronization\ForceSynchronizeTime" /V /FO LIST
```

**Look for**
- `Last Run Result: 0x0` (success)
- Task is enabled
- Reasonable last run time (not “never”)

---

### 5.10 Enable Operational logging (for precise failure cause)

```powershell
wevtutil sl Microsoft-Windows-Time-Service/Operational /e:true
w32tm /resync /rediscover
```

Then review:
- Event Viewer → Applications and Services Logs → Microsoft → Windows → Time-Service → Operational

---

## 6) Troubleshooting Steps (Top-to-Bottom)

> Minimal risk first. Don’t shotgun registry edits until you’ve proven the layer.

### Step 1 — Confirm it’s not “wrong time zone”
- Settings → Time & language → Date & time:
  - **Set time automatically** = ON
  - Click **Sync now**
- Validate:

```powershell
tzutil /g
Get-Date
w32tm /query /source
```

---

### Step 2 — Start W32Time cleanly and resync

```powershell
net start w32time
w32tm /resync /rediscover
w32tm /query /status
w32tm /query /source
```

If it errors, capture exact output and proceed to the relevant root-cause playbook.

---

### Step 3 — If `Local CMOS Clock`, verify policy is not disabling NTP

```powershell
w32tm /query /configuration /verbose
reg query "HKLM\SOFTWARE\Policies\Microsoft\W32Time\TimeProviders\NtpClient" /v Enabled
```

- If `Enabled=0` → fix in Intune/MDM, not locally.

---

### Step 4 — Prove UDP/123 path works (or doesn’t)

```powershell
w32tm /stripchart /computer:time.windows.com /dataonly /samples:5 /packetinfo
w32tm /stripchart /computer:time.cloudflare.com /dataonly /samples:5 /packetinfo
```

- If timeouts to both: network path is blocked.
- If stripchart works but resync fails: suspect source-port-123 blocking or policy restrictions.

---

### Step 5 — If clock is wildly wrong, get it close first
If the device is off by many hours:
- Set time roughly correct (GUI or admin tooling)
- Then:

```powershell
w32tm /resync /rediscover
```

---

### Step 6 — Set manual peers (ONLY if policy doesn’t override)

```powershell
net stop w32time
w32tm /config /manualpeerlist:"time.windows.com,0x9 time.cloudflare.com,0x8" /syncfromflags:manual /update
net start w32time
w32tm /resync /rediscover
w32tm /query /source
w32tm /query /status
```

If it reverts later, you’re being overridden by MDM policy.

---

### Step 7 — Service trigger-start behaving weird? Validate tasks + triggers

```powershell
sc qtriggerinfo w32time
schtasks /Query /TN "\Microsoft\Windows\Time Synchronization\SynchronizeTime" /V /FO LIST
```

If your org needs W32Time always-on:

```powershell
sc config w32time start= auto
net stop w32time
net start w32time
```

(Only do this if your standards require it.)

---

### Step 8 — Turn on W32Time debug log for hard evidence

```powershell
net stop w32time
w32tm /debug /enable /file:C:\w32time.log /size:10000000 /entries:0-300
net start w32time
w32tm /resync /rediscover
```

Review:
- `C:\w32time.log`
- Time-Service Operational log

---

## 7) Remediation Playbooks (by Root Cause)

### Playbook A — MDM/Intune policy disables NTP client
**Signals**
- Policy registry key exists and shows NtpClient `Enabled=0`
- `w32tm /query /configuration /verbose` indicates provider disabled or forced config

**Fix**
- Remediate in Intune/MDM:
  - Enable Windows NTP Client
  - Configure allowed NTP peers (often corporate NTP)
  - Confirm policy is assigned to the device/user group

**Validate**

```powershell
reg query "HKLM\SOFTWARE\Policies\Microsoft\W32Time\TimeProviders\NtpClient" /v Enabled
w32tm /query /configuration /verbose
w32tm /resync /rediscover
w32tm /query /source
```

---

### Playbook B — UDP/123 blocked (or source port 123 blocked)
**Signals**
- `w32tm /stripchart` times out to multiple servers
- Or stripchart works but `w32tm /resync` fails (source-port 123 suspicion)

**Fix**
- Test on alternate network (hotspot) to prove it’s network-side
- Engage network/security to allow:
  - Outbound UDP destination port 123
  - And if necessary, allow client **UDP source port 123** behavior for W32Time
- If public NTP is blocked by policy:
  - Use corporate NTP servers instead

**Validate**

```powershell
w32tm /stripchart /computer:time.windows.com /dataonly /samples:5 /packetinfo
w32tm /resync /rediscover
w32tm /query /source
```

---

### Playbook C — Clock offset too large (samples rejected)
**Signals**
- Device time is wildly wrong (hours+)
- Resync attempts don’t change the clock
- Logs indicate correction rejected / too large

**Fix**
- Set time roughly correct manually first
- Then resync

**Validate**

```powershell
Get-Date
w32tm /resync /rediscover
w32tm /query /status
```

---

### Playbook D — Scheduled task disabled/failing
**Signals**
- Time sync only works manually
- Tasks show non-zero Last Run Result or never run

**Fix**
- Re-enable task(s) if permitted by org policy
- Check task history/errors
- Ensure device is online during run windows

**Validate**

```powershell
schtasks /Query /TN "\Microsoft\Windows\Time Synchronization\SynchronizeTime" /V /FO LIST
w32tm /query /status
```

---

### Playbook E — Another time agent is fighting you
**Signals**
- You fix time, it snaps back later
- Port conflicts or repeated corrections
- Vendor tools installed (VM tools, OEM utilities, security agents)

**Fix**
- Identify the agent/service responsible
- Align org standard: only one authority for time sync
- Remove/disable conflicting time features where appropriate

**Validate**

```powershell
w32tm /query /source
w32tm /query /status
netstat -ano | findstr ":123"
```

---

## 8) Evidence Pack (Escalation-Ready)

Collect this bundle before escalating to MDM or Network teams.

### Core state

```powershell
dsregcmd /status
tzutil /g
Get-Date
w32tm /query /status
w32tm /query /source
w32tm /query /configuration /verbose
w32tm /query /peers
```

### Policy proof

```powershell
reg query "HKLM\SOFTWARE\Policies\Microsoft\W32Time\TimeProviders\NtpClient" /v Enabled
reg query "HKLM\SOFTWARE\Policies\Microsoft\W32Time\Parameters" /v NtpServer
```

### Network proof

```powershell
nslookup time.windows.com
w32tm /stripchart /computer:time.windows.com /dataonly /samples:5 /packetinfo
w32tm /stripchart /computer:time.cloudflare.com /dataonly /samples:5 /packetinfo
```

### Task proof

```powershell
schtasks /Query /TN "\Microsoft\Windows\Time Synchronization\SynchronizeTime" /V /FO LIST
schtasks /Query /TN "\Microsoft\Windows\Time Synchronization\ForceSynchronizeTime" /V /FO LIST
```

### Logs
- Export:
  - Microsoft-Windows-Time-Service/Operational
- Optional debug log:

```powershell
net stop w32time
w32tm /debug /enable /file:C:\w32time.log /size:10000000 /entries:0-300
net start w32time
w32tm /resync /rediscover
```

Attach:
- Exported event logs
- `C:\w32time.log` (if enabled)

---

## 9) Appendix — Command Cheat Sheet

### Quick “what’s my source?”

```powershell
w32tm /query /source
```

### Full health snapshot

```powershell
w32tm /query /status
w32tm /query /configuration /verbose
w32tm /query /peers
```

### Prove NTP reachability

```powershell
w32tm /stripchart /computer:time.windows.com /dataonly /samples:5 /packetinfo
```

### Force sync

```powershell
net start w32time
w32tm /resync /rediscover
```

### Set manual peers (only if policy allows)

```powershell
net stop w32time
w32tm /config /manualpeerlist:"time.windows.com,0x9 time.cloudflare.com,0x8" /syncfromflags:manual /update
net start w32time
w32tm /resync /rediscover
```

### Check for policy override

```powershell
reg query "HKLM\SOFTWARE\Policies\Microsoft\W32Time\TimeProviders\NtpClient" /v Enabled
reg query "HKLM\SOFTWARE\Policies\Microsoft\W32Time\Parameters" /v NtpServer
```

### Check tasks

```powershell
schtasks /Query /TN "\Microsoft\Windows\Time Synchronization\SynchronizeTime" /V /FO LIST
```
