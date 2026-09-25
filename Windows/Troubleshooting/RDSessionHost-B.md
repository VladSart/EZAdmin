# RD Session Host & Session Collections — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.
> Covers: one session host in a collection never receiving new users (not in drain, "looks healthy"), host stuck in drain after patching, `change logon` vs Server Manager "Allow new connections" disagreeing, uneven load balancing, users getting a **temporary profile** or *"User Profile Disk could not be attached"* / UPD already-in-use, disconnected sessions not being cleaned up (or being logged off too early), and safe drain-and-reboot patching of a collection.
> RemoteApp publishing faults: `RemoteApp-B.md` · Deep dive: `RDSessionHost-A.md` · Script: `../Scripts/Get-RDSessionHostHealth.ps1` · Siblings: `RDConnectionBroker-B.md` · `RDGateway-B.md` · `RDWebAccess-B.md` · `RDSLicensing-B.md` · `RDSDeadlockSept2026-B.md` · FSLogix on RDSH: `../../Azure/AVD/FSLogix-B.md`

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run on the **Connection Broker** (elevated Windows PowerShell 5.1, `RemoteDesktop` module), then on the suspect host:

```powershell
$cb = '<broker.fqdn>'; $coll = '<CollectionName>'
Get-RDSessionHost -CollectionName $coll -ConnectionBroker $cb | Select SessionHost, NewConnectionAllowed
Get-RDUserSession -ConnectionBroker $cb -CollectionName $coll | Group-Object HostServer | Select Name, Count
(Get-RDSessionCollectionConfiguration -CollectionName $coll -ConnectionBroker $cb -LoadBalancing) | Select SessionHost, RelativeWeight, SessionLimit
Get-RDSessionCollectionConfiguration -CollectionName $coll -ConnectionBroker $cb -UserProfileDisk | Select EnableUserProfileDisk, DiskPath, MaxUserProfileDiskSizeGB
# On the suspect RDSH:
Invoke-Command -ComputerName <rdsh.fqdn> { change logon /query; Get-Service TermService, SessionEnv, UmRdpService | Select Name, Status }
```

| Result | Meaning | Go to |
|---|---|---|
| `NewConnectionAllowed` = `No` or `NotUntilReboot` | Host is drained at the **broker** level | Fix 1 |
| Broker says `Yes`, but `change logon /query` says logons **disabled** / drain | Local WinStation drain (`change logon /drain`, left over from patching/script) — broker still routes, host refuses | Fix 2 |
| Broker `Yes`, local enabled, host still gets 0 sessions while others are full | Load-balancing weight/limit, stale broker registration, or host rejecting redirect | Fix 3 |
| One host has far more sessions than its peers | `RelativeWeight` skewed, or users reconnecting to their disconnected sessions there (expected) | Fix 3 |
| Users get **TEMP** profile / Event 1511/1515, or UPD attach error | UPD share permission, UPD VHDX locked on another host, or disk full | Fix 4 |
| Disconnected sessions pile up / users logged off unexpectedly | Collection session limits vs GPO time-limit precedence | Fix 5 |
| Need to patch the collection without kicking users mid-work | Drain → message → logoff → reboot → undrain | Fix 6 |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
User lands on a session host in collection <Coll>
└── Broker (Tssdis) picks a host
    ├── Existing (disconnected) session for this user? → reconnect to THAT host (overrides LB)
    └── Else load-balance across hosts where:
        ├── Host is a member of the collection (Get-RDSessionHost)
        ├── NewConnectionAllowed = Yes                  (broker-level drain flag)
        ├── Sessions on host < SessionLimit              (per-host, collection LB config)
        └── Lowest (sessions / RelativeWeight) wins
└── Broker redirects client → RDSH:3389
    └── RDSH accepts the connection
        ├── TermService / SessionEnv / UmRdpService running
        ├── Local logons enabled (change logon /query ≠ drain/disable)   (host-level drain flag)
        ├── Remote Desktop Users / collection user group allows the user
        ├── RDSH can reach a license server (RDSLicensing-B.md)
        └── User profile loads
            ├── UPD enabled? → \\server\share\UVHD-<SID>.vhdx attaches (NOT mounted on any other host)
            │     └── Every RDSH computer account has Full Control on share + NTFS
            ├── FSLogix? → see FSLogix-B.md (never run UPD and FSLogix together)
            └── Else local/roaming profile → User Profile Service
└── Session lifetime governed by
    ├── GPO: Computer\...\Remote Desktop Session Host\Session Time Limits   (wins if set)
    └── Collection: DisconnectedSessionLimitMin / IdleSessionLimitMin / BrokenConnectionAction
```
</details>

---
## Diagnosis & Validation Flow

1. **Confirm the broker drain flag.**
   `Get-RDSessionHost -CollectionName $coll -ConnectionBroker $cb`
   Expected: every host `NewConnectionAllowed : Yes`. `NotUntilReboot` means someone drained for patching and the host has **not rebooted since** — it flips back to `Yes` only after a restart.

2. **Confirm the local drain flag on the host.**
   `Invoke-Command -ComputerName <rdsh> { change logon /query }`
   Expected: *"Session logins are currently ENABLED"*. Any *DRAIN* or *DISABLED* text means the host will refuse redirected users even though the broker still sends them there — users see a slow connect then land elsewhere (or fail if all hosts refuse). The broker does **not** read this flag.

3. **Check the host is actually a registered, reachable collection member.**
   `Get-RDServer -ConnectionBroker $cb -Role RDS-RD-SERVER` and `Test-NetConnection <rdsh> -Port 3389`
   Expected: host listed; `TcpTestSucceeded : True`. Missing = was removed from the deployment (Fix 3).

4. **Look at session distribution vs LB config.**
   Compare `Get-RDUserSession ... | Group HostServer` with `-LoadBalancing` output. Expected: roughly proportional to `RelativeWeight`, none at `SessionLimit`. Disconnected sessions **count** toward the host's total.

5. **Check what the host logged for failed attempts.**
   ```powershell
   Get-WinEvent -ComputerName <rdsh> -LogName 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational' -MaxEvents 50 |
     Select TimeCreated, Id, Message | Format-Table -Wrap
   Get-WinEvent -ComputerName <rdsh> -LogName 'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational' -MaxEvents 30 |
     Where Id -in 1149,1158,261 | Select TimeCreated, Id, Message
   ```
   Good: 1149 (auth OK) → LSM 21/22 (logon/shell start). 1149 with no following 21 = the session was rejected or never built on this host.

6. **Profile issues:** `Get-WinEvent -ComputerName <rdsh> -LogName 'Microsoft-Windows-User Profile Service/Operational' -MaxEvents 30` and Application log IDs **1511** (temp profile), **1515**, **1500/1508**. Then check the UPD share (Fix 4).

---
## Common Fix Paths

<details><summary>Fix 1 — Host drained at the broker (NewConnectionAllowed = No / NotUntilReboot)</summary>

```powershell
Set-RDSessionHost -SessionHost <rdsh.fqdn> -NewConnectionAllowed Yes -ConnectionBroker <broker.fqdn>
Get-RDSessionHost -CollectionName <Coll> -ConnectionBroker <broker.fqdn> | Where SessionHost -eq '<rdsh.fqdn>'
```
Equivalent to Server Manager → Collection → Host Servers → right-click → **Allow New Connections**. Always pass the FQDN exactly as it appears in `Get-RDSessionHost`; a short name returns *"not part of the collection"*.
If it keeps returning to `No` after nightly reboots, find the scheduled task / RMM script that drains it (Task Scheduler on the broker and host, search scripts for `NewConnectionAllowed`).
</details>

<details><summary>Fix 2 — Local host drain left enabled (change logon)</summary>

```powershell
Invoke-Command -ComputerName <rdsh.fqdn> { change logon /enable; change logon /query }
```
`change logon /drain` and `/drainuntilrestart` are local WinStation settings — used by patching tools, WSUS/ConfigMgr scripts, or engineers on the console. They survive until explicitly re-enabled (`/drain`) or next boot (`/drainuntilrestart`). The broker has **no** view of them, which is the classic "healthy host that gets no users".
Standardise on **one** drain mechanism (the broker one, Fix 6) so this cannot drift.
</details>

<details><summary>Fix 3 — Host gets no/too many users (load balancing & membership)</summary>

```powershell
$cb='<broker.fqdn>'; $coll='<Coll>'
# View
$lb = Get-RDSessionCollectionConfiguration -CollectionName $coll -ConnectionBroker $cb -LoadBalancing
$lb | Select SessionHost, RelativeWeight, SessionLimit
# Reset every host to equal weight and a sane limit
foreach ($h in $lb) { $h.RelativeWeight = 100; $h.SessionLimit = <MaxSessionsPerHost> }
Set-RDSessionCollectionConfiguration -CollectionName $coll -ConnectionBroker $cb -LoadBalancing $lb
```
- Weight `0`/tiny or `SessionLimit` = current session count → host is effectively skipped.
- Host heavy because of **reconnects** is expected: disconnected users always return to their own host. Log off stale disconnected sessions (Fix 5) to rebalance.
- Host missing from `Get-RDSessionHost`: re-add — `Add-RDSessionHost -CollectionName $coll -SessionHost <rdsh.fqdn> -ConnectionBroker $cb` (host must already be an `RDS-RD-SERVER` in the deployment: `Add-RDServer -Server <rdsh.fqdn> -Role RDS-RD-SERVER -ConnectionBroker $cb`).
- Stale registration after a rename/rebuild: the Q&A-reported "toggle drain on/off fixes it" symptom points here — `Set-RDSessionHost ... No` then `... Yes` re-writes the broker record. If it recurs nightly, remove and re-add the host (`Remove-RDSessionHost` / `Add-RDSessionHost`) in a maintenance window.
</details>

<details><summary>Fix 4 — Temp profile / User Profile Disk won't attach</summary>

```powershell
$share = (Get-RDSessionCollectionConfiguration -CollectionName <Coll> -ConnectionBroker <broker.fqdn> -UserProfileDisk).DiskPath
$sid = (New-Object System.Security.Principal.NTAccount('<DOMAIN\user>')).Translate([System.Security.Principal.SecurityIdentifier]).Value
Get-Item (Join-Path $share "UVHD-$sid.vhdx") | Select FullName, Length, LastWriteTime
Get-SmbOpenFile -CimSession <fileserver> | Where Path -like "*UVHD-$sid*" | Select ClientComputerName, ClientUserName, Path
(Get-Acl $share).Access | Select IdentityReference, FileSystemRights
```
| Finding | Action |
|---|---|
| Open handle from **another** RDSH | User has a live/disconnected session there. Log it off (`Invoke-RDUserLogoff -HostServer <otherHost> -UnifiedSessionID <id> -Force`). If the host is dead/hung, close the handle: `Close-SmbOpenFile -CimSession <fileserver> -FileId <id> -Force` **(data in that session is lost)** |
| RDSH computer accounts lack **Full Control** on share/NTFS | Re-apply: Server Manager → Collection → Tasks → Edit Properties → User Profile Disks (re-save sets the ACLs), or grant each `DOMAIN\RDSH$` Full Control |
| VHDX at `MaxUserProfileDiskSizeGB`, or file server volume full | Free space / grow the disk (A runbook, Playbook 4). Growing the collection maximum does not grow existing disks |
| `UVHD-template.vhdx` missing | Re-save UPD settings in collection properties to regenerate it |

**Rollback / safety:** never delete a `UVHD-<SID>.vhdx` to "fix" a user — that is their entire profile. Rename it (`.bak`) so it can be restored.
</details>

<details><summary>Fix 5 — Disconnected/idle session limits not behaving</summary>

```powershell
Get-RDSessionCollectionConfiguration -CollectionName <Coll> -ConnectionBroker <broker.fqdn> -Connection |
  Select DisconnectedSessionLimitMin, IdleSessionLimitMin, ActiveSessionLimitMin, BrokenConnectionAction, AutomaticReconnectionEnabled
Invoke-Command -ComputerName <rdsh.fqdn> { gpresult /scope computer /v | Select-String 'Session Time Limits' -Context 0,6 }
Set-RDSessionCollectionConfiguration -CollectionName <Coll> -ConnectionBroker <broker.fqdn> -DisconnectedSessionLimitMin 120 -BrokenConnectionAction LogOffSession
```
A GPO under *Computer Configuration → Administrative Templates → Windows Components → Remote Desktop Services → Remote Desktop Session Host → Session Time Limits* **overrides** the collection value. If the GPO is set, change it there. Existing sessions pick up new limits on next connect.
</details>

<details><summary>Fix 6 — Safe drain-and-reboot for patching</summary>

```powershell
$cb='<broker.fqdn>'; $h='<rdsh.fqdn>'; $coll='<Coll>'
Set-RDSessionHost -SessionHost $h -NewConnectionAllowed NotUntilReboot -ConnectionBroker $cb   # auto-undrains on reboot
Get-RDUserSession -ConnectionBroker $cb -CollectionName $coll | Where HostServer -eq $h |
  ForEach-Object { Send-RDUserMessage -HostServer $h -UnifiedSessionID $_.UnifiedSessionId -MessageTitle 'Maintenance' -MessageBody 'Please save your work and sign out within 30 minutes.' }
# ... wait ...
Get-RDUserSession -ConnectionBroker $cb -CollectionName $coll | Where HostServer -eq $h |
  ForEach-Object { Invoke-RDUserLogoff -HostServer $h -UnifiedSessionID $_.UnifiedSessionId -Force }
Restart-Computer -ComputerName $h -Wait -For PowerShell -Timeout 1800 -Force
Get-RDSessionHost -CollectionName $coll -ConnectionBroker $cb | Where SessionHost -eq $h   # expect Yes
```
Do hosts one at a time (or in rings) so capacity stays above peak. If a host comes back still `No`, it was drained with `No` rather than `NotUntilReboot` → Fix 1.
</details>

---
## Escalation Evidence

```
RDSH / Collection escalation
Deployment broker(s):            <broker.fqdn> (HA: yes/no)
Collection:                      <Coll>   Hosts: <n>   OS build(s): <e.g. 20348.xxxx>
Affected host(s):                <rdsh.fqdn>
Broker NewConnectionAllowed:     <Yes/No/NotUntilReboot>
change logon /query:             <ENABLED / DRAIN / DISABLED>
Sessions per host:               <host=count, ...>
LB RelativeWeight / SessionLimit:<host=w/l, ...>
UPD enabled / path / max GB:     <yes/no> <\\server\share> <n>
Symptom start (UTC) + last change (patch/GPO/rebuild): <...>
Event IDs seen (LSM / RCM / Profile / App 1511): <...>
Get-RDSessionHostHealth.ps1 CSV attached: <yes/no>
Steps already tried:             <Fix n ...>
```

---
## 🎓 Learning Pointers
- There are **two independent drain switches**: the broker's `NewConnectionAllowed` (what Server Manager shows) and the host's local `change logon` state (what the host enforces). Most "host gets no users" tickets are these two disagreeing. [Set-RDSessionHost](https://learn.microsoft.com/en-us/powershell/module/remotedesktop/set-rdsessionhost) · [change logon](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/change-logon)
- Prefer `NotUntilReboot` for patching — it removes the "forgot to undrain" failure mode entirely.
- Reconnection always beats load balancing: an overloaded host is often full of *disconnected* sessions, so session time limits are a load-balancing tool too.
- A UPD is a per-user VHDX that can be mounted by **one** host at a time; a lingering disconnected session elsewhere is the #1 cause of temp profiles. For new builds, Microsoft recommends FSLogix over UPD — see `../../Azure/AVD/FSLogix-A.md`.
- Session Time Limits GPOs silently override collection properties — always check `gpresult` before editing the collection. (Policy lives in `TerminalServer.admx` → *Session Time Limits*.)
