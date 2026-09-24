# Known Issue Rollback (KIR) Deployment — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

> **Use when:** Microsoft release health says a Windows update regression is **"Mitigated"** with a **Known Issue Rollback**, and you need that rollback active on managed (GPO or Intune) devices *without* uninstalling the update. Applies to Windows 10 1809+/Windows 11 and Windows Server 2019+ (Microsoft has also shipped KIR MSIs for 2012/2012 R2/2016 on specific issues, e.g. Sept 2026 RDS). Deep dive: `KnownIssueRollback-A.md`. Current worked example: `RDSDeadlockSept2026-B.md`.

**The two rules that cause 80% of KIR tickets:**
1. Set the KIR policy to **Disabled** — "Disabled" = *the buggy change is disabled* = rollback **on**.
2. **Restart** the device after the policy lands. No restart = no rollback.

---
## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---
## Triage
```powershell
# 1. OS build — must match the OS named in the KIR MSI filename
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'; "$($cv.ProductName) $($cv.DisplayVersion) $($cv.CurrentBuild).$($cv.UBR)"

# 2. Is the KB that caused the regression installed?
Get-HotFix -Id <KB#######> -ErrorAction SilentlyContinue

# 3. Has a KIR policy landed? (KIR ADMX writes numeric feature IDs here, value 0 = feature off)
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides' -ErrorAction SilentlyContinue

# 4. Rebooted since the policy applied?
(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
gpresult /scope computer /r | Select-String 'Rollback|KIR|Last time Group Policy was applied'

# 5. Intune-managed? Check MDM enrollment + ADMX ingestion
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\PolicyManager\AdmxInstalled' -ErrorAction SilentlyContinue | Select-Object PSChildName
```

| Result | Meaning | Do this |
|---|---|---|
| KB not installed | KIR irrelevant — device isn't carrying the regression | Different root cause |
| KB installed, no Overrides values | KIR not delivered | Fix 1 (GPO) / Fix 3 (Intune) / check scoping |
| Overrides values present, LastBoot **before** gpresult apply time | Staged, not active | **Restart** |
| Overrides present, rebooted, issue persists | Wrong KIR (OS mismatch/wrong issue), policy set Enabled, or KIR insufficient | Fix 4 |
| Device unmanaged/consumer | Microsoft applies KIR automatically via Windows Update | Ensure device can reach WU; reboot |
| Issue superseded by a newer CU/OOB | KIR no longer needed | Install fix → Fix 5 (cleanup) |

---
## Dependency Cascade
<details><summary>What must be true</summary>

```
Microsoft publishes KIR on Windows release health (issue status: Mitigated)
└── Correct KIR .msi downloaded (OS/version in filename == target OS)
    └── ADMX/ADML installed
        ├── GPO path: C:\Windows\PolicyDefinitions → copied to SYSVOL Central Store (if used)
        │   └── GPO: Computer Config › Admin Templates › KB####### Issue XXX Rollback › <OS> = DISABLED
        │       └── GPO linked + scoped (OU / security filter / WMI filter) + device can read SYSVOL
        └── Intune path: ADMX ingested via OMA-URI ./Device/Vendor/MSFT/Policy/ConfigOperations/ADMXInstall/KIR/Policy/<PolicyName>
            └── ./Device/Vendor/MSFT/Policy/Config/KIR~Policy~KnownIssueRollback~<ParentCategory>/<PolicyName> = <disabled/>
                └── Applicability rule OS Version min/max matches device build; device CU ≥ July 26 2022
    └── HKLM\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides\<featureId> = 0
        └── DEVICE RESTART  → feature-management state re-read at boot → buggy change off
```
</details>

---
## Diagnosis & Validation Flow
1. **Identify the correct KIR.** Open the release-health known issue for the device's exact OS version; note KB, issue number, MSI link. Wrong OS MSI = policy not applicable.
2. **Confirm the ADMX is available where you're editing.** `Get-ChildItem \\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions\*KnownIssue*` (or `C:\Windows\PolicyDefinitions` without Central Store). Missing = GPMC won't show the setting.
3. **Confirm the GPO applies.** `gpresult /scope computer /h C:\Temp\gp.html` → GPO listed under *Applied GPOs*. Listed under *Denied* = scoping/WMI filter issue.
4. **Confirm the registry value.** Triage step 3 → at least one numeric value name with data `0`.
5. **Confirm restart.** LastBootUpTime later than the policy application time.
6. **Confirm the symptom is gone** using the issue's own test (e.g. RDS 20498/6005 events stop).

---
## Common Fix Paths

<details><summary>Fix 1 — Deploy KIR by GPO (AD / hybrid-joined)</summary>

```powershell
# On the GPMC workstation (elevated)
msiexec /i "C:\Temp\<OS> KB####### <date> Known Issue Rollback.msi" /qb
# Copy definitions to the Central Store
Copy-Item C:\Windows\PolicyDefinitions\*KnownIssueRollback*.admx \\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions\ -Force
Copy-Item C:\Windows\PolicyDefinitions\en-US\*KnownIssueRollback*.adml \\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions\en-US\ -Force

# Create + link GPO
New-GPO -Name 'KIR - KB####### Issue XXX' | New-GPLink -Target 'OU=<Servers>,DC=<domain>,DC=<tld>'
```
Then GPMC → edit GPO → Computer Configuration › Administrative Templates › **KB####### Issue XXX Rollback** › *<OS>* → **Disabled**.
```powershell
Invoke-GPUpdate -Computer <device> -Force -RandomDelayInMinutes 0
Restart-Computer -ComputerName <device> -Force
```
ADMX filenames vary per release — list with `Get-ChildItem C:\Windows\PolicyDefinitions -Filter *Rollback*` after the MSI install.
</details>

<details><summary>Fix 2 — Single device / workgroup (local policy)</summary>

Install the MSI on the device → `gpedit.msc` → Local Computer Policy › Computer Configuration › Administrative Templates › **KB####### Issue XXX Rollback** › *<OS>* → **Disabled** → restart.
</details>

<details><summary>Fix 3 — Deploy KIR via Intune (ADMX ingestion, Custom profile)</summary>

1. Extract ADMX: `msiexec /i "<KIR>.msi" /qb TARGETDIR=C:\Temp\KIR`
2. Open the `.admx`; record `policy name="..."` (e.g. `KB5011563_220428_2000_1_KnownIssueRollback`) and `parentCategory ref="..."` (e.g. `KnownIssueRollback_Win_11`).
3. Intune › Devices › Configuration › Create › Windows 10 and later › Templates › **Custom**. Add two OMA-URI rows:

| Name | OMA-URI | Type | Value |
|---|---|---|---|
| ADMX ingest | `./Device/Vendor/MSFT/Policy/ConfigOperations/ADMXInstall/KIR/Policy/<PolicyName>` | String | *entire .admx file contents* |
| KIR activate | `./Device/Vendor/MSFT/Policy/Config/KIR~Policy~KnownIssueRollback~<ParentCategory>/<PolicyName>` | String | `<disabled/>` |

4. Assign; add an **Applicability rule** → OS Version → min `10.0.<build>` max `10.0.<build+1>` so it only lands on the matching OS.
5. Restart devices after the profile reports **Succeeded** (use a Remediation or proactive restart notification).

Device-side check:
```powershell
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\PolicyManager\AdmxInstalled' -Recurse -EA SilentlyContinue | Where-Object Name -match 'KIR'
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Policies\Microsoft\FeatureManagement\Overrides' -EA SilentlyContinue
```
Requires the July 26 2022 CU or later on the device.
</details>

<details><summary>Fix 4 — KIR applied but issue persists</summary>

- Policy set to **Enabled** by mistake → change to **Disabled**, gpupdate, restart.
- **OS mismatch** — a Win11 23H2 KIR won't apply to 24H2; server KIRs are per-SKU. Re-download the right MSI.
- **No restart** since policy landed → restart.
- **Conflict in Intune** (two profiles, same OMA-URI) → keep one.
- **KIR superseded / insufficient** (e.g. Sept 2026 RDS: some hosts recurred after KIR) → install the OOB/next CU fix.
- Still broken → escalate with evidence below.
</details>

<details><summary>Fix 5 — Retire the KIR once Microsoft ships the fix</summary>

KIRs are designed to be temporary (months at most). After the fixing CU/OOB is installed:
```powershell
Remove-GPLink -Name 'KIR - KB####### Issue XXX' -Target 'OU=<Servers>,DC=<domain>,DC=<tld>'
# optional: Remove-GPO -Name 'KIR - KB####### Issue XXX'
Invoke-GPUpdate -Computer <device> -Force; Restart-Computer -ComputerName <device> -Force
```
Intune: delete the Custom profile. Leftover KIR policies can keep newer, fixed code paths disabled.
</details>

---
## Escalation Evidence
```
Ticket: KIR not effective / not applying
Release-health issue (URL/title):   <...>
KB causing regression:              <KB#######>
KIR MSI filename used:              <...>
Target OS / build.UBR:              <...>
Delivery method:                    <GPO name + OU | Intune profile name + ID>
Policy state set:                   <Disabled / Enabled / Not configured>
gpresult shows GPO applied?:        <Y/N — attach gpresult.html>
Overrides registry values:          <paste Get-ItemProperty output>
Intune profile status:              <Succeeded / Error code / Conflict / Pending>
Last reboot vs policy time:         <timestamps>
Symptom still reproduces?:          <Y/N — how tested>
Report CSV:                         <Get-KnownIssueRollbackStatus.ps1 output>
```

---
## 🎓 Learning Pointers
- KIR only reverts **non-security** changes inside an update — it's why Microsoft can offer it without re-opening a CVE. Official procedure: https://learn.microsoft.com/en-us/troubleshoot/windows-client/group-policy/use-group-policy-to-deploy-known-issue-rollback
- Consumer/unmanaged devices get KIR **automatically** from Windows Update; enterprise-managed devices don't — that's why your managed fleet is still broken while home PCs "fixed themselves".
- The "Disabled" semantics make sense once you see it's a **feature-management override**: you're disabling the new feature. `KnownIssueRollback-A.md` walks the registry path.
- Server-side KIR background and scope: https://learn.microsoft.com/en-us/troubleshoot/windows-server/installing-updates-features-roles/known-issue-rollback
- Intune ADMX ingestion is the same mechanism used for third-party ADMX — see https://learn.microsoft.com/en-us/intune/device-configuration/settings-catalog/configure-admx-templates-windows
- Keep a standing "KIR" OU-linked GPO template + Intune Custom profile template so the next KIR is a 10-minute job.
