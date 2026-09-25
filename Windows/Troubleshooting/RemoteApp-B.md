# RemoteApp Publishing (RDS Session Collections) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.
> Covers: *"The remote program could not be started because it is not in the list of authorized programs"*, a RemoteApp that works on one session host but not another, app window flashes and closes / session opens then logs straight off, command-line arguments ignored or rejected, file-type associations (double-click `.pdf`/`.xlsx` → RemoteApp) not working, wrong/generic icons, and RemoteApp sessions lingering (or dropping) after the last app is closed.
> Deep dive: `RemoteApp-A.md` · Script: `../Scripts/Get-RemoteAppPublishingAudit.ps1` · Siblings: `RDSessionHost-B.md` (drain/LB/UPD) · `RDWebAccess-B.md` (app not *visible* in RD Web / feed) · `RDConnectionBroker-B.md` · `RDGateway-B.md` · AVD RemoteApp: `../../Azure/AVD/AVD-A.md`

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage

Run on the **Connection Broker** (elevated Windows PowerShell 5.1, `RemoteDesktop` module):

```powershell
$cb = '<broker.fqdn>'; $coll = '<CollectionName>'; $alias = '<AppAlias>'
Get-RDRemoteApp -CollectionName $coll -ConnectionBroker $cb |
  Select DisplayName, Alias, FilePath, FileVirtualPath, CommandLineSetting, RequiredCommandLine, ShowInWebAccess, @{n='Groups';e={$_.UserGroups -join ';'}}
# Does the published path exist on EVERY host in the collection?
$app = Get-RDRemoteApp -CollectionName $coll -Alias $alias -ConnectionBroker $cb
Get-RDSessionHost -CollectionName $coll -ConnectionBroker $cb | ForEach-Object {
  Invoke-Command -ComputerName $_.SessionHost -ArgumentList $app.FilePath {
    param($p) [pscustomobject]@{ Host=$env:COMPUTERNAME; Path=[Environment]::ExpandEnvironmentVariables($p); Exists=Test-Path ([Environment]::ExpandEnvironmentVariables($p)) } }
} | Select Host, Path, Exists
Get-RDFileTypeAssociation -CollectionName $coll -AppAlias $alias -ConnectionBroker $cb
```

| Result | Meaning | Go to |
|---|---|---|
| `Exists = False` on one or more hosts | App not installed / installed to a different path on that host — users landing there get "not in the list of authorized programs" or "cannot find the program" | Fix 1 |
| Alias missing from `Get-RDRemoteApp` but users still have an old `.rdp`/shortcut | App was unpublished/renamed; stale `.rdp` still points at the old `\|\|alias` | Fix 2 |
| Path exists everywhere, window flashes and session logs off | Launcher stub exits, first-run/UAC prompt hidden, or app needs Explorer shell | Fix 3 |
| `CommandLineSetting = DoNotAllow` and the user/FTA passes a file | Arguments are stripped → app opens blank or errors | Fix 4 |
| No rows from `Get-RDFileTypeAssociation`, or `IsPublished = False` | FTA not published — or client isn't a *feed subscriber* (RD Web launch never registers FTAs) | Fix 5 |
| Generic/blank icon in RD Web or feed | `IconPath` unreachable from broker or wrong `IconIndex` | Fix 6 |
| Sessions stay "Disconnected" for hours after users close the app, or reopen is slow | RemoteApp logoff time limit / hidden process keeping session alive | Fix 7 |
| App missing from RD Web for some users | Not a publishing fault — visibility filter | `RDWebAccess-B.md` Fix 4 |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
User double-clicks a RemoteApp (RD Web / feed / .rdp / FTA)
└── .rdp contains remoteapplicationmode:i:1 + remoteapplicationprogram:s:||<Alias>
    └── Client → (RD Gateway) → Broker (Tssdis) → picks host in collection
        └── Broker publishing data (TScPubRPC / RDCms DB) knows <Alias> → FilePath, CommandLineSetting
            └── Chosen RDSH:
                ├── FilePath resolves on THIS host (same path, env vars expand)
                ├── User has NTFS read/execute on the exe and its dependencies
                ├── rdpinit.exe → rdpshell.exe start (not explorer.exe)
                │   └── app process starts with allowed/required command line
                │       └── app shows a top-level window (else session looks "empty")
                └── When last app window closes → session disconnected → logoff after
                    "RemoteApp session logoff" time limit (GPO) → session gone
File-type associations: only registered on the client by a FEED subscription
(RemoteApp and Desktop Connections on Windows), published per alias + extension.
```
</details>

---
## Diagnosis & Validation Flow

1. **Confirm the alias the client is asking for.** Open the user's `.rdp` (RD Web: download it; feed shortcuts live under `%AppData%\Microsoft\Windows\Start Menu\Programs\Work Resources (RADC)`) and read `remoteapplicationprogram:s:||<Alias>`.
   - Good: alias matches `Get-RDRemoteApp ... -Alias <Alias>`.
   - Bad: alias not returned → Fix 2.
2. **Confirm which host the user landed on.**
   `Get-RDUserSession -ConnectionBroker $cb -CollectionName $coll | ? UserName -eq '<sam>' | Select HostServer, SessionState, CreateTime`
   - Failure on only some launches = only some hosts are broken → step 3 per host.
3. **Path check per host** (Triage block). All `True` is the only acceptable result. 32-bit vs 64-bit `Program Files` differences and per-user installs (`%LocalAppData%`) are the usual culprits.
4. **Launch the app manually on the failing host** as a test user via a *full desktop* session (or `runas /user:<domain\user> "<FilePath>"`). If it prompts for UAC, EULA, first-run wizard, or licence activation, that prompt is what the RemoteApp user can't see → Fix 3.
5. **Check events on the failing host:**
   ```powershell
   Get-WinEvent -ComputerName <rdsh> -FilterHashtable @{LogName='Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'; StartTime=(Get-Date).AddHours(-2)} |
     Select TimeCreated, Id, Message | Format-List
   Get-WinEvent -ComputerName <rdsh> -FilterHashtable @{LogName='Application'; Level=2; StartTime=(Get-Date).AddHours(-2)} | Select TimeCreated, ProviderName, Message
   ```
   - Logon (21) immediately followed by logoff (23) for the user = app exited → Fix 3.
   - Application error / .NET runtime crash for the exe = app fault, not RDS.
6. **Command line:** compare what the client sends (`remoteapplicationcmdline:s:` in the `.rdp`, or the file path for an FTA) with `CommandLineSetting`/`RequiredCommandLine`.
7. **FTAs:** on the client, confirm it is feed-subscribed (Control Panel → RemoteApp and Desktop Connections shows the connection) and the extension shows the RemoteApp as a handler (`assoc .<ext>` / Default Apps).

---
## Common Fix Paths

<details><summary>Fix 1 — App missing or at a different path on some hosts</summary>

Every host in a collection must have the app at the **same** `FilePath`. The broker does not install or verify apps.

```powershell
# Option A (preferred): install the app on the missing host(s) to the same path, then re-test.
# Option B: take the host out of rotation until it is fixed
Set-RDSessionHost -SessionHost <rdsh.fqdn> -NewConnectionAllowed No -ConnectionBroker $cb
# Option C: publish a path that is identical everywhere (e.g. use %ProgramFiles% consistently)
Set-RDRemoteApp -CollectionName $coll -Alias $alias -FilePath 'C:\Program Files\Vendor\App\app.exe' -ConnectionBroker $cb
```
Re-enable with `-NewConnectionAllowed Yes` once installed. Build hosts from one image or a scripted install so paths can't drift.
</details>

<details><summary>Fix 2 — Stale alias / unpublished app still launched from old shortcuts</summary>

```powershell
Get-RDRemoteApp -ConnectionBroker $cb | Select CollectionName, Alias, DisplayName   # find where it lives now
```
- If renamed: users must get a new `.rdp` — refresh the feed (client: RemoteApp and Desktop Connections → *Update now*), re-download from RD Web, or redistribute the `.rdp`.
- Do **not** change an `Alias` on a live app (`Set-RDRemoteApp -Alias` is the key, not a rename); publish new + unpublish old in a maintenance window instead.
</details>

<details><summary>Fix 3 — Window flashes, session logs off (launcher stub / hidden prompt / Explorer dependency)</summary>

- **Launcher stubs** (exe starts a child then exits, e.g. updaters or `*.cmd` wrappers): publish the real long-running exe, or a wrapper that waits (`start /wait`).
- **Hidden first-run / EULA / UAC**: run the app once per user in a desktop session, pre-seed settings via GPO/registry, or fix the install so it doesn't need elevation. RemoteApps can't elevate interactively.
- **Needs `explorer.exe`** (shell extensions, tray-dependent add-ins): test in a full desktop; if it only works there, publish the desktop to that user group instead or ask the vendor.
- **Crashes**: Application log shows the fault → vendor/app ticket, not RDS.

Validate: user launch → `Get-RDUserSession` shows `STATE_ACTIVE` and the window appears.
</details>

<details><summary>Fix 4 — Command-line arguments ignored or rejected</summary>

```powershell
# Allow any arguments (needed for FTAs and for links that pass a file/URL)
Set-RDRemoteApp -CollectionName $coll -Alias $alias -CommandLineSetting Allow -ConnectionBroker $cb
# Or force one fixed argument set (e.g. a specific DB profile) - client args are ignored
Set-RDRemoteApp -CollectionName $coll -Alias $alias -CommandLineSetting Require -RequiredCommandLine '/profile:"Prod"' -ConnectionBroker $cb
```
`Require` + an FTA = the file the user double-clicked is **not** passed. Security note: `Allow` lets users pass arbitrary arguments to the exe — acceptable for Office/PDF readers, think twice for admin tools or `cmd`-capable apps.
</details>

<details><summary>Fix 5 — File-type associations don't open in the RemoteApp</summary>

```powershell
Get-RDFileTypeAssociation -CollectionName $coll -AppAlias $alias -ConnectionBroker $cb
Set-RDFileTypeAssociation -CollectionName $coll -AppAlias $alias -FileExtension '.pdf' -IsPublished $true -ConnectionBroker $cb
Set-RDRemoteApp -CollectionName $coll -Alias $alias -CommandLineSetting Allow -ConnectionBroker $cb   # file path must reach the app
```
Then on the client: **feed subscription required** (Control Panel → RemoteApp and Desktop Connections → Access RemoteApp and desktops → feed URL or email) and *Update now*. Launching from the RD Web page never registers FTAs. The local file path is passed via drive redirection — **drive redirection must be allowed** for the collection (`Get-RDSessionCollectionConfiguration -Client`, `ClientDeviceRedirectionOptions` includes `Drive`).
Rollback: `-IsPublished $false`, update feed.
</details>

<details><summary>Fix 6 — Wrong or blank icon</summary>

```powershell
Set-RDRemoteApp -CollectionName $coll -Alias $alias -IconPath 'C:\Program Files\Vendor\App\app.exe' -IconIndex 0 -ConnectionBroker $cb
```
The icon is read when publishing; the path must be valid on the host the broker queried. Refresh RD Web (clear browser cache) / update the feed.
</details>

<details><summary>Fix 7 — RemoteApp sessions linger (or drop) after the last app closes</summary>

GPO: *Computer Config → Admin Templates → Windows Components → Remote Desktop Services → Remote Desktop Session Host → Session Time Limits → "Set time limit for logoff of RemoteApp sessions"*. It controls how long the session stays disconnected after the last RemoteApp window closes.
```powershell
gpresult /h C:\Temp\gp.html     # on the RDSH - confirm which value wins
Get-RDUserSession -ConnectionBroker $cb -CollectionName $coll | ? SessionState -eq 'STATE_DISCONNECTED' | Select UserName, HostServer, DisconnectTime
```
- Too long → idle sessions eat RAM/licences; set minutes, not "Never".
- Too short (Immediately) → reopening an app always does a full logon (slow, profile reload).
- Session never ends even with the limit: a hidden/background process with a window (tray helper, updater) keeps the session "in use" → identify with `query process /id:<sessionid>` / `Get-Process -IncludeUserName` and remove it from that user's startup.
</details>

---
## Escalation Evidence

```
RemoteApp escalation
Deployment broker / collection: ______ / ______
App Alias / DisplayName: ______ / ______
FilePath / FileVirtualPath: ______
CommandLineSetting / RequiredCommandLine: ______
Hosts in collection + path Exists (per host): ______
Affected user(s) / host they landed on (Get-RDUserSession): ______
Client + launch method (RD Web / feed / .rdp / FTA / Windows App): ______
Exact error text / screenshot: ______
LocalSessionManager events (21/23/24/25) around failure: ______
Application log errors for the exe: ______
Manual launch in full desktop on same host works? (Y/N, prompts seen): ______
FTA: Get-RDFileTypeAssociation output + feed subscribed? ______
Get-RemoteAppPublishingAudit.ps1 CSV attached: Y/N
```

---
## 🎓 Learning Pointers
- The client only sends an **alias** (`||Alias`); the host resolves it to a path. "Not in the list of authorized programs" is almost always "this host can't resolve/find that alias's program", not a permissions problem. See [Publish RemoteApps in RDS](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/rds-create-collection).
- One broken host in a collection makes RemoteApp failures look **random** — always test the path on every host before touching the app. `Get-RemoteAppPublishingAudit.ps1` does this in one pass.
- RemoteApp sessions run `rdpshell.exe`, not Explorer — anything that assumes a desktop shell or an interactive first-run prompt will fail silently.
- FTAs are a **feed** feature: they need a subscribed client, a published extension, `CommandLineSetting Allow`, and drive redirection. Cmdlets: [Set-RDFileTypeAssociation](https://learn.microsoft.com/en-us/powershell/module/remotedesktop/set-rdfiletypeassociation) · [Set-RDRemoteApp](https://learn.microsoft.com/en-us/powershell/module/remotedesktop/set-rdremoteapp).
- The "logoff of RemoteApp sessions" time limit is separate from the normal disconnected-session limit — tune both (see `RDSessionHost-B.md` Fix 5).
