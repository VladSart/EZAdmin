# Folder Redirection & Offline Files (CSC) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why redirected/offline content diverges, not just what to type.

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
- [Learning Pointers](#-learning-pointers)

---

## Scope & Assumptions

**In scope:**
- Folder Redirection via Group Policy: target-location modes, policy-removal behavior, redirectable folder list
- Offline Files (Client-Side Caching / CSC): sync engine, Sync Center conflict handling, Always Offline mode, cache sizing
- The per-user nature of Offline Files state vs. the per-computer/per-user split of Folder Redirection GPO settings
- The AppData\Roaming redirection anti-pattern and why it's specifically risky
- BranchCache's dependency on the same CSC infrastructure (cross-referenced, not duplicated)

**Out of scope:**
- Work Folders (the newer, sync-based alternative to Offline Files) — a different architecture entirely; mentioned only as a migration target in Learning Pointers
- OneDrive Known Folder Move — the modern cloud-native replacement for Folder Redirection for Desktop/Documents/Pictures; see `M365/SharePoint-OneDrive/Sync-Issues-A.md`
- Roaming User Profiles — frequently deployed alongside Folder Redirection but architecturally separate (whole-profile roaming vs. specific-folder redirection); only referenced where the two interact
- BranchCache's own caching architecture — see `Troubleshooting/BranchCache-A.md` for the full picture; this runbook covers only the shared CSC dependency

**Assumptions:**
- AD DS domain-joined clients (Folder Redirection via GPO requires AD DS — no Entra-native equivalent for this specific mechanism, which is why OneDrive KFM has become the standard for Entra-joined/hybrid fleets)
- Windows 10/11 or Windows Server 2016+ clients
- PowerShell 5.1 baseline; note that most Offline Files per-file state (pinning, conflict resolution) has no supported PowerShell cmdlet and is managed through the Shell API / Sync Center GUI, called out explicitly where relevant

---

## How It Works

<details><summary>Full architecture</summary>

### Two Related but Separate Technologies

**Folder Redirection** and **Offline Files** are frequently deployed together but are architecturally distinct:

- **Folder Redirection** changes *where* a special folder (Desktop, Documents, Pictures, etc.) physically lives — from the local user profile to a network share. It is a **User Configuration** Group Policy setting (`User Configuration → Policies → Windows Settings → Folder Redirection`) applied at logon.
- **Offline Files (CSC — Client-Side Caching)** is what makes a network location (whether redirected or just a mapped/UNC path) usable when the network is unavailable, by maintaining a local cache and syncing changes bidirectionally. It's enabled by default for any redirected folder unless explicitly turned off via "Do not automatically make redirected folders available offline."

A folder can be redirected without Offline Files (network-only, breaks when offline); Offline Files can also be used on ordinary network shares that were never redirected via GPO at all (a user or admin manually marks a share "Always available offline"). The common enterprise deployment combines both: redirect the folder to a server share, then rely on Offline Files so the user isn't blocked by network interruptions.

### Folder Redirection Target Modes

Configured per-folder under **Properties → Target** in the GPO editor:

| Mode | Behavior |
|---|---|
| Basic — create a folder for each user under the root path | Generates `\\server\share\%username%\<FolderName>` per user automatically — the standard, low-maintenance choice |
| Basic — redirect to the following location | An explicit static path; multiple users sharing the same literal path unless environment variables are used to differentiate |
| Basic — redirect to the local user profile location | Effectively un-redirects, moving the folder back under the local profile |
| Advanced — specify locations for various user groups | Different target paths based on GPO security-group filtering — used when different user populations need different file server targets (e.g., by site/region) |

### What Happens at First Application

On first policy application, Windows **moves** (not copies) the existing local folder contents to the target location. This is a one-time, potentially slow operation — for a user with a large local Desktop/Documents folder, first redirection over a WAN link can take a long time and, if interrupted (laptop sleeps, network drops mid-move), can leave the folder in a partially-migrated, inconsistent state that manual cleanup may be needed to resolve.

### Policy Removal Behavior

What happens if the GPO scope changes (user moved out of the linked OU, policy unlinked) is explicitly configurable per folder, not automatic:

| Policy Removal setting | Result |
|---|---|
| Redirect the folder back to the user profile location when policy is removed | Folder returns to local profile; contents are **copied** (not moved) back — nothing is deleted from the server-side redirected location, and access to server-side content becomes local-computer-only from that point |
| Leave the folder in the new location when policy is removed | Folder stays pointed at the (now policy-orphaned) redirected location indefinitely |

Both options can produce a large, slow data-movement operation depending on content volume — this is a genuine planning consideration for OU restructuring or GPO cleanup work, not just a first-deployment concern.

### The Offline Files (CSC) Cache and Sync Engine

The local cache lives at `C:\Windows\CSC` and is size-bounded by the **"Limit disk space used by Offline Files"** policy — default 25% of the drive hosting the cache. Sync happens at several trigger points: logon, logoff, a configurable background interval, and manual ("Sync Now" in Sync Center). Each sync pass reconciles the local cache against the server copy in both directions.

**Conflict detection is the core safety mechanism**: if the local cached copy and the server copy have both changed since the last successful sync, Offline Files does not silently pick a winner — it surfaces the conflict in Sync Center and requires the user (or an admin acting on their behalf) to choose: keep the local version, keep the server version, or keep both (Windows appends a differentiator to one copy's filename). Microsoft's own guidance is explicit that Offline Files is best suited to paths with effectively single-writer semantics — heavy concurrent multi-user editing of the same files will generate frequent, genuine conflicts, not sync bugs to fix.

### Always Offline Mode

Configured via **"Configure slow-link mode"** (`Computer Configuration → Administrative Templates → Network → Offline Files`) with the **Latency** parameter set to `1` (millisecond) for a given UNC path (or `*` for all). Setting latency to 1 guarantees the client will *always* classify the link as "slow" and therefore never transition to Online mode for that share — it works exclusively from the local cache and only reconciles with the server on the **Background Sync** interval, which defaults to every 120 minutes and is separately configurable via "Configure Background Sync."

This is a deliberate design pattern for reducing WAN chatter and improving perceived responsiveness for remote/mobile users — every file operation is a local disk operation, not a network round-trip — at the cost of up to one Background Sync interval's worth of staleness relative to the server copy. Any latency threshold *above* 1 configures genuine adaptive slow-link behavior instead: the client transitions to Online mode when the link is fast enough and falls back to cache-only when it measures latency above the configured threshold.

### The AppData\Roaming Redirection Anti-Pattern

All special folders except AppData\Roaming can be redirected through the standard GPO UI without caveat. AppData\Roaming is technically redirectable but is specifically called out as conflict-prone: it holds files many applications (Outlook, Office, browsers, LOB apps) keep open continuously during a session and write to frequently. Under Offline Files' single-writer-oriented sync model, files with long-held open handles or frequent small writes are far more likely to generate genuine conflicts or fail to sync cleanly than user-document folders, which are typically opened, edited, and closed in discrete sessions.

### BranchCache's Shared Dependency

BranchCache's SMB caching mode (see `Troubleshooting/BranchCache-A.md`) is built on the same CSC (Client-Side Caching) infrastructure that powers Offline Files — specifically, it requires `CscService` to be running, even on machines that don't otherwise use Folder Redirection or Offline Files features directly. This is an architectural sharing of the underlying caching subsystem, not a coincidence, and it means a security baseline that disables Offline Files for unrelated reasons has a side effect on BranchCache SMB caching that's easy to miss during incident triage.

</details>

---

## Dependency Stack

```
AD DS domain, client domain-joined, GPO linked to the OU containing the USER object
   (Folder Redirection is a User Configuration setting — computer-only GPO scoping never
    applies it, regardless of which computer the user logs onto)
        │
Target UNC path exists, with NTFS + share permissions granting the user's per-folder subpath
   ("Grant the user exclusive rights" is on by default — admins do NOT get automatic access
    unless separately granted)
        │
First-application MOVE completes successfully (not interrupted mid-transfer)
        │
[Default, unless "Do not automatically make redirected folders available offline" is set]
Offline Files (CscService) enabled and running
        │
Local CSC cache within its configured size limit ("Limit disk space used by Offline Files",
default 25% of the cache drive)
        │
Sync triggers fire successfully: logon / logoff / background interval / manual
        │
Conflict detection resolves cleanly (no unresolved dual-edit conflicts sitting in Sync Center)
        │
[If Always Offline / slow-link mode is configured] Background Sync interval is the ONLY
reconciliation point — the client will not opportunistically sync sooner even on a fast link
        │
User sees current, correctly-located content
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---|---|---|
| Folder still points to local `C:\Users\...` path | GPO not applied — wrong OU scope, computer-only linking, or a failed first-move | `gpresult /r /scope:user`; check `User Shell Folders` registry values |
| Redirected folder inaccessible the instant network drops | Offline Files disabled or `CscService` stopped | `Get-Service CscService` |
| File shows a conflict icon | Genuine concurrent edit — expected behavior for multi-writer paths, not a bug | Sync Center → Conflicts view |
| New user on a shared machine sees odd offline/pinning behavior inherited from a prior user | Per-profile CSC pinning state persisted across profile change | Explorer folder properties → offline availability; consider profile cleanup |
| Sign-in noticeably slower since Folder Redirection deployment | No slow-link handling configured — synchronous full fetch every logon over a slow link | `Get-ItemProperty ...NetCache -Name SlowLinkEntries` |
| Folder never re-checks network even on a fast connection | Always Offline mode (Latency=1) — by design, not a fault | Same registry check; confirm the specific `Latency=` value configured |
| Outlook/Office settings intermittently reset or corrupt | AppData\Roaming was redirected — documented anti-pattern (open-handle conflicts) | `gpresult` — confirm whether AppData (Roaming) has a redirection policy applied |
| BranchCache SMB caching AND Folder Redirection offline access both broke at once | Shared root cause: `CscService` disabled (security baseline, GPO change) | `Get-Service CscService`; check recent GPO/baseline change history |
| First redirection deployment takes an extremely long time / times out | Large existing local folder content being moved synchronously over a slow link | Check folder size before deployment; consider off-hours rollout or pre-seeding |
| Content in the redirected location differs across two machines the same user uses | Sync hasn't completed on one machine yet (background interval hasn't fired), not necessarily a conflict | `Get-WinEvent -LogName "Microsoft-Windows-OfflineFiles/Operational"` on both machines |

---

## Validation Steps

**1. Confirm the GPO is actually linked and scoped to the user (not just the computer):**
```powershell
gpresult /r /scope:user
```
Expected: the Folder Redirection GPO appears under "Applied Group Policy Objects" for the user scope specifically.

**2. Confirm the actual live redirection target:**
```powershell
Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
```
Expected: UNC path matching the GPO's configured target for each redirected folder.

**3. Confirm Offline Files service and policy-level enablement:**
```powershell
Get-Service CscService | Select-Object Status, StartType
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetCache" -Name Enabled -ErrorAction SilentlyContinue
```
Expected: service `Running`/`Automatic`; policy `Enabled` (or absent, meaning default-on) rather than explicitly `0`.

**4. Confirm cache size headroom:**
```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetCache" -Name CacheSizeLimit -ErrorAction SilentlyContinue
Get-ChildItem C:\Windows\CSC -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
```
Compare current usage against the configured (or default 25%-of-drive) limit — a cache near its ceiling can silently stop accepting new offline content.

**5. Confirm no unresolved sync conflicts exist:**
```powershell
control /name Microsoft.SyncCenter
```
Review the Conflicts view manually — there's no fully reliable headless/PowerShell enumeration of Sync Center conflict state; the GUI is authoritative here.

**6. Confirm slow-link/Always-Offline configuration matches intent:**
```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetCache" -Name SlowLinkEntries -ErrorAction SilentlyContinue
```
A `Latency=1` entry for the relevant UNC path confirms Always Offline is deliberately active; any higher value confirms genuine adaptive slow-link behavior instead.

**7. Review the Offline Files operational event log for the specific failure signature:**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-OfflineFiles/Operational" -MaxEvents 100 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message | Format-Table -Wrap
```

---

## Troubleshooting Steps (by phase)

### Phase 1: Redirection Never Applied

1. `gpresult /r /scope:user` — confirm the GPO is in the applied list.
2. If missing: confirm OU linkage, security filtering, and WMI filters on the GPO; confirm the user object (not just the computer) is in scope.
3. If present but the folder still points locally: check the Application event log for Folder Redirection source events (502 = failed redirection is the most common) and confirm target-share NTFS/share permissions for that specific user's subpath.

### Phase 2: Offline Access Broken

1. `Get-Service CscService` — confirm running.
2. Confirm the "Do not automatically make redirected folders available offline" setting wasn't unintentionally enabled.
3. Check whether this coincides with a BranchCache SMB caching regression on the same machine (shared `CscService` dependency) — if so, treat as one root cause, not two tickets.

### Phase 3: Sync Conflicts

1. Open Sync Center, review each conflict individually — do not bulk-resolve without understanding which edit the user actually wants.
2. If conflicts are frequent on a specific path, escalate as a usage-pattern issue (multiple concurrent editors on a path designed for single-writer use), not a recurring technical fault.
3. Consider whether that specific workload should move to a co-authoring-aware platform (SharePoint/OneDrive) instead of continuing on Offline Files.

### Phase 4: Performance (Slow Logon / Slow Access)

1. Confirm whether slow-link mode is configured at all — its absence is the most common cause of a slow-logon regression after Folder Redirection deployment.
2. If configuring it: choose a realistic latency threshold, not `1` (which forces Always Offline and full cache-reliance, appropriate only for genuinely disconnected/mobile use cases).
3. Pair with "Configure Background Sync" tuning if the default 120-minute interval doesn't match the environment's connectivity patterns.

### Phase 5: AppData\Roaming Redirection Cleanup

1. Confirm via `gpresult` whether AppData (Roaming) actually has an active redirection policy.
2. If yes and app-corruption symptoms are present, plan a removal (set to Not Configured) rather than attempting to "fix" the conflict rate — this folder's redirection is not a supportable long-term configuration.
3. For settings-continuity goals that motivated the original AppData redirection, evaluate Enterprise State Roaming / Windows Backup for Organizations (`Troubleshooting/WindowsBackup-A.md`) as the modern replacement mechanism.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Deploy Folder Redirection with Offline Files correctly from scratch</summary>

```
User Configuration → Policies → Windows Settings → Folder Redirection → <Folder> → Properties
  Target tab: Basic — Create a folder for each user under the root path
  Root Path: \\<fileserver>\<share>
  Settings tab: Grant the user exclusive rights to <FolderName> = checked (default)
                Move the contents of <FolderName> to the new location = checked (first deploy only)
                Policy Removal: choose deliberately (see How It Works — Policy Removal Behavior)
```

Pre-provision the share with appropriate root-level NTFS permissions (Authenticated Users: Create Folders/Append Data + List Folder, this folder only — not Read/List on other users' subfolders) so the per-user subfolder creation succeeds without requiring elevated rights at redirection time.

Verify Offline Files defaults to enabled for the redirected folder (no need to separately configure unless intentionally disabling it):
```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetCache" -Name Enabled -ErrorAction SilentlyContinue
```

**Rollback:** set the folder's Target to "Redirect to the local user profile location," choose the desired Policy Removal behavior, `gpupdate /force /target:user`.

</details>

<details><summary>Playbook 2 — Configure realistic slow-link / Always Offline behavior</summary>

For adaptive slow-link handling (recommended default for most fleets):
```
Computer Configuration → Administrative Templates → Network → Offline Files
  → Configure slow-link mode: Enabled
     UNC Paths: \\<fileserver>\<share>\*   Value: Latency=<realistic-ms-threshold>
  → Configure Background Sync: Enabled, tune interval/variance to environment connectivity
```

For deliberate Always Offline (mobile/remote-heavy user populations):
```
  → Configure slow-link mode: Enabled
     UNC Paths: *   Value: Latency=1
  → Configure Background Sync: Enabled, interval tuned to acceptable staleness window
```

**Verify:**
```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetCache" -Name SlowLinkEntries
```

**Rollback:** disable "Configure slow-link mode" to return to default synchronous online/offline transition behavior.

</details>

<details><summary>Playbook 3 — Remove AppData\Roaming redirection safely</summary>

```
User Configuration → Policies → Windows Settings → Folder Redirection → AppData (Roaming)
  → Setting: Not Configured
```
Run `gpupdate /force /target:user` on affected machines. On next logon, AppData\Roaming reverts to the local profile per the folder's own Policy Removal setting (copy-back if "Redirect back to user profile" was set; otherwise it stays at the redirected path until manually addressed).

For teams needing settings continuity across devices as the original motivation, evaluate:
```
Windows Backup for Organizations (Windows settings backup and restore) — see Troubleshooting/WindowsBackup-A.md
Enterprise State Roaming (Entra-native app-settings sync) — check current tenant configuration
```

**Rollback:** re-enable AppData (Roaming) redirection — not recommended given the documented conflict risk; only do so as a short-term compatibility bridge with a defined removal date.

</details>

<details><summary>Playbook 4 — Recover from an interrupted first-redirection move</summary>

Use when a first-time redirection move was interrupted (network drop, laptop sleep) and left the folder in a mixed state (some content local, some moved, possibly duplicated).

```powershell
# On the client — inventory what's actually where before touching anything
Get-ChildItem "$env:USERPROFILE\<FolderName>" -Recurse -ErrorAction SilentlyContinue |
    Select-Object FullName, Length, LastWriteTime | Export-Csv "$env:TEMP\local-inventory.csv" -NoTypeInformation

Get-ChildItem "\\<fileserver>\<share>\$env:USERNAME\<FolderName>" -Recurse -ErrorAction SilentlyContinue |
    Select-Object FullName, Length, LastWriteTime | Export-Csv "$env:TEMP\server-inventory.csv" -NoTypeInformation
```
Compare the two inventories manually (or via a diff script) before deciding what to reconcile — do not simply re-run the GPO's move operation, since a second automatic move can silently overwrite content on either side depending on which path the folder currently resolves to.

Once content is reconciled and verified server-side, re-trigger a clean redirection:
```powershell
gpupdate /force /target:user
```

**Rollback:** N/A — this is a recovery procedure. Document what was found and reconciled for the ticket record.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect Folder Redirection / Offline Files evidence for escalation
.NOTES     Run as the affected user (or under their profile context) — HKCU and per-user
           CSC state require the user's own session, not just local admin rights.
#>

$OutputDir = "$env:TEMP\FolderRedirection-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# 1. Current redirection targets
Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" |
    Out-File "$OutputDir\UserShellFolders.txt"

# 2. GPO application results
gpresult /r /scope:user | Out-File "$OutputDir\gpresult-user.txt"
gpresult /h "$OutputDir\gpresult-full.html" /f

# 3. Offline Files service and policy state
Get-Service CscService | Select-Object Status, StartType |
    Export-Csv "$OutputDir\CscService-State.csv" -NoTypeInformation
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetCache" -ErrorAction SilentlyContinue |
    Out-File "$OutputDir\NetCache-Policy.txt"

# 4. Cache size usage
Get-ChildItem C:\Windows\CSC -Recurse -Force -ErrorAction SilentlyContinue |
    Measure-Object -Property Length -Sum |
    Select-Object Count, @{N='TotalMB';E={[math]::Round($_.Sum/1MB,2)}} |
    Export-Csv "$OutputDir\CSCCacheSize.csv" -NoTypeInformation

# 5. Offline Files operational event log (last 200 events)
Get-WinEvent -LogName "Microsoft-Windows-OfflineFiles/Operational" -MaxEvents 200 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, LevelDisplayName, Message |
    Export-Csv "$OutputDir\OfflineFiles-Events.csv" -NoTypeInformation

# 6. Network path reachability at time of evidence collection
foreach ($path in @("<UNC-path-to-test>")) {
    [PSCustomObject]@{ Path = $path; Reachable = (Test-Path $path -ErrorAction SilentlyContinue) }
} | Export-Csv "$OutputDir\PathReachability.csv" -NoTypeInformation

Write-Host "Evidence collected: $OutputDir" -ForegroundColor Green
Compress-Archive -Path "$OutputDir\*" -DestinationPath "$OutputDir.zip"
Write-Host "Archive: $OutputDir.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# Current redirection targets
Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"

# GPO application
gpresult /r /scope:user
gpupdate /force /target:user

# Offline Files service
Get-Service CscService
Set-Service CscService -StartupType Automatic; Start-Service CscService

# Offline Files policy state
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\NetCache"

# Sync Center (GUI — no full headless equivalent for conflict resolution)
control /name Microsoft.SyncCenter

# Cache size
Get-ChildItem C:\Windows\CSC -Recurse -Force | Measure-Object -Property Length -Sum

# Event log
Get-WinEvent -LogName "Microsoft-Windows-OfflineFiles/Operational" -MaxEvents 50

# Network path check
Test-Path \\<server>\<share>
```

---

## 🎓 Learning Pointers

- **Folder Redirection is a User Configuration policy; Offline Files is largely a Computer Configuration policy.** A common deployment mistake is scoping the GPO only to computer OUs (fine for Offline Files settings) while forgetting the redirection half needs the *user* object in scope — the two halves of "make this feel seamless offline" live in different Group Policy branches. [MS Docs: Folder Redirection using Group Policy](https://learn.microsoft.com/en-us/windows-server/storage/folder-redirection/folder-redirection-using-group-policy)

- **A sync conflict is the system working correctly, not failing.** The alternative to surfacing a conflict is silently discarding one person's edit — Offline Files is deliberately conservative here. Frequent conflicts on a specific path are a usage-pattern signal (too many concurrent editors) rather than a technical defect to keep patching around.

- **Always Offline mode (Latency=1) trades network round-trips for staleness, on purpose.** It's the right call for genuinely mobile/roaming users where responsiveness matters more than real-time freshness — but applying it broadly to office-based users who are almost always on a fast link just adds unnecessary staleness with no benefit. Match the latency threshold to the actual population being configured.

- **AppData\Roaming redirection is a known anti-pattern for a structural reason, not a configuration nuance** — it holds files applications keep open and write to continuously, which is fundamentally at odds with a sync model built around discrete open/edit/close cycles. If inherited in an existing environment, treat its removal as overdue cleanup rather than a risky change.

- **BranchCache SMB caching and Offline Files share the same `CscService` foundation.** This repo's BranchCache runbook depends on this fact explicitly — recognizing the shared dependency turns "two features broke at once" into "one service got disabled," a much faster diagnosis. See `Troubleshooting/BranchCache-A.md`.

- **For Entra-joined/hybrid-modern fleets, OneDrive Known Folder Move has largely superseded Folder Redirection** for Desktop/Documents/Pictures — it doesn't require AD DS GPO delivery and uses cloud sync instead of CSC. Folder Redirection remains the right tool specifically where AD DS GPO is the management plane and/or the target needs to be an on-prem file server, not OneDrive. See `M365/SharePoint-OneDrive/Sync-Issues-A.md` for the OneDrive-side equivalent troubleshooting.
