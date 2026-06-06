# Entra Connect Sync Errors — Hotfix Runbook (Mode B: Ops)
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

Run these on the Entra Connect server (formerly Azure AD Connect):

```powershell
# 1. Check overall sync service health
Get-ADSyncScheduler | Select-Object SyncCycleEnabled, NextSyncCyclePolicyType, CurrentlyRunning, LastSyncCycleStartedDate

# 2. Get sync errors (most common starting point)
Get-ADSyncCSObject -ConnectorName "<YourConnectorName>" -DistinguishedName "<UserDN>" -ErrorAction SilentlyContinue
# OR for all errors:
Get-ADSyncConnectorStatistics -ConnectorName "<ConnectorName>"

# 3. Check for attribute-level errors in Synchronization Service Manager
# GUI: Synchronization Service Manager → Operations tab → look for red/yellow entries

# 4. Check Windows Event Logs for sync errors
Get-WinEvent -LogName "Application" -MaxEvents 50 | Where-Object {$_.Source -like "*Azure AD*" -or $_.Source -like "*ADSync*"} | Format-List

# 5. Trigger a manual delta sync and watch output
Start-ADSyncSyncCycle -PolicyType Delta
```

| What you see | What it means |
|---|---|
| `SyncCycleEnabled: False` | Scheduler disabled — find out why before re-enabling |
| `CurrentlyRunning: True` + hung for >2 hrs | Sync stuck — needs service restart |
| Sync Service Manager shows "stopped-server" | Connectivity to Entra ID lost or TLS issue |
| Sync Service Manager shows "attribute-value-must-be-unique" | Duplicate attribute (UPN/ProxyAddress/SourceAnchor) conflict |
| Event 611 in Application log | Export errors to Entra ID |
| Event 6900 | General sync engine error — read description |
| Sync completes but user not in Entra | Scoping filter excluding the object |

---
## Dependency Cascade

<details><summary>What must be true</summary>

```
On-Prem Active Directory
  └── Entra Connect server (domain-joined, service account healthy)
        └── ADSync service running (Microsoft.IdentityModel.Clients.ActiveDirectory)
              └── Scheduler enabled (SyncCycleEnabled = True)
                    └── Network path to Entra ID endpoints (*.msappproxy.net, login.microsoftonline.com)
                          └── TLS 1.2 enabled on Connect server
                                └── Service account permissions on AD (read/write where needed)
                                      └── No attribute conflicts in staging area (metaverse)
                                            └── Scoping filters not excluding target objects
                                                  └── User syncs to Entra ID tenant
                                                        └── Entra object visible + correct attributes
```

Key failure points:
- Service account password expired or permissions revoked
- Duplicate `proxyAddresses`, `userPrincipalName`, or `objectGUID` (ImmutableId) collisions
- Scoping filter (OU filter or attribute filter) excluding objects unintentionally
- TLS 1.2 not configured — connection to Entra endpoints fails
- Entra Connect version outdated — service rejects connection
- Staging mode accidentally left on (objects processed but not exported)

</details>

---
## Diagnosis & Validation Flow

**Step 1 — Check ADSync service**
```powershell
Get-Service ADSync | Select-Object Status, StartType
```
Expected: `Running`, `Automatic`.  
Bad: Stopped — `Start-Service ADSync`, then re-check.

**Step 2 — Check sync scheduler**
```powershell
Get-ADSyncScheduler | Select-Object SyncCycleEnabled, CurrentlyRunning, NextSyncCyclePolicyType, LastSyncCycleStartedDate
```
Expected: `SyncCycleEnabled: True`, `CurrentlyRunning: False`.  
Bad: Disabled or stuck — see Fix 1.

**Step 3 — Check staging mode**
```powershell
Get-ADSyncGlobalSettings | Select-Object StagingModeEnabled
```
Expected: `False`.  
Bad: `True` — objects are processed but NOT exported to Entra ID (Fix 2).

**Step 4 — Run delta sync and capture output**
```powershell
$result = Start-ADSyncSyncCycle -PolicyType Delta
$result
# Wait for completion (2-5 mins typical)
Start-Sleep -Seconds 120
Get-ADSyncScheduler | Select-Object CurrentlyRunning, LastSyncCycleStartedDate
```

**Step 5 — Open Synchronization Service Manager**
```
C:\Program Files\Microsoft Azure Active Directory Connect\SynchronizationServiceManager.exe
```
In Operations tab: look for red (Error) or yellow (Warning) rows.  
Double-click any error row → note the **CS Object DN**, **Error Type**, and **Error Detail**.

**Step 6 — Check for attribute conflicts**
```powershell
# Get all objects with errors in the connector space
Import-Module ADSync
$connectors = Get-ADSyncConnector
$azureConnector = $connectors | Where-Object {$_.Type -eq "Extensible2"}
$errorObjects = Get-ADSyncCSObject -ConnectorIdentifier $azureConnector.Identifier |
  Where-Object {$_.SyncError -ne $null}
$errorObjects | Select-Object DistinguishedName, SyncError | Format-List
```

**Step 7 — Check Entra ID Connect Health (if licensed)**  
Entra portal → Entra Connect → Health  
Look for: alerts, sync errors, agent status.

**Step 8 — Verify network connectivity**
```powershell
# Test key Entra endpoints
$endpoints = @(
    "login.microsoftonline.com",
    "provisioningapi.microsoftonline.com",
    "aadcdn.msauth.net"
)
foreach ($ep in $endpoints) {
    $result = Test-NetConnection -ComputerName $ep -Port 443
    Write-Host "$ep : $($result.TcpTestSucceeded)"
}
```

---
## Common Fix Paths

<details><summary>Fix 1 — Sync scheduler disabled or stuck</summary>

**Cause:** Scheduler manually disabled, or a sync cycle hung and never completed.

```powershell
# Check state
Get-ADSyncScheduler | Select-Object SyncCycleEnabled, CurrentlyRunning, LastSyncCycleStartedDate

# Re-enable if disabled
Set-ADSyncScheduler -SyncCycleEnabled $true

# If stuck (CurrentlyRunning = True for > 2 hours):
# Restart the ADSync service — this cancels any running cycle
Stop-Service ADSync -Force
Start-Sleep -Seconds 10
Start-Service ADSync

# Verify and trigger fresh delta sync
Get-ADSyncScheduler
Start-ADSyncSyncCycle -PolicyType Delta
```

**Rollback note:** Restarting ADSync is safe. Any in-progress sync is cancelled and will restart from the last watermark.

</details>

<details><summary>Fix 2 — Staging mode enabled (objects not exporting)</summary>

**Cause:** Staging mode is enabled — either intentionally (DR server) or accidentally. Objects are imported and processed but NOT exported to Entra ID.

```powershell
# Check
Get-ADSyncGlobalSettings | Select-Object StagingModeEnabled

# Disable staging mode (ONLY if this is the primary Connect server)
Set-ADSyncGlobalSettings -StagingModeEnabled $false

# Run a full sync after disabling
Start-ADSyncSyncCycle -PolicyType Initial
```

⚠️ **Warning:** Only disable staging if this is the intended active Connect server. If you have two Connect servers and this is the standby, leaving staging mode ON is correct.

</details>

<details><summary>Fix 3 — Attribute conflict (duplicate UPN / ProxyAddress / ImmutableId)</summary>

**Cause:** Two AD objects have the same `userPrincipalName`, `proxyAddresses`, or `msDS-ConsistencyGuid` value. Entra ID rejects one with an attribute uniqueness error.

```powershell
# In Sync Service Manager, note the conflicting DN and attribute from the error
# Find the duplicate in AD:
# Example: duplicate proxyAddresses
$conflictEmail = "<email@domain.com>"
Get-ADUser -Filter {ProxyAddresses -like "*$conflictEmail*"} -Properties ProxyAddresses |
  Select-Object DistinguishedName, UserPrincipalName, ProxyAddresses

# Example: duplicate UPN
$conflictUPN = "<user@domain.com>"
Get-ADUser -Filter {UserPrincipalName -eq $conflictUPN} |
  Select-Object DistinguishedName, UserPrincipalName
```

**Fix — Remove or correct the duplicate:**
```powershell
# Remove duplicate proxyAddress from the non-primary user
$dupUser = Get-ADUser -Identity "<DN-of-duplicate>" -Properties ProxyAddresses
$updatedProxies = $dupUser.ProxyAddresses | Where-Object {$_ -notlike "*$conflictEmail*"}
Set-ADUser -Identity $dupUser -ProxyAddresses $updatedProxies

# After fixing in AD, trigger delta sync
Start-ADSyncSyncCycle -PolicyType Delta
```

**Rollback note:** Document the original `ProxyAddresses` value before removing. Restoration is manual.

</details>

<details><summary>Fix 4 — Object not syncing (scoping filter exclusion)</summary>

**Cause:** The object is in an OU not included in the sync scope, or an attribute filter is excluding it.

```powershell
# Check which OUs are in scope
Get-ADSyncConnector | Where-Object {$_.Type -eq "AD"} | ForEach-Object {
    $_.ConnectorPartitions | ForEach-Object {
        $_.Containers | Select-Object SelectedContainers
    }
}
```

In **Synchronization Service Manager** → Connectors → [AD connector] → Properties → Configure Directory Partitions → Containers  
Verify the OU containing the user is ticked.

**To add an OU to sync scope:**
1. Open Entra Connect wizard
2. Customize synchronization options
3. Add the OU to the selected list
4. Run: `Start-ADSyncSyncCycle -PolicyType Initial`

⚠️ Adding OUs may trigger a large initial sync. Check object count before proceeding.

</details>

<details><summary>Fix 5 — Password hash sync not working</summary>

**Cause:** Password Sync Agent disabled, service account permissions missing, or DC connectivity issue.

```powershell
# Check if PHS is enabled in config
Get-ADSyncAADPasswordSyncConfiguration -SourceConnector "<AD-ConnectorName>"

# Check Password Sync heartbeat (look for event 656, 657 in Application log)
Get-WinEvent -LogName "Application" -MaxEvents 100 |
  Where-Object {$_.Id -in @(656, 657, 611)} |
  Select-Object TimeCreated, Id, Message | Format-List

# Force a full password sync (syncs all password hashes — can take time)
Invoke-ADSyncRunProfile -ConnectorName "<AD-ConnectorName>" -RunProfileName "Full Import"
```

If event 611 shows password sync errors:
- Check service account has `Replicating Directory Changes` and `Replicating Directory Changes All` permissions on the domain
- Check network connectivity from Connect server to all DCs on port 389/636

</details>

<details><summary>Fix 6 — Entra Connect version too old (connection rejected)</summary>

**Cause:** Microsoft retires older versions of Entra Connect. Outdated versions lose connectivity with Entra ID endpoints.

```powershell
# Check installed version
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Azure AD Connect" -ErrorAction SilentlyContinue).Version

# Current supported version: check https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/reference-connect-version-history
```

**Upgrade path:**
1. Download latest Entra Connect from Microsoft Download Center
2. Run the installer on the Connect server — it upgrades in-place
3. No configuration data is lost in an in-place upgrade
4. After upgrade, verify sync: `Start-ADSyncSyncCycle -PolicyType Delta`

</details>

---
## Escalation Evidence

```
TICKET ESCALATION — Entra Connect Sync Error

Entra Connect server: ______________
Entra Connect version: _____________
AD Domain: ________________________
Entra Tenant ID: ___________________

Sync service state: (Running / Stopped)
Scheduler enabled: (True / False)
Staging mode enabled: (True / False)
Last successful sync: ______________
Currently running: (True / False / Stuck since: ___)

Error type (from Sync Service Manager): ___________
Error detail: _____________________
Affected object DN: ________________
Attribute causing conflict: _________

Network connectivity to Entra endpoints: (OK / FAIL)
  - login.microsoftonline.com :443: ___
  - provisioningapi.microsoftonline.com :443: ___

Event log entries (App log, last 24h):
---
[paste Event IDs 611, 656, 657, 6900 entries here]
---

Steps already attempted:
[ ] ADSync service restarted
[ ] Delta sync triggered manually
[ ] Staging mode checked
[ ] Attribute conflict identified and resolved
[ ] Scoping / OU filter checked
[ ] Entra Connect version verified
[ ] Network connectivity tested
```

---
## 🎓 Learning Pointers

- **Sync Service Manager is the truth:** The Operations tab in Synchronization Service Manager shows every import/sync/export operation with pass/fail details. Before touching anything, spend 2 minutes reading what it says — the error detail usually tells you exactly what attribute and which object is at fault. [Sync Service Manager guide](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/how-to-connect-sync-service-manager-ui)
- **Staging mode is a silent killer:** An Entra Connect server in staging mode processes everything normally and shows no errors — but exports nothing. It's designed for DR testing but has caught many engineers by surprise. Always check `Get-ADSyncGlobalSettings` before assuming sync is working.
- **Attribute conflicts follow a priority rule:** When two objects have the same `proxyAddress` or UPN, Entra uses a "last writer wins with duplicate quarantine" rule — one object syncs fine, the other gets a `QuarantinedAttributeValue` error. The quarantined one is the one that synced *after* the conflict was created. [Duplicate attribute resiliency](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/how-to-connect-syncservice-duplicate-attribute-resiliency)
- **Version retirements are silent:** Microsoft doesn't email you when your Entra Connect version hits end-of-support. The first sign is usually that syncs stop working with a "stopped-server" error. Keep a calendar reminder to check version currency every 6 months. [Version history](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/reference-connect-version-history)
- **Password hash sync requires DC replication rights:** The Entra Connect service account needs `Replicating Directory Changes` and `Replicating Directory Changes All` on the domain object — not individual OUs. These are AD extended rights, not standard delegations. Missing these = PHS silently stops.
- **Delta vs. Initial sync:** Delta sync processes only changes since the last watermark (fast, safe, run often). Initial sync re-imports everything from scratch (slow, needed after scoping changes or service account fixes). Don't run Initial unless you have to — it can take hours on large directories.
