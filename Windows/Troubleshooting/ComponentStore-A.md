# Component Store Corruption (DISM / SFC / CBS) — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what. Hotfix path: [`ComponentStore-B.md`](ComponentStore-B.md). Evidence script: [`../Scripts/Get-ComponentStoreHealth.ps1`](../Scripts/Get-ComponentStoreHealth.ps1).

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
- **In scope:** Windows 10/11 and Windows Server 2016–2025 servicing via Component-Based Servicing (CBS): the WinSxS component store, the `COMPONENTS` hive, TrustedInstaller, DISM `/Cleanup-Image` operations, SFC, and how cumulative updates (LCU) and servicing stack updates (SSU) consume the store.
- **Out of scope:** the update *delivery* pipeline (WU client, WSUS approvals, WUfB rings, Delivery Optimization) — see `Windows Update/Update to Latest B.md`, `Intune/Troubleshooting/WUfB-B.md`, `DeliveryOptimization-A.md`. Feature-update (setup.exe / upgrade) failures, except as a repair vehicle. Offline servicing of images for deployment (covered only where the same commands apply).
- **Assumes:** local admin, elevated PowerShell, and access to install media or a donor of the **same build** when Windows Update can't supply payloads.

---
## How It Works
<details><summary>Full architecture</summary>

### The component model
Since Vista, Windows is not a set of files — it's a set of **components**. Each component (e.g. `amd64_microsoft-windows-kernel32_31bf3856ad364e35_10.0.20348.2849_none_...`) is:
- a **manifest** (XML: identity, version, file list, file hashes, registry, dependencies), and
- **payload files**, stored once under `C:\Windows\WinSxS\<component-directory>\`.

The files you see in `C:\Windows\System32` are **hard links** to the payload in WinSxS. That's why Explorer over-reports WinSxS size — most of it is the same bytes counted twice. `/AnalyzeComponentStore` reports the real figure ("Actual Size of Component Store" vs "Shared with Windows").

### Packages, not components, are what you install
An LCU `.msu`/`.cab` is a **package**: a collection of component versions plus an applicability description. CBS tracks package state in the `COMPONENTS` hive (`C:\Windows\System32\config\COMPONENTS`, loaded on demand) and in `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages`.

```
Package (KB50xxxxx)             <- what WU / wusa / DISM /Add-Package install
  └── Deployments / Updates
        └── Component versions  <- manifest in WinSxS\Manifests, payload in WinSxS\<dir>
              └── Projected files (hard links into System32, SysWOW64, ...)
```

### Express / differential payloads — why an old baseline matters
Modern LCUs (Windows 10 1809+/Server 2019+) ship **forward and reverse differentials** rather than full files. Installing an LCU means: take the **RTM baseline** of each component (kept in the store), apply the forward diff to reach the new version. Uninstalling applies the reverse diff.

Consequence: if the baseline manifest or payload of a component is missing, the LCU **cannot compute the new file** → `0x800f0831` ("CBS_E_STORE_CORRUPTION"-class failures naming a missing package) or `0x80073712` (ERROR_SXS_COMPONENT_STORE_CORRUPT). The fix is not "retry harder" — it's to restore the missing baseline from a source that has it.

### TrustedInstaller and the transaction
Only **TrustedInstaller** (service *Windows Modules Installer*, `TrustedInstaller.exe`) can write the store. Servicing happens in two stages:
1. **Online stage** — staging: payloads are resolved, diffs computed, files written as pending.
2. **Offline stage** (during shutdown/boot, the "Working on updates" screen) — `poqexec.exe` executes `C:\Windows\WinSxS\pending.xml`: renames, hard-link swaps, registry commits that can't be done while files are in use.

If the machine loses power or `poqexec` fails, `pending.xml` survives and the `RebootPending` / `SessionsPending` keys stay set. **Every further servicing operation is blocked or rolled back until the transaction is resolved.** This is why "reboot first" is always step 1.

### Where the corruption marker lives
DISM `/CheckHealth` does not scan anything. It reads a flag CBS sets when a prior operation detected corruption (under `HKLM\...\Component Based Servicing` — `Corruption`-related values). A clean `/CheckHealth` only means "nobody has recorded corruption yet".

`/ScanHealth` hashes every payload file against its manifest and verifies manifests exist for installed component versions. It writes findings to `CBS.log` (`CSI Payload Corrupt`, `CSI Manifest ... missing`) and sets the flag.

`/RestoreHealth` = ScanHealth + fetch replacement payloads from a **repair source** + rewrite them.

### Repair source resolution order
```
DISM /RestoreHealth
 ├─ /Source:<...> given?  → try each explicit source first
 │     (wim:<path>:<index>, esd:<path>:<index>, a mounted image's Windows folder, or \\donor\c$\Windows\WinSxS)
 ├─ /LimitAccess given?   → STOP here (don't touch WU/WSUS)
 └─ otherwise → the configured update source:
        ├─ GPO "Specify settings for optional component installation and component repair"
        │     RepairContentServerSource = 2  → Windows Update directly (bypasses WSUS)
        │     LocalSourcePath               → alternate file path(s)
        ├─ Machine is WSUS-managed (UseWUServer=1) and no override → asks WSUS
        │     → WSUS never hosts repair payloads → 0x800f081f
        └─ Unmanaged → Windows Update → succeeds if the exact component versions are on WU
```

### SFC vs DISM
- **SFC** (`sfc /scannow`) checks *protected system files in their projected locations* (System32 etc.) against the store, and **copies from the store** to fix them. It cannot repair the store.
- **DISM** repairs the **store** from an external source.
- Therefore: DISM first, then SFC. SFC "unable to fix" almost always means the store copy is itself bad.

### Cleanup operations
| Operation | What it does | Reversible? |
|---|---|---|
| `/AnalyzeComponentStore` | Reports actual size, reclaimable packages, last cleanup date, "Component Store Cleanup Recommended" | Read-only |
| `/StartComponentCleanup` | Removes superseded component versions older than the grace period (the scheduled task `\Microsoft\Windows\Servicing\StartComponentCleanup` does this with a 30-day grace) | Superseded updates can no longer be uninstalled |
| `/StartComponentCleanup /ResetBase` | Removes **all** superseded versions immediately and makes the current state the new baseline | **No** — no installed update can be uninstalled afterwards |
| `/SPSuperseded` | Legacy (SP-era) | n/a on modern builds |
| Third-party "WinSxS cleaners" / manual deletion | Breaks hard links and manifests | **No** — the #1 source of "not repairable" |

### Why in-place upgrade is the backstop
An in-place upgrade (setup.exe, same or newer build, "Keep personal files and apps") rebuilds the entire store from the install media and re-applies the installed state. It's the supported last resort short of reinstall. On Server, it preserves roles for supported paths but is a change event — back up first and check role-specific upgrade guidance (DCs, clusters, RDS).
</details>

---
## Dependency Stack
```
[L7] Update / feature install succeeds; SFC reports no violations
[L6] Correct SSU present for the LCU (combined SSU+LCU on Win11 / Server 2022+)
[L5] Repair source reachable and MATCHING (build + edition + language + patch level)
        ├─ Windows Update (not blocked by WSUS policy / proxy / firewall)
        ├─ install.wim / install.esd of same build
        └─ healthy donor WinSxS at same patch level
[L4] Component store consistent
        ├─ Manifests present (WinSxS\Manifests)
        ├─ Payload hashes match
        └─ RTM baselines present for every component an LCU diffs against
[L3] CBS metadata loadable
        ├─ COMPONENTS hive (System32\config\COMPONENTS)
        └─ CBS\Packages registry state consistent with the store
[L2] No pending transaction (pending.xml processed, RebootPending/SessionsPending clear)
        └─ TrustedInstaller service startable (Manual, LocalSystem)
[L1] Volume & disk healthy; free space on C: and the EFI / System Reserved partition
        └─ No filter driver (AV/DLP/backup) blocking TrustedInstaller writes
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| `0x800f081f` "source files could not be found" | No usable repair source — WSUS-managed without override, or source at wrong build | `Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' UseWUServer`; `...\Policies\Servicing` |
| `0x800f0831` on LCU install | Missing baseline manifest from a prior package | `CBS.log` "Failed to get the underlying CBS package" / package identity named |
| `0x80073712` | Store file/manifest missing | `DISM /ScanHealth` then CBS.log `CSI Manifest` lines |
| `0x800f0922` | ESP / System Reserved full, or network call blocked during install (VPN/proxy) | ESP free space; retry off VPN |
| `0x80070002` in CBS during repair | File not found in source → source wrong build | Compare build of source (`Get-WindowsImage -ImagePath ... -Index n`) with `winver` |
| `0x800f0906` (feature install, e.g. .NET 3.5) | Same root as 081f for Features on Demand | `RepairContentServerSource`, or `/Source` to `sources\sxs` |
| SFC "unable to fix some" | Store copy is bad | DISM RestoreHealth first |
| "The component store is not repairable" | Manifest / hive damage beyond payload replacement | Playbook 4 (in-place upgrade) |
| DISM hangs at 62.3% / 84.9% | Normal long phases on large stores; true hang if CPU/disk idle for >60 min | `Get-Process TiWorker`; `dism.log` last timestamp |
| Update installs then reverts at reboot ("Undoing changes") | Offline stage failure (poqexec) or filter driver | `C:\Windows\Logs\CBS\CBS.log` around boot, `Setup` event log, `fltmc` |
| Every update fails immediately | pending.xml / RebootPending, TrustedInstaller disabled | Registry keys; `Get-Service TrustedInstaller` |
| WinSxS "huge" | Superseded versions never cleaned (task disabled) — or Explorer double-counting hard links | `/AnalyzeComponentStore` actual size |
| Corruption keeps returning after repair | Failing disk, bad RAM, or cleaner tool/script running on schedule | `Get-PhysicalDisk`, `System` log disk/NTFS events, scheduled tasks |

---
## Validation Steps
1. **Build and patch level** (source matching depends on this)
   ```powershell
   $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
   '{0} build {1}.{2} {3}' -f $cv.ProductName, $cv.CurrentBuildNumber, $cv.UBR, $cv.EditionID
   ```
   Good: a concrete build.UBR — e.g. `20348.3207`. Record it.
2. **No pending transaction**
   ```powershell
   $cbs = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
   'RebootPending','SessionsPending','PackagesPending' | ForEach-Object { '{0}: {1}' -f $_, (Test-Path "$cbs\$_") }
   Test-Path C:\Windows\WinSxS\pending.xml
   ```
   Good: all `False`. Bad: any `True` after a reboot → Playbook 3.
3. **TrustedInstaller can start**
   ```powershell
   Get-Service TrustedInstaller | Select-Object Status, StartType
   ```
   Good: `Manual` (Stopped is normal when idle). Bad: `Disabled` — something hardened it; set back to Manual.
4. **Store scan**
   ```powershell
   DISM /Online /Cleanup-Image /ScanHealth
   ```
   Good: "No component store corruption detected." Bad: "repairable" / "not repairable".
5. **Repair source policy**
   ```powershell
   Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing' -ErrorAction SilentlyContinue |
     Select-Object LocalSourcePath, RepairContentServerSource, UseWindowsUpdate
   Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction SilentlyContinue | Select-Object UseWUServer
   ```
   Good on WSUS-managed: `RepairContentServerSource = 2` or a valid `LocalSourcePath`. Bad: `UseWUServer = 1` with neither.
6. **Store size and cleanup posture**
   ```powershell
   DISM /Online /Cleanup-Image /AnalyzeComponentStore
   Get-ScheduledTask -TaskPath '\Microsoft\Windows\Servicing\' -TaskName StartComponentCleanup | Select-Object State
   ```
   Good: task `Ready`; "Component Store Cleanup Recommended: No". Bad: task `Disabled` → store will bloat.
7. **Post-repair**
   ```powershell
   sfc /scannow
   Get-WinEvent -LogName Setup -MaxEvents 10 | Select-Object TimeCreated, Id, Message
   ```
   Good: SFC clean; Setup log shows the retried KB with "installed successfully" (Event 2).

---
## Troubleshooting Steps (by phase)
### Phase 1 — Is it really the store?
- Reboot; re-check pending keys.
- Run ScanHealth. If clean and the update still fails, the store isn't the problem: check ESP/System Reserved space, SSU version, filter drivers (`fltmc`), proxy/VPN, and the `Setup` + `WindowsUpdateClient/Operational` logs.

### Phase 2 — What exactly is corrupt?
```powershell
Select-String C:\Windows\Logs\CBS\CBS.log -Pattern 'CSI Payload Corrupt|CSI Manifest|Repair failed|Failed to get the underlying|Mark store corruption' |
  Select-Object -Last 40 | ForEach-Object Line
```
- `CSI Payload Corrupt ... <file>` → payload hash mismatch — WU or matching media usually fixes.
- `Manifest ... missing` for an **old** version → baseline issue — needs RTM-level media of the same build (fresh ISO is fine here).
- Missing component at a **recent** version → need a same-patch-level donor or WU.
- Also read `CBS.persist.log` and `CbsPersist_*.cab` (rotated logs) if the event predates the current `CBS.log`.

### Phase 3 — Get a source that matches
- Build number must match (e.g. 20348 for Server 2022, 26100 for Server 2025 / Win11 24H2). Edition index must match (Standard vs Datacenter, Core vs Desktop Experience). Language must include the installed base language.
- For recent-version components, patch the *image* first: mount `install.wim`, `Add-WindowsPackage` the same LCU, then use the mounted `Windows` folder as `/Source`.

### Phase 4 — Repair, then prove it
- RestoreHealth → ScanHealth → SFC → retry the failing KB manually (`.msu` from the Catalog) → confirm with `Get-HotFix` and the Setup log.

### Phase 5 — Stop it recurring
- Disk health, RAM diagnostics on physical hosts, remove WinSxS "cleaners", re-enable the StartComponentCleanup task, fix the repair-source GPO permanently.

---
## Remediation Playbooks
<details><summary>Playbook 1 — Permanent repair source for WSUS/ConfigMgr-managed estates</summary>

GPO: *Computer Configuration → Administrative Templates → System → Specify settings for optional component installation and component repair*
- **Enabled**
- *Alternate source file path*: `wim:\\<fileserver>\<share>\<build>\install.wim:<index>` (optional — only if you maintain per-build images)
- *Never attempt to download payload from Windows Update*: **unchecked**
- *Download repair content and optional features directly from Windows Update instead of WSUS*: **checked** (writes `RepairContentServerSource = 2`)

Verify on a client after `gpupdate /force`:
```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing'
```
Rollback: set the GPO to Not Configured. Requires outbound access to Windows Update endpoints — confirm proxy/firewall allow it for servers.
</details>

<details><summary>Playbook 2 — Build a patched source image (recent-version components)</summary>

```powershell
$wim   = 'C:\Repair\install.wim'          # copied from same-build ISO (make writable)
$mount = 'C:\Repair\Mount'
$lcu   = '<C:\Repair\windows10.0-kb50xxxxx-x64.msu>'   # the SAME LCU the broken host has / needs
New-Item $mount -ItemType Directory -Force | Out-Null
Set-ItemProperty $wim -Name IsReadOnly -Value $false
Mount-WindowsImage -ImagePath $wim -Index <Index> -Path $mount
Add-WindowsPackage -Path $mount -PackagePath $lcu
DISM /Online /Cleanup-Image /RestoreHealth /Source:$mount\Windows /LimitAccess
Dismount-WindowsImage -Path $mount -Discard
```
`-Discard` leaves the WIM unchanged; use `-Save` if you want to keep a patched repair image for the fleet. Cleanup: `Remove-Item C:\Repair -Recurse` when done. If mount fails later with "image already mounted": `DISM /Cleanup-Wim`.
</details>

<details><summary>Playbook 3 — Resolve a stuck transaction (pending.xml)</summary>

1. Reboot twice, watching for "Working on updates" completing.
2. If still pending, from an elevated prompt:
   ```powershell
   DISM /Online /Cleanup-Image /RevertPendingActions
   Restart-Computer
   ```
3. If the OS won't boot past "Undoing changes" loops: boot WinRE → Command Prompt → identify the OS volume (`dir D:\Windows`) →
   ```
   dism /Image:D:\ /Cleanup-Image /RevertPendingActions
   ```
**Risk:** discards the in-flight update set; the KB will need reinstalling. Do **not** rename/delete `pending.xml` by hand unless Microsoft support directs it — it leaves CBS metadata and the store out of sync.
</details>

<details><summary>Playbook 4 — In-place upgrade repair ("not repairable")</summary>

Preconditions: verified full backup / VM snapshot (see `WindowsServerBackup-A.md`), same-or-newer build media of the same edition and language, role-specific guidance checked (DCs: prefer demote/rebuild; clusters: drain node; RDS: drain host — `RDSessionHost-B.md`).
```powershell
# From mounted ISO drive <X:>
X:\setup.exe /auto upgrade /imageindex <Index> /dynamicupdate disable /compat scanonly   # compatibility pre-check
X:\setup.exe /auto upgrade /imageindex <Index> /dynamicupdate disable /showoobe none
```
Server: `/imageindex` must match the installed edition (Core vs Desktop Experience cannot be changed this way on 2016/2019/2022). Afterwards: re-apply the latest SSU/LCU, run ScanHealth, SFC.
Rollback: restore snapshot/backup; on client OS `Settings → Recovery → Go back` works for ~10 days.
</details>

<details><summary>Playbook 5 — Reclaim space safely</summary>

```powershell
DISM /Online /Cleanup-Image /AnalyzeComponentStore
DISM /Online /Cleanup-Image /StartComponentCleanup
# Only with change approval — makes all current updates permanent:
# DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase
Enable-ScheduledTask -TaskPath '\Microsoft\Windows\Servicing\' -TaskName StartComponentCleanup
```
</details>

---
## Evidence Pack
Run the companion script (read-only, CSV + log bundle):
```powershell
.\Get-ComponentStoreHealth.ps1 -OutputPath C:\Temp\CBS-Evidence -RunScanHealth -CollectLogs
```
Or minimal inline collection:
```powershell
$out = "C:\Temp\CBS-Evidence-$env:COMPUTERNAME"; New-Item $out -ItemType Directory -Force | Out-Null
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
"$($cv.ProductName) $($cv.EditionID) $($cv.CurrentBuildNumber).$($cv.UBR)" | Out-File "$out\build.txt"
DISM /Online /Cleanup-Image /CheckHealth           | Out-File "$out\checkhealth.txt"
DISM /Online /Cleanup-Image /AnalyzeComponentStore | Out-File "$out\analyze.txt"
Get-HotFix | Sort-Object InstalledOn -Descending   | Out-File "$out\hotfix.txt"
fltmc                                              | Out-File "$out\fltmc.txt"
Get-WinEvent -LogName Setup -MaxEvents 50 | Format-List TimeCreated, Id, Message | Out-File "$out\setup-events.txt"
Copy-Item C:\Windows\Logs\CBS\CBS.log, C:\Windows\Logs\DISM\dism.log $out -ErrorAction SilentlyContinue
Get-ChildItem C:\Windows\Logs\CBS -Filter 'CbsPersist_*' | Sort-Object LastWriteTime -Descending | Select-Object -First 3 | Copy-Item -Destination $out
Compress-Archive "$out\*" "$out.zip" -Force
```

---
## Command Cheat Sheet
| Command | Purpose |
|---|---|
| `DISM /Online /Cleanup-Image /CheckHealth` | Read corruption flag (seconds) |
| `DISM /Online /Cleanup-Image /ScanHealth` | Full hash scan |
| `DISM /Online /Cleanup-Image /RestoreHealth` | Repair via configured source |
| `... /RestoreHealth /Source:wim:X:\sources\install.wim:2 /LimitAccess` | Repair from media only |
| `... /RestoreHealth /Source:\\donor\c$\Windows\WinSxS /LimitAccess` | Repair from donor |
| `sfc /scannow` | Repair projected files from store |
| `DISM /Online /Cleanup-Image /AnalyzeComponentStore` | Real store size, cleanup recommendation |
| `DISM /Online /Cleanup-Image /StartComponentCleanup` | Remove superseded versions (grace period) |
| `DISM /Online /Cleanup-Image /RevertPendingActions` | Abandon stuck transaction |
| `Get-WindowsImage -ImagePath X:\sources\install.wim` | List editions/indexes in media |
| `Get-WindowsPackage -Online \| Where PackageState -ne Installed` | Packages in odd states (Staged, InstallPending, Superseded) |
| `DISM /Online /Get-Packages /Format:Table` | Package list incl. state |
| `wusa <file.msu> /quiet /norestart` | Manual LCU install |
| `Select-String C:\Windows\Logs\CBS\CBS.log -Pattern 'CSI Payload Corrupt'` | Corrupt payload list |
| `DISM /Cleanup-Wim` | Clear orphaned WIM mounts |

---
## 🎓 Learning Pointers
- The store holds components (manifest + payload) and System32 is hard links into it — read [Manage the Component Store](https://learn.microsoft.com/windows-hardware/manufacture/desktop/manage-the-component-store) before trusting any WinSxS size figure.
- LCUs are differentials against an RTM baseline, which is why a missing *old* manifest breaks a *new* update (`0x800f0831`). Background: [Windows quality update packaging (forward/reverse differentials)](https://learn.microsoft.com/windows/deployment/update/psfxwhitepaper).
- WSUS doesn't serve repair payloads; set the component-repair GPO once and `0x800f081f` largely disappears from WSUS estates. [Configure a Windows repair source](https://learn.microsoft.com/windows-hardware/manufacture/desktop/configure-a-windows-repair-source).
- `/ResetBase` is irreversible — understand the trade-off in [Clean up the WinSxS folder](https://learn.microsoft.com/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder).
- Error-code reference for servicing failures: [Windows Update common errors and mitigation](https://learn.microsoft.com/troubleshoot/windows-client/installing-updates-features-roles/common-windows-update-errors).
- Before an in-place upgrade on a server role, check the role guidance and get a restorable backup — `WindowsServerBackup-A.md`, `RDSessionHost-B.md`.
