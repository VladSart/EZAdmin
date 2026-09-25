# RD Session Host & Session Collections — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.
> Hotfix: `RDSessionHost-B.md` · Script: `../Scripts/Get-RDSessionHostHealth.ps1` · Siblings: `RDConnectionBroker-A.md` (routing/DB), `RDGateway-A.md`, `RDWebAccess-A.md`, `RDSLicensing-A.md` · Profiles: `../../Azure/AVD/FSLogix-A.md`

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
- **In scope:** session-based desktop/RemoteApp collections on Windows Server 2016–2025 managed by an RDS deployment (Server Manager / `RemoteDesktop` module): host membership, the two drain mechanisms, broker load balancing, collection connection/session settings vs Group Policy, User Profile Disks (UPD), user session operations, and patch-window orchestration.
- **Out of scope:** broker HA/database (`RDConnectionBroker-A.md`), Gateway/Web (`RDGateway-A.md`, `RDWebAccess-A.md`), CALs (`RDSLicensing-A.md`), FSLogix internals (`FSLogix-A.md`), Azure Virtual Desktop host pools (different control plane — `Set-AzWvdSessionHost -AllowNewSession`), and client-side RDP (`RDP-A.md`).
- Commands assume elevated Windows PowerShell 5.1 on a broker (or a management box with the `RemoteDesktop` module and rights on the deployment). `<placeholders>` are user values.

---
## How It Works
<details><summary>Full architecture</summary>

### Objects
```
RDS Deployment (owned by the Connection Broker DB)
├── Servers:   RDS-CONNECTION-BROKER, RDS-RD-SERVER, RDS-WEB-ACCESS, RDS-GATEWAY, RDS-LICENSING
└── Session collections (1..n)
      ├── Member hosts (each RDS-RD-SERVER belongs to at most ONE collection)
      ├── User groups (who may use the collection)
      ├── Connection settings  (session limits, broken-connection action, auto-reconnect)
      ├── Security settings    (NLA, encryption level, security layer)
      ├── Load-balancing config (per host: RelativeWeight, SessionLimit)
      ├── Client settings      (redirection: drives, clipboard, printers, ...)
      ├── User Profile Disk config (enable, share path, max size, include/exclude)
      └── Published RemoteApps (for RemoteApp collections)
```
Collection settings are **stored in the broker DB and pushed to the hosts** by RDMS as local policy-equivalent registry values. They behave like a low-precedence policy: a domain GPO touching the same setting wins, and Server Manager will still display the collection value — the root of many "the setting says X but hosts do Y" cases.

### The connection path (session collection)
```
Client ──(.rdp from RD Web: full address = broker/CAN, loadbalanceinfo:s:tsv://MS Terminal Services Plugin.1.<Coll>)──►
  Broker (Tssdis)
    1. Resolve collection from loadbalanceinfo
    2. Does user have a session (active/disconnected) in this collection?  → YES: target = that host
    3. NO: candidate hosts = members where NewConnectionAllowed=Yes AND sessions < SessionLimit
           choose host with lowest load, weighted by RelativeWeight
    4. Send redirection (host + routing token) to the client
Client ──► RDSH:3389 with routing token
  RDSH
    5. TermService accepts (if local logons enabled)
    6. SessionBroker-Client on RDSH reports "session created/logon" back to Tssdis
    7. Winlogon → profile (UPD attach / FSLogix / local) → shell or RemoteApp
```
The broker **only** knows the drain flag it stores (`NewConnectionAllowed`). The host's own `change logon` state is invisible to it, which is why a locally drained host keeps getting routed to and refusing users.

### Two drain mechanisms
| Mechanism | Where stored | Values | Who reads it | Survives reboot |
|---|---|---|---|---|
| Broker drain — `Set-RDSessionHost -NewConnectionAllowed` / Server Manager "Allow New Connections" | Broker DB | `Yes`, `No`, `NotUntilReboot` | Broker when choosing a host | `No`: yes. `NotUntilReboot`: resets to `Yes` after the host restarts |
| Local drain — `change logon` (`chglogon.exe`) | Host WinStation config | `/enable`, `/disable`, `/drain`, `/drainuntilrestart` | TermService on that host | `/drain` and `/disable`: yes. `/drainuntilrestart`: no |

In drain, **reconnection to existing sessions is still allowed**; only new sessions are blocked. `/disable` blocks all remote logons, including reconnects.

### Load balancing
The broker compares hosts by current session count (active **and** disconnected) relative to `RelativeWeight`, skipping any host at `SessionLimit`. Weights are relative (100/100/50 → third host gets about half the share). There is no CPU/memory awareness in classic RDS load balancing — heavy users on a host do not steer new users away. Separately, the host uses **Dynamic Fair Share Scheduling** (CPU, disk, network) to stop one session starving others; it can be turned off by GPO ("Turn off Fair Share CPU Scheduling") but rarely should be.

### User Profile Disks
- Each user gets `UVHD-<SID>.vhdx` on the collection share, cloned from `UVHD-template.vhdx`. At logon the host mounts it and junctions it into `C:\Users\<user>` (whole profile, or include/exclude list).
- A VHDX can be attached by **one** host at a time. If the user still has a session (even disconnected) on another host, or a host crashed with the disk mounted, the new logon cannot attach it → temporary profile.
- The share needs **Full Control for every RDSH computer account** (share + NTFS). Server Manager sets this when UPD is configured; adding a host later, restoring the share, or migrating the file server often drops it.
- Changing the collection max size affects **new** disks only.
- UPD is tied to one collection — a user in two collections has two independent disks. FSLogix is Microsoft's recommended profile container for new designs; never enable UPD and FSLogix together on the same host.

### Session limits precedence
```
Domain GPO (Computer, RDS\RDSH\Session Time Limits)   ← wins
User GPO (same node, User config)                     ← applied if computer setting not configured
Collection properties (pushed as local config)        ← only if no GPO
Default: never time out
```
</details>

---
## Dependency Stack
```
[7] User experience: desktop/RemoteApp, redirected resources
[6] Profile: UPD (share ACL, VHDX unlocked, space) | FSLogix | local
[5] Logon: Winlogon, GPO processing, collection user group, Remote Desktop Users
[4] RDSH acceptance: TermService/SessionEnv/UmRdpService, local logons enabled, licensing (grace or CAL server)
[3] Redirection: client can reach RDSH:3389 (direct or via RD Gateway)
[2] Broker selection: host in collection, NewConnectionAllowed=Yes, < SessionLimit, weight>0, existing session lookup
[1] Deployment: broker DB healthy, host registered as RDS-RD-SERVER, AD computer object/DNS correct
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| One host never gets new users, looks healthy | Local `change logon /drain` left set; or LB weight 0/limit reached | `change logon /query`; `-LoadBalancing` |
| Host stays drained after patch reboot | Drained with `No` instead of `NotUntilReboot`; nightly script re-drains | `Get-RDSessionHost`; Task Scheduler |
| Toggling drain off/on "fixes" a host until next reboot | Stale host record in broker DB / host rebuilt with same name | Remove + re-add host (Playbook 2) |
| Users all piling on one host | Unequal weights; reconnects to disconnected sessions; other hosts drained | Sessions per host incl. disconnected |
| Temp profile (App 1511) on RDSH | UPD VHDX in use on another host, share ACL missing, disk/volume full | `Get-SmbOpenFile`; share ACL |
| "Could not attach user profile disk" | As above, or UPD share unreachable (SMB/DFS path) | `Test-Path` from host as SYSTEM |
| Disconnected sessions never logged off | No limit configured, or GPO sets "Never" | `-Connection` config; `gpresult` |
| Users logged off after short idle | GPO idle/disconnect limit lower than expected | `gpresult /scope computer` |
| Collection changes in Server Manager "don't apply" | GPO overriding same setting; RDMS can't reach host (WinRM) | `gpresult`; `Test-WSMan <host>` |
| "The connection was denied because the user account is not authorized for remote login" | User not in collection user group / Remote Desktop Users on host | Collection `-UserGroup`; local group |
| New host added but never used | Not added to collection (only to deployment) | `Get-RDSessionHost -CollectionName` |

---
## Validation Steps
1. **Membership:** `Get-RDSessionHost -CollectionName <Coll> -ConnectionBroker <cb>` → every intended host listed. Bad: host missing, or present in `Get-RDServer -Role RDS-RD-SERVER` but no collection.
2. **Broker drain:** same output → `NewConnectionAllowed : Yes`. Bad: `No`/`NotUntilReboot` outside a maintenance window.
3. **Local drain:** `Invoke-Command <host> { change logon /query }` → *ENABLED*. Bad: *DRAIN*, *DRAINUNTILRESTART*, *DISABLED*.
4. **Services:** `Get-Service TermService,SessionEnv,UmRdpService -ComputerName <host>` → Running. Bad: stopped or stuck `StopPending` (see `RDSDeadlockSept2026-B.md` if after the Sept 2026 CU).
5. **Reachability:** `Test-NetConnection <host> -Port 3389` from broker (and gateway) → `True`.
6. **LB:** `-LoadBalancing` → weights non-zero, `SessionLimit` above expected peak per host.
7. **Session limits:** `-Connection` values match design and `gpresult` shows no conflicting Session Time Limits (or matches).
8. **UPD (if enabled):** `-UserProfileDisk` → `DiskPath` reachable; `UVHD-template.vhdx` exists; ACL has each `DOMAIN\HOST$` Full Control; free space > (users × max size) headroom.
9. **Licensing:** `Get-RDLicenseConfiguration -ConnectionBroker <cb>` → mode + server set (`RDSLicensing-A.md`).

---
## Troubleshooting Steps (by phase)
**Phase 1 — Is the broker sending users to the host?** Check LSM/RCM logs on the host for any 1149 events in the window. None at all → broker isn't selecting it (membership, drain, weight, limit). Present → phase 2.

**Phase 2 — Is the host accepting?** 1149 followed by no LSM 21/22 → local drain/disable, service issue, or authorization. Check `change logon /query`, `TerminalServices-RemoteConnectionManager/Admin`, and whether the user is in the collection group.

**Phase 3 — Is logon completing?** LSM 21 but user reports black screen/temp profile → profile layer. Check User Profile Service operational log, App 1511/1515, UPD handle locks, `Microsoft-Windows-VHDMP-Operational` for attach failures.

**Phase 4 — Is session lifetime right?** Compare collection `-Connection` values with RSoP. Remember existing sessions keep their old limits until reconnect.

**Phase 5 — Distribution over time.** Run the script daily; a host whose session count stays at 0 while others climb, after phases 1–4 pass, is a stale broker record (Playbook 2).

---
## Remediation Playbooks

<details><summary>Playbook 1 — Normalise drain state across the collection</summary>

```powershell
$cb='<broker.fqdn>'; $coll='<Coll>'
$hosts = Get-RDSessionHost -CollectionName $coll -ConnectionBroker $cb
foreach ($h in $hosts) {
    $local = Invoke-Command -ComputerName $h.SessionHost { (change logon /query) -join ' ' }
    [pscustomobject]@{ Host=$h.SessionHost; Broker=$h.NewConnectionAllowed; Local=$local }
}
# Fix: enable locally, then set broker flag
Invoke-Command -ComputerName <rdsh.fqdn> { change logon /enable }
Set-RDSessionHost -SessionHost <rdsh.fqdn> -NewConnectionAllowed Yes -ConnectionBroker $cb
```
Then remove `change logon /drain` from any patch scripts and standardise on the broker flag (`NotUntilReboot`).
</details>

<details><summary>Playbook 2 — Remove and re-add a host with a stale broker record</summary>

Maintenance window; drain and log off the host first (Playbook 5).
```powershell
$cb='<broker.fqdn>'; $coll='<Coll>'; $h='<rdsh.fqdn>'
$lbBefore = Get-RDSessionCollectionConfiguration -CollectionName $coll -ConnectionBroker $cb -LoadBalancing   # record weights
Remove-RDSessionHost -SessionHost $h -ConnectionBroker $cb -Force
Add-RDSessionHost -CollectionName $coll -SessionHost $h -ConnectionBroker $cb
# Re-apply the host's LB weight/limit
$lb = Get-RDSessionCollectionConfiguration -CollectionName $coll -ConnectionBroker $cb -LoadBalancing
($lb | Where SessionHost -eq $h).RelativeWeight = <weight>; ($lb | Where SessionHost -eq $h).SessionLimit = <limit>
Set-RDSessionCollectionConfiguration -CollectionName $coll -ConnectionBroker $cb -LoadBalancing $lb
```
**Rollback:** if `Add-RDSessionHost` fails, the host is still an `RDS-RD-SERVER` in the deployment; fix WinRM/DNS and retry — no user data is touched. Published RemoteApps are collection-level and are not lost.
</details>

<details><summary>Playbook 3 — Rebalance load</summary>

1. Set equal weights and a realistic `SessionLimit` (Fix 3 in the B runbook).
2. Set a disconnected-session limit so abandoned sessions stop pinning users to hosts: `Set-RDSessionCollectionConfiguration -CollectionName <Coll> -ConnectionBroker <cb> -DisconnectedSessionLimitMin 120 -BrokenConnectionAction LogOffSession` (or the GPO equivalent if a GPO owns it).
3. For an immediate rebalance, drain the heavy host with `NotUntilReboot` and let natural logoffs move users over; avoid forced logoffs in hours.
</details>

<details><summary>Playbook 4 — User Profile Disk recovery</summary>

**Locked disk (in use elsewhere):**
```powershell
$sid = (New-Object System.Security.Principal.NTAccount('<DOMAIN\user>')).Translate([System.Security.Principal.SecurityIdentifier]).Value
Get-RDUserSession -ConnectionBroker <cb> | Where UserName -eq '<user>' | Select HostServer, UnifiedSessionId, SessionState
Invoke-RDUserLogoff -HostServer <host> -UnifiedSessionID <id> -Force
# Host dead/hung and handle still open on file server (last resort — unsaved session data lost):
Get-SmbOpenFile -CimSession <fileserver> | Where Path -like "*UVHD-$sid*" | Close-SmbOpenFile -Force
```
**Missing ACL:** grant each host's computer account Full Control on share and folder:
```powershell
$path='<D:\UPD>'; $acl=Get-Acl $path
foreach ($h in '<RDSH01$>','<RDSH02$>') {
  $rule = New-Object System.Security.AccessControl.FileSystemAccessRule("<DOMAIN>\$h",'FullControl','ContainerInherit,ObjectInherit','None','Allow')
  $acl.AddAccessRule($rule) }
Set-Acl $path $acl
```
**Disk full (user's VHDX at max):** with the user logged off, on the file server (Hyper-V module / or `diskpart`):
```powershell
Resize-VHD -Path '<\\server\share\UVHD-SID.vhdx>' -SizeBytes <NewSize>GB   # needs Hyper-V PowerShell module on the file server
# Then mount and extend the partition:
$d = Mount-VHD -Path '<path>' -Passthru | Get-Disk; $p = $d | Get-Partition | Where Type -eq 'Basic'
$p | Resize-Partition -Size ($p | Get-PartitionSupportedSize).SizeMax; Dismount-VHD -Path '<path>'
```
**Rollback:** copy the VHDX before resizing. Never delete a user's VHDX; rename to `.bak` to force a fresh profile, keep the old one for data recovery.

**Moving to FSLogix:** disable UPD on the collection only after profiles are migrated (FSLogix `frx.exe migrate-vhd` / third-party tooling). See `FSLogix-A.md`.
</details>

<details><summary>Playbook 5 — Patch-window orchestration (rolling)</summary>

```powershell
$cb='<broker.fqdn>'; $coll='<Coll>'; $warnMin = 30
$hosts = (Get-RDSessionHost -CollectionName $coll -ConnectionBroker $cb).SessionHost
foreach ($h in $hosts) {
  Set-RDSessionHost -SessionHost $h -NewConnectionAllowed NotUntilReboot -ConnectionBroker $cb
  Get-RDUserSession -ConnectionBroker $cb -CollectionName $coll | Where HostServer -eq $h | ForEach-Object {
    Send-RDUserMessage -HostServer $h -UnifiedSessionID $_.UnifiedSessionId -MessageTitle 'Maintenance' -MessageBody "Sign out within $warnMin minutes." }
  Start-Sleep -Seconds ($warnMin*60)
  Get-RDUserSession -ConnectionBroker $cb -CollectionName $coll | Where HostServer -eq $h | ForEach-Object {
    Invoke-RDUserLogoff -HostServer $h -UnifiedSessionID $_.UnifiedSessionId -Force }
  # install updates here (WSUS/ConfigMgr/Intune trigger) then:
  Restart-Computer -ComputerName $h -Wait -For PowerShell -Timeout 1800 -Force
  if ((Get-RDSessionHost -CollectionName $coll -ConnectionBroker $cb | Where SessionHost -eq $h).NewConnectionAllowed -ne 'Yes') {
    Write-Warning "$h did not undrain"; break }
}
```
Keep capacity: process one host (or one ring) at a time, and stop the loop on the first failure. The Sept 2026 CU TermService hang (`RDSDeadlockSept2026-A.md`) is a known reason a host comes back unable to accept sessions.
</details>

---
## Evidence Pack
```powershell
# Run on a broker. Output: C:\Temp\RDSH-Evidence-<timestamp>\
$cb='<broker.fqdn>'; $coll='<Coll>'
$out = "C:\Temp\RDSH-Evidence-$(Get-Date -f yyyyMMdd-HHmm)"; New-Item $out -ItemType Directory -Force | Out-Null
Get-RDServer -ConnectionBroker $cb | Export-Csv "$out\servers.csv" -NoTypeInformation
Get-RDSessionCollection -ConnectionBroker $cb | Export-Csv "$out\collections.csv" -NoTypeInformation
Get-RDSessionHost -CollectionName $coll -ConnectionBroker $cb | Export-Csv "$out\hosts.csv" -NoTypeInformation
Get-RDUserSession -ConnectionBroker $cb -CollectionName $coll | Export-Csv "$out\sessions.csv" -NoTypeInformation
foreach ($sw in 'LoadBalancing','Connection','UserProfileDisk','Security','Client') {
  $p = @{ CollectionName=$coll; ConnectionBroker=$cb; $sw=$true }
  Get-RDSessionCollectionConfiguration @p | Export-Clixml "$out\config-$sw.xml" }
foreach ($h in (Get-RDSessionHost -CollectionName $coll -ConnectionBroker $cb).SessionHost) {
  Invoke-Command -ComputerName $h {
    [pscustomobject]@{ Host=$env:COMPUTERNAME; Logon=((change logon /query) -join ' ')
      Services=((Get-Service TermService,SessionEnv,UmRdpService | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ';')
      LastBoot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime }
  } | Export-Csv "$out\host-state.csv" -Append -NoTypeInformation
  foreach ($log in 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational','Microsoft-Windows-User Profile Service/Operational') {
    try { Get-WinEvent -ComputerName $h -LogName $log -MaxEvents 200 |
      Select @{n='Host';e={$h}}, TimeCreated, Id, LevelDisplayName, Message |
      Export-Csv "$out\events-$($h.Split('.')[0])-$(($log -split '[-/]')[-2]).csv" -NoTypeInformation } catch {}
  }
  Invoke-Command -ComputerName $h { gpresult /scope computer /x "C:\Windows\Temp\rsop.xml" /f } ; Copy-Item "\\$h\C$\Windows\Temp\rsop.xml" "$out\rsop-$($h.Split('.')[0]).xml" -ErrorAction SilentlyContinue
}
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force; "Evidence: $out.zip"
```

---
## Command Cheat Sheet
| Task | Command |
|---|---|
| List hosts + drain | `Get-RDSessionHost -CollectionName <Coll> -ConnectionBroker <cb>` |
| Drain until reboot | `Set-RDSessionHost -SessionHost <h> -NewConnectionAllowed NotUntilReboot -ConnectionBroker <cb>` |
| Undrain | `Set-RDSessionHost -SessionHost <h> -NewConnectionAllowed Yes -ConnectionBroker <cb>` |
| Local drain state | `change logon /query` · enable: `change logon /enable` |
| Sessions | `Get-RDUserSession -ConnectionBroker <cb> -CollectionName <Coll>` |
| Message a user | `Send-RDUserMessage -HostServer <h> -UnifiedSessionID <id> -MessageTitle <t> -MessageBody <b>` |
| Log off | `Invoke-RDUserLogoff -HostServer <h> -UnifiedSessionID <id> -Force` |
| Disconnect | `Disconnect-RDUser -HostServer <h> -UnifiedSessionID <id> -Force` |
| LB config | `Get-RDSessionCollectionConfiguration -CollectionName <Coll> -ConnectionBroker <cb> -LoadBalancing` |
| Session limits | `... -Connection` / `Set-RDSessionCollectionConfiguration -DisconnectedSessionLimitMin <n>` |
| UPD config | `... -UserProfileDisk` |
| Add host to collection | `Add-RDSessionHost -CollectionName <Coll> -SessionHost <h> -ConnectionBroker <cb>` |
| Remove host | `Remove-RDSessionHost -SessionHost <h> -ConnectionBroker <cb>` |
| Local sessions on a host | `quser /server:<h>` · `qwinsta /server:<h>` |
| UPD file locks | `Get-SmbOpenFile -CimSession <fs> \| Where Path -like '*UVHD-*'` |

---
## 🎓 Learning Pointers
- The broker routes on data in its database; the host enforces its own WinStation state. Keeping those in agreement is most of RDSH operations. [Set-RDSessionHost](https://learn.microsoft.com/en-us/powershell/module/remotedesktop/set-rdsessionhost) · [change logon](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/change-logon)
- Collection properties are effectively local policy pushed by RDMS — domain GPO always wins. Design so each setting has exactly one owner. [Set-RDSessionCollectionConfiguration](https://learn.microsoft.com/en-us/powershell/module/remotedesktop/set-rdsessioncollectionconfiguration)
- Classic RDS load balancing is session-count based, not resource based — size `SessionLimit` from real per-user resource usage, and use Dynamic Fair Share to protect users on a busy host.
- UPD's single-attach design makes it fragile in multi-host collections; FSLogix is Microsoft's recommended replacement. [FSLogix overview](https://learn.microsoft.com/en-us/fslogix/overview-what-is-fslogix)
- If you're weighing RDS against Azure Virtual Desktop, the drain concept maps to AVD's `AllowNewSession` on a host pool session host — same operational idea, different control plane. See `../../Azure/AVD/`.
