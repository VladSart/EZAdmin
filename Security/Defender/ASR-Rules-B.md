# ASR Rules — Hotfix Runbook (Mode B: Ops)
> Fix or escalate in under 10 minutes.

---

## Skim Index
- [Triage](#triage)
- [Dependency Cascade](#dependency-cascade)
- [Diagnosis & Validation Flow](#diagnosis--validation-flow)
- [Common Fix Paths](#common-fix-paths)
- [Escalation Evidence](#escalation-evidence)

---

## Triage

Run on the affected device (elevated PowerShell):

```powershell
# 1 — Current ASR rule states (0=Off, 1=Block, 2=Audit, 6=Warn)
$pref = Get-MpPreference
$ids    = $pref.AttackSurfaceReductionRules_Ids
$states = $pref.AttackSurfaceReductionRules_Actions
for ($i = 0; $i -lt $ids.Count; $i++) {
    [PSCustomObject]@{ RuleId = $ids[$i]; Action = $states[$i] }
}

# 2 — Recent ASR block events (Event ID 1121 = blocked, 1122 = audited)
Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 50 -EA SilentlyContinue |
    Where-Object { $_.Id -in 1121, 1122 } |
    Select-Object TimeCreated, Id,
        @{N="Process";E={$_.Properties[5].Value}},
        @{N="RuleId";E={$_.Properties[7].Value}},
        @{N="RuleName";E={$_.Properties[9].Value}} |
    Select-Object -First 10

# 3 — Check policy source (Intune MDM vs GPO vs local)
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Windows Defender Exploit Guard\ASR\Rules" -EA SilentlyContinue

# 4 — Existing exclusions
Get-MpPreference | Select-Object AttackSurfaceReductionOnlyExclusions

# 5 — MDE ASR report (if MDE licensed)
# Check: security.microsoft.com > Reports > Attack Surface Reduction Rules
```

| Result | Likely cause | Go to |
|--------|-------------|-------|
| Event 1121 for known-good app | Rule in Block mode, no exclusion | Fix 1 |
| Event 1122 only | Rule in Audit mode — not actually blocking | Fix 2 |
| No events but app still fails | Different Defender feature (AMSI, controlled folder access, real-time) | Fix 3 |
| Rules show mixed Block/Audit | Intune policy conflict or GPO override | Fix 4 |
| Rules list empty | ASR not configured — check MDE licensing | Fix 5 |

---

## Dependency Cascade

<details><summary>What must be true for ASR to function</summary>

```
[Windows 10 1709+ / Windows 11 — E3/E5 license or MDE P1/P2]
    └── [Windows Defender AV active (real-time protection ON)]
            └── [MDE onboarded (for cloud-delivered rule updates)]
                    └── [ASR policy delivered via Intune EDR or Endpoint Security profile]
                            └── [Rules configured: Block or Audit mode]
                                    ├── [Block mode: process/file/script PREVENTED]
                                    └── [Audit mode: event logged, no block]
```

**Rule sources (priority order):**
```
Local PowerShell (Set-MpPreference) 
    ← overridden by →
GPO (HKLM:\SOFTWARE\Policies\...\ASR\Rules)
    ← overridden by →
Intune MDM (HKLM:\SOFTWARE\Microsoft\PolicyManager\...)
```
MDM wins. If Intune sets a rule to Block, local or GPO cannot override it.

</details>

---

## Diagnosis & Validation Flow

**Step 1 — Identify the blocking rule**

Check Event ID 1121 in the Windows Defender operational log:
```powershell
Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 100 -EA SilentlyContinue |
    Where-Object Id -eq 1121 |
    ForEach-Object {
        [PSCustomObject]@{
            Time    = $_.TimeCreated
            Process = $_.Properties[5].Value    # blocked executable
            File    = $_.Properties[3].Value    # target file/path
            RuleId  = $_.Properties[7].Value    # GUID of rule
        }
    } | Select-Object -First 5
```

Map Rule GUID to name using the [ASR Rules reference](https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/attack-surface-reduction-rules-reference):

| Common Rule GUID | Rule Name |
|-----------------|-----------|
| `d4f940ab-401b-4efc-aadc-ad5f3c50688a` | Block all Office apps from creating child processes |
| `3b576869-a4ec-4529-8536-b80a7769e899` | Block Office apps from creating executable content |
| `75668c1f-73b5-4cf0-bb93-3ecf5cb7cc84` | Block Office apps from injecting code into other processes |
| `be9ba2d9-53ea-4cdc-84e5-9b1eeee46550` | Block executable content from email/webmail |
| `b2b3f03d-6a65-4f7b-a9c7-1c7ef74a9ba4` | Block untrusted/unsigned processes from USB |
| `92e97fa1-2edf-4476-bdd6-9dd0b4dddc7b` | Block Win32 API calls from Office macros |
| `5beb7efe-fd9a-4556-801d-275e5ffc04cc` | Block execution of potentially obfuscated scripts |
| `e6db77e5-3df2-4cf1-b95a-636979351e5b` | Block persistence through WMI event subscription |

**Step 2 — Confirm it's ASR, not another Defender feature**

ASR blocks show: Event ID **1121** (block) or **1122** (audit) in `Microsoft-Windows-Windows Defender/Operational`.

Controlled Folder Access blocks show: Event ID **1123**.
Real-time protection blocks show: Event ID **1116** (malware detected).

If none of these match, the block is from a different source (AppLocker, WDAC, SmartScreen, Exploit Protection).

**Step 3 — Determine policy source**

```powershell
# MDM-managed rules
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Defender" -EA SilentlyContinue |
    Select-Object *ASR*

# GPO rules
Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Windows Defender Exploit Guard\ASR\Rules" -EA SilentlyContinue
```
If MDM-managed, fix must go through Intune — local changes will be reverted on next sync.

**Step 4 — Check existing exclusions**
```powershell
Get-MpPreference | Select-Object -ExpandProperty AttackSurfaceReductionOnlyExclusions
```
Expected: path to the affected executable already listed (if previously excluded). If absent, proceed to Fix 1.

---

## Common Fix Paths

<details>
<summary>Fix 1 — Add ASR exclusion for a legitimate application (Intune-managed)</summary>

ASR exclusions are path-based (not GUID/rule-specific — an exclusion exempts the path from ALL ASR rules).

**In Intune portal:**
1. Endpoint Security > Attack Surface Reduction > your ASR policy
2. Edit profile → Attack Surface Reduction Rules → Add to "Only exclusions"
3. Add the full path: e.g. `C:\Program Files\CompanyApp\app.exe`
4. Save and push — allow 15 min for sync

**Verify on device (after sync):**
```powershell
Get-MpPreference | Select-Object -ExpandProperty AttackSurfaceReductionOnlyExclusions
# Should contain the newly added path
```

**Via PowerShell (local only — will be overwritten by Intune on next sync):**
```powershell
Add-MpPreference -AttackSurfaceReductionOnlyExclusions "C:\Program Files\CompanyApp\app.exe"
```
Use local method only for emergency break-fix while waiting for Intune policy to propagate.

**Rollback:**
```powershell
Remove-MpPreference -AttackSurfaceReductionOnlyExclusions "C:\Program Files\CompanyApp\app.exe"
```
Or remove from Intune policy.
</details>

<details>
<summary>Fix 2 — Rule in Audit mode producing noise (expected — not a real block)</summary>

Event 1122 means the rule is in Audit mode — the action was logged but NOT blocked. The application should be running normally.

If the application IS failing despite only Audit events:
- The actual block is from a different source — see Step 2 of diagnosis
- Check if AMSI is blocking scripts, or real-time protection is flagging a file

To confirm audit vs. block state:
```powershell
$pref = Get-MpPreference
$ids    = $pref.AttackSurfaceReductionRules_Ids
$states = $pref.AttackSurfaceReductionRules_Actions
for ($i = 0; $i -lt $ids.Count; $i++) {
    $stateName = switch ($states[$i]) { 0{"Off"} 1{"Block"} 2{"Audit"} 6{"Warn"} default{"Unknown"} }
    [PSCustomObject]@{ RuleId = $ids[$i]; State = $stateName }
}
```
If all relevant rules show "Audit" and the app is failing, investigate AppLocker/WDAC (`Windows/Troubleshooting/`).
</details>

<details>
<summary>Fix 3 — App blocked but no ASR events found</summary>

Check other Defender enforcement features:

```powershell
# Controlled Folder Access events
Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 30 -EA SilentlyContinue |
    Where-Object Id -eq 1123 |
    Select-Object TimeCreated, @{N="App";E={$_.Properties[5].Value}}, @{N="Folder";E={$_.Properties[3].Value}}

# Real-time protection block
Get-WinEvent -LogName "Microsoft-Windows-Windows Defender/Operational" -MaxEvents 30 -EA SilentlyContinue |
    Where-Object Id -in 1116, 1117 |
    Select-Object TimeCreated, Id, Message

# Check Exploit Protection per-app settings
Get-ProcessMitigation -System
```

If Event 1123: Controlled Folder Access exclusion needed (different from ASR exclusion):
```powershell
Add-MpPreference -ControlledFolderAccessAllowedApplications "C:\Path\To\App.exe"
```

If Event 1116/1117: This is AV detection — add as exclusion or submit false positive to Microsoft.
</details>

<details>
<summary>Fix 4 — Rule states inconsistent / policy conflict</summary>

MDM and GPO can conflict. MDM takes priority:

```powershell
# Show effective rules vs. configured rules
$mdmPath = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Defender"
$gpPath  = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Windows Defender Exploit Guard\ASR\Rules"

Write-Host "=== MDM Rules ===" -ForegroundColor Cyan
Get-ItemProperty $mdmPath -EA SilentlyContinue | Select-Object *ASR*

Write-Host "=== GPO Rules ===" -ForegroundColor Cyan
Get-ItemProperty $gpPath -EA SilentlyContinue
```

If MDM and GPO have conflicting states:
1. **Preferred resolution:** Remove the GPO ASR configuration — let Intune own it entirely
2. In Group Policy: Computer Configuration > Administrative Templates > Windows Components > Windows Defender Antivirus > Windows Defender Exploit Guard > Attack Surface Reduction → Set to "Not Configured"
3. Run `gpupdate /force`, then force Intune sync, verify effective state

**Rollback:** Re-enable GPO setting if Intune policy doesn't cover needed rules.
</details>

<details>
<summary>Fix 5 — ASR rules empty / not configured</summary>

Check licensing first:
```powershell
# Get assigned M365 licenses via Graph (or check AAD portal)
# MDE P1 or P2, M365 E3/E5, or Business Premium required for ASR

# Local check — is Defender AV active?
Get-MpComputerStatus | Select-Object AMRunningMode, RealTimeProtectionEnabled
```

If AV is in Passive mode (third-party AV present), ASR rules still apply but behavior changes. In EDR Block mode, some ASR rules still fire even in passive.

To configure ASR rules via Intune:
1. Endpoint Security > Attack Surface Reduction > Create Policy
2. Platform: Windows 10/11 | Profile: Attack Surface Reduction Rules
3. Start with **Audit mode** for all rules for 2-4 weeks before switching to Block
4. Review reports at security.microsoft.com > Reports > Attack Surface Reduction Rules

**Safe starter set (Audit first, then promote to Block after validation):**
```
Block Office apps from creating child processes         → Audit → Block
Block executable content from email/webmail            → Audit → Block  
Block credential stealing from LSASS                   → Audit → Block
Block untrusted/unsigned processes from USB            → Audit → Block
```
</details>

---

## Escalation Evidence

```
=== ASR RULES ESCALATION ===
Date/Time      : 
Engineer       : 
Ticket         : 

Device Name    : 
OS Version     : 
MDE Onboarded  : (Yes/No)
AV Mode        : (Get-MpComputerStatus | Select AMRunningMode)

Affected App   : 
App Path       : 
App Version    : 
Action Observed: (blocked / crashes / other)

ASR Event ID   : (1121=Block / 1122=Audit / 1123=CFA / none)
Blocking Rule  : (GUID from event)
Rule Name      : 

Current Rule States:
(paste output of rule-states PowerShell block above)

Policy Source  : (Intune MDM / GPO / Local)
Exclusions Set : (paste Get-MpPreference | Select AttackSurfaceReductionOnlyExclusions)

Steps Attempted:
1. 
2. 
3. 

Expected behaviour : App runs without ASR interference
Actual behaviour   : 
```

---

## 🎓 Learning Pointers

- **ASR exclusions are path-based, not rule-based** — excluding a path removes it from ALL ASR rules simultaneously. Be precise with paths to avoid over-exclusion. Wildcard support is limited. [MS Docs: ASR exclusions](https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/enable-attack-surface-reduction#exclude-files-and-folders-from-asr-rules)
- **Always run Audit mode first** in a new environment — ASR rules are notorious for false-positives on LOB apps, especially anything that spawns child processes from Office or uses macro automation.
- **Event 1121 ≠ always the cause** — Controlled Folder Access (1123) and real-time AV (1116) can produce identical user symptoms. Always check event ID before adding ASR exclusion.
- **MDM overrides GPO** — if you're fighting a rule that "keeps coming back" after local changes, there's an Intune policy pushing it. Fix the Intune policy, not the device.
- **MDE portal ASR reports** (security.microsoft.com > Reports > Attack Surface Reduction Rules) show impact across your entire fleet before you go to Block mode — use it to pre-identify exclusions needed.
- **LSASS credential-stealing rule** (`9e6c4e1f-7d60-472f-ba1a-a39ef669e4b3`) is high-impact and commonly blocks legitimate apps (e.g., some backup agents, AV products). Always audit for 2+ weeks before enabling in Block mode. [MS Docs: LSASS rule](https://learn.microsoft.com/en-us/microsoft-365/security/defender-endpoint/attack-surface-reduction-rules-reference#block-credential-stealing-from-the-windows-local-security-authority-subsystem)
