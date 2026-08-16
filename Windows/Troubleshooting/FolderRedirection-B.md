# Folder Redirection & Offline Files (CSC) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)
- [Learning Pointers](#-learning-pointers)

---

## Triage

Run these first. Results tell you which fix path to take.

```powershell
# 1. Is the redirected folder actually pointing where policy says it should?
(New-Object -ComObject Shell.Application).NameSpace('shell:Personal').Self.Path
Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -Name Personal

# 2. Is Offline Files even enabled and running?
Get-Service CscService | Select-Object Status, StartType

# 3. Is the network share reachable right now, and does Sync Center report a problem?
Test-Path \\<server>\<share>
Get-WinEvent -LogName "Microsoft-Windows-OfflineFiles/Operational" -MaxEvents 20 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message

# 4. Are there unresolved sync conflicts sitting in Sync Center right now?
control /name Microsoft.SyncCenter

# 5. Is "Always Offline" mode active (explains why it never touches the network even when online)?
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetCache" -Name SlowLinkEntries -ErrorAction SilentlyContinue
```

| If | Then |
|----|------|
| `User Shell Folders` `Personal` path still shows a local path, not `\\server\share\...` | Redirection GPO never applied to this user, or applied but folder move failed → **Fix 1** |
| `CscService` stopped or disabled | Offline Files (and therefore Folder Redirection's offline availability) is fully broken → **Fix 2** |
| Files show a red "X" sync-conflict icon in Explorer/Sync Center | Genuine edit conflict — two versions of the same file exist and need manual resolution → **Fix 3** |
| A previous user's account left this folder "always offline," blocking redirection for the next user of the same machine | Stale per-user Offline Files state surviving a profile change → **Fix 4** |
| User complains everything is slow / redirected Desktop takes forever to load at sign-in | Redirected folder isn't cached offline, or a slow-link threshold is forcing constant re-sync at logon → **Fix 5** |
| AppData\Roaming was manually added to redirection and users report broken/corrupt app settings | AppData\Roaming should never be redirected — file-handle conflicts are expected and documented as unsupported → **Fix 6** |
| BranchCache SMB caching also stopped working on this same machine | Confirm `CscService` wasn't disabled as a side effect — see `Troubleshooting/BranchCache-B.md` Fix 7 | — |

---

## Dependency Cascade

<details><summary>What must be true</summary>

```
AD DS domain + GPO applied to the user object (Folder Redirection is a USER Group Policy setting,
not computer)
        │
Target share exists, is reachable, and the user has NTFS+share permissions on their subfolder
   (with "Grant the user exclusive rights" enabled by default — admins don't get automatic access)
        │
Initial redirection/move completes at logon
   (existing local folder contents get MOVED to the target — can be slow/large on first apply,
    and a failed/interrupted move leaves the folder in an inconsistent state)
        │
[If Offline Files is enabled — default for redirected folders unless explicitly disabled via
 "Do not automatically make redirected folders available offline"]
Offline Files (CscService) running on the client
        │
Local CSC cache populated (C:\Windows\CSC) — bounded by the "Limit disk space used by
Offline Files" policy (default: 25% of the drive holding the cache)
        │
Sync operations succeed on logon/logoff, background interval, or manual trigger
   (Sync Center surfaces conflicts here — a conflict does not mean data loss, it means TWO
    valid edits exist and a human has to pick)
        │
[If "Configure slow-link mode" is set with Latency=1] Always Offline mode — client NEVER
transitions to Online mode for that share, works from cache always, syncs only on the
Background Sync interval (default 120 minutes)
        │
User sees current, synced content in the redirected folder location
```

**The one per-user trap:** Offline Files state (pinned/always-offline folders, cached credentials
for the share) is tracked per Windows user profile, not centrally. A folder set to "Always
available offline" by one user, then handed to a different account on the same machine (or a
machine re-image that doesn't fully clear CSC), can leave that setting stuck in a way Group
Policy alone won't override.

</details>

---

## Diagnosis & Validation Flow

**1. Confirm where the folder is actually pointing right now:**
```powershell
Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
```
Expected: `Personal`, `Desktop`, etc. show a UNC path matching the GPO's target, not a local `C:\Users\...` path. A local path means redirection never applied for this user/session — this is a Group Policy application problem, not a file-sync problem.

**2. Confirm Offline Files is running (only relevant if the folder should be available offline):**
```powershell
Get-Service CscService | Select-Object Status, StartType
```
Expected: `Running`/`Automatic`. If stopped, the redirected folder works fine while online but throws errors or shows nothing the moment the network path is unreachable.

**3. Confirm the target share is actually reachable right now:**
```powershell
Test-Path \\<server>\<share>\<username>
```
If `False` while the user reports "my files are missing," this is very likely working exactly as designed — they're offline/disconnected and looking at a stale or absent cache, not experiencing data loss. Confirm cache state before assuming corruption.

**4. Check the Offline Files operational event log for the actual failure:**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-OfflineFiles/Operational" -MaxEvents 50 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-Table -Wrap
```
Look specifically for sync failure events referencing the affected path — this log is far more specific than the generic "files unavailable" symptom the user reports.

**5. Open Sync Center and look for conflict items, not just errors:**
```powershell
control /name Microsoft.SyncCenter
```
A file listed under "Conflicts" is not broken — it means the sync engine found two different valid versions (one made offline, one made by someone/something else on the source) and is waiting for a human decision. This is expected behavior for shared/multi-writer paths, not a bug.

**6. Confirm whether Always Offline mode explains "why does it never touch the network":**
```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetCache" -Name SlowLinkEntries -ErrorAction SilentlyContinue
```
If `Latency=1` is configured for this share, the client is deliberately never transitioning to Online mode — it always serves from cache and only syncs on the Background Sync interval (default every 120 minutes). This is a design choice for mobile/roaming users, not a fault.

---

## Common Fix Paths

<details><summary>Fix 1 — Redirection never applied / folder still points locally</summary>

**Symptom:** `User Shell Folders` registry path is still local; GPO is confirmed linked and scoped correctly.

```powershell
# Confirm the GPO is actually being received by this user
gpresult /r /scope:user

# Force a policy refresh and force-reprocess even if the GPO version hasn't changed
gpupdate /force /target:user

# If it still doesn't apply, confirm the user has NTFS+share permission on their target subfolder
# (the redirection GPO creates \\server\share\%username%\<Folder> — if that folder/ACL wasn't
#  provisioned correctly, the move silently fails and Explorer falls back to the local path)
```

Check the **Application** event log on the client for Folder Redirection event source errors (commonly Event ID 502 for a failed redirection, or 101 for a slow-link deferral) — these name the exact folder and failure reason.

**Rollback:** N/A — this is a diagnostic/reapply fix path, not a destructive change.

</details>

<details><summary>Fix 2 — Offline Files service stopped/disabled</summary>

**Symptom:** `CscService` status is `Stopped` and/or `StartType` is `Disabled`; redirected folders are inaccessible or empty the moment the network path drops.

```powershell
Set-Service CscService -StartupType Automatic
Start-Service CscService

# Confirm Offline Files is enabled at the policy level too — the service can be running
# while the feature itself is policy-disabled
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetCache" -Name Enabled -ErrorAction SilentlyContinue
```

If this machine also uses BranchCache for SMB caching, re-enabling `CscService` here also restores that dependency — see `Troubleshooting/BranchCache-B.md` Fix 7 if BranchCache was the original reason this got flagged.

**Rollback:**
```powershell
Set-Service CscService -StartupType Disabled
Stop-Service CscService
```
Only do this deliberately (e.g., a Work Folders migration) — disabling it breaks both Folder Redirection's offline availability and BranchCache SMB caching on this machine.

</details>

<details><summary>Fix 3 — Genuine sync conflict needs manual resolution</summary>

**Symptom:** File shows a conflict icon in Explorer or is listed under Sync Center's Conflicts view.

```powershell
control /name Microsoft.SyncCenter
```
In the Conflicts view, each item offers **Keep both versions**, **Keep the version from [source]**, or **Keep the version from [this computer]**. There is no safe automatic resolution — pick based on which edit the user actually wants to keep, or choose "Keep both" (Windows appends a suffix to one copy) if unsure and let the user reconcile manually.

**Prevent recurrence:** Microsoft's own guidance is that Offline Files is intended for paths where effectively only one user has write access at a time. If conflicts are frequent on a specific shared path, that's a signal the path is being used in a way Offline Files isn't designed for (multiple concurrent editors) — consider moving that specific workload to a co-authoring-aware platform (SharePoint/OneDrive) instead of continuing to fight sync conflicts.

**Rollback:** N/A — conflict resolution is inherently a one-way decision per file.

</details>

<details><summary>Fix 4 — Stale per-user "Always Offline" state blocking a new user/profile</summary>

**Symptom:** A folder behaves as permanently offline (never re-checks the network) for a new user or after a profile change, even though no current GPO forces Always Offline.

```powershell
# Confirm current per-file/folder offline availability state
Get-ChildItem "$env:USERPROFILE\<RedirectedFolder>" | ForEach-Object {
    (New-Object -ComObject Shell.Application).NameSpace($_.DirectoryName).ParseName($_.Name).ExtendedProperty("System.OfflineAvailability")
}

# Clear this folder's offline pin for the CURRENT user (right-click equivalent in Explorer):
# Explorer GUI: right-click the folder → "Always available offline" to toggle off
# There is no supported command-line cmdlet for this — CSC state is managed via the shell API
```

If GUI toggling doesn't stick, the underlying CSC cache entry for the old profile may need to be cleared — this typically requires a profile-level cleanup (see `Troubleshooting/UserProfile-B.md` for profile deletion/cleanup procedure) rather than fighting the Offline Files state directly.

**Rollback:** N/A — re-enable "Always available offline" via the same Explorer toggle if needed.

</details>

<details><summary>Fix 5 — Redirected Desktop/Documents slow at logon</summary>

**Symptom:** Sign-in takes noticeably longer since Folder Redirection was deployed, especially over VPN or a slow link.

```powershell
# Confirm whether slow-link mode is engaging (and at what threshold) for this share
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetCache" -Name SlowLinkEntries -ErrorAction SilentlyContinue

# If NOT configured, logon is doing a full synchronous fetch over a slow link every time —
# this is the single most common cause of "logon got slow after Folder Redirection"
```

**The fix is almost always to configure (not remove) slow-link handling:** set "Configure slow-link mode" with a realistic latency threshold (not `1`, which forces permanent Always Offline) so the client falls back to cached content automatically when the link is genuinely slow, instead of blocking logon on a full synchronous fetch. Pair with "Configure Background Sync" to control how often it catches up once online.

**Rollback:** remove/disable the "Configure slow-link mode" GPO setting to return to default synchronous behavior — only do this if the redirected folders are consistently small and links are consistently fast.

</details>

<details><summary>Fix 6 — AppData\Roaming redirected, causing app-setting corruption</summary>

**Symptom:** Redirected AppData\Roaming, with users reporting broken Outlook profiles, Office settings resetting, or other app-state corruption tied to file-handle conflicts.

**This is a known, documented anti-pattern, not a fixable configuration.** AppData\Roaming contains files many applications keep open continuously and write to frequently — redirecting it is far more conflict-prone than user-document folders and is explicitly called out as a source of sync failures from open file handles.

```
User Configuration → Policies → Windows Settings → Folder Redirection → AppData (Roaming)
  → Setting: Not Configured (remove the redirection)
```

For app-setting continuity across devices, prefer Enterprise State Roaming / Windows Backup for Organizations settings sync (`Troubleshooting/WindowsBackup-A.md`) over Folder Redirection for this specific folder.

**Rollback:** N/A — removing the redirection is the fix; there's no partial/safe way to keep AppData\Roaming redirected.

</details>

---

## Escalation Evidence

```
=== Folder Redirection / Offline Files Failure — Ticket Evidence ===

Date/Time:                     _______________
User:                          _______________
Machine:                       _______________
Affected folder:               _______________  (Desktop / Documents / AppData\Roaming / etc.)
Target UNC path (from GPO):    _______________

--- Commands Run ---
User Shell Folders path (actual):        _______________
CscService status:                       _______________
Test-Path to target share:               _______________
Sync Center conflict items present (Y/N):_______________
Always Offline / slow-link configured:   _______________

--- Scenario ---
[ ] Redirection never applied (still local path)
[ ] Offline Files service down
[ ] Genuine sync conflict, needs user decision
[ ] Slow logon since redirection deployed
[ ] AppData\Roaming redirected (anti-pattern)
[ ] Related BranchCache SMB caching also broken on this machine

--- Steps Taken ---
[ ] Confirmed actual redirection target vs. GPO-intended target
[ ] Confirmed CscService running
[ ] Confirmed network path reachability
[ ] Reviewed Microsoft-Windows-OfflineFiles/Operational event log
[ ] Checked Sync Center for outstanding conflicts
```

---

## 🎓 Learning Pointers

- **Folder Redirection is a User-side Group Policy setting — it lives under `User Configuration`, not `Computer Configuration`.** A GPO scoped only to computer objects, or a user object outside the linked OU, produces exactly the "folder still points locally" symptom with no error the user notices until they lose access to a machine they'd cached files on. [MS Docs: Configure Folder Redirection with Group Policy](https://learn.microsoft.com/en-us/windows-server/storage/folder-redirection/folder-redirection-using-group-policy)

- **A sync conflict is not data loss — it's two valid edits that need a human decision.** Resist the urge to auto-resolve or reflexively pick "keep mine" without checking; Sync Center shows both versions specifically so nothing is silently discarded.

- **Offline Files availability state is tracked per Windows profile, not centrally enforced by GPO alone.** A folder pinned "Always available offline" by a prior user can outlive that user's session in ways a policy refresh won't automatically clean up — this is the most common source of "it's stuck in a weird state and nothing I change in GPO fixes it."

- **"Configure slow-link mode" with Latency=1 is Always Offline mode — deliberately never touching the network — not a bug if a user reports the folder "ignores" a fast connection.** Any latency threshold above 1 is a genuine slow-link fallback; confirm which behavior is actually intended before treating this as broken. [MS Docs: Enable Always Offline mode](https://learn.microsoft.com/en-us/windows-server/storage/folder-redirection/enable-always-offline)

- **AppData\Roaming redirection is explicitly discouraged, not just risky** — the folder holds files many applications keep open continuously, and Microsoft's own guidance identifies this as a leading cause of sync-conflict tickets. If it's already redirected in an environment you inherit, treat removing it as a fix, not a regression.

- **BranchCache SMB caching and Folder Redirection's offline availability share the same underlying dependency: `CscService`.** If both features break at the same time on the same machine, look for one root cause (the service being disabled) rather than troubleshooting them as two unrelated incidents — see `Troubleshooting/BranchCache-B.md`.
