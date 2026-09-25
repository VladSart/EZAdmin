# RemoteApp Publishing (RDS Session Collections) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.
> Ops version: `RemoteApp-B.md` · Script: `../Scripts/Get-RemoteAppPublishingAudit.ps1` · Related: `RDSessionHost-A.md` · `RDWebAccess-A.md` · `RDConnectionBroker-A.md` · `RDGateway-A.md` · AVD equivalent: `../../Azure/AVD/AVD-A.md`

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
- **In scope:** RemoteApp programs published in RDS **session collections** on Windows Server 2016–2025, managed through the `RemoteDesktop` PowerShell module / Server Manager; delivery via RD Web Access, the RemoteApp and Desktop Connections (RADC) feed, Windows App, and `.rdp` files; file-type associations; command-line policy; RemoteApp session lifetime.
- **Out of scope:** app *visibility* in RD Web (collection `UserGroup` ∩ RemoteApp `UserGroups`, `ShowInWebAccess` — see `RDWebAccess-A.md`), host drain/load balancing/UPD (`RDSessionHost-A.md`), broker HA (`RDConnectionBroker-A.md`), gateway (`RDGateway-A.md`), AVD RemoteApp application groups (`AVD-A.md`), legacy Server 2008 R2 RemoteApp Manager / standalone `TSAppAllowList` publishing (mentioned only for context).
- Commands run elevated in Windows PowerShell 5.1 on the Connection Broker (active management server in HA) unless stated.

---
## How It Works
<details><summary>Full architecture</summary>

### 1. Publishing is metadata only
`New-RDRemoteApp` writes a record into the broker's publishing store (RDCms / the deployment database, served by the `TScPubRPC` "RemoteApp and Desktop Connection Management" service). The record contains:

| Property | Purpose |
|---|---|
| `Alias` | Unique key within the collection. What the client actually asks for. Immutable in practice. |
| `DisplayName` | Label in RD Web / feed / Start menu. |
| `FilePath` | Path the **session host** executes. Not validated per host. |
| `FileVirtualPath` | Path as shown/used for icon lookup; usually = `FilePath`, may use env vars. |
| `CommandLineSetting` | `Allow` (client args passed), `DoNotAllow` (stripped), `Require` (use `RequiredCommandLine`, ignore client). |
| `RequiredCommandLine` | Fixed arguments when `Require`. |
| `IconPath` / `IconIndex` | Icon source, read at publish time. |
| `UserGroups` | Per-app visibility filter (empty = all collection users). |
| `ShowInWebAccess` | Whether it appears in RD Web/feed at all. |
| `FolderName` | Folder grouping in RD Web / Start menu. |

Nothing is copied to the session hosts. The broker assumes every host in the collection can run `FilePath`. That assumption is the root of most RemoteApp tickets.

### 2. The launch
```
RD Web / feed / .rdp
   remoteapplicationmode:i:1
   remoteapplicationprogram:s:||<Alias>
   remoteapplicationname:s:<DisplayName>
   remoteapplicationcmdline:s:<args>          (optional; FTA puts the file path here)
   loadbalanceinfo:s:tsv://MS Terminal Services Plugin.1.<CollectionId>
        │
        ▼
Client ──(RD Gateway, 443)──► Broker (Tssdis)
        │  resolves collection from loadbalanceinfo,
        │  picks host (existing session for this user first, else LB),
        │  redirects client
        ▼
Session host (TermService)
   logon → userinit → rdpinit.exe → rdpshell.exe  (NOT explorer.exe)
   rdpinit asks for the program for ||Alias → FilePath + CommandLineSetting
   → CreateProcess(FilePath, args) as the user
   → top-level windows are remoted individually (RAIL) to the client
```
The `||` prefix means "look up by alias". A plain path (no `||`) is only accepted when the host's allow-list is disabled — a legacy/standalone configuration, not how collections work.

### 3. Session reuse and lifetime
- A user launching a second app **from the same collection** is placed in their existing session on the same host (broker session directory) — both apps share one session, one profile load.
- Apps from **different collections** always mean separate sessions (possibly separate hosts, separate profile loads — FSLogix/UPD lock conflicts are possible if both collections point at the same profile store).
- When the last RemoteApp window closes, rdpinit keeps the session briefly then **disconnects** it; the GPO *"Set time limit for logoff of RemoteApp sessions"* decides when that disconnected session is logged off. The normal disconnected-session limit (collection config or GPO) still applies too; the shorter effective one wins in practice.
- A process that still owns a window (even hidden) can keep a RemoteApp session "in use" so it never goes idle → sessions pile up.

### 4. File-type associations (FTAs)
- Configured per `(Collection, AppAlias, FileExtension)` with `Set-RDFileTypeAssociation -IsPublished`.
- Delivered **only through the feed** (`webfeed.aspx`). A subscribed Windows client registers the extensions locally and points them at a generated `.rdp` for that alias.
- On double-click the local file path is placed on the command line. The server can only open it if **drive redirection** is allowed and `CommandLineSetting` is `Allow` (with `Require` the file path is discarded).
- Launching from the RD Web page or a hand-distributed `.rdp` never creates FTAs. Non-Windows Windows App clients do not register RemoteApp FTAs.

### 5. Shell differences that break apps
`rdpshell.exe` is not Explorer: no taskbar/notification area of its own (tray icons are proxied), no shell extensions loaded into Explorer, no Explorer-driven first-run. UAC elevation prompts can't be satisfied interactively. Apps that immediately spawn a child and exit (launchers, auto-updaters, `.cmd` wrappers without `start /wait`) leave rdpinit with no window → session disconnects/logs off, user sees a flash.
</details>

---
## Dependency Stack
```
[7] App window remoted to client (RAIL), FTAs registered on client (feed only)
[6] App process: exe + DLLs + licence + first-run satisfied, runs non-elevated
[5] rdpinit/rdpshell resolve ||Alias → FilePath, apply CommandLineSetting
[4] FilePath exists and is executable by the user on THIS host
[3] Session host: in collection, not drained, TermService/SessionEnv healthy, profile loads
[2] Broker: publishing record (TScPubRPC/RDCms), session directory, LB (Tssdis)
[1] Client → RD Gateway → broker connectivity, certificates, licensing
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| "not in the list of authorized programs" / "cannot find the program" on some launches | `FilePath` missing on one host | Path test per host (Validation 2) |
| Same error on every launch after a change | Alias renamed/unpublished; stale `.rdp` | `Get-RDRemoteApp` vs `.rdp` alias |
| Window flashes, session ends | Launcher stub, hidden prompt, crash | LSM 21→23 seconds apart; Application log |
| App opens but not the file double-clicked | `CommandLineSetting DoNotAllow/Require` or drive redirection off | `Get-RDRemoteApp`, `Get-RDSessionCollectionConfiguration -Client` |
| Double-click doesn't launch the RemoteApp at all | FTA not published, or client not feed-subscribed | `Get-RDFileTypeAssociation`; client RADC |
| Works for admins, not users | NTFS on exe/data folder; app needs elevation | `icacls`; test as user |
| Blank/generic icon | `IconPath` invalid at publish time | `Get-RDRemoteApp` IconPath |
| Disconnected RemoteApp sessions accumulate | RemoteApp logoff limit "Never"; hidden window process | GPO RSoP; `query process` |
| Reopening app is always a full logon | RemoteApp logoff limit = Immediately | GPO RSoP |
| Two apps, two logons, profile lock errors | Apps in different collections sharing one profile store | Collection of each alias |
| App works in desktop session, not as RemoteApp | Explorer/shell dependency | Test both modes on same host |

---
## Validation Steps
1. **Publishing record**
   ```powershell
   Get-RDRemoteApp -CollectionName <c> -ConnectionBroker <cb> | fl DisplayName, Alias, FilePath, FileVirtualPath, CommandLineSetting, RequiredCommandLine, IconPath, ShowInWebAccess, UserGroups, FolderName
   ```
   Good: expected alias, absolute or env-var path, sensible command-line policy. Bad: path to `%LocalAppData%` / a user profile / a mapped drive.
2. **Path on every host** — run `Get-RemoteAppPublishingAudit.ps1` or the Triage loop in `RemoteApp-B.md`. Good: `Exists=True` for every (app, host). Bad: any `False`.
3. **Collection client settings (for FTAs)**
   ```powershell
   Get-RDSessionCollectionConfiguration -CollectionName <c> -ConnectionBroker <cb> -Client | fl ClientDeviceRedirectionOptions
   ```
   Good: includes `Drive` if FTAs are used.
4. **FTAs**
   ```powershell
   Get-RDFileTypeAssociation -CollectionName <c> -AppAlias <alias> -ConnectionBroker <cb>
   ```
   Good: required extensions present with `IsPublished = True`.
5. **Launch telemetry on host** — LSM Operational 21 (logon) / 24 (disconnect) / 25 (reconnect) / 23 (logoff). A 21 followed by 23 within seconds for a RemoteApp launch = the app process exited.
6. **Lifetime policy** — `gpresult /scope computer /h` on the RDSH; locate *Set time limit for logoff of RemoteApp sessions*. Good: a finite value (e.g. 15–60 min) agreed with the customer.

---
## Troubleshooting Steps (by phase)
**Phase A — Is it the app or the host?** Pin the user to one host (drain others briefly or test with a user who has an existing session) and retry. If only one host fails → host build drift (Playbook 1).

**Phase B — Does the process start?** Watch on the host during a launch:
```powershell
while ($true) { Get-Process -IncludeUserName | ? UserName -like '*<sam>' | Select Name, Id, StartTime; Start-Sleep 1; Clear-Host }
```
No process → path/permission/alias. Process starts then dies → app-level (Phase C).

**Phase C — Why does it exit?** Application log, WER (`C:\ProgramData\Microsoft\Windows\WER\ReportArchive`), vendor log. Try the same exe in a full desktop as the same user — prompts or errors visible there are what the RemoteApp user can't see.

**Phase D — Arguments/files.** Log the actual command line:
```powershell
Get-CimInstance Win32_Process -Filter "Name='<app.exe>'" | Select ProcessId, CommandLine
```
Empty when an FTA was used → `CommandLineSetting` or drive redirection.

**Phase E — Lifetime.** `Get-RDUserSession` over time; `query process /id:<n>` for sessions that should have ended.

---
## Remediation Playbooks

<details><summary>Playbook 1 — Standardise app paths across a collection</summary>

1. Run `Get-RemoteAppPublishingAudit.ps1`; list every (alias, host) with `Exists=False`.
2. Drain affected hosts (`Set-RDSessionHost -NewConnectionAllowed No`).
3. Install the app to the published path (same installer/version), or reinstall on all hosts to a common path and update `FilePath`/`IconPath`.
4. Re-run the audit → all `True`; undrain.
Rollback: re-apply previous `FilePath` with `Set-RDRemoteApp` (record it first). No user data affected.
</details>

<details><summary>Playbook 2 — Safely rename/replace a published app</summary>

1. `New-RDRemoteApp -CollectionName <c> -Alias <newAlias> -DisplayName '<Name>' -FilePath '<path>' -UserGroups <grp> -ConnectionBroker <cb>`.
2. Communicate; users update feed / re-download.
3. After the grace period: `Remove-RDRemoteApp -CollectionName <c> -Alias <oldAlias> -ConnectionBroker <cb>`.
Rollback: re-publish old alias with the recorded properties (export them first: `Get-RDRemoteApp ... | Export-Clixml`).
</details>

<details><summary>Playbook 3 — Enable file-type associations end to end</summary>

```powershell
Set-RDRemoteApp -CollectionName <c> -Alias <alias> -CommandLineSetting Allow -ConnectionBroker <cb>
'.pdf','.xlsx' | % { Set-RDFileTypeAssociation -CollectionName <c> -AppAlias <alias> -FileExtension $_ -IsPublished $true -ConnectionBroker <cb> }
# Ensure drive redirection is in ClientDeviceRedirectionOptions (keep existing flags - read first)
Get-RDSessionCollectionConfiguration -CollectionName <c> -ConnectionBroker <cb> -Client | fl ClientDeviceRedirectionOptions
```
Client: subscribe via RADC (GPO *User Config → Admin Templates → Windows Components → Remote Desktop Services → RemoteApp and Desktop Connections → Specify default connection URL* for automatic subscription), then *Update now*.
Rollback: `-IsPublished $false`; restore previous `CommandLineSetting` / redirection options.
Security: drive redirection exposes client disks to the session — agree it with the customer.
</details>

<details><summary>Playbook 4 — Make a "flashing" app RemoteApp-friendly</summary>

- Replace launcher with the real exe (check Task Manager → Details in a desktop session for which process stays).
- Wrapper for scripts: publish `C:\Windows\System32\cmd.exe` is **not** recommended; instead a signed PowerShell/exe wrapper that `Start-Process -Wait`s the real app — and restrict it with `CommandLineSetting Require`.
- Pre-accept EULA/first-run via HKCU GPP registry items; remove elevation requirement (manifest `requireAdministrator` apps can't run as RemoteApp for standard users).
- If Explorer-dependent: publish a full desktop collection for that user group.
</details>

<details><summary>Playbook 5 — Tame RemoteApp session lifetime</summary>

1. Set *Set time limit for logoff of RemoteApp sessions* to a finite value (e.g. 30 min) via GPO on the RDSH OU.
2. Align collection disconnected limit (`Set-RDSessionCollectionConfiguration -DisconnectedSessionLimitMin`).
3. Find "sticky" processes in disconnected sessions and remove them from per-user startup (Run keys, Startup folder, vendor updaters).
Rollback: revert GPO; `gpupdate /force` on hosts.
</details>

---
## Evidence Pack
```powershell
# Run on the Connection Broker, elevated. Read-only.
param([string]$CB = ([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName), [string]$Out = "C:\Temp\RemoteAppEvidence_$(Get-Date -f yyyyMMdd_HHmm)")
Import-Module RemoteDesktop
New-Item -ItemType Directory -Path $Out -Force | Out-Null
$colls = Get-RDSessionCollection -ConnectionBroker $CB
$colls | Export-Csv "$Out\Collections.csv" -NoTypeInformation
foreach ($c in $colls) {
  $n = $c.CollectionName
  Get-RDRemoteApp -CollectionName $n -ConnectionBroker $CB | Export-Clixml "$Out\RemoteApps_$n.xml"
  Get-RDSessionHost -CollectionName $n -ConnectionBroker $CB | Export-Csv "$Out\Hosts_$n.csv" -NoTypeInformation
  Get-RDSessionCollectionConfiguration -CollectionName $n -ConnectionBroker $CB -Client | Export-Clixml "$Out\ClientCfg_$n.xml"
  Get-RDSessionCollectionConfiguration -CollectionName $n -ConnectionBroker $CB -Connection | Export-Clixml "$Out\ConnCfg_$n.xml"
  foreach ($a in (Get-RDRemoteApp -CollectionName $n -ConnectionBroker $CB)) {
    try { Get-RDFileTypeAssociation -CollectionName $n -AppAlias $a.Alias -ConnectionBroker $CB | Export-Clixml "$Out\FTA_${n}_$($a.Alias).xml" } catch {}
  }
}
Get-RDUserSession -ConnectionBroker $CB | Export-Csv "$Out\UserSessions.csv" -NoTypeInformation
# Per-host path check + events: run Get-RemoteAppPublishingAudit.ps1 -OutputPath $Out
Compress-Archive -Path "$Out\*" -DestinationPath "$Out.zip" -Force
Write-Host "Evidence: $Out.zip"
```

---
## Command Cheat Sheet
```powershell
Get-RDRemoteApp -CollectionName <c> -ConnectionBroker <cb>
New-RDRemoteApp -CollectionName <c> -DisplayName '<Name>' -FilePath '<path>' -Alias <alias> -ConnectionBroker <cb>
Set-RDRemoteApp -CollectionName <c> -Alias <alias> -FilePath '<path>' -ConnectionBroker <cb>
Set-RDRemoteApp -CollectionName <c> -Alias <alias> -CommandLineSetting Allow|DoNotAllow|Require [-RequiredCommandLine '<args>']
Set-RDRemoteApp -CollectionName <c> -Alias <alias> -UserGroups 'DOM\Grp' -ShowInWebAccess $true
Set-RDRemoteApp -CollectionName <c> -Alias <alias> -IconPath '<exe>' -IconIndex 0
Remove-RDRemoteApp -CollectionName <c> -Alias <alias> -ConnectionBroker <cb>
Get-RDFileTypeAssociation -CollectionName <c> -AppAlias <alias> -ConnectionBroker <cb>
Set-RDFileTypeAssociation -CollectionName <c> -AppAlias <alias> -FileExtension '.ext' -IsPublished $true
Get-RDSessionCollectionConfiguration -CollectionName <c> -Client | fl ClientDeviceRedirectionOptions
Get-RDUserSession -ConnectionBroker <cb> -CollectionName <c>
Get-CimInstance Win32_Process -Filter "Name='app.exe'" | Select ProcessId, CommandLine
query process /id:<sessionId> /server:<rdsh>
.\Get-RemoteAppPublishingAudit.ps1 -ConnectionBroker <cb>
```

---
## 🎓 Learning Pointers
- Publishing stores metadata on the broker; hosts are trusted to match. Treat "same path on every host" as a build requirement and audit it after every patch/app update cycle. Reference: [Create and deploy a Remote Desktop Services collection](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/rds-create-collection).
- Read the `.rdp` a client actually uses — `remoteapplicationprogram`, `remoteapplicationcmdline` and `loadbalanceinfo` tell you alias, arguments and collection. Reference: [Supported RDP properties](https://learn.microsoft.com/en-us/azure/virtual-desktop/rdp-properties).
- `CommandLineSetting` is a security control as much as a feature: `Allow` passes client-supplied arguments to a server exe. Reference: [New-RDRemoteApp](https://learn.microsoft.com/en-us/powershell/module/remotedesktop/new-rdremoteapp).
- FTAs need four things at once — published extension, feed-subscribed Windows client, `Allow`, drive redirection. Reference: [Set-RDFileTypeAssociation](https://learn.microsoft.com/en-us/powershell/module/remotedesktop/set-rdfiletypeassociation).
- The same concepts (alias, command-line policy, FTAs via feed) carry over to AVD RemoteApp application groups, with the control plane in Azure instead of the broker — see `../../Azure/AVD/AVD-A.md`.
