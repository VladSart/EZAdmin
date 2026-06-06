# Entra Hybrid Join (HAADJ) — Reference Runbook (Mode A: Deep Dive)
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
- Hybrid Azure AD Join (HAADJ) — devices domain-joined to on-premises AD that also register with Entra ID
- Managed domains (Password Hash Sync / Pass-Through Auth) and Federated domains (AD FS / third-party IDP)
- Windows 10/11 devices; Server SKUs excluded from Hybrid Join scope

**What this does NOT cover:**
- Pure Entra Join (cloud-only)
- Entra Registered (personal/BYOD)
- macOS or iOS/Android hybrid scenarios

**Assumptions:**
- Entra Connect (Azure AD Connect) is deployed and syncing the on-prem OU containing the device computer objects
- The tenant is licensed for at least Entra ID Free (no license required for HAADJ itself)
- Device is domain-joined (on-prem AD) with line-of-sight to a domain controller at the time of join

---

## How It Works

<details><summary>Full HAADJ architecture — expand to read</summary>

### The two-phase registration model

HAADJ requires two things to both be true:
1. **Computer object in on-prem AD** — the device must be domain-joined
2. **Device object in Entra ID** — Entra Connect syncs the computer object upward, and the device then self-registers a certificate

### Phase 1 — Entra Connect syncs the computer object

Entra Connect reads the on-prem AD `computer` object and writes a stub device object into Entra ID.  
Key attributes copied:
- `objectGUID` (becomes the Entra `deviceId`)
- `userCertificate` (populated by the device during Phase 2; Entra Connect syncs it up)
- `dNSHostName`, `operatingSystem`, `operatingSystemVersion`

The device object in Entra appears with state **Pending** until Phase 2 completes.

### Phase 2 — Device self-registers (the DRS registration)

The device runs the **Automatic Device Registration** scheduled task. This task:
1. Calls the **Device Registration Service (DRS)** endpoint to discover the tenant's STS
2. Uses the machine Kerberos ticket (krbtgt) to prove identity to on-prem AD FS or the Entra STS
3. Receives a device certificate from Entra's DRS
4. Writes the certificate's thumbprint into the on-prem computer object's `userCertificate` attribute
5. Entra Connect picks up that attribute change and syncs it — the Entra device object transitions from **Pending** → **Registered**

### Discovery mechanism (how the device finds DRS)

The device looks up the DRS endpoint via:
- **SCP (Service Connection Point)** in on-prem AD: `CN=62a0ff2e-97b9-4513-943f-0d221bd30080,CN=Device Registration Configuration,CN=Services,CN=Configuration,DC=...`
- The SCP stores the `azureADId` (tenant ID) and `azureADName` (verified domain)
- Alternatively, for Windows 10 1709+ in managed domains, DNS-based discovery can resolve `enterpriseregistration.<domain>` → CNAME → `enterpriseregistration.windows.net`

### Certificate chain

```
Entra DRS Root CA
  └─ Entra DRS Issuing CA
       └─ Device Certificate (stored in device's Local Machine\My cert store)
            Subject: CN=<DeviceId>
            EKU: Client Authentication
            Validity: 90 days (auto-renewed)
```

The PRT (Primary Refresh Token) is issued after successful device registration and is used for SSO to cloud resources. PRT issues are covered in `PRT-Issues-B.md`.

### Entra Connect sync timing

- Default sync cycle: 30 minutes
- `userCertificate` is a delta change — picked up on next delta sync
- If Entra Connect is in **staging mode**, it will NOT write changes → devices stay Pending forever

### Managed vs. Federated domain differences

| | Managed Domain (PHS/PTA) | Federated Domain (ADFS) |
|---|---|---|
| DRS discovery | SCP → `login.microsoftonline.com` | SCP → ADFS endpoint |
| Authentication proof | Windows Integrated Auth via Kerberos to Entra | WS-Trust 2005/2013 to ADFS, then Entra |
| Certificate issuance | Direct from Entra DRS | Via ADFS proxy → Entra DRS |
| Common extra failure point | Proxy blocking `login.microsoftonline.com` | ADFS MEX endpoint misconfigured |

</details>

---

## Dependency Stack

```
[ Entra ID Device Object — Registered ]
           ▲
           │  userCertificate synced
[ Entra Connect Delta Sync ]
           ▲
           │  writes userCertificate attribute
[ Device Registration Scheduled Task ]
           ▲
           │  DRS endpoint reachable
[ Network: HTTPS to login.microsoftonline.com / ADFS ]
           ▲
           │  Kerberos ticket obtainable
[ Domain Controller reachable / on-prem AD ]
           ▲
           │  device domain-joined
[ On-prem Computer Object in synced OU ]
           ▲
           │  Entra Connect syncs the OU
[ Entra Connect — Active (not staging) ]
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| `AzureAdJoined : NO` + `WorkplaceJoined : NO` | Device not yet registered, or registration failed silently | Scheduled task last run time; event log 104/106 |
| `AzureAdJoined : YES` but device shows **Pending** in Entra portal | `userCertificate` not synced by Entra Connect | Entra Connect delta sync; staging mode |
| `dsregcmd /status` shows `AzureAdJoined : YES` but SSO to O365 fails | PRT not issued or expired | `dsregcmd /status` → `AzureAdPrt` field |
| Device registered but wrong tenant | Multiple tenants / SCP pointing at wrong tenant | SCP `azureADId` attribute value |
| Error `0x801c03f2` in event log | Device object not found on Entra side | Delete stale Entra device object; force re-reg |
| Error `0x801c001d` | DRS endpoint unreachable | Proxy/firewall; DNS resolution of `login.microsoftonline.com` |
| Error `0xCAA20003` | Certificate store issue | Run `certutil -store My` on device |
| Registration works on some DCs but not others | SCP not replicated or missing on some DCs | Check SCP on each DC in the affected site |
| New devices register but old ones remain Pending | Entra Connect not syncing `userCertificate` | Check attribute filter / connector rules in Entra Connect |
| Device removed from Entra, now stuck Pending again | `userCertificate` is stale in on-prem AD | Clear `userCertificate` on computer object; force re-reg |

---

## Validation Steps

### Step 1 — Confirm on-prem domain join
```powershell
(Get-WmiObject Win32_ComputerSystem).PartOfDomain
# Expected: True

nltest /dsgetdc:<domain.local>
# Expected: \\<DomainController> with no "ERROR" string
```
**Bad output:** `False` / `ERROR_NO_SUCH_DOMAIN` → device not domain-joined or no DC reachable. Fix domain join first.

---

### Step 2 — Check dsregcmd full output
```powershell
dsregcmd /status
```
**Good registration:**
```
+----------------------------------------------------------------------+
| Device State                                                         |
+----------------------------------------------------------------------+
         AzureAdJoined : YES
    EnterpriseJoined : NO
        DomainJoined : YES

+----------------------------------------------------------------------+
| SSO State                                                            |
+----------------------------------------------------------------------+
    AzureAdPrt : YES
```
**Bad:** `AzureAdJoined : NO` or `AzureAdPrt : NO` — note the exact `UserState` error code if present.

---

### Step 3 — Check SCP in AD
```powershell
$scp = [ADSI]"LDAP://CN=62a0ff2e-97b9-4513-943f-0d221bd30080,CN=Device Registration Configuration,CN=Services,CN=Configuration,DC=<domain>,DC=<tld>"
$scp.Properties["keywords"]
# Expected output includes:
#   azureADName:<yourverifieddomain.com>
#   azureADId:<your-tenant-id>
```
**Bad:** Object not found → SCP missing. See Fix 1.

---

### Step 4 — Check Entra Connect sync scope
```powershell
# Run on Entra Connect server
Import-Module ADSync
Get-ADSyncConnector | Select Name, State
# Expected: State = Running (not Staging or Disabled)

Get-ADSyncScheduler
# Expected: SyncCycleEnabled = True, NextSyncCyclePolicyType = Delta
```
**Bad:** `SyncCycleEnabled = False` or server in staging mode → sync not running.

---

### Step 5 — Check computer object has correct OU and userCertificate
```powershell
# Run on any domain controller or machine with RSAT AD Tools
$comp = Get-ADComputer <DeviceName> -Properties userCertificate, DistinguishedName
$comp.DistinguishedName  # should be in an OU synced by Entra Connect
($comp.userCertificate).Count  # 0 = not yet registered; >0 = has cert
```
**Bad:** `userCertificate` count is 0 after attempted registration → scheduled task hasn't completed or is failing.

---

### Step 6 — Check Device Registration scheduled task on device
```powershell
Get-ScheduledTask -TaskPath "\Microsoft\Windows\Workplace Join\" -TaskName "Automatic-Device-Join" | 
    Select TaskName, State, @{n='LastRunTime';e={$_.LastRunInfo.LastRunTime}}, @{n='LastResult';e={$_.LastRunInfo.LastTaskResult}}
# Expected: LastResult = 0 (success) or recently run
```
**Bad:** `LastResult = 0x801c...` → registration error code. Cross-reference with Symptom→Cause table above.

---

### Step 7 — Confirm device in Entra portal
```powershell
# Via Microsoft Graph (run from any authenticated session)
Connect-MgGraph -Scopes "Device.Read.All"
Get-MgDevice -Filter "displayName eq '<DeviceName>'" | Select DisplayName, TrustType, ApproximateLastSignInDateTime, ProfileType
# Expected: TrustType = ServerAd (= Hybrid); ProfileType = RegisteredDevice
```
**Bad:** No result → device not in Entra. Result with `TrustType = AzureAd` → device was Entra-joined, not hybrid.

---

## Troubleshooting Steps (by phase)

### Phase A — Pre-registration (before the task even runs)

1. Confirm the computer object is in an OU synced by Entra Connect
   - Log into Entra Connect server → Synchronization Service Manager → check connector scope rules
2. Confirm SCP exists and points to the correct tenant (Step 3 above)
3. Confirm the device can reach DRS endpoints:
   ```powershell
   Test-NetConnection -ComputerName "enterpriseregistration.windows.net" -Port 443
   Test-NetConnection -ComputerName "login.microsoftonline.com" -Port 443
   Test-NetConnection -ComputerName "device.login.microsoftonline.com" -Port 443
   ```
4. For federated domains, also check ADFS proxy:
   ```powershell
   Test-NetConnection -ComputerName "<adfs.domain.com>" -Port 443
   Invoke-WebRequest "https://<adfs.domain.com>/adfs/services/trust/mex" -UseDefaultCredentials
   ```

### Phase B — Registration task running but failing

1. Check event log on the device:
   ```powershell
   Get-WinEvent -LogName "Microsoft-Windows-User Device Registration/Admin" -MaxEvents 50 |
       Select TimeCreated, Id, Message | Format-List
   ```
   Key event IDs:
   - **104** — Join succeeded
   - **106** — Join task started
   - **204** — Automatic registration failed (has error code)
   - **305** — WamDefaultSet error (PRT issue post-join)
2. Export full diagnostics: `dsregcmd /debug` (requires admin; writes to `%TEMP%\dsregcmd_debug.txt`)
3. Check certificate store for stale/expired device certs:
   ```powershell
   Get-ChildItem -Path "Cert:\LocalMachine\My" | Where-Object {$_.Subject -match "CN=" -and $_.Issuer -match "MS-Organization"} | Select Thumbprint, Subject, NotAfter
   ```

### Phase C — Registered in Entra but stuck Pending

1. Confirm `userCertificate` was written to the on-prem computer object (Step 5)
2. Force a delta sync on Entra Connect:
   ```powershell
   # Run on Entra Connect server
   Start-ADSyncSyncCycle -PolicyType Delta
   ```
3. Wait 2 minutes, then re-check device in Entra portal. If still Pending, run full sync:
   ```powershell
   Start-ADSyncSyncCycle -PolicyType Initial
   ```
4. Check for sync errors related to the device object:
   ```powershell
   Get-ADSyncConnectorRunStatus
   # Then check Synchronization Service Manager for connector errors on the device object
   ```

### Phase D — Registered OK but no PRT (SSO broken)

See `PRT-Issues-B.md` for full PRT troubleshooting. Quick check:
```powershell
dsregcmd /status | Select-String "AzureAdPrt|PrtUpdateTime|PrtExpiryTime"
```

---

## Remediation Playbooks

<details><summary>Fix 1 — Create or repair the SCP in AD</summary>

**Use when:** `dsregcmd /status` shows `TenantId` is blank or wrong, or SCP object is missing.

```powershell
# Run on a domain controller or with Enterprise Admin rights
# Replace values with your actual tenant ID and verified domain

$tenantId   = "<your-tenant-id>"         # From Entra portal → Overview
$tenantName = "<yourdomain.onmicrosoft.com>"  # Primary domain or any verified domain

$configNC   = (Get-ADRootDSE).configurationNamingContext
$scp        = "CN=62a0ff2e-97b9-4513-943f-0d221bd30080,CN=Device Registration Configuration,CN=Services,$configNC"

# Check if SCP exists
try {
    $existing = [ADSI]"LDAP://$scp"
    Write-Host "SCP exists. Current keywords: $($existing.Properties['keywords'])"
} catch {
    Write-Host "SCP not found — creating."
    New-ADObject -Name "62a0ff2e-97b9-4513-943f-0d221bd30080" `
        -Type "serviceConnectionPoint" `
        -Path "CN=Device Registration Configuration,CN=Services,$configNC" `
        -OtherAttributes @{ "keywords" = @("azureADName:$tenantName","azureADId:$tenantId") }
    Write-Host "SCP created."
}

# Update keywords if SCP exists but is wrong
$entry = [ADSI]"LDAP://$scp"
$entry.Properties["keywords"].Clear()
$entry.Properties["keywords"].Add("azureADName:$tenantName")
$entry.Properties["keywords"].Add("azureADId:$tenantId")
$entry.CommitChanges()
Write-Host "SCP keywords updated."
```

**Rollback:** The SCP was wrong before — rollback is to restore the original `keywords` values (note them first with `$existing.Properties['keywords']`).

</details>

---

<details><summary>Fix 2 — Force device re-registration</summary>

**Use when:** Device has stale cert, wrong registration, or is stuck Pending after sync confirmed working.

```powershell
# Run on the DEVICE as SYSTEM or local admin
# Step 1: Leave current registration
dsregcmd /leave
Start-Sleep -Seconds 5

# Step 2: Clear stale userCertificate from the computer object in AD
# (Run on a DC or machine with RSAT AD Tools)
$deviceName = $env:COMPUTERNAME
Set-ADComputer $deviceName -Clear userCertificate
Write-Host "userCertificate cleared on $deviceName"

# Step 3: Trigger the scheduled task on the device
$task = Get-ScheduledTask -TaskPath "\Microsoft\Windows\Workplace Join\" -TaskName "Automatic-Device-Join"
Start-ScheduledTask -TaskPath $task.TaskPath -TaskName $task.TaskName

# Step 4: Wait and check
Start-Sleep -Seconds 30
dsregcmd /status | Select-String "AzureAdJoined|DomainJoined|TenantId"
```

**Rollback:** Not directly reversible — the device will attempt fresh registration. If the environment is healthy this completes within 30 minutes; if Entra Connect syncs the new cert.

</details>

---

<details><summary>Fix 3 — Fix Entra Connect not syncing device OU</summary>

**Use when:** Device is domain-joined and SCP is correct, but device object never appears in Entra (even as Pending).

```powershell
# Run on Entra Connect server
Import-Module ADSync

# 1. Check if the OU is in scope
Get-ADSyncConnector | Where-Object {$_.SubType -eq "Windows Azure Active Directory (Microsoft)"} | 
    Select Name, ConnectorPartitions | Format-List
# Look for the on-prem AD connector and its included OUs

# 2. Confirm sync connector isn't in staging
$scheduler = Get-ADSyncScheduler
if ($scheduler.StagingModeEnabled) {
    Write-Warning "Entra Connect is in STAGING MODE — no writes are happening!"
    # To disable staging mode: open Entra Connect wizard → Configure → toggle staging mode
}

# 3. Trigger delta sync after fixing OU scope
Start-ADSyncSyncCycle -PolicyType Delta
Get-ADSyncConnectorRunStatus
```

**To add an OU to sync scope:** Open Entra Connect → Configure → Customize synchronization options → tick the target OU. Re-run a full sync after.

**Rollback:** Removing an OU from sync scope will orphan all Entra objects that came from it. Do not remove OUs without understanding downstream impact (Entra devices, users, groups).

</details>

---

<details><summary>Fix 4 — Remove and re-create stale Entra device object</summary>

**Use when:** Device object exists in Entra but in a bad state (wrong TrustType, duplicate entries, or permanently stuck Pending after all other fixes).

```powershell
# Step 1: Find the stale device object
Connect-MgGraph -Scopes "Device.ReadWrite.All"
$device = Get-MgDevice -Filter "displayName eq '<DeviceName>'"
$device | Select Id, DisplayName, TrustType, ApproximateLastSignInDateTime, IsCompliant

# Step 2: Note the device ID, then delete
Remove-MgDevice -DeviceId $device.Id
Write-Host "Deleted device object: $($device.Id)"

# Step 3: On the device, clear userCertificate and re-register (Fix 2 steps 1-4)
```

**Rollback:** Deleting the Entra device object removes it from Conditional Access device compliance state. Any CA policies requiring compliant/registered devices will fail for this device until re-registration completes and Intune re-evaluates compliance (typically 15-60 minutes after re-enrollment if Intune-managed).

</details>

---

<details><summary>Fix 5 — Proxy bypass for DRS endpoints</summary>

**Use when:** Registration fails with `0x801c001d` or `0x80072EFD` and `Test-NetConnection` to DRS endpoints times out.

```powershell
# Check current WinHTTP proxy
netsh winhttp show proxy

# If proxy is set and blocking DRS, add bypass for Microsoft endpoints
netsh winhttp set proxy proxy-server="<proxy>:<port>" bypass-list="*.microsoftonline.com;*.windows.net;*.microsoft.com;login.microsoftonline.com;device.login.microsoftonline.com;enterpriseregistration.windows.net;enterpriseenrollment.windows.net"

# Verify bypass works
Test-NetConnection -ComputerName "device.login.microsoftonline.com" -Port 443
```

For WPAD/GPO-managed proxies, coordinate with network team to whitelist:
- `https://login.microsoftonline.com`
- `https://device.login.microsoftonline.com`
- `https://enterpriseregistration.windows.net`
- `https://autologon.microsoftazuread-sso.com` (if Seamless SSO enabled)

**Rollback:** `netsh winhttp reset proxy` restores to direct connection (or WPAD).

</details>

---

## Evidence Pack

Run this on the affected device and attach output to your escalation ticket.

```powershell
<#
.SYNOPSIS  Collects Hybrid Join diagnostic evidence for escalation
.NOTES     Run as local admin on the affected device
#>

$output = [System.Text.StringBuilder]::new()
$ts     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

$null = $output.AppendLine("=== HAADJ Evidence Pack — $ts ===")
$null = $output.AppendLine("Computer: $env:COMPUTERNAME  |  User: $env:USERNAME")
$null = $output.AppendLine("")

# 1. dsregcmd /status
$null = $output.AppendLine("--- dsregcmd /status ---")
$null = $output.AppendLine((& dsregcmd /status 2>&1 | Out-String))

# 2. Scheduled task last result
$task = Get-ScheduledTask -TaskPath "\Microsoft\Windows\Workplace Join\" -TaskName "Automatic-Device-Join" -ErrorAction SilentlyContinue
if ($task) {
    $null = $output.AppendLine("--- Automatic-Device-Join Scheduled Task ---")
    $null = $output.AppendLine("State       : $($task.State)")
    $null = $output.AppendLine("LastRunTime : $($task.LastRunInfo.LastRunTime)")
    $null = $output.AppendLine("LastResult  : 0x{0:X}" -f $task.LastRunInfo.LastTaskResult)
}

# 3. Device Registration event log (last 50 events)
$null = $output.AppendLine("--- User Device Registration/Admin Log (last 50) ---")
$events = Get-WinEvent -LogName "Microsoft-Windows-User Device Registration/Admin" -MaxEvents 50 -ErrorAction SilentlyContinue
foreach ($e in $events) {
    $null = $output.AppendLine("$($e.TimeCreated) [ID:$($e.Id)] $($e.Message -replace '\s+',' ')")
}

# 4. Machine certificate store (DRS certs)
$null = $output.AppendLine("--- LocalMachine\My certs (MS-Organization) ---")
Get-ChildItem "Cert:\LocalMachine\My" | Where-Object {$_.Issuer -match "MS-Organization"} | ForEach-Object {
    $null = $output.AppendLine("Thumbprint: $($_.Thumbprint) | Subject: $($_.Subject) | Expires: $($_.NotAfter)")
}

# 5. Network connectivity to DRS endpoints
$null = $output.AppendLine("--- DRS Endpoint Reachability ---")
@("login.microsoftonline.com","device.login.microsoftonline.com","enterpriseregistration.windows.net") | ForEach-Object {
    $r = Test-NetConnection $_ -Port 443 -WarningAction SilentlyContinue
    $null = $output.AppendLine("$_ : TcpTest=$($r.TcpTestSucceeded)  Ping=$($r.PingSucceeded)")
}

# 6. SCP check
$null = $output.AppendLine("--- SCP Keywords ---")
try {
    $configNC = ([ADSI]"LDAP://RootDSE").configurationNamingContext
    $scp = [ADSI]"LDAP://CN=62a0ff2e-97b9-4513-943f-0d221bd30080,CN=Device Registration Configuration,CN=Services,$configNC"
    $null = $output.AppendLine($scp.Properties["keywords"] -join "; ")
} catch {
    $null = $output.AppendLine("SCP not found or unreachable: $_")
}

# Output to file
$outPath = "$env:TEMP\HAADJ-Evidence-$env:COMPUTERNAME.txt"
$output.ToString() | Out-File -FilePath $outPath -Encoding UTF8
Write-Host "Evidence written to: $outPath" -ForegroundColor Cyan
```

---

## Command Cheat Sheet

| Task | Command |
|------|---------|
| Full registration status | `dsregcmd /status` |
| Debug registration (verbose) | `dsregcmd /debug` (output in `%TEMP%`) |
| Leave Entra registration | `dsregcmd /leave` |
| Force re-registration | `dsregcmd /join` |
| Check SCP keywords | `([ADSI]"LDAP://CN=62a0ff2e...,CN=Services,<configNC>").Properties["keywords"]` |
| View Device Reg event log | `Get-WinEvent -LogName "Microsoft-Windows-User Device Registration/Admin" -MaxEvents 20` |
| Check scheduled task | `Get-ScheduledTask -TaskPath "\Microsoft\Windows\Workplace Join\"` |
| Run scheduled task | `Start-ScheduledTask -TaskPath "\Microsoft\Windows\Workplace Join\" -TaskName "Automatic-Device-Join"` |
| Check Entra Connect staging | `Get-ADSyncScheduler \| Select StagingModeEnabled` |
| Force delta sync | `Start-ADSyncSyncCycle -PolicyType Delta` |
| Force full sync | `Start-ADSyncSyncCycle -PolicyType Initial` |
| Check userCertificate on AD object | `Get-ADComputer <name> -Properties userCertificate \| Select userCertificate` |
| Clear userCertificate | `Set-ADComputer <name> -Clear userCertificate` |
| Find device in Entra via Graph | `Get-MgDevice -Filter "displayName eq '<name>'"` |
| Delete stale Entra device | `Remove-MgDevice -DeviceId <id>` |

---

## 🎓 Learning Pointers

- **Why "Pending" is a sync problem, not a registration problem.** When you see a device in Pending state in the Entra portal, the device itself has already completed the DRS registration — it has a certificate. The pending state means Entra Connect hasn't yet synced the `userCertificate` attribute back. Always check the Connect sync before trying to re-register. [MS Docs: Hybrid join verification](https://learn.microsoft.com/en-us/entra/identity/devices/troubleshoot-hybrid-join-windows-current)

- **The SCP is a per-forest configuration, not per-device.** One misconfigured SCP affects every device in the forest trying to register. Treat SCP changes as a change-controlled forest-wide operation. [MS Docs: Configure SCP](https://learn.microsoft.com/en-us/entra/identity/devices/hybrid-join-manual#configure-a-service-connection-point)

- **Staging mode on Entra Connect is a common gotcha during migrations.** When a Connect server is in staging mode it reads AD but makes no writes to Entra — and emits no obvious warnings in normal operation. Always check `Get-ADSyncScheduler | Select StagingModeEnabled` when devices stop registering site-wide.

- **Error codes are in hex — look them up specifically.** `0x801c` prefix errors all come from the Device Registration client and have specific meanings. The full list is in the Microsoft HAADJ troubleshooting guide. Treat the error code as the primary diagnostic signal before doing anything else. [MS Docs: Error codes](https://learn.microsoft.com/en-us/entra/identity/devices/troubleshoot-hybrid-join-windows-current#step-5-collect-logs-and-contact-microsoft-support)

- **Deleting a device from Entra breaks Intune compliance until re-enrollment.** If the device is Intune-managed, deleting its Entra object will cause Conditional Access "require compliant device" policies to fail. Plan this during a maintenance window or co-ordinate with the user that they may be blocked from cloud apps for up to an hour post-fix.

- **`dsregcmd /leave` does not unjoin from on-prem AD.** It only removes the Entra-side registration and clears the local device certificate. The device stays domain-joined to on-prem AD. Users sometimes confuse this with `Remove-Computer` — they are completely different operations. [Community reference: Practical 365 HAADJ deep dive](https://practical365.com/azure-ad-hybrid-join-troubleshooting/)
