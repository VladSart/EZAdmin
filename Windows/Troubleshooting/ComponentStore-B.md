# Component Store Corruption (DISM / SFC / CBS) — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes. Covers `0x800f081f`, `0x800f0831`, `0x800f0922`, `0x80073712`, SFC "unable to fix", and cumulative updates that fail and roll back.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage
Elevated PowerShell. Steps 1–3 take under a minute; step 4 takes 5–30 min — start it and read on.

```powershell
# 1. Build + pending reboot state
Get-ComputerInfo -Property OsName, OsBuildNumber, OsHardwareAbstractionLayer
Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
Test-Path 'C:\Windows\WinSxS\pending.xml'

# 2. Fast corruption flag (reads the registry marker only, seconds)
DISM /Online /Cleanup-Image /CheckHealth

# 3. Last servicing errors
Select-String -Path C:\Windows\Logs\CBS\CBS.log -Pattern 'error|0x800f|corrupt' | Select-Object -Last 20

# 4. Real scan (minutes)
DISM /Online /Cleanup-Image /ScanHealth
```

| Result | Meaning | Go to |
|---|---|---|
| `RebootPending` / `pending.xml` present | Servicing stack is mid-transaction; every repair will fail or be undone | Reboot first, re-triage |
| CheckHealth: "No component store corruption detected" **and** ScanHealth clean | Store is fine — the failing update's cause is elsewhere (disk space, SSU, 3rd-party filter driver) | Fix 5 |
| "The component store is repairable" | Corruption found, source needed | Fix 1 → Fix 2 |
| RestoreHealth fails `0x800f081f` "source files could not be found" | Windows Update can't supply the payload (WSUS-managed, offline, or the exact build is missing) | Fix 2 |
| `0x800f0831` on CU install | A prior LCU's manifest is missing — store lost a baseline | Fix 2 (matching-build source) then Fix 4 |
| `0x80073712` | Component store file missing / corrupt | Fix 1 / Fix 2 |
| `0x800f0922` | Usually System Reserved/EFI partition full or a VPN/proxy blocking a servicing call — not store corruption | Fix 5 |
| SFC "found corrupt files but was unable to fix some of them" | SFC's source (the store) is itself bad | Fix 1 then re-run SFC |
| "The component store is not repairable" | Deeper damage (often from disk failure or aggressive "cleanup" tools) | Fix 3 / escalate |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Cumulative update installs / SFC can repair
└── TrustedInstaller (Windows Modules Installer) service can start
    └── Servicing stack (SSU) current enough for the LCU being applied
        └── No pending transaction (pending.xml / RebootPending cleared)
            └── Component store C:\Windows\WinSxS consistent
                ├── Manifests (.manifest) present for every installed component version
                ├── Payload files hash-match their manifests
                └── COMPONENTS registry hive (C:\Windows\System32\config\COMPONENTS) loadable
                    └── Repair source available for any missing payload:
                        ├── Windows Update (blocked if WSUS-managed & "Specify settings for optional component installation" not set)
                        ├── WSUS — does NOT serve repair payloads
                        └── Offline source: install.wim/.esd of the SAME build + edition + language
                            └── Disk healthy (chkdsk clean, no bad sectors under WinSxS)
```
</details>

---
## Diagnosis & Validation Flow
1. **Clear any pending transaction** — reboot. If `pending.xml` persists across two reboots, go to Fix 3.
2. **Run ScanHealth and read the verdict**
   ```powershell
   DISM /Online /Cleanup-Image /ScanHealth
   ```
   Expected good: "No component store corruption detected."
3. **Identify what's corrupt**
   ```powershell
   Select-String C:\Windows\Logs\CBS\CBS.log -Pattern 'CSI Payload Corrupt|CSI Manifest|Repair failed|Store corruption' |
     Select-Object -Last 30 | ForEach-Object Line
   ```
   Names the component (e.g. `amd64_microsoft-windows-...`) and version — tells you which build your repair source must contain.
4. **Check disk health before repairing** (repairing on a failing disk wastes time)
   ```powershell
   Get-PhysicalDisk | Select-Object FriendlyName, HealthStatus, OperationalStatus
   Repair-Volume -DriveLetter C -Scan
   ```
   Good: Healthy / "NoErrorsFound".
5. **After repair, validate**
   ```powershell
   DISM /Online /Cleanup-Image /ScanHealth
   sfc /scannow
   Get-WindowsUpdateLog  # optional, writes WindowsUpdate.log to Desktop for the retry
   ```
   Expected: DISM clean; SFC "did not find any integrity violations" or "found corrupt files and successfully repaired them".

---
## Common Fix Paths

<details><summary>Fix 1 — Standard online repair (Windows Update as source)</summary>

```powershell
DISM /Online /Cleanup-Image /RestoreHealth
sfc /scannow
```
If the machine is WSUS/ConfigMgr-managed, RestoreHealth tries WSUS and gets nothing → `0x800f081f`. Temporarily allow Windows Update as repair source:
```powershell
$k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Servicing'
New-Item $k -Force | Out-Null
Set-ItemProperty $k -Name RepairContentServerSource -Value 2 -Type DWord   # 2 = contact Windows Update directly
DISM /Online /Cleanup-Image /RestoreHealth
# Rollback: Remove-ItemProperty $k -Name RepairContentServerSource   (or let GPO re-apply)
```
This is the registry value behind GPO *Computer Configuration → Administrative Templates → System → "Specify settings for optional component installation and component repair"*. GPO refresh will overwrite it — fix the GPO for a permanent change.
</details>

<details><summary>Fix 2 — Offline source from matching install media (0x800f081f, 0x800f0831)</summary>

The source must match **build, edition and language**. A fresh ISO is usually older than the patched OS — that's fine for base components, but for LCU-era components you may need a same-month image (Visual Studio Subscriptions / VLSC / media refreshed monthly) or a healthy donor.
```powershell
$iso = '<\\server\share\WindowsServer2022.iso>'
$m = Mount-DiskImage -ImagePath $iso -PassThru
$drv = ($m | Get-Volume).DriveLetter
Get-WindowsImage -ImagePath "$drv`:\sources\install.wim" | Select-Object ImageIndex, ImageName
# Pick the index matching the installed edition (Standard/Datacenter, Desktop Experience or Core)
DISM /Online /Cleanup-Image /RestoreHealth /Source:wim:$drv`:\sources\install.wim:<Index> /LimitAccess
Dismount-DiskImage -ImagePath $iso
```
For `.esd` media use `/Source:esd:<path>\install.esd:<Index>`.

**Healthy donor (same build, same patch level):** share its `C:\Windows\WinSxS` read-only and use `/Source:\\<donor>\c$\Windows\WinSxS /LimitAccess`.
</details>

<details><summary>Fix 3 — Stuck pending.xml / "not repairable"</summary>

```powershell
# Try revert of pending actions (from WinRE for the OS volume, or /Online if it boots)
DISM /Online /Cleanup-Image /RevertPendingActions
# From WinRE (OS volume often D: there):
# dism /Image:D:\ /Cleanup-Image /RevertPendingActions
```
**Risk:** reverts the in-flight update set. Reboot, re-run ScanHealth. If still "not repairable": capture evidence and plan an **in-place upgrade repair** (setup.exe from same-build media, "Keep files and apps") — preserves roles/data on Server 2016+ for supported upgrade paths; take a full backup first (`WindowsServerBackup-B.md`).
</details>

<details><summary>Fix 4 — CU keeps failing after store is clean</summary>

```powershell
# Install latest SSU/LCU manually (combined package on 2022+/Win11)
# Download the .msu from the Microsoft Update Catalog for the exact build, then:
wusa.exe <C:\Temp\windows10.0-kbXXXXXXX-x64.msu> /quiet /norestart
# or
DISM /Online /Add-Package /PackagePath:<C:\Temp\Windows10.0-KBXXXXXXX-x64.cab>
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5
```
If the catalog package also fails with `0x800f0831`, the missing baseline is a specific earlier LCU — CBS.log names its package identity; install that KB first.
</details>

<details><summary>Fix 5 — Not corruption: space, partitions, filter drivers</summary>

```powershell
Get-Volume | Select-Object DriveLetter, FileSystemLabel, SizeRemaining, Size
Get-Partition | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' } |
  Get-Volume | Select-Object SizeRemaining, Size          # EFI System Partition
fltmc                                                    # 3rd-party minifilters (AV, DLP, backup)
Dism /Online /Cleanup-Image /AnalyzeComponentStore       # reclaimable space
Dism /Online /Cleanup-Image /StartComponentCleanup       # safe; removes superseded versions after 30 days
```
Do **not** use `/ResetBase` unless you accept losing the ability to uninstall existing updates. Never delete WinSxS content manually or with "cleaner" tools — that is the #1 cause of "not repairable".
</details>

---
## Escalation Evidence
```
Hostname / OS / build (winver):   ____________________
Failing KB + error code:          ____________________
CheckHealth / ScanHealth result:  ____________________
RestoreHealth result + source:    ____________________
SFC result:                       ____________________
pending.xml present after reboot: Yes / No
Corrupt components (CBS.log):     ____________________
Disk health (Get-PhysicalDisk):   ____________________
Free space C: / ESP:              ____________________
WSUS/ConfigMgr managed:           Yes / No  RepairContentServerSource: ___
Attached: CBS.log, DISM.log (C:\Windows\Logs\DISM\dism.log), CBS.persist*.cab   [ ]
```

---
## 🎓 Learning Pointers
- `CheckHealth` only reads a flag; `ScanHealth` actually hashes the store. A clean CheckHealth proves nothing on its own. [Repair a Windows image](https://learn.microsoft.com/windows-hardware/manufacture/desktop/repair-a-windows-image)
- `0x800f081f` on a WSUS-managed server is almost always "no repair source", not "unrepairable" — WSUS doesn't serve repair payloads. [Configure a Windows repair source](https://learn.microsoft.com/windows-hardware/manufacture/desktop/configure-a-windows-repair-source)
- SFC repairs from the component store; if the store is bad, SFC can't win. Order is always DISM first, then SFC.
- `StartComponentCleanup` is safe and scheduled already (`\Microsoft\Windows\Servicing\StartComponentCleanup`); `/ResetBase` is permanent. [Clean up the WinSxS folder](https://learn.microsoft.com/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder)
- Update-pipeline issues before the store (WU client, WSUS, WUfB) live in `Windows Update/Update to Latest B.md` and `Intune/Troubleshooting/WUfB-B.md`. Store bloat also slows System State backups — see `WindowsServerBackup-A.md`.
