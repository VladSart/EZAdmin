# RDS Session Deadlock after September 2026 CU — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

> **Scope:** Windows Server 2016/2019/2022/2025 (and 2012/2012 R2 on ESU) hosts that installed the **September 8, 2026 cumulative update** and now hang on RDP ("Connecting…" / "Please wait for the Remote Desktop Configuration"), cannot log users off, or only recover with a hard reset. Affects RD Session Hosts **and** plain administrative RDP (no RDSH role) — community-confirmed. Deep dive: `RDSDeadlockSept2026-A.md`. Generic KIR mechanics: `KnownIssueRollback-B.md`.

| Server | Faulting Sept CU | Affected build | Permanent fix (OOB, Sept 14 2026) | Build after fix |
|---|---|---|---|---|
| 2025 | KB5122871 | 26100.33438 | **KB5129235** | 26100.33451 |
| 2022 | KB5122882 | 20348.5622 | **KB5129237** | 20348.5631 |
| 2019 | KB5122876 | — | **KB5129238** | — |
| 2016 | KB5123099 | — | *No OOB* → use KIR | — |
| 2012 R2 (ESU) | — | — | KB5129243 (community-reported replacement for a pulled fix) | — |

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage
Run from a **non-RDP** channel if the host is already hung (Enter-PSSession / RMM shell / console / hypervisor console).

```powershell
# 1. Build + UBR — is the faulting CU (or the OOB fix) installed?
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
"$($cv.ProductName)  $($cv.CurrentBuild).$($cv.UBR)"

# 2. Relevant hotfixes present?
Get-HotFix | Where-Object HotFixID -in 'KB5122871','KB5122882','KB5122876','KB5123099','KB5129235','KB5129237','KB5129238' |
    Select-Object HotFixID, InstalledOn

# 3. TermService state
Get-Service TermService | Select-Object Name, Status

# 4. Deadlock signatures (last 24h)
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin'; Id=20498; StartTime=(Get-Date).AddDays(-1)} -EA SilentlyContinue | Measure-Object | Select-Object @{n='Evt20498';e={$_.Count}}
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Winlogon'; Id=6005; StartTime=(Get-Date).AddDays(-1)} -EA SilentlyContinue | Measure-Object | Select-Object @{n='Evt6005';e={$_.Count}}
```

| Result | Meaning | Do this |
|---|---|---|
| Build = OOB build (e.g. 26100.33451 / 20348.5631) or OOB KB present | Already fixed | Not this issue → `RDP-B.md` |
| Sept CU present, no OOB, TermService `Running`, no 20498/6005 | Exposed, not yet triggered | **Fix 1** (OOB) in next window |
| Sept CU present, TermService `StopPending`, 20498 and/or 6005 events | **Active deadlock** | **Fix 4** (recover) → then **Fix 1** |
| Server 2016 with KB5123099 | No OOB exists | **Fix 2** (KIR) |
| Host unreachable by any channel | Hard hang | Hard reset from hypervisor/iLO/iDRAC → Fix 1 or Fix 5 |
| No Sept CU installed | Different problem | `RDP-B.md` |

---
## Dependency Cascade
<details><summary>What must be true for an RDP session to connect and log off cleanly</summary>

```
Hardware / hypervisor
└── Windows Server kernel + Sept 2026 LCU (KB512287x / KB5123099)
    └── Feature flag 3802373433 (new RDP audio-redirection teardown path)  ← ENABLED by Sept CU
        └── RDPSERVERBASE!WDLIB_Close  → RtlWaitOnAddress(no timeout)      ← can wait forever at session teardown
            └── Local Session Manager (LSM) — single critical section for all session state changes
                ├── TermService (svchost -k termsvcs)     → new connections queue behind the stuck thread
                ├── Winlogon / SessionEnv notifications   → Evt 6005 "taking long time… (Disconnect)"
                ├── RD Connection Broker requests         → Evt 20498 "taken too long to complete the client connection"
                └── Anything that enumerates sessions     → Task Manager, MMC, RD Licensing Diagnoser, Explorer, WU page hang
```
Trigger is **session teardown (logoff/disconnect)**, which is why hosts run fine for hours after a reboot and then fail as users log off.
</details>

---
## Diagnosis & Validation Flow
1. **Confirm the patch level**
   `Get-HotFix -Id KB5122882` (use your OS's KB) → returns a row = faulting CU present. Empty = not this issue (unless OOB already superseded it — check build in step 2).
2. **Confirm the build/UBR**
   Triage command 1 → `20348.5622` / `26100.33438` = affected. `20348.5631` / `26100.33451` = fixed.
3. **Confirm deadlock signature, not a generic RDP fault**
   `Get-Service TermService` → `StopPending` = LSM deadlock active. `Running` + no events = exposed but not triggered.
4. **Check for Event 20498** (RemoteConnectionManager/Admin) and **Winlogon 6005** (System). Both present in the same window as user logoffs = this defect.
5. **Check for mitigations already applied**
   ```powershell
   Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\4\3802373433' -EA SilentlyContinue   # community registry override
   Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides' -EA SilentlyContinue        # KIR GPO lands here
   gpresult /scope computer /r | Select-String -Pattern 'KIR|Rollback'
   ```
   Any hit = a mitigation is staged. KIR needs a **restart** to take effect; registry override needs a TermService restart.
6. **Validate after fixing:** build incremented, TermService `Running`, zero 20498/6005 through at least one full logoff cycle (24–48 h).

---
## Common Fix Paths

<details><summary>Fix 1 — Install the out-of-band update (permanent, preferred for 2019/2022/2025)</summary>

OOB updates are **cumulative** — install them directly, with or without the Sept CU already present. Reported as **Microsoft Update Catalog only** (not offered by WU/WSUS automatically) — import the `.msu` into WSUS or deploy via RMM.

```powershell
# Download the .msu for your OS from https://www.catalog.update.microsoft.com/ (search the KB)
# Server 2025: KB5129235 | Server 2022: KB5129237 | Server 2019: KB5129238
wusa.exe "C:\Temp\<windows-server-kb-file>.msu" /quiet /norestart
# Reboot in a maintenance window — disconnects all sessions
Restart-Computer -Force

# Validate
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; "$($cv.CurrentBuild).$($cv.UBR)"
```
After success: remove any KIR GPO and registry override (Fix 6). Security fixes (incl. CVE-2026-69525, RDS RCE, CVSS 9.8) are retained.
</details>

<details><summary>Fix 2 — Known Issue Rollback via Group Policy (Server 2016, or if OOB can't be installed yet)</summary>

1. Download the KIR MSI for the OS from the Windows release health known-issue entry (Server 2016 = KB5123099 KIR).
2. Install the MSI on the GPMC workstation; copy the new `.admx`/`.adml` from `C:\Windows\PolicyDefinitions` to `\\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions\` if you use a Central Store.
3. New GPO linked to the RDS/server OU → **Computer Configuration › Administrative Templates › KB####### Issue XXX Rollback › <OS>** → set to **Disabled** (Disabled = rollback active; this wording trips people up).
4. Apply and **restart** (Microsoft requires a restart for KIR to take effect):
```powershell
Invoke-GPUpdate -Computer <server> -Force
Restart-Computer -ComputerName <server> -Force
```
Monitor 20498/6005 for 24–48 h. Community reports exist of recurrence on some 2019/2022 hosts after KIR → move to Fix 1 wherever an OOB exists.
Intune-managed servers: see `KnownIssueRollback-B.md` → Fix 3 (ADMX ingestion OMA-URI).
</details>

<details><summary>Fix 3 — Registry feature-flag override (UNOFFICIAL — last-resort fallback only)</summary>

Community-derived (kernel debugging on r/sysadmin), **not Microsoft-documented**; reported to **fail** on at least one Server 2022 21H2 host. Disables the Sept RDP audio-redirection change. Keys are TrustedInstaller-protected — run elevated as an admin (SYSTEM via RMM may get Access Denied).

```powershell
New-Item C:\Temp -ItemType Directory -Force | Out-Null
reg export "HKLM\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides" C:\Temp\FeatureOverrides-backup.reg /y
$k = 'HKLM:\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\4\3802373433'
New-Item -Path $k -Force | Out-Null
Set-ItemProperty -Path $k -Name EnabledState        -Value 1 -Type DWord   # 1 = disabled
Set-ItemProperty -Path $k -Name EnabledStateOptions -Value 0 -Type DWord
Restart-Service TermService -Force    # drops all RDP sessions
```
**Rollback:** `Remove-Item $k -Force` then restart TermService (or `reg import C:\Temp\FeatureOverrides-backup.reg`).
</details>

<details><summary>Fix 4 — Recover a host that is deadlocked right now (no reboot)</summary>

Use a non-RDP channel. Kills the TermService svchost; all RDP sessions drop. This is a **stopgap** — the deadlock returns at the next bad teardown until Fix 1/2 is applied.

```powershell
$svcPid = (Get-CimInstance Win32_Service -Filter "Name='TermService'").ProcessId
tasklist /svc /fi "PID eq $svcPid"          # confirm only TermService lives in this svchost
Stop-Process -Id $svcPid -Force
Start-Service TermService
Get-Service TermService
```
If `Stop-Process` hangs or fails → hard reset from hypervisor/out-of-band management.
</details>

<details><summary>Fix 5 — Remove the September CU with DISM (destructive — last resort)</summary>

⚠️ Removes **all** September security fixes, including the CVSS 9.8 RDS RCE and two actively exploited zero-days. Only for internal-only hosts that are unrecoverable by Fixes 1–4. `wusa /uninstall` fails because the package bundles the SSU.

```powershell
dism.exe /Online /Get-Packages /Format:Table | findstr /i "Package_for_RollupFix"
dism.exe /Online /Remove-Package /PackageName:<Package_for_RollupFix~31bf3856ad364e35~amd64~~BUILD> /NoRestart
Restart-Computer -Force
```
Then decline the KB in WSUS / pause updates for that ring, and schedule Fix 1 as soon as possible (OOB is cumulative and restores the security fixes).
</details>

<details><summary>Fix 6 — Clean up after the OOB is installed</summary>

```powershell
Remove-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\4\3802373433' -Force -EA SilentlyContinue
# Unlink/delete the KIR GPO in GPMC, then:
gpupdate /target:computer /force
```
</details>

---
## Escalation Evidence
```
Ticket: RDS deadlock after September 2026 CU
Host(s):                      <server names>
OS / Build.UBR:               <e.g. Windows Server 2022 20348.5622>
Sept CU installed (KB/date):  <KB5122882 / 2026-09-xx>
OOB installed?:               <Y/N — KB, build after>
KIR GPO applied + rebooted?:  <Y/N — GPO name, reboot time>
Registry override present?:   <Y/N>
RDSH role / Broker / Gateway: <roles present>
TermService status at fault:  <Running / StopPending>
Evt 20498 count + first time: <n / timestamp>
Winlogon 6005 count:          <n>
Audio redirection in use?:    <Y/N>
Third-party (Citrix VDA etc): <product/version>
Recovery method used:         <svchost kill / hard reset / DISM rollback>
Evidence pack path:           <output of Get-RDSDeadlockSept2026Status.ps1 CSV>
```

---
## 🎓 Learning Pointers
- The trigger is **teardown, not connect** — "fine after reboot, dead a few hours later" is the tell. Correlate 20498/6005 timestamps with logoff times rather than logon storms.
- A single stuck thread in **LSM's critical section** freezes everything that touches session state — that's why Task Manager and MMC hang too. See Microsoft's RDS architecture: https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/welcome-to-rds
- OOB updates are **cumulative** and often **Catalog-only** — build a WSUS import / RMM `.msu` deployment path before you need it: https://www.catalog.update.microsoft.com/
- KIR "Disabled = rollback on" and "restart required" are the two most common KIR deployment mistakes — `KnownIssueRollback-A.md` explains why.
- Watch Windows release health for status changes (Investigating → Mitigated → Resolved): https://learn.microsoft.com/en-us/windows/release-health/status-windows-server-2022 and `resolved-issues-windows-server-2025`.
- Citrix-published cross-check for the same September issue set: CTX697101 (support.citrix.com).
