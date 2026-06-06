# Windows Time Troubleshooting (Azure AD / Entra ID Joined) — Deep Dive Runbook

> Scenario: **Azure AD (Entra ID) joined** device.  
> Symptom: `w32tm /query /source` shows **Local CMOS Clock**, and while `ping time.windows.com` works, the clock **won’t sync**.  
> Important: Ping (ICMP) proves almost nothing for NTP. Windows Time uses **NTP over UDP/123**.

---

## 0) What “Local CMOS Clock” means

When `w32tm /query /source` returns **Local CMOS Clock**, it means:

- Windows is **not currently synchronized** to an external source (NTP or otherwise), and
- It is effectively **free-running** from its local hardware clock.

Common reasons:
- W32Time hasn’t successfully contacted or accepted time from a configured NTP source.
- NTP Client provider is **disabled** (often via MDM/Intune policy).
- NTP traffic is blocked (UDP 123, or specifically **source-port 123** behavior).
- The clock is too far off and the client refuses to step it (safety limits).
- W32Time service not running / trigger-start not invoked yet.

---

## 1) Architecture: How time is supposed to work on Azure AD Joined

Azure AD Joined is NOT the same as AD DS domain-joined time hierarchy.

### Expected behavior (workgroup-like)
- Device uses **Windows Time service (W32Time)**.
- It syncs via **NtpClient** provider to configured peers (default can include time.windows.com).
- Transport: **UDP 123**.

### Key distinction
- No AD domain hierarchy (no PDC emulator time chain).
- Device is effectively a stand-alone time client, unless your org configures internal NTP.

---

## 2) Dependency Map (what must be true)

### 2.1 Hardware / firmware layer
- CMOS clock provides initial time at boot.
- Bad CMOS battery → big drift → time corrections may be rejected or break auth and TLS.

### 2.2 Windows correction safety rails (critical)
- Standalone clients may refuse large corrections.
- Default phase correction limits can block sync if the device is wildly wrong (hours+).

### 2.3 Windows Time stack
- **Service:** `W32Time`
- **Provider:** `NtpClient` must be enabled
- Optional influences: Secure Time Seeding (STS), third-party time tools.

### 2.4 Policy layer (very common in orgs)
- Intune/MDM ADMX-backed policies can override:
  - NTP client enable/disable
  - peer list / poll intervals
- If policy disables NtpClient → local changes won’t stick.

### 2.5 Network layer
- DNS resolution of NTP hostname
- Route/NAT to internet/internal NTP
- Firewall allows UDP/123
- **Special gotcha:** Windows NTP client may use **UDP source port 123**, which some security devices block.

---

## 3) Why “Ping works but time won’t sync”

- `ping` = ICMP echo.  
- NTP = UDP/123.  
- Many networks allow ICMP and block/inspect UDP differently.
- Even if UDP/123 is “allowed”, some environments block **source port 123** from clients, breaking W32Time.

Bottom line: you must validate via NTP-aware tests.

---

## 4) Triage Decision Tree (fast isolate root cause)

### 4.1 Verify current state and whether time is WAY off
Run:
```powershell
w32tm /query /status
w32tm /query /source
