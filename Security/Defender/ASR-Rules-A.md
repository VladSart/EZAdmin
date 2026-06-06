# Attack Surface Reduction Rules — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why ASR works, how rules interact, and how to deploy without breaking production.

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
- ASR rules deployed via Intune (Endpoint Security → Attack Surface Reduction)
- ASR rules deployed via Group Policy / ConfigMgr
- Rule state management: Audit → Warn → Block transitions
- False positive triage and exclusion management
- MDE Advanced Hunting for ASR telemetry

**Out of scope:**
- Network Protection (separate rule set)
- Controlled Folder Access (separate feature)
- Exploit Protection (per-process mitigation, separate from ASR)

**Assumptions:**
- Microsoft Defender Antivirus is the active AV (ASR requires MDA; third-party AV disables it)
- Windows 10 1709+ or Windows 11 (some rules require 1903+)
- MDE Plan 1 or Plan 2 licence for full telemetry; Windows Security app shows local events for non-MDE

---

## How It Works

<details><summary>Full architecture</summary>

### The ASR Engine

ASR rules are enforced by the Windows Defender kernel driver (`WdFilter.sys`) and the Antimalware Scan Interface (AMSI). Each rule is identified by a **GUID** and operates in one of four states:

```
State 0 = Disabled (rule not enforced, no logging)
State 1 = Block    (action blocked + event logged)
State 2 = Audit    (action allowed + event logged — use for testing)
State 6 = Warn     (user sees a toast, can override once per session)
```

### Rule Evaluation Flow

```
Process spawns child / opens file / executes script
        │
        ▼
WdFilter.sys intercepts kernel call
        │
        ▼
Matches ASR rule GUID criteria?
   ├─ No  → Allow
   └─ Yes → Check state
                ├─ 0 (Disabled) → Allow
                ├─ 2 (Audit)    → Allow + Event ID 1121 (audited)
                ├─ 6 (Warn)     → Block + Toast → User can click "Allow"
                └─ 1 (Block)    → Block + Event ID 1121 (blocked)
```

### Exclusion Processing

Exclusions are evaluated **before** rule enforcement:

```
Exclusion types (in precedence order):
  1. Per-rule exclusions  (OMA-URI or GP: ASROnlyExclusions per GUID)
  2. Global exclusions    (MDA exclusion list — applies to ALL rules)
  3. Folder/process path  (e.g. C:\MyApp\, myapp.exe)
```

**Critical:** Global MDA exclusions also exclude from ASR. Broad AV exclusions silently disable ASR for those paths.

### MDE Telemetry Pipeline

```
WdFilter.sys blocks/audits
        │
        ▼
Windows Security Center
        │
        ▼
MDE Sensor (MsSense.exe) → MDE Portal / Advanced Hunting
        │
        ▼
Event Log: Microsoft-Windows-Windows Defender/Operational
  Event ID 1121 = Blocked
  Event ID 1122 = Audited
  Event ID 5007 = Configuration change
```

### Intune Delivery Path

```
Intune Policy (Endpoint Security → ASR)
        │  OMA-URI: ./Vendor/MSFT/Policy/Config/Defender/AttackSurfaceReductionRules
        ▼
MDM Bridge → WMI → WdFilter.sys registry keys
        │
Registry: HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Windows Defender Exploit Guard\ASR\Rules
        │  Key = Rule GUID, Value = State (0/1/2/6)
```

### Rule GUID Reference (Key Rules)

| GUID | Rule Name | Common FP Risk |
|------|-----------|---------------|
| `be9ba2d9-53ea-4cdc-84e5-9b1eeee46550` | Block executable content from email/webmail | Medium |
| `d4f940ab-401b-4efc-aadc-ad5f3c50688a` | Block all Office apps from creating child processes | **High** |
| `3b576869-a4ec-4529-8536-b80a7769e899` | Block Office apps from creating executable content | Medium |
| `75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84` | Block Office apps from injecting into other processes | Medium |
| `d3e037e1-3eb8-44c8-a917-57927947596d` | Block JS/VBS from launching downloaded executables | Low |
| `5beb7efe-fd9a-4556-801d-275e5ffc04cc` | Block execution of potentially obfuscated scripts | **High** |
| `92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b` | Block Win32 API calls from Office macros | Low |
| `01443614-cd74-433a-b99e-2ecdc07bfc25` | Block executable files unless they meet prevalence criteria | **High** |
| `c1db55ab-c21a-4637-bb3f-a12568109d35` | Use advanced protection against ransomware | Low |
| `9e6c4e1f-7d60-472f-ba1a-a39ef669e4b0` | Block credential stealing from lsass.exe | Medium |
| `d1e49aac-8f56-4280-b9ba-993a6d77406c` | Block process creations from PSExec/WMI | **High** |
| `b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4` | Block untrusted/unsigned processes from USB | Low |
| `26190899-1602-49e8-8b27-eb1d0a1ce869` | Block Office comm apps from creating child processes | Low |
| `7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c` | Block Adobe Reader from creating child processes | Low |
| `e6db77e5-3df2-4cf1-b95a-636979351e5b` | Block persistence via WMI event subscription | Low |

</details>

---

## Dependency Stack

```
Microsoft Defender Antivirus (active, not passive mode)
        │
Windows Defender Exploit Guard service (WdNisSvc)
        │
WdFilter.sys (kernel driver — must be loaded)
        │
ASR Rule Registry Keys (HKLM\...\ASR\Rules)
        │
Policy delivery (Intune MDM / GPO / ConfigMgr)
        │
MDE Sensor (MsSense.exe) — for cloud telemetry only
        │
Intune/MDE Portal visibility
```

**If any layer is broken, rules at the layers above will silently not enforce.**

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|------------------|-------|
| Rules show as configured in Intune but not enforced | Third-party AV active; MDA in passive mode | `Get-MpComputerStatus \| Select AMRunningMode` |
| Specific application breaks after enabling rules | ASR Block hit without exclusion | Event ID 1121 in Defender Operational log |
| Rules show "Not applicable" in Intune | Windows version < 1709, or rule GUID not supported on that build | Check OS version + rule GUID compatibility matrix |
| User gets toast but no block occurs in logs | Rule in Warn (state 6) mode, user clicked Allow | Check `Get-MpPreference \| Select AttackSurfaceReductionRules_Actions` |
| All rules appear disabled even though policy deployed | MDM conflict — another policy is setting state to 0 | Check merged policy via `Get-MpPreference` vs GP RSoP |
| Macro-based business app broken | Rule `d4f940ab` blocking Office child process | Verify process name in Event 1121 InitiatingProcessFileName |
| Script execution broken | Rule `5beb7efe` blocking obfuscated PS | Check PowerShell event log + ASR Event 1121 |
| Security baseline policy conflicts with ASR | Baseline and ASR policy set same GUID to different states | Check Intune policy conflict blade for the device |
| PSExec scripts failing | Rule `d1e49aac` active — PSExec creates processes via WMI | Expected behaviour; add PSExec path to per-rule exclusion |

---

## Validation Steps

**1. Confirm MDA is active (not passive/EDR-only):**
```powershell
Get-MpComputerStatus | Select-Object AMRunningMode, RealTimeProtectionEnabled, AntivirusEnabled
```
Expected: `AMRunningMode = Normal`, `RealTimeProtectionEnabled = True`
Bad: `AMRunningMode = Passive` → ASR rules are **not enforced** in passive mode.

**2. Confirm WdFilter.sys is loaded:**
```powershell
Get-Service -Name WdFilter | Select-Object Status, StartType
fltmc | findstr WdFilter
```
Expected: `Status = Running`, visible in fltmc output.

**3. Read current ASR rule states from registry:**
```powershell
Get-MpPreference | Select-Object -ExpandProperty AttackSurfaceReductionRules_Ids
Get-MpPreference | Select-Object -ExpandProperty AttackSurfaceReductionRules_Actions
```
Returns parallel arrays: first array = GUIDs, second array = states (0/1/2/6).

**4. Check for recent ASR blocks/audits (last 24 hours):**
```powershell
Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 500 |
    Where-Object { $_.Id -in @(1121, 1122) } |
    Select-Object TimeCreated, Id, Message |
    Sort-Object TimeCreated -Descending
```
Event 1121 = blocked/audited action. Message contains: rule GUID, initiating process, target file.

**5. Validate Intune policy delivery (check MDM diagnostics):**
```powershell
# Run MDM diagnostics
MdmDiagnosticsTool.exe -out C:\Temp\MDMDiag
# Then check: C:\Temp\MDMDiag\MDMDiagReport.html → search "AttackSurfaceReduction"
```

**6. Check for exclusions that may be suppressing rules:**
```powershell
Get-MpPreference | Select-Object ExclusionPath, ExclusionProcess, ExclusionExtension
Get-MpPreference | Select-Object AttackSurfaceReductionOnlyExclusions
```

---

## Troubleshooting Steps (by phase)

### Phase 1: Policy Not Applied

1. Confirm device is enrolled in Intune and primary user licence includes MDE.
2. Check Intune device config blade → profile status → any errors.
3. Run `MdmDiagnosticsTool.exe -out C:\Temp\MDMDiag` and verify OMA-URI values in report.
4. Check registry: `HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Windows Defender Exploit Guard\ASR\Rules` — GUIDs should be present.
5. If keys missing, trigger Intune sync: `Invoke-MgDeviceManagementManagedDeviceSyncDevice` or use Company Portal → Sync.

### Phase 2: Rule Active but Not Blocking

1. Confirm `AMRunningMode = Normal` (not Passive).
2. Verify GUID state = 1 (Block), not 2 (Audit) or 6 (Warn).
3. Check if the path involved is in `ExclusionPath` or `AttackSurfaceReductionOnlyExclusions`.
4. Check if another policy (GPO / ConfigMgr baseline) is overriding state to 0 or 2.
5. Verify OS build supports the rule (e.g. rule `e6db77e5` WMI persistence requires Windows 10 1903+).

### Phase 3: False Positive / Application Broken

1. Identify which rule fired: extract GUID from Event 1121 message.
2. Identify initiating process and target from event.
3. Assess: Is this a legitimate business process?
   - Yes → add per-rule exclusion (preferred over global AV exclusion)
   - No → rule is working as intended, investigate the process
4. For per-rule exclusion via Intune: use OMA-URI `./Vendor/MSFT/Policy/Config/Defender/AttackSurfaceReductionOnlyExclusions`.
5. Test exclusion in Audit mode first on a pilot group before widening.

### Phase 4: Rollout Strategy (Audit → Block)

1. Deploy all rules in **Audit** mode (state 2) to all devices for minimum 2 weeks.
2. Query Advanced Hunting for audit events:
   ```kusto
   DeviceEvents
   | where ActionType startswith "AsrAudit"
   | summarize Count=count() by RuleId, InitiatingProcessFileName, FileName
   | order by Count desc
   ```
3. For each rule with audit events:
   - Identify legitimate business processes generating events.
   - Add per-rule exclusions for those processes.
   - Re-audit for 1 week post-exclusion.
4. Move rules with zero or resolved audit events to **Block** (state 1).
5. Leave high-FP rules (e.g. `d4f940ab`, `01443614`) in Warn (state 6) for user populations with LOB dependencies.

---

## Remediation Playbooks

<details><summary>Playbook 1 — Enable all rules in Audit mode via Intune OMA-URI</summary>

**Use when:** Starting fresh ASR deployment; no existing policy.

**Intune OMA-URI Settings (add each as a separate custom OMA-URI):**

```
OMA-URI: ./Vendor/MSFT/Policy/Config/Defender/AttackSurfaceReductionRules
Data type: String
Value: <GUID>=2;<GUID>=2;...
```

**PowerShell equivalent (local test / GPO):**
```powershell
$GUIDs = @(
    "be9ba2d9-53ea-4cdc-84e5-9b1eeee46550",
    "d4f940ab-401b-4efc-aadc-ad5f3c50688a",
    "3b576869-a4ec-4529-8536-b80a7769e899",
    "75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84",
    "d3e037e1-3eb8-44c8-a917-57927947596d",
    "5beb7efe-fd9a-4556-801d-275e5ffc04cc",
    "92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b",
    "01443614-cd74-433a-b99e-2ecdc07bfc25",
    "c1db55ab-c21a-4637-bb3f-a12568109d35",
    "9e6c4e1f-7d60-472f-ba1a-a39ef669e4b0",
    "d1e49aac-8f56-4280-b9ba-993a6d77406c",
    "b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4",
    "26190899-1602-49e8-8b27-eb1d0a1ce869",
    "7674ba52-37eb-4a4f-a9a1-f0f9a1619a2c",
    "e6db77e5-3df2-4cf1-b95a-636979351e5b"
)
Add-MpPreference -AttackSurfaceReductionRules_Ids $GUIDs -AttackSurfaceReductionRules_Actions (@(2) * $GUIDs.Count)
```

**Rollback:**
```powershell
Remove-MpPreference -AttackSurfaceReductionRules_Ids $GUIDs
```

</details>

<details><summary>Playbook 2 — Add per-rule exclusion for a specific process</summary>

**Use when:** A specific executable is triggering a rule and it's a known-good business app.

```powershell
# Identify the rule GUID from Event 1121, then:
$RuleGUID = "<GUID-from-event>"
$ExclusionPath = "C:\Program Files\<YourApp>\<yourapp.exe>"

# Add exclusion scoped to that rule only
Add-MpPreference -AttackSurfaceReductionOnlyExclusions $ExclusionPath

# Verify
Get-MpPreference | Select-Object -ExpandProperty AttackSurfaceReductionOnlyExclusions
```

**In Intune (OMA-URI):**
```
OMA-URI: ./Vendor/MSFT/Policy/Config/Defender/AttackSurfaceReductionOnlyExclusions
Data type: String
Value: C:\Program Files\<YourApp>\<yourapp.exe>
```

**Rollback:**
```powershell
Remove-MpPreference -AttackSurfaceReductionOnlyExclusions $ExclusionPath
```

</details>

<details><summary>Playbook 3 — Transition a rule from Audit to Block</summary>

**Use when:** Rule has been in Audit for 2+ weeks, no unresolved FPs.

```powershell
$RuleGUID = "<target-rule-GUID>"

# First confirm current state
$prefs = Get-MpPreference
$idx = $prefs.AttackSurfaceReductionRules_Ids.IndexOf($RuleGUID)
Write-Host "Current state: $($prefs.AttackSurfaceReductionRules_Actions[$idx])"

# Move to Block
Set-MpPreference -AttackSurfaceReductionRules_Ids $RuleGUID -AttackSurfaceReductionRules_Actions 1

# Verify
$prefs = Get-MpPreference
$idx = $prefs.AttackSurfaceReductionRules_Ids.IndexOf($RuleGUID)
Write-Host "New state: $($prefs.AttackSurfaceReductionRules_Actions[$idx])"
```

**In Intune:** Update the OMA-URI value for that GUID from `2` to `1`.

**Rollback:** Change value back to `2` in Intune policy and sync.

</details>

<details><summary>Playbook 4 — Resolve policy conflict (Intune vs GPO)</summary>

**Use when:** `Get-MpPreference` shows different values than Intune portal reports.

```powershell
# Check what MDM is delivering
$MDMPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Windows Defender Exploit Guard\ASR\Rules"
Get-ItemProperty -Path $MDMPath -ErrorAction SilentlyContinue

# Check what GPO is delivering  
$GPOPath = "HKLM:\SOFTWARE\Microsoft\Windows Defender\Windows Defender Exploit Guard\ASR\Rules"
Get-ItemProperty -Path $GPOPath -ErrorAction SilentlyContinue

# Run RSoP for GP
gpresult /H C:\Temp\RSoP.html /F
```

If both sources set the same GUID to conflicting states, MDM (Intune) takes precedence when device is MDM-enrolled. Remove the GPO setting or align them.

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collect ASR evidence for escalation or audit
.NOTES     Run as admin on affected endpoint
#>

$OutputDir = "C:\Temp\ASR-Evidence-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# 1. MDA status and ASR configuration
Get-MpComputerStatus | Export-Csv "$OutputDir\MDA-Status.csv" -NoTypeInformation
$prefs = Get-MpPreference
[PSCustomObject]@{
    RuleIds     = ($prefs.AttackSurfaceReductionRules_Ids -join "; ")
    RuleActions = ($prefs.AttackSurfaceReductionRules_Actions -join "; ")
    GlobalExclusions     = ($prefs.ExclusionPath -join "; ")
    ASROnlyExclusions    = ($prefs.AttackSurfaceReductionOnlyExclusions -join "; ")
    ExclusionProcess     = ($prefs.ExclusionProcess -join "; ")
} | Export-Csv "$OutputDir\ASR-Config.csv" -NoTypeInformation

# 2. Recent ASR events (48 hours)
$events = Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 1000 -ErrorAction SilentlyContinue |
    Where-Object { $_.Id -in @(1121, 1122, 5007) -and $_.TimeCreated -gt (Get-Date).AddHours(-48) }
$events | Select-Object TimeCreated, Id, Message | Export-Csv "$OutputDir\ASR-Events.csv" -NoTypeInformation

# 3. Registry state
$MDMPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Windows Defender Exploit Guard\ASR\Rules"
$LocalPath = "HKLM:\SOFTWARE\Microsoft\Windows Defender\Windows Defender Exploit Guard\ASR\Rules"
$MDMKeys  = Get-ItemProperty -Path $MDMPath  -ErrorAction SilentlyContinue
$LocalKeys = Get-ItemProperty -Path $LocalPath -ErrorAction SilentlyContinue
[PSCustomObject]@{ Source="MDM";   Keys=($MDMKeys   | Out-String) } | Export-Csv "$OutputDir\Registry-ASR.csv" -NoTypeInformation -Append
[PSCustomObject]@{ Source="Local"; Keys=($LocalKeys | Out-String) } | Export-Csv "$OutputDir\Registry-ASR.csv" -NoTypeInformation -Append

# 4. MDM diagnostic snapshot
try {
    MdmDiagnosticsTool.exe -out "$OutputDir\MDMDiag" | Out-Null
} catch { Write-Warning "MDMDiagnosticsTool not available" }

# 5. System info
Get-ComputerInfo | Select-Object CsName, OsVersion, OsBuildNumber, WindowsVersion |
    Export-Csv "$OutputDir\System-Info.csv" -NoTypeInformation

Write-Host "Evidence collected to: $OutputDir" -ForegroundColor Green
Compress-Archive -Path "$OutputDir\*" -DestinationPath "$OutputDir.zip"
Write-Host "Archive: $OutputDir.zip" -ForegroundColor Green
```

---

## Command Cheat Sheet

```powershell
# Read all ASR rule states
Get-MpPreference | Select AttackSurfaceReductionRules_Ids, AttackSurfaceReductionRules_Actions

# Set a single rule to Audit (2)
Set-MpPreference -AttackSurfaceReductionRules_Ids "<GUID>" -AttackSurfaceReductionRules_Actions 2

# Set a single rule to Block (1)
Set-MpPreference -AttackSurfaceReductionRules_Ids "<GUID>" -AttackSurfaceReductionRules_Actions 1

# Set a single rule to Disabled (0)
Set-MpPreference -AttackSurfaceReductionRules_Ids "<GUID>" -AttackSurfaceReductionRules_Actions 0

# Add per-rule exclusion
Add-MpPreference -AttackSurfaceReductionOnlyExclusions "C:\Path\To\app.exe"

# View exclusions
Get-MpPreference | Select ExclusionPath, ExclusionProcess, AttackSurfaceReductionOnlyExclusions

# Recent blocks and audits
Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 200 |
    Where-Object Id -in 1121,1122 | Select TimeCreated, Id, Message

# Confirm MDA mode
Get-MpComputerStatus | Select AMRunningMode, RealTimeProtectionEnabled

# MDM delivered registry keys
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Windows Defender Exploit Guard\ASR\Rules"

# Advanced Hunting — audit events (MDE Portal / KQL)
# DeviceEvents | where ActionType startswith "AsrAudit" | summarize count() by RuleId, InitiatingProcessFileName

# Advanced Hunting — block events
# DeviceEvents | where ActionType startswith "AsrBlocked" | summarize count() by RuleId, InitiatingProcessFileName

# Force Intune policy sync
Invoke-CimMethod -Namespace root/CIMV2/MDM/DMMap -ClassName MDM_Client -MethodName TriggerSync
```

---

## 🎓 Learning Pointers

- **ASR requires MDA as active AV** — if a third-party AV is installed and MDA is in passive mode, ASR rules are silently not enforced even though they appear configured. Always verify `AMRunningMode = Normal`. [MS Docs: ASR prerequisites](https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/attack-surface-reduction-rules-deployment-prerequisites)

- **Per-rule exclusions vs global exclusions** — adding a path to MDA's global exclusion list also disables ASR for that path. Always use `AttackSurfaceReductionOnlyExclusions` for targeted exclusions to minimise exposure. [MS Docs: ASR exclusions](https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/enable-attack-surface-reduction#exclude-files-and-folders-from-asr-rules)

- **Audit mode is production-safe** — deploying all rules in state 2 (Audit) does not affect users but generates telemetry. This is the recommended starting point for every new tenant. Skipping audit → block transitions cold is the most common cause of LOB application outages.

- **Rule `01443614` (block executable files by prevalence) generates the most FPs** in enterprise environments — it blocks installers, one-off executables, and software from small vendors that haven't built up cloud prevalence. Keep this in Warn or Audit until prevalence data is established. [MS Docs: Rule reference](https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/attack-surface-reduction-rules-reference)

- **MDE Advanced Hunting is the best source of truth for ASR impact** — Event Viewer only shows local events. Advanced Hunting (`DeviceEvents | where ActionType startswith "Asr"`) gives fleet-wide visibility for FP triage before a block rollout.

- **Policy conflicts between Intune and GPO** are a top cause of unexpected rule states. MDM (Intune) wins when both are present on an enrolled device, but the GP-sourced keys in `HKLM\SOFTWARE\Microsoft\...` vs the MDM-sourced keys in `HKLM\SOFTWARE\Policies\Microsoft\...` can create confusion when reading `Get-MpPreference`. Always check both registry paths when state doesn't match expectations.
