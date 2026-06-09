# Microsoft Defender for Identity — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How It Works](#how-it-works)
- [Dependency Stack](#dependency-stack)
- [Symptom → Cause Map](#symptom--cause-map)
- [Validation Steps](#validation-steps)
- [Troubleshooting Steps by Phase](#troubleshooting-steps-by-phase)
- [Remediation Playbooks](#remediation-playbooks)
- [Evidence Pack](#evidence-pack)
- [Command Cheat Sheet](#command-cheat-sheet)
- [🎓 Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

- **What this covers:** MDI sensor deployment on Domain Controllers and AD FS servers, health monitoring, alert investigation, identity-based threat detection, integration with Microsoft Defender XDR.
- **What this does NOT cover:** Microsoft Defender for Cloud Apps (MDCA) policy engine; Microsoft Entra ID Protection risk policies; Sentinel integration configuration.
- **Assumed knowledge:** Active Directory architecture (DC roles, LDAP, Kerberos, NTLM); PowerShell remoting; basic network concepts (ports, DNS resolution).
- **Minimum requirements:** MDI sensor requires .NET Framework 4.7+, minimum 6 GB RAM free on DC, Windows Server 2012 R2 or later.

---

## How It Works

<details><summary>Full architecture</summary>

### Sensor Architecture

MDI works via a **lightweight sensor** installed on every Domain Controller (and optionally AD FS, AD CS servers). The sensor operates inline with Active Directory traffic — it is NOT a SPAN/mirror-port solution.

```
┌─────────────────────────────────────────────────────────────────┐
│                     ACTIVE DIRECTORY DOMAIN                     │
│                                                                 │
│   ┌──────────────┐    ┌──────────────┐    ┌──────────────┐     │
│   │     DC-01    │    │     DC-02    │    │    ADFS-01   │     │
│   │              │    │              │    │              │     │
│   │ MDI Sensor   │    │ MDI Sensor   │    │ MDI Sensor   │     │
│   │  (local)     │    │  (local)     │    │  (optional)  │     │
│   └──────┬───────┘    └──────┬───────┘    └──────┬───────┘     │
│          │                  │                   │              │
└──────────┼──────────────────┼───────────────────┼──────────────┘
           │                  │                   │
           └──────────────────┴───────────────────┘
                              │
                    HTTPS (443) outbound
                              │
                    ┌─────────▼──────────┐
                    │  MDI Cloud Service  │
                    │  (*.atp.azure.com)  │
                    │                    │
                    │  - Alert engine     │
                    │  - ML models        │
                    │  - Entity profiling │
                    └─────────┬──────────┘
                              │
                    ┌─────────▼──────────┐
                    │  Defender XDR      │
                    │  (security.microsoft│
                    │   .com)            │
                    └────────────────────┘
```

### What the Sensor Captures

| Traffic Type | How Captured | Why |
|---|---|---|
| LDAP queries | ETW (Event Tracing for Windows) | Enumerate AD, LDAP recon detection |
| Kerberos | Network packet parsing (NDIS) | Golden Ticket, Pass-the-Ticket, AS-REP roasting |
| NTLM | Network packet parsing + ETW | Pass-the-Hash, NTLM relay detection |
| SAM-R | Windows API hooking | Lateral movement via remote SAM enumeration |
| DNS | ETW | DNS reconnaissance detection |
| Windows Events | Event log subscription | 4624/4625/4768/4769/4776/7045 etc. |

### Entity Profiling (Behavioral Baseline)

MDI builds a **30-day rolling baseline** for:
- User login hours, devices, locations
- Service account usage patterns
- Resource access patterns

Alerts are generated when observed behaviour deviates significantly from the baseline. This means **new deployments have a 30-day learning period** during which alert fidelity is lower.

### Sensor vs. Stand-alone Sensor

| Type | Use Case | Network Requirement |
|---|---|---|
| **Sensor** (default) | Installed on DC — captures traffic locally | Outbound HTTPS 443 only |
| **Stand-alone Sensor** | Installed on dedicated server, receives SPAN/mirror port | Requires SPAN port config on switch |

Stand-alone sensors are legacy and not recommended for new deployments.

</details>

---

## Dependency Stack

```
Defender XDR Portal (security.microsoft.com)
        │
MDI Cloud Service (*.atp.azure.com)
        │  HTTPS 443 outbound
        │
MDI Sensor (on each DC / ADFS)
        │
        ├── Requires: .NET Framework 4.7.2+
        ├── Requires: Windows Server 2012 R2+
        ├── Requires: Local Admin rights for installation
        ├── Requires: Directory Service Account (DSA) with Read rights in AD
        │           └── OR Group Managed Service Account (gMSA) [preferred]
        │
Domain Controller
        │
        ├── Windows Event Log (Security, System, Directory Service)
        ├── ETW providers (Kerberos, LDAP, DNS, NTLM)
        └── Network stack (NDIS packet capture)
```

**Directory Service Account (DSA) permissions required:**
- Read access to all objects in the domain
- For AD FS: Read service account properties
- For AD CS (optional): Read Certificate Authority objects

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Sensor shows "Not Running" in portal | Service stopped, DSA password expired, .NET issue | `Get-Service AATPSensor` on DC; check DSA account |
| "Sensor version outdated" warning | Auto-update blocked (proxy, firewall, WSUS) | Check outbound 443 to `*.atp.azure.com` |
| No events in portal after install | DSA lacks AD read permissions | Test DSA: `Get-ADUser -Filter * -Credential <DSA>` |
| High CPU/memory on DC after install | Sensor processing overload (common on DCs with high auth volume) | Check sensor config — reduce capture threads |
| "Delayed sync" sensor health | DNS not resolving MDI endpoint, proxy issues | `Resolve-DnsName <workspace>.atp.azure.com` |
| Duplicate alerts for same entity | Multiple sensors reporting same event (misconfigured domain naming) | Check sensor domain controller mapping |
| Alerts missing for known attack | Event audit not configured, event forwarding not working | Verify Event ID collection via `auditpol /get /category:*` |
| gMSA sensor cannot authenticate | gMSA not added to "Log on as a service" or password sync issue | Check gMSA: `Test-ADServiceAccount -Identity <gMSA>` |

---

## Validation Steps

### 1. Confirm Sensor Service Status
```powershell
# Run on each DC
Get-Service -Name AATPSensor | Select-Object Name, Status, StartType
Get-Service -Name AATPSensorUpdater | Select-Object Name, Status, StartType
```
**Expected:** Both `Running`. If `Stopped` — check Windows Event Log Application/System for AATPSensor errors.

### 2. Confirm Sensor Version
```powershell
$reg = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Azure Advanced Threat Protection\Sensor"
$reg.Version
```
**Expected:** Should match current version in MDI portal (Sensor Settings → Sensors). Portal auto-pushes updates — if stuck, check outbound connectivity.

### 3. Test Outbound Connectivity
```powershell
# Replace <workspace> with your MDI workspace name (found in portal)
Test-NetConnection -ComputerName "<workspace>sensorapi.atp.azure.com" -Port 443
Test-NetConnection -ComputerName "triprd1wcus2sensorapi.atp.azure.com" -Port 443
```
**Expected:** `TcpTestSucceeded: True`. If False — firewall/proxy blocking outbound 443.

### 4. Validate DSA/gMSA Account
```powershell
# If using DSA (regular account):
$cred = Get-Credential   # Enter DSA account credentials
Get-ADDomain -Credential $cred -Server <DC_FQDN>

# If using gMSA:
Test-ADServiceAccount -Identity "<gMSA_sAMAccountName>"
```
**Expected:** DSA can query domain; gMSA returns `True`.

### 5. Confirm Audit Policy
```powershell
# Run on DC — check critical audit categories
auditpol /get /category:"Account Logon","Account Management","DS Access","Logon/Logoff"
```
**Expected:** Account Logon, Account Management, DS Access — `Success and Failure`. Missing audit = missed detections.

### 6. Check Sensor Health in Portal
```powershell
# Via Graph / Defender API — or check in portal:
# security.microsoft.com → Settings → Identities → Sensors
# Each sensor should show: Running, Up-to-date, No health issues
```

### 7. Verify Event Log Collection
```powershell
# Check recent security events are being generated
Get-WinEvent -LogName Security -MaxEvents 20 | 
    Where-Object { $_.Id -in @(4624,4625,4768,4769,4776) } |
    Select-Object TimeCreated, Id, Message
```
**Expected:** Recent events present. If no events — audit policy not configured.

---

## Troubleshooting Steps by Phase

### Phase 1: Installation Issues

**Problem: Installer fails silently**
```powershell
# Check installation log
$logPath = "C:\ProgramData\Microsoft\Azure Advanced Threat Protection\Sensor\Logs"
Get-ChildItem $logPath | Sort-Object LastWriteTime -Descending | Select-Object -First 5
Get-Content "$logPath\Microsoft.Tri.Sensor-Errors.log" -Tail 50
```

**Problem: "Workspace already exists" or tenant mismatch**
- Verify you are using the correct MDI workspace URL from the MDI portal
- Check the sensor package was downloaded from the correct MDI instance (Settings → Sensor → Download)

---

### Phase 2: Connectivity Issues

**Problem: Sensor installed but "Disconnected" in portal**
```powershell
# Step 1: Test all required MDI endpoints
$endpoints = @(
    "<workspace>.atp.azure.com",
    "<workspace>sensorapi.atp.azure.com",
    "crl.microsoft.com",
    "mscrl.microsoft.com"
)
foreach ($ep in $endpoints) {
    $result = Test-NetConnection -ComputerName $ep -Port 443 -WarningAction SilentlyContinue
    Write-Host "$ep : $($result.TcpTestSucceeded)"
}

# Step 2: Check proxy configuration
netsh winhttp show proxy

# Step 3: Check sensor proxy config in registry
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Azure Advanced Threat Protection\Sensor" -Name ProxyServer -ErrorAction SilentlyContinue
```

**Configure proxy for MDI sensor:**
```powershell
# Set proxy via sensor config tool (not registry directly)
# Run as admin on DC:
$sensorInstallPath = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Azure Advanced Threat Protection\Sensor").InstallationPath
& "$sensorInstallPath\Microsoft.Tri.Sensor.Deployment.Configurator.exe" --ProxyUrl "http://<proxy>:<port>"
Restart-Service AATPSensor
```

---

### Phase 3: DSA / Permission Issues

**Problem: "Directory services account error" in portal**
```powershell
# Verify DSA account exists and is not locked/expired
Get-ADUser -Identity "<DSA_sAMAccountName>" -Properties PasswordLastSet, PasswordNeverExpires, LockedOut, Enabled |
    Select-Object SamAccountName, Enabled, LockedOut, PasswordLastSet, PasswordNeverExpires

# Test DSA can read domain objects
$dsaCred = Get-Credential  # Enter DSA credentials
Get-ADObject -Filter { ObjectClass -eq "organizationalUnit" } -Credential $dsaCred | Select-Object -First 5
```

**Migrate from DSA to gMSA (recommended):**
```powershell
# Step 1: Create gMSA (run on DC with AD module)
New-ADServiceAccount -Name "MDI-gMSA" `
    -DNSHostName "MDI-gMSA.$((Get-ADDomain).DNSRoot)" `
    -PrincipalsAllowedToRetrieveManagedPassword "Domain Controllers" `
    -KerberosEncryptionType AES128,AES256

# Step 2: Install gMSA on each DC
Install-ADServiceAccount -Identity "MDI-gMSA"

# Step 3: Test gMSA
Test-ADServiceAccount -Identity "MDI-gMSA"

# Step 4: Update MDI sensor to use gMSA
# In MDI portal: Settings → Directory Service Accounts → Add gMSA
# Then re-run sensor configuration on each DC
```

---

### Phase 4: Sensor Performance Issues

**Problem: High CPU/memory on DC after sensor install**
```powershell
# Check sensor resource usage
Get-Process -Name "Microsoft.Tri.Sensor" | Select-Object CPU, WorkingSet, Id

# Check sensor config for max CPU/network capture settings
$configPath = "C:\ProgramData\Microsoft\Azure Advanced Threat Protection\Sensor\Configuration"
Get-Content "$configPath\*.json" -ErrorAction SilentlyContinue | Select-String -Pattern "MaxCpuPercentage|NetworkAdapterName"
```

- In MDI portal: Settings → Sensors → select DC → Advanced → set **Max CPU** limit (default: none — set to 85% to protect DC)
- Consider excluding high-volume service accounts from monitoring if causing sensor overload

---

### Phase 5: Alert Investigation

**Investigating a suspicious alert:**
```powershell
# Get authentication events for a suspected account
$username = "<SuspectUser>"
$startTime = (Get-Date).AddHours(-4)

Get-WinEvent -FilterHashtable @{
    LogName   = 'Security'
    Id        = @(4624, 4625, 4768, 4769, 4776)
    StartTime = $startTime
} | Where-Object {
    $_.Message -match $username
} | Select-Object TimeCreated, Id, @{N="Details"; E={$_.Message}} |
Format-Table -AutoSize -Wrap
```

---

## Remediation Playbooks

<details><summary>Playbook 1 — Sensor not running after Windows Update</summary>

**Cause:** .NET Framework update or OS patch broke sensor service dependency.

```powershell
# Step 1: Check service and dependencies
Get-Service AATPSensor | Select-Object Status, StartType
Get-EventLog -LogName Application -Source "AATPSensor*" -Newest 20 |
    Select-Object TimeGenerated, EntryType, Message

# Step 2: Attempt service restart
Restart-Service AATPSensor -Force

# Step 3: If restart fails — repair .NET
# Check .NET version
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP" -Recurse |
    Get-ItemProperty -Name Version,Release -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match "^(?!S)\p{L}" } |
    Select-Object PSChildName, Version

# Step 4: If .NET 4.7.2+ is missing — install from:
# https://dotnet.microsoft.com/download/dotnet-framework/net472

# Step 5: Re-register sensor
$sensorPath = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Azure Advanced Threat Protection\Sensor").InstallationPath
& "$sensorPath\Microsoft.Tri.Sensor.Deployment.Configurator.exe" --reinstall
Restart-Service AATPSensor
```

**Rollback:** No destructive steps — sensor restart is safe. Re-installation preserves existing configuration.

</details>

<details><summary>Playbook 2 — False positive alerts — suppressing known benign behaviour</summary>

**Scenario:** MDI alerting on legitimate admin tools (e.g., scheduled password audit scripts, IT admin lateral movement for maintenance).

```powershell
# Identify the source account/IP generating alerts
# In MDI portal: Alerts → select alert → Tune this alert
# Options:
#   - Suppress for specific user/computer
#   - Close as True/False positive
#   - Create suppression rule

# For documented exceptions — add to MDI Exclusions:
# Settings → Identities → Exclusions
# Exclude by: User UPN, Computer name, IP address, or Subnet

# Document the exclusion in your change record:
$exclusionLog = @{
    Date      = (Get-Date -Format "yyyy-MM-dd")
    AlertType = "<AlertType>"
    Excluded  = "<UserOrComputer>"
    Reason    = "<BusinessJustification>"
    ApprovedBy = "<ApproverName>"
}
$exclusionLog | ConvertTo-Json | Out-File "C:\Temp\MDI_Exclusion_$(Get-Date -Format yyyyMMdd).json"
```

**Rollback:** Remove exclusion from MDI portal at any time — alerting resumes immediately.

</details>

<details><summary>Playbook 3 — Sensor update stuck on old version</summary>

**Cause:** Updater service cannot reach MDI update endpoint (proxy, firewall, WSUS interference).

```powershell
# Step 1: Check updater service
Get-Service AATPSensorUpdater | Select-Object Status

# Step 2: Check updater log
$logPath = "C:\ProgramData\Microsoft\Azure Advanced Threat Protection\Sensor\Logs"
Get-Content "$logPath\Microsoft.Tri.SensorUpdater-Errors.log" -Tail 30

# Step 3: Manually trigger update check
Restart-Service AATPSensorUpdater

# Step 4: If auto-update consistently fails — manually update
# Download latest sensor installer from MDI portal: Settings → Sensors → Download
# Run installer on DC (it upgrades in-place — no data loss)
# msiexec /i "Azure ATP Sensor Setup.exe" /quiet NetFrameworkCommandLineArguments="/q"

# Step 5: Verify updated version
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Azure Advanced Threat Protection\Sensor").Version
```

**Rollback:** Previous sensor version packages not retained — rollback not recommended unless instructed by Microsoft support.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  MDI sensor evidence collection for escalation
.NOTES     Run as local Administrator on the affected DC
#>

$outputDir = "C:\Temp\MDI_Evidence_$(Get-Date -Format yyyyMMdd_HHmm)"
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

# Sensor service status
Get-Service AATPSensor, AATPSensorUpdater |
    Select-Object Name, Status, StartType |
    Export-Csv "$outputDir\sensor_services.csv" -NoTypeInformation

# Sensor registry info
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Azure Advanced Threat Protection\Sensor" |
    Select-Object * |
    ConvertTo-Json |
    Out-File "$outputDir\sensor_registry.json"

# Sensor version
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Azure Advanced Threat Protection\Sensor").Version |
    Out-File "$outputDir\sensor_version.txt"

# Outbound connectivity test
$endpoints = @(
    "triprd1wcus2sensorapi.atp.azure.com",
    "crl.microsoft.com"
)
$connectResults = foreach ($ep in $endpoints) {
    $r = Test-NetConnection -ComputerName $ep -Port 443 -WarningAction SilentlyContinue
    [PSCustomObject]@{ Endpoint = $ep; Success = $r.TcpTestSucceeded }
}
$connectResults | Export-Csv "$outputDir\connectivity.csv" -NoTypeInformation

# DSA account check (if using regular DSA)
$dsaSAM = Read-Host "Enter DSA sAMAccountName (or press Enter to skip)"
if ($dsaSAM) {
    Get-ADUser -Identity $dsaSAM -Properties * |
        Select-Object SamAccountName, Enabled, LockedOut, PasswordExpired, PasswordLastSet, PasswordNeverExpires |
        Export-Csv "$outputDir\dsa_account.csv" -NoTypeInformation
}

# Audit policy
auditpol /get /category:* | Out-File "$outputDir\auditpol.txt"

# Recent sensor errors from event log
Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = '*AATP*' } -MaxEvents 50 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, LevelDisplayName, Message |
    Export-Csv "$outputDir\sensor_events.csv" -NoTypeInformation

# System info
Get-ComputerInfo | Select-Object CsDNSHostName, OsName, OsVersion, CsProcessors, CsTotalPhysicalMemory |
    ConvertTo-Json | Out-File "$outputDir\system_info.json"

# Copy last 500 lines of sensor error log
$logPath = "C:\ProgramData\Microsoft\Azure Advanced Threat Protection\Sensor\Logs\Microsoft.Tri.Sensor-Errors.log"
if (Test-Path $logPath) {
    Get-Content $logPath -Tail 500 | Out-File "$outputDir\sensor_error_log.txt"
}

# Zip everything
Compress-Archive -Path "$outputDir\*" -DestinationPath "$outputDir.zip" -Force
Write-Host "[OK] Evidence pack: $outputDir.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# Check sensor service status
Get-Service AATPSensor, AATPSensorUpdater | Select-Object Name, Status

# Restart sensor
Restart-Service AATPSensor

# Check sensor version
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Azure Advanced Threat Protection\Sensor").Version

# Test connectivity to MDI cloud
Test-NetConnection -ComputerName "triprd1wcus2sensorapi.atp.azure.com" -Port 443

# Check audit policy
auditpol /get /category:"Account Logon","Account Management"

# View sensor error log
Get-Content "C:\ProgramData\Microsoft\Azure Advanced Threat Protection\Sensor\Logs\Microsoft.Tri.Sensor-Errors.log" -Tail 50

# Validate gMSA
Test-ADServiceAccount -Identity "<gMSA_Name>"

# Check DSA account status
Get-ADUser -Identity "<DSA_SAM>" -Properties Enabled, LockedOut, PasswordExpired | Select-Object *

# Find recent Kerberos auth events
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=@(4768,4769); StartTime=(Get-Date).AddHours(-1)} | Select-Object TimeCreated, Id

# Find recent NTLM auth events
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4776; StartTime=(Get-Date).AddHours(-1)} | Select-Object TimeCreated, Id

# Check .NET version
Get-ChildItem "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" | Get-ItemProperty -Name Release

# Export sensor configuration
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Azure Advanced Threat Protection\Sensor" | ConvertTo-Json

# Check proxy config
netsh winhttp show proxy
```

---

## 🎓 Learning Pointers

- **MDI detects lateral movement, not just perimeter attacks.** Unlike network firewalls, MDI sees inside the domain — Pass-the-Hash, Pass-the-Ticket, and Golden Ticket attacks become visible because the sensor captures Kerberos and NTLM traffic inline on the DC. Understand these attack techniques via [MITRE ATT&CK - Defense Evasion](https://attack.mitre.org/tactics/TA0005/).

- **The 30-day baseline matters.** New MDI deployments generate noisier alerts for the first month as the ML models profile entities. Schedule a post-deployment review at day 30 to tune exclusions. Microsoft documentation: [MDI entity profiles](https://learn.microsoft.com/en-us/defender-for-identity/entity-profiles).

- **gMSA is strongly preferred over DSA.** A regular service account requires manual password rotation (failure to rotate = sensor goes offline). A gMSA rotates automatically every 30 days without any sensor restart. See [Configure gMSA for MDI](https://learn.microsoft.com/en-us/defender-for-identity/manage-sensitive-honeytoken-accounts).

- **Audit policy gaps = missed detections.** MDI relies on Windows Security Event Log. Without `Account Logon: Success and Failure`, Kerberos events (4768/4769) will not be generated. Enforce audit policy via GPO and validate with `auditpol /get`. Reference: [MDI required audit policies](https://learn.microsoft.com/en-us/defender-for-identity/configure-windows-event-collection).

- **MDI integrates natively with Defender XDR.** Alerts from MDI appear in the unified Defender XDR incident queue and correlate with MDE, MDCA, and Entra ID Protection signals. Use the attack story view in `security.microsoft.com` to see the full kill chain rather than investigating MDI alerts in isolation.

- **Honeytoken accounts are a low-effort, high-value detection tool.** Create 1-2 AD accounts that should never be used but are tagged in MDI as Honeytoken accounts. Any authentication attempt against them triggers an immediate high-severity alert — excellent early-warning for credential stuffing or lateral movement. See [Configure honeytoken accounts](https://learn.microsoft.com/en-us/defender-for-identity/manage-sensitive-honeytoken-accounts).
