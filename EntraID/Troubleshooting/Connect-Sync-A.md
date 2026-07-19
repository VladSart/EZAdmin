# Entra Connect Sync Errors — Reference Runbook (Mode A: Deep Dive)
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

**In scope:**
- Entra Connect (formerly Azure AD Connect) v2.x on Windows Server 2016/2019/2022
- Password Hash Sync (PHS), Pass-through Authentication (PTA), and Federation scenarios
- Attribute-level sync errors, scoping filter issues, staging mode, and service account failures
- Hybrid identity models: on-premises AD → Entra ID

**Out of scope:**
- Entra Cloud Sync (different agent model — see `CloudSync-A.md`/`CloudSync-B.md`)
- Cross-forest topologies (covered in detail in Microsoft's multi-forest docs)
- Direct federation with third-party IdPs (ADFS-specific issues beyond initial triage)

**Assumptions:**
- You have RDP or console access to the Entra Connect server
- You have Domain Admin or delegated AD read rights
- The Connect server is domain-joined and running Windows Server 2016+
- ADSync PowerShell module is available (`Import-Module ADSync`)

---
## How It Works

<details><summary>Full architecture — sync engine internals</summary>

### Sync Engine Architecture

Entra Connect's sync engine has three distinct spaces and two transform stages between them:

```
On-Prem Active Directory
        │
        │  Import (read from AD)
        ▼
Connector Space (AD-CS)
  [Staging area — raw AD objects as seen by Connect]
        │
        │  Synchronization Rules (Inbound)
        │  [Filter, transform, merge attributes]
        ▼
Metaverse (MV)
  [Single unified view of each identity across all sources]
        │
        │  Synchronization Rules (Outbound)
        │  [Project MV object to target connector format]
        ▼
Connector Space (AAD-CS)
  [Staging area — objects as they will appear in Entra ID]
        │
        │  Export (write to Entra ID)
        ▼
Entra ID (Azure AD)
```

**Key concepts:**

1. **Connector Space (CS):** A staging area specific to each connected directory (AD and Entra ID). Every import operation writes to the CS. Objects in CS are "pending" until sync rules process them.

2. **Metaverse (MV):** The central identity store inside the sync engine. Objects from multiple CSes are "joined" or "projected" into the MV. This is where attribute transformations happen. An MV object that isn't linked to the AAD-CS will never export to Entra ID.

3. **Sync Cycle — 3 phases per connector:**
   - **Import:** Read objects from the source (AD or Entra ID) into the CS
   - **Synchronize:** Apply inbound rules (AD-CS → MV), then outbound rules (MV → AAD-CS)
   - **Export:** Write CS changes to the target (Entra ID)

4. **Delta vs. Initial sync:**
   - **Delta:** Processes only objects changed since the last high-watermark (stored per-connector). Fast, runs every 30 min by default.
   - **Initial (Full):** Re-imports everything from scratch. Required after: connector reconfiguration, OU scope changes, service account permission changes, or database corruption.

5. **Run Profiles:** Named sequences of operations (e.g., "Delta Import", "Delta Sync", "Export"). The scheduler runs these in order. Synchronization Service Manager shows each run profile execution with pass/fail status.

### Password Hash Sync (PHS) Sub-System

PHS is a separate sub-component running inside the ADSync service. It:
- Monitors DCs for password changes using the MS-DRSR (Directory Replication) protocol
- Requires `Replicating Directory Changes` and `Replicating Directory Changes All` extended rights on the **domain object** (not OUs)
- Pushes a salted, hashed version of the NT hash — not the plaintext or NT hash itself
- Syncs every 2 minutes by default (event ID 656 = cycle start, 657 = cycle end)
- A missed cycle is not an error; it catches up on the next run

### Staging Mode

A Connect server in staging mode:
- Performs all imports and synchronizations normally
- Does NOT export to Entra ID
- Is completely invisible from Entra ID's perspective — it looks like the primary server is the only one running
- Is designed for: testing config changes, DR standby, migration cutover preparation

**Danger:** A server accidentally left in staging mode after a migration or DR test will appear healthy in all local checks but contribute nothing to Entra ID sync.

</details>

---
## Dependency Stack

```
On-Premises Active Directory
  └── Service Account (has: Domain User + specific delegated rights)
        └── ADSync Service (running, auto-start)
              └── SQL Server LocalDB / SQL Server (stores MV, CS, watermarks)
                    └── Sync Scheduler (SyncCycleEnabled = True, 30-min interval)
                          └── Network path (TLS 1.2) to Entra ID endpoints
                                ├── login.microsoftonline.com :443
                                ├── provisioningapi.microsoftonline.com :443
                                └── aadcdn.msauth.net :443
                                      └── Entra Connect version (supported, not retired)
                                            └── Staging Mode = False (active server)
                                                  └── Sync Rules (no attribute conflicts)
                                                        └── Scoping filters (OUs included)
                                                              └── Object exports to Entra ID
```

**Service account minimum permissions (AD side):**
| Permission | Where | Required For |
|---|---|---|
| Read all user attributes | Domain | Import |
| `Replicating Directory Changes` | Domain object | PHS |
| `Replicating Directory Changes All` | Domain object | PHS |
| Create/Delete computer objects | OUs for writeback | Device writeback |
| Manage group membership | OUs for writeback | Group writeback |

**Entra ID side:** The Connect service account in Entra ID requires the `Hybrid Identity Administrator` role (or legacy `Directory Synchronization Accounts` role).

---
## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Objects not appearing in Entra ID (no error in portal) | Staging mode ON; or OU out of scope | `Get-ADSyncGlobalSettings`; check OU scope in wizard |
| `attribute-value-must-be-unique` error | Duplicate `proxyAddresses`, `userPrincipalName`, or `msDS-ConsistencyGuid` | Sync Service Manager → Operations → error detail |
| `stopped-server` in Sync Service Manager | Entra connectivity lost; TLS 1.2 not configured; cert expired on Connect | Test network endpoints; check TLS registry |
| `stopped-extension-dll-exception` | ADSync service module crash; usually version mismatch or .NET runtime issue | Event log 6900; reinstall or upgrade Connect |
| Sync stuck (CurrentlyRunning for > 2 hours) | Deadlock in sync engine; large initial sync; service hung | Restart ADSync service |
| Password changes not reflected in Entra ID | PHS disabled; service account missing DC replication rights; DC unreachable | Events 656/657; `Get-ADSyncAADPasswordSyncConfiguration` |
| User disappears from Entra ID | Scoping filter now excludes the object; OU moved out of scope | Check OU assignment; run delta sync |
| `QuarantinedAttributeValue` error in Entra portal | Duplicate attribute conflict — one object quarantined | Entra portal → Users → All users → filter by sync errors |
| Sync completes with 0 exports | All objects already in sync (normal); or staging mode | Check export count in Sync Service Manager |
| Error after Entra Connect upgrade | Run profile or connector config mismatch post-upgrade | Re-run Configure Synchronization Options in wizard |
| `InvalidSoftMatch` error | Soft-match failed (no matching UPN/SMTP) during initial migration | Manually set `msDS-ConsistencyGuid` to match objectGUID |
| `ObjectTypeMismatch` | AD object type (user/contact/group) doesn't match existing Entra object | Check for pre-existing cloud-only objects with same UPN |

---
## Validation Steps

**Step 1 — Confirm ADSync service and scheduler are healthy**
```powershell
Get-Service ADSync | Select-Object Name, Status, StartType
Get-ADSyncScheduler | Select-Object SyncCycleEnabled, CurrentlyRunning,
    NextSyncCyclePolicyType, LastSyncCycleStartedDate, NextSyncCycleStartTimeInUTC
```
Expected: `Running`, `Automatic`, `SyncCycleEnabled: True`, `CurrentlyRunning: False`.

**Step 2 — Confirm staging mode is off (production server)**
```powershell
Get-ADSyncGlobalSettings | Select-Object StagingModeEnabled
```
Expected: `False`.

**Step 3 — Check for objects with sync errors**
```powershell
Import-Module ADSync
$connectors = Get-ADSyncConnector
$aadConnector = $connectors | Where-Object { $_.Type -eq "Extensible2" } | Select-Object -First 1

# Get all CS objects with errors
$csErrors = Get-ADSyncCSObject -ConnectorIdentifier $aadConnector.Identifier -ErrorAction SilentlyContinue |
    Where-Object { $_.SyncError -ne $null }
$csErrors | Select-Object DistinguishedName, SyncError | Format-List
```
Expected: empty result (no errors).
Bad: lists objects with error codes — note the DN and error type.

**Step 4 — Check connector statistics**
```powershell
$adConnector = $connectors | Where-Object { $_.Type -eq "AD" } | Select-Object -First 1
Get-ADSyncConnectorStatistics -ConnectorName $adConnector.Name
```
Look for: `ExportErrors`, `ImportErrors`. Zero is good.

**Step 5 — Validate network connectivity to Entra endpoints**
```powershell
$endpoints = @(
    "login.microsoftonline.com",
    "provisioningapi.microsoftonline.com",
    "aadcdn.msauth.net",
    "s1.adhybridhealth.azure.com"  # Connect Health endpoint
)
foreach ($ep in $endpoints) {
    $r = Test-NetConnection -ComputerName $ep -Port 443 -WarningAction SilentlyContinue
    [PSCustomObject]@{
        Endpoint = $ep
        Reachable = $r.TcpTestSucceeded
        RemoteAddress = $r.RemoteAddress
    }
} | Format-Table -AutoSize
```
Expected: all `True`.

**Step 6 — Verify TLS 1.2 is enforced (required for Entra connectivity)**
```powershell
$tlsPaths = @(
    "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client",
    "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server"
)
foreach ($path in $tlsPaths) {
    if (Test-Path $path) {
        $enabled = (Get-ItemProperty $path -ErrorAction SilentlyContinue).Enabled
        $disabled = (Get-ItemProperty $path -ErrorAction SilentlyContinue).DisabledByDefault
        Write-Host "$path — Enabled: $enabled, DisabledByDefault: $disabled"
    } else {
        Write-Host "$path — NOT FOUND (TLS 1.2 may not be explicitly configured)"
    }
}
```

**Step 7 — Confirm Entra Connect version is current**
```powershell
$ver = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Azure AD Connect" -ErrorAction SilentlyContinue).Version
Write-Host "Installed version: $ver"
# Compare against: https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/reference-connect-version-history
```

**Step 8 — Trigger delta sync and verify completion**
```powershell
$before = Get-ADSyncScheduler | Select-Object -ExpandProperty LastSyncCycleStartedDate
Start-ADSyncSyncCycle -PolicyType Delta
Start-Sleep -Seconds 180
$after = Get-ADSyncScheduler | Select-Object -ExpandProperty LastSyncCycleStartedDate
Write-Host "Before: $before`nAfter: $after"
# After timestamp should be newer
```

---
## Troubleshooting Steps (by phase)

### Phase 1 — Service Layer

If sync hasn't run at all:
1. Confirm ADSync service is running (`Get-Service ADSync`)
2. Check Windows Event Log for service start failures (Application log, source: ADSync)
3. Check SQL Server LocalDB is accessible: `sqllocaldb info ADSync`
4. Verify service account credentials haven't expired: check the ADSync service logon account in Services.msc
5. Check disk space — full disk can prevent DB operations: `Get-PSDrive C | Select-Object Used, Free`

### Phase 2 — Import Phase Failures

Imports fail (AD connector):
1. Verify service account can read AD: `dsquery user -samid <serviceAccountSAM>`
2. Check if DC is reachable from Connect server: `nltest /dsgetdc:<domain-fqdn>`
3. Look for LDAP bind errors in Application event log (Event ID 1000 or 6900)
4. Check for AD replication health — if DCs are diverged, imports may see stale data: `repadmin /replsummary`

### Phase 3 — Synchronization Rule Failures

Objects importing but not projecting to MV:
1. Open Synchronization Service Manager → Metaverse Designer — confirm object types are present
2. Check Synchronization Rules Editor for customizations that may be filtering objects
3. For a specific object: CS Object → Lineage tab shows which sync rule processed it
4. Check for "join" vs "provision" rule mismatches — an object that doesn't join to an existing MV object will be provisioned as new (may cause duplicate in Entra)

### Phase 4 — Export / Attribute Conflict Failures

Objects in AAD-CS but export fails:
1. In Sync Service Manager → Operations → find the failed Export run profile
2. Double-click → expand the error row → note Error Type and CS Object
3. For `attribute-value-must-be-unique`: use Fix 3 in B runbook to find and resolve duplicates
4. For `InvalidLicenseAssignment`: licensing error in Entra — not a sync issue; check user's location attribute (`usageLocation`) is set in AD
5. For `ObjectTypeMismatch`: a cloud-only object with same UPN exists — must be converted or deleted first

### Phase 5 — Post-Sync Verification

After fixing:
1. Run delta sync: `Start-ADSyncSyncCycle -PolicyType Delta`
2. Wait 3-5 minutes, check Sync Service Manager Operations for green runs
3. Verify in Entra portal that the affected user/object now shows correct attributes
4. If using Connect Health, check the Health blade in the Entra admin center for residual alerts

---
## Remediation Playbooks

<details><summary>Playbook 1 — Resolve attribute uniqueness conflict (duplicate proxyAddress / UPN)</summary>

**Scenario:** Export to Entra ID fails with `attribute-value-must-be-unique`. Two AD objects share the same `proxyAddresses` entry or `userPrincipalName`.

**Step 1 — Identify conflicting objects**
```powershell
# For proxyAddresses conflict:
$conflictEmail = "<smtp:conflicting@domain.com>"
$conflicting = Get-ADUser -Filter * -Properties ProxyAddresses |
    Where-Object { $_.ProxyAddresses -contains $conflictEmail } |
    Select-Object DistinguishedName, UserPrincipalName, ProxyAddresses
$conflicting | Format-List

# For UPN conflict:
$conflictUPN = "<conflicting@domain.com>"
Get-ADUser -Filter { UserPrincipalName -eq $conflictUPN } |
    Select-Object DistinguishedName, UserPrincipalName
```

**Step 2 — Determine which object is "correct"**
- The primary object is usually the active user
- The secondary is often a disabled account, shared mailbox proxy, or orphaned object
- Check `LastLogonDate`, `Enabled`, and `Description` to determine owner

**Step 3 — Remove the duplicate attribute**
```powershell
# Backup first
$dupUser = Get-ADUser -Identity "<DN-of-duplicate>" -Properties ProxyAddresses
$originalProxies = $dupUser.ProxyAddresses
Write-Host "Original ProxyAddresses for $($dupUser.DistinguishedName):"
$originalProxies | ForEach-Object { Write-Host "  $_" }

# Remove conflicting entry
$cleanedProxies = $originalProxies | Where-Object { $_ -ne $conflictEmail }
Set-ADUser -Identity $dupUser.DistinguishedName -Replace @{ proxyAddresses = $cleanedProxies }

# Confirm
(Get-ADUser -Identity $dupUser.DistinguishedName -Properties ProxyAddresses).ProxyAddresses
```

**Step 4 — Trigger sync and verify**
```powershell
Start-ADSyncSyncCycle -PolicyType Delta
Start-Sleep -Seconds 180
# Check Sync Service Manager for clean export
```

**Rollback:** Re-add the removed proxyAddress value: `Set-ADUser -Identity <DN> -Add @{ proxyAddresses = $conflictEmail }`

</details>

<details><summary>Playbook 2 — Recover from sync service account credential expiry</summary>

**Scenario:** ADSync service stops starting, or exports fail with authentication errors. The service account's password has expired or been reset.

**Step 1 — Confirm the issue**
```powershell
# Check service account on the ADSync service
$svc = Get-WmiObject -Class Win32_Service -Filter "Name='ADSync'"
Write-Host "Service runs as: $($svc.StartName)"

# Check event log for credential errors
Get-WinEvent -LogName Application -MaxEvents 50 |
    Where-Object { $_.Source -like "*ADSync*" -and $_.Level -le 3 } |
    Select-Object TimeCreated, Message | Format-List
```

**Step 2 — Reset the password in AD**
```powershell
# Reset in AD (from a DC or machine with AD module)
$newPassword = Read-Host -AsSecureString -Prompt "New password for service account"
Set-ADAccountPassword -Identity "<serviceAccountSAM>" -NewPassword $newPassword -Reset
Set-ADUser -Identity "<serviceAccountSAM>" -PasswordNeverExpires $true
```

⚠️ Consider whether PasswordNeverExpires is appropriate for your security policy. Alternatively, configure a managed service account (gMSA) to eliminate this problem permanently.

**Step 3 — Update the ADSync service logon credentials**
```powershell
# Update via Entra Connect configuration wizard:
# 1. Run: C:\Program Files\Microsoft Azure Active Directory Connect\AzureADConnect.exe
# 2. Choose: "Change user sign-in" or "View current configuration"
# 3. Update AD DS connector account credentials under "Customize synchronization options"

# Or directly via services.msc:
# Services → Microsoft Azure AD Sync → Properties → Log On tab → update credentials
```

**Step 4 — Restart and verify**
```powershell
Restart-Service ADSync
Start-Sleep -Seconds 30
Get-Service ADSync | Select-Object Status
Get-ADSyncScheduler | Select-Object SyncCycleEnabled, CurrentlyRunning
Start-ADSyncSyncCycle -PolicyType Delta
```

**Rollback:** Not applicable — credential reset is forward-only.

</details>

<details><summary>Playbook 3 — Resolve scoping filter misconfiguration (user excluded from sync)</summary>

**Scenario:** A specific user or group of users is not appearing in Entra ID, but no errors are shown. The object is simply not being synced.

**Step 1 — Confirm the object is not in Entra ID**
```powershell
# Run this from a machine with the MSOnline or Microsoft.Graph module
Connect-MgGraph -Scopes "User.Read.All"
Get-MgUser -Filter "userPrincipalName eq '<upn@domain.com>'" | Select-Object DisplayName, Id
# If null — not synced to Entra ID
```

**Step 2 — Check if object exists in ADSync connector space**
```powershell
Import-Module ADSync
$adConnector = (Get-ADSyncConnector | Where-Object { $_.Type -eq "AD" } | Select-Object -First 1).Name
$csObj = Get-ADSyncCSObject -ConnectorName $adConnector -DistinguishedName "<user-DN>"
if (-not $csObj) {
    Write-Host "Object NOT in connector space — likely out of OU scope"
} else {
    Write-Host "Object IS in connector space"
    $csObj | Select-Object DistinguishedName, Lineage, SyncError | Format-List
}
```

**Step 3 — Check OU scope in Entra Connect configuration**
```powershell
# List included containers per AD connector
$adConnector = Get-ADSyncConnector | Where-Object { $_.Type -eq "AD" } | Select-Object -First 1
$adConnector.ConnectorPartitions | ForEach-Object {
    $_.Containers | Select-Object SelectedContainers
}
```

**Step 4 — Check attribute-based filtering (if used)**
```powershell
# List inbound sync rules that have scoping filters
Get-ADSyncRule | Where-Object { $_.Direction -eq "Inbound" -and $_.ScopeFilter -ne $null } |
    Select-Object Name, ScopeFilter | Format-List
```

**Step 5 — Expand OU scope or fix attribute filter**
If the user is in an OU not in scope:
1. Run the Entra Connect Configuration Wizard
2. Navigate to: Customize synchronization options → Filter by OUs
3. Add the required OU to the selected list
4. Complete wizard — this triggers an initial sync automatically

⚠️ Adding OUs can add large numbers of objects. Verify the count before proceeding:
```powershell
(Get-ADObject -SearchBase "<OU-DN>" -SearchScope Subtree -Filter * | Measure-Object).Count
```

**Rollback:** Remove the OU from scope in the wizard and run an initial sync to remove the objects from Entra ID.

</details>

<details><summary>Playbook 4 — Force soft-match to link cloud-only and on-prem objects</summary>

**Scenario:** A user was created in Entra ID before hybrid identity was configured. When sync starts, a duplicate object is created rather than the on-prem user linking to the existing cloud user. Result: two user objects for the same person.

**Background:** Entra Connect uses "soft matching" to link AD users to existing Entra objects by comparing:
1. `userPrincipalName` (must match exactly)
2. `proxyAddresses` (SMTP addresses must overlap)

If neither matches, a new duplicate object is created. "Hard match" uses `msDS-ConsistencyGuid` / `ImmutableId`.

**Step 1 — Identify the existing Entra ID object's ImmutableId**
```powershell
Connect-MgGraph -Scopes "User.Read.All"
$cloudUser = Get-MgUser -Filter "userPrincipalName eq '<upn@domain.com>'" -Property OnPremisesImmutableId
$cloudUser.OnPremisesImmutableId
# If null — cloud-only, no hard match set
```

**Step 2 — Set AD object's msDS-ConsistencyGuid to match Entra ImmutableId**
```powershell
# Get the on-prem user's objectGUID
$adUser = Get-ADUser -Identity "<samAccountName>" -Properties ObjectGUID, 'msDS-ConsistencyGuid'

# If cloud ImmutableId is null — generate from AD objectGUID
$immutableId = [System.Convert]::ToBase64String($adUser.ObjectGUID.ToByteArray())
Write-Host "Derived ImmutableId: $immutableId"

# Set msDS-ConsistencyGuid on AD object (this is what Entra Connect uses as the anchor)
Set-ADUser -Identity $adUser.DistinguishedName `
    -Replace @{ 'msDS-ConsistencyGuid' = $adUser.ObjectGUID.ToByteArray() }
```

**Step 3 — Clear ImmutableId on Entra cloud object to allow soft-match**
```powershell
# This forces Entra to re-match on next sync
Update-MgUser -UserId $cloudUser.Id -OnPremisesImmutableId $null
```

**Step 4 — Trigger sync and verify merge**
```powershell
Start-ADSyncSyncCycle -PolicyType Delta
# Wait 5-10 minutes, then check
Start-Sleep -Seconds 300
Get-MgUser -Filter "userPrincipalName eq '<upn@domain.com>'" -Property OnPremisesImmutableId, OnPremisesSyncEnabled
```
Expected: `OnPremisesSyncEnabled: True`, `OnPremisesImmutableId` populated.

**Rollback:** If the merge causes issues, you may need to delete the on-prem-synced object and restore the cloud-only object's ImmutableId. This is disruptive — always test in a non-prod tenant first.

</details>

---
## Evidence Pack

Run this script on the Entra Connect server to collect all data needed for Microsoft or L3 escalation:

```powershell
<#
.SYNOPSIS  Entra Connect Sync Evidence Collector
.NOTES     Run from the Entra Connect server as a local administrator
#>

$reportPath = "C:\Temp\EntraConnectEvidence_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
New-Item -ItemType Directory -Path $reportPath -Force | Out-Null

Write-Host "Collecting Entra Connect evidence to $reportPath..." -ForegroundColor Cyan

# 1. ADSync service and scheduler state
"=== ADSync Service ===" | Out-File "$reportPath\01_ServiceState.txt"
Get-Service ADSync | Select-Object Name, Status, StartType | Format-List |
    Out-File "$reportPath\01_ServiceState.txt" -Append
"=== Scheduler ===" | Out-File "$reportPath\01_ServiceState.txt" -Append
Get-ADSyncScheduler | Format-List | Out-File "$reportPath\01_ServiceState.txt" -Append
"=== Global Settings ===" | Out-File "$reportPath\01_ServiceState.txt" -Append
Get-ADSyncGlobalSettings | Select-Object StagingModeEnabled | Format-List |
    Out-File "$reportPath\01_ServiceState.txt" -Append

# 2. Connect version
"=== Version ===" | Out-File "$reportPath\02_Version.txt"
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Azure AD Connect" -ErrorAction SilentlyContinue).Version |
    Out-File "$reportPath\02_Version.txt" -Append

# 3. Connector statistics
Import-Module ADSync -ErrorAction SilentlyContinue
"=== Connectors ===" | Out-File "$reportPath\03_Connectors.txt"
Get-ADSyncConnector | Select-Object Name, Type, State | Format-Table -AutoSize |
    Out-File "$reportPath\03_Connectors.txt" -Append
foreach ($connector in (Get-ADSyncConnector)) {
    "`n=== Statistics: $($connector.Name) ===" | Out-File "$reportPath\03_Connectors.txt" -Append
    Get-ADSyncConnectorStatistics -ConnectorName $connector.Name | Format-List |
        Out-File "$reportPath\03_Connectors.txt" -Append
}

# 4. Objects with sync errors
"=== Sync Errors ===" | Out-File "$reportPath\04_SyncErrors.txt"
$aadConnector = Get-ADSyncConnector | Where-Object { $_.Type -eq "Extensible2" } | Select-Object -First 1
if ($aadConnector) {
    $csErrors = Get-ADSyncCSObject -ConnectorIdentifier $aadConnector.Identifier -ErrorAction SilentlyContinue |
        Where-Object { $_.SyncError -ne $null }
    $csErrors | Select-Object DistinguishedName, SyncError | Format-List |
        Out-File "$reportPath\04_SyncErrors.txt" -Append
}

# 5. Network connectivity
"=== Network Connectivity ===" | Out-File "$reportPath\05_Network.txt"
$eps = @("login.microsoftonline.com","provisioningapi.microsoftonline.com",
         "aadcdn.msauth.net","s1.adhybridhealth.azure.com")
foreach ($ep in $eps) {
    $r = Test-NetConnection -ComputerName $ep -Port 443 -WarningAction SilentlyContinue
    "$ep :443 — $($r.TcpTestSucceeded)" | Out-File "$reportPath\05_Network.txt" -Append
}

# 6. Event logs (last 24 hours)
"=== Application Events (ADSync/Azure AD) ===" | Out-File "$reportPath\06_EventLog.txt"
$since = (Get-Date).AddHours(-24)
Get-WinEvent -LogName Application -ErrorAction SilentlyContinue |
    Where-Object {
        $_.TimeCreated -gt $since -and
        ($_.ProviderName -like "*ADSync*" -or $_.ProviderName -like "*Azure AD*")
    } |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Format-List | Out-File "$reportPath\06_EventLog.txt" -Append

# 7. Sync rules summary
"=== Sync Rules ===" | Out-File "$reportPath\07_SyncRules.txt"
Get-ADSyncRule | Select-Object Name, Direction, Precedence, EnabledState |
    Sort-Object Direction, Precedence | Format-Table -AutoSize |
    Out-File "$reportPath\07_SyncRules.txt" -Append

# 8. TLS configuration
"=== TLS Configuration ===" | Out-File "$reportPath\08_TLS.txt"
@("TLS 1.0","TLS 1.1","TLS 1.2","TLS 1.3") | ForEach-Object {
    $proto = $_
    @("Client","Server") | ForEach-Object {
        $path = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$proto\$_"
        $enabled = if (Test-Path $path) {
            (Get-ItemProperty $path -ErrorAction SilentlyContinue).Enabled
        } else { "KEY NOT PRESENT" }
        "$proto\$_`: Enabled=$enabled" | Out-File "$reportPath\08_TLS.txt" -Append
    }
}

# Compress results
Compress-Archive -Path "$reportPath\*" -DestinationPath "$reportPath.zip" -Force
Write-Host "`nEvidence collected: $reportPath.zip" -ForegroundColor Green
Write-Host "Upload this file to your support ticket." -ForegroundColor Green
```

---
## Command Cheat Sheet

| Task | Command |
|---|---|
| Check sync service | `Get-Service ADSync \| Select-Object Status, StartType` |
| Check scheduler | `Get-ADSyncScheduler` |
| Check staging mode | `Get-ADSyncGlobalSettings \| Select-Object StagingModeEnabled` |
| Disable staging mode | `Set-ADSyncGlobalSettings -StagingModeEnabled $false` |
| Run delta sync | `Start-ADSyncSyncCycle -PolicyType Delta` |
| Run initial sync | `Start-ADSyncSyncCycle -PolicyType Initial` |
| List connectors | `Get-ADSyncConnector \| Select-Object Name, Type, State` |
| Connector stats | `Get-ADSyncConnectorStatistics -ConnectorName "<name>"` |
| Find duplicate UPN | `Get-ADUser -Filter {UserPrincipalName -eq "<upn>"} \| Select-Object DN, UPN` |
| Find duplicate proxy | `Get-ADUser -Filter * -Properties ProxyAddresses \| Where-Object { $_.ProxyAddresses -contains "<smtp:x>" }` |
| Check installed version | `(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Azure AD Connect").Version` |
| Check PHS config | `Get-ADSyncAADPasswordSyncConfiguration -SourceConnector "<AD-connector-name>"` |
| Open Sync Manager | `& "C:\Program Files\Microsoft Azure Active Directory Connect\SynchronizationServiceManager.exe"` |
| Open Connect wizard | `& "C:\Program Files\Microsoft Azure Active Directory Connect\AzureADConnect.exe"` |
| Check event log | `Get-WinEvent -LogName Application -MaxEvents 50 \| Where-Object { $_.Source -like "*ADSync*" }` |
| Restart ADSync service | `Restart-Service ADSync` |
| List sync rules | `Get-ADSyncRule \| Select-Object Name, Direction, Precedence` |

---
## 🎓 Learning Pointers

- **The three-space model is the mental key.** Every sync problem maps to one of three spaces: CS (import/export staging), MV (identity join and transform), or the target directory. When you understand which space a problem lives in, the fix becomes obvious. The Synchronization Service Manager Operations tab tells you exactly which run profile phase failed. [Sync Service Manager deep dive](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/how-to-connect-sync-service-manager-ui)

- **Staging mode is the most dangerous "invisible" state in Entra Connect.** A server in staging mode looks completely healthy from the inside — sync cycles run, logs are clean, the scheduler ticks away. The only sign something is wrong is that nothing appears in Entra ID. Always check `Get-ADSyncGlobalSettings` before assuming sync is working, especially after DR exercises.

- **The ImmutableId / msDS-ConsistencyGuid relationship is frequently misunderstood.** Entra ID's `ImmutableId` attribute is the Base64-encoded version of the AD object's `msDS-ConsistencyGuid`. If that attribute is not set in AD, Connect uses the `objectGUID` instead. This is fine until you need to move or restore objects — at which point you must explicitly manage `msDS-ConsistencyGuid` to maintain continuity. [Source anchor concepts](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/plan-connect-design-concepts#sourceanchor)

- **Duplicate attribute resiliency (DAR) prevents global sync failures but hides problems.** When DAR is enabled (default), an attribute conflict doesn't stop all sync — only the conflicting object gets quarantined. This is good for availability but means conflicts can accumulate silently for weeks. Use the `Get-ADSyncCSObject` query in the Evidence Pack regularly to surface hidden errors. [DAR documentation](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/how-to-connect-syncservice-duplicate-attribute-resiliency)

- **Password Hash Sync is a replication operation, not a polling operation.** Connect doesn't periodically query AD for password hashes. Instead, DCs notify it of changes via the MS-DRSR protocol — the same mechanism used for normal DC-to-DC replication. This is why `Replicating Directory Changes All` is required at the domain level (not per-OU): it's a DC-level privilege. Missing this right means PHS silently stops working with no errors anywhere obvious.

- **Version retirements happen on a 12-month cycle and Microsoft doesn't notify admins proactively.** Build a recurring calendar task (every 6 months) to check the version history page and compare your installed version. A version past its retirement date will eventually start failing with `stopped-server` as Microsoft tightens endpoint auth requirements. [Version history](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/reference-connect-version-history)
