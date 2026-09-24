# Known Issue Rollback (KIR) — Reference Runbook (Mode A: Deep Dive)
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
- **Covers:** what KIR is, how Microsoft delivers it to unmanaged vs. managed devices, the ADMX/GPO and Intune (ADMX ingestion) deployment paths, how to verify activation on-device, and KIR lifecycle/retirement.
- **Platforms:** Windows 10 1809+ / Windows 11 / Windows Server 2019+ as the documented baseline. Microsoft has additionally shipped KIR MSIs for older server SKUs (2012, 2012 R2, 2016) for specific high-impact regressions — e.g. the September 2026 RDS deadlock (`RDSDeadlockSept2026-A.md`).
- **Not covered:** uninstalling updates (DISM/wusa), Windows Update for Business pause/rollback of feature updates, Autopatch "expedite"/"pause" (see `Intune/…` update runbooks and `Windows Update/…`).
- **Assumption:** you can read Windows release health (https://aka.ms/windowsreleasehealth) or the M365 admin center *Windows release health* blade — KIRs are announced there first.

---
## How It Works
<details><summary>Full architecture</summary>

### Servicing model: ship dark, light up by flag
Modern Windows cumulative updates carry new code paths that are **gated by feature-management flags** (numeric feature IDs). The same mechanism turns on dormant features for enablement packages (see `Windows1126H2-A.md`). A regression introduced by a non-security change in an LCU is almost always behind such a flag — so Microsoft can neutralise it by flipping the flag off, without removing the binaries or the security fixes shipped alongside.

### What a KIR is
A **Known Issue Rollback** is Microsoft flipping that flag back to its pre-update behaviour.

```
             ┌──────────────────── LCU (security + non-security changes) ────────────────────┐
             │  CVE fixes (always kept)     change A     change B (REGRESSION, flag 12345)    │
             └────────────────────────────────────────────────────────────────────────────────┘
KIR active:                                               flag 12345 → OFF (old code path)
```
Microsoft's documented constraint: **KIR applies to non-security changes only**, because reverting a non-security change can't re-open a vulnerability.

### Two delivery channels
| Device type | How the KIR arrives | Admin action |
|---|---|---|
| Unmanaged / consumer / non-enterprise | Microsoft pushes the rollback configuration via Windows Update cloud config | None (restart may be needed) |
| Enterprise-managed (GPO / MDM) | Microsoft publishes a **KIR policy definition .msi** (ADMX/ADML) | You deploy it via GPO or Intune ADMX ingestion |

This split is why a managed fleet can stay broken while home PCs "self-heal" — the automatic path is deliberately suppressed for enterprise-managed devices so IT keeps control.

### The KIR ADMX and why "Disabled" is correct
Each KIR MSI installs an `.admx` containing a single policy per OS, named like `KB5011563_220428_2000_1_KnownIssueRollback`, under a parent category like `KnownIssueRollback_Win_11`. The policy writes a DWORD named after the **feature ID** under:

```
HKLM\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides
    <featureId> (REG_DWORD) = 0     ← feature disabled → rollback active
```
The policy is modelled as "this new behaviour: Enabled/Disabled". **Disabled** turns off the new (buggy) behaviour — i.e. activates the rollback. Setting **Enabled** explicitly forces the buggy behaviour on.

### Why a restart is mandatory
Feature-management state is evaluated early at boot and cached by components. Microsoft's guidance is explicit: the fix that introduced the issue is disabled **after the device applies the policy and then restarts**. gpupdate alone changes the registry but not the running code.

### Intune path: ADMX ingestion
MDM can't consume GPOs, so Intune uses the Policy CSP's ADMX-backed policy support:
1. `./Device/Vendor/MSFT/Policy/ConfigOperations/ADMXInstall/KIR/Policy/<PolicyName>` — String = full ADMX text. Registers the ADMX on the device (visible under `HKLM\SOFTWARE\Microsoft\PolicyManager\AdmxInstalled`).
2. `./Device/Vendor/MSFT/Policy/Config/KIR~Policy~KnownIssueRollback~<ParentCategory>/<PolicyName>` — String = `<disabled/>`. Sets the policy.
Requires the **July 26, 2022** CU (or later) on the device. Scope by **Applicability rule → OS Version** (`10.0.<build>` to `10.0.<build+1>`) since each KIR ADMX is OS-specific.

### Lifecycle
Issue reported → release health *Investigating* → *Mitigated* (KIR published) → fix ships in a later LCU or OOB → *Resolved*. KIR policy definitions have a **limited lifespan (months at most)**; once the fix is installed, remove the GPO/profile. Leftover overrides can keep a later, corrected code path disabled.
</details>

---
## Dependency Stack
```
[6] Symptom resolved (verified with the issue's own test)
[5] Device RESTART after policy applied
[4] Registry: HKLM\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides\<featureId> = 0
[3] Policy delivery: GPO (SYSVOL read, scoping, WMI filter)  |  Intune Custom profile (ADMX ingest + <disabled/>, applicability rule)
[2] Policy definition: OS-matched KIR .admx/.adml (Central Store or ingested)
[1] Regressing KB installed on the device (otherwise KIR is moot)
[0] Microsoft has published a KIR for this issue + OS version (release health)
```

---
## Symptom → Cause Map
| Symptom | Most Likely Cause | Check |
|---|---|---|
| KIR setting not visible in GPMC | ADMX not in Central Store / local PolicyDefinitions | `gci \\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions -Filter *Rollback*` |
| GPO applied, issue persists | No restart | LastBootUpTime vs gpresult time |
| GPO applied, restarted, issue persists | Policy set Enabled; OS mismatch; wrong issue number | GPO report; MSI filename vs `winver` |
| GPO in "Denied GPOs" | Security filtering / WMI filter false | `gpresult /h` |
| Intune profile Error | Malformed ADMX string (truncated paste), wrong OMA-URI tokens | Profile per-setting status; `AdmxInstalled` key |
| Intune profile Not applicable | Applicability rule OS range wrong | Device OS version vs rule |
| Intune profile Conflict | Two profiles set same OMA-URI | Remove duplicate |
| Home PCs fixed, corp PCs not | Expected — managed devices need admin-deployed KIR | Deploy via GPO/Intune |
| Newer CU installed, related feature "missing" | Stale KIR override still active | Overrides values; remove KIR |
| KIR applied, issue recurs (e.g. Sept 2026 RDS on some hosts) | KIR insufficient for that build | Install OOB/fixing CU |

---
## Validation Steps
1. **Regressing KB present** — `Get-HotFix -Id <KB>` → row returned. Bad: empty (look elsewhere).
2. **ADMX available** — GPO: `Get-ChildItem C:\Windows\PolicyDefinitions -Filter *Rollback*` (or Central Store). Intune: `Get-ChildItem HKLM:\SOFTWARE\Microsoft\PolicyManager\AdmxInstalled -Recurse | ? Name -match 'KIR'`.
3. **Policy applied** — `gpresult /scope computer /r` lists the KIR GPO under Applied. Intune: profile *Succeeded* for the device.
4. **Override value written** — `Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides'` → numeric value(s) = `0`.
5. **Restarted after apply** — `(Get-CimInstance Win32_OperatingSystem).LastBootUpTime` later than policy application.
6. **Symptom gone** — re-run the known-issue repro or event check.

---
## Troubleshooting Steps (by phase)
**Phase 1 — Confirm KIR is the right tool.** Is the issue listed as *Mitigated* with a KIR for *this exact OS*? If there's already an OOB/fixing CU, prefer installing it (KIR is a bridge).

**Phase 2 — Definition layer.** Download the OS-matched MSI; confirm ADMX in PolicyDefinitions/Central Store; confirm policy name and parent category if using Intune.

**Phase 3 — Delivery layer.** GPO: link, security filter, WMI filter, replication (`repadmin /syncall` if new GPO not seen by the DC the device uses). Intune: profile status per device, applicability, conflicts.

**Phase 4 — Activation layer.** Registry value present = delivery worked. Restart. Re-test.

**Phase 5 — Retirement.** When the fixing update is deployed fleet-wide, unlink/delete the GPO or delete the Intune profile; restart on next cycle.

---
## Remediation Playbooks
<details><summary>Playbook 1 — Standard GPO KIR rollout with WMI scoping</summary>

```powershell
# 1. Install definitions on the admin box and publish to Central Store
msiexec /i "C:\Temp\<KIR>.msi" /qb
$cs = "\\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions"
Get-ChildItem C:\Windows\PolicyDefinitions -Filter *Rollback*.admx | Copy-Item -Destination $cs -Force
Get-ChildItem C:\Windows\PolicyDefinitions\en-US -Filter *Rollback*.adml | Copy-Item -Destination "$cs\en-US" -Force

# 2. GPO
$gpo = New-GPO -Name 'KIR - <KB> Issue <n> - <OS>'
New-GPLink -Guid $gpo.Id -Target 'OU=<Target>,DC=<domain>,DC=<tld>' | Out-Null
# 3. Edit in GPMC: Admin Templates > KB<KB> Issue <n> Rollback > <OS> = Disabled
# 4. Optional WMI filter (GPMC > WMI Filters), e.g. Windows Server 2022 only:
#    SELECT * FROM Win32_OperatingSystem WHERE BuildNumber = "20348"
```
Rollback: set policy Not Configured or unlink; gpupdate; restart.
</details>

<details><summary>Playbook 2 — Intune Custom profile (cloud-native / Autopilot devices)</summary>

```powershell
# Extract ADMX without installing to PolicyDefinitions
msiexec /i "C:\Temp\<KIR>.msi" /qb TARGETDIR=C:\Temp\KIR
$admx = Get-ChildItem C:\Temp\KIR -Recurse -Filter *.admx | Select-Object -First 1
[xml]$x = Get-Content $admx.FullName
$pol = $x.policyDefinitions.policies.policy
"PolicyName     : $($pol.name)"
"ParentCategory : $($pol.parentCategory.ref)"
Get-Content $admx.FullName -Raw | Set-Clipboard   # paste into the ADMX-ingest OMA-URI value
```
OMA-URIs: see `KnownIssueRollback-B.md` Fix 3. Add OS Version applicability rule. After *Succeeded*, restart via Remediation or user notification.
Rollback: delete the profile; restart.
</details>

<details><summary>Playbook 3 — Emergency single-host activation (no GPO/Intune reach)</summary>

Install the MSI locally → `gpedit.msc` → set KIR policy **Disabled** → restart. This persists in local policy; document it so it gets removed later (`gpedit` → Not Configured).
</details>

<details><summary>Playbook 4 — Retire KIRs after the fix ships</summary>

```powershell
Get-GPO -All | Where-Object DisplayName -like 'KIR - *' | Select-Object DisplayName, CreationTime, ModificationTime
# For each superseded KIR:
Remove-GPO -Name '<KIR GPO name>'   # destructive - export first: Backup-GPO -Name '<KIR GPO name>' -Path C:\Temp\GPOBackup
```
Intune: delete Custom profiles named `KIR*`. Validate the Overrides key no longer holds the feature ID after restart.
</details>

---
## Evidence Pack
```powershell
$out = "C:\Temp\KIR_${env:COMPUTERNAME}_$(Get-Date -f yyyyMMdd_HHmm)"
New-Item $out -ItemType Directory -Force | Out-Null
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
"$($cv.ProductName) $($cv.DisplayVersion) $($cv.CurrentBuild).$($cv.UBR)" | Out-File "$out\os.txt"
Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 15 | Export-Csv "$out\hotfix.csv" -NoTypeInformation
reg export "HKLM\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides" "$out\kir-policy-overrides.reg" /y 2>$null
reg export "HKLM\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides" "$out\fm-control-overrides.reg" /y 2>$null
reg export "HKLM\SOFTWARE\Microsoft\PolicyManager\AdmxInstalled" "$out\mdm-admxinstalled.reg" /y 2>$null
gpresult /scope computer /h "$out\gpresult.html" /f
Get-ChildItem C:\Windows\PolicyDefinitions -Filter *Rollback* -EA SilentlyContinue | Select-Object Name, LastWriteTime | Export-Csv "$out\local-admx.csv" -NoTypeInformation
(Get-CimInstance Win32_OperatingSystem).LastBootUpTime | Out-File "$out\lastboot.txt"
dsregcmd /status | Out-File "$out\dsregcmd.txt"
Compress-Archive "$out\*" "$out.zip" -Force; "Evidence: $out.zip"
```

---
## Command Cheat Sheet
| Purpose | Command |
|---|---|
| OS build | `winver` / `$c=gp 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; "$($c.CurrentBuild).$($c.UBR)"` |
| KB present | `Get-HotFix -Id <KB>` |
| KIR overrides | `gp 'HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides'` |
| Local ADMX | `gci C:\Windows\PolicyDefinitions -Filter *Rollback*` |
| Central Store ADMX | `gci \\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions -Filter *Rollback*` |
| Extract MSI | `msiexec /i "<KIR>.msi" /qb TARGETDIR=C:\Temp\KIR` |
| Applied GPOs | `gpresult /scope computer /r` |
| Remote refresh | `Invoke-GPUpdate -Computer <pc> -Force -RandomDelayInMinutes 0` |
| Restart | `Restart-Computer -ComputerName <pc> -Force` |
| Last boot | `(Get-CimInstance Win32_OperatingSystem).LastBootUpTime` |
| MDM ingested ADMX | `gci HKLM:\SOFTWARE\Microsoft\PolicyManager\AdmxInstalled -Recurse` |
| List KIR GPOs | `Get-GPO -All \| ? DisplayName -like 'KIR*'` |
| Fleet status | `.\Get-KnownIssueRollbackStatus.ps1 -ComputerName (gc .\pcs.txt) -KB <KB>` |

---
## 🎓 Learning Pointers
- Microsoft's canonical procedure (GPO + Intune ADMX ingestion): https://learn.microsoft.com/en-us/troubleshoot/windows-client/group-policy/use-group-policy-to-deploy-known-issue-rollback
- Server-focused KIR overview: https://learn.microsoft.com/en-us/troubleshoot/windows-server/installing-updates-features-roles/known-issue-rollback
- Original design write-up (why KIR exists, non-security-only rule): "Known Issue Rollback – Helping you keep Windows devices protected and productive", Windows IT Pro Blog.
- ADMX-backed MDM policies explain the OMA-URI tokens used for ingestion: https://learn.microsoft.com/en-us/windows/client-management/understanding-admx-backed-policies
- Real-world test case: the September 2026 RDS deadlock shows KIR's limits — Server 2016 got KIR only, and some 2019/2022 hosts recurred under KIR until the OOB. See `RDSDeadlockSept2026-A.md`.
- Build the muscle before you need it: pre-create a "KIR" GPO template and Intune profile template, and subscribe to release-health notifications in the M365 admin center.
