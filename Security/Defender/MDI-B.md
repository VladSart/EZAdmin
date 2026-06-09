# Microsoft Defender for Identity — Hotfix Runbook (Mode B: Ops)
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

Run these five commands first. Output tells you exactly where to go.

```powershell
# 1. Check MDI sensor service on a Domain Controller
Get-Service -Name "AATPSensor","AATPSensorUpdater" -ComputerName <DC_NAME> |
    Select-Object Name, Status, StartType

# 2. Check sensor health via Graph/MDI portal (web check)
# Navigate: security.microsoft.com → Settings → Identities → Sensors
# OR use the MDI PowerShell module if installed:
# Get-MDISensor

# 3. Check last event received from a DC sensor
# MDI portal → Health issues → Look for "Domain controller is not syncing" or "No events received"

# 4. Check DNS resolution from DC to MDI cloud endpoint
Invoke-Command -ComputerName <DC_NAME> -ScriptBlock {
    Resolve-DnsName "*.atp.azure.com" -Type A
    Test-NetConnection "<WORKSPACE>.atp.azure.com" -Port 443
}

# 5. Check DC event log for sensor errors
Get-WinEvent -ComputerName <DC_NAME> -FilterHashtable @{
    LogName   = "Application"
    ProviderName = "Azure Advanced Threat Protection Sensor"
    Level     = 2  # Error
    StartTime = (Get-Date).AddHours(-2)
} -ErrorAction SilentlyContinue | Select-Object TimeCreated, Message | Select-Object -First 10
```

**Interpretation:**

| Finding | Action |
|---------|--------|
| AATPSensor service Stopped | → [Fix 1 — Restart sensor service](#fix-1--restart-sensor-service) |
| DNS resolution fails for `*.atp.azure.com` | → [Fix 2 — Fix network/proxy connectivity](#fix-2--fix-networkproxy-connectivity) |
| Sensor service running but no data in portal | → [Fix 3 — Re-register or reinstall sensor](#fix-3--re-register-or-reinstall-sensor) |
| Health alert: Sensor version outdated | → [Fix 4 — Force sensor update](#fix-4--force-sensor-update) |
| Event ID 2000/2001 in Application log | → [Fix 2 — Fix network/proxy connectivity](#fix-2--fix-networkproxy-connectivity) |
| Sensor healthy but no lateral movement alerts | → [Fix 5 — Enable required event collection](#fix-5--enable-required-event-collection) |
| Health alert: NTDS auditing not enabled | → [Fix 6 — Enable NTDS and security auditing](#fix-6--enable-ntds-and-security-auditing) |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
Microsoft Defender for Identity Cloud (*.atp.azure.com / *.sensorapi.atp.azure.com)
    │
    │   HTTPS/443 outbound from DC (or via proxy)
    │
MDI Sensor (AATPSensor service on each Domain Controller)
    │
    ├── .NET 4.7.2+ installed on DC
    ├── Windows Server 2012 R2 / 2016 / 2019 / 2022
    ├── 6 GB RAM minimum on DC (sensor uses ~4 GB)
    ├── 10% free CPU headroom
    │
    ├── Network Capture (WinPcap / Npcap)
    │       └── Captures network traffic from DC NIC
    │
    ├── Event Log Sources (must be audited)
    │       ├── Security Event Log (Event ID 4776, 4624, 4625, 4662, 4728, 4729, 4732...)
    │       ├── System Event Log
    │       └── NTDS auditing (for LDAP/AD object attribute changes)
    │
    └── AD Service Account (gMSA or standard svc account)
            ├── Requires: Read access to domain
            ├── Requires: Read SAM-R (lateral movement path detection)
            └── Optional: Read LAPS attributes for LAPS integration

Entra ID / M365 Tenant
    └── MDI workspace linked to Entra tenant (licensing: M365 E5, EMS E5, or Defender for Identity P2)
```

</details>

---

## Diagnosis & Validation Flow

**1. Confirm both sensor services are running**
```powershell
Get-Service -Name "AATPSensor","AATPSensorUpdater" -ComputerName <DC_NAME> |
    Select-Object Name, Status, StartType
```
Expected: Both Running, StartType = Automatic.
Bad: Stopped → proceed to Fix 1.

**2. Confirm outbound HTTPS to MDI cloud**
```powershell
Invoke-Command -ComputerName <DC_NAME> -ScriptBlock {
    $endpoints = @(
        "<WORKSPACE>.atp.azure.com",
        "<WORKSPACE>sensorapi.atp.azure.com"
    )
    foreach ($ep in $endpoints) {
        $result = Test-NetConnection $ep -Port 443
        [PSCustomObject]@{ Endpoint = $ep; TcpTestSucceeded = $result.TcpTestSucceeded }
    }
}
```
Expected: TcpTestSucceeded = True for all endpoints.
Bad: False → Fix 2.

**3. Check sensor health in Defender portal**
```
security.microsoft.com → Settings → Identities → Sensors
```
Expected: All sensors show Status = Running, Version = current.
Bad: Any sensor shows Warning/Error → check Health issues tab for specific alert.

**4. Confirm event log audit policy**
```powershell
Invoke-Command -ComputerName <DC_NAME> -ScriptBlock {
    auditpol /get /subcategory:"Logon","Account Logon","Directory Service Access","Directory Service Changes"
}
```
Expected: Success and Failure for Logon/Account Logon; Success for Directory Service events.
Bad: No Auditing → Fix 6.

**5. Confirm SAM-R access configured (for lateral movement)**
```powershell
# Check if MDI service account has rights to perform SAM-R queries
# In Group Policy: Network access: Restrict clients allowed to make remote calls to SAM
# Should include the MDI service account or gMSA
Invoke-Command -ComputerName <DC_NAME> -ScriptBlock {
    Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "RestrictRemoteSam" -ErrorAction SilentlyContinue
}
```
Expected: If key exists, value should include MDI service account (SID).

---

## Common Fix Paths

<details><summary>Fix 1 — Restart sensor service</summary>

```powershell
$dc = "<DC_NAME>"

# Restart both sensor services
Invoke-Command -ComputerName $dc -ScriptBlock {
    Restart-Service -Name "AATPSensor" -Force
    Start-Sleep -Seconds 10
    Restart-Service -Name "AATPSensorUpdater" -Force
    Get-Service -Name "AATPSensor","AATPSensorUpdater" | Select-Object Name, Status
}
```

**Check after:** Wait 2–3 minutes, then verify sensor appears online in the MDI portal.

**If service fails to start:** Check Windows Event Log → Application for AATPSensor errors. Common cause: insufficient memory on DC, or corrupted sensor installation (→ Fix 3).

**Rollback:** N/A — service restart is non-destructive.

</details>

<details><summary>Fix 2 — Fix network/proxy connectivity</summary>

```powershell
$dc = "<DC_NAME>"
$workspace = "<WORKSPACE_NAME>"  # From MDI portal → Workspace name

# 1. Test all required endpoints
Invoke-Command -ComputerName $dc -ScriptBlock {
    $endpoints = @(
        "$using:workspace.atp.azure.com",
        "${using:workspace}sensorapi.atp.azure.com",
        "dc.services.visualstudio.com",
        "www.microsoft.com/pkiops",
        "mscrl.microsoft.com",
        "crl.microsoft.com"
    )
    foreach ($ep in $endpoints) {
        $r = Test-NetConnection $ep -Port 443 -WarningAction SilentlyContinue
        [PSCustomObject]@{ Endpoint = $ep; OK = $r.TcpTestSucceeded }
    } | Format-Table
}

# 2. If proxy is in use — set sensor proxy
# On the DC, in an elevated cmd:
# netsh winhttp set proxy proxy-server="http://<PROXY>:<PORT>" bypass-list="<local>"

# 3. Or configure via MDI sensor config file:
# C:\Program Files\Azure Advanced Threat Protection Sensor\[version]\Sensor.Config
# Add: <ProxyUrl>http://proxy:port</ProxyUrl>
# Then restart AATPSensor service
```

**Firewall rules needed (outbound from DC):**
- `*.atp.azure.com` → 443/TCP
- `*.sensorapi.atp.azure.com` → 443/TCP
- `dc.services.visualstudio.com` → 443/TCP (telemetry — can be blocked if needed)

**Rollback:** Remove proxy setting from config file and restart sensor.

</details>

<details><summary>Fix 3 — Re-register or reinstall sensor</summary>

```powershell
# Step 1: Download current sensor installer from MDI portal
# security.microsoft.com → Settings → Identities → Sensors → Add sensor → Download installer

# Step 2: Copy installer to DC (use admin share)
# \\<DC_NAME>\C$\Temp\

# Step 3: Run reinstall (preserves existing config if same workspace key)
Invoke-Command -ComputerName "<DC_NAME>" -ScriptBlock {
    $installer = "C:\Temp\Azure ATP Sensor Setup.exe"
    $accessKey  = "<ACCESS_KEY_FROM_MDI_PORTAL>"
    Start-Process $installer -ArgumentList "/quiet","NetFrameworkCommandLineArguments=/q","AccessKey=$accessKey" -Wait
}

# Step 4: Verify services post-install
Get-Service -ComputerName "<DC_NAME>" -Name "AATPSensor","AATPSensorUpdater"
```

**Where to get the Access Key:**
MDI portal (security.microsoft.com) → Settings → Identities → Sensors → Add sensor.

**Rollback:** Uninstall via Programs and Features. Sensor removal does not affect AD or other DCs.

</details>

<details><summary>Fix 4 — Force sensor update</summary>

```powershell
$dc = "<DC_NAME>"

# Option A: Force update via updater service restart
Invoke-Command -ComputerName $dc -ScriptBlock {
    Restart-Service -Name "AATPSensorUpdater" -Force
    Start-Sleep -Seconds 30
    Get-Service -Name "AATPSensor" | Select-Object Name, Status
}

# Option B: Trigger update check from MDI portal
# security.microsoft.com → Settings → Identities → Sensors → [Sensor] → Update

# Option C: Manual update (download latest installer and run Fix 3 above)
```

**Note:** Sensor update restarts the AATPSensor service briefly (30–60 seconds). During update, no events are collected from that DC. Updates are normally automatic via AATPSensorUpdater.

</details>

<details><summary>Fix 5 — Enable required event collection</summary>

**Context:** MDI requires specific Windows events. If these aren't being logged, detection coverage is incomplete.

```powershell
# Required events: 4776, 4624, 4625, 4662, 4728, 4729, 4732, 4733, 4768, 4769, 4771, 4781, 8004

# Check current audit policy on DC
Invoke-Command -ComputerName "<DC_NAME>" -ScriptBlock {
    auditpol /get /category:* | Where-Object { $_ -match "Logon|Account|Directory|Policy" }
}

# Apply correct audit policy via Group Policy (preferred):
# Computer Configuration → Windows Settings → Security Settings → Advanced Audit Policy
# Account Logon → Credential Validation: Success + Failure
# Account Management → All subcategories: Success + Failure
# DS Access → Directory Service Access: Success
# DS Access → Directory Service Changes: Success
# Logon/Logoff → Logon: Success + Failure

# Quick-apply via auditpol on a single DC (test only — use GPO for production)
Invoke-Command -ComputerName "<DC_NAME>" -ScriptBlock {
    auditpol /set /subcategory:"Credential Validation" /success:enable /failure:enable
    auditpol /set /subcategory:"Logon" /success:enable /failure:enable
    auditpol /set /subcategory:"Directory Service Changes" /success:enable
    auditpol /set /subcategory:"Directory Service Access" /success:enable
}
```

**Rollback:** Reverse auditpol commands with `/success:disable /failure:disable`.

</details>

<details><summary>Fix 6 — Enable NTDS and security auditing</summary>

**Context:** LDAP-based attacks and AD object access require NTDS auditing.

```powershell
# Step 1: Enable auditing on the NTDS object via ADSI Edit
# ADSI Edit → Default Naming Context → Properties → Security → Advanced → Auditing
# Add: Everyone → Successful → Write All Properties, Delete, Create All Child Objects, Delete All Child Objects

# Step 2: Or use PowerShell to set SACL on domain root
$rootDN = (Get-ADDomain).DistinguishedName
$acl = Get-Acl "AD:$rootDN"
$auditRule = New-Object System.DirectoryServices.ActiveDirectoryAuditRule(
    [System.Security.Principal.NTAccount]"Everyone",
    [System.DirectoryServices.ActiveDirectoryRights]"WriteProperty,DeleteTree,CreateChild,DeleteChild",
    [System.Security.AccessControl.AuditFlags]"Success",
    [System.DirectoryServices.ActiveDirectorySecurityInheritance]"All"
)
$acl.AddAuditRule($auditRule)
Set-Acl "AD:$rootDN" $acl
Write-Host "NTDS auditing SACL applied"

# Step 3: Verify in Event Viewer → Security log on a DC after making an AD change
# Event ID 4662 should appear
```

**Rollback:** Remove the audit rule from the SACL via ADSI Edit or reverse the PowerShell above.

</details>

---

## Escalation Evidence

```
=== MDI ESCALATION — SENSOR HEALTH ISSUE ===

Date/Time:          [TIMESTAMP]
Reporter:           [YOUR NAME / TICKET ID]
Tenant:             [TENANT_NAME.onmicrosoft.com]
MDI Workspace:      [WORKSPACE_NAME]
Affected DC(s):     [DC1, DC2, ...]
Sensor Version:     [FROM PORTAL]
Current Status:     [RUNNING / STOPPED / WARNING]

--- Connectivity Test Output ---
[PASTE: Test-NetConnection results for *.atp.azure.com]

--- Sensor Service Status ---
[PASTE: Get-Service AATPSensor,AATPSensorUpdater output]

--- Recent Sensor Errors (App Event Log) ---
[PASTE: Last 5 errors from Application log, source AATPSensor]

--- Health Alerts in Portal ---
[LIST: Health alerts shown in security.microsoft.com → Settings → Identities → Sensors]

--- Fixes Attempted ---
[LIST each fix tried and result]

--- Escalation Request ---
[ ] Microsoft Support case required
[ ] Defender for Identity engineering escalation
Support contact: https://admin.microsoft.com → New service request
```

---

## 🎓 Learning Pointers

- **MDI is sensor-per-DC, not tenant-wide agent.** Every Domain Controller in scope must have its own sensor. Missing a DC = blind spot for attacks transiting that DC. Prioritise RODCs and DCs in branch offices that are often skipped. [Sensor planning](https://learn.microsoft.com/en-us/defender-for-identity/capacity-planning)

- **MDI detects lateral movement, not endpoint compromise.** It watches Kerberos, NTLM, LDAP, and SAM-R traffic from DCs. It won't see an initial phish or endpoint exploit — that's MDE's job. The two work together in the Defender portal. [MDI + MDE integration](https://learn.microsoft.com/en-us/defender-for-identity/mde-integration)

- **The gMSA service account is strongly recommended** over a standard service account. It self-rotates its password, eliminating a common misconfiguration where an expired password silently stops the sensor. [gMSA setup for MDI](https://learn.microsoft.com/en-us/defender-for-identity/directory-service-accounts)

- **Health issues have SLA impact.** MDI health alerts (sensor not communicating, no events received) mean detection gaps. Treat a DC sensor in Warning/Error state as a P2 incident — attacks can transit undetected during the gap. [Health monitoring](https://learn.microsoft.com/en-us/defender-for-identity/health-alerts)

- **SAM-R restriction = lateral movement blind spot.** Windows hardening guides often recommend restricting SAM-R access. If the MDI service account is not in the SAM-R allowed list, lateral movement path detection is completely disabled. [SAM-R configuration](https://learn.microsoft.com/en-us/defender-for-identity/remote-calls-sam)
