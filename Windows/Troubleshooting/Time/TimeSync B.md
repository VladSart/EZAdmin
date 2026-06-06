# TimeSync v2 — Windows 11 (Entra ID Joined)

> **Purpose:** Fast diagnosis and fix for Windows time sync issues.  
> **Audience:** L2/L3 IT Support.  
> **Scope:** Windows 11 (AADJ / Entra ID joined, not AD DS).

---

## Skim Index

- [Triage (30–60 seconds)](#triage-30–60-seconds)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage (30–60 seconds)

Run these first. Do not troubleshoot blind.

```powershell
w32tm /query /source
w32tm /query /status
tzutil /g
```

### Interpret

- **Source = Local CMOS Clock** → policy or network problem
- **No Last Successful Sync Time** → sync never occurred
- **Wrong time zone** → looks like drift but isn’t

If still broken → continue.

---

## Dependency Cascade

Time sync fails if **any layer below breaks**.

<details>
<summary><strong>Layer 0 — Hardware / Firmware</strong></summary>

- RTC / CMOS battery
- BIOS clock sanity
- Large drift after sleep or power-off

If time is wrong after cold boot → hardware issue.

</details>

<details>
<summary><strong>Layer 1 — Windows Time Service</strong></summary>

- `W32Time` must start
- NtpClient provider enabled

```powershell
Get-Service w32time
w32tm /query /configuration /verbose
```

</details>

<details>
<summary><strong>Layer 2 — Policy / MDM (Intune)</strong></summary>

- Policy can disable NTP completely
- Policy overrides all local fixes

```powershell
reg query "HKLM\\SOFTWARE\\Policies\\Microsoft\\W32Time\\TimeProviders\\NtpClient" /v Enabled
reg query "HKLM\\SOFTWARE\\Policies\\Microsoft\\W32Time\\Parameters" /v NtpServer
```

</details>

<details>
<summary><strong>Layer 3 — Network / Firewall</strong></summary>

- DNS must resolve NTP
- UDP destination port 123 allowed
- Some networks require **source port 123 allowed**

```powershell
w32tm /stripchart /computer:time.windows.com /dataonly /samples:5 /packetinfo
```

</details>

<details>
<summary><strong>Layer 4 — External NTP Source</strong></summary>

- Public NTP reachable
- Or corporate NTP required by policy

Test multiple sources.

</details>

---

## Diagnosis & Validation Flow

Follow in order. Stop when you find the break.

### 1. Confirm join + management

```powershell
dsregcmd /status
```

Expect:
- AzureAdJoined = YES
- DomainJoined = NO

---

### 2. Validate service health

```powershell
Get-Service w32time
sc qtriggerinfo w32time
```

Service should not instantly stop.

---

### 3. Validate effective configuration

```powershell
w32tm /query /configuration /verbose
w32tm /query /source
w32tm /query /peers
```

Red flags:
- NtpClient disabled
- Empty peer list
- Source = Local CMOS Clock

---

### 4. Prove network reachability

```powershell
nslookup time.windows.com
w32tm /stripchart /computer:time.windows.com /dataonly /samples:5 /packetinfo
```

Interpretation:
- Stripchart timeouts → UDP/123 blocked
- Stripchart works but resync fails → source-port-123 or policy

---

### 5. Force resync

```powershell
net start w32time
w32tm /resync /rediscover
```

Re-check:

```powershell
w32tm /query /status
w32tm /query /source
```

---

## Common Fix Paths

<details>
<summary><strong>MDM / Intune disables NTP</strong></summary>

- Registry shows `Enabled=0`
- Local fixes revert

Fix in Intune:
- Enable Windows NTP Client
- Configure valid peers

</details>

<details>
<summary><strong>UDP 123 blocked</strong></summary>

- Stripchart fails
- Ping works (ICMP ≠ NTP)

Fix:
- Allow outbound UDP 123
- Allow source port 123 if required
- Or use corporate NTP

</details>

<details>
<summary><strong>Clock offset too large</strong></summary>

- Device hours off

Fix:
- Set time roughly correct
- Then resync

</details>

<details>
<summary><strong>Time snaps back after fixing</strong></summary>

- Policy or agent overriding

Fix:
- Identify authority
- One time source only

</details>

---

## Escalation Evidence

Copy into ticket before escalation.

```powershell
w32tm /query /status
w32tm /query /source
w32tm /query /configuration /verbose
w32tm /query /peers

dsregcmd /status

w32tm /stripchart /computer:time.windows.com /dataonly /samples:5 /packetinfo
```

---

**Rule of thumb:**

> If the device can’t reach UDP 123 or policy disables NTP — Windows cannot fix time. No script will save you.
