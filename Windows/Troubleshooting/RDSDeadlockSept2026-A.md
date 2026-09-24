# RDS Session Deadlock after September 2026 CU — Reference Runbook (Mode A: Deep Dive)
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
- **In scope:** Windows Server 2012/2012 R2 (ESU), 2016, 2019, 2022, 2025 after the **September 8, 2026** monthly cumulative update — KB5122871 (2025, build 26100.33438), KB5122882 (2022, 20348.5622), KB5122876 (2019), KB5123099 (2016), plus the matching 2012/2012 R2 ESU rollups.
- **Affected workloads:** RD Session Host farms (the bulk of reports), RD Connection Broker/Licensing servers, and **ordinary administrative RDP** on servers without the RDSH role (community-confirmed). Citrix VDA on these OS builds is affected too (Citrix CTX697101).
- **Not in scope:** Windows 10/11 client RDP, AVD multi-session images (no confirmed reports at time of writing — verify against release health for your build), generic RDP failures (→ `RDP-A.md`), the separate **USB Audio Class 1.0 "Code 10"** regression from the same release (not fixed by the OOB at time of writing).
- **Source quality:** Microsoft release health confirms the symptom, the KIR and the OOB fixes. The internal root-cause detail (feature flag `3802373433`, `WDLIB_Close`) comes from community kernel debugging (r/sysadmin, surfaced by LazyAdmin/BleepingComputer) — treat it as highly plausible, not vendor-confirmed.
- Timeline: Sept 8 CU → ~Sept 10–11 first reports → Sept 13 status "Mitigated" + KIR MSIs → **Sept 14 OOB** for 2019/2022/2025 (KB5129238/KB5129237/KB5129235) → 2012 R2 fix reissued as KB5129243 (community-reported).

---
## How It Works
<details><summary>Full architecture</summary>

### The RDP session lifecycle and the LSM bottleneck
Every interactive session on Windows — console or remote — is owned by the **Local Session Manager (LSM)** service. TermService (Remote Desktop Services, `svchost.exe -k termsvcs`) accepts the RDP transport, but every *state change* — create, connect, disconnect, logoff, reconnect — is serialized through LSM.

```
 Client ──TLS/CredSSP──► TermService (listener, WDLIB / rdpserverbase)
                               │
                               ▼
                         LSM  [single critical section: session state]
                         ├─► Winlogon (logon UI, SessionEnv notifications)
                         ├─► RD Connection Broker / SessionEnv
                         └─► Consumers: Task Manager, MMC snap-ins, Explorer, RD Licensing Diagnoser, WU settings page
```

### What the September CU changed
The September LCU introduced an RDP **audio redirection improvement** gated behind a Windows feature-management flag (community-identified as `3802373433`). With the flag on, session teardown runs `RDPSERVERBASE!WDLIB_Close`, which calls `RtlWaitOnAddress` **with no timeout**. If the value it waits on never changes (race during teardown), the thread blocks forever — while holding its place in LSM's serialized path.

### Why it presents as "fine after reboot, then dead"
Nothing goes wrong at connect time. The fault fires on a **disconnect/logoff**. So after a reboot, the host serves users normally until the first unlucky teardown — typically hours later as people log off. From then on:

| Component | Effect |
|---|---|
| New RDP connections | Hang at "Connecting…" / "Please wait for the Remote Desktop Configuration" → Event 20498 |
| Existing sessions | Can't log off; disconnects stall → Winlogon Event 6005 (SessionEnv, Disconnect) |
| TermService | Goes `StopPending` if anything tries to stop it |
| Management tools | Anything enumerating sessions hangs (Task Manager Users tab, MMC, Explorer, WU page) |
| Shutdown | Normal restart hangs waiting on session teardown → hard reset needed |

### Why rollback is dangerous this month
The same LCU fixed **CVE-2026-69525** (RDS remote code execution, CVSS 9.8) plus two exploited zero-days (CVE-2026-81963 Windows Update stack, CVE-2026-85880 ALPC; both in CISA KEV). Removing the LCU on an internet-exposed RD Gateway/RDSH trades a stability bug for a pre-auth RCE — the reason every playbook below prefers **forward-fix** (OOB) over **back-out** (DISM).

### The three Microsoft-sanctioned fix layers
1. **Out-of-band cumulative update** (Sept 14): permanently fixes the teardown path. Cumulative → installs on top of the August or September baseline. Reported Catalog-only distribution.
2. **Known Issue Rollback (KIR)**: an ADMX-delivered policy that flips the offending feature off. Needs the MSI → ADMX → GPO (or Intune ADMX ingestion) → **reboot** chain. Distribution notice was limited to tenants with applicable M365/Windows licensing, though the MSIs themselves are publicly downloadable. Only option on Server 2016 at time of writing.
3. **DISM removal** of the LCU: last resort.

A fourth, **unofficial** layer — manually writing the feature override under `HKLM\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\4\3802373433` — is what KIR does in a managed, documented way. It was reported unreliable on at least one 2022 21H2 host and should only be used where neither OOB nor KIR is possible.
</details>

---
## Dependency Stack
```
[7] User experience: RDP connect / logoff / reconnect
[6] RD Connection Broker, RD Gateway, Citrix VDA, RMM remote shells
[5] Winlogon + SessionEnv notifications
[4] Local Session Manager (LSM) — serialized session state          ← blocked
[3] TermService / rdpserverbase.dll (WDLIB_Close teardown path)      ← stuck thread
[2] Feature management state (flag 3802373433: CU default ON; KIR/override OFF)
[1] Servicing: Sept LCU (KB512287x/KB5123099) → OOB (KB512923x) supersedes
[0] OS build: 2016 / 2019 / 20348 / 26100
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| RDP stuck at "Connecting…", only hours after reboot | Teardown deadlock (this issue) | 20498 + 6005 events; Sept CU present |
| "Please wait for the Remote Desktop Configuration" forever | Same | TermService `StopPending` |
| Task Manager / MMC / Explorer hang on the server | LSM blocked | Same; `Get-Service TermService` hangs or StopPending |
| Server hangs on normal restart | Session teardown can't complete | Hard reset required; then OOB |
| Admin RDP to a DC (no RDSH) hangs | Same defect — not RDSH-specific | Build/UBR |
| Recurrence after KIR GPO applied | KIR not active (no reboot / wrong OS ADMX / Enabled instead of Disabled) or KIR insufficient on that build | `gpresult`; Policies\...\FeatureManagement\Overrides; move to OOB |
| Recurrence after registry override | Known community failure mode | Remove override; install OOB/KIR |
| Server 2016 still failing post-Sept 14 | No OOB for 2016 | KIR only |
| RDP fails immediately, even after fresh reboot | Different issue (NLA/cert/licensing) | `RDP-B.md` |
| USB headset "Code 10", no audio | Separate Sept regression | Device Manager; not fixed by OOB (as of mid-Sept) |

---
## Validation Steps
1. **OS & build** — `(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion') | % { "$($_.CurrentBuild).$($_.UBR)" }`
   Good: `20348.5631` / `26100.33451` (OOB). Bad: `20348.5622` / `26100.33438` with no mitigation.
2. **Hotfix inventory** — `Get-HotFix | ? HotFixID -match '51228|51230|51292'`
   Good: OOB KB present. Bad: only the Sept CU KB.
3. **TermService health** — `Get-Service TermService`
   Good: `Running`, returns instantly. Bad: `StopPending`, or the cmdlet itself is slow.
4. **Event signatures (7 days)** — 20498 in `Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin`; 6005 from `Microsoft-Windows-Winlogon` in System.
   Good: zero since fix/mitigation date. Bad: any, clustered around logoff times.
5. **Mitigation state** — KIR values under `HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides`; community override under `...\Control\FeatureManagement\Overrides\4\3802373433`; last boot time **after** the KIR GPO applied.
6. **Soak** — 24–48 h across a normal logoff cycle with no 20498/6005 recurrence.

---
## Troubleshooting Steps (by phase)
**Phase 1 — Stabilise.** If users are locked out: recover via non-RDP channel (kill TermService svchost; see Playbook 4) or hard reset. Communicate to users that a reconnect-after-logoff storm may re-trigger until fixed.

**Phase 2 — Classify the fleet.** Run `Get-RDSDeadlockSept2026Status.ps1` across all servers (RDSH, brokers, DCs, jump boxes — anything people RDP to). Bucket: Fixed / Exposed / Deadlocked / Mitigated-KIR / Mitigated-Registry / Not-applicable.

**Phase 3 — Forward-fix.** OOB to every 2019/2022/2025 host in Exposed/Deadlocked/Mitigated buckets. KIR to 2016. Prioritise internet-exposed RD Gateway/RDSH — they need the Sept security content *and* stability.

**Phase 4 — Clean up.** Remove KIR GPOs and registry overrides once the OOB is confirmed (KIR policies are designed to be short-lived). Re-enable any update pauses/declines.

**Phase 5 — Verify & close.** Soak window, then close with evidence (build, events, mitigation state).

---
## Remediation Playbooks
<details><summary>Playbook 1 — Fleet OOB deployment (WSUS import / RMM)</summary>

```powershell
# WSUS: import from Catalog via the WSUS console (Updates > Import Updates) or PowerShell on the WSUS server
# (Catalog import requires the WSUS console's IE-based import or manual .cab approach; many MSPs simply push the .msu via RMM)

# RMM / remoting push of the .msu (example for Server 2022)
$targets = Get-Content C:\Temp\rds-hosts.txt
foreach ($t in $targets) {
    Copy-Item C:\Temp\<windows-server-2022-kb5129237>.msu "\\$t\C$\Temp\" -Force
    Invoke-Command -ComputerName $t -ScriptBlock {
        Start-Process wusa.exe -ArgumentList 'C:\Temp\<windows-server-2022-kb5129237>.msu /quiet /norestart' -Wait
    }
}
# Reboot in drain order: set RDSH to "Do not allow new connections", wait for sessions to drain, then restart
Set-RDSessionHost -SessionHost <rdsh.fqdn> -NewConnectionAllowed No -ConnectionBroker <broker.fqdn>
```
Rollback: OOB is a normal LCU — removable with DISM like any other, but there is no reason to remove it unless it introduces a new regression.
</details>

<details><summary>Playbook 2 — KIR via GPO (Server 2016, or bridging until OOB)</summary>

1. Get the OS-matched KIR MSI from the release-health entry. OS in the MSI filename **must** match the target OS.
2. `msiexec /i "<KIR>.msi" /qb TARGETDIR=C:\Temp\KIR` (or plain install) on the GPMC box; copy ADMX/ADML to the Central Store.
3. GPO → Computer Configuration › Administrative Templates › *KB####### Issue XXX Rollback* › *<OS>* → **Disabled**.
4. Scope with a security group or WMI filter (e.g. `SELECT * FROM Win32_OperatingSystem WHERE BuildNumber = "14393"`).
5. `gpupdate /force` + **restart**. Verify KIR value under `HKLM\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides`.
Rollback: set the policy to Not Configured / unlink GPO, gpupdate, restart. Full mechanics: `KnownIssueRollback-A.md`.
</details>

<details><summary>Playbook 3 — Unofficial registry override (only where OOB and KIR are impossible)</summary>

See `RDSDeadlockSept2026-B.md` Fix 3. Always back up `...\FeatureManagement\Overrides` first; test on one host; restart TermService (drops sessions). Remove it after the OOB lands. Keys are TrustedInstaller-owned — admin shell works, some RMM SYSTEM contexts don't.
</details>

<details><summary>Playbook 4 — Live-host recovery without reboot</summary>

```powershell
$svc = Get-CimInstance Win32_Service -Filter "Name='TermService'"
Stop-Process -Id $svc.ProcessId -Force
Start-Service TermService
```
Drops all sessions. Buys time only.
</details>

<details><summary>Playbook 5 — DISM LCU removal (destructive)</summary>

```powershell
dism.exe /Online /Get-Packages /Format:Table | findstr /i "Package_for_RollupFix"
dism.exe /Online /Remove-Package /PackageName:<exact package name> /NoRestart
```
Re-exposes CVE-2026-69525 and both KEV zero-days. Block re-offer (WSUS decline / WUfB pause) and replace with the OOB at the earliest opportunity — the OOB brings the security content back.
</details>

---
## Evidence Pack
```powershell
# Collect-RDSDeadlockEvidence.ps1 — run elevated on the affected host (non-RDP channel if hung)
$out = "C:\Temp\RDSDeadlock_${env:COMPUTERNAME}_$(Get-Date -f yyyyMMdd_HHmm)"
New-Item $out -ItemType Directory -Force | Out-Null
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
"$($cv.ProductName) $($cv.CurrentBuild).$($cv.UBR)" | Out-File "$out\build.txt"
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 15 | Export-Csv "$out\hotfix.csv" -NoTypeInformation
Get-Service TermService, SessionEnv, UmRdpService -EA SilentlyContinue | Select-Object Name, Status, StartType | Export-Csv "$out\services.csv" -NoTypeInformation
Get-WindowsFeature RDS-* -EA SilentlyContinue | Where-Object Installed | Select-Object Name | Export-Csv "$out\rdsroles.csv" -NoTypeInformation
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin'; Id=20498; StartTime=(Get-Date).AddDays(-7)} -EA SilentlyContinue |
    Select-Object TimeCreated, Id, Message | Export-Csv "$out\evt20498.csv" -NoTypeInformation
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Winlogon'; Id=6005; StartTime=(Get-Date).AddDays(-7)} -EA SilentlyContinue |
    Select-Object TimeCreated, Id, Message | Export-Csv "$out\evt6005.csv" -NoTypeInformation
Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'; StartTime=(Get-Date).AddDays(-2)} -EA SilentlyContinue |
    Select-Object TimeCreated, Id, Message | Export-Csv "$out\lsm-operational.csv" -NoTypeInformation
reg export "HKLM\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides" "$out\fm-overrides-control.reg" /y 2>$null
reg export "HKLM\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides" "$out\fm-overrides-policy.reg" /y 2>$null
gpresult /scope computer /h "$out\gpresult.html" /f
(Get-CimInstance Win32_OperatingSystem).LastBootUpTime | Out-File "$out\lastboot.txt"
Compress-Archive -Path "$out\*" -DestinationPath "$out.zip" -Force
"Evidence: $out.zip"
```

---
## Command Cheat Sheet
| Purpose | Command |
|---|---|
| Build + UBR | `$c=gp 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; "$($c.CurrentBuild).$($c.UBR)"` |
| Sept/OOB KBs | `Get-HotFix \| ? HotFixID -match '51228\|51230\|51292'` |
| TermService state | `Get-Service TermService` |
| TermService PID | `(Get-CimInstance Win32_Service -Filter "Name='TermService'").ProcessId` |
| Kill hung TermService | `Stop-Process -Id <pid> -Force; Start-Service TermService` |
| Evt 20498 | `Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-TerminalServices-RemoteConnectionManager/Admin';Id=20498} -MaxEvents 10` |
| Evt 6005 | `Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-Winlogon';Id=6005} -MaxEvents 10` |
| Active sessions | `qwinsta` / `query user` |
| Drain an RDSH | `Set-RDSessionHost -SessionHost <fqdn> -NewConnectionAllowed No -ConnectionBroker <fqdn>` |
| Install OOB | `wusa.exe <file>.msu /quiet /norestart` |
| KIR policy values | `gci 'HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides'` |
| Community override | `gp 'HKLM:\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\4\3802373433'` |
| GPO applied? | `gpresult /scope computer /r` |
| LCU package name | `dism /Online /Get-Packages /Format:Table \| findstr RollupFix` |
| Last boot | `(Get-CimInstance Win32_OperatingSystem).LastBootUpTime` |

---
## 🎓 Learning Pointers
- **Forward-fix beats back-out** when a CU carries a critical RCE fix. Build your process so an OOB `.msu` can be pushed fleet-wide in under an hour — WSUS Catalog import or RMM file deployment.
- **Feature flags are the new servicing unit.** Monthly LCUs ship code dark and light it up via feature management; KIR is simply Microsoft flipping that flag back for you. Background: https://techcommunity.microsoft.com/t5/windows-it-pro-blog/known-issue-rollback-helping-you-keep-windows-devices-protected/ba-p/2176831
- **LSM is a serialization point** — one hung teardown freezes connect, logoff and every session-enumerating tool. When "everything RDS hangs at once", think LSM before thinking network.
- **Ring your server patching.** A pilot ring of one RDSH + one admin-RDP server with a 48-hour soak would have caught this before production. See Windows Update for Business / WSUS ring guidance: https://learn.microsoft.com/en-us/windows/deployment/update/waas-manage-updates-wsus
- Subscribe to **Windows release health** for your server SKUs (and the M365 admin center Windows release health blade) so KIR notices don't depend on community blogs: https://learn.microsoft.com/en-us/windows/release-health/
- Related: `RDP-A.md` (general RDP), `KnownIssueRollback-A.md` (KIR mechanics), `Windows Update/WSUS-Server-A.md`.
