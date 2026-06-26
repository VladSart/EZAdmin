# Intune Security Baselines — Reference Runbook (Mode A: Deep Dive)
> Engineering-grade reference. Explains why, not just what.

---

## Skim Index
- [Scope & Assumptions](#scope--assumptions)
- [How Security Baselines Work](#how-security-baselines-work)
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

- **Covers:** Intune Security Baselines (MDM Security Baseline, Microsoft Defender for Endpoint, Microsoft 365 Apps, Edge), conflict resolution with Configuration Profiles and GPO, compliance reporting, and upgrade/migration between baseline versions
- **Does NOT cover:** Custom OMA-URI policies (see Policy-Conflict), GPO-managed environments without Intune, third-party baselines (CIS Benchmarks applied via SCCM)
- **Pre-requisites:** Microsoft Intune Plan 1 or higher, devices enrolled in Intune (AAD-joined, Hybrid AAD-joined, or co-managed with Workloads set to Intune)
- **Run as:** Intune Administrator or equivalent Graph API permissions

---

## How Security Baselines Work

<details><summary>Full architecture — baseline delivery and enforcement pipeline</summary>

### What Is a Security Baseline?

An Intune Security Baseline is a pre-built policy bundle that maps to Microsoft's hardening recommendations. Each baseline is a versioned snapshot tied to a specific Microsoft guidance set (e.g., Windows 11 Security Baseline, November 2021).

Available baselines (as of 2025):
| Baseline | What it configures |
|----------|-------------------|
| **MDM Security Baseline** | ~350 Windows settings (OS hardening, Defender, BitLocker, etc.) |
| **MDE Security Baseline** | Defender for Endpoint–specific settings |
| **Microsoft 365 Apps Baseline** | Office hardening (macro blocking, update channel, etc.) |
| **Microsoft Edge Baseline** | Edge browser hardening |
| **Windows 365 Cloud PC Baseline** | Cloud PC–specific settings |

### How Baseline Settings Are Delivered

```
Intune Portal (baseline profile assigned to group)
        │
        ▼
Microsoft Intune MDM channel (OMA-DM)
        │
        ▼
Windows MDM bridge (WMI → CSP)
        │
        ▼
CSP (Configuration Service Provider) — e.g., Policy CSP, Defender CSP, BitLocker CSP
        │
        ▼
Windows registry / service / kernel enforcement
```

### CSP Path Structure

Each baseline setting maps to a CSP path:
```
./Device/Vendor/MSFT/Policy/Config/<Area>/<SettingName>
```

Example — block USB storage:
```
./Device/Vendor/MSFT/Policy/Config/Storage/RemovableDiskDenyWriteAccess
```

### Baseline Versioning

Baselines are versioned. When Microsoft releases a new version, existing profiles stay on the old version until you migrate. You cannot auto-upgrade — migration is manual or via duplication.

```
Baseline v21H1 → v22H2 → Nov2023 → Aug2024
    ↑                                  ↑
 (existing profile)         (new profile, must create + migrate)
```

### Conflict Resolution Priority (high to low)

When multiple policies target the same CSP setting:
```
1. Endpoint Security policies (highest — overrides everything)
2. Security Baselines
3. Configuration Profiles (Settings Catalog / Templates)
4. OMA-URI custom profiles
5. Compliance policies (report only — don't configure)
```

**Exception:** If two policies of the same type conflict, the setting becomes "Error" or "Not applicable" — Intune does not arbitrate between same-tier conflicts.

### Conflict with GPO (Co-managed / Hybrid)

When both Intune MDM and GPO target the same setting:
- **ADMX-backed policies:** The "last writer wins" — whichever was applied most recently persists in the registry
- **CSP-only settings:** MDM wins over GPO for modern CSPs
- **MDM wins GP (Windows 10 1803+):** With `ControlPolicyConflict/MDMWinsOverGP = 1`, MDM CSP policies override conflicting ADMX-backed GPOs

</details>

---

## Dependency Stack

```
Intune Security Baseline Profile (version-locked)
        │
        ▼
  Device Group Assignment (Entra ID Security Group / dynamic group / All Devices)
        │
        ▼
  MDM Check-in (every 8 hours by default, or triggered via Intune portal / Sync)
        │
        ▼
  Policy CSP / BitLocker CSP / Defender CSP / etc.
        │
      ┌─┴────────────────────────┐
      ▼                          ▼
  MDM Bridge (Windows)    Win32 service enforcement
  (registry via WMI)      (BitLocker, Defender, etc.)
        │
        ▼
  Device Compliance Evaluation (based on configured settings)
        │
        ▼
  Compliance State → Conditional Access enforcement
```

---

## Symptom → Cause Map

| Symptom | Most Likely Cause | Check |
|---------|-------------------|-------|
| Setting shows "Error" in device baseline report | Conflict with another policy at same tier, or unsupported CSP on that OS version | Device baseline report → drill into error; check Configuration Profiles for duplicate setting |
| Setting shows "Not applicable" | OS version doesn't support that CSP, or device is not MDM-enrolled | Check OS build, verify MDM enrollment |
| Baseline deployed but device still shows "Non-compliant" | Compliance policy evaluates different settings than baseline; or baseline doesn't auto-create compliance policy | Baseline ≠ compliance policy — assign a separate compliance policy |
| New baseline version breaks previously working settings | Version migration changed defaults or removed settings | Compare old vs. new version in Intune UI; test on pilot group first |
| Conflicting baseline and Configuration Profile | Both policies target same CSP — Intune flags conflict | Use "Conflict" filter in Endpoint Security > Security Baselines > device report |
| GPO and baseline conflict (hybrid join) | MDM and GPO both targeting same registry key | Check MDM wins over GPO policy, or remove GPO setting |
| User can't install apps after baseline | MDM Security Baseline blocks sideloading / Store | Check `ApplicationManagement/AllowAllTrustedApps` CSP |
| BitLocker enforced unexpectedly | Baseline includes BitLocker settings targeting OS drive | Review BitLocker CSP settings in baseline report |
| Edge broken / new tab page missing | Edge baseline over-restricts Edge settings | Check Edge baseline for `HomepageLocation`, `NewTabPageLocation` settings |
| Macro blocking breaks business app | M365 Apps baseline blocks VBA macros | Override macro setting in separate Configuration Profile (lower priority) — or create exception |

---

## Validation Steps

**1. Verify baseline is assigned and check-in completed**

```powershell
# Check MDM enrollment and last sync
$mdmInfo = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Enrollments\*' -ErrorAction SilentlyContinue |
    Where-Object {$_.EnrollmentType -ne $null}
$mdmInfo | Select-Object PSChildName, EnrollmentType, UPN, LastCheckinTime | Format-Table -AutoSize
```

Or from Intune portal: Devices → <device> → Device configuration → filter by baseline profile.

---

**2. Verify MDM sync is functional**

```powershell
# Trigger MDM sync
$session = New-CimSession
Invoke-CimMethod -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_DMSessionActions' `
    -MethodName 'BeginSession' -CimSession $session -ErrorAction SilentlyContinue

# Alternatively, via scheduled task
Start-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\' -TaskName '*'
```

Then check Event Viewer: **Applications and Services Logs → Microsoft → Windows → DeviceManagement-Enterprise-Diagnostics-Provider → Admin** for policy application results.

---

**3. Read applied CSP values from device registry**

```powershell
# MDM policy values land here
$policyPath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device'
Get-ChildItem $policyPath | ForEach-Object {
    $area = $_.PSChildName
    Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue |
        Where-Object {$_ -is [PSCustomObject]} |
        Select-Object * -ExcludeProperty PS* |
        ForEach-Object {
            $_.PSObject.Properties | ForEach-Object {
                [PSCustomObject]@{Area=$area; Setting=$_.Name; Value=$_.Value}
            }
        }
} | Format-Table -AutoSize
```

---

**4. Check for policy conflicts**

```powershell
# Check MDM conflict log
Get-WinEvent -FilterHashtable @{
    LogName = 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin'
    Level   = 2   # Error
    StartTime = (Get-Date).AddDays(-1)
} -ErrorAction SilentlyContinue | Select-Object TimeCreated, Message | Format-List
```

Or in Intune portal: Endpoint Security → Security Baselines → <profile> → Device Status → click device → "Conflict" column.

---

**5. Identify which policies are targeting a specific setting**

```powershell
# Example: find who is setting 'SmartScreen' on this device
$areas = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\PolicyManager\providers'
foreach ($provider in $areas) {
    $vals = Get-ItemProperty $provider.PSPath -ErrorAction SilentlyContinue
    $vals.PSObject.Properties | Where-Object {$_.Name -like '*SmartScreen*'} |
        ForEach-Object { Write-Host "$($provider.PSChildName): $($_.Name) = $($_.Value)" }
}
```

---

**6. Verify MDM wins over GPO is configured**

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceManagement' `
    -Name 'MDMWinsOverGP' -ErrorAction SilentlyContinue
```

Expected: `MDMWinsOverGP = 1` (set via GPO Computer Config → Administrative Templates → Windows Components → MDM)
Missing or 0: GPO may override MDM CSP policy.

---

**7. Export full MDM diagnostic report**

```powershell
# Collect full MDM diagnostics — output is a CAB file
$outputPath = "C:\Temp\MDMDiag_$(Get-Date -Format 'yyyyMMdd-HHmmss').cab"
MdmDiagnosticsTool.exe -out $outputPath -area 'DeviceEnrollment;DeviceManagement;TPM'
Write-Host "MDM diagnostic report saved to: $outputPath"
```

Open the CAB and look for `MDMDiagReport.xml` — contains all policies, their sources, and conflict status.

---

## Troubleshooting Steps (by phase)

### Phase 1 — Baseline not applying at all

1. Confirm device is in the assigned group: Intune → Groups → <group> → Members
2. Confirm device is MDM-enrolled: `dsregcmd /status` → `MDMEnrollmentUrl` must be populated
3. Check last sync: Intune → Device → Sync. If >8 hours, trigger sync
4. Check event log: DeviceManagement-Enterprise-Diagnostics-Provider/Admin — look for enrollment or policy errors
5. Co-managed devices: check Intune workload "Device Configuration" is set to Intune, not SCCM

### Phase 2 — Settings showing Error or Conflict

1. In Intune portal: Endpoint Security → Security Baselines → Profile → Device Status → drill into device → find red settings
2. For each conflicting setting: identify which other profile is targeting it
3. Resolve by: removing the duplicate setting from the Configuration Profile, or creating a "ring" where baselines are authoritative
4. If conflict is with GPO: enable MDMWinsOverGP or remove the GPO setting
5. Never try to "fix" conflicts by duplicating the setting in another policy — this deepens the conflict

### Phase 3 — Baseline causes app/functionality breakage

1. Identify the breaking setting via user report + baseline diff
2. In Intune: export baseline settings list (CSV) to identify the offending CSP
3. Options:
   - **Exclude setting:** Baselines don't support per-setting exclusions — you must create a Configuration Profile that overrides the setting (Configuration Profiles have lower priority than baselines for Endpoint Security, but you can re-configure the setting in a Compliance or Settings Catalog profile — test carefully)
   - **Migrate to Settings Catalog:** Recreate the baseline manually in Settings Catalog where you have granular control
   - **Exception group:** Create an exclusion group and remove affected devices from baseline assignment temporarily

### Phase 4 — Migrating to a new baseline version

1. In Intune: Endpoint Security → Security Baselines → select profile → Properties → Security Baseline version → "Change Version"
2. Review the diff — Microsoft shows what changed between versions
3. **Do not migrate directly on all devices.** Create a new baseline profile with the new version and assign to a pilot ring first
4. After pilot validation (1-2 weeks), reassign main profile
5. The old profile can remain for rollback — just move devices between assignment groups

---

## Remediation Playbooks

<details><summary>Fix 1 — Resolve conflict between Security Baseline and Configuration Profile</summary>

```powershell
# Step 1: Identify the conflicting setting from MDM event log
$conflictEvents = Get-WinEvent -FilterHashtable @{
    LogName = 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin'
    Level = 2
    StartTime = (Get-Date).AddDays(-1)
} -ErrorAction SilentlyContinue

$conflictEvents | Select-Object TimeCreated, Message | Format-List

# Step 2: Check which MDM policies are loaded for the conflicting area
# (Example: checking SmartScreen policies)
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\SmartScreen' -ErrorAction SilentlyContinue

# Step 3: Document conflicting profile names from Intune portal
# Resolution must be done in Intune UI — remove the duplicate setting from the lower-priority profile
Write-Host "Resolution: Remove the conflicting setting from the Configuration Profile in Intune portal."
Write-Host "Security Baselines take priority over Configuration Profiles."
```

</details>

<details><summary>Fix 2 — Enable MDM wins over GPO (hybrid-joined devices)</summary>

```powershell
# Via PowerShell (local — for testing; deploy via GPO for fleet)
$regPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceManagement'
if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
Set-ItemProperty -Path $regPath -Name 'MDMWinsOverGP' -Value 1 -Type DWord

Write-Host "MDMWinsOverGP enabled. MDM CSP policies will now override conflicting ADMX-backed GPOs." -ForegroundColor Green
Write-Warning "This is a policy registry key — it should be deployed via GPO, not set manually."

# Verify
Get-ItemProperty $regPath -Name MDMWinsOverGP
```

**Deploy via GPO:**
Computer Config → Admin Templates → Windows Components → MDM → Enable "MDM wins over Group Policy"

**Rollback:** Set `MDMWinsOverGP = 0` or remove the registry value.

</details>

<details><summary>Fix 3 — Trigger forced MDM sync and collect diagnostics</summary>

```powershell
# Force MDM sync via scheduled task
$tasks = Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' -ErrorAction SilentlyContinue
if ($tasks) {
    $tasks | Start-ScheduledTask
    Write-Host "MDM sync tasks triggered:" -ForegroundColor Cyan
    $tasks | Select-Object TaskName, State | Format-Table
} else {
    Write-Warning "No EnterpriseMgmt scheduled tasks found. Is device MDM enrolled?"
}

# Wait and check event log
Start-Sleep -Seconds 30
$recentEvents = Get-WinEvent -FilterHashtable @{
    LogName = 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin'
    StartTime = (Get-Date).AddMinutes(-2)
} -ErrorAction SilentlyContinue | Select-Object TimeCreated, Level, Message

Write-Host "`nRecent MDM events:" -ForegroundColor Cyan
$recentEvents | Format-List
```

</details>

<details><summary>Fix 4 — Identify and document all Security Baseline settings on a device</summary>

```powershell
<#
.SYNOPSIS  Exports all MDM-managed policy values from the device for baseline audit
.NOTES     Run on the target device as administrator
#>

$outputCsv = "C:\Temp\MDM-PolicyAudit_$(Get-Date -Format 'yyyyMMdd').csv"
$null = New-Item -Path (Split-Path $outputCsv) -ItemType Directory -Force -ErrorAction SilentlyContinue

$results = @()
$policyBase = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device'

if (Test-Path $policyBase) {
    $areas = Get-ChildItem $policyBase -ErrorAction SilentlyContinue
    foreach ($area in $areas) {
        $values = Get-ItemProperty $area.PSPath -ErrorAction SilentlyContinue
        if ($values) {
            $values.PSObject.Properties | Where-Object {$_.Name -notlike 'PS*'} | ForEach-Object {
                $results += [PSCustomObject]@{
                    Area    = $area.PSChildName
                    Setting = $_.Name
                    Value   = $_.Value
                    Path    = $area.PSPath
                }
            }
        }
    }
}

$results | Export-Csv -Path $outputCsv -NoTypeInformation
Write-Host "MDM policy audit exported to: $outputCsv ($($results.Count) settings)" -ForegroundColor Green
```

</details>

---

## Evidence Pack

```powershell
<#
.SYNOPSIS  Collects Security Baseline diagnostics for escalation
.NOTES     Run on the affected device as administrator
#>

$outputFile = "C:\Temp\SecurityBaseline-Diag_$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
$null = New-Item -Path (Split-Path $outputFile) -ItemType Directory -Force -ErrorAction SilentlyContinue

function Log { param($msg) $msg | Tee-Object -FilePath $outputFile -Append | Write-Host }

Log "=== Security Baseline Diagnostics === $(Get-Date)"

Log "`n--- Device MDM Enrollment ---"
Log (& dsregcmd /status 2>&1 | Select-String 'MDM|AzureAd|DomainJoined|EnrollmentUrl' | Out-String)

Log "`n--- MDM Enrollment Details ---"
$enrollment = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Enrollments\*' -ErrorAction SilentlyContinue |
    Where-Object {$_.EnrollmentType -ne $null}
Log ($enrollment | Select-Object UPN, EnrollmentType, ProviderID, MDMServiceUri | Format-List | Out-String)

Log "`n--- MDMWinsOverGP ---"
Log (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceManagement' -ErrorAction SilentlyContinue | Out-String)

Log "`n--- MDM Event Log (last 24h errors) ---"
try {
    Get-WinEvent -FilterHashtable @{
        LogName = 'Microsoft-Windows-DeviceManagement-Enterprise-Diagnostics-Provider/Admin'
        Level = 2
        StartTime = (Get-Date).AddDays(-1)
    } -ErrorAction SilentlyContinue | Select-Object TimeCreated, Message |
        Tee-Object -FilePath $outputFile -Append | Format-List | Out-String | Write-Host
} catch { Log "Could not read MDM event log: $_" }

Log "`n--- MDM Policy Areas (count per area) ---"
Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device' -ErrorAction SilentlyContinue |
    Select-Object @{N='Area';E={$_.PSChildName}},
    @{N='Settings';E={(Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object {$_.Name -notlike 'PS*'} | Measure-Object | Select-Object -ExpandProperty Count}} |
    Tee-Object -FilePath $outputFile -Append | Format-Table | Out-String | Write-Host

Log "`n--- BitLocker Status (if enforced by baseline) ---"
Log (Get-BitLockerVolume -ErrorAction SilentlyContinue | Select-Object MountPoint, VolumeStatus, EncryptionPercentage, KeyProtector | Format-Table | Out-String)

Log "`n=== End === Output: $outputFile"
```

---

## Escalation Evidence

```
TICKET ESCALATION — INTUNE SECURITY BASELINE ISSUE
===================================================
Date/Time              : ___________
Affected device(s)     : ___________
Baseline profile name  : ___________
Baseline version       : ___________
Issue (conflict/error/breakage): ___________
Affected setting(s)    : ___________
Conflicting policy name: ___________
Device join type       : [AAD-joined / Hybrid AAD-joined / Co-managed]
Last MDM sync          : ___________
MDMWinsOverGP enabled  : ___________
Error code in event log: ___________

Attached: MDM-PolicyAudit CSV, SecurityBaseline-Diag.txt, Intune device status screenshot
Escalate to: Intune / EMS team
```

---

## Command Cheat Sheet

| Command | Purpose |
|---------|---------|
| `dsregcmd /status` | Check MDM enrollment and join type |
| `MdmDiagnosticsTool.exe -out C:\Temp\diag.cab` | Full MDM diagnostic report |
| `Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device'` | List all MDM policy areas |
| `Get-BitLockerVolume` | Check BitLocker status (enforced by baseline) |
| `Start-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*'` | Force MDM sync |
| `Get-WinEvent -LogName '...Enterprise-Diagnostics...'` | MDM event log |
| `gpresult /r` | Show applied GPOs (to find conflicts) |
| `Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\PolicyManager\...'` | Read specific CSP value |
| Intune portal: Endpoint Security → Baselines → profile → Device Status | Per-device baseline compliance |
| Intune portal: Devices → <device> → Configuration → filter Profile Type = Baseline | All baseline profiles on a device |

---

## 🎓 Learning Pointers

- **Security Baselines are versioned snapshots — they don't auto-update.** When Microsoft releases a new version (e.g., Windows 11 Security Baseline August 2024), your existing profile remains on the old version indefinitely. You must actively migrate. This is by design — unexpected changes to hardening settings can break production. Build a pilot-first migration process into your baseline management workflow. [MS Docs: Manage security baselines](https://learn.microsoft.com/en-us/mem/intune/protect/security-baselines)

- **Baselines are not compliance policies.** A device can have all baseline settings applied and still show "non-compliant" in Intune — because compliance evaluates the compliance policy, not the baseline. You must deploy a separate compliance policy with matching settings if you want CA enforcement based on baseline state.

- **The "Error" state means conflict, not a bug in the setting.** When Intune shows a setting as "Error" in the baseline report, it almost always means two policies are fighting over the same CSP path. The fix is always to find and remove the duplicate — not to re-push the baseline or resync the device.

- **MDM wins over GPO requires explicit opt-in.** Hybrid AAD-joined devices can have both GPO and MDM targeting the same setting. Without `MDMWinsOverGP = 1`, the result is unpredictable and depends on application order. For any environment moving workloads to Intune, this should be one of the first Intune GPOs you deploy. [MS Docs: MDM and GPO coexistence](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-controlpolicyconflict)

- **The MDM Diagnostic Report (MdmDiagnosticsTool.exe) is your best local troubleshooting tool.** It produces a CAB file with `MDMDiagReport.xml` that shows every policy, its source, its current value, and any errors. This is far more precise than reading registry keys manually and is the file you should attach to any escalation.

- **Baseline → Settings Catalog migration is a one-way maturity upgrade.** Settings Catalog gives you granular control (per-setting, with descriptions), while baselines give you opinionated defaults. As your environment matures, migrating baselines to Settings Catalog lets you fine-tune exactly which hardening settings apply and override individual settings without the all-or-nothing constraint of a baseline. [MS Docs: Settings Catalog](https://learn.microsoft.com/en-us/mem/intune/configuration/settings-catalog)
